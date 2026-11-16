//! Switch: an on/off control drawn as a knob on a track, with a caption. Tier 2, written
//! against the public API of tiers 0 and 1 (the recipe in base.zig). It is a checkbox in
//! behaviour (a click or Space flips it) and a different thing to assistive technology: it
//! reports on and off, not checked.
//!
//! Accessibility: role switch, named by its caption, value 1 on and 0 off; a11y/tree.zig
//! `states` sets `checked` from it, which a bridge reports as on (AccessKit `Toggled`, ARIA
//! `aria-checked` on a switch).
//!
//! State: the application's `bool`. The runtime front end takes a pointer to it; the comptime
//! front end binds a `bool` field, checked while compiling. The caption is a bound label.
//!
//! Not animated: the knob jumps. `Frame.animate` (prototype/ui.zig) is the anim lane's, which
//! has not landed; the knob's side is one table index, so easing it later is one call.

const std = @import("std");
const base = @import("base.zig");
const label_zig = @import("label.zig");
const checkbox_zig = @import("checkbox.zig");
const types = @import("../core/types.zig");
const spec_zig = @import("../comptime/spec.zig");
const Spec = spec_zig.Spec;
const Theme = base.Theme;
const Id = types.Id;
const Style = types.Style;
const Color = types.Color;
const Response = types.Response;
const Frame = @import("../runtime/frame.zig").Frame;
const Input = @import("../core/input.zig").Input;
const simd = @import("../core/simd.zig");
const Tree = @import("../core/tree.zig").Tree;
const a11y = @import("../a11y/tree.zig");

// ---- spec -----------------------------------------------------------------------------------

/// The type of a switch's bound field.
pub const Bind = bool;

/// Why `State`'s field `name` cannot be a switch's value, or null when it can.
pub fn bindError(comptime State: type, comptime name: []const u8) ?[]const u8 {
    return base.fieldError(State, "switch", name, Bind);
}

// ---- look -----------------------------------------------------------------------------------

/// The row: track, then caption, centred across, `gap` apart.
pub fn switchStyle(th: *const Theme) Style {
    return .{ .dir = .x, .gap = th.gap, .cross = .center };
}

/// The 32 x 18 pill. Off: the control colour, knob at the start; on: the accent, knob at the
/// end. Both picked by table index from the value.
pub fn trackStyle(th: *const Theme, on: bool) Style {
    const fills = [2]Color{ th.control, th.accent };
    const sides = [2]types.Align{ .start, .end };
    const k = @intFromBool(on);
    return .{ .dir = .x, .size = .{ .px(32), .px(18) }, .pad = @splat(2), .radius = 9, .fill = fills[k], .main = sides[k], .cross = .center };
}

/// The 14 px knob, in the text colour.
pub fn knobStyle(th: *const Theme) Style {
    return .{ .size = .{ .px(14), .px(14) }, .radius = 7, .fill = th.text };
}

// ---- runtime front end ----------------------------------------------------------------------

/// A switch named `id` over `value`, captioned by `str`. A click, or Space while it has
/// focus, flips it (WAI-ARIA APG switch pattern; `checkbox.toggled`) and sets `clicked`.
pub fn @"switch"(f: *Frame, th: *const Theme, id: Id, value: *bool, str: []const u8) Response {
    const row = f.open(id, switchStyle(th));
    var r = f.interact(row, .button);
    r.clicked = checkbox_zig.toggled(r.clicked, r.focused, f.in);
    value.* = base.toggle(value.*, r.clicked);
    _ = f.open(.none, trackStyle(th, value.*));
    _ = f.leaf(.none, knobStyle(th));
    f.close();
    _ = label_zig.label(f, th, str);
    f.close();
    expose(f.tree(), row.ix(), value.*);
    return r;
}

