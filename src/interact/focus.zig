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
const Rect = types.Rect;
const none = types.none;

const W = simd.lanes;

/// Scancodes of the keys that move focus. `Input.Keys` is indexed by the host's scancodes; the
/// defaults are USB HID usage ids (what SDL and the web's `KeyboardEvent.code` map to), and a
/// host with other codes sets its own.
pub const Keymap = struct {
    tab: u8 = 0x2b,
};

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

    /// Advances by one frame. Run after `Interaction.step` on the same input and tree: `prev`
    /// is last frame's tree, which the keys move focus through. Tab moves to the next node
    /// that senses focus in row order (tree order, as the web's tab order with no tabindex),
    /// Shift+Tab to the previous one; both wrap. Rows with id 0 cannot hold focus and are
    /// skipped. Key repeats move again.
    pub fn step(s: *Focus, it: *Interaction, prev: *const Tree, in: *const Input) void {
        const press = simd.andB(in.buttons.left, !s.left);
        const focusable: u8 = @bitCast(types.Sense{ .focus = true });
        var key = false;
        for (in.events) |e| {
            const down = simd.orB(e.kind == .press, e.kind == .repeat);
            key = simd.orB(key, e.kind == .press);
            const tab = simd.andB(down, e.code == s.keys.tab);
            const cur = simd.find(prev.c.id, prev.len, it.focus);
            const next = seek(prev, prev.c.sense, focusable, 0, prev.len, cur, e.mods.shift);
            const id = prev.c.id[@min(next, prev.cap - 1)];
            it.focus = simd.selU(simd.andB(tab, next != none), id, it.focus);
        }
        // A key after a press shows the ring; a press after a key hides it.
        s.visible = simd.andB(simd.orB(s.visible, key), !press);
        s.left = in.buttons.left;
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

const testing = std.testing;
const mem = @import("../core/mem.zig");
const Replay = @import("../core/input.zig").Replay;
const Sense = types.Sense;
const Id = types.Id;

/// A form: name field, two radio buttons, ok, cancel; all focusable and named.
const Form = struct {
    raw: [64 * 1024]u8 align(mem.column_align) = undefined,
    t: Tree = undefined,

    const ids = [_]Id{ Id.from("name"), Id.from("red"), Id.from("blue"), Id.from("ok"), Id.from("cancel") };

    fn build(f: *Form) void {
        const layout = @import("../layout/layout.zig");
        const Texts = @import("../core/texts.zig").Texts;
        var carver: mem.Carver = .{ .buf = &f.raw };
        f.t = Tree.init(&carver, 16);
        var tx = Texts.init(&carver, 1);
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

    fn run(w: *Walk, t: *const Tree, src: []const u8) !void {
        var text: [16]u8 = undefined;
        var events: [8]Input.Event = undefined;
        var contacts: [1]Input.Contact = undefined;
        const buf: Replay.Buffers = .{ .text = &text, .events = &events, .contacts = &contacts };
        var r: Replay = .{ .src = src };
        while (try r.next(buf)) |in| : (w.n += 1) {
            w.it.step(t, in);
            w.fo.step(&w.it, t, in);
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
    try w.run(&f.t,
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
    try w.run(&f.t,
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
