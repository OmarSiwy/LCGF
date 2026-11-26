//! Mathematical composition over measured inline boxes. Shape each leaf at its intended
//! size, compose its box, then place its original TextRun and emit the supplied rule quads.
//! No formula parser, retained nodes, font callbacks or allocator is required. The optional
//! OpenType MATH view reads constants, glyph corrections and stretch constructions directly
//! from caller-owned font bytes. Device corrections are deliberately left to the host.
//!
//! Font data: https://learn.microsoft.com/typography/opentype/spec/math

const std = @import("std");
const ot = @import("../font/opentype.zig");
const coverage = @import("../shape/layout.zig").coverageIndex;
const draw = @import("../../draw/draw_list.zig");
const Image = @import("emit.zig").Image;
pub const Box = @import("inline_objects.zig").Box;
pub const Error = ot.Error || error{ InvalidInput, NoVariant, LimitExceeded };

/// The 51 MathValueRecords, in the table's specified order. Values are logical pixels;
/// percentages and minimum operator dimensions are exposed separately in Metrics.
pub const Constant = enum(u8) {
    leading,
    axis_height,
    accent_base_height,
    flattened_accent_base_height,
    subscript_shift_down,
    subscript_top_max,
    subscript_baseline_drop_min,
    superscript_shift_up,
    superscript_shift_up_cramped,
    superscript_bottom_min,
    superscript_baseline_drop_max,
    sub_superscript_gap_min,
    superscript_bottom_max_with_subscript,
    space_after_script,
    upper_limit_gap_min,
    upper_limit_baseline_rise_min,
    lower_limit_gap_min,
    lower_limit_baseline_drop_min,
    stack_top_shift_up,
    stack_top_display_shift_up,
    stack_bottom_shift_down,
    stack_bottom_display_shift_down,
    stack_gap_min,
    stack_display_gap_min,
    stretch_stack_top_shift_up,
    stretch_stack_bottom_shift_down,
    stretch_stack_gap_above_min,
    stretch_stack_gap_below_min,
    fraction_numerator_shift_up,
    fraction_numerator_display_shift_up,
    fraction_denominator_shift_down,
    fraction_denominator_display_shift_down,
    fraction_numerator_gap_min,
    fraction_numerator_display_gap_min,
    fraction_rule_thickness,
    fraction_denominator_gap_min,
    fraction_denominator_display_gap_min,
    skewed_fraction_horizontal_gap,
    skewed_fraction_vertical_gap,
    overbar_vertical_gap,
    overbar_rule_thickness,
    overbar_extra_ascender,
    underbar_vertical_gap,
    underbar_rule_thickness,
    underbar_extra_descender,
    radical_vertical_gap,
    radical_display_vertical_gap,
    radical_rule_thickness,
    radical_extra_ascender,
    radical_kern_before_degree,
    radical_kern_after_degree,
};
pub const Metrics = struct {
    values: [51]f32 = @splat(0),
    script_scale: f32 = 0.8,
    scriptscript_scale: f32 = 0.6,
    delimited_min_height: f32 = 0,
    display_operator_min_height: f32 = 0,
    degree_raise: f32 = 0.6,

    pub fn get(m: Metrics, field: Constant) f32 {
        return m.values[@backingInt(field)];
    }
    pub fn set(m: *Metrics, field: Constant, value: f32) void {
        m.values[@backingInt(field)] = value;
    }

    /// Explicit synthetic metrics for a font without MATH. A host can replace individual
    /// values or use Font.metrics; no fallback font is silently selected.
    pub fn proportional(em: f32) Error!Metrics {
        if (!positive(em)) return error.InvalidInput;
        var m: Metrics = .{};
        for (&m.values) |*v| v.* = em * 0.08;
        m.set(.axis_height, em * 0.25);
        m.set(.accent_base_height, em * 0.45);
        m.set(.flattened_accent_base_height, em * 0.7);
        m.set(.subscript_shift_down, em * 0.25);
        m.set(.subscript_top_max, em * 0.35);
        m.set(.superscript_shift_up, em * 0.4);
        m.set(.superscript_shift_up_cramped, em * 0.35);
        m.set(.superscript_baseline_drop_max, em * 0.4);
        m.set(.superscript_bottom_max_with_subscript, em * 0.35);
        m.set(.space_after_script, em * 0.05);
        m.set(.fraction_numerator_shift_up, em * 0.4);
        m.set(.fraction_numerator_display_shift_up, em * 0.65);
        m.set(.fraction_denominator_shift_down, em * 0.4);
        m.set(.fraction_denominator_display_shift_down, em * 0.65);
        m.set(.fraction_rule_thickness, em * 0.05);
        m.set(.overbar_rule_thickness, em * 0.05);
        m.set(.underbar_rule_thickness, em * 0.05);
        m.set(.radical_rule_thickness, em * 0.05);
        m.set(.radical_kern_before_degree, em * 5 / 18);
        m.set(.radical_kern_after_degree, -em * 10 / 18);
        m.delimited_min_height = em * 1.5;
        m.display_operator_min_height = em * 1.5;
        return m;
    }
};

