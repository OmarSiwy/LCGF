//! Bounded static SVG import and painting over Path, brushes and caller-owned surfaces.
//! Supported: svg/g, all path commands, rect/circle/ellipse/line/polyline/polygon, affine
//! transforms, viewBox/alignment, inherited presentation and inline style, fill/stroke/dashes,
//! non-scaling strokes, local linear/radial gradient references and templates, group opacity.
//! No CSS selector engine, text layout, script, external resources, use/pattern/filter/mask or
//! clipPath interpreter is implied: unsupported visual elements/properties return an error.
//! The caller may instead parse pathData/transformList and use the native paint primitives.
//! Painting streams shapes; a later malformed element/capacity failure leaves earlier shapes
//! painted. Clear/replay, or render to a caller-owned staging surface for atomic publication.

const std = @import("std");
const simd = @import("../core/simd.zig");
const types = @import("../core/types.zig");
const paths = @import("paths.zig");
const vector = @import("vector.zig");
const brushes = @import("brushes.zig");
const color = @import("color_math.zig");
const surface = @import("surface.zig");
const decoration = @import("decoration.zig");
const compositor = @import("compositor.zig");
const geometry = @import("geometry.zig");
const Rect = types.Rect;
const identity = geometry.identity;

pub const Error = vector.Error || compositor.Error || error{ InvalidXml, InvalidNumber, InvalidColorSyntax, UnsupportedElement, UnsupportedAttribute, UnsupportedCss, UnsupportedPaint, UnknownReference, CyclicReference, UnbalancedTags };
pub const Length = struct {
    value: f32,
    percent: bool = false,
    fn resolve(v: Length, basis: f32) f32 {
        return if (v.percent) v.value * basis else v.value;
    }
};
pub const Paint = union(enum) { none, solid: color.Rgba, current_color, gradient: []const u8 };
pub const Style = struct {
    palette: []const color.Rgba = &.{},
    color: color.Rgba = .{ 0, 0, 0, 1 },
    fill: Paint = .{ .solid = .{ 0, 0, 0, 1 } },
    stroke: Paint = .none,
    fill_opacity: f32 = 1,
    stroke_opacity: f32 = 1,
    stroke_width: Length = .{ .value = 1 },
    cap: paths.Cap = .butt,
    join: paths.Join = .miter,
    miter_limit: f32 = 4,
    dash_array: []const u8 = "",
    dash_offset: Length = .{ .value = 0 },
    rule: paths.Rule = .nonzero,
    non_scaling: bool = false,
    visible: bool = true,
    stroke_first: bool = false,
    interpolation: color.Space = .srgb,
    stop_color: Paint = .{ .solid = .{ 0, 0, 0, 1 } },
    stop_opacity: f32 = 1,
};
pub const Gradient = struct {
    id: []const u8 = "",
    href: ?[]const u8 = null,
    radial: bool = false,
    /// x1/y1/x2/y2 or cx/cy/r/fx/fy/fr. Missing focal centers follow cx/cy.
    coordinates: [6]Length = undefined,
    specified: u16 = 0,
    object_box: bool = true,
    matrix: [6]f32 = identity,
    spread: brushes.Spread = .pad,
    interpolation: color.Interpolation = .{ .premultiplied = false },
    stops: []const brushes.Stop = &.{},
    resolved: bool = false,
    stop_start: usize = 0,
};
pub const Frame = struct {
    name: []const u8,
    style: Style,
    matrix: [6]f32,
    displayed: bool,
    selected: bool,
    shape: bool,
    opacity: f32,
    layer: ?usize,
    gradient: ?usize = null,
};
pub const Buffers = struct {
    path: *paths.Path,
    centerline: *paths.Polyline,
    work: *paths.Polyline,
    outline: *paths.Polyline,
    fill: paths.Scratch,
    accumulator: []f32,
    coverage: []u8,
    gradients: []Gradient,
    stops: []brushes.Stop,
    segments: []brushes.Segment,
    stack: []Frame,
    /// Each active opacity group needs a distinct, target-sized surface. Reused after close.
    layers: []surface.Surface = &.{},
    dashes: []f32,
    /// At least options.view.clips.len + 1 rows: the extra row clips the outer viewport.
    clips: []decoration.Clip,
};
pub const Options = struct {
    /// Explicit host-selected logical viewport. Source width/height are intrinsic metadata.
    viewport: Rect,
    view: decoration.View = .{},
    /// Maximum curve flattening error in output pixels.
    tolerance: f32 = 0.2,
    current_color: color.Rgba = .{ 0, 0, 0, 1 },
    /// Render a particular element and descendants, retaining ancestor transforms/styles.
    /// Useful for OpenType SVG glyph documents containing several glyph groups.
    fragment: ?[]const u8 = null,
    /// OpenType SVG uses an unclipped em-square viewport and an explicit baseline transform.
    clip_viewport: bool = true,
    initial_transform: [6]f32 = identity,
    /// False renders the selected element under the root viewport as a virtual <use>.
    fragment_ancestors: bool = true,
    /// Use source width/height as user-space size when no viewBox is supplied.
    use_intrinsic_size: bool = false,
    /// Optional OpenType CPAL --colorN variables. Missing variables use var() fallbacks.
    palette: []const color.Rgba = &.{},
};
pub const ResolvedPaint = struct { brush: brushes.Brush, inverse: [6]f32 = identity };

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn trim(a: []const u8) []const u8 {
    return std.mem.trim(u8, a, " \t\r\n");
}
fn space(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}
fn nameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == ':' or c == '.';
}
fn pathRoom(p: *const paths.Path, verbs: usize, points: usize) Error!void {
    if (p.verbs > p.verb.len or p.points > p.x.len or p.points > p.y.len or verbs > p.verb.len - p.verbs or points > p.x.len - p.points or points > p.y.len - p.points) return error.InsufficientStorage;
}
const Numbers = struct {
    bytes: []const u8,
    at: usize = 0,
    fn separators(n: *Numbers) void {
        while (n.at < n.bytes.len and (space(n.bytes[n.at]) or n.bytes[n.at] == ',')) n.at += 1;
    }
    fn more(n: *Numbers) bool {
        n.separators();
        return n.at < n.bytes.len;
    }
    fn number(n: *Numbers) Error!f32 {
        n.separators();
        const start = n.at;
        if (n.at < n.bytes.len and (n.bytes[n.at] == '+' or n.bytes[n.at] == '-')) n.at += 1;
        var digits: usize = 0;
        while (n.at < n.bytes.len and std.ascii.isDigit(n.bytes[n.at])) : (n.at += 1) digits += 1;
        if (n.at < n.bytes.len and n.bytes[n.at] == '.') {
            n.at += 1;
            while (n.at < n.bytes.len and std.ascii.isDigit(n.bytes[n.at])) : (n.at += 1) digits += 1;
        }
        if (digits == 0) return error.InvalidNumber;
        if (n.at < n.bytes.len and (n.bytes[n.at] == 'e' or n.bytes[n.at] == 'E')) {
            n.at += 1;
            if (n.at < n.bytes.len and (n.bytes[n.at] == '+' or n.bytes[n.at] == '-')) n.at += 1;
            const exponent = n.at;
            while (n.at < n.bytes.len and std.ascii.isDigit(n.bytes[n.at])) n.at += 1;
            if (n.at == exponent) return error.InvalidNumber;
        }
        const value = std.fmt.parseFloat(f32, n.bytes[start..n.at]) catch return error.InvalidNumber;
        if (!std.math.isFinite(value)) return error.InvalidNumber;
        return value;
    }
    fn flag(n: *Numbers) Error!bool {
        n.separators();
        if (n.at >= n.bytes.len or (n.bytes[n.at] != '0' and n.bytes[n.at] != '1')) return error.InvalidPath;
        const value = n.bytes[n.at] == '1';
        n.at += 1;
        return value;
    }
    fn length(n: *Numbers) Error!Length {
        var result: Length = .{ .value = try n.number() };
        if (n.at < n.bytes.len and n.bytes[n.at] == '%') {
            result.percent = true;
            result.value /= 100;
            n.at += 1;
        } else if (std.mem.startsWith(u8, n.bytes[n.at..], "px")) n.at += 2;
        return result;
    }
};
pub fn parseLength(bytes: []const u8) Error!Length {
    var n: Numbers = .{ .bytes = trim(bytes) };
    const v = try n.length();
    if (n.more()) return error.InvalidNumber;
    return v;
}
fn number(bytes: []const u8) Error!f32 {
    var n: Numbers = .{ .bytes = trim(bytes) };
    const v = try n.number();
    if (n.more()) return error.InvalidNumber;
    return v;
}
fn alpha(bytes: []const u8) Error!f32 {
    const v = try parseLength(bytes);
    return std.math.clamp(v.value, 0, 1);
}

