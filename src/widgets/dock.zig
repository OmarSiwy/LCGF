//! Dock (tier 2): a docking layout of up to five panes, a left, top, bottom and right pane
//! around the centre, with a splitter between each side pane and the rest. It is a thin
//! composition of splitter.zig: no layout code of its own. The sizes are application state
//! (`State`, one per dock id), dragged by the handles or moved by the arrow keys on a focused
//! handle; F6 and Shift+F6 move keyboard focus to the next and previous pane.
//!
//! Runtime only:
//!
//!     var d = dock.open(f, th, .from("main"), &app.dock, .{ .top = false });
//!     d.pane(f, .left); ...left's children...
//!     d.pane(f, .centre); ...
//!     d.close(f);
//!
//! Panes are visited in `Pane` order (left, top, centre, bottom, right); only the panes in
//! `Panes` exist, and the centre always does.

const std = @import("std");
const base = @import("base.zig");
const splitter = @import("splitter.zig");
const types = @import("../core/types.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const Input = @import("../core/input.zig").Input;
const Style = types.Style;
const Id = types.Id;
const Theme = base.Theme;
const none = types.none;

/// A pane's place, in the order the panes are built.
pub const Pane = enum(u3) { left, top, centre, bottom, right };

/// Which side panes exist; the centre always does.
pub const Panes = struct { left: bool = true, top: bool = true, bottom: bool = true, right: bool = true };

/// The sizes, as the four splitters' fractions (`splitter.open`'s `split`), in the caller's
/// memory, one per dock id.
pub const State = struct {
    /// The left pane's share of the dock; the middle share of what the left pane leaves (the
    /// right pane takes the rest); the top pane's share of the middle; the centre's share of
    /// what the top pane leaves (the bottom pane takes the rest).
    splits: [4]f32 = .{ 0.2, 0.75, 0.2, 0.75 },
};

/// The key that moves focus between panes (USB HID usage), as in most desktop editors.
pub const f6: u8 = 0x3f;

/// The id of pane `p` of dock `id`; its splitters are `id.with(1)` to `id.with(4)`.
pub fn paneId(id: Id, p: Pane) Id {
    return id.with(10 + @as(u32, @backingInt(p)));
}

/// The dock: fills its parent.
pub fn rootStyle(th: *const Theme) Style {
    _ = th;
    return .{ .size = .{ .fill, .fill } };
}

/// A pane: fills its splitter's pane, its children in a column, clipped. A group to assistive
/// technology, focusable so F6 can land on it.
pub fn paneStyle(th: *const Theme) Style {
    _ = th;
    return .{ .dir = .y, .size = .{ .fill, .fill }, .clip = true, .role = .group };
}

/// Whether pane `p` exists in `panes`.
pub fn has(panes: Panes, p: Pane) bool {
    const on = [5]bool{ panes.left, panes.top, true, panes.bottom, panes.right };
    return on[@backingInt(p)];
}

/// The pane that focus moves to from `from` (or from no pane, `null`) by `step` (+1 F6, -1
/// Shift+F6), wrapping and skipping the panes `panes` lacks.
pub fn cycle(panes: Panes, from: ?Pane, step: i8) Pane {
    var k: i8 = if (from) |p| @backingInt(p) else if (step > 0) -1 else 5;
    for (0..5) |_| {
        k = @mod(k + step, 5);
        if (has(panes, @fromBackingInt(@intCast(k)))) break;
    }
    return @fromBackingInt(@intCast(k));
}

/// The pane of dock `id` holding the focused node in last frame's tree, or null.
fn focusedPane(f: *const Frame, id: Id, panes: Panes) ?Pane {
    if (f.ctx.inter.focus == 0) return null;
    const prev = f.prevTree();
    var r = prev.find(@fromBackingInt(f.ctx.inter.focus));
    // Parents come before their children, so the walk ends at the root.
    while (r != none) : (r = if (r == 0) none else prev.c.parent[r]) {
        inline for (0..5) |k| if (has(panes, @fromBackingInt(@intCast(k))) and prev.c.id[r] == @backingInt(paneId(id, @fromBackingInt(@intCast(k))))) return @fromBackingInt(@intCast(k));
    }
    return null;
}

/// Opens dock `id` with the side panes `panes`, sized by `st`; F6 and Shift+F6 in this frame's
/// events move focus first. Then `pane` for each pane in order, then `close`.
pub fn open(f: *Frame, th: *const Theme, id: Id, st: *State, panes: Panes) Dock {
    return openFace(f, th, id, st, panes, rootStyle(th));
}

/// `open` with the dock laid out by `face` instead of `rootStyle(th)`.
pub fn openFace(f: *Frame, th: *const Theme, id: Id, st: *State, panes: Panes, face: Style) Dock {
    var at = focusedPane(f, id, panes);
    var moved = false;
    for (f.in.events) |e| {
        if (e.kind == .press and e.code == f6) {
            at = cycle(panes, at, if (e.mods.shift) -1 else 1);
            moved = true;
        }
    }
    if (moved) f.ctx.inter.focus = @backingInt(paneId(id, at.?));
    _ = f.open(id, face);
    return .{ .th = th, .id = id, .st = st, .panes = panes };
}

/// A dock being built: which pane comes next.
pub const Dock = struct {
    th: *const Theme,
    id: Id,
    st: *State,
    panes: Panes,
    /// The next position to enter, 0 (left) to 5 (past the right pane).
    next: u3 = 0,
    in_pane: bool = false,

    /// Ends the pane being built, if any, and opens pane `p`, which must exist and come after
    /// it; build its children next.
    pub fn pane(d: *Dock, f: *Frame, p: Pane) void {
        std.debug.assert(has(d.panes, p) and @backingInt(p) >= d.next);
        d.advance(f, @backingInt(p));
        const n = f.open(paneId(d.id, p), paneStyle(d.th));
        _ = f.interact(n, .{ .focus = true });
        d.in_pane = true;
    }

    /// Ends the last pane and the dock.
    pub fn close(d: *Dock, f: *Frame) void {
        d.advance(f, 5);
        f.close();
    }

    /// Closes the open pane and walks the splitters from position `next` to `to`: the steps
    /// between two neighbours open, hand over or close the splitters of the panes that exist.
    fn advance(d: *Dock, f: *Frame, to: u3) void {
        if (d.in_pane) f.close();
        d.in_pane = false;
        const th = d.th;
        const s = &d.st.splits;
        const L = d.panes.left;
        const T = d.panes.top;
        const B = d.panes.bottom;
        const R = d.panes.right;
        const a = d.id.with(1);
        const b = d.id.with(2);
        const c = d.id.with(3);
        const e = d.id.with(4);
        while (d.next <= to) : (d.next += 1) switch (d.next) {
            0 => if (L) splitter.open(f, th, a, .x, &s[0]),
            1 => {
                if (L) splitter.handle(f, th, a, .x, s[0]);
                if (R) splitter.open(f, th, b, .x, &s[1]);
                if (T) splitter.open(f, th, c, .y, &s[2]);
            },
            2 => {
                if (T) splitter.handle(f, th, c, .y, s[2]);
                if (B) splitter.open(f, th, e, .y, &s[3]);
            },
            3 => if (B) splitter.handle(f, th, e, .y, s[3]),
            4 => {
                if (B) splitter.close(f);
                if (T) splitter.close(f);
                if (R) splitter.handle(f, th, b, .x, s[1]);
            },
            5 => {
                if (R) splitter.close(f);
                if (L) splitter.close(f);
                return;
            },
            else => unreachable,
        };
    }
};

// ---- comptime front end in base.ComptimeUi ----------------------------------------------------

const spec_zig = @import("../comptime/spec.zig");
const Spec = spec_zig.Spec;
const flatten = @import("../comptime/flatten.zig");
const Axis = types.Axis;

/// The splitters by position: left, right, top, bottom; their axes and handle names' suffixes.
const split_axes = [4]Axis{ .x, .x, .y, .y };
const split_names = [4][:0]const u8{ "_split_left", "_split_right", "_split_top", "_split_bottom" };

/// Whether the splitter at position `k` exists in `panes`.
fn splitOn(panes: Panes, k: usize) bool {
    return ([4]bool{ panes.left, panes.right, panes.top, panes.bottom })[k];
}

pub const ct = struct {
    /// Dock `name` with the side panes `panes`, sized by the `State` field `field`; `children`
    /// holds one tuple of spec nodes per pane that exists, in `Pane` order (left, top, centre,
    /// bottom, right). `spec.styled` restyles it as `openFace` does. Its runtime twin is
    /// `open`, `pane` for each pane, `close`.
    pub fn dock(comptime th: Theme, comptime name: @EnumLiteral(), comptime field: @EnumLiteral(), comptime panes: Panes, comptime children: anytype) Spec {
        const id = @tagName(name);
        var specs: [5]Spec = @splat(.{ .kind = .col });
        var k: usize = 0;
        for (0..5) |q| if (has(panes, @fromBackingInt(@intCast(q)))) {
            specs[q] = spec_zig.col(paneStyle(&th), children[k]);
            specs[q].id = id ++ "_" ++ @tagName(@as(Pane, @fromBackingInt(@intCast(q))));
            specs[q].widget = base.FocusStop;
            k += 1;
        };
        if (k != children.len) @compileError("dock '" ++ id ++ "': one tuple of children per pane");
        var firsts: [4]u32 = @splat(0);
        var inner = specs[@backingInt(Pane.centre)];
        if (panes.bottom) {
            firsts[3] = flatten.count(inner);
            inner = split(th, .y, id ++ split_names[3], inner, specs[@backingInt(Pane.bottom)]);
        }
        if (panes.top) {
            firsts[2] = flatten.count(specs[@backingInt(Pane.top)]);
            inner = split(th, .y, id ++ split_names[2], specs[@backingInt(Pane.top)], inner);
        }
        if (panes.right) {
            firsts[1] = flatten.count(inner);
            inner = split(th, .x, id ++ split_names[1], inner, specs[@backingInt(Pane.right)]);
        }
        if (panes.left) {
            firsts[0] = flatten.count(specs[@backingInt(Pane.left)]);
            inner = split(th, .x, id ++ split_names[0], specs[@backingInt(Pane.left)], inner);
        }
        var s = spec_zig.col(rootStyle(&th), .{inner});
        s.id = id;
        s.bind = @tagName(field);
        s.widget = Comptime(th, id, @tagName(field), panes, specs, firsts);
        return s;
    }

    /// A splitter's rows as `splitter.open` and `splitter.handle` build them: the container,
    /// the first pane holding `first`, the second holding the handle (named `handle`) and the
    /// body holding `second`.
    fn split(comptime th: Theme, comptime axis: Axis, comptime handle: [:0]const u8, comptime first: Spec, comptime second: Spec) Spec {
        const hd: Spec = .{ .kind = .col, .id = handle, .style = splitter.handleStyle(&th, axis), .widget = base.FocusStop };
        return .{ .kind = .col, .style = splitter.containerStyle(&th, axis), .children = &.{
            spec_zig.col(splitter.firstStyle(&th, axis, 0), .{first}),
            .{ .kind = .col, .style = splitter.secondStyle(&th, axis, 0), .children = &.{ hd, spec_zig.col(splitter.bodyStyle(&th), .{second}) } },
        } };
    }
};

/// The custom widget (`Spec.widget`) of `ct.dock`: its `step` moves the splits and F6 focus as
/// `open` and the splitters do at run time; its `push` builds the rows they build, with the
/// same ids. `panes` are the pane specs by `Pane` and `firsts` the rows of each splitter's
/// first pane's content, to find each container's row from its handle's.
pub fn Comptime(comptime th: Theme, comptime name: [:0]const u8, comptime field: []const u8, comptime panes: Panes, comptime specs: [5]Spec, comptime firsts: [4]u32) type {
    return struct {
        pub fn bindError(comptime S: type, comptime bound: []const u8) ?[]const u8 {
            return base.fieldError(S, "dock '" ++ name ++ "'", bound, State);
        }

        fn rowOf(comptime U: type, comptime id: []const u8) u32 {
            return @backingInt(@field(U.Events.Widget, id));
        }

        pub fn step(ui: anytype, comptime row: u32, event: anytype, in: *const Input) void {
            _ = row;
            const U = @TypeOf(ui.*);
            var st: State = @field(ui.signals.state, field);
            inline for (0..4) |k| if (comptime splitOn(panes, k)) {
                const hd = comptime rowOf(U, name ++ split_names[k]);
                const r = base.ctResponse(ui, hd, event, in);
                // Container, first pane, its content, second pane, handle.
                const box = ui.lastRect(hd - 3 - firsts[k]);
                st.splits[k] = splitter.resize(st.splits[k], r.held, splitter.along(box, split_axes[k], in.pointer), r.focused, in);
            };
            ui.signals.set(comptime U.field(field), st);
            // F6 after the handles, which answer for the focus the frame started with.
            var at: ?Pane = null;
            if (ui.focus) |w| inline for (0..5) |q| if (comptime has(panes, @fromBackingInt(@intCast(q)))) {
                const lo = comptime rowOf(U, specs[q].id.?);
                if (@backingInt(w) >= lo and @backingInt(w) < lo + comptime flatten.count(specs[q])) at = @fromBackingInt(@intCast(q));
            };
            var moved = false;
            for (in.events) |e| if (e.kind == .press and e.code == f6) {
                at = cycle(panes, at, if (e.mods.shift) -1 else 1);
                moved = true;
            };
            if (moved) inline for (0..5) |q| if (comptime has(panes, @fromBackingInt(@intCast(q)))) {
                if (at.? == @as(Pane, @fromBackingInt(@intCast(q)))) ui.focus = @field(U.Events.Widget, specs[q].id.?);
            };
        }

        pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
            const t = &ui.tables.t;
            const st: State = @field(ui.signals.state, field);
            const id = Id.hash(name);
            var stack: [16]u32 = undefined;
            var top: u32 = 1;
            stack[0] = t.push(parent, id, &n.style);
            next.* += 1;
            const S = struct {
                fn open(tt: anytype, stk: *[16]u32, tp: *u32, nx: *u32, node: Id, s: Style) void {
                    stk[tp.*] = tt.push(stk[tp.* - 1], node, &s);
                    tp.* += 1;
                    nx.* += 1;
                }
                fn close(tt: anytype, stk: *[16]u32, tp: *u32) void {
                    tp.* -= 1;
                    tt.seal(stk[tp.*]);
                }
            };
            const splits = struct {
                fn open(u: anytype, stk: *[16]u32, tp: *u32, nx: *u32, base_id: Id, comptime k: usize, split: f32) void {
                    const tt = &u.tables.t;
                    S.open(tt, stk, tp, nx, base_id.with(k + 1), splitter.containerStyle(&th, split_axes[k]));
                    S.open(tt, stk, tp, nx, .none, splitter.firstStyle(&th, split_axes[k], split));
                }
                fn handle(u: anytype, stk: *[16]u32, tp: *u32, nx: *u32, base_id: Id, comptime k: usize, split: f32, inp: *const Input) void {
                    const tt = &u.tables.t;
                    const axis = split_axes[k];
                    S.close(tt, stk, tp);
                    S.open(tt, stk, tp, nx, .none, splitter.secondStyle(&th, axis, split));
                    const r = u.response(nx.*, inp);
                    var hs = splitter.handleStyle(&th, axis);
                    hs.fill = splitter.handleFill(&th, r);
                    hs.value = split;
                    const hd = tt.push(stk[tp.* - 1], base_id.with(k + 1).with(1), &hs);
                    tt.c.role[hd] = splitter.role;
                    nx.* += 1;
                    u.setCursor(splitter.cursors[@backingInt(axis)], r.hovered or r.held);
                    S.open(tt, stk, tp, nx, .none, splitter.bodyStyle(&th));
                }
                fn close(tt: anytype, stk: *[16]u32, tp: *u32) void {
                    S.close(tt, stk, tp);
                    S.close(tt, stk, tp);
                    S.close(tt, stk, tp);
                }
            };
            const L = panes.left;
            const T = panes.top;
            const B = panes.bottom;
            const R = panes.right;
            const sp = st.splits;
            inline for (0..6) |step_k| {
                switch (step_k) {
                    0 => if (L) splits.open(ui, &stack, &top, next, id, 0, sp[0]),
                    1 => {
                        if (L) splits.handle(ui, &stack, &top, next, id, 0, sp[0], in);
                        if (R) splits.open(ui, &stack, &top, next, id, 1, sp[1]);
                        if (T) splits.open(ui, &stack, &top, next, id, 2, sp[2]);
                    },
                    2 => {
                        if (T) splits.handle(ui, &stack, &top, next, id, 2, sp[2], in);
                        if (B) splits.open(ui, &stack, &top, next, id, 3, sp[3]);
                    },
                    3 => if (B) splits.handle(ui, &stack, &top, next, id, 3, sp[3], in),
                    4 => {
                        if (B) splits.close(t, &stack, &top);
                        if (T) splits.close(t, &stack, &top);
                        if (R) splits.handle(ui, &stack, &top, next, id, 1, sp[1], in);
                    },
                    else => {
                        if (R) splits.close(t, &stack, &top);
                        if (L) splits.close(t, &stack, &top);
                    },
                }
                // Pane `step_k` comes after the step that opens its place.
                if (step_k < 5 and comptime has(panes, @fromBackingInt(@intCast(step_k)))) {
                    const pn = specs[step_k];
                    S.open(t, &stack, &top, next, paneId(id, @fromBackingInt(@intCast(step_k))), pn.style);
                    inline for (pn.children) |c| ui.push(c, stack[top - 1], next, in);
                    S.close(t, &stack, &top);
                }
            }
            S.close(t, &stack, &top);
        }
    };
}

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;
const keys_zig = @import("keys.zig");
const context = @import("../runtime/context.zig");
const mem = @import("../core/mem.zig");

