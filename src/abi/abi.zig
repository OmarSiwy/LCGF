//! The mapping from a Zig function to its C export (docs/plans/bindings-rust.md §6.1), by
//! comptime reflection over its signature. `Wrap(f)` is the `callconv(.c)` function that decodes
//! each C argument into the Zig parameter, calls `f`, and encodes the result: what a hand-written
//! `cOpen` did, with nothing to keep in step by hand. tools/abi-gen spells the same C types into
//! the header (src/abi/api.zig lists what is exported and the C name of each type).
//!
//! | Zig                                         | C                                        |
//! |---------------------------------------------|------------------------------------------|
//! | ints, floats, `bool` parameters             | the same                                 |
//! | `bool` result                               | `int` (a C `bool` return leaves the upper bits to the callee) |
//! | enum with an integer tag (`Id`, `Node`)     | its tag as `uint32_t`; out of range is the first tag |
//! | bitpack struct (`Response`, `Color`)        | its backing integer                      |
//! | extern struct, or a pointer to one          | the same                                 |
//! | `Handle` types (`*Frame`)                   | a pointer to an opaque `lcgf_<name>`     |
//! | any other struct, by value or `*const`      | `const lcgf_<name> *`: its words (src/abi/words.zig) |
//! | `[]const T` parameter                       | `const T *x, size_t x_len`               |
//! | `[]T` result                                | `T *f(..., size_t *len)`                 |

const std = @import("std");
const words = @import("words.zig");

/// The C form of a pointer to a handle type `T` (a `*Frame`): an opaque type, cast back.
pub fn Handle(comptime T: type) type {
    return opaque {
        pub const Zig = T;
    };
}

/// The C form of a struct of no C layout: its words, in `words.put` order.
pub fn Words(comptime T: type) type {
    return extern struct {
        w: [words.wordsOf(T)]u32,
        pub const Zig = T;
        pub const words_form = true;
    };
}

/// Whether `T` crosses as words: floats, ints of 32 bits or fewer, bools, enums, bitpacks,
/// optional enums, and arrays and structs of them.
pub fn wordable(comptime T: type) bool {
    return comptime wordableIn(T);
}

fn wordableIn(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .float => |f| f.bits == 32,
        .int => |i| i.bits <= 32,
        .bool, .@"enum" => true,
        .optional => |o| @typeInfo(o.child) == .@"enum",
        .array => |a| wordableIn(a.child),
        .@"struct" => |s| s.backing_integer != null or blk: {
            for (s.field_types) |F| if (!wordableIn(F)) break :blk false;
            break :blk true;
        },
        else => false,
    };
}

/// The C form of a struct of no C layout that cannot be words (`Input`): an extern struct of
/// its fields in order, each in its C form: a slice is a pointer (null when empty) and a `_len`,
/// a nested struct its own C form, a bitpack its backing integer, an enum its tag.
pub fn CForm(comptime T: type) type {
    return extern struct {
        f: Fields(T),
        pub const Zig = T;
        pub const c_form = true;
    };
}

/// The C type of a field of type `F`, and the C fields it becomes.
fn cField(comptime F: type) []const type {
    return switch (@typeInfo(F)) {
        .pointer => |p| if (p.size == .slice) &.{ ?[*]const p.child, usize } else &.{F},
        .@"struct" => |s| if (s.backing_integer) |B| &.{B} else if (s.layout == .@"extern") &.{F} else &.{Form(F)},
        .@"enum" => |e| &.{e.tag_type},
        // An optional enum is its tag, all ones for null (as in words).
        .optional => |o| if (@typeInfo(o.child) == .@"enum") &.{@typeInfo(o.child).@"enum".tag_type} else &.{F},
        .array => |a| if (isDirect(a.child)) &.{F} else &.{[a.len]cField(a.child)[0]},
        else => &.{F},
    };
}

