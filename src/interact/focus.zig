//! focus: keyboard focus on top of `Interaction.focus`. The pointer sets focus in
//! `Interaction.step` (prototype/ui.zig: a press on a node that senses focus); this file adds
//! the ring that shows where focus is and the keys that move it. Tier 0: no allocator, no I/O.
//!
//! The focused id stays in `Interaction.focus`, so `Interaction.response(id).focused` keeps
//! reporting it; `Focus.step` runs after `Interaction.step` and writes it there.

const std = @import("std");
const simd = @import("../core/simd.zig");
const types = @import("../core/types.zig");
const Tree = @import("../core/tree.zig").Tree;
const Input = @import("../core/input.zig").Input;
const Interaction = @import("interaction.zig").Interaction;
const mem = @import("../core/mem.zig");
const Rect = types.Rect;
const none = types.none;

const W = simd.lanes;

/// Scancodes of the keys that move focus. `Input.Keys` is indexed by the host's scancodes; the
/// defaults are USB HID usage ids (what SDL and the web's `KeyboardEvent.code` map to), and a
/// host with other codes sets its own.
pub const Keymap = struct {
    tab: u8 = 0x2b,
    right: u8 = 0x4f,
    left: u8 = 0x50,
    down: u8 = 0x51,
    up: u8 = 0x52,
    home: u8 = 0x4a,
    end: u8 = 0x4d,
};

/// The focus scope column set: which nodes group their focusable descendants (a toolbar, a
/// radio group, a listbox, a tab list), and what `scan` derives from that. One row per node of
/// the tree it is scanned with; the caller keeps it with that tree (last frame's, for `step`).
pub const Scopes = struct {
    c: Columns,
    /// Written by `scan`: the open modal layer, the last row whose `kind` has `trap`, or
    /// `none`. Later rows are on top, so a dialog opened from a dialog is the one in front.
    modal: u32 = none,

    /// `kind` bits.
    pub const group: u8 = 1;
    /// A modal layer (dialog, sheet, open menu): while it is in the tree, focus stays among
    /// its descendants, as the WAI-ARIA APG modal dialog pattern asks.
    pub const trap: u8 = 2;

    pub const Columns = struct {
        /// Set by the caller, bits: `group` for a node whose focusable descendants are one
        /// composite widget (WAI-ARIA APG): Tab enters and leaves it as one stop, arrows move
        /// inside. `trap` for a modal layer.
        kind: []u8,
        /// Written by `scan`: the row of the nearest group above the node, or `none`.
        group: []u32,
        /// Written by `scan`, at group rows: the group's first focusable row, or `none`.
        lead: []u32,
        /// Written by `scan`: 1 for a Tab stop, a focusable row that is in no group or is its
        /// group's lead.
        stop: []u8,
    };

    /// One row per node of a tree of capacity `cap`, plus the spare rows every column has.
    pub fn init(carver: *mem.Carver, cap: u32) Scopes {
        std.debug.assert(cap > 0);
        return .{ .c = carver.columns(Columns, simd.rows(cap)) };
    }
    /// Clears every `kind`, for the next frame.
    pub fn reset(sc: *Scopes) void {
        @memset(sc.c.kind, 0);
    }
};

/// Fills `group`, `lead`, `stop` and `trap` from `kind`, `parent`, `sense` and `id`. One forward sweep
/// (a child needs its parent's group), run once the tree is built. Rows outside groups write
/// their lead to a spare row, so the sweep has no branch on the group.
pub fn scan(t: *const Tree, sc: *Scopes) void {
    sc.modal = none;
    if (t.len == 0) return;
    const c = &sc.c;
    const parent = t.c.parent;
    const spare: u32 = @intCast(simd.padded(t.cap));
    const focusable: u8 = @bitCast(types.Sense{ .focus = true });
    c.group[0] = none;
    c.lead[0] = none;
    c.stop[0] = @intFromBool(simd.andB((t.c.sense[0] & focusable) != 0, t.c.id[0] != 0));
    var trap = pick(u32, (c.kind[0] & Scopes.trap) != 0, 0, none);
    for (1..t.len) |i| {
        const p = parent[i];
        const g = pick(u32, (c.kind[p] & Scopes.group) != 0, p, c.group[p]);
        c.group[i] = g;
        c.lead[i] = none;
        const able = simd.andB((t.c.sense[i] & focusable) != 0, t.c.id[i] != 0);
        const slot = @min(g, spare);
        // `i` when able, else all ones: rows rise, so the first able row stays the minimum.
        c.lead[slot] = @min(c.lead[slot], @as(u32, @intCast(i)) | -%@as(u32, @intFromBool(!able)));
        c.stop[i] = @intFromBool(simd.andB(able, simd.orB(g == none, c.lead[slot] == i)));
        trap = pick(u32, (c.kind[i] & Scopes.trap) != 0, @intCast(i), trap);
    }
    sc.modal = trap;
}

