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
const simd = @import("../core/simd.zig");
const DrawList = @import("../draw/draw_list.zig").DrawList;
const spec_zig = @import("../comptime/spec.zig");
const quad_shader = @import("../render/shaders/quad.zig");
const Tree = @import("../core/tree.zig").Tree;
const Texts = @import("../core/texts.zig").Texts;
const Mono = @import("../text/protocol.zig").Mono;
const layout = @import("../layout/layout.zig");
const runtime_frame = @import("../runtime/frame.zig");
const Output = @import("../runtime/context.zig").Output;
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

/// The tokens that follow the platform's appearance (`Input.appearance`): `dark` or `light`,
/// with the system's accent for checked boxes, slider fills and focus when it gives one.
pub fn forAppearance(a: @import("../core/input.zig").Input.Appearance) Tokens {
    var tok = if (a.dark) dark else light;
    if (a.accent.a != 0) tok.palette[@backingInt(Role.accent)] = a.accent;
    return tok;
}

/// How tightly controls pack: a factor on the space scale. Text sizes and radii stay, so a
/// denser theme fits more controls without smaller type.
pub const Density = enum(u8) { compact, comfortable, spacious };

const density_factor = [3]f32{ 0.75, 1, 1.25 };

/// `tok` at density `d`: each space step scaled and rounded to whole pixels, so edges stay on
/// the pixel grid. `comfortable` is `tok` unchanged.
pub fn dense(tok: Tokens, d: Density) Tokens {
    var out = tok;
    const k: @Vector(step_count, f32) = @splat(density_factor[@backingInt(d)]);
    const v: @Vector(step_count, f32) = tok.space;
    const r: @Vector(step_count, f32) = @round(v * k);
    out.space = r;
    return out;
}

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

// ---- per-widget overrides ---------------------------------------------------------------------

/// `th` with the fields of `patch` replaced: `override(th, .{ .accent = red, .pad = 12 })`. Pass
/// the result to one widget to restyle that widget alone; the theme is a value, so an override
/// is a copy, with nothing registered and nothing to undo. A field `base.Theme` lacks is a
/// compile error.
pub fn override(th: base.Theme, patch: anytype) base.Theme {
    var out = th;
    inline for (@typeInfo(@TypeOf(patch)).@"struct".field_names) |name| @field(out, name) = @field(patch, name);
    return out;
}

// ---- custom material example -------------------------------------------------------------------

/// An example custom material (sheen.wgsl): a themed surface lit from above. Like every user
/// material it is one WGSL `fn material(in: Frag) -> vec4f`; the renderer's quad shader wraps it
/// (`quad_shader.shader`), the back end compiles it once (`quad_shader.Materials.add`, which
/// hands back the `Material`), and a node opts in through `Style.material` and `Style.params`.
/// The colour still comes from the theme's tokens, so the material follows a theme switch.
pub const sheen_wgsl = @embedFile("sheen.wgsl");

/// The full quad shader for the sheen material, ready for `Materials.add`.
pub const sheen_shader = quad_shader.shader(sheen_wgsl);

/// `s` drawn with sheen material `m` (the handle `Materials.add(sheen_shader)` returned),
/// lifted toward white by `strength`, 0 to 1, at its top edge.
pub fn sheen(s: Style, m: types.Material, strength: f32) Style {
    var out = s;
    out.material = m;
    out.params = .{ strength, 0, 0, 0 };
    return out;
}

// ---- comptime themes ------------------------------------------------------------------------

/// Theme `tok` at density `d`, folded into constants: the widget theme and the state table are
/// computed by the compiler and land in read-only data, as the comptime front end's flatten
/// tables do (prototype/comptime_ui_probe.zig). Nothing is derived per frame; picking a look is
/// one load from `states`. `theme` is what `ComptimeUi(State, spec, theme)` and the `ct`
/// builders take.
pub fn Folded(comptime tok: Tokens, comptime d: Density) type {
    return struct {
        pub const tokens: Tokens = dense(tok, d);
        pub const theme: base.Theme = widgets(&tokens);
        pub const states: States = controlStates(&tokens);

        /// The look of state `r`: one load from the folded table.
        pub fn look(r: Response) Look {
            return states[stateBits(r)];
        }
    };
}

