//! Optional paragraph break policies, caller-provided hyphenation patterns and bounded
//! balanced breaking. Outputs feed the existing Lines.place/reorder and glyph emit passes.
//! End/start/middle truncation preserves shaped grapheme clusters and original byte offsets.

const std = @import("std");
const lines = @import("lines.zig");
const utf8 = @import("../unicode/utf8.zig");
const LineBreaks = @import("../unicode/line.zig").LineBreaks;
const draw = @import("../../draw/draw_list.zig");
const Image = @import("emit.zig").Image;
pub const tailoring = @import("tailoring.zig");
pub const Error = error{ NoSpace, InvalidInput, LimitExceeded, UnsupportedPolicy };

pub const Hyphen = struct { byte: u32, advance: f32, penalty: f32 = 50 };
pub const Policy = struct {
    /// keep_all removes automatic CJK intercharacter breaks; explicit hyphens still apply.
    word: enum { normal, keep_all, grapheme } = .normal,
    emergency: bool = true,
    soft_hyphen_advance: f32 = 0,
    tailoring: tailoring.Options = .{},
};
pub const Opportunity = struct { end: u32, ink: u32, byte: u32, mandatory: bool = false, emergency: bool = false, penalty: f32 = 0, marker: f32 = 0 };
pub const Marker = struct { advance: f32 = 0, byte: u32 = 0, x: f32 = 0 };
pub const Scratch = struct { prefix: []f32, cost: []f64, previous: []u32, choices: []u32 };
pub const Options = struct {
    width: f32,
    /// Leading-line exclusion widths. Greedy consumes these; balanced needs a different
    /// two-dimensional cost table and reports UnsupportedPolicy rather than ignoring them.
    line_widths: []const f32 = &.{},
    algorithm: enum { greedy, balanced } = .greedy,
    max_candidates: u32 = 4096,
    balance_last: bool = true,
};

fn cjk(cp: u21) bool {
    return (cp >= 0x2e80 and cp <= 0x9fff) or (cp >= 0xac00 and cp <= 0xd7ff) or (cp >= 0xf900 and cp <= 0xfaff) or (cp >= 0x20000 and cp <= 0x3ffff);
}
fn hard(cp: u21) bool {
    return cp == '\n' or cp == '\r' or cp == 0x85 or cp == 0x2028 or cp == 0x2029;
}

/// Builds opportunities only at shaped grapheme boundaries. Soft hyphen glyphs become
/// invisible zero-advance controls; a chosen break paints the explicit marker instead.
/// Dictionary positions inside a ligature/cluster are ignored, never split. Hyphens must
/// be in increasing source-byte order and use the same text as the shaped rows.
pub fn opportunities(g: *lines.Glyphs, text: []const u8, policy: Policy, hyphens: []const Hyphen, out: []Opportunity) Error![]const Opportunity {
    if (out.len == 0) return error.NoSpace;
    for (hyphens, 0..) |h, i| if (h.byte > text.len or !std.math.isFinite(h.advance) or h.advance < 0 or !std.math.isFinite(h.penalty) or (i > 0 and h.byte <= hyphens[i - 1].byte)) return error.InvalidInput;
    if (!std.math.isFinite(policy.soft_hyphen_advance) or policy.soft_hyphen_advance < 0) return error.InvalidInput;
    out[0] = .{ .end = 0, .ink = 0, .byte = 0 };
    var n: usize = 1;
    var iterator: LineBreaks = .{ .text = text };
    var next = iterator.next();
    var hy: usize = 0;
    var i: u32 = 0;
    var ink: u32 = 0;
    while (i < g.len) {
        var end = i + 1;
        while (end < g.len and g.cluster[end] == g.cluster[i]) end += 1;
        const cp = utf8.decode(text, g.cluster[i]).cp;
        const at: u32 = if (end < g.len) g.cluster[end] else @intCast(text.len);
        if (cp == 0xad) @memset(g.advance[i..end], 0);
        if (!lines.isSpace(text, g.cluster[i]) and cp != 0xad) ink = end;
        while (next != null and next.?.pos < at) next = iterator.next();
        const standard = next != null and next.?.pos == at;
        const mandatory = end == g.len or (standard and next.?.mandatory) or hard(cp);
        const following = if (end < g.len) utf8.decode(text, g.cluster[end]).cp else 0;
        const tailored = tailoring.allowed(cp, following, standard, policy.tailoring);
        const allowed = mandatory or policy.word == .grapheme or policy.tailoring.mode == .anywhere or (tailored and !(policy.word == .keep_all and cjk(cp) and cjk(following)));
        while (hy < hyphens.len and hyphens[hy].byte < at) hy += 1;
        const explicit = policy.tailoring.mode != .anywhere and hy < hyphens.len and hyphens[hy].byte == at;
        const soft = policy.tailoring.mode != .anywhere and cp == 0xad;
        if (allowed or explicit or soft or policy.emergency) {
            if (n == out.len) return error.NoSpace;
            out[n] = .{
                .end = end,
                .ink = ink,
                .byte = at,
                .mandatory = mandatory,
                .emergency = !allowed and !explicit and !soft,
                .marker = if (mandatory) 0 else if (explicit) hyphens[hy].advance else if (soft) policy.soft_hyphen_advance else 0,
                .penalty = if (explicit) hyphens[hy].penalty else if (soft) 50 else 0,
            };
            n += 1;
        }
        i = end;
    }
    return out[0..n];
}