/// Keyboard-focus state carried from frame to frame. Plain data; the caller owns it and calls
/// `step` once per frame, after `Interaction.step`.
pub const Focus = struct {
    /// Draw the focus ring. Set by a key press, cleared by a pointer press: the ring shows for
    /// keyboard users and stays out of the way of mouse users (CSS `:focus-visible`).
    visible: bool = false,
    /// How far the ring sits outside the focused node's rect, in logical pixels.
    ring_width: f32 = 2,
    keys: Keymap = .{},
    /// Left button last frame, to see presses.
    left: bool = false,
    /// Focus at the end of the last step, to put back when the pointer takes focus out of a
    /// modal layer.
    last: u32 = 0,
    /// Open modal layers, oldest first, by id, with the focus each one opened over: what to
    /// put back when it closes. Layers nested deeper than `max_layers` are not remembered.
    layers: [max_layers]u32 = @splat(0),
    saved: [max_layers]u32 = @splat(0),
    depth: u32 = 0,
    /// Bit `e` is set when `in.events[e]` moved focus this step, so it is not also delivered
    /// to a widget (`keyboard.route`). Events past the 64th are never marked.
    taken: u64 = 0,

    pub const max_layers = 8;

    /// Advances by one frame. Run after `Interaction.step` on the same input and tree: `prev`
    /// is last frame's tree, which the keys move focus through. Tab moves to the next node
    /// that senses focus in row order (tree order, as the web's tab order with no tabindex),
    /// Shift+Tab to the previous one; both wrap. Rows with id 0 cannot hold focus and are
    /// skipped. Key repeats move again.
    ///
    /// Inside a group (`Scopes`, scanned on `prev`) the group is one Tab stop: Tab enters it at
    /// its first focusable row and leaves it from any row. Arrows move between the group's
    /// focusable rows (Right and Down forward, Left and Up back, wrapping) and Home and End go
    /// to its first and last, as the WAI-ARIA APG keyboard interface asks of composite widgets.
    /// Outside a group, arrows and Home/End leave focus alone for the focused widget to use.
    ///
    /// While a modal layer is open (`Scopes.modal`) focus stays inside it: Tab and Shift+Tab
    /// wrap among its stops, and focus found outside it (the layer just opened, or a click
    /// behind it) moves in, back to where it was in the layer, else to its first stop, else
    /// to nothing.
    ///
    /// When a layer closes, focus goes back to what had it when the layer opened, usually the
    /// button that opened it (APG dialog pattern); closing several at once goes back to what
    /// was focused before the oldest of them. Layers are told apart by id, so a modal layer
    /// needs one.
    pub fn step(s: *Focus, it: *Interaction, prev: *const Tree, sc: *const Scopes, in: *const Input) void {
        const press = simd.andB(in.buttons.left, !s.left);
        const focusable: u8 = @bitCast(types.Sense{ .focus = true });
        const k = s.keys;
        const c = &sc.c;
        const last = prev.cap - 1;
        s.restore(it, pick(u32, sc.modal != none, prev.c.id[@min(sc.modal, last)], 0));
        // The rows focus may be in: the open layer's descendants, or the whole tree.
        const trapped = sc.modal != none;
        const lo_t = pick(u32, trapped, sc.modal +% 1, 0);
        const hi_t = pick(u32, trapped, prev.c.end[@min(sc.modal, last)], prev.len);
        {
            const cur = simd.find(prev.c.id, prev.len, it.focus);
            const was = simd.find(prev.c.id, prev.len, s.last);
            const first = seek(prev, c.stop, 1, lo_t, hi_t, lo_t -% 1, false);
            const to = pick(u32, (was -% lo_t) < (hi_t -% lo_t), was, first);
            const id = pick(u32, to != none, prev.c.id[@min(to, last)], 0);
            const out = (cur -% lo_t) >= (hi_t -% lo_t);
            it.focus = pick(u32, simd.andB(trapped, out), id, it.focus);
        }
        var key = false;
        s.taken = 0;
        for (in.events, 0..) |e, ei| {
            const down = simd.orB(e.kind == .press, e.kind == .repeat);
            key = simd.orB(key, e.kind == .press);
            const cur = simd.find(prev.c.id, prev.len, it.focus);
            const row = @min(cur, last);
            const g = pick(u32, cur != none, c.group[row], none);
            const gr = @min(g, last);
            const in_group = g != none;
            // Tab: from inside a group, as if from its lead, so Shift+Tab leaves it too.
            const from_tab = pick(u32, in_group, c.lead[gr], cur);
            const to_tab = seek(prev, c.stop, 1, lo_t, hi_t, from_tab, e.mods.shift);
            // Arrows: the group's rows [g + 1, end[g]); an empty range outside a group.
            const lo = g +% 1;
            const hi = pick(u32, in_group, prev.c.end[gr], 0);
            const fwd = simd.orB(e.code == k.right, e.code == k.down);
            const back = simd.orB(e.code == k.left, e.code == k.up);
            const home = e.code == k.home;
            const end = e.code == k.end;
            // Home is "forward from just before the range", End "back from just after it".
            const from_arrow = pick(u32, home, g, pick(u32, end, hi, cur));
            const to_arrow = seek(prev, prev.c.sense, focusable, lo, hi, from_arrow, simd.orB(back, end));
            const arrow = simd.orB(simd.orB(fwd, back), simd.orB(home, end));
            const next = pick(u32, e.code == k.tab, to_tab, pick(u32, arrow, to_arrow, none));
            const id = prev.c.id[@min(next, last)];
            const move = simd.andB(down, next != none);
            it.focus = pick(u32, move, id, it.focus);
            const bit = @as(u64, @intFromBool(simd.andB(move, ei < 64))) << @intCast(ei & 63);
            s.taken |= bit;
        }
        // A key after a press shows the ring; a press after a key hides it.
        s.visible = simd.andB(simd.orB(s.visible, key), !press);
        s.left = in.buttons.left;
        s.last = it.focus;
    }

    /// Follows the open modal layer `top` (an id, 0 for none): a new layer is pushed with the
    /// focus it opens over; a layer further down the stack, or none, pops back to it and puts
    /// back the focus saved by the first layer popped. Once per frame over at most
    /// `max_layers` entries.
    fn restore(s: *Focus, it: *Interaction, top: u32) void {
        const open = s.layers[0..s.depth];
        if (s.depth > 0 and open[s.depth - 1] == top) return;
        // Where `top` is in the stack: its depth, else 0 (`top` 0 closes them all).
        var keep: u32 = 0;
        for (open, 1..) |id, d| keep = pick(u32, id == top, @intCast(d), keep);
        if (keep == 0 and top != 0) {
            // Newly open. A full stack keeps its oldest entries and replaces the newest.
            const d = @min(s.depth, max_layers - 1);
            s.layers[d] = top;
            s.saved[d] = it.focus;
            s.depth = d + 1;
            return;
        }
        if (keep < s.depth) {
            it.focus = s.saved[keep];
            s.last = it.focus;
            s.depth = keep;
        }
    }

    /// Where to draw the focus ring this frame: the focused node's rect in `t`, grown by
    /// `ring_width`. A zero rect when the ring is hidden, nothing is focused, or the focused
    /// node is not in `t`, so the caller can draw it unconditionally.
    pub fn ring(s: *const Focus, it: *const Interaction, t: *const Tree) Rect {
        const row = simd.find(t.c.id, t.len, it.focus);
        const r = t.rect(@min(row, t.cap - 1));
        const m = simd.b2f(simd.andB(simd.andB(s.visible, it.focus != 0), row != none));
        const g = s.ring_width;
        return .{ .x0 = (r.x0 - g) * m, .y0 = (r.y0 - g) * m, .x1 = (r.x1 + g) * m, .y1 = (r.y1 + g) * m };
    }
};