/// All SVG path-data commands, including compact arc flags, relative/repeated commands and
/// smooth-control reflection. Appends no hidden objects; clears the supplied Path first.
pub fn pathData(bytes: []const u8, p: *paths.Path) Error!void {
    p.clear();
    var n: Numbers = .{ .bytes = bytes };
    var command: u8 = 0;
    var previous: u8 = 0;
    var current: [2]f32 = .{ 0, 0 };
    var start = current;
    var control = current;
    while (n.more()) {
        if (std.ascii.isAlphabetic(n.bytes[n.at])) {
            command = n.bytes[n.at];
            n.at += 1;
        } else if (command == 0) return error.InvalidPath;
        const c = std.ascii.toUpper(command);
        const relative = std.ascii.isLower(command);
        const base: [2]f32 = if (relative) current else .{ 0, 0 };
        if (p.verbs == 0 and c != 'M') return error.InvalidPath;
        if (c == 'Z') {
            try pathRoom(p, 1, 0);
            p.close();
            current = start;
            previous = c;
            command = 0;
            continue;
        }
        var end = current;
        switch (c) {
            'M', 'L', 'T' => {
                end = .{ base[0] + try n.number(), base[1] + try n.number() };
                if (c == 'T') {
                    const reflected: [2]f32 = if (previous == 'Q' or previous == 'T') .{ 2 * current[0] - control[0], 2 * current[1] - control[1] } else current;
                    try pathRoom(p, 1, 2);
                    p.quadTo(reflected[0], reflected[1], end[0], end[1]);
                    control = reflected;
                } else {
                    try pathRoom(p, 1, 1);
                    if (c == 'M') {
                        p.moveTo(end[0], end[1]);
                        start = end;
                        command = if (relative) 'l' else 'L';
                    } else p.lineTo(end[0], end[1]);
                }
            },
            'H' => {
                end[0] = base[0] + try n.number();
                try pathRoom(p, 1, 1);
                p.lineTo(end[0], end[1]);
            },
            'V' => {
                end[1] = base[1] + try n.number();
                try pathRoom(p, 1, 1);
                p.lineTo(end[0], end[1]);
            },
            'Q' => {
                control = .{ base[0] + try n.number(), base[1] + try n.number() };
                end = .{ base[0] + try n.number(), base[1] + try n.number() };
                try pathRoom(p, 1, 2);
                p.quadTo(control[0], control[1], end[0], end[1]);
            },
            'C', 'S' => {
                const first: [2]f32 = if (c == 'C') .{ base[0] + try n.number(), base[1] + try n.number() } else if (previous == 'C' or previous == 'S') .{ 2 * current[0] - control[0], 2 * current[1] - control[1] } else current;
                control = .{ base[0] + try n.number(), base[1] + try n.number() };
                end = .{ base[0] + try n.number(), base[1] + try n.number() };
                try pathRoom(p, 1, 3);
                p.cubicTo(first[0], first[1], control[0], control[1], end[0], end[1]);
            },
            'A' => {
                const radius: [2]f32 = .{ try n.number(), try n.number() };
                const rotation = try n.number();
                const large = try n.flag();
                const sweep = try n.flag();
                end = .{ base[0] + try n.number(), base[1] + try n.number() };
                try vector.arcTo(p, current, end, .{ .radius = radius, .rotation_degrees = rotation, .large = large, .sweep = sweep });
            },
            else => return error.InvalidPath,
        }
        if (!std.math.isFinite(end[0]) or !std.math.isFinite(end[1])) return error.InvalidGeometry;
        current = end;
        previous = c;
    }
}

pub fn transformList(bytes: []const u8) Error![6]f32 {
    var n: Numbers = .{ .bytes = bytes };
    var result = identity;
    while (n.more()) {
        const start = n.at;
        while (n.at < n.bytes.len and std.ascii.isAlphabetic(n.bytes[n.at])) n.at += 1;
        const name = n.bytes[start..n.at];
        while (n.at < n.bytes.len and space(n.bytes[n.at])) n.at += 1;
        if (n.at == n.bytes.len or n.bytes[n.at] != '(') return error.InvalidTransform;
        n.at += 1;
        var values: [6]f32 = undefined;
        var count: usize = 0;
        while (n.more() and n.bytes[n.at] != ')') {
            if (count == values.len) return error.InvalidTransform;
            values[count] = try n.number();
            count += 1;
        }
        if (n.at == n.bytes.len or n.bytes[n.at] != ')') return error.InvalidTransform;
        n.at += 1;
        var matrix = identity;
        if (eql(name, "matrix")) {
            if (count != 6) return error.InvalidTransform;
            matrix = values;
        } else if (eql(name, "translate")) {
            if (count < 1 or count > 2) return error.InvalidTransform;
            matrix[4] = values[0];
            matrix[5] = if (count == 2) values[1] else 0;
        } else if (eql(name, "scale")) {
            if (count < 1 or count > 2) return error.InvalidTransform;
            matrix[0] = values[0];
            matrix[3] = if (count == 2) values[1] else values[0];
        } else if (eql(name, "rotate")) {
            if (count != 1 and count != 3) return error.InvalidTransform;
            const angle = values[0] * std.math.pi / 180;
            const c = @cos(angle);
            const s = @sin(angle);
            matrix = .{ c, s, -s, c, 0, 0 };
            if (count == 3) {
                matrix[4] = values[1] - c * values[1] + s * values[2];
                matrix[5] = values[2] - s * values[1] - c * values[2];
            }
        } else if (eql(name, "skewX") or eql(name, "skewY")) {
            if (count != 1) return error.InvalidTransform;
            matrix[if (eql(name, "skewX")) @as(usize, 2) else 1] = @tan(values[0] * std.math.pi / 180);
        } else return error.InvalidTransform;
        result = geometry.compose(result, matrix);
        for (result) |value| if (!std.math.isFinite(value)) return error.InvalidTransform;
    }
    return result;
}

fn hex(c: u8) Error!u8 {
    return std.fmt.charToDigit(c, 16) catch return error.InvalidColorSyntax;
}
/// Hex, numeric/percentage rgb[a], hsl[a], transparent and all CSS named colors.
/// Other authored color spaces can be supplied natively through color_math and brushes.
pub fn parseColor(bytes: []const u8) Error!color.Rgba {
    const b = trim(bytes);
    if (b.len == 0) return error.InvalidColorSyntax;
    if (b[0] == '#') {
        var rgba: [4]u8 = .{ 0, 0, 0, 255 };
        if (b.len == 4 or b.len == 5) {
            for (0..b.len - 1) |i| rgba[i] = (try hex(b[i + 1])) * 17;
        } else if (b.len == 7 or b.len == 9) {
            for (0..(b.len - 1) / 2) |i| rgba[i] = (try hex(b[2 * i + 1])) * 16 + try hex(b[2 * i + 2]);
        } else return error.InvalidColorSyntax;
        return .{ @as(f32, @floatFromInt(rgba[0])) / 255, @as(f32, @floatFromInt(rgba[1])) / 255, @as(f32, @floatFromInt(rgba[2])) / 255, @as(f32, @floatFromInt(rgba[3])) / 255 };
    }
    if (std.mem.indexOfScalar(u8, b, '(')) |open| {
        if (b[b.len - 1] != ')') return error.InvalidColorSyntax;
        const kind = b[0..open];
        const rgb = eql(kind, "rgb") or eql(kind, "rgba");
        const hsl = eql(kind, "hsl") or eql(kind, "hsla");
        if (!rgb and !hsl) return error.InvalidColorSyntax;
        var n: Numbers = .{ .bytes = b[open + 1 .. b.len - 1] };
        var channels: [4]f32 = .{ 0, 0, 0, 1 };
        for (0..3) |i| {
            const value = try n.length();
            if (hsl and i != 0 and !value.percent) return error.InvalidColorSyntax;
            channels[i] = if (rgb and !value.percent) value.value / 255 else value.value;
        }
        if (n.more()) {
            if (n.bytes[n.at] == '/') n.at += 1;
            channels[3] = (try n.length()).value;
            if (n.more()) return error.InvalidColorSyntax;
        }
        channels[3] = std.math.clamp(channels[3], 0, 1);
        if (hsl) return color.hsl(channels[0], std.math.clamp(channels[1], 0, 1), std.math.clamp(channels[2], 0, 1), channels[3]);
        return .{ std.math.clamp(channels[0], 0, 1), std.math.clamp(channels[1], 0, 1), std.math.clamp(channels[2], 0, 1), channels[3] };
    }
    if (std.ascii.eqlIgnoreCase(b, "transparent")) return .{ 0, 0, 0, 0 };
    var lower: [32]u8 = undefined;
    if (b.len > lower.len) return error.InvalidColorSyntax;
    for (b, 0..) |c, i| lower[i] = std.ascii.toLower(c);
    if (named_colors.get(lower[0..b.len])) |value| return .{ @as(f32, @floatFromInt(value >> 16)) / 255, @as(f32, @floatFromInt((value >> 8) & 255)) / 255, @as(f32, @floatFromInt(value & 255)) / 255, 1 };
    return error.InvalidColorSyntax;
}