const test_limits: context.Limits = .{ .nodes = 64, .texts = 8, .customs = 1, .strings = 128, .depth = 16 };

const TestDock = struct {
    st: State = .{},
    panes: Panes = .{},
    buf: [context.Context.requiredBytes(test_limits)]u8 align(mem.column_align) = undefined,
    ctx: context.Context = undefined,

    fn build(t: *TestDock, f: *Frame) void {
        const th: *const Theme = &.default;
        var d = open(f, th, .from("dock"), &t.st, t.panes);
        inline for (0..5) |k| if (has(t.panes, @fromBackingInt(@intCast(k)))) {
            d.pane(f, @fromBackingInt(@intCast(k)));
            _ = base.label(f, th, @tagName(@as(Pane, @fromBackingInt(@intCast(k)))));
        };
        d.close(f);
    }

    fn frame(t: *TestDock, in: *const Input) context.Output {
        var f = t.ctx.begin(in);
        t.build(&f);
        return f.end(.{});
    }

    fn rect(out: context.Output, p: Pane) types.Rect {
        return out.tree.rect(out.tree.find(paneId(.from("dock"), p)));
    }
};

var test_dock: TestDock = .{};

test "dock: five panes around the centre, sized by the state" {
    const t = &test_dock;
    t.* = .{};
    t.ctx = try .init(&t.buf, test_limits);
    const in: Input = .{ .viewport = .{ 400, 300 } };
    const out = t.frame(&in);
    try testing.expect(out.status.ok());
    const l = TestDock.rect(out, .left);
    const top = TestDock.rect(out, .top);
    const c = TestDock.rect(out, .centre);
    const b = TestDock.rect(out, .bottom);
    const r = TestDock.rect(out, .right);
    try testing.expectEqual(@as(f32, 0), l.x0);
    try testing.expectEqual(@as(f32, 80), l.x1);
    try testing.expectEqual(@as(f32, 400), r.x1);
    try testing.expect(l.x1 < top.x0 and top.x0 == c.x0 and c.x0 == b.x0 and c.x1 < r.x0);
    try testing.expect(top.y1 < c.y0 and c.y1 < b.y0 and b.y1 == 300);
}