/// The row after `cur` (before it with `back`) among rows `[lo, hi)` of `t` whose `col` has a
/// bit of `mask` set and whose id is not 0, wrapping around the range; `none` when there is no
/// such row. `cur` may be outside the range or `none`: forward then gives the first row and
/// back the last. One SIMD sweep, no early exit.
///
/// Wrapping is the order of the keys `r -% (cur + 1)`: rows after `cur` come first, then the
/// ones before it, then `cur` itself. Back multiplies the keys by -1, which reverses it.
pub fn seek(t: *const Tree, col: []const u8, mask: u8, lo: u32, hi: u32, cur: u32, back: bool) u32 {
    const sign: u32 = -%@as(u32, @intFromBool(back)) | 1; // 1 or -1
    const base = cur +% sign;
    const maskv: simd.Bytes = @splat(mask);
    const zero8: simd.Bytes = @splat(0);
    var best = simd.u(none);
    var any: simd.B = @splat(false);
    var i: usize = 0;
    const n = simd.padded(hi);
    while (i < n) : (i += W) {
        const r = simd.iota + simd.u(@intCast(i));
        const bits_: simd.Bytes = col[i..][0..W].*;
        const take = ((bits_ & maskv) != zero8) & (simd.loadU(t.c.id, i) != simd.u(0)) &
            (r >= simd.u(lo)) & (r < simd.u(hi));
        best = @min(best, @select(u32, take, (r -% simd.u(base)) *% simd.u(sign), simd.u(none)));
        any = any | take;
    }
    const found = @reduce(.Or, any);
    return (base +% @reduce(.Min, best) *% sign) | -%@as(u32, @intFromBool(!found));
}

