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

/// The widget theme of `tok`: every widget reads its look from this, so it is the only place
/// tokens meet widgets.
pub fn widgets(tok: *const Tokens) base.Theme {
    return .{
        .text = tok.color(.text),
        .text_px = tok.textAt(.md),
        .panel = tok.color(.surface),
        .control = tok.color(.control),
        .control_hot = tok.color(.control_hot),
        .control_held = tok.color(.control_held),
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