fn read(comptime T: type, data: []const u8, at: usize) Error!T {
    if (at > data.len or data.len - at < @sizeOf(T)) return error.Truncated;
    return std.mem.readInt(T, data[at..][0..@sizeOf(T)], .big);
}
fn tail(data: []const u8, at: usize) Error![]const u8 {
    if (at > data.len) return error.Truncated;
    return data[at..];
}
fn finite(v: f32) bool {
    return std.math.isFinite(v);
}
fn positive(v: f32) bool {
    return finite(v) and v > 0;
}
fn boxValid(b: Box) bool {
    return finite(b.width) and finite(b.height) and finite(b.baseline) and b.width >= 0 and b.height >= 0 and b.baseline >= 0 and b.baseline <= b.height;
}
fn metricsValid(m: Metrics) bool {
    for (m.values) |v| if (!finite(v)) return false;
    return finite(m.degree_raise) and finite(m.script_scale) and finite(m.scriptscript_scale);
}

pub const Axis = enum { horizontal, vertical };
pub const Corner = enum(u2) { top_right, top_left, bottom_right, bottom_left };
pub const Variant = struct { glyph: u16, advance: f32 };
pub const Piece = struct {
    glyph: u16,
    /// Distance along the assembly; vertical assemblies progress upward from their bottom.
    offset: f32,
};
pub const Stretch = struct { count: u32, length: f32, italic: f32, assembled: bool };