test "dock: without some side panes, the rest fill their place" {
    const t = &test_dock;
    t.* = .{ .panes = .{ .left = false, .top = false } };
    t.ctx = try .init(&t.buf, test_limits);
    const in: Input = .{ .viewport = .{ 400, 300 } };
    const out = t.frame(&in);
    try testing.expectEqual(none, out.tree.find(paneId(.from("dock"), .left)));
    const c = TestDock.rect(out, .centre);
    try testing.expectEqual(@as(f32, 0), c.x0);
    try testing.expectEqual(@as(f32, 0), c.y0);
    try testing.expect(c.x1 < TestDock.rect(out, .right).x0 and c.y1 < TestDock.rect(out, .bottom).y0);
}

test "dock: dragging the left handle resizes the left pane" {
    const t = &test_dock;
    t.* = .{};
    t.ctx = try .init(&t.buf, test_limits);
    var in: Input = .{ .viewport = .{ 400, 300 } };
    var out = t.frame(&in);
    const hd = out.tree.rect(out.tree.find(Id.from("dock").with(1).with(1)));
    in.pointer = .{ (hd.x0 + hd.x1) / 2, 150 };
    for ([_]f32{ in.pointer[0], in.pointer[0], 160, 160 }, [_]bool{ false, true, true, false }) |x, down| {
        in.pointer[0] = x;
        in.buttons.left = down;
        out = t.frame(&in);
    }
    try testing.expectApproxEqAbs(@as(f32, 0.4), t.st.splits[0], 0.01);
    try testing.expectApproxEqAbs(@as(f32, 160), TestDock.rect(out, .left).x1, 1);
}