fn width(points: []const Opportunity, prefix: []const f32, first: usize, last: usize) f32 {
    const end = points[last];
    return @max(prefix[end.ink] - prefix[points[first].end], 0) + end.marker;
}

/// `markers` has one row per possible output line. Balanced breaking minimizes squared
/// unused width plus explicit penalties; a large emergency penalty prefers ordinary word
/// and dictionary breaks. Work is bounded by max_candidates and supplied scratch.
pub fn breakLines(g: *const lines.Glyphs, text: []const u8, points: []const Opportunity, options: Options, scratch: Scratch, out: *lines.Lines, markers: []Marker) Error!void {
    if (points.len == 0 or points[0].end != 0 or !std.math.isFinite(options.width) or options.width < 0) return error.InvalidInput;
    if (points.len > options.max_candidates) return error.LimitExceeded;
    for (options.line_widths) |available| if (!std.math.isFinite(available) or available < 0) return error.InvalidInput;
    if (options.algorithm == .balanced and options.line_widths.len > 0) return error.UnsupportedPolicy;
    if (scratch.prefix.len <= g.len or scratch.cost.len < points.len or scratch.previous.len < points.len or scratch.choices.len < points.len) return error.NoSpace;
    scratch.prefix[0] = 0;
    for (g.advance[0..g.len], 0..) |a, i| scratch.prefix[i + 1] = scratch.prefix[i] + a;
    out.len = 0;
    out.ellipsis = 0;
    out.ellipsis_x = 0;
    if (points.len == 1) return;
    var count: usize = 0;
    if (options.algorithm == .greedy) {
        var start: usize = 0;
        while (start + 1 < points.len) {
            const available = if (count < options.line_widths.len) options.line_widths[count] else options.width;
            var ordinary: ?usize = null;
            var emergency: ?usize = null;
            var stop = start + 1;
            while (stop < points.len) : (stop += 1) {
                if (width(points, scratch.prefix, start, stop) <= available + lines.slack) {
                    if (points[stop].emergency) emergency = stop else ordinary = stop;
                }
                if (points[stop].mandatory) break;
            }
            const chosen = ordinary orelse emergency orelse (start + 1);
            scratch.choices[count] = @intCast(chosen);
            count += 1;
            start = chosen;
        }
    } else {
        @memset(scratch.cost[0..points.len], std.math.inf(f64));
        scratch.cost[0] = 0;
        var mandatory: usize = 0;
        for (1..points.len) |end| {
            for (mandatory..end) |start| {
                const w = width(points, scratch.prefix, start, end);
                if (w > options.width + lines.slack and start + 1 != end) continue;
                const delta: f64 = @floatCast(@abs(options.width - w));
                const badness = if (points[end].mandatory and !options.balance_last and w <= options.width) 0 else delta * delta;
                const cost = scratch.cost[start] + badness + points[end].penalty + (if (points[end].emergency) @as(f64, 1e9) else 0) + (if (w > options.width + lines.slack) @as(f64, 1e12) else 0);
                if (cost < scratch.cost[end]) {
                    scratch.cost[end] = cost;
                    scratch.previous[end] = @intCast(start);
                }
            }
            if (points[end].mandatory) mandatory = end;
        }
        var at: u32 = @intCast(points.len - 1);
        while (at != 0) {
            scratch.choices[count] = at;
            count += 1;
            at = scratch.previous[at];
        }
        std.mem.reverse(u32, scratch.choices[0..count]);
    }
    if (out.first.len < count or markers.len < count) return error.NoSpace;
    var previous: usize = 0;
    for (scratch.choices[0..count], 0..) |choice, row| {
        const point = points[choice];
        out.first[row] = points[previous].end;
        out.end[row] = point.end;
        out.ink[row] = @max(point.ink, points[previous].end);
        out.start[row] = if (out.first[row] < g.len) g.cluster[out.first[row]] else @intCast(text.len);
        out.width[row] = width(points, scratch.prefix, previous, choice);
        out.hard[row] = @floatFromInt(@intFromBool(point.mandatory));
        markers[row] = .{ .advance = point.marker, .byte = point.byte, .x = out.width[row] - point.marker };
        previous = choice;
    }
    out.len = @intCast(count);
}