pub fn Fields(comptime T: type) type {
    const s = @typeInfo(T).@"struct";
    var names: []const []const u8 = &.{};
    var field_types: []const type = &.{};
    for (s.field_names, s.field_types) |n, F| {
        const C = cField(F);
        names = names ++ &[_][]const u8{n};
        field_types = field_types ++ &[_]type{C[0]};
        if (C.len == 2) {
            names = names ++ &[_][]const u8{n ++ "_len"};
            field_types = field_types ++ &[_]type{C[1]};
        }
    }
    const na: [names.len][]const u8 = names[0..names.len].*;
    const ta: [field_types.len]type = field_types[0..field_types.len].*;
    return @Struct(.@"extern", null, &na, &ta, &@splat(.{}));
}

/// `T`'s C form (words or `CForm`).
pub fn Form(comptime T: type) type {
    return if (wordable(T)) Words(T) else CForm(T);
}

/// `T` from its C form.
pub fn decode(comptime T: type, c: *const Form(T)) T {
    if (comptime wordable(T)) return words.get(T, &c.w);
    var v: T = undefined;
    inline for (@typeInfo(T).@"struct".field_names) |n| @field(v, n) = fromField(@FieldType(T, n), c.f, n);
    return v;
}

/// `T`'s C form of `v`.
pub fn encode(comptime T: type, v: T, out: *Form(T)) void {
    if (comptime wordable(T)) return words.put(T, v, &out.w);
    inline for (@typeInfo(T).@"struct".field_names) |n| toField(@FieldType(T, n), @field(v, n), &out.f, n);
}

fn fromField(comptime F: type, c: anytype, comptime n: []const u8) F {
    const x = @field(c, n);
    return switch (@typeInfo(F)) {
        .pointer => |p| if (p.size == .slice) (if (x) |ptr| ptr[0..@field(c, n ++ "_len")] else &.{}) else x,
        .@"struct" => |s| if (s.backing_integer != null) @bitCast(x) else if (s.layout == .@"extern") x else decode(F, &x),
        .@"enum" => fromC(F, .{}, .{@as(u32, x)}, 0),
        .optional => |o| if (@typeInfo(o.child) == .@"enum") (if (x == std.math.maxInt(@TypeOf(x))) null else fromC(o.child, .{}, .{@as(u32, x)}, 0)) else x,
        .array => |a| if (comptime isDirect(a.child)) x else blk: {
            var out: F = undefined;
            for (&out, x) |*o, e| o.* = fromField(a.child, .{ .e = e }, "e");
            break :blk out;
        },
        else => x,
    };
}

fn toField(comptime F: type, v: F, c: anytype, comptime n: []const u8) void {
    switch (@typeInfo(F)) {
        .pointer => |p| if (p.size == .slice) {
            @field(c, n) = if (v.len == 0) null else v.ptr;
            @field(c, n ++ "_len") = v.len;
        } else {
            @field(c, n) = v;
        },
        .@"struct" => |s| if (s.backing_integer != null) {
            @field(c, n) = @bitCast(v);
        } else if (s.layout == .@"extern") {
            @field(c, n) = v;
        } else encode(F, v, &@field(c, n)),
        .@"enum" => @field(c, n) = @backingInt(v),
        .optional => |o| if (@typeInfo(o.child) == .@"enum") {
            @field(c, n) = if (v) |e| @backingInt(e) else std.math.maxInt(@typeInfo(o.child).@"enum".tag_type);
        } else {
            @field(c, n) = v;
        },
        .array => |a| if (comptime isDirect(a.child)) {
            @field(c, n) = v;
        } else for (&@field(c, n), v) |*o, e| {
            var t: struct { e: cField(a.child)[0] } = undefined;
            toField(a.child, e, &t, "e");
            o.* = t.e;
        },
        else => @field(c, n) = v,
    }
}

/// A type the mapping passes through as it is: C has the same thing.
fn isDirect(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .float, .bool, .void, .@"opaque" => true,
        .@"struct" => |s| s.layout == .@"extern",
        .pointer => |p| p.size != .slice and isDirect(p.child),
        .array => |x| isDirect(x.child),
        .optional => |o| @typeInfo(o.child) == .pointer and isDirect(o.child),
        else => false,
    };
}