/// Writes what assistive technology reads of the switch at tree row `row`: role switch (past
/// `types.Role`, so written to the column directly) and the value, 1 on and 0 off. Both front
/// ends call it.
pub fn expose(t: *Tree, row: u32, on: bool) void {
    t.c.role[row] = @backingInt(a11y.Role.@"switch");
    t.c.value[row] = simd.b2f(on);
}

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// A switch named `id` over the `bool` field `bind`, captioned by the string field `text`:
    /// `ct.@"switch"(th, .vsync, .vsync, .vsync_text)`.
    pub fn @"switch"(comptime th: Theme, comptime id: @EnumLiteral(), comptime bind: @EnumLiteral(), comptime text: @EnumLiteral()) Spec {
        // Track (with its knob), caption: the rows the front ends push, in spec order.
        const track: Spec = .{ .kind = .col, .children = &.{Spec{ .kind = .col }} };
        var s = spec_zig.row(switchStyle(&th), .{ track, label_zig.ct.label(th, text) });
        s.kind = .@"switch";
        s.id = @tagName(id);
        s.bind = @tagName(bind);
        return s;
    }
};

// ---- example page -------------------------------------------------------------------------

/// The switch's example page: VSync, HDR (on) and Bloom on a panel, in both front ends. Its
/// replay (testdata/switch.replay) clicks and uses Space; its golden images
/// (tools/widgetgolden/ref/switch-*.png) show the knobs moving.
pub const Page = struct {
    const th = Theme.default;
    const panel: Style = .{ .dir = .y, .size = .{ .fill, .fill }, .pad = @splat(12), .gap = 8, .fill = th.panel };

    pub const App = struct {
        vsync: bool = false,
        hdr: bool = true,
        bloom: bool = false,
        pub fn build(app: *App, f: *Frame) void {
            _ = f.open(.from("panel"), panel);
            _ = @"switch"(f, &th, .from("vsync"), &app.vsync, "VSync");
            _ = @"switch"(f, &th, .from("hdr"), &app.hdr, "HDR");
            _ = @"switch"(f, &th, .from("bloom"), &app.bloom, "Bloom");
            f.close();
        }
    };
    pub const State = struct {
        vsync: bool = false,
        vsync_text: []const u8 = "VSync",
        hdr: bool = true,
        hdr_text: []const u8 = "HDR",
        bloom: bool = false,
        bloom_text: []const u8 = "Bloom",
    };
    pub const spec = spec_zig.col(panel, .{
        ct.@"switch"(th, .vsync, .vsync, .vsync_text),
        ct.@"switch"(th, .hdr, .hdr, .hdr_text),
        ct.@"switch"(th, .bloom, .bloom, .bloom_text),
    });
    pub const Ui = base.ComptimeUi(State, spec, th);
    pub const Run = base.Harness(App, Ui, .{ .nodes = 32, .texts = 4, .customs = 1, .strings = 256, .depth = 8 });
    pub const replay = @embedFile("testdata/switch.replay");
    /// Frames kept as golden images, by name: tools/widgetgolden/ref/switch-<name>.png.
    pub const golden_frames = .{ .{ "rest", 0 }, .{ "on", 2 }, .{ "flipped", 6 } };
};

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

test "bindError: a switch binds a bool" {
    const State = struct { on: bool = false, n: u32 = 0 };
    try testing.expectEqual(null, comptime bindError(State, "on"));
    try testing.expectEqualStrings("switch 'n' needs a bool field, not u32", comptime bindError(State, "n").?);
}

test "ct.switch: a named, focusable widget with a void event: track, knob and caption rows" {
    const events = @import("../comptime/events.zig");
    const s = comptime ct.@"switch"(.default, .vsync, .vsync, .vsync_text);
    try testing.expectEqual(spec_zig.Kind.@"switch", s.kind);
    try testing.expectEqualStrings("vsync", s.id.?);
    try testing.expectEqualStrings("vsync", s.bind.?);
    try testing.expectEqual(@as(usize, 2), s.children.len);
    try testing.expectEqual(@as(usize, 1), s.children[0].children.len);
    try testing.expectEqualStrings("vsync_text", s.children[1].bind.?);
    const E = events.Events(s);
    try testing.expectEqual(void, @FieldType(E.Event, "vsync"));
    try testing.expectEqualSlices(E.Widget, &.{.vsync}, E.focus_order);
}