/// A borrowed, bounded MATH table. parse checks its fixed header/constants; optional glyph
/// subtables are checked on access. All corrections are unhinted logical-pixel values.
pub const Font = struct {
    data: []const u8,
    scale: f32,
    constants: usize,
    glyph_info: usize,
    variants: usize,

    pub fn fromFace(face: *const ot.Face, px: f32) Error!?Font {
        const data = (try face.dir.find(ot.tag("MATH"))) orelse return null;
        return try parse(data, face.units_per_em, px);
    }

    pub fn parse(data: []const u8, units_per_em: u16, px: f32) Error!Font {
        if (units_per_em == 0 or !positive(px)) return error.InvalidInput;
        if (try read(u16, data, 0) != 1 or try read(u16, data, 2) != 0) return error.Unsupported;
        const constants = try read(u16, data, 4);
        const glyph_info = try read(u16, data, 6);
        const variants = try read(u16, data, 8);
        if (constants == 0) return error.Malformed;
        _ = try read(i16, data, @as(usize, constants) + 212);
        return .{ .data = data, .scale = px / @as(f32, @floatFromInt(units_per_em)), .constants = constants, .glyph_info = glyph_info, .variants = variants };
    }

    pub fn metrics(font: Font) Metrics {
        const d = font.data[font.constants..];
        var m: Metrics = .{
            .script_scale = @as(f32, @floatFromInt(read(i16, d, 0) catch unreachable)) * 0.01,
            .scriptscript_scale = @as(f32, @floatFromInt(read(i16, d, 2) catch unreachable)) * 0.01,
            .delimited_min_height = @as(f32, @floatFromInt(read(u16, d, 4) catch unreachable)) * font.scale,
            .display_operator_min_height = @as(f32, @floatFromInt(read(u16, d, 6) catch unreachable)) * font.scale,
            .degree_raise = @as(f32, @floatFromInt(read(i16, d, 212) catch unreachable)) * 0.01,
        };
        for (&m.values, 0..) |*v, i| v.* = @as(f32, @floatFromInt(read(i16, d, 8 + i * 4) catch unreachable)) * font.scale;
        return m;
    }

    fn info(font: Font, field: usize) Error!?[]const u8 {
        if (font.glyph_info == 0) return null;
        const offset = try read(u16, font.data, font.glyph_info + field);
        return if (offset == 0) null else try tail(font.data, font.glyph_info + offset);
    }
    fn correction(font: Font, glyph: u16, field: usize, fallback: f32) Error!f32 {
        const data = (try font.info(field)) orelse return fallback;
        const cov = try tail(data, try read(u16, data, 0));
        const index = (try coverage(cov, glyph)) orelse return fallback;
        if (index >= try read(u16, data, 2)) return error.Malformed;
        return @as(f32, @floatFromInt(try read(i16, data, 4 + @as(usize, index) * 4))) * font.scale;
    }
    pub fn italic(font: Font, glyph: u16) Error!f32 {
        return font.correction(glyph, 0, 0);
    }
    pub fn accent(font: Font, glyph: u16, fallback_center: f32) Error!f32 {
        return font.correction(glyph, 2, fallback_center);
    }
    pub fn extended(font: Font, glyph: u16) Error!bool {
        const data = (try font.info(4)) orelse return false;
        return (try coverage(data, glyph)) != null;
    }
    /// `height` is positive above the glyph's baseline, in logical pixels.
    pub fn kern(font: Font, glyph: u16, corner: Corner, height: f32) Error!f32 {
        if (!finite(height)) return error.InvalidInput;
        const data = (try font.info(6)) orelse return 0;
        const index = (try coverage(try tail(data, try read(u16, data, 0)), glyph)) orelse return 0;
        if (index >= try read(u16, data, 2)) return error.Malformed;
        const offset = try read(u16, data, 4 + @as(usize, index) * 8 + @as(usize, @backingInt(corner)) * 2);
        if (offset == 0) return 0;
        const k = try tail(data, offset);
        const count = try read(u16, k, 0);
        var row: usize = 0;
        var prior = -std.math.inf(f32);
        for (0..count) |i| {
            const threshold = @as(f32, @floatFromInt(try read(i16, k, 2 + i * 4))) * font.scale;
            if (threshold < prior) return error.Malformed;
            if (height >= threshold) row = i + 1;
            prior = threshold;
        }
        return @as(f32, @floatFromInt(try read(i16, k, 2 + @as(usize, count) * 4 + row * 4))) * font.scale;
    }

    fn construction(font: Font, glyph: u16, axis: Axis) Error!?[]const u8 {
        if (font.variants == 0) return null;
        const data = try tail(font.data, font.variants);
        const vertical = try read(u16, data, 6);
        const horizontal = try read(u16, data, 8);
        const cov_offset = try read(u16, data, if (axis == .vertical) 2 else 4);
        if (cov_offset == 0) return null;
        const index = (try coverage(try tail(data, cov_offset), glyph)) orelse return null;
        if (index >= (if (axis == .vertical) vertical else horizontal)) return error.Malformed;
        const row = @as(usize, index) + (if (axis == .vertical) @as(usize, 0) else vertical);
        const offset = try read(u16, data, 10 + row * 2);
        return if (offset == 0) null else try tail(data, offset);
    }

    /// Smallest font-supplied variant meeting the target, null if none meets it.
    pub fn variant(font: Font, glyph: u16, axis: Axis, target: f32) Error!?Variant {
        if (!finite(target) or target < 0) return error.InvalidInput;
        const data = (try font.construction(glyph, axis)) orelse return null;
        const count = try read(u16, data, 2);
        var best: ?Variant = null;
        for (0..count) |i| {
            const v: Variant = .{ .glyph = try read(u16, data, 4 + i * 4), .advance = @as(f32, @floatFromInt(try read(u16, data, 6 + i * 4))) * font.scale };
            if (v.advance >= target and (best == null or v.advance < best.?.advance)) best = v;
        }
        return best;
    }

    /// Select a variant, otherwise repeat extender parts and distribute legal connector
    /// overlap. Output is bounded by `pieces`; there is no unbounded size-search loop.
    pub fn stretch(font: Font, glyph: u16, axis: Axis, target: f32, pieces: []Piece) Error!Stretch {
        if (try font.variant(glyph, axis, target)) |v| {
            if (pieces.len == 0) return error.NoSpace;
            pieces[0] = .{ .glyph = v.glyph, .offset = 0 };
            return .{ .count = 1, .length = v.advance, .italic = try font.italic(v.glyph), .assembled = false };
        }
        const construction_data = (try font.construction(glyph, axis)) orelse return error.NoVariant;
        const offset = try read(u16, construction_data, 0);
        if (offset == 0) return error.NoVariant;
        const data = try tail(construction_data, offset);
        const count = try read(u16, data, 4);
        if (count == 0) return error.Malformed;
        _ = try read(u16, data, 6 + (@as(usize, count) - 1) * 10 + 8);
        const overlap = @as(f32, @floatFromInt(try read(u16, font.data, font.variants))) * font.scale;
        var repetitions: usize = 0;
        var plan: AssemblyPlan = undefined;
        while (true) : (repetitions += 1) {
            plan = try assemblyPlan(data, count, repetitions, overlap, font.scale, pieces.len);
            if (plan.count > 0 and plan.length >= target) break;
            if (plan.extenders == 0) return error.NoVariant;
            if (repetitions >= pieces.len) return error.NoSpace;
        }
        var remove = @min(@max(plan.length - target, 0), plan.adjustment);
        var n: usize = 0;
        var pen: f32 = 0;
        var previous_end: f32 = 0;
        for (0..count) |i| {
            const part = try assemblyPart(data, i, font.scale);
            const copies = if (part.extender) repetitions else 1;
            for (0..copies) |_| {
                if (n > 0) {
                    const extra = @min(remove, @min(previous_end, part.start) - overlap);
                    pen -= overlap + extra;
                    remove -= extra;
                }
                pieces[n] = .{ .glyph = part.glyph, .offset = pen };
                n += 1;
                pen += part.advance;
                previous_end = part.end;
            }
        }
        return .{ .count = @intCast(n), .length = pen, .italic = @as(f32, @floatFromInt(try read(i16, data, 0))) * font.scale, .assembled = true };
    }
};