/// The C parameters a Zig parameter of type `T` becomes; `handles` are the types passed as
/// opaque pointers.
pub fn CParams(comptime T: type, comptime handles: anytype) []const type {
    if (comptime isHandle(T, handles)) |H| return &.{*Handle(H)};
    if (isDirect(T)) return &.{T};
    return switch (@typeInfo(T)) {
        .@"enum" => &.{u32},
        .@"struct" => |s| if (s.backing_integer) |B| &.{B} else &.{*const Form(T)},
        .pointer => |p| if (p.size == .slice)
            &.{ [*]const p.child, usize }
        else if (p.attrs.@"const" and @typeInfo(p.child) == .@"struct")
            &.{*const Form(p.child)}
        else
            @compileError("abi: no C form for " ++ @typeName(T)),
        else => @compileError("abi: no C form for " ++ @typeName(T)),
    };
}

/// `*Frame` or `*const Frame` for a handle type `Frame`: that type.
fn isHandle(comptime T: type, comptime handles: anytype) ?type {
    const info = @typeInfo(T);
    if (info != .pointer or info.pointer.size != .one) return null;
    inline for (handles) |H| if (info.pointer.child == H) return H;
    return null;
}

/// A result with no C layout: written to an out parameter as its words.
fn isWordsResult(comptime T: type) bool {
    const info = @typeInfo(T);
    return info == .@"struct" and info.@"struct".layout == .auto;
}

/// The C result of a Zig result `T`; a slice returns its pointer and writes its length out, and
/// a struct of no C layout writes its words out.
pub fn CResult(comptime T: type) type {
    if (isWordsResult(T)) return void;
    return switch (@typeInfo(T)) {
        .bool => c_int,
        .@"enum" => u32,
        .@"struct" => |s| if (s.backing_integer) |B| B else if (s.layout == .@"extern") T else @compileError("abi: no C result for " ++ @typeName(T)),
        .pointer => |p| if (p.size != .slice) T else if (p.attrs.@"const") [*]const p.child else [*]p.child,
        else => if (isDirect(T)) T else @compileError("abi: no C result for " ++ @typeName(T)),
    };
}

fn isSlice(comptime T: type) bool {
    const info = @typeInfo(T);
    return info == .pointer and info.pointer.size == .slice;
}

/// Every C parameter of `F`'s export, in order: each Zig parameter's, then `*usize` for a slice
/// result's length or `*Words(R)` for a words result.
pub fn cParamsOf(comptime F: type, comptime handles: anytype) []const type {
    const info = @typeInfo(F).@"fn";
    var out: []const type = &.{};
    for (info.param_types) |P| out = out ++ CParams(P.?, handles);
    const R = info.return_type.?;
    if (isSlice(R)) out = out ++ &[_]type{*usize};
    if (isWordsResult(R)) out = out ++ &[_]type{*Form(R)};
    return out;
}

/// Zig parameter `T` from its C arguments, `c[at..]` (`CParams(T)` of them).
pub fn fromC(comptime T: type, comptime handles: anytype, c: anytype, comptime at: usize) T {
    if (comptime isHandle(T, handles)) |H| return @ptrCast(@alignCast(@as(*Handle(H), c[at])));
    if (comptime isDirect(T)) return c[at];
    switch (@typeInfo(T)) {
        .@"enum" => |e| {
            // An integer outside the enum is its first tag, never an invalid value.
            if (e.mode == .nonexhaustive) return @fromBackingInt(@as(e.tag_type, @truncate(c[at])));
            inline for (e.field_values) |v| if (c[at] == v) return @fromBackingInt(@as(e.tag_type, v));
            return @fromBackingInt(@as(e.tag_type, e.field_values[0]));
        },
        .@"struct" => |s| return if (s.backing_integer != null) @bitCast(c[at]) else decode(T, c[at]),
        // A `*const T` of words is decoded by `invoke`, into room the call can point at.
        .pointer => return c[at][0..c[at + 1]],
        else => comptime unreachable,
    }
}