/// After bidi reorder, reserve the marker on the paragraph's visual end. Supply the resolved
/// base direction per line (not a guess from its first glyph); glyph and marker quads agree.
pub fn placeMarkers(l: *const lines.Lines, g: *lines.Glyphs, markers: []Marker, rtl: []const bool) error{NoSpace}!void {
    if (markers.len < l.len or rtl.len < l.len) return error.NoSpace;
    for (0..l.len) |i| {
        markers[i].x = if (rtl[i]) 0 else l.width[i] - markers[i].advance;
        if (rtl[i]) for (g.x[l.first[i]..l.ink[i]]) |*x| {
            x.* += markers[i].advance;
        };
    }
}

pub fn markerQuads(run: draw.TextRun, l: *const lines.Lines, markers: []const Marker, images: []const Image, out: []draw.Quad) error{NoSpace}!u32 {
    if (markers.len < l.len or images.len < l.len) return error.NoSpace;
    var n: u32 = 0;
    for (0..l.len) |i| {
        if (markers[i].advance <= 0) continue;
        if (n == out.len) return error.NoSpace;
        const b = images[i].bounds;
        const x = run.rect[0] + l.x[i] + markers[i].x;
        const y = run.rect[1] + l.baseline[i];
        out[n] = .{ .rect = .{ x + b[0], y + b[1], x + b[2], y + b[3] }, .clip = run.clip, .uv = images[i].uv, .params = @splat(0), .radii = @splat(0), .fill = run.color, .border_color = 0, .border = 0, .opacity = 1, .xform = run.xform, .clip_radii = run.clip_radii };
        n += 1;
    }
    return n;
}