const AssemblyPart = struct { glyph: u16, start: f32, end: f32, advance: f32, extender: bool };
fn assemblyPart(data: []const u8, i: usize, scale: f32) Error!AssemblyPart {
    const at = 6 + i * 10;
    const part: AssemblyPart = .{
        .glyph = try read(u16, data, at),
        .start = @as(f32, @floatFromInt(try read(u16, data, at + 2))) * scale,
        .end = @as(f32, @floatFromInt(try read(u16, data, at + 4))) * scale,
        .advance = @as(f32, @floatFromInt(try read(u16, data, at + 6))) * scale,
        .extender = (try read(u16, data, at + 8)) & 1 != 0,
    };
    if (part.start > part.advance or part.end > part.advance or !positive(part.advance)) return error.Malformed;
    return part;
}
const AssemblyPlan = struct { count: usize = 0, extenders: usize = 0, length: f32 = 0, adjustment: f32 = 0 };
fn assemblyPlan(data: []const u8, count: usize, repetitions: usize, overlap: f32, scale: f32, capacity: usize) Error!AssemblyPlan {
    var plan: AssemblyPlan = .{};
    var previous_end: f32 = 0;
    for (0..count) |i| {
        const part = try assemblyPart(data, i, scale);
        if (part.extender) {
            plan.extenders += 1;
            if (part.advance <= overlap) return error.Malformed;
        }
        const copies = if (part.extender) repetitions else 1;
        if (copies > capacity -| plan.count) return error.NoSpace;
        for (0..copies) |_| {
            if (plan.count > 0) {
                const available = @min(previous_end, part.start);
                if (available < overlap) return error.Malformed;
                plan.length -= overlap;
                plan.adjustment += available - overlap;
            }
            plan.length += part.advance;
            previous_end = part.end;
            plan.count += 1;
        }
    }
    return plan;
}

pub fn Composite(comptime children: usize, comptime rules: usize) type {
    return struct { box: Box, offsets: [children][2]f32, rules: [rules][4]f32 };
}
pub const FractionOptions = struct { display: bool = false, padding: f32 = 0, thickness: ?f32 = null };
pub fn fraction(numerator: Box, denominator: Box, m: Metrics, options: FractionOptions) Error!Composite(2, 1) {
    if (!boxValid(numerator) or !boxValid(denominator) or !metricsValid(m) or !finite(options.padding) or options.padding < 0) return error.InvalidInput;
    const thickness = options.thickness orelse m.get(.fraction_rule_thickness);
    if (!finite(thickness) or thickness < 0) return error.InvalidInput;
    const axis = -m.get(.axis_height);
    const top = axis - thickness * 0.5;
    const bottom = axis + thickness * 0.5;
    const up = m.get(if (options.display) .fraction_numerator_display_shift_up else .fraction_numerator_shift_up);
    const down = m.get(if (options.display) .fraction_denominator_display_shift_down else .fraction_denominator_shift_down);
    const gap_top = m.get(if (options.display) .fraction_numerator_display_gap_min else .fraction_numerator_gap_min);
    const gap_bottom = m.get(if (options.display) .fraction_denominator_display_gap_min else .fraction_denominator_gap_min);
    const n_y = @min(-up - numerator.baseline, top - gap_top - numerator.height);
    const d_y = @max(down - denominator.baseline, bottom + gap_bottom);
    const low = @min(n_y, 0);
    const high = @max(d_y + denominator.height, 0);
    const width = @max(numerator.width, denominator.width) + options.padding * 2;
    return .{
        .box = .{ .width = width, .height = high - low, .baseline = -low },
        .offsets = .{ .{ (width - numerator.width) * 0.5, n_y - low }, .{ (width - denominator.width) * 0.5, d_y - low } },
        .rules = .{.{ 0, top - low, width, bottom - low }},
    };
}