// Standard named-color values: https://www.w3.org/TR/css-color-4/#named-colors
const named_colors = std.StaticStringMap(u32).initComptime(.{
    .{ "aliceblue", 0xf0f8ff },
    .{ "antiquewhite", 0xfaebd7 },
    .{ "aqua", 0x00ffff },
    .{ "aquamarine", 0x7fffd4 },
    .{ "azure", 0xf0ffff },
    .{ "beige", 0xf5f5dc },
    .{ "bisque", 0xffe4c4 },
    .{ "black", 0x000000 },
    .{ "blanchedalmond", 0xffebcd },
    .{ "blue", 0x0000ff },
    .{ "blueviolet", 0x8a2be2 },
    .{ "brown", 0xa52a2a },
    .{ "burlywood", 0xdeb887 },
    .{ "cadetblue", 0x5f9ea0 },
    .{ "chartreuse", 0x7fff00 },
    .{ "chocolate", 0xd2691e },
    .{ "coral", 0xff7f50 },
    .{ "cornflowerblue", 0x6495ed },
    .{ "cornsilk", 0xfff8dc },
    .{ "crimson", 0xdc143c },
    .{ "cyan", 0x00ffff },
    .{ "darkblue", 0x00008b },
    .{ "darkcyan", 0x008b8b },
    .{ "darkgoldenrod", 0xb8860b },
    .{ "darkgray", 0xa9a9a9 },
    .{ "darkgreen", 0x006400 },
    .{ "darkgrey", 0xa9a9a9 },
    .{ "darkkhaki", 0xbdb76b },
    .{ "darkmagenta", 0x8b008b },
    .{ "darkolivegreen", 0x556b2f },
    .{ "darkorange", 0xff8c00 },
    .{ "darkorchid", 0x9932cc },
    .{ "darkred", 0x8b0000 },
    .{ "darksalmon", 0xe9967a },
    .{ "darkseagreen", 0x8fbc8f },
    .{ "darkslateblue", 0x483d8b },
    .{ "darkslategray", 0x2f4f4f },
    .{ "darkslategrey", 0x2f4f4f },
    .{ "darkturquoise", 0x00ced1 },
    .{ "darkviolet", 0x9400d3 },
    .{ "deeppink", 0xff1493 },
    .{ "deepskyblue", 0x00bfff },
    .{ "dimgray", 0x696969 },
    .{ "dimgrey", 0x696969 },
    .{ "dodgerblue", 0x1e90ff },
    .{ "firebrick", 0xb22222 },
    .{ "floralwhite", 0xfffaf0 },
    .{ "forestgreen", 0x228b22 },
    .{ "fuchsia", 0xff00ff },
    .{ "gainsboro", 0xdcdcdc },
    .{ "ghostwhite", 0xf8f8ff },
    .{ "gold", 0xffd700 },
    .{ "goldenrod", 0xdaa520 },
    .{ "gray", 0x808080 },
    .{ "green", 0x008000 },
    .{ "greenyellow", 0xadff2f },
    .{ "grey", 0x808080 },
    .{ "honeydew", 0xf0fff0 },
    .{ "hotpink", 0xff69b4 },
    .{ "indianred", 0xcd5c5c },
    .{ "indigo", 0x4b0082 },
    .{ "ivory", 0xfffff0 },
    .{ "khaki", 0xf0e68c },
    .{ "lavender", 0xe6e6fa },
    .{ "lavenderblush", 0xfff0f5 },
    .{ "lawngreen", 0x7cfc00 },
    .{ "lemonchiffon", 0xfffacd },
    .{ "lightblue", 0xadd8e6 },
    .{ "lightcoral", 0xf08080 },
    .{ "lightcyan", 0xe0ffff },
    .{ "lightgoldenrodyellow", 0xfafad2 },
    .{ "lightgray", 0xd3d3d3 },
    .{ "lightgreen", 0x90ee90 },
    .{ "lightgrey", 0xd3d3d3 },
    .{ "lightpink", 0xffb6c1 },
    .{ "lightsalmon", 0xffa07a },
    .{ "lightseagreen", 0x20b2aa },
    .{ "lightskyblue", 0x87cefa },
    .{ "lightslategray", 0x778899 },
    .{ "lightslategrey", 0x778899 },
    .{ "lightsteelblue", 0xb0c4de },
    .{ "lightyellow", 0xffffe0 },
    .{ "lime", 0x00ff00 },
    .{ "limegreen", 0x32cd32 },
    .{ "linen", 0xfaf0e6 },
    .{ "magenta", 0xff00ff },
    .{ "maroon", 0x800000 },
    .{ "mediumaquamarine", 0x66cdaa },
    .{ "mediumblue", 0x0000cd },
    .{ "mediumorchid", 0xba55d3 },
    .{ "mediumpurple", 0x9370db },
    .{ "mediumseagreen", 0x3cb371 },
    .{ "mediumslateblue", 0x7b68ee },
    .{ "mediumspringgreen", 0x00fa9a },
    .{ "mediumturquoise", 0x48d1cc },
    .{ "mediumvioletred", 0xc71585 },
    .{ "midnightblue", 0x191970 },
    .{ "mintcream", 0xf5fffa },
    .{ "mistyrose", 0xffe4e1 },
    .{ "moccasin", 0xffe4b5 },
    .{ "navajowhite", 0xffdead },
    .{ "navy", 0x000080 },
    .{ "oldlace", 0xfdf5e6 },
    .{ "olive", 0x808000 },
    .{ "olivedrab", 0x6b8e23 },
    .{ "orange", 0xffa500 },
    .{ "orangered", 0xff4500 },
    .{ "orchid", 0xda70d6 },
    .{ "palegoldenrod", 0xeee8aa },
    .{ "palegreen", 0x98fb98 },
    .{ "paleturquoise", 0xafeeee },
    .{ "palevioletred", 0xdb7093 },
    .{ "papayawhip", 0xffefd5 },
    .{ "peachpuff", 0xffdab9 },
    .{ "peru", 0xcd853f },
    .{ "pink", 0xffc0cb },
    .{ "plum", 0xdda0dd },
    .{ "powderblue", 0xb0e0e6 },
    .{ "purple", 0x800080 },
    .{ "rebeccapurple", 0x663399 },
    .{ "red", 0xff0000 },
    .{ "rosybrown", 0xbc8f8f },
    .{ "royalblue", 0x4169e1 },
    .{ "saddlebrown", 0x8b4513 },
    .{ "salmon", 0xfa8072 },
    .{ "sandybrown", 0xf4a460 },
    .{ "seagreen", 0x2e8b57 },
    .{ "seashell", 0xfff5ee },
    .{ "sienna", 0xa0522d },
    .{ "silver", 0xc0c0c0 },
    .{ "skyblue", 0x87ceeb },
    .{ "slateblue", 0x6a5acd },
    .{ "slategray", 0x708090 },
    .{ "slategrey", 0x708090 },
    .{ "snow", 0xfffafa },
    .{ "springgreen", 0x00ff7f },
    .{ "steelblue", 0x4682b4 },
    .{ "tan", 0xd2b48c },
    .{ "teal", 0x008080 },
    .{ "thistle", 0xd8bfd8 },
    .{ "tomato", 0xff6347 },
    .{ "turquoise", 0x40e0d0 },
    .{ "violet", 0xee82ee },
    .{ "wheat", 0xf5deb3 },
    .{ "white", 0xffffff },
    .{ "whitesmoke", 0xf5f5f5 },
    .{ "yellow", 0xffff00 },
    .{ "yellowgreen", 0x9acd32 },
});
fn parsePaint(bytes: []const u8, palette: []const color.Rgba) Error!Paint {
    var b = trim(bytes);
    var nesting: usize = 0;
    while (std.mem.startsWith(u8, b, "var(")) {
        if (b[b.len - 1] != ')' or nesting == 32) return error.UnsupportedPaint;
        nesting += 1;
        const body = b[4 .. b.len - 1];
        const comma = std.mem.indexOfScalar(u8, body, ',');
        const name = trim(body[0 .. comma orelse body.len]);
        if (std.mem.startsWith(u8, name, "--color")) {
            const digits = name[7..];
            if (digits.len != 0 and !(digits.len > 1 and digits[0] == '0')) {
                const index = std.fmt.parseInt(usize, digits, 10) catch palette.len;
                if (index < palette.len) return .{ .solid = palette[index] };
            }
        }
        b = trim(body[(comma orelse return error.UnsupportedPaint) + 1 ..]);
    }
    if (eql(b, "none")) return .none;
    if (eql(b, "currentColor")) return .current_color;
    if (std.mem.startsWith(u8, b, "url(")) {
        if (b[b.len - 1] != ')') return error.UnsupportedPaint;
        var id = trim(b[4 .. b.len - 1]);
        if (id.len >= 2 and (id[0] == '\'' or id[0] == '"') and id[id.len - 1] == id[0]) id = id[1 .. id.len - 1];
        if (id.len < 2 or id[0] != '#') return error.UnsupportedPaint;
        return .{ .gradient = id[1..] };
    }
    return .{ .solid = try parseColor(b) };
}

