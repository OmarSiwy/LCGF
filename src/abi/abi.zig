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
    };
}

/// A type the mapping passes through as it is: C has the same thing.
fn isDirect(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .float, .bool, .void => true,
        .@"struct" => |s| s.layout == .@"extern",
        .pointer => |p| p.size != .slice and isDirect(p.child),
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
        .@"struct" => |s| if (s.backing_integer) |B| &.{B} else &.{*const Words(T)},
        .pointer => |p| if (p.size == .slice)
            &.{ [*]const p.child, usize }
        else if (p.attrs.@"const" and @typeInfo(p.child) == .@"struct")
            &.{*const Words(p.child)}
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

/// The C result of a Zig result `T`; a slice returns its pointer and writes its length out.
pub fn CResult(comptime T: type) type {
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
/// result's length.
pub fn cParamsOf(comptime F: type, comptime handles: anytype) []const type {
    const info = @typeInfo(F).@"fn";
    var out: []const type = &.{};
    for (info.param_types) |P| out = out ++ CParams(P.?, handles);
    if (isSlice(info.return_type.?)) out = out ++ &[_]type{*usize};
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
        .@"struct" => |s| return if (s.backing_integer != null) @bitCast(c[at]) else words.get(T, &c[at].w),
        // A `*const T` of words is decoded by `invoke`, into room the call can point at.
        .pointer => return c[at][0..c[at + 1]],
        else => comptime unreachable,
    }
}

/// Zig result `v` as its C result.
pub fn toC(comptime T: type, v: T) CResult(T) {
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
            @field(scratch, name) = words.get(Child, &c[at].w);
            args[k] = &@field(scratch, name);
        } else args[k] = fromC(P.?, handles, c, at);
        at += n;
    }
    const r = @call(.always_inline, f, args);
    if (comptime isSlice(R)) c[at].* = r.len;
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