pub const ScriptOptions = struct { cramped: bool = false, italic: f32 = 0, sub_kern: f32 = 0, super_kern: f32 = 0 };
pub const Scripts = struct { box: Box, base: [2]f32, subscript: ?[2]f32, superscript: ?[2]f32 };
pub fn scripts(base: Box, subscript: ?Box, superscript: ?Box, m: Metrics, options: ScriptOptions) Error!Scripts {
    if (!boxValid(base) or !metricsValid(m) or !finite(options.italic) or !finite(options.sub_kern) or !finite(options.super_kern)) return error.InvalidInput;
    if (subscript) |s| if (!boxValid(s)) return error.InvalidInput;
    if (superscript) |s| if (!boxValid(s)) return error.InvalidInput;
    const sub = subscript orelse Box{ .width = 0, .height = 0, .baseline = 0 };
    const sup = superscript orelse Box{ .width = 0, .height = 0, .baseline = 0 };
    var sup_baseline = -@max(m.get(if (options.cramped) .superscript_shift_up_cramped else .superscript_shift_up), @max(base.baseline - m.get(.superscript_baseline_drop_max), sup.height - sup.baseline + m.get(.superscript_bottom_min)));
    var sub_baseline = @max(m.get(.subscript_shift_down), @max(base.height - base.baseline + m.get(.subscript_baseline_drop_min), sub.baseline - m.get(.subscript_top_max)));
    if (subscript != null and superscript != null) {
        const sup_bottom = sup_baseline + sup.height - sup.baseline;
        const raise = @max(sup_bottom + m.get(.superscript_bottom_max_with_subscript), 0);
        sup_baseline -= raise;
        const gap = sub_baseline - sub.baseline - (sup_baseline + sup.height - sup.baseline);
        sub_baseline += @max(m.get(.sub_superscript_gap_min) - gap, 0);
    }
    const sub_x = base.width + options.sub_kern;
    const sup_x = base.width + options.italic + options.super_kern;
    const left = @min(0, @min(if (subscript != null) sub_x else 0, if (superscript != null) sup_x else 0));
    const low = @min(-base.baseline, if (superscript != null) sup_baseline - sup.baseline else 0);
    const high = @max(base.height - base.baseline, if (subscript != null) sub_baseline + sub.height - sub.baseline else 0);
    const right = @max(base.width, @max(if (subscript != null) sub_x + sub.width else 0, if (superscript != null) sup_x + sup.width else 0));
    return .{
        .box = .{ .width = right - left + (if (subscript != null or superscript != null) m.get(.space_after_script) else 0), .height = high - low, .baseline = -low },
        .base = .{ -left, -base.baseline - low },
        .subscript = if (subscript != null) .{ sub_x - left, sub_baseline - sub.baseline - low } else null,
        .superscript = if (superscript != null) .{ sup_x - left, sup_baseline - sup.baseline - low } else null,
    };
}

pub const Limits = struct { box: Box, base: [2]f32, above: ?[2]f32, below: ?[2]f32 };
pub fn limits(base: Box, above: ?Box, below: ?Box, m: Metrics, italic: f32) Error!Limits {
    if (!boxValid(base) or !metricsValid(m) or !finite(italic)) return error.InvalidInput;
    if (above) |b| if (!boxValid(b)) return error.InvalidInput;
    if (below) |b| if (!boxValid(b)) return error.InvalidInput;
    const a = above orelse Box{ .width = 0, .height = 0, .baseline = 0 };
    const b = below orelse Box{ .width = 0, .height = 0, .baseline = 0 };
    const width = @max(base.width, @max(if (above != null) a.width + @abs(italic) else 0, if (below != null) b.width + @abs(italic) else 0));
    const ay = @min(-m.get(.upper_limit_gap_min) - a.height, -m.get(.upper_limit_baseline_rise_min) - a.baseline);
    const by = @max(base.height + m.get(.lower_limit_gap_min), base.height + m.get(.lower_limit_baseline_drop_min) - b.baseline);
    const low = if (above != null) @min(ay, 0) else 0;
    const high = if (below != null) @max(by + b.height, base.height) else base.height;
    return .{
        .box = .{ .width = width, .height = high - low, .baseline = base.baseline - low },
        .base = .{ (width - base.width) * 0.5, -low },
        .above = if (above != null) .{ (width - a.width + italic) * 0.5, ay - low } else null,
        .below = if (below != null) .{ (width - b.width - italic) * 0.5, by - low } else null,
    };
}