const Attribute = struct { name: []const u8, value: []const u8 };
const Attributes = struct {
    bytes: []const u8,
    at: usize = 0,
    fn next(a: *Attributes) Error!?Attribute {
        while (a.at < a.bytes.len and space(a.bytes[a.at])) a.at += 1;
        if (a.at == a.bytes.len) return null;
        const start = a.at;
        while (a.at < a.bytes.len and nameChar(a.bytes[a.at])) a.at += 1;
        if (a.at == start) return error.InvalidXml;
        const name = a.bytes[start..a.at];
        while (a.at < a.bytes.len and space(a.bytes[a.at])) a.at += 1;
        if (a.at == a.bytes.len or a.bytes[a.at] != '=') return error.InvalidXml;
        a.at += 1;
        while (a.at < a.bytes.len and space(a.bytes[a.at])) a.at += 1;
        if (a.at == a.bytes.len or (a.bytes[a.at] != '\'' and a.bytes[a.at] != '"')) return error.InvalidXml;
        const quote = a.bytes[a.at];
        a.at += 1;
        const begin = a.at;
        while (a.at < a.bytes.len and a.bytes[a.at] != quote) a.at += 1;
        if (a.at == a.bytes.len) return error.InvalidXml;
        const value = a.bytes[begin..a.at];
        a.at += 1;
        return .{ .name = name, .value = value };
    }
};
const Tag = struct {
    name: []const u8,
    attributes: []const u8,
    closing: bool,
    empty: bool,
    fn get(t: Tag, key: []const u8) Error!?[]const u8 {
        var a: Attributes = .{ .bytes = t.attributes };
        while (try a.next()) |attr| if (eql(attr.name, key)) return attr.value;
        return null;
    }
};
const Xml = struct {
    bytes: []const u8,
    at: usize = 0,
    fn next(x: *Xml) Error!?Tag {
        while (x.at < x.bytes.len) {
            while (x.at < x.bytes.len and space(x.bytes[x.at])) x.at += 1;
            if (x.at == x.bytes.len) return null;
            if (x.bytes[x.at] != '<') return error.InvalidXml;
            if (std.mem.startsWith(u8, x.bytes[x.at..], "<!--")) {
                const end = std.mem.indexOf(u8, x.bytes[x.at + 4 ..], "-->") orelse return error.InvalidXml;
                x.at += end + 7;
                continue;
            }
            if (std.mem.startsWith(u8, x.bytes[x.at..], "<?")) {
                const end = std.mem.indexOf(u8, x.bytes[x.at + 2 ..], "?>") orelse return error.InvalidXml;
                x.at += end + 4;
                continue;
            }
            x.at += 1;
            if (x.at == x.bytes.len or x.bytes[x.at] == '!') return error.UnsupportedElement;
            const closing = x.bytes[x.at] == '/';
            if (closing) x.at += 1;
            const start = x.at;
            while (x.at < x.bytes.len and nameChar(x.bytes[x.at])) x.at += 1;
            if (start == x.at) return error.InvalidXml;
            const name = x.bytes[start..x.at];
            const begin = x.at;
            var quote: u8 = 0;
            while (x.at < x.bytes.len) : (x.at += 1) {
                const c = x.bytes[x.at];
                if (quote != 0) {
                    if (c == quote) quote = 0;
                } else if (c == '\'' or c == '"') quote = c else if (c == '>') break;
            }
            if (x.at == x.bytes.len) return error.InvalidXml;
            var attributes = trim(x.bytes[begin..x.at]);
            x.at += 1;
            const empty = attributes.len != 0 and attributes[attributes.len - 1] == '/';
            if (empty) attributes = trim(attributes[0 .. attributes.len - 1]);
            if (closing and (empty or attributes.len != 0)) return error.InvalidXml;
            return .{ .name = name, .attributes = attributes, .closing = closing, .empty = empty };
        }
        return null;
    }
    fn skip(x: *Xml, open: Tag) Error!void {
        if (open.empty) return;
        // Descriptive/definition content is not parsed as visible text. Nested tags are
        // balanced; entities remain borrowed bytes and no external resolver is invoked.
        var depth: usize = 1;
        while (depth != 0) {
            while (x.at < x.bytes.len and x.bytes[x.at] != '<') x.at += 1;
            const tag = (try x.next()) orelse return error.UnbalancedTags;
            if (tag.closing) {
                depth -= 1;
                if (depth == 0 and !eql(tag.name, open.name)) return error.UnbalancedTags;
            } else if (!tag.empty) depth += 1;
        }
    }
};
fn metadata(name: []const u8) bool {
    return eql(name, "id") or eql(name, "version") or eql(name, "xmlns") or std.mem.startsWith(u8, name, "xmlns:") or eql(name, "xml:space") or eql(name, "xml:lang") or eql(name, "lang") or eql(name, "role") or eql(name, "focusable") or eql(name, "tabindex") or std.mem.startsWith(u8, name, "aria-") or std.mem.startsWith(u8, name, "data-");
}
const Declarations = struct {
    bytes: []const u8,
    at: usize = 0,
    fn next(d: *Declarations) Error!?Attribute {
        while (d.at < d.bytes.len and (space(d.bytes[d.at]) or d.bytes[d.at] == ';')) d.at += 1;
        if (d.at == d.bytes.len) return null;
        const start = d.at;
        while (d.at < d.bytes.len and d.bytes[d.at] != ':') d.at += 1;
        if (d.at == d.bytes.len) return error.UnsupportedCss;
        const name = trim(d.bytes[start..d.at]);
        d.at += 1;
        const begin = d.at;
        while (d.at < d.bytes.len and d.bytes[d.at] != ';') d.at += 1;
        const value = trim(d.bytes[begin..d.at]);
        if (name.len == 0 or value.len == 0) return error.UnsupportedCss;
        return .{ .name = name, .value = value };
    }
};
fn styleProperty(style: *Style, opacity: *f32, displayed: *bool, name: []const u8, value: []const u8) Error!bool {
    const v = trim(value);
    if (eql(v, "inherit")) {
        if (eql(name, "opacity") or eql(name, "display")) return error.UnsupportedCss;
        const known = [_][]const u8{ "color", "fill", "stroke", "fill-opacity", "stroke-opacity", "stroke-width", "stroke-linecap", "stroke-linejoin", "stroke-miterlimit", "stroke-dasharray", "stroke-dashoffset", "fill-rule", "visibility", "paint-order" };
        for (known) |k| if (eql(name, k)) return true;
        return false;
    }
    if (eql(name, "color")) {
        const parsed_color = try parsePaint(v, style.palette);
        style.color = switch (parsed_color) {
            .solid => |c| c,
            .current_color => style.color,
            else => return error.UnsupportedPaint,
        };
    } else if (eql(name, "fill")) style.fill = try parsePaint(v, style.palette) else if (eql(name, "stroke")) style.stroke = try parsePaint(v, style.palette) else if (eql(name, "stop-color")) style.stop_color = try parsePaint(v, style.palette) else if (eql(name, "stop-opacity")) style.stop_opacity = try alpha(v) else if (eql(name, "color-interpolation")) {
        style.interpolation = if (eql(v, "sRGB") or eql(v, "auto")) .srgb else if (eql(v, "linearRGB")) .linear_srgb else return error.UnsupportedCss;
    } else if (eql(name, "opacity")) opacity.* = try alpha(v) else if (eql(name, "fill-opacity")) style.fill_opacity = try alpha(v) else if (eql(name, "stroke-opacity")) style.stroke_opacity = try alpha(v) else if (eql(name, "stroke-width")) {
        style.stroke_width = try parseLength(v);
        if (style.stroke_width.value < 0) return error.InvalidStroke;
    } else if (eql(name, "stroke-miterlimit")) {
        style.miter_limit = try number(v);
        if (style.miter_limit < 1) return error.InvalidStroke;
    } else if (eql(name, "stroke-linecap")) {
        style.cap = if (eql(v, "butt")) .butt else if (eql(v, "round")) .round else if (eql(v, "square")) .square else return error.UnsupportedCss;
    } else if (eql(name, "stroke-linejoin")) {
        style.join = if (eql(v, "miter")) .miter else if (eql(v, "round")) .round else if (eql(v, "bevel")) .bevel else return error.UnsupportedCss;
    } else if (eql(name, "stroke-dasharray")) style.dash_array = if (eql(v, "none")) "" else v else if (eql(name, "stroke-dashoffset")) style.dash_offset = try parseLength(v) else if (eql(name, "fill-rule")) {
        style.rule = if (eql(v, "nonzero")) .nonzero else if (eql(v, "evenodd")) .even_odd else return error.UnsupportedCss;
    } else if (eql(name, "vector-effect")) {
        style.non_scaling = if (eql(v, "none")) false else if (eql(v, "non-scaling-stroke")) true else return error.UnsupportedCss;
    } else if (eql(name, "visibility")) {
        style.visible = if (eql(v, "visible")) true else if (eql(v, "hidden") or eql(v, "collapse")) false else return error.UnsupportedCss;
    } else if (eql(name, "display")) {
        displayed.* = if (eql(v, "none")) false else if (eql(v, "inline")) true else return error.UnsupportedCss;
    } else if (eql(name, "paint-order")) {
        style.stroke_first = if (eql(v, "normal") or eql(v, "fill stroke") or eql(v, "fill")) false else if (eql(v, "stroke") or eql(v, "stroke fill")) true else return error.UnsupportedCss;
    } else return false;
    return true;
}
fn shapeAttribute(name: []const u8, element: []const u8) bool {
    if (eql(element, "path")) return eql(name, "d");
    if (eql(element, "rect")) return eql(name, "x") or eql(name, "y") or eql(name, "width") or eql(name, "height") or eql(name, "rx") or eql(name, "ry");
    if (eql(element, "circle")) return eql(name, "cx") or eql(name, "cy") or eql(name, "r");
    if (eql(element, "ellipse")) return eql(name, "cx") or eql(name, "cy") or eql(name, "rx") or eql(name, "ry");
    if (eql(element, "line")) return eql(name, "x1") or eql(name, "y1") or eql(name, "x2") or eql(name, "y2");
    if (eql(element, "polygon") or eql(element, "polyline")) return eql(name, "points");
    if (eql(element, "svg")) return eql(name, "width") or eql(name, "height") or eql(name, "viewBox") or eql(name, "preserveAspectRatio");
    return false;
}
fn styled(tag: Tag, parent: Style, parent_matrix: [6]f32) Error!Frame {
    var result: Frame = .{ .name = tag.name, .style = parent, .matrix = parent_matrix, .displayed = true, .selected = true, .shape = !eql(tag.name, "svg") and !eql(tag.name, "g"), .opacity = 1, .layer = null };
    // vector-effect is not inherited; paint/order and the presentation fields above are.
    result.style.non_scaling = false;
    var attrs: Attributes = .{ .bytes = tag.attributes };
    var inline_style: ?[]const u8 = null;
    while (try attrs.next()) |a| {
        if (eql(a.name, "style")) inline_style = a.value else if (eql(a.name, "transform")) result.matrix = geometry.compose(parent_matrix, try transformList(a.value)) else if (try styleProperty(&result.style, &result.opacity, &result.displayed, a.name, a.value)) {} else if (!metadata(a.name) and !shapeAttribute(a.name, tag.name)) return error.UnsupportedAttribute;
    }
    if (inline_style) |css| {
        var declarations: Declarations = .{ .bytes = css };
        while (try declarations.next()) |a| if (!try styleProperty(&result.style, &result.opacity, &result.displayed, a.name, a.value)) return error.UnsupportedCss;
    }
    return result;
}

fn gradientDefaults(radial: bool) Gradient {
    return .{ .radial = radial, .coordinates = if (radial) .{ .{ .value = 0.5, .percent = true }, .{ .value = 0.5, .percent = true }, .{ .value = 0.5, .percent = true }, .{ .value = 0.5, .percent = true }, .{ .value = 0.5, .percent = true }, .{ .value = 0, .percent = true } } else .{ .{ .value = 0, .percent = true }, .{ .value = 0, .percent = true }, .{ .value = 1, .percent = true }, .{ .value = 0, .percent = true }, .{ .value = 0 }, .{ .value = 0 } } };
}
fn gradientTag(tag: Tag, parent: Style, inherited: *Style) Error!Gradient {
    var g = gradientDefaults(eql(tag.name, "radialGradient"));
    inherited.* = parent;
    var attrs: Attributes = .{ .bytes = tag.attributes };
    var inline_style: ?[]const u8 = null;
    var opacity: f32 = 1;
    var displayed = true;
    while (try attrs.next()) |a| {
        const coordinate_names = if (g.radial) [_][]const u8{ "cx", "cy", "r", "fx", "fy", "fr" } else [_][]const u8{ "x1", "y1", "x2", "y2", "", "" };
        var coordinate = false;
        for (coordinate_names, 0..) |name, i| if (name.len != 0 and eql(a.name, name)) {
            g.coordinates[i] = try parseLength(a.value);
            g.specified |= @as(u16, 1) << @intCast(i);
            coordinate = true;
            break;
        };
        if (coordinate) continue;
        if (eql(a.name, "id")) g.id = a.value else if (eql(a.name, "href") or eql(a.name, "xlink:href")) {
            const ref = trim(a.value);
            if (ref.len < 2 or ref[0] != '#') return error.UnsupportedPaint;
            g.href = ref[1..];
        } else if (eql(a.name, "gradientUnits")) {
            g.object_box = if (eql(a.value, "objectBoundingBox")) true else if (eql(a.value, "userSpaceOnUse")) false else return error.UnsupportedPaint;
            g.specified |= 1 << 6;
        } else if (eql(a.name, "gradientTransform")) {
            g.matrix = try transformList(a.value);
            g.specified |= 1 << 7;
        } else if (eql(a.name, "spreadMethod")) {
            g.spread = if (eql(a.value, "pad")) .pad else if (eql(a.value, "repeat")) .repeat else if (eql(a.value, "reflect")) .reflect else return error.UnsupportedPaint;
            g.specified |= 1 << 8;
        } else if (eql(a.name, "style")) inline_style = a.value else if (try styleProperty(inherited, &opacity, &displayed, a.name, a.value)) {} else if (!metadata(a.name)) return error.UnsupportedAttribute;
    }
    if (inline_style) |css| {
        var declarations: Declarations = .{ .bytes = css };
        while (try declarations.next()) |a| if (!try styleProperty(inherited, &opacity, &displayed, a.name, a.value)) return error.UnsupportedCss;
    }
    g.interpolation.space = inherited.interpolation;
    return g;
}
fn stopTag(tag: Tag, inherited: Style, previous: f32) Error!brushes.Stop {
    var style = inherited;
    var offset: f32 = 0;
    var opacity: f32 = 1;
    var displayed = true;
    var attrs: Attributes = .{ .bytes = tag.attributes };
    var inline_style: ?[]const u8 = null;
    while (try attrs.next()) |a| {
        if (eql(a.name, "offset")) offset = (try parseLength(a.value)).value else if (eql(a.name, "style")) inline_style = a.value else if (try styleProperty(&style, &opacity, &displayed, a.name, a.value)) {} else if (!metadata(a.name)) return error.UnsupportedAttribute;
    }
    if (inline_style) |css| {
        var declarations: Declarations = .{ .bytes = css };
        while (try declarations.next()) |a| if (!try styleProperty(&style, &opacity, &displayed, a.name, a.value)) return error.UnsupportedCss;
    }
    var stop_color = switch (style.stop_color) {
        .solid => |v| v,
        .current_color => style.color,
        else => return error.UnsupportedPaint,
    };
    stop_color[3] *= style.stop_opacity;
    return .{ .position = @max(previous, std.math.clamp(offset, 0, 1)), .color = stop_color };
}
fn findGradient(rows: []const Gradient, id: []const u8) ?usize {
    for (rows, 0..) |g, i| if (eql(g.id, id)) return i;
    return null;
}

