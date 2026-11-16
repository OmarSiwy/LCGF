//! Theme (tier 2): design tokens, and the widget theme they produce. Written against the public
//! API of tiers 0 to 2 only. Widgets take their whole look from `widgets_base.Theme`
//! (src/widgets/base.zig), so a theme here is a set of tokens plus one function, `widgets`, that
//! turns them into that struct: restyling never needs per-widget code.
//!
//! Tokens are the four kinds a design system names: colours (a palette indexed by `Role`), space,
//! radius and a type scale (each a `Scale` indexed by `Step`). The defaults are the prototype's
//! dark theme (prototype/ui.zig `Theme`), so `widgets(&.{})` is `widgets_base.Theme.default`.

const std = @import("std");
const types = @import("../core/types.zig");
const base = @import("../widgets/base.zig");
const Color = types.Color;
const Style = types.Style;
const Response = types.Response;

/// What a colour is for. A palette holds one colour per role, in this order.
pub const Role = enum(u8) {
    /// Label text.
    text,
    /// Panels and toolbars that hold widgets.
    surface,
    /// A control at rest.
    control,
    /// A control under the pointer; also outlines.
    control_hot,
    /// A control held down.
    control_held,
    /// What is on: a checked box, a slider's fill, focus.
    accent,
};
pub const role_count = @typeInfo(Role).@"enum".field_names.len;

/// One colour per `Role`, indexed by `@intFromEnum(role)`.
pub const Palette = [role_count]Color;

/// A step on a size scale, smallest first.
pub const Step = enum(u8) { xs, sm, md, lg, xl };
pub const step_count = @typeInfo(Step).@"enum".field_names.len;

/// One size per `Step`, in logical pixels, non-decreasing.
pub const Scale = [step_count]f32;

/// The prototype's dark colours.
pub const dark_palette: Palette = .{
    Color.rgb(230, 230, 235), // text
    Color.rgb(30, 31, 36), // surface
    Color.rgb(58, 60, 70), // control
    Color.rgb(74, 77, 90), // control_hot
    Color.rgb(44, 46, 54), // control_held
    Color.rgb(90, 140, 255), // accent
};

pub const Tokens = struct {
    palette: Palette = dark_palette,
    /// Padding and gaps. `lg` pads controls, `md` separates a control from its caption.
    space: Scale = .{ 2, 4, 6, 8, 12 },
    /// Corner radii. `md` rounds controls.
    radius: Scale = .{ 0, 2, 4, 6, 8 },
    /// Text sizes. `md` is body text.
    text_size: Scale = .{ 11, 12, 14, 18, 24 },

    pub fn color(tok: *const Tokens, role: Role) Color {
        return tok.palette[@backingInt(role)];
    }
    pub fn spaceAt(tok: *const Tokens, s: Step) f32 {
        return tok.space[@backingInt(s)];
    }
    pub fn radiusAt(tok: *const Tokens, s: Step) f32 {
        return tok.radius[@backingInt(s)];
    }
    pub fn textAt(tok: *const Tokens, s: Step) f32 {
        return tok.text_size[@backingInt(s)];
    }
};

/// A light palette: dark text on light surfaces, controls darkening as they are engaged.
pub const light_palette: Palette = .{
    Color.rgb(28, 29, 33), // text
    Color.rgb(245, 245, 247), // surface
    Color.rgb(222, 223, 228), // control
    Color.rgb(206, 208, 216), // control_hot
    Color.rgb(190, 192, 201), // control_held
    Color.rgb(30, 96, 220), // accent
};

/// The prototype's theme: light text on dark surfaces.
pub const dark: Tokens = .{};
/// The same sizes in `light_palette`.
pub const light: Tokens = .{ .palette = light_palette };

// ---- state styles -----------------------------------------------------------------------

/// What an interaction state changes on a control: its face and its outline.
pub const Look = struct {
    fill: Color,
    border_color: Color = .transparent,
    border: f32 = 0,
};

/// One `Look` per combination of interaction bits, indexed by `stateBits`: `hovered | held << 1 |
/// focused << 2`. A widget picks its look by indexing, never by branching on its state. Rows 0
/// to 3 are `widgets_base.StateColors`'s order, so its fills are rows 0 to 3 of this table.
pub const States = [8]Look;

/// The row of a `States` table for response `r`. Other bits of the response do not move it.
pub inline fn stateBits(r: Response) u3 {
    return @as(u3, @intFromBool(r.hovered)) | (@as(u3, @intFromBool(r.held)) << 1) | (@as(u3, @intFromBool(r.focused)) << 2);
}

/// A control's looks from the tokens: rest, hot, held (held looks held wherever the pointer is,
/// as in the prototype's button), and the same four focused with an accent outline `xs` wide.
pub fn controlStates(tok: *const Tokens) States {
    var t: States = undefined;
    const faces = [4]Color{ tok.color(.control), tok.color(.control_hot), tok.color(.control_held), tok.color(.control_held) };
    for (&t, 0..) |*row, i| row.* = .{
        .fill = faces[i & 3],
        .border_color = if (i >= 4) tok.color(.accent) else .transparent,
        .border = if (i >= 4) tok.spaceAt(.xs) else 0,
    };
    return t;
}