/// `c ? a : b` as a cmov, as `pick` in interaction.zig (Zig 0.18 re-branches mask selects on
/// loaded operands; docs/CHECKS.md).
inline fn pick(comptime T: type, c: bool, a: T, b: T) T {
    return if (c) blk: {
        @branchHint(.unpredictable);
        break :blk a;
    } else b;
}

const testing = std.testing;
const Replay = @import("../core/input.zig").Replay;
const Sense = types.Sense;
const Id = types.Id;

/// A form: name field, two radio buttons, ok, cancel; all focusable and named.
const Form = struct {
    raw: [64 * 1024]u8 align(mem.column_align) = undefined,
    t: Tree = undefined,
    sc: Scopes = undefined,

    const ids = [_]Id{ Id.from("name"), Id.from("red"), Id.from("blue"), Id.from("ok"), Id.from("cancel") };

    fn build(f: *Form) void {
        const layout = @import("../layout/layout.zig");
        const Texts = @import("../core/texts.zig").Texts;
        var carver: mem.Carver = .{ .buf = &f.raw };
        f.t = Tree.init(&carver, 16);
        var tx = Texts.init(&carver, 1);
        f.sc = Scopes.init(&carver, 16);
        const t = &f.t;
        const root = t.push(0, .none, &.{ .size = .{ .px(300), .px(200) }, .gap = 10 });
        for (ids) |id| {
            const n = t.push(root, id, &.{ .size = .{ .px(100), .px(20) } });
            t.seal(n);
            t.c.sense[n] = @bitCast(Sense.button);
        }
        t.seal(root);
        layout.run(t, &tx, .{ 300, 200 });
    }
};

/// Steps `Interaction` and `Focus` through a recording; returns per-frame focus, ring state.
const Walk = struct {
    it: Interaction = .{},
    fo: Focus = .{},
    focus: [16]u32 = undefined,
    ring: [16]Rect = undefined,
    n: usize = 0,

    /// Scans `sc` on `t` first, as the front end does after building the tree.
    fn run(w: *Walk, t: *const Tree, sc: *Scopes, src: []const u8) !void {
        scan(t, sc);
        var text: [16]u8 = undefined;
        var events: [8]Input.Event = undefined;
        var contacts: [1]Input.Contact = undefined;
        const buf: Replay.Buffers = .{ .text = &text, .events = &events, .contacts = &contacts };
        var r: Replay = .{ .src = src };
        while (try r.next(buf)) |in| : (w.n += 1) {
            w.it.step(t, in);
            w.fo.step(&w.it, t, sc, in);
            w.focus[w.n] = w.it.focus;
            w.ring[w.n] = w.fo.ring(&w.it, t);
        }
    }
};

fn bi(id: Id) u32 {
    return @backingInt(id);
}

test "walkthrough: the ring shows for keys, hides for the pointer, follows focus" {
    var f: Form = .{};
    f.build();
    var w: Walk = .{};
    // The app focuses the name field (code sets `Interaction.focus`); a key shows the ring; a click on "ok" moves focus and
    // hides it; a key shows it again on "ok"; a click on nothing focusable clears focus (as
    // `Interaction.step` does) and the ring with it.
    w.it.focus = bi(Form.ids[0]);
    try w.run(&f.t, &f.sc,
        \\frame
        \\frame
        \\press 4
        \\frame
        \\pointer 50 100
        \\buttons left
        \\frame
        \\buttons
        \\release 4
        \\frame
        \\press 5
        \\frame
        \\pointer 250 190
        \\buttons left
    );
    try testing.expectEqual(6, w.n);
    const name = bi(Form.ids[0]);
    const ok = bi(Form.ids[3]);
    try testing.expectEqualSlices(u32, &.{ name, name, ok, ok, ok, 0 }, w.focus[0..6]);
    // Name is at y 0..20, ok at y 90..110 (20 high, 10 apart); the ring is 2 px outside.
    try testing.expectEqual(Rect{}, w.ring[0]);
    try testing.expectEqual(Rect{ .x0 = -2, .y0 = -2, .x1 = 102, .y1 = 22 }, w.ring[1]);
    try testing.expectEqual(Rect{}, w.ring[2]);
    try testing.expectEqual(Rect{}, w.ring[3]); // a release is not a press
    try testing.expectEqual(Rect{ .x0 = -2, .y0 = 88, .x1 = 102, .y1 = 112 }, w.ring[4]);
    try testing.expectEqual(Rect{}, w.ring[5]);
}

