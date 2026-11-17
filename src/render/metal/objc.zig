//! The Objective-C runtime, reached without headers or link-time libraries: libobjc, Metal and
//! QuartzCore are opened at run time and every message goes through `objc_msgSend` cast to the
//! call's C signature (`msg`). So the back end cross-compiles from any host, and on a machine
//! without them `load` fails instead of the program failing to start.
//!
//!     try objc.load();
//!     const layer = objc.msg(objc.Id, objc.class("CAMetalLayer"), "new", .{});
//!     defer objc.release(layer);
//!
//! One `objc_msgSend` serves every return type on arm64. On x86_64 a struct return larger than
//! 16 bytes would need `objc_msgSend_stret`; no call made here returns one.

const std = @import("std");
const builtin = @import("builtin");

pub const Id = *opaque {};
pub const Sel = *opaque {};
pub const Class = *opaque {};
pub const BOOL = bool;
pub const NSUInteger = usize;
pub const NSInteger = isize;
pub const CGFloat = f64;
pub const CGSize = extern struct { width: CGFloat, height: CGFloat };

pub const Error = error{ NoLibrary, MissingFunction };

const Fns = struct {
    objc_msgSend: *const fn () callconv(.c) void,
    objc_getClass: *const fn ([*:0]const u8) callconv(.c) ?Class,
    sel_registerName: *const fn ([*:0]const u8) callconv(.c) Sel,
    objc_autoreleasePoolPush: *const fn () callconv(.c) ?*anyopaque,
    objc_autoreleasePoolPop: *const fn (?*anyopaque) callconv(.c) void,
};

/// `MTLCreateSystemDefaultDevice`, the one Metal entry point that is not a message.
pub var createSystemDefaultDevice: *const fn () callconv(.c) ?Id = undefined;
// ponytail: process-global, as the Objective-C runtime it points into is.
var fns: Fns = undefined;
var loaded = false;

const libobjc = "/usr/lib/libobjc.A.dylib";
const metal = "/System/Library/Frameworks/Metal.framework/Metal";
const quartz_core = "/System/Library/Frameworks/QuartzCore.framework/QuartzCore";

/// Opens libobjc, Metal and QuartzCore (CAMetalLayer). Call once before anything else here;
/// later calls return at once. Fails off macOS.
pub fn load() Error!void {
    if (loaded) return;
    const objc = std.c.dlopen(libobjc, .{ .NOW = true }) orelse return error.NoLibrary;
    const mtl = std.c.dlopen(metal, .{ .NOW = true }) orelse return error.NoLibrary;
    _ = std.c.dlopen(quartz_core, .{ .NOW = true }) orelse return error.NoLibrary;
    inline for (@typeInfo(Fns).@"struct".field_names) |name| {
        @field(fns, name) = @ptrCast(@alignCast(std.c.dlsym(objc, name.ptr) orelse return error.MissingFunction));
    }
    createSystemDefaultDevice = @ptrCast(@alignCast(std.c.dlsym(mtl, "MTLCreateSystemDefaultDevice") orelse return error.MissingFunction));
    loaded = true;
}

/// A class by name; a missing class is a programming error (the name is a constant).
pub fn class(comptime name: [:0]const u8) Id {
    return @ptrCast(fns.objc_getClass(name) orelse std.debug.panic("objc: no class {s}", .{name}));
}

/// One cache per selector. Objective-C interns names, so concurrent first lookups
/// can publish the same selector. The cached path only loads the pointer.
pub fn sel(comptime name: [:0]const u8) Sel {
    const Cache = struct {
        const key = name;
        var stored = std.atomic.Value(?Sel).init(null);
    };
    if (Cache.stored.load(.monotonic)) |s| return s;
    const registered = fns.sel_registerName(Cache.key);
    Cache.stored.store(registered, .monotonic);
    return registered;
}

/// The C signature of `objc_msgSend` for a message with `Args` to a receiver, returning `R`.
pub fn Send(comptime R: type, comptime Args: type) type {
    const a = @typeInfo(Args).@"struct".field_types;
    return switch (a.len) {
        0 => fn (Id, Sel) callconv(.c) R,
        1 => fn (Id, Sel, a[0]) callconv(.c) R,
        2 => fn (Id, Sel, a[0], a[1]) callconv(.c) R,
        3 => fn (Id, Sel, a[0], a[1], a[2]) callconv(.c) R,
        4 => fn (Id, Sel, a[0], a[1], a[2], a[3]) callconv(.c) R,
        5 => fn (Id, Sel, a[0], a[1], a[2], a[3], a[4]) callconv(.c) R,
        else => @compileError("objc.msg: more than 5 arguments"),
    };
}

/// Sends `selector` to `target` with `args` (a tuple of C-ABI values) and returns its `R`.
/// Argument types are the tuple's: pass `@as(NSUInteger, n)`, not a bare integer literal.
pub fn msg(comptime R: type, target: Id, comptime selector: [:0]const u8, args: anytype) R {
    const f: *const Send(R, @TypeOf(args)) = @ptrCast(fns.objc_msgSend);
    return @call(.auto, f, .{ target, sel(selector) } ++ args);
}

pub fn release(o: Id) void {
    msg(void, o, "release", .{});
}

pub fn retain(o: Id) Id {
    return msg(Id, o, "retain", .{});
}

/// An autoreleased NSString with `s`'s bytes (UTF-8).
pub fn string(s: [:0]const u8) Id {
    return msg(Id, class("NSString"), "stringWithUTF8String:", .{s.ptr});
}

/// An autorelease pool. Objects that methods return without `new`, `alloc` or `copy` in their
/// names live until the pool around them pops; wrap each frame (and setup) in one.
pub const Pool = struct {
    token: ?*anyopaque,

    pub fn push() Pool {
        return .{ .token = fns.objc_autoreleasePoolPush() };
    }

    pub fn pop(p: Pool) void {
        fns.objc_autoreleasePoolPop(p.token);
    }
};

const testing = std.testing;

test "objc: message signatures follow the argument tuple" {
    try testing.expectEqual(fn (Id, Sel) callconv(.c) void, Send(void, @TypeOf(.{})));
    try testing.expectEqual(fn (Id, Sel, NSUInteger, CGSize) callconv(.c) Id, Send(Id, @TypeOf(.{ @as(NSUInteger, 1), CGSize{ .width = 1, .height = 2 } })));
}

test "objc: load fails cleanly where there is no Objective-C runtime" {
    if (builtin.os.tag == .macos) return error.SkipZigTest;
    try testing.expectError(error.NoLibrary, load());
}

test "objc: messages reach a real runtime" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try load();
    const pool = Pool.push();
    defer pool.pop();
    const s = string("metal");
    try testing.expectEqual(@as(NSUInteger, 5), msg(NSUInteger, s, "length", .{}));
}

test "selectors cache each name independently" {
    const Registrar = struct {
        var calls: usize = 0;
        fn intern(name: [*:0]const u8) callconv(.c) Sel {
            calls += 1;
            return @ptrCast(@constCast(name));
        }
    };
    if (builtin.os.tag == .macos) {
        try load();
    } else {
        fns.sel_registerName = Registrar.intern;
    }
    defer if (builtin.os.tag != .macos) {
        fns.sel_registerName = undefined;
    };
    const a = sel("lcgfTestFirst:");
    const b = sel("lcgfTestSecond:");
    try testing.expect(a != b);
    try testing.expectEqual(a, sel("lcgfTestFirst:"));
    try testing.expectEqual(b, sel("lcgfTestSecond:"));
    if (builtin.os.tag != .macos) try testing.expectEqual(2, Registrar.calls);
}
