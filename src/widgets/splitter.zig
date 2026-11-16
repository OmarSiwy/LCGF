//! Splitter (tier 2): two panes side by side (or one above the other) with a handle between
//! them that moves the split. The split is application state: an `f32`, the first pane's
//! share of the container, 0 to 1. Written against the public API of tiers 0 and 1
//! (src/widgets/base.zig has the recipe).
//!
//! Runtime: `splitter.open(f, th, id, .x, &split)`, the first pane's children,
//! `splitter.handle(f, th, id, .x, split)`, the second pane's children, `splitter.close(f)`.
//! Comptime: `splitter.ct.splitter(th, .id, .x, .split, .{...first}, .{...second})`.

const std = @import("std");
const base = @import("base.zig");
const types = @import("../core/types.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const Input = @import("../core/input.zig").Input;
const spec_zig = @import("../comptime/spec.zig");
const Spec = spec_zig.Spec;
const Style = types.Style;
const Axis = types.Axis;
const Id = types.Id;
const Theme = base.Theme;
const simd = @import("../core/simd.zig");
const keys = @import("keys.zig");
const a11y = @import("../a11y/tree.zig");
const Tree = @import("../core/tree.zig").Tree;

/// How thick the handle is across the split, logical pixels.
pub const handle_px: f32 = 6;

// ---- spec ---------------------------------------------------------------------------------

/// Starts a splitter along `axis` (`.x`: panes side by side) whose first pane takes `split.*`
/// of it, and opens the first pane. `id` names the container; the handle is `id.with(1)`.
pub fn open(f: *Frame, th: *const Theme, id: Id, axis: Axis, split: *f32) void {
    // Input first, against last frame's container rect, so this frame shows the new split.
    const r = f.ctx.inter.response(id.with(1));
    split.* = resize(split.*, r.held, along(f.lastRect(id), axis, f.in.pointer), r.focused, f.in);
    _ = f.open(id, containerStyle(th, axis));
    _ = f.open(.none, firstStyle(th, axis, split.*));
}

/// Closes the first pane and opens the second: the handle, then the body that holds the
/// second pane's children.
pub fn handle(f: *Frame, th: *const Theme, id: Id, axis: Axis, split: f32) void {
    f.close();
    _ = f.open(.none, secondStyle(th, axis, split));
    const hd = f.leaf(id.with(1), handleStyle(th, axis));
    const r = f.interact(hd, .any);
    f.tree().c.role[hd.ix()] = role;
    f.tree().c.value[hd.ix()] = split;
    f.setFill(hd, handleFill(th, r));
    f.setCursor(cursors[@backingInt(axis)], r.hovered or r.held);
    _ = f.open(.none, bodyStyle(th));
}

/// Closes the second pane and the splitter.
pub fn close(f: *Frame) void {
    f.close();
    f.close();
    f.close();
}

/// The container: fills its parent, its panes laid along `axis`.
pub fn containerStyle(th: *const Theme, axis: Axis) Style {
    _ = th;
    return .{ .dir = axis, .size = .{ .fill, .fill } };
}

/// The first pane: `split` of the container along `axis`, the full container across.
pub fn firstStyle(th: *const Theme, axis: Axis, split: f32) Style {
    _ = th;
    const share = base.unit(split);
    const sizes = [2][2]types.Size{ .{ .pct(share), .fill }, .{ .fill, .pct(share) } };
    return .{ .dir = .y, .size = sizes[@backingInt(axis)], .clip = true };
}

/// The handle: `handle_px` along `axis`, the full container across, with rounded ends.
pub fn handleStyle(th: *const Theme, axis: Axis) Style {
    const sizes = [2][2]types.Size{ .{ .px(handle_px), .fill }, .{ .fill, .px(handle_px) } };
    return .{ .size = sizes[@backingInt(axis)], .radius = @min(th.radius, handle_px / 2) };
}

/// The handle's fill by interaction state (`base.stateIndex`): control at rest, control-hot
/// under the pointer, accent while dragged.
pub fn handleFill(th: *const Theme, r: types.Response) types.Color {
    const fills: base.StateColors = .{ th.control, th.control_hot, th.accent, th.accent };
    return fills[base.stateIndex(r)];
}

/// The pointer over the handle shows which way it moves, by axis.
pub const cursors = [2]@import("../runtime/context.zig").Cursor{ .resize_h, .resize_v };

/// The second pane: the rest of the container, `1 - split`, holding the handle at its start
/// and then the body. Both panes are percentages of the container, so they always add up to
/// it exactly whatever their contents (a grower would start from its content's size).
pub fn secondStyle(th: *const Theme, axis: Axis, split: f32) Style {
    _ = th;
    const rest = 1 - base.unit(split);
    const sizes = [2][2]types.Size{ .{ .pct(rest), .fill }, .{ .fill, .pct(rest) } };
    return .{ .dir = axis, .size = sizes[@backingInt(axis)] };
}

/// The body of the second pane: what the handle leaves of it. It shrinks below its content
/// (a grower starts from its content's size), so a nearly closed pane shows nothing.
pub fn bodyStyle(th: *const Theme) Style {
    _ = th;
    return .{ .dir = .y, .size = .{ .fill, .fill }, .clip = true, .shrink = true };
}

// ---- behaviour ----------------------------------------------------------------------------

/// How far one arrow key moves the split.
pub const step: f32 = 0.05;

/// Where `pointer` is along `axis` of the container rect `box`, 0 at its start to 1 at its
/// end (not clamped).
pub fn along(box: types.Rect, axis: Axis, pointer: [2]f32) f32 {
    const lo = [2]f32{ box.x0, box.y0 };
    const len = [2]f32{ box.w(), box.h() };
    const a = @backingInt(axis);
    return (pointer[a] - lo[a]) / @max(len[a], 1);
}

/// The next split (WAI-ARIA APG window splitter pattern). While the handle is held it
/// follows the pointer (`at`, as `along` gives it). While it has focus, Left or Up moves it
/// back by `step`, Right or Down forward, Home to 0 and End to 1, repeats included. The
/// result is clamped to 0..1.
pub fn resize(split: f32, held: bool, at: f32, focused: bool, in: *const Input) f32 {
    var v = base.slide(split, held, at, 0, 1);
    const k = keys.map;
    for (in.events) |e| {
        const down = focused and (e.kind == .press or e.kind == .repeat);
        const dir = @as(f32, @floatFromInt(@intFromBool(e.code == k.right or e.code == k.down))) -
            @as(f32, @floatFromInt(@intFromBool(e.code == k.left or e.code == k.up)));
        v = simd.selF(down, v + dir * step, v);
        v = simd.selF(down and e.code == k.home, 0, v);
        v = simd.selF(down and e.code == k.end, 1, v);
    }
    return base.unit(v);
}

// ---- accessibility ------------------------------------------------------------------------

/// What assistive technology sees (WAI-ARIA APG window splitter pattern): the handle is a
/// focusable `separator` whose value is the split, 0 to 1 (a bridge scales it to
/// aria-valuenow's 0..100), labelled by the first pane. `types.Role` has no separator, so
/// both front ends write the byte; the harness compares it and the value.
pub const role: u8 = @backingInt(a11y.Role.separator);

/// Fills the caller's semantic columns for the splitter whose container is tree row `row`:
/// the handle is named by the first pane's text. Call after the frame, for either front end.
pub fn semantics(t: *const Tree, s: *a11y.Semantics, row: u32) void {
    const first = row + 1;
    const hd = t.c.end[first] + 1; // the second pane starts after the first; the handle leads it
    s.c.labelled_by[hd] = first;
}

/// The splitter as a spec node.
pub const ct = struct {
    /// A splitter along `axis` over the f32 field `split`, its handle the widget `id`, its
    /// panes holding `first` and `second` (tuples of specs). Mistakes are compile errors: an
    /// empty pane, or a `split` that is not an f32 field of the state struct.
    pub fn splitter(comptime th: Theme, comptime id: @EnumLiteral(), comptime axis: Axis, comptime split: @EnumLiteral(), comptime first: anytype, comptime second: anytype) Spec {
        if (first.len == 0 or second.len == 0) @compileError("splitter '" ++ @tagName(id) ++ "' has an empty pane");
        var hd: Spec = .{ .kind = .col, .style = handleStyle(&th, axis) };
        hd.id = @tagName(id);
        const rest: Spec = .{ .kind = .col, .style = secondStyle(&th, axis, 0), .children = &.{ hd, spec_zig.col(bodyStyle(&th), second) } };
        var s: Spec = .{ .kind = .col, .style = containerStyle(&th, axis), .children = &.{ spec_zig.col(firstStyle(&th, axis, 0), first), rest } };
        s.widget = Splitter(@tagName(id), axis, @tagName(split));
        return s;
    }

    /// How the comptime front end builds and drives one splitter.
    fn Splitter(comptime id: [:0]const u8, comptime axis: Axis, comptime split: []const u8) type {
        return struct {
            /// Drag from `ui.pointer` and last frame's container rect; keys from `ui.focus`.
            pub fn step(ui: anytype, comptime row: u32, event: anytype, in: *const Input) void {
                _ = event;
                const me = @field(@TypeOf(ui.*).Events.Widget, id);
                const held = ui.pointer.pressed == me;
                // The container's rect in last frame's tree (row + 1, under the root). Read only
                // while held, which needs a laid-out frame to have been pressed.
                const at = if (held) along(ui.tables.t.rect(row + 1), axis, in.pointer) else 0;
                const field = comptime @TypeOf(ui.*).field(split);
                ui.signals.set(field, resize(@field(ui.signals.state, split), held, at, ui.focus == me, in));
            }

            pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
                const th = @TypeOf(ui.*).theme;
                const t = &ui.tables.t;
                const value: f32 = @field(ui.signals.state, split);
                const box = t.push(parent, .none, &n.style);
                const a = t.push(box, .none, &firstStyle(&th, axis, value));
                next.* += 2;
                inline for (n.children[0].children) |c| ui.push(c, a, next, in);
                t.seal(a);
                const rest = t.push(box, .none, &secondStyle(&th, axis, value));
                var hs = n.children[1].children[0].style;
                hs.fill = handleFill(&th, ui.response(next.* + 1, in));
                hs.value = value;
                const hd = t.push(rest, .hash(id), &hs);
                t.c.role[hd] = role;
                const b = t.push(rest, .none, &n.children[1].children[1].style);
                next.* += 3;
                inline for (n.children[1].children[1].children) |c| ui.push(c, b, next, in);
                t.seal(b);
                t.seal(rest);
                t.seal(box);
            }
        };
    }
};