/// Liang-style patterns are caller-owned scalar sequences and inter-scalar weights. A dot
/// denotes a word boundary. The caller chooses the language dictionary and casing policy;
/// this evaluator uses the exact supplied scalars, without an embedded language corpus.
pub const Pattern = struct { letters: []const u21, weights: []const u8 };
pub fn hyphenate(word: []const u8, patterns: []const Pattern, minimum: [2]u32, marker_advance: f32, scalars: []u21, offsets: []u32, weights: []u8, out: []Hyphen) Error![]const Hyphen {
    if (scalars.len < 2 or offsets.len < 2 or weights.len < 3) return error.NoSpace;
    var n: usize = 1;
    scalars[0] = '.';
    offsets[0] = 0;
    var i: usize = 0;
    while (i < word.len) {
        if (n + 1 >= scalars.len or n + 1 >= offsets.len or n + 2 >= weights.len) return error.NoSpace;
        const d = utf8.decode(word, i);
        scalars[n] = d.cp;
        offsets[n] = @intCast(i);
        n += 1;
        i += d.len;
    }
    scalars[n] = '.';
    offsets[n] = @intCast(word.len);
    n += 1;
    @memset(weights[0 .. n + 1], 0);
    for (patterns) |pattern| {
        if (pattern.letters.len == 0 or pattern.weights.len != pattern.letters.len + 1) return error.InvalidInput;
        if (pattern.letters.len > n) continue;
        for (0..n - pattern.letters.len + 1) |at| {
            if (!std.mem.eql(u21, scalars[at..][0..pattern.letters.len], pattern.letters)) continue;
            for (pattern.weights, 0..) |weight, k| weights[at + k] = @max(weights[at + k], weight);
        }
    }
    var count: usize = 0;
    for (1..n - 1) |at| {
        const left = at - 1;
        const right = n - 2 - left;
        if (left < minimum[0] or right < minimum[1] or weights[at] & 1 == 0) continue;
        if (count == out.len) return error.NoSpace;
        out[count] = .{ .byte = offsets[at], .advance = marker_advance };
        count += 1;
    }
    return out[0..count];
}

pub const Truncation = struct { prefix: u32, suffix: u32, omitted: [2]u32, width: f32, truncated: bool };
pub const Truncate = enum { start, middle, end };
fn clusterEnd(g: *const lines.Glyphs, at: u32) u32 {
    var end = at + 1;
    while (end < g.len and g.cluster[end] == g.cluster[at]) end += 1;
    return end;
}
fn clusterStart(g: *const lines.Glyphs, at: u32) u32 {
    var start = at - 1;
    while (start > 0 and g.cluster[start - 1] == g.cluster[start]) start -= 1;
    return start;
}
fn sum(g: *const lines.Glyphs, first: u32, end: u32) f32 {
    var value: f32 = 0;
    for (g.advance[first..end]) |a| value += a;
    return value;
}

pub fn truncate(g: *const lines.Glyphs, text_len: u32, available: f32, marker: f32, mode: Truncate) Error!Truncation {
    if (!std.math.isFinite(available) or !std.math.isFinite(marker) or available < 0 or marker < 0) return error.InvalidInput;
    const whole = sum(g, 0, g.len);
    if (whole <= available + lines.slack) return .{ .prefix = g.len, .suffix = g.len, .omitted = .{ text_len, text_len }, .width = whole, .truncated = false };
    var left: u32 = 0;
    var right = g.len;
    var used = marker;
    var prefix_width: f32 = 0;
    var suffix_width: f32 = 0;
    while (left < right) {
        const prefix = mode == .end or (mode == .middle and prefix_width <= suffix_width);
        const start = if (prefix) left else clusterStart(g, right);
        const end = if (prefix) clusterEnd(g, left) else right;
        const advance = sum(g, start, end);
        if (used + advance > available + lines.slack) break;
        used += advance;
        if (prefix) {
            left = end;
            prefix_width += advance;
        } else {
            right = start;
            suffix_width += advance;
        }
    }
    return .{ .prefix = left, .suffix = right, .omitted = .{ if (left < g.len) g.cluster[left] else text_len, if (right < g.len) g.cluster[right] else text_len }, .width = used, .truncated = true };
}

