//! Radio group: a set of options of which exactly one is selected. Tier 2, written against
//! the public API of tiers 0 and 1 (the recipe in base.zig).
//!
//! State: the application's selection, a `u32` index into the options. The runtime front end
//! takes a pointer to it and the captions as a slice; the comptime front end binds a `u32`
//! field (checked while compiling) and takes the captions as a tuple of string fields, one
//! option per field. Each option is a widget of its own (a hit target and a focus stop), named
//! `<group>.<index>` in the comptime `Widget` enum and `group.with(index)` at run time.
//!
//! Accessibility: the group has role radio group, each option role radio, named by its
//! caption, value 1 when selected (a11y/tree.zig `states` sets `checked` from it). The group
//! has no accessible name yet: the ARIA pattern labels it by a heading, which these
//! front ends cannot point at (`Semantics.labelled_by` is the application's to set).

const std = @import("std");
const base = @import("base.zig");
const keys = @import("keys.zig");
const label_zig = @import("label.zig");
const types = @import("../core/types.zig");
const spec_zig = @import("../comptime/spec.zig");
const Spec = spec_zig.Spec;
const Theme = base.Theme;
const Id = types.Id;
const Style = types.Style;
const Color = types.Color;
const Response = types.Response;
const Tree = @import("../core/tree.zig").Tree;
const Frame = @import("../runtime/frame.zig").Frame;
const Input = @import("../core/input.zig").Input;
const simd = @import("../core/simd.zig");
const none = types.none;
const a11y = @import("../a11y/tree.zig");

// ---- spec -----------------------------------------------------------------------------------

/// The type of a radio group's bound field: the index of the selected option.
pub const Bind = u32;

/// Why `State`'s field `name` cannot hold a radio group's selection, or null when it can.
pub fn bindError(comptime State: type, comptime name: []const u8) ?[]const u8 {
    return base.fieldError(State, "radio group", name, Bind);
}

/// The id of option `index` of the group named `group`, in both front ends: the runtime front
/// end derives it with `Id.with`, the comptime one from the option's spec name.
pub fn optionId(group: Id, index: u32) Id {
    return group.with(index);
}

// ---- behaviour ------------------------------------------------------------------------------

/// What one frame's input does to a group's selection and focus.
pub const Step = struct { value: u32, focus: u32 };

/// The selection and focus of a group of `n` options after this frame's input, or null when
/// nothing changes them.
/// `clicked` is the option clicked and `focused` the option with focus (`none` for neither).
/// A click selects; with focus, Right and Down select the next option and Left and Up the
/// previous one, wrapping, and focus follows, and Space selects the focused option (WAI-ARIA
/// APG radio group pattern).
pub fn step(n: u32, clicked: u32, focused: u32, in: *const Input) ?Step {
    if (clicked != none) return .{ .value = clicked, .focus = clicked };
    if (focused == none) return null;
    const k = keys;
    const fwd = keys.keyCount(in, k.right, .press) + keys.keyCount(in, k.down, .press);
    const back = keys.keyCount(in, k.left, .press) + keys.keyCount(in, k.up, .press);
    const space = keys.keyCount(in, k.space, .release) != 0;
    if (fwd == back and !space) return null;
    // Moves count from the focused option; `n` * back keeps the sum from wrapping below 0.
    const to = (focused + fwd + (n - 1) * back) % n;
    return .{ .value = to, .focus = to };
}

// ---- look -----------------------------------------------------------------------------------

/// The group: options stacked, `gap` apart.
pub fn groupStyle(th: *const Theme) Style {
    return .{ .dir = .y, .gap = th.gap };
}

/// One option: ring, then caption, centred across, `gap` apart.
pub fn optionStyle(th: *const Theme) Style {
    return .{ .dir = .x, .gap = th.gap, .cross = .center };
}

/// The 16 px ring, outlined in the control's hot colour; it centres the dot.
pub fn ringStyle(th: *const Theme) Style {
    return .{ .size = .{ .px(16), .px(16) }, .radius = 8, .fill = th.control, .border = 1, .border_color = th.control_hot, .main = .center, .cross = .center };
}