pub const Dark = Folded(dark, .comfortable);
pub const Light = Folded(light, .comfortable);

// ---- run-time switching -----------------------------------------------------------------------

/// The stock palettes, by index: what a run-time theme switch picks from. An application keeps
/// its own table the same way and stores only the index.
pub const palettes = [_]Palette{ dark_palette, light_palette };

/// `tok` with palette `p`: switching theme at run time is swapping the palette, sizes stay.
/// The runtime front end rebuilds every frame, so the next frame built with `widgets` of the
/// result is in the new theme.
pub fn withPalette(tok: Tokens, p: Palette) Tokens {
    var out = tok;
    out.palette = p;
    return out;
}

/// Switches a frame painted in palette `from` to palette `to` without rebuilding it: each quad
/// fill and outline and each text colour that is `from[role]` becomes `to[role]`. This is how a
/// comptime UI, whose theme is fixed when it is compiled, changes theme at run time: paint as
/// usual, then recolor its draw list by palette index. Colours not in `from` (transparent,
/// custom fills) are left alone. `from`'s colours must be distinct, or a role is ambiguous.
pub fn recolor(d: *DrawList, from: *const Palette, to: *const Palette) void {
    for (d.quads[0..d.quad_len]) |*q| {
        q.fill = remap(q.fill, from, to);
        q.border_color = remap(q.border_color, from, to);
    }
    for (d.runs[0..d.run_len]) |*r| r.color = remap(r.color, from, to);
}

/// `c` through the palette map, as selects over every role; each compares the original `c`, so
/// a colour already mapped is never mapped again.
inline fn remap(c: u32, from: *const Palette, to: *const Palette) u32 {
    var out = c;
    inline for (0..role_count) |k| out = simd.selU(c == from[k].bitsOf(), to[k].bitsOf(), out);
    return out;
}

/// Whether `p`'s colours are distinct, which `recolor` needs of its `from`.
pub fn distinct(p: *const Palette) bool {
    for (p, 0..) |a, i| for (p[i + 1 ..]) |b| if (a.bitsOf() == b.bitsOf()) return false;
    return true;
}

// ---- inherited text --------------------------------------------------------------------------

/// Text colour and size a node hands down to its subtree: two caller-owned columns, one row per
/// tree row. 0 in a row means "the parent's"; row 0 (the root) holds the page's defaults. Each
/// frame: `clear`, set the root and any overrides, build, then `endInherited` (or `resolve`
/// before measuring text, in your own copy of `Frame.end`).
pub const Inherited = struct {
    /// `Color.bitsOf()`, 0 to inherit.
    color: []u32,
    /// Logical pixels, 0 to inherit.
    px: []f32,

    /// Every row inherits, and the root starts from `th`'s text.
    pub fn clear(in: Inherited, th: *const base.Theme) void {
        @memset(in.color, 0);
        @memset(in.px, 0);
        in.color[0] = th.text.bitsOf();
        in.px[0] = th.text_px;
    }

    /// Node `node`'s subtree takes colour `color` and size `px` (either 0 to keep inheriting).
    pub fn set(in: Inherited, node: types.Node, color: Color, px: f32) void {
        in.color[node.ix()] = color.bitsOf();
        in.px[node.ix()] = px;
    }

    /// Resolves the columns down `t` (rows are in push order, so a parent is final before its
    /// children read it), then gives each text run of `tx` that inherits (colour 0 or size 0)
    /// its node's resolved value. Run before text is measured: size changes layout.
    pub fn resolve(in: Inherited, t: *const Tree, tx: *Texts) void {
        const parent = t.c.parent;
        for (1..t.len) |i| {
            in.color[i] = simd.selU(in.color[i] == 0, in.color[parent[i]], in.color[i]);
            in.px[i] = simd.selF(in.px[i] == 0, in.px[parent[i]], in.px[i]);
        }
        for (0..tx.len) |r| {
            const n = tx.c.node[r];
            tx.c.color[r] = simd.selU(tx.c.color[r] == 0, in.color[n], tx.c.color[r]);
            tx.c.px[r] = simd.selF(tx.c.px[r] == 0, in.px[n], tx.c.px[r]);
        }
    }
};