// ---- tests --------------------------------------------------------------------------------

const testing = std.testing;

/// The example page: a side-by-side splitter at 30%, a label on the left and a checkbox on
/// the right, in both front ends, in theme `th`.
pub fn Page(comptime th: Theme) type {
    const area: Style = .{ .dir = .y, .size = .{ .px(300), .px(120) }, .pad = @splat(8) };
    return struct {
        pub const App = struct {
            split: f32 = 0.3,
            wire: bool = false,
            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.none, area);
                open(f, &th, .from("split"), .x, &app.split);
                _ = base.label(f, &th, "Files");
                handle(f, &th, .from("split"), .x, app.split);
                _ = base.checkbox(f, &th, .from("wire"), &app.wire, "Wireframe");
                close(f);
                f.close();
            }
        };
        pub const State = struct {
            split: f32 = 0.3,
            files: []const u8 = "Files",
            wire: bool = false,
            wire_text: []const u8 = "Wireframe",
        };
        pub const spec = spec_zig.col(area, .{ct.splitter(th, .split_handle, .x, .split, .{base.ct.label(th, .files)}, .{base.ct.checkbox(th, .wire, .wire, .wire_text)})});
        pub const Ui = base.ComptimeUi(State, spec, th);
        pub const Run = base.Harness(App, Ui, .{ .nodes = 32, .texts = 8, .customs = 1, .strings = 256, .depth = 8 });
    };
}

