//! CSS properties the compiler knows and typed values read from declaration tokens. Colours go
//! through the framework's own parser (`svg.parseColor`: hex, rgb[a], hsl[a], named colours).
//! Lengths resolve to logical pixels at build time.

const std = @import("std");
const lcgf = @import("lcgf");
const css = @import("css.zig");
const diag = @import("diag.zig");
const types = lcgf.types;

/// Every longhand property the cascade tracks. Shorthands expand into these (`shorthands`).
pub const Prop = enum(u8) {
    display,
    @"flex-direction",
    @"flex-wrap",
    @"flex-grow",
    @"flex-shrink",
    @"flex-basis",
    @"justify-content",
    @"align-items",
    @"align-self",
    @"align-content",
    @"row-gap",
    @"column-gap",
    width,
    height,
    @"min-width",
    @"min-height",
    @"max-width",
    @"max-height",
    @"padding-top",
    @"padding-right",
    @"padding-bottom",
    @"padding-left",
    @"margin-top",
    @"margin-right",
    @"margin-bottom",
    @"margin-left",
    @"box-sizing",
    @"overflow-x",
    @"overflow-y",
    position,
    top,
    right,
    bottom,
    left,
    @"z-index",
    transform,
    @"transform-origin",
    opacity,
    visibility,
    cursor,
    @"pointer-events",
    @"background-color",
    @"background-image",
    @"border-top-width",
    @"border-color",
    @"border-style",
    @"border-top-left-radius",
    @"border-top-right-radius",
    @"border-bottom-right-radius",
    @"border-bottom-left-radius",
    @"box-shadow",
    @"outline-width",
    @"outline-style",
    @"outline-color",
    @"outline-offset",
    @"list-style-type",
    color,
    @"font-size",
    @"font-family",
    @"font-weight",
    @"font-style",
    @"line-height",
    @"text-align",
    @"white-space",
    @"letter-spacing",
    @"word-spacing",
    @"text-overflow",
    @"text-transform",
    @"aspect-ratio",
    order,
    direction,
    @"accent-color",
    content,
    @"grid-template-columns",
    @"grid-template-rows",
    @"grid-column",
    @"grid-row",
    @"grid-area",
    @"grid-template-areas",
    @"grid-auto-flow",
    @"grid-auto-columns",
    @"grid-auto-rows",
    @"justify-items",
    @"justify-self",
    @"caption-side",
    @"text-decoration",
    @"object-fit",
    @"column-count",

    /// Inherited properties take the parent's computed value when nothing is declared.
    pub fn inherited(p: Prop) bool {
        return switch (p) {
            .color, .@"font-size", .@"font-family", .@"font-weight", .@"font-style", .@"line-height", .@"text-align", .@"white-space", .@"letter-spacing", .@"word-spacing", .@"text-transform", .@"list-style-type", .visibility, .cursor, .@"pointer-events", .direction, .@"accent-color" => true,
            else => false,
        };
    }
};

pub const prop_count = @typeInfo(Prop).@"enum".field_names.len;

/// A shorthand and the longhands it sets, in the order its values are read.
pub const Shorthand = struct { name: []const u8, longhands: []const Prop };

pub const shorthands = [_]Shorthand{
    .{ .name = "padding", .longhands = &.{ .@"padding-top", .@"padding-right", .@"padding-bottom", .@"padding-left" } },
    .{ .name = "margin", .longhands = &.{ .@"margin-top", .@"margin-right", .@"margin-bottom", .@"margin-left" } },
    .{ .name = "gap", .longhands = &.{ .@"row-gap", .@"column-gap" } },
    .{ .name = "columns", .longhands = &.{.@"column-count"} },
    .{ .name = "overflow", .longhands = &.{ .@"overflow-x", .@"overflow-y" } },
    .{ .name = "flex", .longhands = &.{ .@"flex-grow", .@"flex-shrink", .@"flex-basis" } },
    .{ .name = "background", .longhands = &.{ .@"background-color", .@"background-image" } },
    .{ .name = "border", .longhands = &.{ .@"border-top-width", .@"border-style", .@"border-color" } },
    .{ .name = "border-width", .longhands = &.{.@"border-top-width"} },
    .{ .name = "border-radius", .longhands = &.{ .@"border-top-left-radius", .@"border-top-right-radius", .@"border-bottom-right-radius", .@"border-bottom-left-radius" } },
    .{ .name = "inset", .longhands = &.{ .top, .right, .bottom, .left } },
    .{ .name = "place-items", .longhands = &.{.@"align-items"} },
    .{ .name = "padding-inline", .longhands = &.{ .@"padding-left", .@"padding-right" } },
    .{ .name = "padding-block", .longhands = &.{ .@"padding-top", .@"padding-bottom" } },
    .{ .name = "margin-inline", .longhands = &.{ .@"margin-left", .@"margin-right" } },
    .{ .name = "margin-block", .longhands = &.{ .@"margin-top", .@"margin-bottom" } },
    .{ .name = "flex-flow", .longhands = &.{ .@"flex-direction", .@"flex-wrap" } },
    .{ .name = "list-style", .longhands = &.{.@"list-style-type"} },
    .{ .name = "outline", .longhands = &.{ .@"outline-width", .@"outline-style", .@"outline-color" } },
    .{ .name = "padding-inline-start", .longhands = &.{.@"padding-left"} },
    .{ .name = "padding-inline-end", .longhands = &.{.@"padding-right"} },
    .{ .name = "padding-block-start", .longhands = &.{.@"padding-top"} },
    .{ .name = "padding-block-end", .longhands = &.{.@"padding-bottom"} },
};