/// `th` whose labels inherit their colour and size from the tree (`Inherited`) instead of
/// carrying the theme's: every widget's text follows, with no per-widget code.
pub fn inheriting(th: base.Theme) base.Theme {
    var out = th;
    out.text = .transparent;
    out.text_px = 0;
    return out;
}

/// `Frame.end` with `in.resolve` before text is measured.
pub fn endInherited(f: *runtime_frame.Frame, font: Mono, in: Inherited) Output {
    const t = f.tree();
    const tx = f.texts();
    t.seal(0);
    in.resolve(t, tx);
    font.measure(tx);
    layout.prepare(t);
    layout.applyText(t, tx, .x);
    layout.fit(t, .x);
    layout.resolve(t, .x, f.in.viewport[0]);
    layout.textAvail(t, tx);
    font.wrap(tx);
    layout.applyText(t, tx, .y);
    layout.fit(t, .y);
    layout.resolve(t, .y, f.in.viewport[1]);
    layout.place(t);
    layout.finalize(t);
    return f.finish();
}

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;
const Input = @import("../core/input.zig").Input;
const mem = @import("../core/mem.zig");
const context = @import("../runtime/context.zig");
const Frame = @import("../runtime/frame.zig").Frame;

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

test "dense: space scales and rounds, everything else stays" {
    try testing.expectEqual(dark, dense(dark, .comfortable));
    try testing.expectEqual(Scale{ 2, 3, 5, 6, 9 }, dense(dark, .compact).space);
    try testing.expectEqual(Scale{ 3, 5, 8, 10, 15 }, dense(dark, .spacious).space);
    const c = dense(light, .compact);
    try testing.expectEqual(light.palette, c.palette);
    try testing.expectEqual(light.text_size, c.text_size);
    try testing.expectEqual(light.radius, c.radius);
}

var density_buffer: [context.Context.requiredBytes(.{ .nodes = 16, .texts = 4, .customs = 1, .strings = 64, .depth = 4 })]u8 align(mem.column_align) = undefined;

test "theme switch: densities change the size of controls, not their behaviour" {
    inline for (.{ Density.compact, Density.spacious }) |d| {
        try expectSwitch(comptime widgets(&dark), comptime widgets(&dense(dark, d)));
    }
    // A button is its caption plus the `lg` pad on each side.
    var ctx = try context.Context.init(&density_buffer, .{ .nodes = 16, .texts = 4, .customs = 1, .strings = 64, .depth = 4 });
    const in: Input = .{ .viewport = .{ 400, 100 } };
    var widths: [3]f32 = undefined;
    for (&widths, [3]Density{ .compact, .comfortable, .spacious }) |*w, d| {
        const th = widgets(&dense(dark, d));
        var f = ctx.begin(&in);
        _ = base.button(&f, &th, .from("b"), "Go");
        const out = f.end(.{});
        w.* = out.tree.rect(out.tree.find(.from("b"))).w();
    }
    try testing.expectEqual(widths[1] - 2 * (8 - 6), widths[0]);
    try testing.expectEqual(widths[1] + 2 * (10 - 8), widths[2]);
}