/// `s` with the look of state `r` from `states`: one table load.
pub fn styled(s: Style, states: *const States, r: Response) Style {
    const l = states[stateBits(r)];
    var out = s;
    out.fill = l.fill;
    out.border_color = l.border_color;
    out.border = l.border;
    return out;
}

/// The widget theme of `tok`: every widget reads its look from this, so it is the only place
/// tokens meet widgets.
pub fn widgets(tok: *const Tokens) base.Theme {
    const states = controlStates(tok);
    return .{
        .text = tok.color(.text),
        .text_px = tok.textAt(.md),
        .panel = tok.color(.surface),
        .control = states[0].fill,
        .control_hot = states[1].fill,
        .control_held = states[2].fill,
        .accent = tok.color(.accent),
        .radius = tok.radiusAt(.md),
        .pad = tok.spaceAt(.lg),
        .gap = tok.spaceAt(.md),
    };
}

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;
const Input = @import("../core/input.zig").Input;

/// The theme switch test: the reference page (`widgets_base.Reference`) driven in theme `a` and
/// in theme `b` by the same script of hovers, clicks and drags, each aimed at last frame's rect
/// of its target so any layout is hit. In each theme both front ends must draw the same frames
/// (the harness checks). Across the two the behaviour must be the same and only the look follow
/// the theme: the same Reset state, checkbox and slider values in every frame, the Reset fill in
/// its own theme's colour, and every text run in its theme's text colour and size.
pub fn expectSwitch(comptime a: base.Theme, comptime b: base.Theme) !void {
    const ta = try trace(a);
    const tb = try trace(b);
    try testing.expectEqualSlices(u8, &ta.state, &tb.state);
    try testing.expectEqualSlices(bool, &ta.wire, &tb.wire);
    try testing.expectEqual(ta.clicks, tb.clicks);
    // A slider value is a position across its track, so it rounds with the track's geometry.
    for (ta.exposure, tb.exposure) |x, y| try testing.expectApproxEqAbs(x, y, 1e-5);
}

const frame_count = 12;

/// What the script did to the page, per frame, in theme-independent terms.
const Trace = struct {
    /// The row of `controlFills()` the Reset button was painted with (held and held-hot look
    /// alike, so held reads 2).
    state: [frame_count]u8,
    wire: [frame_count]bool,
    exposure: [frame_count]f32,
    clicks: u32,
};

fn trace(comptime th: base.Theme) !Trace {
    const R = base.Reference(th);
    const S = struct {
        var h: R.Run = .{};
    };
    const h = &S.h;
    h.init();
    var in: Input = .{ .viewport = .{ 400, 100 } };
    const Move = struct { target: ?[]const u8, along: f32 = 0.5, left: bool };
    const script = [frame_count]Move{
        .{ .target = null, .left = false }, // nothing laid out yet
        .{ .target = "reset", .left = false }, // hover
        .{ .target = "reset", .left = true }, // hold
        .{ .target = "reset", .left = false }, // click
        .{ .target = "wire", .left = true },
        .{ .target = "wire", .left = false }, // toggle on
        .{ .target = "exposure", .along = 0.75, .left = true }, // press at 75%
        .{ .target = "exposure", .along = 0.1, .left = true }, // drag to 10%
        .{ .target = "reset", .left = true }, // dragged off the track, still held
        .{ .target = "reset", .left = false }, // released over the button: no click
        .{ .target = "wire", .left = true },
        .{ .target = "wire", .left = false }, // toggle off
    };
    var tr: Trace = .{ .state = undefined, .wire = undefined, .exposure = undefined, .clicks = 0 };
    const fills = th.controlFills();
    var last: ?*const @import("../core/tree.zig").Tree = null;
    for (script, 0..) |step, k| {
        if (step.target) |name| {
            const r = last.?.rect(last.?.find(.hash(name)));
            in.pointer = .{ r.x0 + step.along * r.w(), (r.y0 + r.y1) * 0.5 };
        }
        in.buttons.left = step.left;
        const out = try h.frame(&in);
        const t = out.runtime.tree;
        last = t;
        const fill = t.c.look[t.find(.from("reset"))].fill;
        tr.state[k] = for (fills, 0..) |c, s| {
            if (c.bitsOf() == fill) break @intCast(s);
        } else return error.FillNotInTheme;
        tr.wire[k] = h.app.wireframe;
        tr.exposure[k] = h.app.exposure;
        tr.clicks += @intFromBool(h.app.clicked);
        const d = out.runtime.draw;
        for (d.runs[0..d.run_len]) |run| {
            try testing.expectEqual(th.text.bitsOf(), run.color);
            try testing.expectEqual(th.text_px, run.px);
        }
    }
    try testing.expectEqual(@as(u32, 1), tr.clicks);
    return tr;
}

test "Tokens: the defaults give the default widget theme" {
    try testing.expectEqual(base.Theme.default, widgets(&.{}));
}