test "ring: nothing focused, or the focused node gone from the tree, draws nothing" {
    var f: Form = .{};
    f.build();
    var it: Interaction = .{};
    const fo: Focus = .{ .visible = true };
    try testing.expectEqual(Rect{}, fo.ring(&it, &f.t));
    it.focus = bi(Id.from("absent"));
    try testing.expectEqual(Rect{}, fo.ring(&it, &f.t));
    it.focus = bi(Form.ids[4]);
    try testing.expectEqual(Rect{ .x0 = -2, .y0 = 118, .x1 = 102, .y1 = 142 }, fo.ring(&it, &f.t));
}

test "walkthrough: Tab and Shift+Tab move through the form in tree order and wrap" {
    var f: Form = .{};
    f.build();
    // A row that senses only hover and an anonymous focusable row are not stops.
    f.t.c.sense[2] = @bitCast(Sense{ .hover = true });
    f.t.c.id[4] = 0;
    var w: Walk = .{};
    // 43 is Tab (HID). Nothing focused: Tab goes to the first stop. Two Tabs in one frame
    // move twice; a repeat moves again; another key (44, Space) does not move.
    try w.run(&f.t, &f.sc,
        \\frame
        \\press 43
        \\frame
        \\press 43
        \\frame
        \\press 43
        \\press 43
        \\frame
        \\repeat 43
        \\frame
        \\press 43 shift
        \\frame
        \\press 43 shift
        \\press 43 shift
        \\frame
        \\press 43 shift
        \\frame
        \\press 44
    );
    const id = Form.ids;
    try testing.expectEqualSlices(u32, &.{
        bi(id[0]), bi(id[2]), bi(id[0]), bi(id[2]), bi(id[0]), bi(id[2]), bi(id[0]), bi(id[0]),
    }, w.focus[0..w.n]);
    // Every Tab is a key, so the ring is on throughout, on the focused node.
    for (w.ring[0..w.n], w.focus[0..w.n]) |r, k| {
        const row = f.t.find(@fromBackingInt(k));
        try testing.expectEqual(f.t.rect(row).y0 - 2, r.y0);
    }
}

test "seek: wraps both ways, skips inert and anonymous rows, none when nothing qualifies" {
    var f: Form = .{};
    f.build();
    const t = &f.t;
    const m: u8 = @bitCast(Sense{ .focus = true });
    // Rows: 0 root (inert), 1..5 the fields.
    try testing.expectEqual(1, seek(t, t.c.sense, m, 0, t.len, none, false));
    try testing.expectEqual(5, seek(t, t.c.sense, m, 0, t.len, none, true));
    try testing.expectEqual(3, seek(t, t.c.sense, m, 0, t.len, 2, false));
    try testing.expectEqual(1, seek(t, t.c.sense, m, 0, t.len, 5, false));
    try testing.expectEqual(5, seek(t, t.c.sense, m, 0, t.len, 1, true));
    try testing.expectEqual(1, seek(t, t.c.sense, m, 0, t.len, 0, false));
    // A sub-range [2, 4): wraps inside it, and from outside starts at its ends.
    try testing.expectEqual(2, seek(t, t.c.sense, m, 2, 4, 3, false));
    try testing.expectEqual(3, seek(t, t.c.sense, m, 2, 4, 2, false));
    try testing.expectEqual(2, seek(t, t.c.sense, m, 2, 4, 0, false));
    try testing.expectEqual(3, seek(t, t.c.sense, m, 2, 4, 5, true));
    // The only stop is found from itself.
    t.c.id[3] = 0;
    try testing.expectEqual(2, seek(t, t.c.sense, m, 2, 4, 2, false));
    try testing.expectEqual(2, seek(t, t.c.sense, m, 2, 4, 2, true));
    // Nothing qualifies.
    t.c.id[2] = 0;
    try testing.expectEqual(none, seek(t, t.c.sense, m, 2, 4, 2, false));
    try testing.expectEqual(none, seek(t, t.c.sense, m, 0, 0, none, true));
}

/// root { name, colours (group) { red, blue, green }, ok }, all named; the group node is inert.
const Radios = struct {
    raw: [64 * 1024]u8 align(mem.column_align) = undefined,
    t: Tree = undefined,
    sc: Scopes = undefined,

    const name = Id.from("name");
    const colours = Id.from("colours");
    const red = Id.from("red");
    const blue = Id.from("blue");
    const green = Id.from("green");
    const ok = Id.from("ok");

    fn build(f: *Radios) void {
        var carver: mem.Carver = .{ .buf = &f.raw };
        f.t = Tree.init(&carver, 16);
        f.sc = Scopes.init(&carver, 16);
        const t = &f.t;
        const root = t.push(0, .none, &.{});
        f.leaf(root, name);
        const group = t.push(root, colours, &.{ .dir = .x });
        f.sc.c.kind[group] = Scopes.group;
        for ([_]Id{ red, blue, green }) |id| f.leaf(group, id);
        t.seal(group);
        f.leaf(root, ok);
        t.seal(root);
    }
    fn leaf(f: *Radios, parent: u32, id: Id) void {
        const n = f.t.push(parent, id, &.{ .size = .{ .px(40), .px(20) } });
        f.t.seal(n);
        f.t.c.sense[n] = @bitCast(Sense.button);
    }
};

