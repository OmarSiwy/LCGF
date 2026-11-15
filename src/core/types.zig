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
