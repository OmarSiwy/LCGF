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

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;
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