test "walkthrough: a radio group is one Tab stop; arrows, Home and End move inside it" {
    var f: Radios = .{};
    f.build();
    var w: Walk = .{};
    // HID: 43 Tab, 79 Right, 80 Left, 81 Down, 82 Up, 74 Home, 77 End.
    try w.run(&f.t, &f.sc,
        \\# name; arrows outside a group do nothing
        \\frame
        \\press 43
        \\press 79
        \\# into the group at its first item, then along it and around
        \\frame
        \\press 43
        \\frame
        \\press 79
        \\frame
        \\press 81
        \\frame
        \\press 79
        \\frame
        \\press 80
        \\frame
        \\press 82
        \\frame
        \\press 77
        \\frame
        \\press 74
        \\# out of the group from blue, forward and back
        \\frame
        \\press 79
        \\press 43
        \\frame
        \\press 43 shift
        \\frame
        \\press 79
        \\press 43 shift
        \\# from name: through the group in one stop
        \\frame
        \\press 43
        \\press 43
    );
    const R = Radios;
    try testing.expectEqualSlices(u32, &.{
        bi(R.name),  bi(R.red),  bi(R.blue),  bi(R.green), bi(R.red),
        bi(R.green), bi(R.blue), bi(R.green), bi(R.red),   bi(R.ok),
        bi(R.red),   bi(R.name), bi(R.ok),
    }, w.focus[0..w.n]);
}

test "scan: groups, leads and Tab stops, with nested and inert rows" {
    var f: Radios = .{};
    f.build();
    const c = &f.sc.c;
    // Rows: 0 root, 1 name, 2 colours, 3 red, 4 blue, 5 green, 6 ok.
    scan(&f.t, &f.sc);
    try testing.expectEqualSlices(u32, &.{ none, none, none, 2, 2, 2, none }, c.group[0..7]);
    try testing.expectEqual(3, c.lead[2]);
    try testing.expectEqualSlices(u8, &.{ 0, 1, 0, 1, 0, 0, 1 }, c.stop[0..7]);
    // red stops sensing focus: blue leads. Making the root a group puts everyone in it; the
    // inner group's lead stays a stop, a group nested in a group.
    f.t.c.sense[3] = 0;
    c.kind[0] = Scopes.group;
    scan(&f.t, &f.sc);
    try testing.expectEqualSlices(u32, &.{ none, 0, 0, 2, 2, 2, 0 }, c.group[0..7]);
    try testing.expectEqual(1, c.lead[0]);
    try testing.expectEqual(4, c.lead[2]);
    try testing.expectEqualSlices(u8, &.{ 0, 1, 0, 0, 1, 0, 0 }, c.stop[0..7]);
}

/// root { name, ok, [dialog (trap) { field, yes, no }] }, 40 x 20 leaves stacked down; the
/// dialog is a float over the top of the window.
const Dialog = struct {
    raw: [64 * 1024]u8 align(mem.column_align) = undefined,
    t: Tree = undefined,
    sc: Scopes = undefined,

    const name = Id.from("name");
    const ok = Id.from("ok");
    const dialog = Id.from("dialog");
    const field = Id.from("field");
    const yes = Id.from("yes");
    const no = Id.from("no");
    const confirm = Id.from("confirm");
    const sure = Id.from("sure");

    /// `open` dialogs: 0, the dialog, or the dialog and a confirmation on top of it.
    fn build(f: *Dialog, open: u32) void {
        const layout = @import("../layout/layout.zig");
        const Texts = @import("../core/texts.zig").Texts;
        var carver: mem.Carver = .{ .buf = &f.raw };
        f.t = Tree.init(&carver, 16);
        var tx = Texts.init(&carver, 1);
        f.sc = Scopes.init(&carver, 16);
        const t = &f.t;
        const root = t.push(0, .none, &.{ .size = .{ .px(200), .px(200) } });
        f.leaf(root, name);
        f.leaf(root, ok);
        if (open > 0) {
            const d = t.push(root, dialog, &.{ .float = true, .offset = .{ 100, 0 } });
            f.sc.c.kind[d] = Scopes.trap;
            for ([_]Id{ field, yes, no }) |id| f.leaf(d, id);
            t.seal(d);
        }
        if (open > 1) {
            const d = t.push(root, confirm, &.{ .float = true, .offset = .{ 100, 100 } });
            f.sc.c.kind[d] = Scopes.trap;
            f.leaf(d, sure);
            t.seal(d);
        }
        t.seal(root);
        layout.run(t, &tx, .{ 200, 200 });
    }
    fn leaf(f: *Dialog, parent: u32, id: Id) void {
        const n = f.t.push(parent, id, &.{ .size = .{ .px(40), .px(20) } });
        f.t.seal(n);
        f.t.c.sense[n] = @bitCast(Sense.button);
    }
};