pub const Radical = struct { box: Box, sign: [2]f32, body: [2]f32, degree: ?[2]f32, rules: [1][4]f32 };
/// Supply an already measured sign/assembly at least as tall as the body plus rule and gap.
pub fn radical(sign: Box, body: Box, degree: ?Box, m: Metrics, display: bool) Error!Radical {
    if (!boxValid(sign) or !boxValid(body) or !metricsValid(m)) return error.InvalidInput;
    if (degree) |b| if (!boxValid(b)) return error.InvalidInput;
    const thickness = @max(m.get(.radical_rule_thickness), 0);
    const gap = @max(m.get(if (display) .radical_display_vertical_gap else .radical_vertical_gap), 0);
    if (sign.height < body.height + gap + thickness) return error.InvalidInput;
    const d = degree orelse Box{ .width = 0, .height = 0, .baseline = 0 };
    const dx = if (degree != null) m.get(.radical_kern_before_degree) else 0;
    const sx = if (degree != null) @max(dx + d.width + m.get(.radical_kern_after_degree), 0) else 0;
    const by = sign.height - body.height;
    const dy = sign.height * (1 - m.degree_raise) - d.height;
    const low = @min(0, if (degree != null) dy else 0) - @max(m.get(.radical_extra_ascender), 0);
    const right = @max(sx + sign.width + body.width, if (degree != null) dx + d.width else 0);
    const left = @min(0, if (degree != null) dx else 0);
    return .{
        .box = .{ .width = right - left, .height = sign.height - low, .baseline = by + body.baseline - low },
        .sign = .{ sx - left, -low },
        .body = .{ sx + sign.width - left, by - low },
        .degree = if (degree != null) .{ dx - left, dy - low } else null,
        .rules = .{.{ sx + sign.width - left, by - gap - thickness - low, sx + sign.width + body.width - left, by - gap - low }},
    };
}

pub fn bar(base: Box, side: enum { over, under }, m: Metrics) Error!Composite(1, 1) {
    if (!boxValid(base) or !metricsValid(m)) return error.InvalidInput;
    const over = side == .over;
    const gap = @max(m.get(if (over) .overbar_vertical_gap else .underbar_vertical_gap), 0);
    const thickness = @max(m.get(if (over) .overbar_rule_thickness else .underbar_rule_thickness), 0);
    const extra = @max(m.get(if (over) .overbar_extra_ascender else .underbar_extra_descender), 0);
    const extension = gap + thickness + extra;
    const y: f32 = if (over) extension else 0;
    const rule_y = if (over) extra else base.height + gap;
    return .{ .box = .{ .width = base.width, .height = base.height + extension, .baseline = base.baseline + y }, .offsets = .{.{ 0, y }}, .rules = .{.{ 0, rule_y, base.width, rule_y + thickness }} };
}

/// Matrices and aligned equation arrays. Rows share baselines; per-column alignment is a
/// factor in 0..1. Every scratch/output slice is caller owned and has a checked capacity.
pub fn matrix(items: []const Box, columns: usize, column_gap: f32, row_gap: f32, axis_height: f32, alignment: []const f32, column_widths: []f32, rows: []Box, offsets: [][2]f32) Error!Box {
    if (columns == 0 or items.len % columns != 0 or !finite(column_gap) or column_gap < 0 or !finite(row_gap) or row_gap < 0 or !finite(axis_height)) return error.InvalidInput;
    const row_count = items.len / columns;
    if (column_widths.len < columns or rows.len < row_count or offsets.len < items.len or (alignment.len != 0 and alignment.len < columns)) return error.NoSpace;
    for (items) |b| if (!boxValid(b)) return error.InvalidInput;
    for (alignment) |a| if (!finite(a) or a < 0 or a > 1) return error.InvalidInput;
    @memset(column_widths[0..columns], 0);
    @memset(rows[0..row_count], .{ .width = 0, .height = 0, .baseline = 0 });
    for (items, 0..) |b, i| {
        const col = i % columns;
        const row = &rows[i / columns];
        column_widths[col] = @max(column_widths[col], b.width);
        const descent = @max(row.height - row.baseline, b.height - b.baseline);
        row.baseline = @max(row.baseline, b.baseline);
        row.height = row.baseline + descent;
    }
    var width: f32 = if (columns > 0) @as(f32, @floatFromInt(columns - 1)) * column_gap else 0;
    for (column_widths[0..columns]) |w| width += w;
    var y: f32 = 0;
    for (rows[0..row_count], 0..) |r, row| {
        var x: f32 = 0;
        for (0..columns) |col| {
            const i = row * columns + col;
            const factor = if (alignment.len == 0) @as(f32, 0.5) else alignment[col];
            offsets[i] = .{ x + (column_widths[col] - items[i].width) * factor, y + r.baseline - items[i].baseline };
            x += column_widths[col] + column_gap;
        }
        y += r.height + (if (row + 1 < row_count) row_gap else 0);
    }
    return .{ .width = width, .height = y, .baseline = std.math.clamp(y * 0.5 + axis_height, 0, y) };
}

