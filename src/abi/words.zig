//! The word codec: a value as u32 words, written field by field in declaration order, and the
//! layout hash over the field lists. Every type that crosses the C seam as words goes through
//! it (the tables in plan.zig, the runtime front end's styles and rows), so padding never
//! reaches the bytes and no compiler's struct layout is part of the contract.

const std = @import("std");

/// Words of a value of `T` written field by field (`put`).
pub fn wordsOf(comptime T: type) comptime_int {
    return switch (@typeInfo(T)) {
        .float, .int, .bool, .@"enum" => 1,
        .optional => |o| wordsOf(o.child),
        .array => |a| a.len * wordsOf(a.child),
        .@"struct" => |s| if (s.backing_integer != null) 1 else blk: {
            var n: comptime_int = 0;
            for (s.field_types) |F| n += wordsOf(F);
            break :blk n;
        },
        else => @compileError("lcgf words: cannot write " ++ @typeName(T)),
    };
}

/// A value as words and back: f32 as its bits, ints, bools and enums as u32, packed structs as
/// their backing integer, arrays and structs element by element.
pub fn put(comptime T: type, v: T, out: []u32) void {
    switch (@typeInfo(T)) {
        .float => out[0] = @bitCast(v),
        .int => out[0] = @intCast(v),
        .bool => out[0] = @intFromBool(v),
        .@"enum" => out[0] = @intCast(@backingInt(v)),
        // An optional enum: null is all ones.
        .optional => |o| if (v) |x| put(o.child, x, out) else {
            out[0] = std.math.maxInt(u32);
        },
        .array => |a| for (v, 0..) |e, k| put(a.child, e, out[k * wordsOf(a.child) ..]),
        .@"struct" => |s| if (s.backing_integer != null) {
            out[0] = @as(s.backing_integer.?, @bitCast(v));
        } else {
            var at: usize = 0;
            inline for (s.field_names, s.field_types) |name, F| {
                put(F, @field(v, name), out[at..]);
                at += wordsOf(F);
            }
        },
        else => comptime unreachable,
    }
}

pub fn get(comptime T: type, in: []const u32) T {
    switch (@typeInfo(T)) {
        .float => return @bitCast(in[0]),
        .int => return @intCast(in[0]),
        .bool => return in[0] != 0,
        .@"enum" => |e| return @fromBackingInt(@as(e.tag_type, @intCast(in[0]))),
        .optional => |o| return if (in[0] == std.math.maxInt(u32)) null else get(o.child, in),
        .array => |a| {
            var v: T = undefined;
            for (&v, 0..) |*e, k| e.* = get(a.child, in[k * wordsOf(a.child) ..]);
            return v;
        },
        .@"struct" => |s| if (s.backing_integer != null) {
            return @bitCast(@as(s.backing_integer.?, @intCast(in[0])));
        } else {
            var v: T = undefined;
            var at: usize = 0;
            inline for (s.field_names, s.field_types) |name, F| {
                @field(v, name) = get(F, in[at..]);
                at += wordsOf(F);
            }
            return v;
        },
        else => comptime unreachable,
    }
}

/// The layout hash of `list`: FNV-1a of the field names and kinds of each type. Two builds agree
/// on it exactly when they read and write the same words.
pub fn layoutHashOf(comptime list: anytype) u32 {
    @setEvalBranchQuota(100_000);
    var h = std.hash.Fnv1a_32.init();
    inline for (list) |T| hashType(T, &h);
    return h.final();
}

fn hashType(comptime T: type, h: *std.hash.Fnv1a_32) void {
    h.update(@typeName(T));
    switch (@typeInfo(T)) {
        .array => |a| {
            h.update(std.mem.asBytes(&@as(u32, a.len)));
            hashType(a.child, h);
        },
        .@"struct" => |s| for (s.field_names, s.field_types) |name, F| {
            h.update(name);
            hashType(F, h);
        },
        .@"enum" => |e| for (e.field_names) |name| h.update(name),
        else => {},
    }
}