pub fn shorthand(name: []const u8) ?*const Shorthand {
    for (&shorthands) |*s| if (std.mem.eql(u8, s.name, name)) return s;
    return null;
}

/// Reads tokens `[i, end)` of a value, skipping whitespace between components.
pub const Reader = struct {
    c: *const css.Css,
    i: u32,
    end: u32,

    pub fn init(c: *const css.Css, first: u32, end: u32) Reader {
        return .{ .c = c, .i = first, .end = end };
    }

    pub fn skipWs(r: *Reader) void {
        while (r.i < r.end and r.c.toks.items(.type)[r.i] == .whitespace) r.i += 1;
    }

    pub fn done(r: *Reader) bool {
        r.skipWs();
        return r.i >= r.end;
    }

    /// The next component's first token, past it (a function or block is one component).
    pub fn next(r: *Reader) ?u32 {
        r.skipWs();
        if (r.i >= r.end) return null;
        const t = r.i;
        const ty = r.c.toks.items(.type)[t];
        r.i = if (ty == .function or ty == .l_parenthesis or ty == .ls_bracket) closeOf(r.c, t, r.end) else t + 1;
        return t;
    }

    /// Splits the rest by top-level commas; returns the end of the current item.
    pub fn untilComma(r: *Reader) u32 {
        var t = r.i;
        const ty = r.c.toks.items(.type);
        while (t < r.end and ty[t] != .comma) t = if (ty[t] == .function or ty[t] == .l_parenthesis) closeOf(r.c, t, r.end) else t + 1;
        return t;
    }
};

pub fn closeOf(c: *const css.Css, open: u32, end: u32) u32 {
    var depth: u32 = 0;
    var t = open;
    const ty = c.toks.items(.type);
    while (t < end) : (t += 1) switch (ty[t]) {
        .function, .l_parenthesis, .ls_bracket, .lc_bracket => depth += 1,
        .r_parenthesis, .rs_bracket, .rc_bracket => {
            depth -= 1;
            if (depth == 0) return t + 1;
        },
        else => {},
    };
    return end;
}

pub fn ident(c: *const css.Css, t: u32) ?[]const u8 {
    return if (c.toks.items(.type)[t] == .ident) c.toks.items(.str)[t] else null;
}

pub fn isIdent(c: *const css.Css, t: u32, name: []const u8) bool {
    return if (ident(c, t)) |s| std.ascii.eqlIgnoreCase(s, name) else false;
}

/// A length before it is resolved: what CSS wrote.
pub const Len = struct {
    v: f32,
    unit: Unit,

    pub const Unit = enum { px, pct, em, rem, auto, number };
};

/// Lengths and percentages; `auto` and unitless numbers are told apart for the caller.
/// Absolute units fold to px (CSS: 1in = 96px).
pub fn len(c: *const css.Css, t: u32) ?Len {
    const ty = c.toks.items(.type)[t];
    const v: f32 = @floatCast(c.toks.items(.num)[t]);
    switch (ty) {
        .number => return .{ .v = v, .unit = .number },
        .percentage => return .{ .v = v, .unit = .pct },
        .ident => return if (isIdent(c, t, "auto")) .{ .v = 0, .unit = .auto } else null,
        .dimension => {
            const u = c.toks.items(.str)[t];
            const table = [_]struct { []const u8, f32, Len.Unit }{
                .{ "px", 1, .px },           .{ "pt", 96.0 / 72.0, .px }, .{ "pc", 16, .px },
                .{ "in", 96, .px },          .{ "cm", 96.0 / 2.54, .px }, .{ "mm", 96.0 / 25.4, .px },
                .{ "q", 96.0 / 101.6, .px }, .{ "em", 1, .em },           .{ "rem", 1, .rem },
            };
            for (table) |row| if (std.ascii.eqlIgnoreCase(u, row[0])) return .{ .v = v * row[1], .unit = row[2] };
            return null;
        },
        else => return null,
    }
}