test "dock: F6 and Shift+F6 move focus between the panes that exist" {
    const t = &test_dock;
    t.* = .{ .panes = .{ .top = false } };
    t.ctx = try .init(&t.buf, test_limits);
    var in: Input = .{ .viewport = .{ 400, 300 } };
    _ = t.frame(&in);
    const id: Id = .from("dock");
    const expect = [_]Pane{ .left, .centre, .bottom, .right, .left, .right };
    for (expect, 0..) |want, k| {
        const ev = [1]Input.Event{.{ .kind = .press, .code = f6, .mods = .{ .shift = k == 5 } }};
        in.events = &ev;
        _ = t.frame(&in);
        try testing.expectEqual(@backingInt(paneId(id, want)), t.ctx.inter.focus);
    }
    try testing.expectEqual(Pane.bottom, cycle(.{}, .centre, 1));
    try testing.expectEqual(Pane.right, cycle(.{}, null, -1));
}

/// The dock restyled as a page does from data: `openFace` against `spec.styled` on `ct.dock`,
/// with a pane missing, over a drag of each handle, F6 and the arrows on a handle.
const restyled = struct {
    const th: Theme = .default;
    const face: Style = .{ .size = .{ .fill, .fill }, .fill = .rgb(20, 40, 60), .pad = @splat(4) };
    const panes: Panes = .{ .top = false };
    const App = struct {
        dock: State = .{},
        on: bool = false,
        pub fn build(app: *App, f: *Frame) void {
            var d = openFace(f, &th, .from("main"), &app.dock, panes, face);
            d.pane(f, .left);
            _ = base.label(f, &th, "Files");
            d.pane(f, .centre);
            _ = base.checkbox(f, &th, .from("on"), &app.on, "On");
            d.pane(f, .bottom);
            _ = base.label(f, &th, "Log");
            d.pane(f, .right);
            _ = base.label(f, &th, "Props");
            d.close(f);
        }
    };
    const PageState = struct { dock: State = .{}, on: bool = false, on_text: []const u8 = "On" };
    const spec = spec_zig.styled(ct.dock(th, .main, .dock, panes, .{
        .{base.ct.label(th, "Files")},
        .{base.ct.checkbox(th, .on, .on, .on_text)},
        .{base.ct.label(th, "Log")},
        .{base.ct.label(th, "Props")},
    }), face);
    var h: base.Harness(App, base.ComptimeUi(PageState, spec, th), test_limits) = .{};
};