/// The borrowed ID/stop rows are an optional import result, not a runtime resource manager.
/// Definitions may follow their users. Local href chains are resolved with bounded passes.
pub fn collectGradients(data: []const u8, rows: []Gradient, stops: []brushes.Stop, stack: []Frame, foreground: color.Rgba) Error![]Gradient {
    return collectGradientsWithPalette(data, rows, stops, stack, foreground, &.{});
}

pub fn collectGradientsWithPalette(data: []const u8, rows: []Gradient, stops: []brushes.Stop, stack: []Frame, foreground: color.Rgba, palette: []const color.Rgba) Error![]Gradient {
    var xml: Xml = .{ .bytes = data };
    var depth: usize = 0;
    var count: usize = 0;
    var used: usize = 0;
    while (try xml.next()) |tag| {
        if (tag.closing) {
            if (depth == 0 or !eql(stack[depth - 1].name, tag.name)) return error.UnbalancedTags;
            depth -= 1;
            continue;
        }
        if (eql(tag.name, "title") or eql(tag.name, "desc") or eql(tag.name, "metadata")) {
            try xml.skip(tag);
            continue;
        }
        const parent: Style = if (depth == 0) .{ .color = foreground, .palette = palette } else stack[depth - 1].style;
        var frame: Frame = .{ .name = tag.name, .style = parent, .matrix = identity, .displayed = true, .selected = true, .shape = false, .opacity = 1, .layer = null };
        if (eql(tag.name, "linearGradient") or eql(tag.name, "radialGradient")) {
            if (count == rows.len) return error.InsufficientStorage;
            if (depth != 0 and stack[depth - 1].gradient != null) return error.UnsupportedElement;
            var g = try gradientTag(tag, parent, &frame.style);
            if (g.id.len == 0 or findGradient(rows[0..count], g.id) != null) return error.InvalidXml;
            g.stop_start = used;
            g.stops = stops[used..used];
            rows[count] = g;
            frame.gradient = count;
            count += 1;
        } else if (eql(tag.name, "stop")) {
            if (depth == 0) return error.InvalidXml;
            const index = stack[depth - 1].gradient orelse return error.InvalidXml;
            if (used == stops.len) return error.InsufficientStorage;
            const g = &rows[index];
            stops[used] = try stopTag(tag, parent, if (g.stops.len == 0) 0 else g.stops[g.stops.len - 1].position);
            used += 1;
            g.stops = stops[g.stop_start..used];
        } else if (eql(tag.name, "defs")) {
            var a: Attributes = .{ .bytes = tag.attributes };
            var opacity: f32 = 1;
            var displayed = true;
            while (try a.next()) |attr| if (!try styleProperty(&frame.style, &opacity, &displayed, attr.name, attr.value) and !metadata(attr.name)) return error.UnsupportedAttribute;
        } else if (eql(tag.name, "svg") or eql(tag.name, "g") or eql(tag.name, "path") or eql(tag.name, "rect") or eql(tag.name, "circle") or eql(tag.name, "ellipse") or eql(tag.name, "line") or eql(tag.name, "polygon") or eql(tag.name, "polyline")) {
            frame = try styled(tag, parent, identity);
        } else return error.UnsupportedElement;
        if (!tag.empty) {
            if (depth == stack.len) return error.InsufficientStorage;
            stack[depth] = frame;
            depth += 1;
        }
    }
    if (depth != 0) return error.UnbalancedTags;
    var remaining = count;
    for (0..count + 1) |_| {
        var progress = false;
        for (rows[0..count]) |*g| {
            if (g.resolved) continue;
            if (g.href) |ref| {
                const source = &rows[findGradient(rows[0..count], ref) orelse return error.UnknownReference];
                if (!source.resolved) continue;
                if (g.radial == source.radial) for (0..6) |i| {
                    const bit = @as(u16, 1) << @intCast(i);
                    if ((g.specified & bit) == 0 and (source.specified & bit) != 0) {
                        g.coordinates[i] = source.coordinates[i];
                        g.specified |= bit;
                    }
                };
                if ((g.specified & (1 << 6)) == 0) g.object_box = source.object_box;
                if ((g.specified & (1 << 7)) == 0) g.matrix = source.matrix;
                if ((g.specified & (1 << 8)) == 0) g.spread = source.spread;
                if (g.stops.len == 0) g.stops = source.stops;
            }
            if (g.radial) {
                if ((g.specified & (1 << 3)) == 0) g.coordinates[3] = g.coordinates[0];
                if ((g.specified & (1 << 4)) == 0) g.coordinates[4] = g.coordinates[1];
            }
            g.resolved = true;
            remaining -= 1;
            progress = true;
        }
        if (remaining == 0) break;
        if (!progress) return error.CyclicReference;
    }
    return rows[0..count];
}

fn diagonal(size: [2]f32) f32 {
    return std.math.hypot(size[0], size[1]) / @sqrt(@as(f32, 2));
}
/// Prepares a native brush plus its coordinate inverse, usable independently of the importer.
pub fn resolvePaint(paint_value: Paint, current_color: color.Rgba, gradients: []const Gradient, object_bounds: Rect, matrix: [6]f32, viewport_size: [2]f32, segments: []brushes.Segment) Error!?ResolvedPaint {
    switch (paint_value) {
        .none => return null,
        .solid => |rgba| return .{ .brush = .{ .solid = rgba } },
        .current_color => return .{ .brush = .{ .solid = current_color } },
        .gradient => |id| {
            const g = gradients[findGradient(gradients, id) orelse return error.UnknownReference];
            if (g.stops.len == 0) return .{ .brush = .{ .solid = .{ 0, 0, 0, 0 } } };
            var basis = viewport_size;
            var placement = matrix;
            if (g.object_box) {
                if (object_bounds.w() <= 0 or object_bounds.h() <= 0) return null;
                basis = .{ 1, 1 };
                placement = geometry.compose(placement, .{ object_bounds.w(), 0, 0, object_bounds.h(), object_bounds.x0, object_bounds.y0 });
            }
            placement = geometry.compose(placement, g.matrix);
            const inverse = geometry.inverse(placement) orelse return null;
            const ramp = try brushes.prepareStops(g.stops, segments, g.interpolation, g.spread);
            if (!g.radial) return .{ .inverse = inverse, .brush = .{ .linear = .{ .ramp = ramp, .from = .{ g.coordinates[0].resolve(basis[0]), g.coordinates[1].resolve(basis[1]) }, .to = .{ g.coordinates[2].resolve(basis[0]), g.coordinates[3].resolve(basis[1]) } } } };
            const r = g.coordinates[2].resolve(diagonal(basis));
            const fr = g.coordinates[5].resolve(diagonal(basis));
            if (r < 0 or fr < 0) return error.InvalidGeometry;
            const start: [2]f32 = .{ g.coordinates[3].resolve(basis[0]), g.coordinates[4].resolve(basis[1]) };
            const end: [2]f32 = .{ g.coordinates[0].resolve(basis[0]), g.coordinates[1].resolve(basis[1]) };
            // SVG's legacy repeated, exactly-on-circumference zero-focus average differs
            // from the general cone rule. Diagnose that specialist case instead of hiding it.
            if (fr == 0 and g.spread != .pad and std.math.hypot(end[0] - start[0], end[1] - start[1]) == r) return error.UnsupportedPaint;
            if (r == 0 and fr == 0) return .{ .brush = .{ .solid = g.stops[g.stops.len - 1].color } };
            return .{ .inverse = inverse, .brush = .{ .two_circle = .{ .ramp = ramp, .start = start, .start_radius = fr, .end = end, .end_radius = r } } };
        },
    }
}