/// The dot inside the ring, picked by table index from whether the option is selected:
/// transparent (it paints nothing) or the accent.
pub fn dotStyle(th: *const Theme, selected: bool) Style {
    const fills = [2]Color{ .transparent, th.accent };
    return .{ .size = .{ .px(8), .px(8) }, .radius = 4, .fill = fills[@intFromBool(selected)] };
}

/// Rows each option takes in the tree: the option, its ring, the dot, the caption.
pub const option_rows = 4;

// ---- runtime front end ----------------------------------------------------------------------

/// A radio group named `id` over `value`, the selected index, one option per caption. A
/// click, or the arrows and Space on the focused option, select (`step`); arrows move focus
/// along. The response is every option's, OR'd; `clicked` is set when the selection was
/// chosen this frame.
pub fn radio(f: *Frame, th: *const Theme, id: Id, value: *u32, captions: []const []const u8) Response {
    const group = f.open(id, groupStyle(th));
    var all: u8 = 0;
    var clicked: u32 = none;
    var focused: u32 = none;
    for (captions, 0..) |caption, i| {
        const o = f.open(optionId(id, @intCast(i)), optionStyle(th));
        const r = f.interact(o, .button);
        all |= @bitCast(r);
        clicked = simd.selU(r.clicked, @intCast(i), clicked);
        focused = simd.selU(r.focused, @intCast(i), focused);
        _ = f.open(.none, ringStyle(th));
        _ = f.leaf(.none, dotStyle(th, false));
        f.close();
        _ = label_zig.label(f, th, caption);
        f.close();
    }
    f.close();
    var r: Response = @bitCast(all);
    r.clicked = false;
    if (step(@intCast(captions.len), clicked, focused, f.in)) |s| {
        value.* = s.value;
        // Focus follows the arrows (the interaction state is the front end's public data).
        f.ctx.inter.focus = @backingInt(optionId(id, s.focus));
        r.clicked = true;
    }
    // The selection is final only now, so the dots and the value column are written after
    // every option has been asked: an option drawn before the one clicked shows it too.
    paintSelection(f.tree(), th, group.ix(), value.*, @intCast(captions.len));
    return r;
}

/// Writes the dots' fills, the options' value column (1 selected, 0 not) and the roles for
/// the group at tree row `group` with `n` options, selection `value`: the group is a radio
/// group and each option a radio, roles past `types.Role` written to the column directly.
/// Both front ends call it.
pub fn paintSelection(t: *Tree, th: *const Theme, group: u32, value: u32, n: u32) void {
    t.c.role[group] = @backingInt(a11y.Role.radio_group);
    for (0..n) |i| {
        const o = group + 1 + option_rows * @as(u32, @intCast(i));
        const on = value == i;
        t.c.look[o + 2].fill = dotStyle(th, on).fill.bitsOf();
        t.c.value[o] = simd.b2f(on);
        t.c.role[o] = @backingInt(a11y.Role.radio);
    }
}

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// A radio group named `id` selecting the `u32` field `bind`, one option per string field
    /// in `captions` (a tuple of enum literals): `ct.radio(th, .size, .size, .{ .s_text,
    /// .m_text, .l_text })`. An empty tuple is a compile error.
    pub fn radio(comptime th: Theme, comptime id: @EnumLiteral(), comptime bind: @EnumLiteral(), comptime captions: anytype) Spec {
        if (captions.len == 0) @compileError("radio group '" ++ @tagName(id) ++ "' needs at least one option");
        // Ring (with its dot), caption: the rows the front ends push, so rows keep spec order.
        const ring: Spec = .{ .kind = .col, .children = &.{Spec{ .kind = .col }} };
        var options: [captions.len]Spec = undefined;
        for (&options, captions, 0..) |*o, caption, i| {
            o.* = .{
                .kind = .row,
                .id = optionName(@tagName(id), i),
                .widget = base.FocusStop,
                .style = optionStyle(&th),
                .children = &.{ ring, label_zig.ct.label(th, caption) },
            };
        }
        const final = options;
        return .{
            .kind = .col,
            .bind = @tagName(bind),
            .style = groupStyle(&th),
            .children = &final,
            .widget = Comptime(@tagName(id), @tagName(bind), captions.len),
        };
    }
};