/// Input for `Page(.default)` at 320 x 200, one commented line per frame.
pub const replay = @embedFile("testdata/splitter.replay");

/// The frames of `replay` kept as golden images (tools/widgetgolden/ref/splitter-<name>.png).
pub const golden_frames = .{
    .{ "rest", 0 },
    .{ "dragged", 3 },
    .{ "end", 6 },
};

const Default = Page(.default);
var harness: Default.Run = .{};

/// Tree rows: root 0, area 1, container 2, first pane 3 (label 4), second pane 5, handle 6,
/// body 7 (checkbox 8..10).
const rows = struct {
    const box = 2;
    const first = 3;
    const second = 5;
    const handle = 6;
    const body = 7;
};

test "splitter: both front ends split the container at the bound fraction around the handle" {
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 200 } };
    const out = try h.frame(&in);
    const t = out.runtime.tree;
    try testing.expectEqual(@as(u32, 11), t.len);
    const box = t.rect(rows.box);
    try testing.expectApproxEqAbs(0.3 * box.w(), t.rect(rows.first).w(), 0.5);
    try testing.expectEqual(handle_px, t.rect(rows.handle).w());
    try testing.expectEqual(t.rect(rows.first).x1, t.rect(rows.handle).x0);
    try testing.expectEqual(t.rect(rows.first).x1, t.rect(rows.second).x0);
    try testing.expectEqual(t.rect(rows.handle).x1, t.rect(rows.body).x0);
    try testing.expectEqual(box.x1, t.rect(rows.second).x1);
    try testing.expectEqual(box.h(), t.rect(rows.handle).h());
}