fn attributeLength(tag: Tag, key: []const u8, basis: f32, fallback: f32) Error!f32 {
    return if (try tag.get(key)) |value| (try parseLength(value)).resolve(basis) else fallback;
}
fn move(p: *paths.Path, x: f32, y: f32) Error!void {
    try pathRoom(p, 1, 1);
    p.moveTo(x, y);
}
fn line(p: *paths.Path, x: f32, y: f32) Error!void {
    try pathRoom(p, 1, 1);
    p.lineTo(x, y);
}
fn close(p: *paths.Path) Error!void {
    try pathRoom(p, 1, 0);
    p.close();
}
fn ellipse(p: *paths.Path, center: [2]f32, radius: [2]f32) Error!void {
    if (radius[0] < 0 or radius[1] < 0) return error.InvalidGeometry;
    if (radius[0] == 0 or radius[1] == 0) return;
    const k: f32 = 0.5522847498307936;
    const x = center[0];
    const y = center[1];
    const rx = radius[0];
    const ry = radius[1];
    try pathRoom(p, 6, 13);
    p.moveTo(x + rx, y);
    p.cubicTo(x + rx, y + ry * k, x + rx * k, y + ry, x, y + ry);
    p.cubicTo(x - rx * k, y + ry, x - rx, y + ry * k, x - rx, y);
    p.cubicTo(x - rx, y - ry * k, x - rx * k, y - ry, x, y - ry);
    p.cubicTo(x + rx * k, y - ry, x + rx, y - ry * k, x + rx, y);
    p.close();
}
fn shape(tag: Tag, size: [2]f32, p: *paths.Path) Error!void {
    p.clear();
    if (eql(tag.name, "path")) return pathData((try tag.get("d")) orelse "", p);
    if (eql(tag.name, "rect")) {
        const x = try attributeLength(tag, "x", size[0], 0);
        const y = try attributeLength(tag, "y", size[1], 0);
        const w = try attributeLength(tag, "width", size[0], 0);
        const h = try attributeLength(tag, "height", size[1], 0);
        if (w < 0 or h < 0) return error.InvalidGeometry;
        if (w == 0 or h == 0) return;
        const rx_value = try tag.get("rx");
        const ry_value = try tag.get("ry");
        var rx: f32 = if (rx_value) |v| (try parseLength(v)).resolve(size[0]) else if (ry_value) |v| (try parseLength(v)).resolve(size[1]) else 0;
        var ry: f32 = if (ry_value) |v| (try parseLength(v)).resolve(size[1]) else rx;
        if (rx < 0 or ry < 0) return error.InvalidGeometry;
        rx = @min(rx, w * 0.5);
        ry = @min(ry, h * 0.5);
        if (rx == 0 or ry == 0) {
            try move(p, x, y);
            try line(p, x + w, y);
            try line(p, x + w, y + h);
            try line(p, x, y + h);
            try close(p);
            return;
        }
        try move(p, x + rx, y);
        try line(p, x + w - rx, y);
        try vector.arcTo(p, .{ x + w - rx, y }, .{ x + w, y + ry }, .{ .radius = .{ rx, ry } });
        try line(p, x + w, y + h - ry);
        try vector.arcTo(p, .{ x + w, y + h - ry }, .{ x + w - rx, y + h }, .{ .radius = .{ rx, ry } });
        try line(p, x + rx, y + h);
        try vector.arcTo(p, .{ x + rx, y + h }, .{ x, y + h - ry }, .{ .radius = .{ rx, ry } });
        try line(p, x, y + ry);
        try vector.arcTo(p, .{ x, y + ry }, .{ x + rx, y }, .{ .radius = .{ rx, ry } });
        try close(p);
    } else if (eql(tag.name, "circle") or eql(tag.name, "ellipse")) {
        const center: [2]f32 = .{ try attributeLength(tag, "cx", size[0], 0), try attributeLength(tag, "cy", size[1], 0) };
        const radius: [2]f32 = if (eql(tag.name, "circle")) @splat(try attributeLength(tag, "r", diagonal(size), 0)) else .{ try attributeLength(tag, "rx", size[0], 0), try attributeLength(tag, "ry", size[1], 0) };
        try ellipse(p, center, radius);
    } else if (eql(tag.name, "line")) {
        try move(p, try attributeLength(tag, "x1", size[0], 0), try attributeLength(tag, "y1", size[1], 0));
        try line(p, try attributeLength(tag, "x2", size[0], 0), try attributeLength(tag, "y2", size[1], 0));
    } else if (eql(tag.name, "polyline") or eql(tag.name, "polygon")) {
        var n: Numbers = .{ .bytes = (try tag.get("points")) orelse "" };
        while (n.more()) {
            const x = try n.number();
            const y = try n.number();
            if (p.verbs == 0) try move(p, x, y) else try line(p, x, y);
        }
        if (p.verbs != 0 and eql(tag.name, "polygon")) try close(p);
    } else return error.UnsupportedElement;
}
fn evaluate(comptime cubic: bool, p: [4]f32, t: f32) f32 {
    const s = 1 - t;
    return if (cubic) s * s * s * p[0] + 3 * s * s * t * p[1] + 3 * s * t * t * p[2] + t * t * t * p[3] else s * s * p[0] + 2 * s * t * p[1] + t * t * p[3];
}
fn curveExtents(comptime cubic: bool, p: [4]f32, lo: *f32, hi: *f32) void {
    lo.* = @min(lo.*, @min(p[0], p[3]));
    hi.* = @max(hi.*, @max(p[0], p[3]));
    const a: f32 = if (cubic) -p[0] + 3 * p[1] - 3 * p[2] + p[3] else 0;
    const b: f32 = if (cubic) 2 * (p[0] - 2 * p[1] + p[2]) else p[0] - 2 * p[1] + p[3];
    const c = p[1] - p[0];
    var roots: [2]f32 = .{ -1, -1 };
    if (a == 0) {
        if (b != 0) roots[0] = -c / b;
    } else {
        const d = b * b - 4 * a * c;
        if (d >= 0) roots = .{ (-b + @sqrt(d)) / (2 * a), (-b - @sqrt(d)) / (2 * a) };
    }
    for (roots) |t| if (t > 0 and t < 1) {
        const value = evaluate(cubic, p, t);
        lo.* = @min(lo.*, value);
        hi.* = @max(hi.*, value);
    };
}
/// Tight authored curve bounds, avoiding integer/tessellation rounding in object-box paint.
pub fn pathBounds(p: *const paths.Path) Rect {
    var low: [2]f32 = @splat(std.math.inf(f32));
    var high: [2]f32 = @splat(-std.math.inf(f32));
    var at: usize = 0;
    var current: [2]f32 = .{ 0, 0 };
    var start = current;
    for (p.verb[0..p.verbs]) |verb| {
        if (verb == .move) {
            current = .{ p.x[at], p.y[at] };
            start = current;
            at += 1;
            continue;
        }
        const count: usize = switch (verb) {
            .move => unreachable,
            .line => 1,
            .quad => 2,
            .cubic => 3,
            .close => 0,
        };
        const end: [2]f32 = if (count == 0) start else .{ p.x[at + count - 1], p.y[at + count - 1] };
        if (verb == .quad or verb == .cubic) {
            const x: [4]f32 = .{ current[0], p.x[at], p.x[at + count - 2], end[0] };
            const y: [4]f32 = .{ current[1], p.y[at], p.y[at + count - 2], end[1] };
            if (verb == .cubic) {
                curveExtents(true, x, &low[0], &high[0]);
                curveExtents(true, y, &low[1], &high[1]);
            } else {
                curveExtents(false, x, &low[0], &high[0]);
                curveExtents(false, y, &low[1], &high[1]);
            }
        } else for (0..2) |i| {
            low[i] = @min(low[i], @min(current[i], end[i]));
            high[i] = @max(high[i], @max(current[i], end[i]));
        }
        current = end;
        at += count;
    }
    if (low[0] == std.math.inf(f32)) return .{};
    return .{ .x0 = low[0], .y0 = low[1], .x1 = high[0], .y1 = high[1] };
}
const Viewport = struct { matrix: [6]f32, size: [2]f32 };
fn viewport(tag: Tag, box: Rect, intrinsic: bool) Error!Viewport {
    var vb: [4]f32 = .{ 0, 0, box.w(), box.h() };
    if (intrinsic) {
        vb[2] = try attributeLength(tag, "width", box.w(), box.w());
        vb[3] = try attributeLength(tag, "height", box.h(), box.h());
    }
    if (try tag.get("viewBox")) |bytes| {
        var n: Numbers = .{ .bytes = bytes };
        for (&vb) |*v| v.* = try n.number();
        if (n.more()) return error.InvalidGeometry;
    }
    if (vb[2] <= 0 or vb[3] <= 0) return error.InvalidGeometry;
    for ([_][]const u8{ "width", "height" }) |key| if (try tag.get(key)) |bytes| {
        if ((try parseLength(bytes)).value < 0) return error.InvalidGeometry;
    };
    var sx = box.w() / vb[2];
    var sy = box.h() / vb[3];
    const aspect = trim((try tag.get("preserveAspectRatio")) orelse "xMidYMid meet");
    var alignment: [2]f32 = .{ 0.5, 0.5 };
    if (eql(aspect, "none")) alignment = .{ 0, 0 } else {
        var words = std.mem.tokenizeAny(u8, aspect, " \t\r\n");
        const alignment_word = words.next() orelse return error.InvalidGeometry;
        const sizing = words.next() orelse "meet";
        if (alignment_word.len != 8 or !eql(alignment_word[0..1], "x") or !eql(alignment_word[4..5], "Y")) return error.InvalidGeometry;
        alignment[0] = if (eql(alignment_word[1..4], "Min")) 0 else if (eql(alignment_word[1..4], "Mid")) 0.5 else if (eql(alignment_word[1..4], "Max")) 1 else return error.InvalidGeometry;
        alignment[1] = if (eql(alignment_word[5..8], "Min")) 0 else if (eql(alignment_word[5..8], "Mid")) 0.5 else if (eql(alignment_word[5..8], "Max")) 1 else return error.InvalidGeometry;
        const scale = if (eql(sizing, "meet")) @min(sx, sy) else if (eql(sizing, "slice")) @max(sx, sy) else return error.InvalidGeometry;
        if (words.next() != null) return error.InvalidGeometry;
        sx = scale;
        sy = scale;
    }
    return .{ .matrix = .{ sx, 0, 0, sy, box.x0 - vb[0] * sx + (box.w() - vb[2] * sx) * alignment[0], box.y0 - vb[1] * sy + (box.h() - vb[3] * sy) * alignment[1] }, .size = .{ vb[2], vb[3] } };
}
fn polylineRoom(p: *const paths.Polyline, points: usize, contours: usize) Error!void {
    if (p.x.len < points or p.y.len < points or p.end.len < contours or p.closed.len < contours) return error.InsufficientStorage;
}
fn croppedBounds(p: *const paths.Polyline, dst: surface.Surface, view: decoration.View) paths.Box {
    const box = paths.bounds(p);
    const x0 = @max(@as(f32, @floatFromInt(box.x)), @floor(view.origin[0] * view.scale));
    const y0 = @max(@as(f32, @floatFromInt(box.y)), @floor(view.origin[1] * view.scale));
    const x1 = @min(@as(f32, @floatFromInt(@as(i64, box.x) + box.w)), @ceil(view.origin[0] * view.scale + @as(f32, @floatFromInt(dst.width))));
    const y1 = @min(@as(f32, @floatFromInt(@as(i64, box.y) + box.h)), @ceil(view.origin[1] * view.scale + @as(f32, @floatFromInt(dst.height))));
    if (x1 <= x0 or y1 <= y0) return .{};
    return .{ .x = @intFromFloat(x0), .y = @intFromFloat(y0), .w = @intFromFloat(x1 - x0), .h = @intFromFloat(y1 - y0) };
}
fn paintPolyline(dst: surface.Surface, poly: *const paths.Polyline, rule: paths.Rule, paint_value: Paint, style: Style, alpha_value: f32, object_bounds: Rect, matrix: [6]f32, size: [2]f32, gradients: []const Gradient, view: decoration.View, buffers: Buffers) Error!void {
    const box = croppedBounds(poly, dst, view);
    if (box.w == 0 or box.h == 0) return;
    const resolved = (try resolvePaint(paint_value, style.color, gradients, object_bounds, matrix, size, buffers.segments)) orelse return;
    if (buffers.accumulator.len < paths.accLen(box) or buffers.coverage.len < paths.imageLen(box)) return error.InsufficientStorage;
    const count = poly.points;
    const fill = buffers.fill;
    if (fill.x0.len < count or fill.y0.len < count or fill.y1.len < count or fill.dxdy.len < count or fill.cross_x.len < count or fill.cross_d.len < count) return error.InsufficientStorage;
    paths.fill(poly, box, rule, fill, buffers.accumulator);
    paths.coverage(buffers.accumulator, buffers.coverage, @as(usize, box.w) * box.h);
    try vector.paintCoverageTransformed(dst, .{ .bytes = buffers.coverage, .box = box, .scale = view.scale }, resolved.brush, resolved.inverse, view, alpha_value);
}
fn paintShape(dst: surface.Surface, tag: Tag, frame: Frame, size: [2]f32, gradients: []const Gradient, view: decoration.View, tolerance: f32, buffers: Buffers) Error!void {
    if (geometry.inverse(frame.matrix) == null) return;
    try shape(tag, size, buffers.path);
    for (buffers.path.x[0..buffers.path.points], buffers.path.y[0..buffers.path.points]) |x, y| if (!std.math.isFinite(x) or !std.math.isFinite(y)) return error.InvalidGeometry;
    const object_bounds = pathBounds(buffers.path);
    const matrix = geometry.compose(.{ view.scale, 0, 0, view.scale, 0, 0 }, frame.matrix);
    const magnification = @max(std.math.hypot(matrix[0], matrix[1]) + std.math.hypot(matrix[2], matrix[3]), 1e-8);
    const local_tolerance = tolerance / magnification;
    const required = paths.flattenLen(buffers.path, local_tolerance);
    try polylineRoom(buffers.centerline, required.points, required.contours);
    paths.flatten(buffers.path, local_tolerance, buffers.centerline);
    const style = frame.style;
    // Both operations are deliberately kept here: callers can reproduce or replace either.
    for (0..2) |pass| {
        const is_stroke = (pass == 0) == style.stroke_first;
        if (!is_stroke) {
            if (style.fill == .none or style.fill_opacity == 0) continue;
            try vector.transform(buffers.centerline, matrix, buffers.work);
            try paintPolyline(dst, buffers.work, style.rule, style.fill, style, style.fill_opacity, object_bounds, frame.matrix, size, gradients, view, buffers);
        } else {
            const width = style.stroke_width.resolve(diagonal(size));
            if (style.stroke == .none or style.stroke_opacity == 0 or width == 0) continue;
            var dashed_count: usize = 0;
            var n: Numbers = .{ .bytes = style.dash_array };
            while (n.more()) {
                if (dashed_count == buffers.dashes.len) return error.InsufficientStorage;
                buffers.dashes[dashed_count] = (try n.length()).resolve(diagonal(size));
                if (buffers.dashes[dashed_count] < 0) return error.InvalidDash;
                dashed_count += 1;
            }
            var any_dash = false;
            for (buffers.dashes[0..dashed_count]) |value| any_dash = any_dash or value > 0;
            if (!any_dash) dashed_count = 0;
            var stroke_source = buffers.centerline;
            var stroke_tolerance = local_tolerance;
            var stroke_style: paths.Stroke = .{ .width = width, .cap = style.cap, .join = style.join, .miter_limit = style.miter_limit };
            if (style.non_scaling) {
                // Work in output pixels, including dashes; the original centerline remains
                // available so stroke-first ordering preserves fill geometry.
                try vector.transform(buffers.centerline, matrix, buffers.work);
                stroke_source = buffers.work;
                stroke_style.width *= view.scale;
                stroke_tolerance = tolerance;
                for (buffers.dashes[0..dashed_count]) |*value| value.* *= view.scale;
            }
            if (dashed_count != 0) {
                const dash_target = if (style.non_scaling) buffers.outline else buffers.work;
                try vector.dash(stroke_source, buffers.dashes[0..dashed_count], style.dash_offset.resolve(diagonal(size)) * (if (style.non_scaling) view.scale else 1), dash_target);
                stroke_source = dash_target;
            }
            const output = if (stroke_source == buffers.outline) buffers.work else buffers.outline;
            const stroke_required = paths.strokeLen(stroke_source, stroke_style, stroke_tolerance);
            try polylineRoom(output, simd.rows(stroke_required.points), stroke_required.contours);
            paths.stroke(stroke_source, stroke_style, stroke_tolerance, output);
            if (!style.non_scaling) try vector.transform(output, matrix, output);
            try paintPolyline(dst, output, .nonzero, style.stroke, style, style.stroke_opacity, object_bounds, frame.matrix, size, gradients, view, buffers);
        }
    }
}
fn target(dst: surface.Surface, layers: []surface.Surface, active: usize) surface.Surface {
    return if (active == 0) dst else layers[active - 1];
}
fn finish(frame: Frame, dst: surface.Surface, layers: []surface.Surface, active: *usize) Error!void {
    if (frame.layer) |index| {
        std.debug.assert(active.* == index + 1);
        active.* -= 1;
        try compositor.composite(target(dst, layers, active.*), layers[index].view(), .{ .opacity = frame.opacity });
    }
}
/// Actual static SVG renderer. All storage and optional isolated surfaces are supplied by the
/// caller; it adds no loader, cache, callback, thread or frame loop to the application.
pub fn paint(data: []const u8, dst: surface.Surface, options: Options, buffers: Buffers) Error!void {
    try dst.validate();
    if (!brushes.validRect(options.viewport) or !std.math.isFinite(options.view.scale) or options.view.scale <= 0 or !std.math.isFinite(options.tolerance) or options.tolerance <= 0 or !color.finite(options.current_color)) return error.InvalidGeometry;
    if (options.current_color[3] < 0 or options.current_color[3] > 1) return error.InvalidColor;
    for (options.palette) |entry| if (!color.finite(entry) or entry[3] < 0 or entry[3] > 1) return error.InvalidColor;
    for (options.initial_transform) |value| if (!std.math.isFinite(value)) return error.InvalidTransform;
    if (surface.overlapsBytes(std.mem.sliceAsBytes(dst.pixels), data)) return error.AliasedStorage;
    try decoration.validateClipSources(dst.pixels, options.view.clips);
    if (buffers.clips.len < options.view.clips.len + @intFromBool(options.clip_viewport)) return error.InsufficientStorage;
    for (buffers.layers, 0..) |layer, i| {
        try layer.validate();
        if (layer.width != dst.width or layer.height != dst.height) return error.SizeMismatch;
        if (surface.overlaps(layer.pixels, dst.pixels) or surface.overlapsBytes(std.mem.sliceAsBytes(layer.pixels), data)) return error.AliasedStorage;
        for (buffers.layers[0..i]) |other| if (surface.overlaps(layer.pixels, other.pixels)) return error.AliasedStorage;
        try decoration.validateClipSources(layer.pixels, options.view.clips);
    }
    const gradients = try collectGradientsWithPalette(data, buffers.gradients, buffers.stops, buffers.stack, options.current_color, options.palette);
    @memcpy(buffers.clips[0..options.view.clips.len], options.view.clips);
    if (options.clip_viewport) buffers.clips[options.view.clips.len] = .{ .rounded = .{ .shape = .{ .rect = options.viewport }, .inverse = geometry.inverse(options.initial_transform) orelse return error.InvalidTransform } };
    var view = options.view;
    view.clips = buffers.clips[0 .. options.view.clips.len + @intFromBool(options.clip_viewport)];
    var xml: Xml = .{ .bytes = data };
    var depth: usize = 0;
    var active: usize = 0;
    var seen_root = false;
    var selected = options.fragment == null;
    var size: [2]f32 = .{ options.viewport.w(), options.viewport.h() };
    var root_coordinates = options.initial_transform;
    while (try xml.next()) |tag| {
        if (tag.closing) {
            if (depth == 0 or !eql(buffers.stack[depth - 1].name, tag.name)) return error.UnbalancedTags;
            depth -= 1;
            try finish(buffers.stack[depth], dst, buffers.layers, &active);
            continue;
        }
        if ((eql(tag.name, "defs") and options.fragment == null) or eql(tag.name, "linearGradient") or eql(tag.name, "radialGradient") or eql(tag.name, "title") or eql(tag.name, "desc") or eql(tag.name, "metadata")) {
            try xml.skip(tag);
            continue;
        }
        if (depth == 0 and (!eql(tag.name, "svg") or seen_root)) return error.InvalidXml;
        if (depth != 0 and (eql(tag.name, "svg") or buffers.stack[depth - 1].shape)) return error.UnsupportedElement;
        const matches_fragment = if (options.fragment) |id| if (try tag.get("id")) |own_id| eql(id, own_id) else false else false;
        const detached = matches_fragment and !options.fragment_ancestors and depth != 0;
        const parent: Style = if (depth == 0 or detached) .{ .color = options.current_color, .palette = options.palette } else buffers.stack[depth - 1].style;
        const parent_matrix = if (depth == 0) identity else if (detached) root_coordinates else buffers.stack[depth - 1].matrix;
        var frame = try styled(tag, parent, parent_matrix);
        if (eql(tag.name, "defs")) {
            frame.shape = false;
            frame.displayed = false;
        }
        if (depth == 0) {
            const vp = try viewport(tag, options.viewport, options.use_intrinsic_size);
            root_coordinates = geometry.compose(options.initial_transform, vp.matrix);
            frame.matrix = geometry.compose(options.initial_transform, geometry.compose(frame.matrix, vp.matrix));
            size = vp.size;
            seen_root = true;
        } else if (!detached) frame.displayed = frame.displayed and buffers.stack[depth - 1].displayed;
        frame.selected = if (depth == 0) options.fragment == null else buffers.stack[depth - 1].selected;
        if (matches_fragment) {
            frame.selected = true;
            selected = true;
        }
        if (frame.opacity == 0) frame.displayed = false;
        if (frame.displayed and frame.opacity < 1 and (frame.selected or options.fragment_ancestors)) {
            if (active == buffers.layers.len) return error.InsufficientStorage;
            try surface.clear(buffers.layers[active], .{ 0, 0, 0, 0 });
            frame.layer = active;
            active += 1;
        }
        if (frame.shape and frame.displayed and frame.selected and frame.style.visible) try paintShape(target(dst, buffers.layers, active), tag, frame, size, gradients, view, options.tolerance, buffers);
        if (tag.empty) try finish(frame, dst, buffers.layers, &active) else {
            if (depth == buffers.stack.len) return error.InsufficientStorage;
            buffers.stack[depth] = frame;
            depth += 1;
        }
    }
    if (!seen_root or depth != 0) return error.UnbalancedTags;
    if (!selected) return error.UnknownReference;
}