/// The comptime name of option `index` of the group named `group`.
fn optionName(comptime group: []const u8, comptime index: u32) [:0]const u8 {
    return std.fmt.comptimePrint("{s}.{d}", .{ group, index });
}

/// The comptime radio group named `name` over field `bind`, with `n` options (`Spec.widget`):
/// the same rows as `radio`, and the same input (`step`) applied to the comptime front end's
/// state and focus. A selection made by keys is reported as the new option's event, as a
/// click on it would be.
pub fn Comptime(comptime name: [:0]const u8, comptime bind: []const u8, comptime n: u32) type {
    return struct {
        pub const focusable = true;

        pub fn bindError(comptime State: type, comptime field: []const u8) ?[]const u8 {
            return base.fieldError(State, "radio group", field, Bind);
        }

        pub fn push(ui: anytype, comptime g: Spec, parent: u32, next: *u32, in: *const Input) void {
            const th = &@TypeOf(ui.*).theme;
            const t = &ui.tables.t;
            next.* += 1;
            const group = t.push(parent, .hash(name), &g.style);
            inline for (g.children, 0..) |o, i| {
                next.* += 3; // the option, its ring and the dot
                const row = t.push(group, optionId(.hash(name), i), &o.style);
                const ring = t.push(row, .none, &ringStyle(th));
                _ = t.push(ring, .none, &dotStyle(th, false));
                t.seal(ring);
                ui.push(o.children[1], row, next, in);
                t.seal(row);
            }
            t.seal(group);
            paintSelection(t, th, group, @field(ui.signals.state, bind), n);
        }

        pub fn step(ui: anytype, comptime row: u32, event: anytype, in: *const Input) @TypeOf(event) {
            const Ui = @TypeOf(ui.*);
            var clicked: u32 = none;
            var focused: u32 = none;
            inline for (0..n) |i| {
                const r = base.ctResponse(ui, row + 1 + option_rows * i, event, in);
                clicked = simd.selU(r.clicked, i, clicked);
                focused = simd.selU(r.focused, i, focused);
            }
            const s = step_(n, clicked, focused, in) orelse return null;
            ui.signals.set(Ui.field(bind), s.value);
            inline for (0..n) |i| {
                if (s.focus == i) {
                    const w = @field(Ui.Events.Widget, optionName(name, i));
                    ui.focus = w;
                    if (clicked == none) return @unionInit(Ui.Events.Event, optionName(name, i), {});
                }
            }
            return null;
        }
    };
}

const step_ = step;

// ---- example page -------------------------------------------------------------------------

/// The radio group's example page: three quality levels on a panel, in both front ends. Its
/// replay (testdata/radio.replay) clicks and uses the arrows; its golden images
/// (tools/widgetgolden/ref/radio-*.png) show the selection moving.
pub const Page = struct {
    const th = Theme.default;
    const panel: Style = .{ .dir = .y, .size = .{ .fill, .fill }, .pad = @splat(12), .fill = th.panel };

    pub const App = struct {
        quality: u32 = 1,
        pub fn build(app: *App, f: *Frame) void {
            _ = f.open(.from("panel"), panel);
            _ = radio(f, &th, .from("quality"), &app.quality, &.{ "Low", "Medium", "High" });
            f.close();
        }
    };
    pub const State = struct {
        quality: u32 = 1,
        low: []const u8 = "Low",
        medium: []const u8 = "Medium",
        high: []const u8 = "High",
    };
    pub const spec = spec_zig.col(panel, .{ct.radio(th, .quality, .quality, .{ .low, .medium, .high })});
    pub const Ui = base.ComptimeUi(State, spec, th);
    pub const Run = base.Harness(App, Ui, .{ .nodes = 32, .texts = 4, .customs = 1, .strings = 256, .depth = 8 });
    pub const replay = @embedFile("testdata/radio.replay");
    /// Frames kept as golden images, by name: tools/widgetgolden/ref/radio-<name>.png.
    pub const golden_frames = .{ .{ "rest", 0 }, .{ "clicked", 2 }, .{ "down", 3 } };
};

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