pub const MarkerGlyph = struct { glyph: u16, advance: f32, span: u32 = 0, x_offset: f32 = 0, y_offset: f32 = 0 };
/// Copies visible original rows plus one caller-shaped marker into a disjoint Glyphs table.
/// Its span/font must belong to the same metrics/font mapping as the paragraph. `sources`
/// identifies original atlas-image rows, maxInt for the marker. Downstream layout and query
/// read the preserved original byte clusters, including the explicit omitted-range boundary.
pub fn copyTruncated(g: *const lines.Glyphs, cut: Truncation, marker: MarkerGlyph, out: *lines.Glyphs, sources: []u32) error{NoSpace}!void {
    const needed = cut.prefix + g.len - cut.suffix + @intFromBool(cut.truncated);
    if (out.glyph.len < needed or sources.len < needed) return error.NoSpace;
    out.len = 0;
    out.fonts = g.fonts;
    for (0..cut.prefix) |i| copy(g, @intCast(i), out, sources);
    if (cut.truncated) {
        const n = out.len;
        out.glyph[n] = marker.glyph;
        out.advance[n] = marker.advance;
        out.cluster[n] = cut.omitted[0];
        out.span[n] = marker.span;
        out.x_offset[n] = marker.x_offset;
        out.y_offset[n] = marker.y_offset;
        out.x[n] = 0;
        out.level[n] = 0;
        sources[n] = std.math.maxInt(u32);
        out.len += 1;
    }
    for (cut.suffix..g.len) |i| copy(g, @intCast(i), out, sources);
}
fn copy(g: *const lines.Glyphs, i: u32, out: *lines.Glyphs, sources: []u32) void {
    inline for (.{ "glyph", "advance", "cluster", "span", "x_offset", "y_offset", "x", "level" }) |field| @field(out, field)[out.len] = @field(g, field)[i];
    sources[out.len] = i;
    out.len += 1;
}

test "strict and loose CJK tailoring change real wrapped lines while keeping glue and clusters" {
    const golden = @import("golden.zig");
    var p: golden.Para = .{};
    var points: [16]Opportunity = undefined;
    var prefix: [16]f32 = undefined;
    var cost: [16]f64 = undefined;
    var previous: [16]u32 = undefined;
    var choices: [16]u32 = undefined;
    var markers: [16]Marker = undefined;
    const scratch: Scratch = .{ .prefix = &prefix, .cost = &cost, .previous = &previous, .choices = &choices };
    const samples = [_][]const u8{ "漢〜字", "漢ぁ字", "漢‐字", "漢・字", "……字" };
    for (samples) |sample| {
        for ([_]tailoring.Mode{ .strict, .loose }, [_]u32{ 2, 1 }) |mode, first_end| {
            p.fixed(sample, 10);
            const opportunities_ = try opportunities(&p.g, sample, .{ .emergency = false, .tailoring = .{ .mode = mode, .writing_system = .japanese } }, &.{}, &points);
            try breakLines(&p.g, sample, opportunities_, .{ .width = 10 }, scratch, &p.l, &markers);
            lines.place(&p.l, &p.g, sample, &.{.{ .ascent = 8, .descent = 2 }}, .{ .width = 10 });
            try std.testing.expectEqual(first_end, p.l.end[0]);
            try std.testing.expectEqual(@as(f32, 8), p.l.baseline[0]);
        }
    }
    const glued = "漢\u{a0}ぁ";
    p.fixed(glued, 10);
    const glued_points = try opportunities(&p.g, glued, .{ .emergency = false, .tailoring = .{ .mode = .loose, .writing_system = .japanese } }, &.{}, &points);
    try breakLines(&p.g, glued, glued_points, .{ .width = 10 }, scratch, &p.l, &markers);
    try std.testing.expectEqual(@as(u32, 1), p.l.len);
    const combined = "漢\u{3099}字";
    p.fixed(combined, 10);
    lines.graphemeClusters(&p.g, combined);
    const anywhere = try opportunities(&p.g, combined, .{ .tailoring = .{ .mode = .anywhere } }, &.{}, &points);
    try breakLines(&p.g, combined, anywhere, .{ .width = 10 }, scratch, &p.l, &markers);
    try std.testing.expectEqual(@as(u32, 2), p.l.end[0]);
}