test "Folded: comptime themes are constants" {
    // Every field is known to the compiler: these run at compile time or not at all.
    comptime {
        std.debug.assert(std.meta.eql(Dark.theme, base.Theme.default));
        std.debug.assert(Light.theme.panel.bitsOf() == light.color(.surface).bitsOf());
        std.debug.assert(Folded(dark, .compact).theme.pad == 6);
        std.debug.assert(std.meta.eql(Light.states, controlStates(&light)));
    }
    try testing.expectEqual(Light.theme.control_hot, Light.look(.{ .hovered = true }).fill);
    try testing.expectEqual(Light.theme.accent, Light.look(.{ .focused = true }).border_color);
}

test "theme switch: between folded themes" {
    try expectSwitch(Dark.theme, Light.theme);
    try expectSwitch(Light.theme, Folded(light, .compact).theme);
}

test "recolor: maps each role once, leaves other colours" {
    var quads: [3]@import("../draw/draw_list.zig").Quad = undefined;
    for (&quads) |*q| q.* = std.mem.zeroes(@TypeOf(q.*));
    quads[0].fill = dark_palette[2].bitsOf();
    quads[0].border_color = dark_palette[3].bitsOf();
    quads[1].fill = 0x1234_5678;
    // A map whose target is another role's source: still one step.
    const to: Palette = .{ dark_palette[2], dark_palette[0], dark_palette[1], dark_palette[3], dark_palette[4], dark_palette[5] };
    const twice: Palette = .{ dark_palette[0], dark_palette[0], dark_palette[1], dark_palette[3], dark_palette[4], dark_palette[5] };
    var d: DrawList = undefined;
    d.quads = &quads;
    d.quad_len = 2;
    d.run_len = 0;
    recolor(&d, &dark_palette, &to);
    try testing.expectEqual(dark_palette[1].bitsOf(), quads[0].fill);
    try testing.expectEqual(dark_palette[3].bitsOf(), quads[0].border_color);
    try testing.expectEqual(@as(u32, 0x1234_5678), quads[1].fill);
    try testing.expectEqual(@as(u32, 0), quads[1].border_color);
    for (&palettes) |*p| try testing.expect(distinct(p));
    try testing.expect(distinct(&to));
    try testing.expect(!distinct(&twice));
}

/// The comptime reference page in `Dark`, and the same page in the runtime front end built in
/// a theme chosen each frame (`widgets_base.Reference`'s App with the theme as a parameter).
const SwitchPage = struct {
    const limits = base.Reference(Dark.theme).page_limits;
    var buffer: [context.Context.requiredBytes(limits)]u8 align(mem.column_align) = undefined;
    var ui: base.Reference(Dark.theme).Ui = .{};

    const App = struct {
        wireframe: bool = false,
        exposure: f32 = 0.25,

        fn build(app: *App, f: *Frame, th: *const base.Theme) void {
            _ = f.open(.from("toolbar"), .{ .dir = .x, .size = .{ .fill, .fit }, .pad = @splat(8), .gap = 8, .cross = .center, .fill = th.panel });
            _ = base.button(f, th, .from("reset"), "Reset");
            _ = base.checkbox(f, th, .from("wire"), &app.wireframe, "Wireframe");
            _ = base.slider(f, th, .from("exposure"), &app.exposure, 0, 1);
            _ = base.label(f, th, "Layer 0");
            f.close();
        }
    };
};

test "theme switch: at run time, by palette index, in both front ends" {
    var ctx = try context.Context.init(&SwitchPage.buffer, SwitchPage.limits);
    const ui = &SwitchPage.ui;
    ui.* = .{};
    var app: SwitchPage.App = .{};
    var in: Input = .{ .viewport = .{ 400, 100 } };
    // The active palette changes every frame while the pointer moves across the toolbar and
    // clicks (the checkbox sits near x = 80).
    for (0..10) |k| {
        const active: u32 = @intCast(k % 2);
        in.pointer = .{ @floatFromInt(k * 20), 20 };
        in.buttons.left = k == 4;
        const th = widgets(&withPalette(dark, palettes[active]));
        var f = ctx.begin(&in);
        app.build(&f, &th);
        const rt = f.end(ui.font);
        // Comptime: compiled in Dark, recolored to the active palette.
        const cp = ui.frame(&in);
        recolor(&ui.tables.d, &palettes[0], &palettes[active]);
        try testing.expect(base.sameDraw(rt.draw, cp.draw));
        try testing.expectEqual(app.wireframe, ui.signals.state.wireframe);
        try testing.expectEqual(th.panel.bitsOf(), rt.draw.quads[0].fill);
    }
}