test "ct.dock restyled: the same frames as openFace, drags, F6 and keys" {
    const h = &restyled.h;
    h.init();
    var in: Input = .{ .viewport = .{ 400, 300 } };
    _ = try h.frame(&in);
    const id: Id = .from("main");
    // Drag each handle 20 px along its axis.
    inline for (.{ 1, 2, 4 }, .{ .x, .x, .y }) |k, axis| {
        const t = &h.ctx.trees[h.ctx.cur];
        const r = t.rect(t.find(id.with(k).with(1)));
        in.pointer = .{ (r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2 };
        const d: [2]f32 = if (axis == .x) .{ 20, 0 } else .{ 0, 20 };
        for ([_]f32{ 0, 0, 1, 1 }, [_]bool{ false, true, true, false }) |m, down| {
            in.pointer[0] += d[0] * m * 0.5;
            in.pointer[1] += d[1] * m * 0.5;
            in.buttons.left = down;
            _ = try h.frame(&in);
        }
    }
    try testing.expect(h.app.dock.splits[0] > 0.2 and h.app.dock.splits[1] > 0.75 and h.app.dock.splits[3] > 0.75);
    // Down on the bottom handle, focused by its drag, moves it; then F6 three times from
    // outside the panes (left, centre, bottom) and Shift+F6 once (centre).
    const split = h.app.dock.splits[3];
    const down = [1]Input.Event{.{ .kind = .press, .code = keys_zig.map.down }};
    in.events = &down;
    _ = try h.frame(&in);
    try testing.expectApproxEqAbs(split + 0.05, h.app.dock.splits[3], 1e-6);
    for ([_]bool{ false, false, false, true }) |shift| {
        const ev = [1]Input.Event{.{ .kind = .press, .code = f6, .mods = .{ .shift = shift } }};
        in.events = &ev;
        _ = try h.frame(&in);
    }
    in.events = &.{};
    _ = try h.frame(&in);
    try testing.expectEqual(@backingInt(paneId(id, .centre)), h.ctx.inter.focus);
    try testing.expectEqual(@TypeOf(h.ui).Events.Widget.main_centre, h.ui.focus.?);
    try testing.expectEqual(h.app.dock, h.ui.signals.state.dock);
}

test "openFace: the theme's style draws as open" {
    const S = struct {
        var st: [2]State = .{ .{}, .{} };
        fn build(f: *Frame, k: u1) void {
            const th: *const Theme = &.default;
            var d = if (k == 0) open(f, th, .from("dock"), &st[k], .{}) else openFace(f, th, .from("dock"), &st[k], .{}, rootStyle(th));
            inline for (0..5) |p| {
                d.pane(f, @fromBackingInt(@intCast(p)));
                _ = base.label(f, th, "pane");
            }
            d.close(f);
        }
    };
    try base.expectSameFace(test_limits, S.build, .{ 81, 150 });
    try testing.expectEqual(S.st[0], S.st[1]);
}

/// A comptime page with runtime regions nested in its widgets (a fit region in a dock pane in a
/// split, a fixed one in a toolbar), each filled by a runtime `Frame` and composed into the
/// page's draw list, against the same page built all at run time: Schemify's build emits the
/// first and must draw the second.
const nested = struct {
    const th: Theme = .default;
    const interop = @import("../comptime/interop.zig");
    const list_zig = @import("list.zig");
    const draw_list = @import("../draw/draw_list.zig");
    const DrawList = draw_list.DrawList;
    const Context = context.Context;
    const items = [_][]const u8{ "R1", "C1", "L1", "Q1" };
    const panes: Panes = .{ .left = false, .top = false, .right = false };
    // Regions are laid out at whole pixels, so the page puts them there: a toolbar of a fixed
    // height with the status first, the split at 30% of 480 px.
    const toolbar: Style = .{ .dir = .x, .size = .{ .fill, .px(40) }, .pad = @splat(6), .gap = 6, .fill = th.panel };
    // A region clips what its owner builds in it, so its run-time twin clips too.
    const status_style: Style = .{ .size = .{ .px(120), .px(24) }, .clip = true };
    const area: Style = .{ .size = .{ .fill, .fill } };
    const PageState = struct { split: f32 = 0.3, dock: State = .{}, files: []const u8 = "Files", log: []const u8 = "Log", save_text: []const u8 = "Save" };
    const spec = spec_zig.col(.{ .size = .{ .fill, .fill } }, .{
        spec_zig.row(toolbar, .{ interop.region(.status, status_style), base.ct.button(th, .save, .save_text) }),
        spec_zig.col(area, .{splitter.ct.splitter(th, .split_handle, .x, .split, .{base.ct.label(th, .files)}, .{ct.dock(th, .main, .dock, panes, .{
            .{interop.fitRegion(.parts, .{})},
            .{base.ct.label(th, .log)},
        })})}),
    });

    /// The region's content, a data-built list in a column sized to it.
    fn parts(f: *Frame, sel: *u32) void {
        _ = f.open(.none, .{});
        _ = list_zig.list(f, &th, .from("parts"), &items, sel);
        f.close();
    }

    fn status(f: *Frame, sel: u32) void {
        _ = f.textf("Selected {d}", .{sel}, base.labelText(&th));
    }

    /// The same page at run time; the regions' places are columns of their styles.
    const App = struct {
        split: f32 = 0.3,
        dock: State = .{},
        sel: u32 = types.none,
        pub fn build(app: *App, f: *Frame) void {
            _ = f.open(.none, .{ .size = .{ .fill, .fill } });
            _ = f.open(.none, toolbar);
            _ = f.open(.none, status_style);
            status(f, app.sel);
            f.close();
            _ = base.button(f, &th, .from("save"), "Save");
            f.close();
            _ = f.open(.none, area);
            splitter.open(f, &th, .from("split"), .x, &app.split);
            _ = base.label(f, &th, "Files");
            splitter.handle(f, &th, .from("split"), .x, app.split);
            var d = open(f, &th, .from("main"), &app.dock, panes);
            d.pane(f, .centre);
            _ = f.open(.none, .{});
            parts(f, &app.sel);
            f.close();
            d.pane(f, .bottom);
            _ = base.label(f, &th, "Log");
            d.close(f);
            splitter.close(f);
            f.close();
            f.close();
        }
    };

    const page_limits: context.Limits = .{ .nodes = 64, .texts = 16, .customs = 2, .strings = 512, .depth = 24 };
    const guest_limits: context.Limits = .{ .nodes = 16, .texts = 8, .customs = 1, .strings = 128, .depth = 8 };

    /// A draw list with room for the page's rows and both guests'.
    const Out = struct {
        buf: [bytes]u8 align(mem.column_align) = undefined,
        draw: DrawList = undefined,
        strings: [1024]u8 = undefined,
        const bytes = blk: {
            var counter: mem.Carver = .{ .buf = null };
            _ = DrawList.init(&counter, 128, 32, 4);
            break :blk counter.off;
        };
        fn init(o: *Out) void {
            var carver: mem.Carver = .{ .buf = &o.buf };
            o.draw = DrawList.init(&carver, 128, 32, 4);
        }
    };

    const Mixed = struct {
        ui: base.ComptimeUi(PageState, spec, th) = .{},
        bufs: [2][Context.requiredBytes(guest_limits)]u8 align(mem.column_align) = undefined,
        ctx: [2]Context = undefined,
        out: [2]Out = .{ .{}, .{} },
        sel: u32 = types.none,
        /// The list's size as last measured; a region of no size paints no command to compose
        /// into, so it starts at one pixel.
        fit: [2]f32 = .{ 1, 1 },

        fn init(m: *Mixed) !void {
            m.* = .{};
            for (&m.ctx, &m.bufs) |*c, *b| c.* = try .init(b, guest_limits);
            for (&m.out) |*o| o.init();
        }

        fn rect4(r: types.Rect) [4]f32 {
            return .{ r.x0, r.y0, r.x1, r.y1 };
        }

        /// One frame: the page (laid out again when the list's size changed last frame), then
        /// each region's runtime frame over its part of the input, composed in its place.
        fn frame(m: *Mixed, in: *const Input) !*const DrawList {
            var top = m.ui.frame(in);
            if (interop.setFit(&m.ui, .parts, m.fit)) top = m.ui.rebuild(in);
            // The status first, as the page builds it before the list: it shows last frame's
            // selection.
            const status_in = interop.regionInput(in, rect4(top.tree.rect(top.tree.find(.from("status")))));
            var f2 = m.ctx[1].begin(&status_in);
            status(&f2, m.sel);
            const g2 = f2.end(.{});
            try interop.compose(&m.out[0].draw, top.draw, g2.draw, @backingInt(Id.from("status")), &m.out[0].strings);
            const list_in = interop.regionInput(in, rect4(top.tree.rect(top.tree.find(.from("parts")))));
            var f = m.ctx[0].begin(&list_in);
            parts(&f, &m.sel);
            const g = f.end(.{});
            const content = g.tree.rect(1);
            m.fit = .{ content.w(), content.h() };
            try interop.compose(&m.out[1].draw, &m.out[0].draw, g.draw, @backingInt(Id.from("parts")), &m.out[1].strings);
            return &m.out[1].draw;
        }
    };

    /// What a draw list paints, in paint order: each quad and text run with what of it shows
    /// (its rect cut to its clip), its look and its text; batching and clip rects aside.
    const Prim = struct { rect: [4]f32, shown: [4]f32, look: [17]u32 = @splat(0), text: []const u8 = "" };

    fn shown(rect: [4]f32, clip: [4]f32) [4]f32 {
        const r: [4]f32 = .{ @max(rect[0], clip[0]), @max(rect[1], clip[1]), @min(rect[2], clip[2]), @min(rect[3], clip[3]) };
        return if (r[2] > r[0] and r[3] > r[1]) r else @splat(0);
    }

    fn prims(d: *const DrawList, out: []Prim) []Prim {
        var n: usize = 0;
        for (0..d.cmd_len) |i| switch (d.command(@intCast(i))) {
            .quads => |b| for (d.quads[b.first..][0..b.count]) |q| {
                out[n] = .{ .rect = q.rect, .shown = shown(q.rect, q.clip) };
                out[n].look[0..4].* = @bitCast(q.radii);
                out[n].look[4..8].* = @bitCast(q.uv);
                out[n].look[8..12].* = @bitCast(q.params);
                out[n].look[12] = q.fill;
                out[n].look[13] = q.border_color;
                out[n].look[14] = @bitCast(q.border);
                out[n].look[15] = @bitCast(q.opacity);
                n += 1;
            },
            .text => |k| {
                const r = d.runs[k];
                out[n] = .{ .rect = r.rect, .shown = shown(r.rect, r.clip), .text = d.strings[r.start..][0..r.bytes] };
                out[n].look[0] = @bitCast(r.px);
                out[n].look[1] = r.color;
                out[n].look[2] = r.font;
                out[n].look[3] = @bitCast(r.opacity);
                n += 1;
            },
            else => {},
        };
        return out[0..n];
    }

    fn expectSamePaint(a: *const DrawList, b: *const DrawList) !void {
        var pa: [256]Prim = undefined;
        var pb: [256]Prim = undefined;
        const x = prims(a, &pa);
        const y = prims(b, &pb);
        try testing.expectEqual(x.len, y.len);
        for (x, y) |p, q| {
            try testing.expectEqual(p.rect, q.rect);
            try testing.expectEqual(p.shown, q.shown);
            try testing.expectEqual(p.look, q.look);
            try testing.expectEqualStrings(p.text, q.text);
        }
    }

    var mixed: Mixed = .{};
    var buf: [Context.requiredBytes(page_limits)]u8 align(mem.column_align) = undefined;
};

test "regions in a comptime page's dock and toolbar paint as the page built at run time" {
    const m = &nested.mixed;
    try m.init();
    var ctx = try nested.Context.init(&nested.buf, nested.page_limits);
    var app: nested.App = .{};
    var in: Input = .{ .viewport = .{ 480, 320 } };
    const Step = struct {
        fn run(mm: *nested.Mixed, c: *nested.Context, a: *nested.App, i: *const Input) !void {
            const mixed_draw = try mm.frame(i);
            var f = c.begin(i);
            a.build(&f);
            const out = f.end(.{});
            try nested.expectSamePaint(out.draw, mixed_draw);
            try testing.expectEqual(a.sel, mm.sel);
        }
    };
    // The first frame measures the list; the second lays the region out to it.
    _ = try m.frame(&in);
    {
        var f = ctx.begin(&in);
        app.build(&f);
        _ = f.end(.{});
    }
    try Step.run(m, &ctx, &app, &in);
    // Click the third item: selected in both, focus in the list.
    const t = &ctx.trees[ctx.cur];
    const box = t.rect(t.find(.from("parts")));
    in.pointer = .{ (box.x0 + box.x1) / 2, box.y0 + nested.list_zig.inset(&nested.th) + nested.list_zig.rowHeight(&nested.th) * 2.5 };
    for ([_]bool{ true, false }) |down| {
        in.buttons.left = down;
        try Step.run(m, &ctx, &app, &in);
    }
    try testing.expectEqual(@as(u32, 2), app.sel);
    try testing.expectEqual(@backingInt(Id.from("parts")), m.ctx[0].inter.focus);
    // Down moves the focused list's selection; the status region shows it.
    const ev = [1]Input.Event{.{ .kind = .press, .code = keys_zig.map.down }};
    in.events = &ev;
    try Step.run(m, &ctx, &app, &in);
    in.events = &.{};
    try Step.run(m, &ctx, &app, &in);
    try testing.expectEqual(@as(u32, 3), app.sel);
}