test "bindError: a radio group binds a u32" {
    const State = struct { size: u32 = 0, on: bool = false };
    try testing.expectEqual(null, comptime bindError(State, "size"));
    try testing.expectEqualStrings("radio group 'on' needs a u32 field, not bool", comptime bindError(State, "on").?);
}

test "ct.radio: one widget per option, named <group>.<index>; the group binds the field" {
    const events = @import("../comptime/events.zig");
    const s = comptime ct.radio(.default, .size, .size, .{ .s_text, .m_text, .l_text });
    try testing.expect(s.widget != null);
    try testing.expectEqual(null, s.id);
    try testing.expectEqualStrings("size", s.bind.?);
    try testing.expectEqual(@as(usize, 3), s.children.len);
    inline for (s.children, 0..) |o, i| {
        try testing.expectEqual(@as(usize, 2), o.children.len);
        try testing.expectEqualStrings(comptime optionName("size", i), o.id.?);
    }
    const E = events.Events(s);
    try testing.expectEqual(3, E.widget_count);
    // The group is row 0; option i is row 1 + 4i.
    try testing.expectEqual(@as(E.Index, 5), @backingInt(E.Widget.@"size.1"));
    try testing.expectEqual(void, @FieldType(E.Event, "size.1"));
}

test "optionId: options of one group are distinct and differ from the group's id" {
    const g = Id.from("size");
    try testing.expect(optionId(g, 0) != optionId(g, 1));
    try testing.expect(optionId(g, 0) != g);
    try testing.expectEqual(optionId(g, 2), g.with(2));
}

/// A three-option group in both front ends, in theme `th`: the tests' page until the example
/// page (C0555).
fn Sizes(comptime th: Theme) type {
    return struct {
        const col: Style = .{ .dir = .y, .pad = @splat(8) };
        pub const App = struct {
            size: u32 = 1,
            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.from("col"), col);
                _ = radio(f, &th, .from("size"), &app.size, &.{ "Small", "Medium", "Large" });
                f.close();
            }
        };
        pub const State = struct { size: u32 = 1, s: []const u8 = "Small", m: []const u8 = "Medium", l: []const u8 = "Large" };
        pub const Ui = base.ComptimeUi(State, spec_zig.col(col, .{ct.radio(th, .size, .size, .{ .s, .m, .l })}), th);
        pub const Run = base.Harness(App, Ui, .{ .nodes = 32, .texts = 4, .customs = 1, .strings = 256, .depth = 8 });
    };
}

var sizes: Sizes(.default).Run = .{};

test "radio look: options stacked, ring and caption in a row, the selected option's dot, in both front ends" {
    const h = &sizes;
    h.init();
    const th = Theme.default;
    const in: Input = .{ .viewport = .{ 200, 120 } };
    const out = try h.frame(&in);
    const t = out.runtime.tree;
    // Rows: root, column, group (2), then per option: option, ring, dot, caption.
    try testing.expectEqual(@as(u32, 3 + 3 * option_rows), t.len);
    var y: f32 = 8;
    for (0..3) |i| {
        const o: u32 = 3 + option_rows * @as(u32, @intCast(i));
        try testing.expectEqual(@backingInt(optionId(.from("size"), @intCast(i))), t.c.id[o]);
        const ring = t.rect(o + 1);
        try testing.expectEqual(@as(f32, 16), ring.w());
        try testing.expectEqual(types.Rect{ .x0 = ring.x0 + 4, .y0 = ring.y0 + 4, .x1 = ring.x0 + 12, .y1 = ring.y0 + 12 }, t.rect(o + 2));
        try testing.expectEqual(ring.x1 + th.gap, t.rect(o + 3).x0);
        try testing.expectApproxEqAbs(y, t.rect(o).y0, 1);
        y = t.rect(o).y1 + th.gap;
        const dot: Color = if (i == 1) th.accent else .transparent;
        try testing.expectEqual(dot.bitsOf(), t.c.look[o + 2].fill);
        try testing.expectEqual(th.control.bitsOf(), t.c.look[o + 1].fill);
    }
    // Quads: three rings and one dot.
    try testing.expectEqual(@as(u32, 4), out.runtime.draw.quad_len);
}

