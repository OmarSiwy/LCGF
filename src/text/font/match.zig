//! Font selection over a caller-owned catalog. Family lists are ordinary borrowed strings,
//! and a successful selection writes the existing Texts.font column. No global font database,
//! object identity, cache, or family interning is required.
//!
//! The ordering is CSS Fonts 4's static-face width/style/weight order, including the special
//! 400..500 weight search. Family comparison is ASCII case-insensitive; applications needing
//! Unicode family-name normalization can provide canonical names from font discovery.

const std = @import("std");
const opentype = @import("opentype.zig");
const Texts = @import("../../core/texts.zig").Texts;

pub const Style = enum { normal, italic, oblique };
pub const Request = struct {
    weight: f32 = 400,
    /// Percentage of normal width, e.g. 75 for condensed and 125 for expanded.
    width: f32 = 100,
    style: Style = .normal,
};

pub const Entry = struct {
    family: []const u8,
    /// Index into the caller's font/shaper table, as Texts.font uses it.
    font: u16,
    weight: f32 = 400,
    width: f32 = 100,
    style: Style = .normal,

    /// Reads static OS/2 selection metadata, falling back to head.macStyle. Names remain
    /// caller-supplied so localized name records and platform aliases have an explicit owner.
    pub fn of(face: *const opentype.Face, family: []const u8, font: u16) Entry {
        const os2 = (face.dir.find(opentype.tag("OS/2")) catch null) orelse &.{};
        const weight = read(os2, 4, if (face.mac_style & 1 != 0) 700 else 400);
        const width = std.math.clamp(read(os2, 6, 5), 1, 9) - 1;
        const selection = read(os2, 62, @as(u16, @intFromBool(face.mac_style & 2 != 0)));
        const widths = [9]f32{ 50, 62.5, 75, 87.5, 100, 112.5, 125, 150, 200 };
        return .{
            .family = family,
            .font = font,
            .weight = @floatFromInt(std.math.clamp(weight, 1, 1000)),
            .width = widths[width],
            .style = if (selection & 0x200 != 0) .oblique else if (selection & 1 != 0) .italic else .normal,
        };
    }
};

fn read(bytes: []const u8, at: usize, default: u16) u16 {
    return if (at + 2 <= bytes.len) std.mem.readInt(u16, bytes[at..][0..2], .big) else default;
}

/// First matching family, then closest width, style, and weight. Equal candidates preserve
/// catalog order. Null means no named family exists; the caller can then choose a fallback
/// explicitly. This selects actual faces: synthetic emboldening/slanting is not implied.
pub fn find(catalog: []const Entry, families: []const []const u8, request: Request) ?usize {
    for (families) |family| {
        var best: ?usize = null;
        var rank: [3]f32 = @splat(std.math.inf(f32));
        for (catalog, 0..) |entry, i| {
            if (!std.ascii.eqlIgnoreCase(entry.family, family)) continue;
            const candidate = [_]f32{ widthRank(entry.width, request.width), styleRank(entry.style, request.style), weightRank(entry.weight, request.weight) };
            if (best == null or less(candidate, rank)) {
                best = i;
                rank = candidate;
            }
        }
        if (best) |i| return i;
    }
    return null;
}

/// Resolves a font directly into a text row, ready for Stack.measure. A miss leaves the
/// previous font untouched and returns false; there is no implicit fallback registry.
pub fn apply(tx: *Texts, row: u32, catalog: []const Entry, families: []const []const u8, request: Request) bool {
    const found = find(catalog, families, request) orelse return false;
    tx.c.font[row] = catalog[found].font;
    return true;
}

fn less(a: [3]f32, b: [3]f32) bool {
    inline for (0..3) |i| {
        if (a[i] != b[i]) return a[i] < b[i];
    }
    return false;
}

fn widthRank(value: f32, wanted: f32) f32 {
    const preferred = if (wanted <= 100) value <= wanted else value >= wanted;
    return @abs(value - wanted) + (if (preferred) @as(f32, 0) else 10000);
}

fn styleRank(value: Style, wanted: Style) f32 {
    if (value == wanted) return 0;
    return switch (wanted) {
        .normal => if (value == .oblique) 1 else 2,
        .italic => if (value == .oblique) 1 else 2,
        .oblique => if (value == .italic) 1 else 2,
    };
}

fn weightRank(value: f32, wanted: f32) f32 {
    if (wanted >= 400 and wanted <= 500) {
        if (value >= wanted and value <= 500) return value - wanted;
        if (value < wanted) return 1000 + wanted - value;
        return 2000 + value - 500;
    }
    const preferred = if (wanted < 400) value <= wanted else value >= wanted;
    return @abs(value - wanted) + (if (preferred) @as(f32, 0) else 2000);
}

test "font requests select actual family faces before the ordinary text measure pass" {
    const mem = @import("../../core/mem.zig");
    const Strings = @import("../../core/strings.zig").Strings;
    const stack = @import("../layout/stack.zig");
    const shape = @import("../shape/shape.zig");
    const golden = @import("../layout/golden.zig");
    const data = @embedFile("testdata/test.ttc");
    const regular = try opentype.Face.parse(data, try opentype.faceOffset(data, 0));
    const bold = try opentype.Face.parse(data, try opentype.faceOffset(data, 1));
    const catalog = [_]Entry{ .of(&regular, "Body", 0), .of(&bold, "Body", 1) };
    try std.testing.expect(catalog[1].weight > catalog[0].weight);
    try std.testing.expectEqual(1, find(&catalog, &.{ "missing", "BODY" }, .{ .weight = 650 }));
    try std.testing.expectEqual(null, find(&catalog, &.{"missing"}, .{}));
    var bytes: [8192]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &bytes };
    var tx: Texts = .init(&carver, 1);
    var string_bytes: [32]u8 = undefined;
    var strings: Strings = .{ .buf = &string_bytes };
    _ = tx.push(0, strings.add("Hello"), &.{ .px = 20 });
    try std.testing.expect(apply(&tx, 0, &catalog, &.{"body"}, .{ .weight = 700 }));
    try std.testing.expectEqual(1, tx.c.font[0]);
    const shapers = [_]shape.Shaper{ .init(regular), .init(bold) };
    var p: golden.Para = .{};
    p.bind();
    var cols: golden.RunCols = .{};
    var st: stack.Stack = .{ .shapers = &shapers, .run = cols.run(), .g = p.g, .l = p.l };
    var ascent: [1]f32 = undefined;
    st.measure(&tx, &strings, &ascent);
    try std.testing.expect(tx.c.w[0] > 0 and tx.c.h[0] > 0 and !st.overflow);
}

test "static-face matching respects width priority and the 400 to 500 weight interval" {
    const catalog = [_]Entry{
        .{ .family = "F", .font = 0, .weight = 300 },
        .{ .family = "F", .font = 1, .weight = 500 },
        .{ .family = "F", .font = 2, .weight = 700 },
        .{ .family = "F", .font = 3, .weight = 400, .width = 75, .style = .italic },
    };
    try std.testing.expectEqual(1, find(&catalog, &.{"F"}, .{ .weight = 400 }));
    try std.testing.expectEqual(0, find(catalog[0..1], &.{"F"}, .{ .weight = 450 }));
    try std.testing.expectEqual(2, find(&catalog, &.{"F"}, .{ .weight = 600 }));
    try std.testing.expectEqual(3, find(&catalog, &.{"F"}, .{ .width = 90, .weight = 700 }));
}