/// Zig result `v` as its C result.
pub fn toC(comptime T: type, v: T) CResult(T) {
    if (comptime isWordsResult(T)) comptime unreachable;
    return switch (@typeInfo(T)) {
        .bool => @intFromBool(v),
        .@"enum" => @backingInt(v),
        .@"struct" => |s| if (s.backing_integer != null) @bitCast(v) else v,
        .pointer => |p| if (p.size == .slice) v.ptr else v,
        else => v,
    };
}

/// Calls `f` with C arguments `c`, decoded parameter by parameter.
fn invoke(comptime f: anytype, comptime handles: anytype, c: anytype) CResult(@typeInfo(@TypeOf(f)).@"fn".return_type.?) {
    const info = @typeInfo(@TypeOf(f)).@"fn";
    const R = info.return_type.?;
    var args: std.meta.ArgsTuple(@TypeOf(f)) = undefined;
    // `*const T` of words decode into these; the call takes their addresses.
    var scratch: Scratch(@TypeOf(f)) = undefined;
    comptime var at = 0;
    inline for (info.param_types, 0..) |P, k| {
        const n = comptime CParams(P.?, handles).len;
        const ptr = comptime @typeInfo(P.?) == .pointer and isHandle(P.?, handles) == null and !isDirect(P.?) and !isSlice(P.?);
        if (ptr) {
            const Child = @typeInfo(P.?).pointer.child;
            const name = std.fmt.comptimePrint("{d}", .{k});
            @field(scratch, name) = decode(Child, c[at]);
            args[k] = &@field(scratch, name);
        } else args[k] = fromC(P.?, handles, c, at);
        at += n;
    }
    const r = @call(.always_inline, f, args);
    if (comptime isSlice(R)) c[at].* = r.len;
    if (comptime isWordsResult(R)) return encode(R, r, c[at]);
    return toC(R, r);
}

/// Room for the decoded words parameters of `F`: field `k` for parameter `k` (unused ones void).
fn Scratch(comptime F: type) type {
    const info = @typeInfo(F).@"fn";
    var names: [info.param_types.len][]const u8 = undefined;
    var field_types: [info.param_types.len]type = undefined;
    for (info.param_types, 0..) |P, k| {
        names[k] = std.fmt.comptimePrint("{d}", .{k});
        const p = @typeInfo(P.?);
        field_types[k] = if (p == .pointer and p.pointer.size == .one and p.pointer.attrs.@"const" and !isDirect(P.?)) p.pointer.child else void;
    }
    return @Struct(.auto, null, &names, &field_types, &@splat(.{}));
}

/// The `callconv(.c)` export of `f`: one C function per arity, its arguments handed to `invoke`.
pub fn Wrap(comptime f: anytype, comptime handles: anytype) type {
    const C = cParamsOf(@TypeOf(f), handles);
    const R = CResult(@typeInfo(@TypeOf(f)).@"fn".return_type.?);
    return switch (C.len) {
        0 => struct {
            pub fn c() callconv(.c) R {
                return invoke(f, handles, .{});
            }
        },
        1 => struct {
            pub fn c(a: C[0]) callconv(.c) R {
                return invoke(f, handles, .{a});
            }
        },
        2 => struct {
            pub fn c(a: C[0], b: C[1]) callconv(.c) R {
                return invoke(f, handles, .{ a, b });
            }
        },
        3 => struct {
            pub fn c(a: C[0], b: C[1], d: C[2]) callconv(.c) R {
                return invoke(f, handles, .{ a, b, d });
            }
        },
        4 => struct {
            pub fn c(a: C[0], b: C[1], d: C[2], e: C[3]) callconv(.c) R {
                return invoke(f, handles, .{ a, b, d, e });
            }
        },
        5 => struct {
            pub fn c(a: C[0], b: C[1], d: C[2], e: C[3], g: C[4]) callconv(.c) R {
                return invoke(f, handles, .{ a, b, d, e, g });
            }
        },
        6 => struct {
            pub fn c(a: C[0], b: C[1], d: C[2], e: C[3], g: C[4], h: C[5]) callconv(.c) R {
                return invoke(f, handles, .{ a, b, d, e, g, h });
            }
        },
        7 => struct {
            pub fn c(a: C[0], b: C[1], d: C[2], e: C[3], g: C[4], h: C[5], i: C[6]) callconv(.c) R {
                return invoke(f, handles, .{ a, b, d, e, g, h, i });
            }
        },
        8 => struct {
            pub fn c(a: C[0], b: C[1], d: C[2], e: C[3], g: C[4], h: C[5], i: C[6], j: C[7]) callconv(.c) R {
                return invoke(f, handles, .{ a, b, d, e, g, h, i, j });
            }
        },
        else => @compileError("abi: more than 8 C parameters"),
    };
}