test "walkthrough: a modal layer keeps focus inside it until it closes" {
    var f: Dialog = .{};
    var w: Walk = .{};
    const D = Dialog;
    f.build(0);
    try w.run(&f.t, &f.sc,
        \\frame
        \\press 43
    );
    // The dialog opens: focus moves to its first stop with no key, then Tab and Shift+Tab
    // wrap inside it.
    f.build(1);
    try w.run(&f.t, &f.sc,
        \\frame
        \\frame
        \\press 43
        \\frame
        \\press 43
        \\press 43
        \\frame
        \\press 43 shift
        \\# a click on "name" behind the dialog: focus goes back to "no"
        \\frame
        \\pointer 10 10
        \\buttons left
        \\frame
        \\buttons
        \\# a click on "yes" in the dialog takes focus as usual
        \\frame
        \\pointer 110 30
        \\buttons left
    );
    try testing.expectEqualSlices(u32, &.{
        bi(D.name), bi(D.field), bi(D.yes), bi(D.field), bi(D.no), bi(D.no), bi(D.no), bi(D.yes),
    }, w.focus[0..w.n]);
    try testing.expectEqual(3, f.sc.modal);
    // Closed again: focus is back on "name", which had it when the dialog opened, and Tab
    // reaches the rows behind.
    f.build(0);
    try w.run(&f.t, &f.sc,
        \\frame
        \\press 43
    );
    try testing.expectEqual(bi(D.ok), w.focus[w.n - 1]);
}

test "step: a modal layer with nothing focusable leaves nothing focused" {
    var f: Dialog = .{};
    f.build(1);
    for (4..7) |r| f.t.c.sense[r] = 0;
    var w: Walk = .{};
    w.it.focus = bi(Dialog.name);
    try w.run(&f.t, &f.sc,
        \\frame
        \\press 43
    );
    try testing.expectEqual(0, w.focus[0]);
}

test "walkthrough: closing a layer gives focus back to what opened it, nested layers too" {
    var f: Dialog = .{};
    var w: Walk = .{};
    const D = Dialog;
    // Tab to "ok"; the app opens the dialog; Tab to "yes"; the app opens the confirmation;
    // closing it returns to "yes", closing the dialog to "ok".
    f.build(0);
    try w.run(&f.t, &f.sc,
        \\frame
        \\press 43
        \\press 43
    );
    f.build(1);
    try w.run(&f.t, &f.sc,
        \\frame
        \\frame
        \\press 43
    );
    f.build(2);
    try w.run(&f.t, &f.sc,
        \\frame
        \\frame
        \\press 43
    );
    f.build(1);
    try w.run(&f.t, &f.sc,
        \\frame
    );
    f.build(0);
    try w.run(&f.t, &f.sc,
        \\frame
    );
    try testing.expectEqualSlices(u32, &.{
        bi(D.ok), bi(D.field), bi(D.yes), bi(D.sure), bi(D.sure), bi(D.yes), bi(D.ok),
    }, w.focus[0..w.n]);
    try testing.expectEqual(0, w.fo.depth);

    // Both closed in one frame: back to what had focus before the first opened.
    f.build(1);
    try w.run(&f.t, &f.sc, "frame\n");
    f.build(2);
    try w.run(&f.t, &f.sc, "frame\n");
    try testing.expectEqual(bi(D.sure), w.focus[w.n - 1]);
    f.build(0);
    try w.run(&f.t, &f.sc, "frame\n");
    try testing.expectEqual(bi(D.ok), w.focus[w.n - 1]);
}

/// Scalar reference for `seek`: walk the range from `cur`, one row at a time, with wrap.
fn seekScalar(t: *const Tree, col: []const u8, mask: u8, lo: u32, hi: u32, cur: u32, back: bool) u32 {
    if (lo >= hi) return none;
    const span = hi - lo;
    // Where the walk starts: just past `cur` inside the range, or at an end from outside it.
    const inside = cur >= lo and cur < hi;
    var k: u32 = 0;
    while (k < span) : (k += 1) {
        const r: u32 = if (inside)
            (if (back) lo + (cur - lo + span - 1 - k) % span else lo + (cur - lo + 1 + k) % span)
        else
            (if (back) hi - 1 - k else lo + k);
        if ((col[r] & mask) != 0 and t.c.id[r] != 0) return r;
    }
    return none;
}