test "radio look: theme tokens reach both front ends" {
    const S = struct {
        var h: Sizes(.{ .accent = .rgb(9, 8, 7), .control = .rgb(1, 1, 1), .gap = 2 }).Run = .{};
    };
    S.h.init();
    const in: Input = .{ .viewport = .{ 200, 120 } };
    const out = try S.h.frame(&in);
    const t = out.runtime.tree;
    try testing.expectEqual(Color.rgb(9, 8, 7).bitsOf(), t.c.look[3 + option_rows + 2].fill);
    try testing.expectEqual(Color.rgb(1, 1, 1).bitsOf(), t.c.look[4].fill);
    try testing.expectEqual(t.rect(3).y1 + 2, t.rect(3 + option_rows).y0);
}

test "step: a click selects; arrows move from the focused option, wrapping; Space selects it" {
    const k = keys;
    const ev = struct {
        fn in(comptime list: []const Input.Event) Input {
            return .{ .events = list };
        }
    };
    const empty: Input = .{};
    try testing.expectEqual(Step{ .value = 2, .focus = 2 }, step(3, 2, none, &empty).?);
    try testing.expectEqual(null, step(3, none, none, &ev.in(&.{.{ .kind = .press, .code = k.down }})));
    try testing.expectEqual(null, step(3, none, 0, &empty));
    try testing.expectEqual(@as(u32, 1), step(3, none, 0, &ev.in(&.{.{ .kind = .press, .code = k.down }})).?.value);
    try testing.expectEqual(@as(u32, 1), step(3, none, 0, &ev.in(&.{.{ .kind = .press, .code = k.right }})).?.value);
    try testing.expectEqual(@as(u32, 2), step(3, none, 0, &ev.in(&.{.{ .kind = .press, .code = k.up }})).?.value);
    try testing.expectEqual(@as(u32, 0), step(3, none, 2, &ev.in(&.{.{ .kind = .repeat, .code = k.right }})).?.value);
    try testing.expectEqual(@as(u32, 2), step(3, none, 0, &ev.in(&.{ .{ .kind = .press, .code = k.down }, .{ .kind = .press, .code = k.down } })).?.value);
    // Focus on an unselected option (a Tab could put it there): Space selects it.
    try testing.expectEqual(Step{ .value = 1, .focus = 1 }, step(3, none, 1, &ev.in(&.{.{ .kind = .release, .code = k.space }})).?);
}