test "Tokens: scales are non-decreasing" {
    const tok: Tokens = .{};
    for ([_]Scale{ tok.space, tok.radius, tok.text_size }) |s| {
        for (s[0 .. s.len - 1], s[1..]) |lo, hi| try testing.expect(lo <= hi);
    }
}

test "theme switch: other tokens restyle the reference page, behaviour unchanged" {
    const tok = comptime blk: {
        var t: Tokens = .{};
        t.palette[@backingInt(Role.control)] = .rgb(200, 200, 205);
        t.palette[@backingInt(Role.control_hot)] = .rgb(180, 180, 190);
        t.palette[@backingInt(Role.control_held)] = .rgb(160, 160, 170);
        t.palette[@backingInt(Role.text)] = .rgb(20, 20, 20);
        t.text_size = .{ 12, 14, 16, 20, 28 };
        t.space = .{ 2, 4, 8, 12, 16 };
        break :blk t;
    };
    try expectSwitch(widgets(&.{}), comptime widgets(&tok));
}

test "States: indexed by hovered | held << 1 | focused << 2" {
    try testing.expectEqual(@as(u3, 0), stateBits(.{ .pressed = true, .clicked = true, .released = true }));
    try testing.expectEqual(@as(u3, 1), stateBits(.{ .hovered = true }));
    try testing.expectEqual(@as(u3, 2), stateBits(.{ .held = true }));
    try testing.expectEqual(@as(u3, 4), stateBits(.{ .focused = true }));
    try testing.expectEqual(@as(u3, 7), stateBits(.{ .hovered = true, .held = true, .focused = true }));
    const tok: Tokens = .{};
    const t = controlStates(&tok);
    const th = widgets(&tok);
    // Rows 0 to 3 are the widget theme's state colours; focus only adds the outline.
    for (th.controlFills(), t[0..4], t[4..8]) |c, plain, focused| {
        try testing.expectEqual(c, plain.fill);
        try testing.expectEqual(c, focused.fill);
        try testing.expectEqual(@as(f32, 0), plain.border);
        try testing.expectEqual(tok.color(.accent), focused.border_color);
        try testing.expectEqual(tok.spaceAt(.xs), focused.border);
    }
    const s = styled(base.buttonStyle(&th), &t, .{ .held = true, .focused = true });
    try testing.expectEqual(th.control_held, s.fill);
    try testing.expectEqual(@as(f32, 2), s.border);
    try testing.expectEqual(th.pad, s.pad[0]);
}

test "theme switch: state tables from other tokens restyle every state" {
    const tok = comptime blk: {
        var t: Tokens = .{};
        t.palette[@backingInt(Role.control)] = .rgb(10, 20, 30);
        t.palette[@backingInt(Role.control_hot)] = .rgb(40, 50, 60);
        t.palette[@backingInt(Role.control_held)] = .rgb(70, 80, 90);
        break :blk t;
    };
    const t = comptime controlStates(&tok);
    try testing.expectEqual(Color.rgb(40, 50, 60), t[stateBits(.{ .hovered = true })].fill);
    try expectSwitch(widgets(&.{}), comptime widgets(&tok));
}

/// WCAG 2 contrast ratio of two opaque colours, 1 to 21.
fn contrast(a: Color, b: Color) f32 {
    const la = luminance(a) + 0.05;
    const lb = luminance(b) + 0.05;
    return @max(la, lb) / @min(la, lb);
}

fn luminance(c: Color) f32 {
    const ch = [3]u8{ c.r, c.g, c.b };
    const w = [3]f32{ 0.2126, 0.7152, 0.0722 };
    var l: f32 = 0;
    for (ch, w) |v, k| {
        const x = @as(f32, @floatFromInt(v)) / 255;
        l += k * if (x <= 0.04045) x / 12.92 else std.math.pow(f32, (x + 0.055) / 1.055, 2.4);
    }
    return l;
}

test "light, dark: text is readable on every surface it sits on" {
    for ([_]Tokens{ dark, light }) |tok| {
        // WCAG AA for body text: 4.5:1, on panels and on every control face.
        for ([_]Role{ .surface, .control, .control_hot, .control_held }) |bg| {
            try testing.expect(contrast(tok.color(.text), tok.color(bg)) >= 4.5);
        }
        // Non-text contrast (WCAG 1.4.11, 3:1): a checked box and a slider's fill against the
        // track, and the focus outline against the panel.
        try testing.expect(contrast(tok.color(.accent), tok.color(.control)) >= 3);
        try testing.expect(contrast(tok.color(.accent), tok.color(.surface)) >= 3);
    }
    try testing.expectEqual(base.Theme.default, widgets(&dark));
    try testing.expectApproxEqAbs(@as(f32, 21), contrast(.black, .white), 1e-3);
}

test "theme switch: dark to light and back" {
    try expectSwitch(comptime widgets(&dark), comptime widgets(&light));
    try expectSwitch(comptime widgets(&light), comptime widgets(&dark));
}