/// Place an existing shaped paragraph in a composed child rectangle, retaining clipping,
/// world transform, colour, font and source byte range.
pub fn childRun(run: draw.TextRun, offset: [2]f32, box: Box) draw.TextRun {
    var out = run;
    out.rect = .{ run.rect[0] + offset[0], run.rect[1] + offset[1], run.rect[0] + offset[0] + box.width, run.rect[1] + offset[1] + box.height };
    return out;
}

/// Rules are ordinary solid quads; append them with the renderer's solid material/texture.
pub fn ruleQuads(run: draw.TextRun, rules: []const [4]f32, out: []draw.Quad) error{NoSpace}!u32 {
    if (out.len < rules.len) return error.NoSpace;
    for (rules, out[0..rules.len]) |r, *q| q.* = plainQuad(run, .{ run.rect[0] + r[0], run.rect[1] + r[1], run.rect[0] + r[2], run.rect[1] + r[3] }, .{ 0, 0, 1, 1 });
    return @intCast(rules.len);
}
fn plainQuad(run: draw.TextRun, rect: [4]f32, uv: [4]f32) draw.Quad {
    return .{ .rect = rect, .clip = run.clip, .params = @splat(0), .uv = uv, .radii = @splat(0), .fill = run.color, .border_color = 0, .border = 0, .opacity = 1, .xform = run.xform, .clip_radii = run.clip_radii };
}
/// Atlas images match the returned Piece glyphs. Vertical piece offsets progress upward;
/// the supplied run origin is the baseline/origin of the bottom piece.
pub fn stretchQuads(run: draw.TextRun, pieces: []const Piece, axis: Axis, images: []const Image, out: []draw.Quad) error{NoSpace}!u32 {
    if (images.len < pieces.len or out.len < pieces.len) return error.NoSpace;
    for (pieces, images[0..pieces.len], out[0..pieces.len]) |piece, image, *q| {
        const x = run.rect[0] + (if (axis == .horizontal) piece.offset else 0);
        const y = run.rect[1] - (if (axis == .vertical) piece.offset else 0);
        q.* = plainQuad(run, .{ x + image.bounds[0], y + image.bounds[1], x + image.bounds[2], y + image.bounds[3] }, image.uv);
    }
    return @intCast(pieces.len);
}

test "fraction enters inline layout and positions real paragraph quads plus rule" {
    const lines = @import("lines.zig");
    const inline_objects = @import("inline_objects.zig");
    const emit = @import("emit.zig");
    const m = try Metrics.proportional(20);
    const leaf: Box = .{ .width = 10, .height = 12, .baseline = 9 };
    const f = try fraction(leaf, leaf, m, .{ .padding = 2 });
    try std.testing.expect(f.offsets[0][1] + leaf.height < f.rules[0][1]);
    try std.testing.expect(f.offsets[1][1] > f.rules[0][3]);
    var paragraph: @import("golden.zig").Para = .{};
    paragraph.fixed("a\u{fffc}b", 10);
    var metrics = [_]lines.Metrics{ .{ .ascent = 9, .descent = 3 }, undefined };
    const objects = [_]inline_objects.Object{.{ .byte = 1, .size = .{ f.box.width, f.box.height }, .baseline = f.box.baseline, .span = 1 }};
    try inline_objects.measure(&paragraph.g, "a\u{fffc}b", &objects, &metrics, metrics[0]);
    try lines.breakLines(&paragraph.g, "a\u{fffc}b", 100, &paragraph.l);
    lines.place(&paragraph.l, &paragraph.g, "a\u{fffc}b", &metrics, .{ .width = 100 });
    try std.testing.expectEqual(f.box.height, paragraph.l.height[0]);
    var placed: [1]inline_objects.Placement = undefined;
    _ = try inline_objects.place(&paragraph.l, &paragraph.g, &objects, &metrics, &placed);
    const run: draw.TextRun = .{ .rect = .{ 30 + placed[0].rect[0], 40 + placed[0].rect[1], 200, 200 }, .clip = .{ 0, 0, 300, 300 }, .px = 12, .start = 0, .bytes = 1, .font = 0, .color = 0xffffffff, .xform = .{ 2, 0, 0, 2, 3, 4 }, .clip_radii = .{ 2, 3, 4, 5 } };
    var numerator: @import("golden.zig").Para = .{};
    numerator.fixed("x", 10);
    try lines.breakLines(&numerator.g, "x", 100, &numerator.l);
    lines.place(&numerator.l, &numerator.g, "x", &.{.{ .ascent = 9, .descent = 3 }}, .{});
    var quads: [2]draw.Quad = undefined;
    _ = try emit.quads(childRun(run, f.offsets[0], leaf), &numerator.g, &numerator.l, "x", .{ .glyphs = &.{.{ .bounds = .{ 0, -9, 10, 3 } }} }, quads[0..1]);
    _ = try ruleQuads(run, &f.rules, quads[1..]);
    try std.testing.expect(quads[0].rect[3] < quads[1].rect[1]);
    try std.testing.expectEqual(run.xform, quads[0].xform);
    try std.testing.expectEqual(run.clip_radii, quads[1].clip_radii);
}