var inherit_buffer: [context.Context.requiredBytes(.{ .nodes = 32, .texts = 8, .customs = 1, .strings = 128, .depth = 6 })]u8 align(mem.column_align) = undefined;

test "theme switch: text colour and size inherit down the tree" {
    var ctx = try context.Context.init(&inherit_buffer, .{ .nodes = 32, .texts = 8, .customs = 1, .strings = 128, .depth = 6 });
    var color: [32]u32 = undefined;
    var px: [32]f32 = undefined;
    const inh: Inherited = .{ .color = &color, .px = &px };
    const in: Input = .{ .viewport = .{ 400, 200 } };
    const big = Color.rgb(200, 30, 30);
    for ([2]base.Theme{ Dark.theme, Light.theme }) |page| {
        // Widgets in an inheriting theme: their labels take the tree's text.
        const th = inheriting(page);
        inh.clear(&page);
        var f = ctx.begin(&in);
        _ = f.open(.from("panel"), .{ .gap = 4 });
        _ = base.label(&f, &th, "plain");
        _ = base.button(&f, &th, .from("b"), "Go");
        const header = f.open(.from("header"), .{});
        inh.set(header, big, 20);
        _ = base.label(&f, &th, "title");
        const sub = f.open(.from("sub"), .{});
        inh.set(sub, .transparent, 11); // size only: colour still from the header
        _ = base.label(&f, &th, "note");
        // A label with its own colour keeps it.
        _ = f.text("own", .{ .px = 13, .color = Color.white });
        f.close();
        f.close();
        f.close();
        const out = endInherited(&f, .{}, inh);
        const d = out.draw;
        try testing.expectEqual(@as(u32, 5), d.run_len);
        const want = [5]struct { u32, f32 }{
            .{ page.text.bitsOf(), page.text_px }, // plain: the page's
            .{ page.text.bitsOf(), page.text_px }, // the button's caption
            .{ big.bitsOf(), 20 }, // title: the header's
            .{ big.bitsOf(), 11 }, // note: header colour, own size
            .{ Color.white.bitsOf(), 13 }, // own
        };
        for (d.runs[0..5], want) |run, w| {
            try testing.expectEqual(w[0], run.color);
            try testing.expectEqual(w[1], run.px);
        }
        // Inherited size reaches layout: the 20 px title is laid out taller than the 11 px note.
        const title = d.runs[2].rect;
        const note = d.runs[3].rect;
        try testing.expect(title[3] - title[1] > note[3] - note[1]);
    }
}

/// One button in the theme, one with an override, in both front ends.
fn OverridePage(comptime th: base.Theme, comptime patch: anytype) type {
    const odd = override(th, patch);
    return struct {
        pub const App = struct {
            pub fn build(_: *App, f: *Frame) void {
                _ = f.open(.from("row"), .{ .dir = .x, .gap = 8 });
                _ = base.button(f, &th, .from("a"), "Same");
                _ = base.button(f, &odd, .from("b"), "Same");
                f.close();
            }
        };
        pub const State = struct { a_text: []const u8 = "Same", b_text: []const u8 = "Same" };
        pub const spec = spec_zig.row(.{ .gap = 8 }, .{ base.ct.button(th, .a, .a_text), base.ct.button(odd, .b, .b_text) });
        pub const Run = base.Harness(App, base.ComptimeUi(State, spec, th), .{ .nodes = 16, .texts = 4, .customs = 1, .strings = 64, .depth = 4 });
    };
}