test "seek matches the scalar walk on random trees, ranges and starting rows" {
    var raw: [128 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var t = Tree.init(&carver, 80);
    var seed: u32 = 777;
    const root = t.push(0, .none, &.{});
    for (1..70) |k| {
        seed = seed *% 1103515245 +% 12345;
        const n = t.push(root, @fromBackingInt(@intCast(@as(u32, @intFromBool((seed >> 16) % 3 != 0)) * @as(u32, @intCast(k)))), &.{});
        t.seal(n);
        t.c.sense[n] = @intCast((seed >> 8) % 16);
    }
    t.seal(root);
    const m: u8 = @bitCast(Sense{ .focus = true });
    var found: u32 = 0;
    for (0..400) |_| {
        seed = seed *% 1103515245 +% 12345;
        const lo = (seed >> 4) % 72;
        const hi = @min((seed >> 12) % 75, t.len);
        const cur = switch ((seed >> 20) % 4) {
            0 => none,
            else => (seed >> 24) % 72,
        };
        for ([_]bool{ false, true }) |back| {
            const want = seekScalar(&t, t.c.sense, m, lo, hi, cur, back);
            try testing.expectEqual(want, seek(&t, t.c.sense, m, lo, hi, cur, back));
            found += @intFromBool(want != none);
        }
    }
    try testing.expect(found > 300);
}

test "walkthrough: keyboard only, through a form, a group, a dialog and back" {
    // root { name, colours (group) { red, blue, green }, ok, [dialog (trap) { yes, no }] }
    const S = struct {
        raw: [64 * 1024]u8 align(mem.column_align) = undefined,
        t: Tree = undefined,
        sc: Scopes = undefined,

        fn build(f: *@This(), open: bool) void {
            const layout = @import("../layout/layout.zig");
            const Texts = @import("../core/texts.zig").Texts;
            var carver: mem.Carver = .{ .buf = &f.raw };
            f.t = Tree.init(&carver, 16);
            var tx = Texts.init(&carver, 1);
            f.sc = Scopes.init(&carver, 16);
            const t = &f.t;
            const root = t.push(0, .none, &.{ .size = .{ .px(300), .px(300) } });
            f.leaf(root, "name");
            const g = t.push(root, Id.from("colours"), &.{ .dir = .x });
            f.sc.c.kind[g] = Scopes.group;
            inline for (.{ "red", "blue", "green" }) |n| f.leaf(g, n);
            t.seal(g);
            f.leaf(root, "ok");
            if (open) {
                const d = t.push(root, Id.from("dialog"), &.{ .float = true, .offset = .{ 150, 150 } });
                f.sc.c.kind[d] = Scopes.trap;
                f.leaf(d, "yes");
                f.leaf(d, "no");
                t.seal(d);
            }
            t.seal(root);
            layout.run(t, &tx, .{ 300, 300 });
        }
        fn leaf(f: *@This(), parent: u32, comptime name: []const u8) void {
            const n = f.t.push(parent, Id.from(name), &.{ .size = .{ .px(40), .px(20) } });
            f.t.seal(n);
            f.t.c.sense[n] = @bitCast(Sense.button);
        }
    };
    var f: S = .{};
    var w: Walk = .{};
    f.build(false);
    // Tab to name, into the group, Right to blue, Tab to ok; Enter (40) "opens" the dialog.
    try w.run(&f.t, &f.sc,
        \\frame
        \\press 43
        \\frame
        \\press 43
        \\press 79
        \\frame
        \\press 43
        \\frame
        \\press 40
    );
    f.build(true);
    try w.run(&f.t, &f.sc,
        \\frame
        \\frame
        \\press 43
        \\press 43
        \\press 43
    );
    f.build(false);
    try w.run(&f.t, &f.sc,
        \\frame
        \\frame
        \\press 43 shift
        \\frame
        \\press 80
    );
    const ids = [_][]const u8{ "name", "blue", "ok", "ok", "yes", "no", "ok", "red", "green" };
    try testing.expectEqual(ids.len, w.n);
    inline for (ids, 0..) |name, k| {
        try testing.expectEqual(bi(Id.from(name)), w.focus[k]);
        const ring = w.ring[k];
        // The keyboard user sees the ring every frame, on the focused node of that frame's tree.
        try testing.expect(ring.x1 > ring.x0);
    }
    // `Interaction.response` reports the keyboard's focus.
    try testing.expect(w.it.response(Id.from("green")).focused);
    try testing.expect(!w.it.response(Id.from("red")).focused);
}
