//! List counters, numbering systems and marker placement. Authoring data and scoped counter
//! rows are caller owned; formatting writes UTF-8 into the caller's buffer. Markers use the
//! ordinary text/quad pipelines and explicit logical-side placement.

const std = @import("std");
const Id = @import("../../core/types.zig").Id;
const draw = @import("../../draw/draw_list.zig");
pub const Box = @import("inline_objects.zig").Box;
pub const Error = error{ NoSpace, InvalidStyle, OutOfRange, Overflow, NoScope };
pub const Additive = struct { weight: u64, symbol: []const u8 };
pub const System = union(enum) {
    numeric: []const []const u8,
    alphabetic: []const []const u8,
    symbolic: []const []const u8,
    cyclic: []const []const u8,
    additive: []const Additive,
};
pub const Style = struct {
    system: System = .{ .numeric = &decimal_digits },
    prefix: []const u8 = "",
    suffix: []const u8 = ". ",
    negative_prefix: []const u8 = "-",
    negative_suffix: []const u8 = "",
    minimum_symbols: u16 = 0,
    pad_symbol: []const u8 = "0",
    range: ?[2]i64 = null,
    /// Explicit fallback for zero alphabetic/symbolic values, unsupported additive values
    /// and values outside range. The decimal result retains this style's affixes.
    decimal_fallback: bool = true,
};
pub const decimal_digits = [_][]const u8{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" };
pub const lower_letters = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z" };
pub const upper_letters = [_][]const u8{ "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z" };
pub const decimal: Style = .{};
pub const decimal_leading_zero: Style = .{ .minimum_symbols = 2 };
pub const lower_alpha: Style = .{ .system = .{ .alphabetic = &lower_letters } };
pub const upper_alpha: Style = .{ .system = .{ .alphabetic = &upper_letters } };
pub const lower_roman: Style = .{ .system = .{ .additive = &.{ .{ .weight = 1000, .symbol = "m" }, .{ .weight = 900, .symbol = "cm" }, .{ .weight = 500, .symbol = "d" }, .{ .weight = 400, .symbol = "cd" }, .{ .weight = 100, .symbol = "c" }, .{ .weight = 90, .symbol = "xc" }, .{ .weight = 50, .symbol = "l" }, .{ .weight = 40, .symbol = "xl" }, .{ .weight = 10, .symbol = "x" }, .{ .weight = 9, .symbol = "ix" }, .{ .weight = 5, .symbol = "v" }, .{ .weight = 4, .symbol = "iv" }, .{ .weight = 1, .symbol = "i" } } }, .range = .{ 1, 3999 } };
pub const upper_roman: Style = .{ .system = .{ .additive = &.{ .{ .weight = 1000, .symbol = "M" }, .{ .weight = 900, .symbol = "CM" }, .{ .weight = 500, .symbol = "D" }, .{ .weight = 400, .symbol = "CD" }, .{ .weight = 100, .symbol = "C" }, .{ .weight = 90, .symbol = "XC" }, .{ .weight = 50, .symbol = "L" }, .{ .weight = 40, .symbol = "XL" }, .{ .weight = 10, .symbol = "X" }, .{ .weight = 9, .symbol = "IX" }, .{ .weight = 5, .symbol = "V" }, .{ .weight = 4, .symbol = "IV" }, .{ .weight = 1, .symbol = "I" } } }, .range = .{ 1, 3999 } };

const Writer = struct {
    out: ?[]u8 = null,
    len: usize = 0,
    fn append(w: *Writer, bytes: []const u8) Error!void {
        return w.repeat(bytes, 1);
    }
    fn repeat(w: *Writer, bytes: []const u8, count: u64) Error!void {
        if (count > std.math.maxInt(usize)) return error.NoSpace;
        const size = std.math.mul(usize, bytes.len, @intCast(count)) catch return error.NoSpace;
        const end = std.math.add(usize, w.len, size) catch return error.NoSpace;
        if (w.out) |out| {
            if (end > out.len) return error.NoSpace;
            var at = w.len;
            while (at < end) : (at += bytes.len) @memcpy(out[at..][0..bytes.len], bytes);
        }
        w.len = end;
    }
};
fn textValid(s: []const u8) bool {
    return std.unicode.utf8ValidateSlice(s);
}
fn magnitude(value: i64) u64 {
    return if (value < 0) @as(u64, @intCast(-(value + 1))) + 1 else @intCast(value);
}
fn validate(style: Style) Error!void {
    for ([_][]const u8{ style.prefix, style.suffix, style.negative_prefix, style.negative_suffix, style.pad_symbol }) |s| if (!textValid(s)) return error.InvalidStyle;
    if (style.minimum_symbols > 0 and style.pad_symbol.len == 0) return error.InvalidStyle;
    if (style.range) |r| if (r[0] > r[1]) return error.InvalidStyle;
    switch (style.system) {
        .additive => |rows| {
            if (rows.len == 0) return error.InvalidStyle;
            for (rows, 0..) |row, i| if (row.symbol.len == 0 or !textValid(row.symbol) or (i > 0 and row.weight >= rows[i - 1].weight)) return error.InvalidStyle;
        },
        inline else => |symbols, tag| {
            if (symbols.len == 0 or (tag == .numeric and symbols.len < 2)) return error.InvalidStyle;
            for (symbols) |s| if (s.len == 0 or !textValid(s)) return error.InvalidStyle;
        },
    }
}

fn core(number: u64, system: System, writer: *Writer) Error!u64 {
    switch (system) {
        .numeric, .alphabetic => |symbols| {
            const alphabetic = system == .alphabetic;
            if (alphabetic and number == 0) return error.OutOfRange;
            if (symbols.len == 1) {
                try writer.repeat(symbols[0], number);
                return number;
            }
            var digits: [64]usize = undefined;
            var count: usize = 0;
            var value = number;
            while (true) {
                if (alphabetic) value -= 1;
                digits[count] = @intCast(value % symbols.len);
                count += 1;
                value /= symbols.len;
                if (value == 0) break;
            }
            var i = count;
            while (i > 0) {
                i -= 1;
                try writer.append(symbols[digits[i]]);
            }
            return count;
        },
        .symbolic => |symbols| {
            if (number == 0) return error.OutOfRange;
            const index = (number - 1) % symbols.len;
            const count = (number - 1) / symbols.len + 1;
            try writer.repeat(symbols[@intCast(index)], count);
            return count;
        },
        .cyclic => |symbols| {
            const index = if (number == 0) symbols.len - 1 else (number - 1) % symbols.len;
            try writer.append(symbols[@intCast(index)]);
            return 1;
        },
        .additive => |rows| {
            var value = number;
            var count: u64 = 0;
            for (rows) |row| {
                if (row.weight == 0) {
                    if (number == 0) {
                        try writer.append(row.symbol);
                        return 1;
                    }
                    break;
                }
                const copies = value / row.weight;
                try writer.repeat(row.symbol, copies);
                count = std.math.add(u64, count, copies) catch return error.NoSpace;
                value %= row.weight;
            }
            if (value != 0 or count == 0) return error.OutOfRange;
            return count;
        },
    }
}

fn selectedSystem(value: i64, style: Style) Error!System {
    var system = style.system;
    var fallback = false;
    if (style.range) |r| fallback = value < r[0] or value > r[1];
    var measure: Writer = .{};
    if (!fallback) _ = core(magnitude(value), system, &measure) catch |err| switch (err) {
        error.OutOfRange => blk: {
            fallback = true;
            break :blk 0;
        },
        else => return err,
    };
    if (fallback) {
        if (!style.decimal_fallback) return error.OutOfRange;
        system = .{ .numeric = &decimal_digits };
    }
    return system;
}
fn formatted(value: i64, style: Style, writer: *Writer) Error!void {
    const system = try selectedSystem(value, style);
    var measure: Writer = .{};
    const count = try core(magnitude(value), system, &measure);
    try writer.append(style.prefix);
    if (value < 0) try writer.append(style.negative_prefix);
    if (count < style.minimum_symbols) try writer.repeat(style.pad_symbol, style.minimum_symbols - count);
    _ = try core(magnitude(value), system, writer);
    if (value < 0) try writer.append(style.negative_suffix);
    try writer.append(style.suffix);
}

/// Returns required bytes without writing. All scalar values, including i64 minimum, have
/// bounded arithmetic; unrepresentable styles report an error or their declared fallback.
pub fn required(value: i64, style: Style) Error!usize {
    try validate(style);
    var writer: Writer = .{};
    try formatted(value, style, &writer);
    return writer.len;
}
pub fn format(value: i64, style: Style, out: []u8) Error![]const u8 {
    const size = try required(value, style);
    if (out.len < size) return error.NoSpace;
    var writer: Writer = .{ .out = out };
    try formatted(value, style, &writer);
    return out[0..writer.len];
}

pub const Counter = struct { id: Id, value: i64, depth: u32 };
pub const Stack = struct {
    rows: []Counter,
    len: u32 = 0,
    depth: u32 = 0,

    pub fn enter(stack: *Stack) Error!void {
        stack.depth = std.math.add(u32, stack.depth, 1) catch return error.Overflow;
    }
    pub fn leave(stack: *Stack) Error!void {
        if (stack.depth == 0) return error.NoScope;
        while (stack.len > 0 and stack.rows[stack.len - 1].depth == stack.depth) stack.len -= 1;
        stack.depth -= 1;
    }
    fn find(stack: Stack, id: Id) ?usize {
        var i = stack.len;
        while (i > 0) {
            i -= 1;
            if (stack.rows[i].id == id) return i;
        }
        return null;
    }
    pub fn get(stack: Stack, id: Id) ?i64 {
        return if (stack.find(id)) |i| stack.rows[i].value else null;
    }
    pub fn reset(stack: *Stack, id: Id, value: i64) Error!void {
        if (stack.find(id)) |i| if (stack.rows[i].depth == stack.depth) {
            stack.rows[i].value = value;
            return;
        };
        if (stack.len == stack.rows.len) return error.NoSpace;
        stack.rows[stack.len] = .{ .id = id, .value = value, .depth = stack.depth };
        stack.len += 1;
    }
    pub fn set(stack: *Stack, id: Id, value: i64) Error!void {
        if (stack.find(id)) |i| stack.rows[i].value = value else try stack.reset(id, value);
    }
    pub fn increment(stack: *Stack, id: Id, amount: i64) Error!i64 {
        const value = std.math.add(i64, stack.get(id) orelse 0, amount) catch return error.Overflow;
        try stack.set(id, value);
        return value;
    }
    /// Nested numbering (e.g. 2.3.1). This style's prefix/suffix wrap the complete chain;
    /// each counter retains its own negative affix and symbol padding.
    pub fn formatChain(stack: Stack, id: Id, style: Style, separator: []const u8, out: []u8) Error![]const u8 {
        try validate(style);
        if (!textValid(separator)) return error.InvalidStyle;
        var inner = style;
        inner.prefix = "";
        inner.suffix = "";
        var measure: Writer = .{};
        try stack.chain(id, inner, separator, &measure);
        const total = std.math.add(usize, measure.len, style.prefix.len) catch return error.NoSpace;
        const size = std.math.add(usize, total, style.suffix.len) catch return error.NoSpace;
        if (size > out.len) return error.NoSpace;
        var writer: Writer = .{ .out = out };
        try writer.append(style.prefix);
        try stack.chain(id, inner, separator, &writer);
        try writer.append(style.suffix);
        return out[0..writer.len];
    }
    fn chain(stack: Stack, id: Id, style: Style, separator: []const u8, writer: *Writer) Error!void {
        var seen = false;
        for (stack.rows[0..stack.len]) |row| if (row.id == id) {
            if (seen) try writer.append(separator);
            try formatted(row.value, style, writer);
            seen = true;
        };
        if (!seen) return error.OutOfRange;
    }
};

pub const Placement = struct { box: Box, marker: [2]f32, content: [2]f32 };
pub const MarkerOptions = struct { inside: bool = false, side: enum { start, end } = .start, rtl: bool = false, gap: f32 = 4 };

/// Baseline-aligned marker. Outside markers reserve no inline width; caller clipping decides
/// whether their protrusion is visible. Inside markers shift the content and enlarge its box.
pub fn place(marker: Box, content: Box, options: MarkerOptions) Error!Placement {
    for ([_]f32{ marker.width, marker.height, marker.baseline, content.width, content.height, content.baseline, options.gap }) |v| if (!std.math.isFinite(v) or v < 0) return error.InvalidStyle;
    if (marker.baseline > marker.height or content.baseline > content.height) return error.InvalidStyle;
    const left = (options.side == .start) != options.rtl;
    const ascent = @max(marker.baseline, content.baseline);
    const descent = @max(marker.height - marker.baseline, content.height - content.baseline);
    const advance = if (options.inside) marker.width + options.gap else 0;
    const mx = if (left) (if (options.inside) @as(f32, 0) else -marker.width - options.gap) else (if (options.inside) content.width + options.gap else content.width + options.gap);
    return .{ .box = .{ .width = content.width + advance, .height = ascent + descent, .baseline = ascent }, .marker = .{ mx, ascent - marker.baseline }, .content = .{ if (left) advance else 0, ascent - content.baseline } };
}
pub fn markerRun(run: draw.TextRun, placement: Placement, box: Box) draw.TextRun {
    var result = run;
    result.rect = .{ run.rect[0] + placement.marker[0], run.rect[1] + placement.marker[1], run.rect[0] + placement.marker[0] + box.width, run.rect[1] + placement.marker[1] + box.height };
    return result;
}
pub const Bullet = enum { disc, circle, square };
pub fn bullet(run: draw.TextRun, kind: Bullet, position: [2]f32, size: f32, ring_width: f32) Error!draw.Quad {
    if (!std.math.isFinite(size) or size <= 0 or !std.math.isFinite(ring_width) or ring_width < 0 or !std.math.isFinite(position[0]) or !std.math.isFinite(position[1])) return error.InvalidStyle;
    const x = run.rect[0] + position[0];
    const y = run.rect[1] + position[1];
    return .{ .rect = .{ x, y, x + size, y + size }, .clip = run.clip, .params = @splat(0), .uv = .{ 0, 0, 1, 1 }, .radii = @splat(if (kind == .square) @as(f32, 0) else size * 0.5), .fill = if (kind == .circle) 0 else run.color, .border_color = run.color, .border = if (kind == .circle) @min(ring_width, size * 0.5) else 0, .opacity = 1, .xform = run.xform, .clip_radii = run.clip_radii };
}

test "counter systems format UTF8 exact integers and reject invalid and insufficient storage" {
    var out: [128]u8 = undefined;
    try std.testing.expectEqualStrings("-9223372036854775808. ", try format(std.math.minInt(i64), decimal, &out));
    try std.testing.expectEqualStrings("09. ", try format(9, decimal_leading_zero, &out));
    try std.testing.expectEqualStrings("AA. ", try format(27, upper_alpha, &out));
    try std.testing.expectEqualStrings("MCMXCIX. ", try format(1999, upper_roman, &out));
    try std.testing.expectEqualStrings("4000. ", try format(4000, upper_roman, &out));
    const arabic: Style = .{ .system = .{ .numeric = &.{ "٠", "١", "٢", "٣", "٤", "٥", "٦", "٧", "٨", "٩" } }, .suffix = " " };
    try std.testing.expectEqualStrings("١٢٣ ", try format(123, arabic, &out));
    try std.testing.expectEqualStrings("††. ", try format(4, .{ .system = .{ .symbolic = &.{ "*", "†" } } }, &out));
    try std.testing.expectError(error.NoSpace, format(100, .{ .system = .{ .symbolic = &.{"*"} } }, out[0..10]));
    try std.testing.expectError(error.InvalidStyle, format(2, .{ .system = .{ .numeric = &.{"0"} } }, &out));
    try std.testing.expectError(error.OutOfRange, format(0, .{ .system = .{ .alphabetic = &lower_letters }, .decimal_fallback = false }, &out));
}

test "nested scoped counters reset increment and format without mutating ancestors" {
    var rows: [4]Counter = undefined;
    var stack: Stack = .{ .rows = &rows };
    const list = Id.from("list");
    try stack.reset(list, 2);
    try stack.enter();
    try stack.reset(list, 0);
    try std.testing.expectEqual(@as(i64, 1), try stack.increment(list, 1));
    try stack.enter();
    try stack.reset(list, 4);
    var out: [32]u8 = undefined;
    try std.testing.expectEqualStrings("2.1.4. ", try stack.formatChain(list, decimal, ".", &out));
    try stack.leave();
    try std.testing.expectEqual(@as(?i64, 1), stack.get(list));
    try stack.leave();
    try std.testing.expectEqual(@as(?i64, 2), stack.get(list));
    try stack.set(list, std.math.maxInt(i64));
    try std.testing.expectError(error.Overflow, stack.increment(list, 1));
    try std.testing.expectError(error.NoScope, stack.leave());
}

test "formatted list marker becomes baseline aligned paragraph glyphs and ordinary bullet quads" {
    const lines = @import("lines.zig");
    const emit = @import("emit.zig");
    var bytes: [16]u8 = undefined;
    const text = try format(3, .{ .suffix = ")" }, &bytes);
    var paragraph: @import("golden.zig").Para = .{};
    paragraph.fixed(text, 8);
    try lines.breakLines(&paragraph.g, text, 100, &paragraph.l);
    lines.place(&paragraph.l, &paragraph.g, text, &.{.{ .ascent = 9, .descent = 3 }}, .{});
    const marker: Box = .{ .width = 16, .height = 12, .baseline = 9 };
    const placement = try place(marker, .{ .width = 80, .height = 20, .baseline = 14 }, .{});
    try std.testing.expectEqual([2]f32{ -20, 5 }, placement.marker);
    const run: draw.TextRun = .{ .rect = .{ 40, 10, 120, 30 }, .clip = .{ 0, 0, 200, 200 }, .start = 0, .bytes = @intCast(text.len), .px = 12, .font = 0, .color = 0xffffffff, .xform = .{ 2, 0, 0, 2, 0, 0 } };
    var quads: [2]draw.Quad = undefined;
    _ = try emit.quads(markerRun(run, placement, marker), &paragraph.g, &paragraph.l, text, .{ .glyphs = &.{ .{ .bounds = .{ 0, -9, 7, 3 } }, .{ .bounds = .{ 0, -9, 7, 3 } } } }, &quads);
    try std.testing.expectEqual(@as(f32, 20), quads[0].rect[0]);
    try std.testing.expectEqual(run.xform, quads[0].xform);
    const ring = try bullet(run, .circle, placement.marker, 8, 1);
    try std.testing.expectEqual(@as(f32, 1), ring.border);
    const rtl = try place(marker, .{ .width = 80, .height = 20, .baseline = 14 }, .{ .rtl = true, .inside = true });
    try std.testing.expectEqual(@as(f32, 100), rtl.box.width);
    try std.testing.expectEqual(@as(f32, 84), rtl.marker[0]);
}