const testing = std.testing;
const TestStorage = struct {
    source: paths.TestBuffers(128, 2048) = .{},
    working: paths.TestBuffers(256, 4096) = .{},
    stroked: paths.TestBuffers(256, 4096) = .{},
    p: paths.Path = undefined,
    center: paths.Polyline = undefined,
    work: paths.Polyline = undefined,
    outline: paths.Polyline = undefined,
    gradients: [8]Gradient = undefined,
    stops: [32]brushes.Stop = undefined,
    segments: [32]brushes.Segment = undefined,
    stack: [16]Frame = undefined,
    dashes: [32]f32 = undefined,
    clips: [4]decoration.Clip = undefined,
    accumulator: [simd.rows(64 * 32 + 2)]f32 = undefined,
    coverage: [simd.rows(64 * 32)]u8 = undefined,
    layer_pixels: [2][simd.rows(64) * 32]u32 = undefined,
    layers: [2]surface.Surface = undefined,
    fn bind(t: *TestStorage, width: u32, height: u32) !Buffers {
        t.p = t.source.path();
        t.center = t.source.polyline();
        t.work = t.working.polyline();
        t.outline = t.stroked.polyline();
        for (&t.layers, 0..) |*layer, i| layer.* = try surface.init(&t.layer_pixels[i], width, height);
        return .{ .path = &t.p, .centerline = &t.center, .work = &t.work, .outline = &t.outline, .fill = t.stroked.scratch(), .accumulator = &t.accumulator, .coverage = &t.coverage, .gradients = &t.gradients, .stops = &t.stops, .segments = &t.segments, .stack = &t.stack, .layers = &t.layers, .dashes = &t.dashes, .clips = &t.clips };
    }
};

