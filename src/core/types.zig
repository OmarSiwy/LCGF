//! Small value types of the core: identities, indices, colours, rects, sizing and style rows.
//! Tier 0: plain data, no allocator, no I/O. Ported from prototype/ui.zig ("Small value types").

const std = @import("std");

/// Stable identity of a widget across frames. 0 means "anonymous".
pub const Id = enum(u32) {
    none = 0,
    _,

    /// Compile-time hash of a name: `Id.from("save")`.
    pub fn from(comptime name: []const u8) Id {
        return @fromBackingInt(comptime nonZero(std.hash.Fnv1a_32.hash(name)));
    }
    /// Compile-time hash of a call site: `Id.src(@src())`.
    pub fn src(comptime loc: std.lang.SourceLocation) Id {
        return from(loc.module ++ ":" ++ loc.file ++ ":" ++ std.fmt.comptimePrint("{d}:{d}", .{ loc.line, loc.column }));
    }
    /// Run-time hash, for ids built from data.
    pub fn hash(bytes: []const u8) Id {
        return @fromBackingInt(nonZero(std.hash.Fnv1a_32.hash(bytes)));
    }
    /// Derives a child id, for widgets created in a loop: `row_id.with(i)`.
    pub fn with(self: Id, n: u32) Id {
        var x = @backingInt(self) ^ (n +% 0x9E37_79B9);
        x = (x ^ (x >> 16)) *% 0x85EB_CA6B;
        x = (x ^ (x >> 13)) *% 0xC2B2_AE35;
        return @fromBackingInt(nonZero(x ^ (x >> 16)));
    }
    inline fn nonZero(h: u32) u32 {
        return h + @intFromBool(h == 0);
    }
};

test "Id: compile-time and run-time hashes agree and are never none" {
    const save = Id.from("save");
    try std.testing.expectEqual(save, Id.hash("save"));
    // FNV-1a 32 of "save", so ids stay stable across builds and match the prototype.
    try std.testing.expectEqual(std.hash.Fnv1a_32.hash("save"), @backingInt(save));
    try std.testing.expect(Id.from("open") != save);
    try std.testing.expect(Id.hash("") != .none);
    // nonZero maps the one colliding hash to 1.
    try std.testing.expectEqual(@as(u32, 1), Id.nonZero(0));
    try std.testing.expectEqual(@as(u32, 7), Id.nonZero(7));
}

test "Id: call sites differ, the same site is stable" {
    const a = Id.src(@src());
    const b = Id.src(@src());
    try std.testing.expect(a != b);
    try std.testing.expect(a != .none);
    var same: [2]Id = undefined;
    for (&same) |*s| s.* = Id.src(@src());
    try std.testing.expectEqual(same[0], same[1]);
}

test "Id.with: deterministic, distinct per index, never none" {
    const row = Id.from("row");
    try std.testing.expectEqual(row.with(3), row.with(3));
    var seen: [64]Id = undefined;
    for (&seen, 0..) |*s, i| {
        s.* = row.with(@intCast(i));
        try std.testing.expect(s.* != .none);
        try std.testing.expect(s.* != row);
        for (seen[0..i]) |prev| try std.testing.expect(prev != s.*);
    }
    try std.testing.expect(Id.none.with(0) != .none);
}

/// "No index" for every u32 link in the core.
pub const none: u32 = 0xffff_ffff;

/// Index of a node in the current frame's `Tree`. Valid until the next `begin`.
pub const Node = enum(u32) {
    root = 0,
    none = none,
    _,
    pub inline fn ix(n: Node) u32 {
        return @backingInt(n);
    }
};

pub const Axis = enum(u1) { x = 0, y = 1 };

test "Node: root is row 0, none is the shared no-index value" {
    try std.testing.expectEqual(@as(u32, 0), Node.root.ix());
    try std.testing.expectEqual(none, Node.none.ix());
    const n: Node = @fromBackingInt(42);
    try std.testing.expectEqual(@as(u32, 42), n.ix());
}

test "Axis: one bit, usable as a two-entry index" {
    try std.testing.expectEqual(1, @bitSizeOf(Axis));
    const pair = [2]f32{ 10, 20 };
    try std.testing.expectEqual(@as(f32, 10), pair[@backingInt(Axis.x)]);
    try std.testing.expectEqual(@as(f32, 20), pair[@backingInt(Axis.y)]);
}

/// RGBA8, laid out so the bytes in memory are r, g, b, a on little-endian hosts.
pub const Color = packed struct(u32) {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 0,

    pub const transparent: Color = .{};
    pub const white: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    pub const black: Color = .{ .a = 255 };

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = 255 };
    }
    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }
    /// 0xRRGGBBAA
    pub fn hex(v: u32) Color {
        return .{ .r = @truncate(v >> 24), .g = @truncate(v >> 16), .b = @truncate(v >> 8), .a = @truncate(v) };
    }
    pub inline fn bitsOf(c: Color) u32 {
        return @bitCast(c);
    }
};

test "Color: constructors, hex and bit layout" {
    const c = Color.hex(0x11223344);
    try std.testing.expectEqual(Color.rgba(0x11, 0x22, 0x33, 0x44), c);
    try std.testing.expectEqual(Color.rgba(1, 2, 3, 255), Color.rgb(1, 2, 3));
    try std.testing.expectEqual(@as(u32, 0), Color.transparent.bitsOf());
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), Color.white.bitsOf());
    // r is the low byte, so the bytes in memory are r, g, b, a on little-endian hosts.
    try std.testing.expectEqual(@as(u32, 0x4433_2211), c.bitsOf());
    try std.testing.expectEqual(@as(u32, 0xff00_0000), Color.black.bitsOf());
}