test "scripts limits radicals and matrices reserve actual measured extents" {
    const m = try Metrics.proportional(20);
    const base: Box = .{ .width = 16, .height = 20, .baseline = 15 };
    const small: Box = .{ .width = 8, .height = 10, .baseline = 7 };
    const s = try scripts(base, small, small, m, .{ .italic = 2 });
    try std.testing.expect(s.superscript.?[1] + small.height + m.get(.sub_superscript_gap_min) <= s.subscript.?[1] + 0.001);
    try std.testing.expect(s.box.height > base.height);
    const l = try limits(base, small, small, m, 2);
    try std.testing.expect(l.above.?[1] + small.height < l.base[1]);
    try std.testing.expect(l.below.?[1] > l.base[1] + base.height);
    const radical_sign: Box = .{ .width = 8, .height = 28, .baseline = 23 };
    const r = try radical(radical_sign, base, small, m, false);
    try std.testing.expect(r.rules[0][3] <= r.body[1]);
    try std.testing.expectEqual(r.body[1] + base.baseline, r.box.baseline);
    var widths: [2]f32 = undefined;
    var rows: [2]Box = undefined;
    var offsets: [4][2]f32 = undefined;
    const b = try matrix(&.{ base, small, small, base }, 2, 4, 3, 5, &.{ 0, 1 }, &widths, &rows, &offsets);
    try std.testing.expectEqual(@as(f32, 36), b.width);
    try std.testing.expectEqual(@as(f32, 43), b.height);
    try std.testing.expectEqual(offsets[0][1] + base.baseline, offsets[1][1] + small.baseline);
    try std.testing.expectError(error.NoSpace, matrix(&.{base}, 1, 0, 0, 0, &.{}, widths[0..0], &rows, &offsets));
}

fn put16(data: []u8, at: usize, value: u16) void {
    std.mem.writeInt(u16, data[at..][0..2], value, .big);
}
test "OpenType MATH constants and extender assembly become glyph quads with bounded storage" {
    // Header + all constants + one vertical construction (glyph 10), no prebuilt variants.
    var data: [300]u8 = @splat(0);
    put16(&data, 0, 1);
    put16(&data, 4, 10);
    put16(&data, 8, 224);
    put16(&data, 10, 80);
    put16(&data, 12, 60);
    put16(&data, 18 + @as(usize, @backingInt(Constant.axis_height)) * 4, 250);
    put16(&data, 222, 60);
    put16(&data, 224, 100);
    put16(&data, 226, 12);
    put16(&data, 230, 1);
    put16(&data, 234, 18); // construction offset
    put16(&data, 236, 1);
    put16(&data, 238, 1);
    put16(&data, 240, 10); // coverage
    put16(&data, 242, 4); // assembly offset
    put16(&data, 250, 3); // assembly part count
    for (0..3) |i| {
        const at = 252 + i * 10;
        put16(&data, at, @intCast(11 + i));
        put16(&data, at + 2, 200);
        put16(&data, at + 4, 200);
        put16(&data, at + 6, 500);
        put16(&data, at + 8, @intFromBool(i == 1));
    }
    const font = try Font.parse(&data, 1000, 20);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), font.metrics().script_scale, 0.0001);
    try std.testing.expectEqual(@as(f32, 5), font.metrics().get(.axis_height));
    var pieces: [8]Piece = undefined;
    const stretched = try font.stretch(10, .vertical, 41, &pieces);
    try std.testing.expect(stretched.assembled);
    try std.testing.expectEqual(@as(f32, 41), stretched.length);
    try std.testing.expectEqual(@as(u32, 5), stretched.count);
    try std.testing.expectError(error.NoSpace, font.stretch(10, .vertical, 41, pieces[0..2]));
    try std.testing.expectError(error.Truncated, Font.parse(data[0..100], 1000, 20));
    const run: draw.TextRun = .{ .rect = .{ 20, 80, 30, 90 }, .clip = .{ 0, 0, 100, 100 }, .px = 20, .start = 0, .bytes = 0, .font = 0, .color = 0xffffffff, .xform = .{ 0, 1, -1, 0, 0, 0 } };
    const images: [8]Image = @splat(.{ .bounds = .{ 0, -10, 5, 0 } });
    var quads: [8]draw.Quad = undefined;
    _ = try stretchQuads(run, pieces[0..stretched.count], .vertical, &images, &quads);
    try std.testing.expect(quads[stretched.count - 1].rect[1] < quads[0].rect[1]);
    try std.testing.expectEqual(run.xform, quads[0].xform);
}