const testing = std.testing;
const types = @import("../core/types.zig");

test "abi: every mapped type comes back from its C form" {
    const handles = .{};
    const st: types.Style = .{ .size = .{ .px(40), .pct(0.5) }, .pad = .{ 1, 2, 3, 4 }, .dir = .x, .cursor = .pointer, .fill = .rgb(1, 2, 3), .opacity = 0.5 };
    var w: Words(types.Style) = undefined;
    words.put(types.Style, st, &w.w);
    try testing.expectEqualDeep(st, fromC(types.Style, handles, .{&w}, 0));
    const ts: types.TextStyle = .{ .px = 13, .color = .rgb(9, 8, 7) };
    var tw: Words(types.TextStyle) = undefined;
    words.put(types.TextStyle, ts, &tw.w);
    try testing.expectEqualDeep(ts, fromC(types.TextStyle, handles, .{&tw}, 0));
    const r: types.Response = .{ .hovered = true, .clicked = true };
    try testing.expectEqual(r, fromC(types.Response, handles, .{toC(types.Response, r)}, 0));
    try testing.expectEqual(types.Id.from("x"), fromC(types.Id, handles, .{toC(types.Id, .from("x"))}, 0));
    const Ease = @import("../anim/tweens.zig").Ease;
    try testing.expectEqual(Ease.out_cubic, fromC(Ease, handles, .{@as(u32, 5)}, 0));
    try testing.expectEqual(Ease.linear, fromC(Ease, handles, .{@as(u32, 99)}, 0));
    const s: []const u8 = "abc";
    try testing.expectEqualStrings(s, fromC([]const u8, handles, .{ s.ptr, s.len }, 0));
    try testing.expectEqual(1, toC(bool, true));
}

test "abi: a wrapper decodes, calls and encodes" {
    const S = struct {
        const H = struct { n: u32 };
        fn f(h: *H, st: types.Style, text: []const u8) u32 {
            h.n += 1;
            return @as(u32, @intFromFloat(st.gap)) + @as(u32, @intCast(text.len));
        }
        fn room(h: *const H) []const u8 {
            return "room"[0..h.n];
        }
    };
    var h: S.H = .{ .n = 0 };
    var w: Words(types.Style) = undefined;
    words.put(types.Style, .{ .gap = 5 }, &w.w);
    const W = Wrap(S.f, .{S.H}).c;
    try testing.expectEqual(8, W(@ptrCast(&h), &w, "abc", 3));
    try testing.expectEqual(1, h.n);
    var len: usize = 0;
    const p = Wrap(S.room, .{S.H}).c(@ptrCast(&h), &len);
    try testing.expectEqualStrings("r", p[0..len]);
}

test "abi: a struct with slices crosses as its C form and back" {
    const Input = @import("../core/input.zig").Input;
    const ev = [_]Input.Event{.{ .kind = .press, .code = 0x2b }};
    const in: Input = .{ .time = 1.5, .viewport = .{ 300, 200 }, .buttons = .{ .left = true }, .text = "hi", .events = &ev, .appearance = .{ .dark = true } };
    var c: Form(Input) = undefined;
    encode(Input, in, &c);
    try testing.expectEqual(2, c.f.text_len);
    try testing.expectEqual(null, c.f.contacts);
    const back = decode(Input, &c);
    try testing.expectEqualDeep(in, back);
    try testing.expect(!wordable(Input));
    try testing.expect(wordable(types.Style));
}