/// The units the compiler rejects, with the reason.
pub fn unitError(c: *const css.Css, t: u32) ?[]const u8 {
    if (c.toks.items(.type)[t] != .dimension) return null;
    const u = c.toks.items(.str)[t];
    for ([_][]const u8{ "vw", "vh", "vmin", "vmax", "vi", "vb", "svw", "svh", "lvw", "lvh", "dvw", "dvh", "cqw", "cqh", "cqi", "cqb", "cqmin", "cqmax" }) |v|
        if (std.ascii.eqlIgnoreCase(u, v)) return "viewport and container units need run-time evaluation; use % or flex-grow";
    return null;
}

/// px of `l` given the element's and the root's font size; null for % and auto.
pub fn px(l: Len, font_px: f32, root_px: f32) ?f32 {
    return switch (l.unit) {
        .px => l.v,
        .em => l.v * font_px,
        .rem => l.v * root_px,
        .number => if (l.v == 0) 0 else null,
        .pct, .auto => null,
    };
}

/// A colour component (one token or one function) as the framework's 8-bit colour.
pub fn color(c: *const css.Css, t: u32, end: u32) ?types.Color {
    const close = if (c.toks.items(.type)[t] == .function) closeOf(c, t, end) else t + 1;
    const raw = c.text(t, close);
    const rgba = lcgf.svg.parseColor(raw) catch return null;
    return .{ .r = unorm(rgba[0]), .g = unorm(rgba[1]), .b = unorm(rgba[2]), .a = unorm(rgba[3]) };
}

fn unorm(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

/// An angle in radians (`deg`, `rad`, `turn`, `grad`).
pub fn angle(c: *const css.Css, t: u32) ?f32 {
    if (c.toks.items(.type)[t] != .dimension) return if (c.toks.items(.type)[t] == .number and c.toks.items(.num)[t] == 0) 0 else null;
    const v: f32 = @floatCast(c.toks.items(.num)[t]);
    const u = c.toks.items(.str)[t];
    if (std.ascii.eqlIgnoreCase(u, "deg")) return v * std.math.pi / 180;
    if (std.ascii.eqlIgnoreCase(u, "rad")) return v;
    if (std.ascii.eqlIgnoreCase(u, "turn")) return v * 2 * std.math.pi;
    if (std.ascii.eqlIgnoreCase(u, "grad")) return v * std.math.pi / 200;
    return null;
}

test "len, color, angle: units fold to px, colours read by the framework's parser" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ds: diag.Diags = .{ .arena = arena.allocator() };
    var c: css.Css = .{ .arena = arena.allocator(), .ds = &ds };
    const src = "1in 2em 50% auto 12vw #ff000080 rgb(0 128 255) 90deg teal";
    const r = c.tokenize(ds.addFile("v.css", src), 0, src);
    var rd: Reader = .init(&c, r[0], r[1]);
    try std.testing.expectEqual(Len{ .v = 96, .unit = .px }, len(&c, rd.next().?).?);
    try std.testing.expectEqual(32, px(len(&c, rd.next().?).?, 16, 10).?);
    try std.testing.expectEqual(Len{ .v = 50, .unit = .pct }, len(&c, rd.next().?).?);
    try std.testing.expectEqual(Len.Unit.auto, len(&c, rd.next().?).?.unit);
    try std.testing.expect(unitError(&c, rd.next().?) != null);
    try std.testing.expectEqual(types.Color.rgba(255, 0, 0, 128), color(&c, rd.next().?, r[1]).?);
    try std.testing.expectEqual(types.Color.rgba(0, 128, 255, 255), color(&c, rd.next().?, r[1]).?);
    try std.testing.expectApproxEqAbs(std.math.pi / 2.0, angle(&c, rd.next().?).?, 1e-6);
    try std.testing.expectEqual(types.Color.rgb(0, 128, 128), color(&c, rd.next().?, r[1]).?);
    try std.testing.expect(rd.done());
}