/// Two switches, off and on, in both front ends, in theme `th`: the tests' page until the
/// example page (C0560).
fn Two(comptime th: Theme) type {
    return struct {
        const col: Style = .{ .dir = .y, .pad = @splat(8), .gap = 8 };
        pub const App = struct {
            vsync: bool = false,
            hdr: bool = true,
            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.from("col"), col);
                _ = @"switch"(f, &th, .from("vsync"), &app.vsync, "VSync");
                _ = @"switch"(f, &th, .from("hdr"), &app.hdr, "HDR");
                f.close();
            }
        };
        pub const State = struct { vsync: bool = false, vsync_text: []const u8 = "VSync", hdr: bool = true, hdr_text: []const u8 = "HDR" };
        pub const Ui = base.ComptimeUi(State, spec_zig.col(col, .{ ct.@"switch"(th, .vsync, .vsync, .vsync_text), ct.@"switch"(th, .hdr, .hdr, .hdr_text) }), th);
        pub const Run = base.Harness(App, Ui, .{ .nodes = 16, .texts = 4, .customs = 1, .strings = 256, .depth = 8 });
    };
}

var two: Two(.default).Run = .{};

test "switch look: the knob at the start when off, at the end when on; the track's fill by value, in both front ends" {
    const h = &two;
    h.init();
    const th = Theme.default;
    const in: Input = .{ .viewport = .{ 200, 100 } };
    const out = try h.frame(&in);
    const t = out.runtime.tree;
    // Rows: root, column, then per switch: row, track, knob, caption.
    for ([2]u32{ 2, 6 }, [2]bool{ false, true }) |row, on| {
        const track = t.rect(row + 1);
        try testing.expectEqual([2]f32{ 32, 18 }, [2]f32{ track.w(), track.h() });
        const knob = t.rect(row + 2);
        try testing.expectEqual([2]f32{ 14, 14 }, [2]f32{ knob.w(), knob.h() });
        try testing.expectEqual(if (on) track.x1 - 16 else track.x0 + 2, knob.x0);
        try testing.expectEqual(track.y0 + 2, knob.y0);
        try testing.expectEqual(track.x1 + th.gap, t.rect(row + 3).x0);
        try testing.expectEqual((if (on) th.accent else th.control).bitsOf(), t.c.look[row + 1].fill);
        try testing.expectEqual(th.text.bitsOf(), t.c.look[row + 2].fill);
    }
}

test "switch look: theme tokens reach both front ends" {
    const S = struct {
        var h: Two(.{ .accent = .rgb(3, 4, 5), .text = .rgb(6, 7, 8), .gap = 1 }).Run = .{};
    };
    S.h.init();
    const in: Input = .{ .viewport = .{ 200, 100 } };
    const out = try S.h.frame(&in);
    const t = out.runtime.tree;
    try testing.expectEqual(Color.rgb(3, 4, 5).bitsOf(), t.c.look[7].fill);
    try testing.expectEqual(Color.rgb(6, 7, 8).bitsOf(), t.c.look[4].fill);
    try testing.expectEqual(t.rect(3).x1 + 1, t.rect(5).x0);
}

test "switch input: click and Space flip it, Enter and Space down do not, in both front ends" {
    const h = &two;
    h.init();
    const k = base.keys;
    var in: Input = .{ .viewport = .{ 200, 100 } };
    var out = try h.frame(&in);
    const t = out.runtime.tree;
    const vs = t.rect(t.find(.from("vsync")));
    const hd = t.rect(t.find(.from("hdr")));
    const up = [_]Input.Event{.{ .kind = .release, .code = k.space }};
    const down = [_]Input.Event{.{ .kind = .press, .code = k.space }};
    const enter = [_]Input.Event{.{ .kind = .press, .code = k.enter }};
    const Step = struct { at: types.Rect, left: bool = false, events: []const Input.Event = &.{}, vsync: bool, hdr: bool };
    const steps = [_]Step{
        .{ .at = vs, .left = true, .vsync = false, .hdr = true },
        .{ .at = vs, .vsync = true, .hdr = true }, // click
        .{ .at = vs, .events = &down, .vsync = true, .hdr = true },
        .{ .at = vs, .events = &up, .vsync = false, .hdr = true }, // Space
        .{ .at = vs, .events = &enter, .vsync = false, .hdr = true },
        .{ .at = hd, .left = true, .vsync = false, .hdr = true },
        .{ .at = hd, .vsync = false, .hdr = false }, // click the other
        .{ .at = hd, .events = &up, .vsync = false, .hdr = true },
    };
    for (steps) |st| {
        in.pointer = .{ (st.at.x0 + st.at.x1) * 0.5, (st.at.y0 + st.at.y1) * 0.5 };
        in.buttons.left = st.left;
        in.events = st.events;
        out = try h.frame(&in);
        try testing.expectEqual(st.vsync, h.app.vsync);
        try testing.expectEqual(st.hdr, h.app.hdr);
        try testing.expectEqual(st.vsync, h.ui.signals.state.vsync);
        try testing.expectEqual(st.hdr, h.ui.signals.state.hdr);
        try testing.expectEqual(simd.b2f(st.vsync), out.runtime.tree.c.value[2]);
    }
}