test "SVG path commands and transform lists preserve curves and authored bounds" {
    var storage: paths.TestBuffers(64, 512) = .{};
    var p = storage.path();
    try pathData("M0 0 Q10 10 20 0", &p);
    try testing.expectEqual(Rect{ .x0 = 0, .y0 = 0, .x1 = 20, .y1 = 5 }, pathBounds(&p));
    try pathData("M1,2 3,4h5v-2q2-3 4 0t4 0c1 2 3 4 5 6s3-1 4-2a3 4 30 0110 0z", &p);
    try testing.expect(p.verbs >= 10);
    try testing.expectEqual(paths.Verb.close, p.verb[p.verbs - 1]);
    const m = try transformList("translate(3 5) scale(2) rotate(90)");
    const pt = geometry.point(m, .{ 1, 0 });
    try testing.expectApproxEqAbs(@as(f32, 3), pt[0], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 7), pt[1], 0.0001);
    try testing.expectError(error.InvalidPath, pathData("L2 3", &p));
    try testing.expectError(error.InvalidPath, pathData("M0 0A1 1 0 2 0 5 5", &p));
}

test "SVG actual gradient templates and isolated opacity overlap render into the surface" {
    const xml =
        \\<svg viewBox="0 0 32 16"><defs>
        \\<linearGradient id="base"><stop offset="0" stop-color="red"/><stop offset="1" stop-color="blue"/></linearGradient>
        \\<linearGradient id="tilted" href="#base" gradientTransform="skewX(30)"/></defs>
        \\<g opacity=".5"><rect width="20" height="16" fill="url(#tilted)"/>
        \\<rect x="12" width="20" height="16" style="fill:red;fill:#00ff00"/></g></svg>
    ;
    var pixels: [simd.rows(64) * 32]u32 = undefined;
    const dst = try surface.init(&pixels, 64, 32);
    var storage: TestStorage = .{};
    const buffers = try storage.bind(64, 32);
    try paint(xml, dst, .{ .viewport = .{ .x1 = 32, .y1 = 16 }, .view = .{ .scale = 2, .quality = .one } }, buffers);
    const overlap = dst.pixels[16 * dst.stride + 30];
    try testing.expectEqual(@as(u32, 128), overlap >> 24);
    try testing.expectEqual(@as(u32, 128), (overlap >> 8) & 255);
    const first = dst.pixels[16 * dst.stride + 8];
    try testing.expectEqual(@as(u32, 128), first >> 24);
    try testing.expect((first & 255) > ((first >> 16) & 255));
    try testing.expectEqual(@as(u32, 0), first & 0x0000ff00);
}

test "SVG non scaling dashed strokes and fragment ancestor opacity are consumed" {
    var pixels: [simd.rows(32) * 16]u32 = undefined;
    const dst = try surface.init(&pixels, 32, 16);
    var storage: TestStorage = .{};
    const buffers = try storage.bind(32, 16);
    const xml = "<svg viewBox='0 0 32 16'><g opacity='.5'><path id='glyph7' d='M1 4h8' transform='scale(2)' fill='none' stroke='red' stroke-width='2' stroke-dasharray='2 2' vector-effect='non-scaling-stroke'/><rect width='32' height='16' fill='blue'/></g></svg>";
    try paint(xml, dst, .{ .viewport = .{ .x1 = 32, .y1 = 16 }, .fragment = "glyph7", .view = .{ .quality = .one } }, buffers);
    try testing.expectEqual(@as(u32, 0x80000080), dst.pixels[8 * dst.stride + 3]);
    try testing.expectEqual(@as(u32, 0), dst.pixels[8 * dst.stride + 5]);
    try testing.expectEqual(@as(u32, 0), dst.pixels[6 * dst.stride + 3]);
}

test "SVG unsupported visual features and reference cycles are explicit" {
    var pixels: [simd.rows(8) * 8]u32 = undefined;
    const dst = try surface.init(&pixels, 8, 8);
    var storage: TestStorage = .{};
    const buffers = try storage.bind(8, 8);
    const options: Options = .{ .viewport = .{ .x1 = 8, .y1 = 8 } };
    try testing.expectError(error.UnsupportedCss, paint("<svg><rect width='8' height='8' style='filter:blur(2px)'/></svg>", dst, options, buffers));
    try testing.expectError(error.UnsupportedElement, paint("<svg><use href='#item'/></svg>", dst, options, buffers));
    try testing.expectError(error.CyclicReference, paint("<svg><defs><linearGradient id='a' href='#b'/><linearGradient id='b' href='#a'/></defs></svg>", dst, options, buffers));
    try testing.expectEqual(@as(u32, 0), dst.pixels[0]);
}

test "SVG font fragments use unclipped baseline coordinates and CPAL fallback colors" {
    var pixels: [simd.rows(32) * 16]u32 = undefined;
    const dst = try surface.init(&pixels, 32, 16);
    var storage: TestStorage = .{};
    const buffers = try storage.bind(32, 16);
    const xml = "<svg><defs><g transform='translate(100)' opacity='.25'><g id='glyph7'><rect y='-8' width='8' height='8' fill='var(--color0,orchid)'/></g></g></defs></svg>";
    const options: Options = .{ .viewport = .{ .x1 = 16, .y1 = 16 }, .fragment = "glyph7", .fragment_ancestors = false, .clip_viewport = false, .initial_transform = .{ 1, 0, 0, 1, 2, 12 }, .palette = &.{.{ 1, 0, 0, 0.5 }}, .view = .{ .quality = .one } };
    try paint(xml, dst, options, buffers);
    try testing.expectEqual(@as(u32, 0x80000080), dst.pixels[6 * dst.stride + 4]);
    try testing.expectEqual(@as(u32, 0), dst.pixels[13 * dst.stride + 4]);
    try testing.expectEqual(color.Rgba{ 139.0 / 255.0, 0, 139.0 / 255.0, 1 }, try parseColor("darkmagenta"));
    const fallback = try parsePaint("var(--color9, darkblue)", options.palette);
    try testing.expectEqual(color.Rgba{ 0, 0, 139.0 / 255.0, 1 }, fallback.solid);
}