test "theme switch: an override restyles one widget, in both front ends" {
    inline for (.{ Dark.theme, Light.theme }) |th| {
        const P = OverridePage(th, .{ .pad = 14, .radius = 0 });
        const S = struct {
            var h: P.Run = .{};
        };
        S.h.init();
        const in: Input = .{ .viewport = .{ 400, 100 } };
        const out = try S.h.frame(&in); // both front ends agree
        const t = out.runtime.tree;
        const a = t.rect(t.find(.from("a")));
        const b = t.rect(t.find(.from("b")));
        // Same caption; only b's pad (14 instead of 8) and radius (0) changed.
        // Edges snap to whole pixels, so widths agree to within one.
        try testing.expectApproxEqAbs(a.w() + 2 * 6, b.w(), 1);
        try testing.expectEqual(a.h() + 2 * 6, b.h());
        try testing.expectEqual(th.radius, t.c.look[t.find(.from("a"))].radius);
        try testing.expectEqual(@as(f32, 0), t.c.look[t.find(.from("b"))].radius);
    }
    // Colours too, in the runtime front end (its widgets take the whole theme per call).
    var ctx = try context.Context.init(&inherit_buffer, .{ .nodes = 32, .texts = 8, .customs = 1, .strings = 128, .depth = 6 });
    const in: Input = .{ .viewport = .{ 400, 100 } };
    const red = override(Dark.theme, .{ .control = Color.rgb(200, 0, 0), .text = Color.rgb(1, 2, 3) });
    var f = ctx.begin(&in);
    _ = base.button(&f, &Dark.theme, .from("a"), "A");
    _ = base.button(&f, &red, .from("b"), "B");
    const out = f.end(.{});
    const t = out.tree;
    try testing.expectEqual(Dark.theme.control.bitsOf(), t.c.look[t.find(.from("a"))].fill);
    try testing.expectEqual(Color.rgb(200, 0, 0).bitsOf(), t.c.look[t.find(.from("b"))].fill);
    try testing.expectEqual(Dark.theme.text.bitsOf(), out.draw.runs[0].color);
    try testing.expectEqual(Color.rgb(1, 2, 3).bitsOf(), out.draw.runs[1].color);
    try testing.expectEqual(Dark.theme, override(Dark.theme, .{}));
}

test "theme switch: a custom material keeps its handle and params, its colour follows the theme" {
    // What a back end does once at start-up: register the material, get its handle.
    var materials: quad_shader.Materials = .{};
    const m = materials.add(sheen_shader);
    try testing.expectEqual(@as(u16, 1), @backingInt(m));
    try testing.expectEqualStrings(sheen_shader, materials.source(m));
    try testing.expect(std.mem.endsWith(u8, sheen_shader, sheen_wgsl));

    var ctx = try context.Context.init(&inherit_buffer, .{ .nodes = 32, .texts = 8, .customs = 1, .strings = 128, .depth = 6 });
    const in: Input = .{ .viewport = .{ 400, 100 } };
    for ([2]base.Theme{ Dark.theme, Light.theme }) |th| {
        var f = ctx.begin(&in);
        _ = f.open(.from("bar"), sheen(.{ .dir = .x, .pad = @splat(th.pad), .fill = th.panel, .radius = th.radius }, m, 0.35));
        _ = base.button(&f, &th, .from("b"), "Go");
        f.close();
        const out = f.end(.{});
        const d = out.draw;
        // The bar is its own batch on the sheen pipeline; the button stays on the stock one.
        var seen = false;
        for (0..d.cmd_len) |i| switch (d.command(@intCast(i))) {
            .quads => |b| if (b.material == m) {
                try testing.expectEqual(@as(u32, 1), b.count);
                const q = d.quads[b.first];
                try testing.expectEqual(th.panel.bitsOf(), q.fill);
                try testing.expectEqual(@as(f32, 0.35), q.params[0]);
                seen = true;
            } else try testing.expectEqual(types.Material.solid, b.material),
            else => {},
        };
        try testing.expect(seen);
    }
}