var switch_semantics: base.Semantic(16) = .{};

test "switch a11y: role switch, named by its caption, on as value and checked, in both front ends" {
    const h = &two;
    h.init();
    const in: Input = .{ .viewport = .{ 200, 100 } };
    _ = try h.frame(&in);
    const x = &switch_semantics;
    try x.run(h);
    const checked = a11y.State.bitsOf(.{ .checked = true });
    for ([2]u32{ 2, 6 }, [2][]const u8{ "VSync", "HDR" }, [2]bool{ false, true }) |node, name, on| {
        const r = x.row(node).?;
        try testing.expectEqual(@backingInt(a11y.Role.@"switch"), x.out[0].c.role[r]);
        try testing.expectEqualStrings(name, x.name(0, r));
        try testing.expectEqualStrings(name, x.name(1, r));
        try testing.expectEqual(simd.b2f(on), x.out[0].c.value[r]);
        try testing.expectEqual(if (on) checked else 0, x.out[0].c.state[r]);
    }
    // Track and knob are presentational: the root, two switches, two captions.
    try testing.expectEqual(@as(u32, 5), x.out[0].len);
}

var page: Page.Run = .{};

test "Page: the switch replay flips by click and Space, in both front ends" {
    const Replay = @import("../core/input.zig").Replay;
    const h = &page;
    h.init();
    var text: [16]u8 = undefined;
    var evs: [8]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &evs, .contacts = &contacts };
    var replay: Replay = .{ .src = Page.replay };
    var vsync: [12]bool = undefined;
    var hdr: [12]bool = undefined;
    var bloom: [12]bool = undefined;
    while (try replay.next(buf)) |in| {
        const k = h.frames;
        _ = try h.frame(in);
        const st = &h.ui.signals.state;
        try testing.expectEqual(h.app.vsync, st.vsync);
        try testing.expectEqual(h.app.hdr, st.hdr);
        try testing.expectEqual(h.app.bloom, st.bloom);
        vsync[k] = h.app.vsync;
        hdr[k] = h.app.hdr;
        bloom[k] = h.app.bloom;
    }
    try testing.expectEqual(@as(u32, 12), h.frames);
    try testing.expectEqualSlices(bool, &.{ false, false, true, false, false, false, false, false, false, false, false, false }, &vsync);
    try testing.expectEqualSlices(bool, &.{ true, true, true, true, true, true, false, false, true, true, true, true }, &hdr);
    const never: [12]bool = @splat(false);
    try testing.expectEqualSlices(bool, &never, &bloom);
    // The rects the replay's comment gives.
    const t = &h.ctx.trees[h.ctx.cur];
    for ([3][]const u8{ "vsync", "hdr", "bloom" }, [3]f32{ 12, 38, 64 }) |name, y| {
        const row = t.find(.hash(name));
        try testing.expectEqual([2]f32{ y, y + 18 }, [2]f32{ t.rect(row).y0, t.rect(row).y1 });
        try testing.expectEqual([2]f32{ 12, 44 }, [2]f32{ t.rect(row + 1).x0, t.rect(row + 1).x1 });
    }
    inline for (Page.golden_frames) |g| try testing.expect(g[1] < 12);
}

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(ct);
}
