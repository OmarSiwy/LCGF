//! System font discovery on macOS, through Core Text.
//!
//! Outside the tiers (it calls an OS API), reached through system.zig. Core Text and Core
//! Foundation are opened at run time from their framework paths and their few functions looked
//! up by name (docs/DEPENDENCIES.md: reached through the system, no extra library), so building
//! needs no macOS SDK. `find` asks Core Text for the font it would draw the character with,
//! starting from Helvetica (CTFontCreateForString, the system's own fallback cascade), and
//! returns that font's file (the descriptor attribute kCTFontURLAttribute). Core Text gives no
//! index into a collection, so `Found.name` carries the PostScript name and the caller picks
//! the face with `fallback.faceByName`.

const std = @import("std");
const Found = @import("system.zig").Found;

const CFIndex = isize;
const CFRange = extern struct { location: CFIndex, length: CFIndex };
const Ref = *const anyopaque;
const utf8_encoding: u32 = 0x08000100;

const Api = struct {
    CFStringCreateWithBytes: *const fn (?Ref, [*]const u8, CFIndex, u32, u8) callconv(.c) ?Ref,
    CFStringGetLength: *const fn (Ref) callconv(.c) CFIndex,
    CFStringGetCString: *const fn (Ref, [*]u8, CFIndex, u32) callconv(.c) u8,
    CFURLGetFileSystemRepresentation: *const fn (Ref, u8, [*]u8, CFIndex) callconv(.c) u8,
    CFRelease: *const fn (Ref) callconv(.c) void,
    CTFontCreateWithName: *const fn (Ref, f64, ?*const anyopaque) callconv(.c) ?Ref,
    CTFontCreateForString: *const fn (Ref, Ref, CFRange) callconv(.c) ?Ref,
    CTFontCopyAttribute: *const fn (Ref, Ref) callconv(.c) ?Ref,
    CTFontCopyPostScriptName: *const fn (Ref) callconv(.c) ?Ref,
    /// A global CFStringRef: the symbol is the variable's address.
    kCTFontURLAttribute: *const Ref,
};

pub const Discovery = struct {
    cf: std.DynLib,
    ct: std.DynLib,
    api: Api,
    base: Ref,
    /// The PostScript name of the last face found; `Found.name` points here.
    name: [256]u8 = undefined,

    pub fn init() error{Unavailable}!Discovery {
        var cf = std.DynLib.open("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation") catch return error.Unavailable;
        errdefer cf.close();
        var ct = std.DynLib.open("/System/Library/Frameworks/CoreText.framework/CoreText") catch return error.Unavailable;
        errdefer ct.close();
        var api: Api = undefined;
        inline for (@typeInfo(Api).@"struct".field_names, @typeInfo(Api).@"struct".field_types) |name, T| {
            const lib = if (name[1] == 'F') &cf else &ct;
            @field(api, name) = lib.lookup(T, name) orelse return error.Unavailable;
        }
        const helvetica = cfString(&api, "Helvetica") orelse return error.Unavailable;
        defer api.CFRelease(helvetica);
        const base = api.CTFontCreateWithName(helvetica, 12, null) orelse return error.Unavailable;
        return .{ .cf = cf, .ct = ct, .api = api, .base = base };
    }

    pub fn deinit(d: *Discovery) void {
        d.api.CFRelease(d.base);
        d.ct.close();
        d.cf.close();
    }

    /// The font Core Text draws `cp` with: its path, written into `path`, and its PostScript
    /// name (`index` is 0). Null when it has none in a file. Core Text answers every
    /// character, with LastResort as the end of its cascade; the caller checks the cmap.
    pub fn find(d: *Discovery, cp: u21, path: []u8) error{NoSpace}!?Found {
        const a = &d.api;
        var bytes: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &bytes) catch return null;
        const str = cfString(a, bytes[0..n]) orelse return null;
        defer a.CFRelease(str);
        const font = a.CTFontCreateForString(d.base, str, .{ .location = 0, .length = a.CFStringGetLength(str) }) orelse return null;
        defer a.CFRelease(font);
        const url = a.CTFontCopyAttribute(font, a.kCTFontURLAttribute.*) orelse return null;
        defer a.CFRelease(url);
        if (a.CFURLGetFileSystemRepresentation(url, 1, path.ptr, @intCast(path.len)) == 0) return error.NoSpace;
        const ps = a.CTFontCopyPostScriptName(font) orelse return null;
        defer a.CFRelease(ps);
        if (a.CFStringGetCString(ps, &d.name, d.name.len, utf8_encoding) == 0) return error.NoSpace;
        return .{
            .path = std.mem.sliceTo(path, 0),
            .index = 0,
            .name = std.mem.sliceTo(&d.name, 0),
        };
    }
};

fn cfString(a: *const Api, s: []const u8) ?Ref {
    return a.CFStringCreateWithBytes(null, s.ptr, @intCast(s.len), utf8_encoding, 0);
}