test "splitter: handle filled by state, resize cursor; any theme alike" {
    const h = &harness;
    h.init();
    var in: Input = .{ .viewport = .{ 320, 200 } };
    var out = try h.frame(&in);
    const th = Theme.default;
    try testing.expectEqual(th.control.bitsOf(), out.runtime.tree.c.look[rows.handle].fill);
    const r = out.runtime.tree.rect(rows.handle);
    in.pointer = .{ (r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5 };
    out = try h.frame(&in);
    try testing.expectEqual(th.control_hot.bitsOf(), out.runtime.tree.c.look[rows.handle].fill);
    try testing.expectEqual(th.control_hot.bitsOf(), out.comptime_.tree.c.look[rows.handle].fill);
    try testing.expectEqual(@import("../runtime/context.zig").Cursor.resize_h, out.runtime.platform.cursor);
    in.buttons.left = true;
    out = try h.frame(&in);
    try testing.expectEqual(th.accent.bitsOf(), out.runtime.tree.c.look[rows.handle].fill);
    try testing.expectEqual(th.accent.bitsOf(), out.comptime_.tree.c.look[rows.handle].fill);
    in.buttons.left = false;
    _ = try h.frame(&in);

    const Light = Page(.{ .control = .rgb(200, 200, 205), .control_hot = .rgb(180, 180, 190), .accent = .rgb(0, 120, 60), .text = .rgb(20, 20, 20), .radius = 0 });
    const S = struct {
        var light: Light.Run = .{};
    };
    S.light.init();
    const lo = try S.light.frame(&in);
    try testing.expectEqual(types.Color.rgb(200, 200, 205).bitsOf(), lo.runtime.tree.c.look[rows.handle].fill);
    try testing.expectEqual(handle_px / 2, handleStyle(&th, .x).radius);
}

test "resize: drag follows the pointer, arrows step, Home and End jump, all clamped" {
    const k = keys.map;
    const none_in: Input = .{};
    try testing.expectEqual(@as(f32, 0.7), resize(0.3, true, 0.7, false, &none_in));
    try testing.expectEqual(@as(f32, 1), resize(0.3, true, 1.4, false, &none_in));
    try testing.expectEqual(@as(f32, 0.3), resize(0.3, false, 0.9, true, &none_in));
    const ev = [3]Input.Event{ .{ .kind = .press, .code = k.right }, .{ .kind = .repeat, .code = k.down }, .{ .kind = .press, .code = k.left } };
    const in: Input = .{ .events = &ev };
    try testing.expectApproxEqAbs(@as(f32, 0.35), resize(0.3, false, 0, true, &in), 1e-6);
    try testing.expectEqual(@as(f32, 0.3), resize(0.3, false, 0, false, &in));
    const he = [2]Input.Event{ .{ .kind = .press, .code = k.end }, .{ .kind = .press, .code = k.right } };
    try testing.expectEqual(@as(f32, 1), resize(0.3, false, 0, true, &.{ .events = &he }));
    const ho = [1]Input.Event{.{ .kind = .press, .code = k.home }};
    try testing.expectEqual(@as(f32, 0), resize(0.3, false, 0, true, &.{ .events = &ho }));
    try testing.expectEqual(@as(f32, 0.5), along(.{ .x0 = 10, .y0 = 0, .x1 = 110, .y1 = 20 }, .x, .{ 60, 5 }));
    try testing.expectEqual(@as(f32, 0.25), along(.{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 40 }, .y, .{ 60, 10 }));
}

test "splitter: dragging and arrow keys move the split in both front ends" {
    const h = &harness;
    h.init();
    var in: Input = .{ .viewport = .{ 320, 200 } };
    var out = try h.frame(&in);
    const box = out.runtime.tree.rect(rows.box);
    const hd = out.runtime.tree.rect(rows.handle);
    in.pointer = .{ (hd.x0 + hd.x1) * 0.5, (hd.y0 + hd.y1) * 0.5 };
    in.buttons.left = true;
    _ = try h.frame(&in);
    // Drag to 60% of the container, then past its end: clamped to 1.
    in.pointer[0] = box.x0 + 0.6 * box.w();
    out = try h.frame(&in);
    try testing.expectApproxEqAbs(@as(f32, 0.6), h.app.split, 1e-5);
    try testing.expectEqual(h.app.split, h.ui.signals.state.split);
    try testing.expectApproxEqAbs(0.6 * box.w(), out.runtime.tree.rect(rows.first).w(), 0.5);
    in.pointer[0] = box.x1 + 40;
    _ = try h.frame(&in);
    try testing.expectEqual(@as(f32, 1), h.app.split);
    try testing.expectEqual(@as(f32, 1), h.ui.signals.state.split);
    // Back to 50%, release: the handle keeps focus; Left steps back, Home jumps to 0.
    in.pointer[0] = box.x0 + 0.5 * box.w();
    _ = try h.frame(&in);
    in.buttons.left = false;
    _ = try h.frame(&in);
    const left = [1]Input.Event{.{ .kind = .press, .code = keys.map.left }};
    in.events = &left;
    _ = try h.frame(&in);
    try testing.expectApproxEqAbs(@as(f32, 0.45), h.app.split, 1e-5);
    try testing.expectEqual(h.app.split, h.ui.signals.state.split);
    const home = [1]Input.Event{.{ .kind = .press, .code = keys.map.home }};
    in.events = &home;
    out = try h.frame(&in);
    try testing.expectEqual(@as(f32, 0), h.app.split);
    try testing.expectEqual(@as(f32, 0), h.ui.signals.state.split);
    try testing.expectEqual(@as(f32, 0), out.runtime.tree.rect(rows.first).w());
}

test "splitter: handle is a focusable separator valued by the split, named by the first pane" {
    const check = @import("check.zig");
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 200 } };
    const out = try h.frame(&in);
    var sb: check.SemBuf = undefined;
    const trees = [2]*const Tree{ out.runtime.tree, out.comptime_.tree };
    const texts = [2]*const @import("../core/texts.zig").Texts{ out.runtime.texts, &h.ui.tables.tx };
    const strings = [2][]const u8{ h.ctx.strings[h.ctx.cur].buf, h.ui.tables.strings.buf };
    for (trees, texts, strings) |t, tx, str| {
        var sem = sb.init();
        semantics(t, &sem, rows.box);
        a11y.names(t, &sem);
        a11y.states(t, &sem);
        try testing.expectEqual(a11y.Role.separator, @as(a11y.Role, @fromBackingInt(t.c.role[rows.handle])));
        try testing.expectApproxEqAbs(@as(f32, 0.3), t.c.value[rows.handle], 1e-6);
        try testing.expectEqualStrings("Files", check.nameOf(&sem, tx, str, rows.handle));
        try testing.expectEqual(@as(u8, 0), sem.c.state[rows.handle]);
    }
    // Focusable: it senses focus, so Tab stops on it.
    const focusable: u8 = @bitCast(types.Sense{ .focus = true });
    try testing.expect(out.runtime.tree.c.sense[rows.handle] & focusable != 0);
}

