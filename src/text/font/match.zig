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

/// One row of an application's font table: the catalog row `find` selects over, and the file
/// the host loads into shaper `entry.font`.
pub const Face = struct { entry: Entry, path: []const u8 };

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

pub const Metric = enum { x_height, cap_height, zero_advance, ideograph_advance };
pub const AdjustError = error{ InvalidSize, MissingMetric };

/// Selected font metric as a fraction of its em. OS/2 x/cap metadata wins when present;
/// native TrueType outline bounds supply a measured fallback. Missing glyph/metric is an
/// explicit error, rather than a silent guessed x-height or incorrect fallback advance.
pub fn metricRatio(face: *const opentype.Face, metric: Metric) error{MissingMetric}!f32 {
    const os2 = (face.dir.find(opentype.tag("OS/2")) catch null) orelse &.{};
    if ((metric == .x_height or metric == .cap_height) and read(os2, 0, 0) >= 2 and os2.len >= 90) {
        const at: usize = if (metric == .x_height) 86 else 88;
        const value = std.mem.readInt(i16, os2[at..][0..2], .big);
        if (value > 0) return @as(f32, @floatFromInt(value)) / @as(f32, @floatFromInt(face.units_per_em));
    }
    const cp: u21 = switch (metric) {
        .x_height => 'x',
        .cap_height => 'H',
        .zero_advance => '0',
        .ideograph_advance => 0x6c34,
    };
    const glyph = face.cmap.glyph(cp);
    if (glyph == 0) return error.MissingMetric;
    var value: f32 = 0;
    if (metric == .zero_advance or metric == .ideograph_advance) {
        value = @floatFromInt(face.hMetrics(glyph).advance);
    } else {
        const record = face.glyphRecord(glyph) catch return error.MissingMetric;
        if (record.len < 10) return error.MissingMetric;
        value = @floatFromInt(std.mem.readInt(i16, record[8..10], .big));
    }
    if (value <= 0) return error.MissingMetric;
    return value / @as(f32, @floatFromInt(face.units_per_em));
}

pub fn adjustedSize(face: *const opentype.Face, px: f32, target_ratio: f32, metric: Metric) AdjustError!f32 {
    if (!std.math.isFinite(px) or !std.math.isFinite(target_ratio) or px < 0 or target_ratio < 0) return error.InvalidSize;
    const result = px * target_ratio / try metricRatio(face, metric);
    if (!std.math.isFinite(result)) return error.InvalidSize;
    return result;
}

/// Direct font-size-adjust consumer: normal Stack measurement/shaping uses the new px.
pub fn applySizeAdjust(tx: *Texts, row: u32, face: *const opentype.Face, target_ratio: f32, metric: Metric) AdjustError!void {
    tx.c.px[row] = try adjustedSize(face, tx.c.px[row], target_ratio, metric);
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
    const old_width = tx.c.w[0];
    const old_height = tx.c.h[0];
    const ratio = try metricRatio(&bold, .x_height);
    try applySizeAdjust(&tx, 0, &bold, ratio * 0.5, .x_height);
    try std.testing.expectApproxEqAbs(@as(f32, 10), tx.c.px[0], 0.001);
    st.measure(&tx, &strings, &ascent);
    try std.testing.expectApproxEqAbs(old_width * 0.5, tx.c.w[0], 0.001);
    try std.testing.expectApproxEqAbs(old_height * 0.5, tx.c.h[0], 0.001);
    try std.testing.expectError(error.MissingMetric, metricRatio(&bold, .ideograph_advance));
    try std.testing.expectError(error.InvalidSize, adjustedSize(&bold, 20, -1, .x_height));
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