test "patterns create measured hyphen breaks consumed by standard line placement" {
    var scalars: [32]u21 = undefined;
    var offsets: [32]u32 = undefined;
    var weights: [33]u8 = undefined;
    var hyphens: [16]Hyphen = undefined;
    const patterns: [1]Pattern = .{.{ .letters = &.{ 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h' }, .weights = &.{ 0, 0, 0, 0, 1, 0, 0, 0, 0 } }};
    const h = try hyphenate("abcdefgh", &patterns, .{ 2, 2 }, 5, &scalars, &offsets, &weights, &hyphens);
    try std.testing.expectEqual(1, h.len);
    try std.testing.expectEqual(4, h[0].byte);
    var p: @import("golden.zig").Para = .{};
    p.fixed("abcdefgh", 10);
    var points: [32]Opportunity = undefined;
    var prefix: [33]f32 = undefined;
    var cost: [32]f64 = undefined;
    var previous: [32]u32 = undefined;
    var choices: [32]u32 = undefined;
    var markers: [32]Marker = undefined;
    const ops = try opportunities(&p.g, "abcdefgh", .{}, h, &points);
    const scratch: Scratch = .{ .prefix = &prefix, .cost = &cost, .previous = &previous, .choices = &choices };
    try breakLines(&p.g, "abcdefgh", ops, .{ .width = 45 }, scratch, &p.l, &markers);
    try std.testing.expectEqual(2, p.l.len);
    try std.testing.expectEqual(4, p.l.end[0]);
    try std.testing.expectEqual(@as(f32, 45), p.l.width[0]);
    lines.place(&p.l, &p.g, "abcdefgh", &.{.{ .ascent = 8, .descent = 2 }}, .{});
    try placeMarkers(&p.l, &p.g, &markers, &.{ false, true });
    try std.testing.expectEqual(@as(f32, 40), markers[0].x);
    try breakLines(&p.g, "abcdefgh", ops, .{ .width = 45, .algorithm = .balanced }, scratch, &p.l, &markers);
    try std.testing.expectEqual(4, p.l.end[0]);
    const shaped_boundaries = try opportunities(&p.g, "abcdefgh", .{ .word = .grapheme }, &.{}, &points);
    try breakLines(&p.g, "abcdefgh", shaped_boundaries, .{ .width = 60, .line_widths = &.{ 20, 30 } }, scratch, &p.l, &markers);
    lines.place(&p.l, &p.g, "abcdefgh", &.{.{ .ascent = 8, .descent = 2 }}, .{ .width = 60, .line_widths = &.{ 20, 30 }, .factor = 1 });
    try std.testing.expectEqualSlices(u32, &.{ 0, 2, 5 }, p.l.first[0..p.l.len]);
    try std.testing.expectEqual(@as(f32, 30), p.l.x[2]);
    try std.testing.expectError(error.UnsupportedPolicy, breakLines(&p.g, "abcdefgh", shaped_boundaries, .{ .width = 60, .line_widths = &.{20}, .algorithm = .balanced }, scratch, &p.l, &markers));
}

test "start middle and end truncation preserve complete clusters in real glyph output" {
    var p: @import("golden.zig").Para = .{};
    p.fixed("a\u{301}bcdef", 10);
    lines.graphemeClusters(&p.g, "a\u{301}bcdef");
    var result: @import("golden.zig").Para = .{};
    result.bind();
    var sources: [256]u32 = undefined;
    inline for (.{ Truncate.start, .middle, .end }) |mode| {
        const cut = try truncate(&p.g, "a\u{301}bcdef".len, 45, 5, mode);
        try copyTruncated(&p.g, cut, .{ .glyph = 99, .advance = 5 }, &result.g, &sources);
        try lines.breakLines(&result.g, "a\u{301}bcdef", 45, &result.l);
        try std.testing.expectEqual(1, result.l.len);
        try std.testing.expect(result.l.width[0] <= 45);
        if (cut.prefix > 0) try std.testing.expect(cut.prefix >= 2);
        try std.testing.expectEqual(std.math.maxInt(u32), sources[cut.prefix]);
    }
}