test "splitter: the example replay gives the same frames in both front ends" {
    const Replay = @import("../core/input.zig").Replay;
    const h = &harness;
    h.init();
    var text: [16]u8 = undefined;
    var evs: [8]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &evs, .contacts = &contacts };
    var rp: Replay = .{ .src = replay };
    var split: [8]f32 = undefined;
    var fills: [8]u32 = undefined;
    while (try rp.next(buf)) |in| {
        const k = h.frames;
        const out = try h.frame(in);
        split[k] = h.app.split;
        try testing.expectEqual(h.app.split, h.ui.signals.state.split);
        fills[k] = out.runtime.tree.c.look[rows.handle].fill;
    }
    try testing.expectEqual(@as(u32, 8), h.frames);
    // The press puts the split under the pointer, the middle of the handle: 88 / 284.
    const want = [8]f32{ 0.3, 0.3, 88.0 / 284.0, 0.5, 0.5, 0.55, 1, 0 };
    for (want, split) |w, got| try testing.expectApproxEqAbs(w, got, 1e-5);
    const th = Theme.default;
    try testing.expectEqualSlices(u32, &.{ th.control.bitsOf(), th.control_hot.bitsOf(), th.accent.bitsOf(), th.accent.bitsOf(), th.control_hot.bitsOf() }, fills[0..5]);
}

test "golden_frames: name frames the splitter replay has" {
    inline for (golden_frames) |g| try testing.expect(g[1] < 8);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