test "radio input: click selects, arrows move selection and focus, in both front ends" {
    const h = &sizes;
    h.init();
    const k = keys;
    var in: Input = .{ .viewport = .{ 200, 120 } };
    var out = try h.frame(&in);
    const t = out.runtime.tree;
    const opt = struct {
        fn at(tr: *const Tree, i: u32) [2]f32 {
            const r = tr.rect(3 + option_rows * i);
            return .{ (r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5 };
        }
    };
    const down = [_]Input.Event{.{ .kind = .press, .code = k.down }};
    const up = [_]Input.Event{.{ .kind = .press, .code = k.up }};
    const Step_ = struct { at: u32, left: bool = false, events: []const Input.Event = &.{}, value: u32, focus: u32 };
    const steps = [_]Step_{
        .{ .at = 2, .left = true, .value = 1, .focus = 2 }, // press: focus
        .{ .at = 2, .value = 2, .focus = 2 }, // click: Large
        .{ .at = 2, .events = &down, .value = 0, .focus = 0 }, // Down wraps to Small
        .{ .at = 2, .events = &up, .value = 2, .focus = 2 }, // Up wraps back
        .{ .at = 2, .events = &up, .value = 1, .focus = 1 },
    };
    for (steps) |st| {
        in.pointer = opt.at(t, st.at);
        in.buttons.left = st.left;
        in.events = st.events;
        out = try h.frame(&in);
        try testing.expectEqual(st.value, h.app.size);
        try testing.expectEqual(st.value, h.ui.signals.state.size);
        try testing.expectEqual(@backingInt(optionId(.from("size"), st.focus)), h.ctx.inter.focus);
        // Comptime widgets are spec rows: column 0, group 1, then option i at 2 + 4i.
        try testing.expectEqual(st.focus, (@as(u32, @backingInt(h.ui.focus.?)) - 2) / option_rows);
        for (0..3) |i| try testing.expectEqual(simd.b2f(i == st.value), out.runtime.tree.c.value[3 + option_rows * i]);
    }
}

var radio_semantics: base.Semantic(32) = .{};

test "radio a11y: a radio group of radios, named by their captions, the selected one checked, in both front ends" {
    const h = &sizes;
    h.init();
    const in: Input = .{ .viewport = .{ 200, 120 } };
    _ = try h.frame(&in);
    const x = &radio_semantics;
    try x.run(h);
    const g = x.row(2).?;
    try testing.expectEqual(@backingInt(a11y.Role.radio_group), x.out[0].c.role[g]);
    try testing.expectEqual(@backingInt(Id.from("size")), x.out[0].c.id[g]);
    const checked = a11y.State.bitsOf(.{ .checked = true });
    for (0..3, [3][]const u8{ "Small", "Medium", "Large" }) |i, name| {
        const r = x.row(3 + option_rows * @as(u32, @intCast(i))).?;
        try testing.expectEqual(@backingInt(a11y.Role.radio), x.out[0].c.role[r]);
        try testing.expectEqual(g, x.out[0].c.parent[r]);
        try testing.expectEqual(@backingInt(optionId(.from("size"), @intCast(i))), x.out[0].c.id[r]);
        try testing.expectEqualStrings(name, x.name(0, r));
        try testing.expectEqualStrings(name, x.name(1, r));
        try testing.expectEqual(simd.b2f(i == 1), x.out[0].c.value[r]);
        try testing.expectEqual(if (i == 1) checked else 0, x.out[0].c.state[r]);
    }
    // Ring and dot are presentational: the root, the group, three options and three captions.
    try testing.expectEqual(@as(u32, 8), x.out[0].len);
}

var page: Page.Run = .{};

test "Page: the radio replay selects by click and arrows, focus following, in both front ends" {
    const Replay = @import("../core/input.zig").Replay;
    const h = &page;
    h.init();
    var text: [16]u8 = undefined;
    var evs: [8]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &evs, .contacts = &contacts };
    var replay: Replay = .{ .src = Page.replay };
    var quality: [8]u32 = undefined;
    while (try replay.next(buf)) |in| {
        const k = h.frames;
        _ = try h.frame(in);
        try testing.expectEqual(h.app.quality, h.ui.signals.state.quality);
        quality[k] = h.app.quality;
    }
    try testing.expectEqual(@as(u32, 8), h.frames);
    try testing.expectEqualSlices(u32, &.{ 1, 1, 2, 0, 1, 2, 2, 2 }, &quality);
    try testing.expectEqual(@as(u32, 0), h.ctx.inter.focus);
    try testing.expectEqual(null, h.ui.focus);
    // The rects the replay's comment gives.
    const t = &h.ctx.trees[h.ctx.cur];
    for ([3][2]f32{ .{ 12, 30 }, .{ 36, 53 }, .{ 59, 77 } }, 0..) |y, i| {
        const r = t.rect(3 + option_rows * @as(u32, @intCast(i)));
        try testing.expectEqual(y, [2]f32{ r.y0, r.y1 });
        try testing.expectEqual([2]f32{ 12, 28 }, [2]f32{ t.rect(4 + option_rows * @as(u32, @intCast(i))).x0, t.rect(4 + option_rows * @as(u32, @intCast(i))).x1 });
    }
    inline for (Page.golden_frames) |g| try testing.expect(g[1] < 8);
}

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(ct);
}
