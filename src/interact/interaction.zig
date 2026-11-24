//! interaction: hover, press, release, click and focus as one pure step per frame.
//! Tier 0: no allocator, no I/O. Ported from prototype/ui.zig ("Interaction").

const std = @import("std");
const simd = @import("../core/simd.zig");
const types = @import("../core/types.zig");
const hit = @import("hit.zig");
const Tree = @import("../core/tree.zig").Tree;
const Input = @import("../core/input.zig").Input;
const Sense = types.Sense;
const none = types.none;

/// Pointer state carried from frame to frame. Plain data; the caller owns it and calls `step`
/// once per frame.
pub const Interaction = struct {
    // Id backing ints; 0 means nothing.
    /// Id under the pointer. While a widget is held it captures the pointer: `hot` is that
    /// widget or nothing, so no other widget lights up during a drag.
    hot: u32 = 0,
    /// Id under the pointer regardless of capture.
    under: u32 = 0,
    active: u32 = 0,
    focus: u32 = 0,
    pressed: u32 = 0,
    released: u32 = 0,
    clicked: u32 = 0,
    // Rows in the previous frame's tree, or `none`. `hot_node` follows `hot`'s capture.
    hot_node: u32 = none,
    active_node: u32 = none,
    pointer: [2]f32 = .{ -1, -1 },
    delta: [2]f32 = .{ 0, 0 },
    buttons: Input.Buttons = .{},
    /// Id clicked this frame within `double_time` of a click on the same id, or 0. The click
    /// after a double click starts a new pair, so a triple click is one double click.
    double_clicked: u32 = 0,
    /// Id held for `long_time` this frame, or 0. Once per press.
    long_pressed: u32 = 0,
    // Seconds; the caller may change them.
    double_time: f32 = 0.4,
    long_time: f32 = 0.5,
    // Bookkeeping for the two above. The times are `Input.time` stored as its bits, so `pick`
    // selects them in integer registers (x86 has no cmov for floats).
    last_click: u32 = 0,
    click_at: u64 = @bitCast(-std.math.inf(f64)),
    press_at: u64 = 0,
    long_fired: bool = false,
    /// Id being dragged, or 0: the held id once the pointer has moved more than
    /// `drag_threshold` logical pixels from where it was pressed. Latched up to and including
    /// the release frame.
    dragging: u32 = 0,
    /// Pointer movement this frame while `dragging`; zero otherwise. The frame the threshold
    /// is crossed carries all movement since the press, so none is lost.
    drag_delta: [2]f32 = .{ 0, 0 },
    drag_threshold: f32 = 4,
    /// Pointer position that `drag_delta` is measured from: the press, then the last frame.
    drag_from: [2]f32 = .{ 0, 0 },
    /// `hot` once it has stayed hot for `hover_delay` seconds (tooltips, hover cards), or 0.
    hover_intent: u32 = 0,
    hover_delay: f32 = 0.5,
    /// When `hot` last changed, as `Input.time` bits.
    hot_at: u64 = 0,

    /// Advances by one frame, from last frame's geometry and this frame's pointer.
    pub fn step(s: *Interaction, prev: *const Tree, in: *const Input) void {
        const node = hit.at(prev, in.pointer[0], in.pointer[1], .any);
        // Clamp instead of branching: the read stays in bounds when nothing is hit. The prototype
        // then selected the id on `node != none`; Zig 0.18's LLVM turns a select (or a mask) on a
        // loaded value into a `je` around the load (`pick` too). Selecting the address, between the
        // row and a constant 0 (`node +% 1` is 0 only for `none`), keeps the load unconditional.
        const row = @min(node, prev.cap - 1);
        const id_at = [2]*const u32{ &zero_id, &prev.c.id[row] };
        const under = id_at[@intFromBool(node +% 1 != 0)].*;
        const press = simd.andB(in.buttons.left, !s.buttons.left);
        const release = simd.andB(!in.buttons.left, s.buttons.left);
        const takes_focus = (prev.c.sense[row] & @as(u8, @bitCast(Sense{ .focus = true }))) != 0;

        s.clicked = pick(u32, simd.andB(release, simd.andB(s.active == under, under != 0)), under, 0);
        s.released = pick(u32, release, s.active, 0);
        s.pressed = pick(u32, press, under, 0);
        s.focus = pick(u32, press, pick(u32, takes_focus, under, 0), s.focus);
        s.active = pick(u32, press, under, pick(u32, release, 0, s.active));
        // Capture, judged on the new `active` as `response` judges hover, so the release frame
        // already shows hover again.
        const owned = simd.orB(s.active == 0, s.active == under);
        const hot_was = s.hot;
        s.under = under;
        s.hot = pick(u32, owned, under, 0);
        s.hot_node = pick(u32, owned, node, none);

        const now: u64 = @bitCast(in.time);
        const clicked = s.clicked != 0;
        const since = in.time - @as(f64, @bitCast(s.click_at));
        const repeat = simd.andB(simd.andB(clicked, s.clicked == s.last_click), since <= s.double_time);
        s.double_clicked = pick(u32, repeat, s.clicked, 0);
        s.last_click = pick(u32, clicked, pick(u32, repeat, 0, s.clicked), s.last_click);
        s.click_at = pick(u64, clicked, now, s.click_at);
        s.press_at = pick(u64, press, now, s.press_at);
        const held_for = in.time - @as(f64, @bitCast(s.press_at));
        const fired = simd.andB(s.long_fired, !press);
        const due = simd.andB(simd.andB(s.active != 0, !fired), held_for >= s.long_time);
        s.long_pressed = pick(u32, due, s.active, 0);
        s.long_fired = simd.orB(fired, due);
        s.hot_at = pick(u64, s.hot != hot_was, now, s.hot_at);
        const rested = in.time - @as(f64, @bitCast(s.hot_at)) >= s.hover_delay;
        s.hover_intent = pick(u32, rested, s.hot, 0);

        // Positions are selected as their bits, as the times are.
        const here: u64 = @bitCast(in.pointer);
        const from: [2]f32 = @bitCast(pick(u64, press, here, @bitCast(s.drag_from)));
        const moved = [2]f32{ in.pointer[0] - from[0], in.pointer[1] - from[1] };
        const far = moved[0] * moved[0] + moved[1] * moved[1] > s.drag_threshold * s.drag_threshold;
        // The release frame still drags (its movement and the drop belong to the drag).
        const owner = s.active | s.released;
        s.dragging = pick(u32, simd.andB(owner != 0, simd.orB(far, simd.andB(!press, s.dragging == owner))), owner, 0);
        const moving = s.dragging != 0;
        const keep = -%@as(u64, @intFromBool(moving));
        s.drag_delta = @bitCast(@as(u64, @bitCast(moved)) & keep);
        s.drag_from = @bitCast(pick(u64, moving, here, @bitCast(from)));
        // No active id means no rows to search. A zero-length find returns none,
        // avoiding the whole id-column scan and preventing anonymous id-0 matches.
        // A held id still resolves against the supplied tree, since its row can move.
        const active_rows = prev.len * @as(u32, @intFromBool(s.active != 0));
        s.active_node = simd.find(prev.c.id, active_rows, s.active);
        s.delta = .{ in.pointer[0] - s.pointer[0], in.pointer[1] - s.pointer[1] };
        s.pointer = in.pointer;
        s.buttons = in.buttons;
    }

    /// Pointer movement this frame while `id` is dragged; zero otherwise.
    pub fn drag(s: *const Interaction, id: types.Id) [2]f32 {
        const k = @backingInt(id);
        const m = simd.b2f(simd.andB(k != 0, s.dragging == k));
        return .{ s.drag_delta[0] * m, s.drag_delta[1] * m };
    }

    /// What happened to widget `id` this frame. Id 0 (anonymous) reports nothing.
    pub fn response(s: *const Interaction, id: types.Id) types.Response {
        const k = @backingInt(id);
        const valid: u8 = @intFromBool(k != 0);
        // While something is held, only that widget reports hover.
        const unowned: u8 = @intFromBool(s.active == 0) | @intFromBool(s.active == k);
        const hovered: u8 = @intFromBool(k == s.hot) & unowned;
        const held: u8 = @intFromBool(k == s.active);
        const pressed: u8 = @intFromBool(k == s.pressed);
        const released: u8 = @intFromBool(k == s.released);
        const clicked: u8 = @intFromBool(k == s.clicked);
        const focused: u8 = @intFromBool(k == s.focus);
        return @bitCast((hovered | (held << 1) | (pressed << 2) | (released << 3) | (clicked << 4) | (focused << 5)) * valid);
    }
};

/// Press, release and click for up to `n` fingers or pens at once, from `Input.contacts`.
/// Each contact is followed by its platform pointer id in one of `n` slots, so a widget keeps
/// the finger that pressed it however the host orders its rows. Contacts beyond `n` are
/// ignored. Fingers find widgets with `hit.near` (within `slop`), as fingers are wide. Focus
/// stays with the mouse `Interaction`.
pub fn Touches(comptime n: comptime_int) type {
    return struct {
        const Self = @This();
        const V = @Vector(n, u32);
        const B = @Vector(n, bool);
        const F = @Vector(n, f32);
        const iota = std.simd.iota(u32, n);

        /// Platform pointer id per slot, or `none` for a free slot.
        pointer: [n]u32 = @splat(none),
        /// Id under the contact (its last position once lifted), 0 for nothing.
        under: [n]u32 = @splat(0),
        /// Id the contact pressed and still holds, 0 for nothing.
        active: [n]u32 = @splat(0),
        // Ids this frame, 0 for nothing; `clicked` is a lift over the widget pressed.
        pressed: [n]u32 = @splat(0),
        released: [n]u32 = @splat(0),
        clicked: [n]u32 = @splat(0),
        down: [n]bool = @splat(false),
        x: [n]f32 = @splat(-1),
        y: [n]f32 = @splat(-1),
        /// Logical pixels a finger may miss a widget by.
        slop: f32 = 8,

        /// Advances by one frame, from last frame's geometry and this frame's contacts.
        pub fn step(t: *Self, prev: *const Tree, in: *const Input) void {
            var ptr: V = t.pointer;
            var under: V = t.under;
            var x: F = t.x;
            var y: F = t.y;
            var seen: B = @splat(false);
            var down: B = @splat(false);
            for (in.contacts) |c| {
                // The slot already following this id, else the first free one, else none
                // (dropped: `mine` is then all false).
                const same = ptr == @as(V, @splat(c.id));
                const own = @reduce(.Min, @select(u32, same, iota, @as(V, @splat(none))));
                const free = @reduce(.Min, @select(u32, ptr == @as(V, @splat(none)), iota, @as(V, @splat(none))));
                const mine = iota == @as(V, @splat(pick(u32, own != none, own, free)));
                const node = hit.near(prev, c.pos[0], c.pos[1], .any, t.slop);
                const row = @min(node, prev.cap - 1);
                const id_at = [2]*const u32{ &zero_id, &prev.c.id[row] };
                const id = id_at[@intFromBool(node +% 1 != 0)].*;
                ptr = @select(u32, mine, @as(V, @splat(c.id)), ptr);
                under = @select(u32, mine, @as(V, @splat(id)), under);
                x = @select(f32, mine, @as(F, @splat(c.pos[0])), x);
                y = @select(f32, mine, @as(F, @splat(c.pos[1])), y);
                seen = seen | mine;
                down = down | (mine & @as(B, @splat(c.down)));
            }
            const zero: V = @splat(0);
            const was: B = t.down;
            const held: V = t.active;
            const press = down & !was;
            const release = !down & was;
            t.clicked = @select(u32, release & (held == under) & (under != zero), under, zero);
            t.released = @select(u32, release, held, zero);
            t.pressed = @select(u32, press, under, zero);
            t.active = @select(u32, press, under, @select(u32, release, zero, held));
            // A slot whose contact is gone is free again; its release is reported above.
            t.pointer = @select(u32, seen, ptr, @as(V, @splat(none)));
            t.under = under;
            t.down = down;
            t.x = x;
            t.y = y;
        }

        /// What any contact did to widget `id` this frame. Hover means a contact (a finger
        /// down, or a pen above the surface) is on it.
        pub fn response(t: *const Self, id: types.Id) types.Response {
            const k: V = @splat(@backingInt(id));
            const live = @as(V, t.pointer) != @as(V, @splat(none));
            const hovered: u8 = @intFromBool(@reduce(.Or, (@as(V, t.under) == k) & live));
            const held: u8 = @intFromBool(@reduce(.Or, @as(V, t.active) == k));
            const pressed: u8 = @intFromBool(@reduce(.Or, @as(V, t.pressed) == k));
            const released: u8 = @intFromBool(@reduce(.Or, @as(V, t.released) == k));
            const clicked: u8 = @intFromBool(@reduce(.Or, @as(V, t.clicked) == k));
            const valid: u8 = @intFromBool(@backingInt(id) != 0);
            return @bitCast((hovered | (held << 1) | (pressed << 2) | (released << 3) | (clicked << 4)) * valid);
        }
    };
}

/// `c ? a : b` as a cmov. `simd.selU`'s mask is seen through by Zig 0.18's LLVM, which then
/// turns a select whose operand is a field loaded only for it into a branch around the load
/// (CodeGenPrepare). The `.unpredictable` hint becomes `!unpredictable` metadata on the select,
/// which keeps it a cmov: p_step has no forward jump outside loop control (census).
inline fn pick(comptime T: type, c: bool, a: T, b: T) T {
    return if (c) blk: {
        @branchHint(.unpredictable);
        break :blk a;
    } else b;
}

/// What `step` reads as the id under the pointer when nothing is hit.
const zero_id: u32 = 0;

const testing = std.testing;
const mem = @import("../core/mem.zig");
const Replay = @import("../core/input.zig").Replay;

const id_a = types.Id.from("a");
const id_b = types.Id.from("b");

/// root 200 x 100 with two 40 x 40 buttons side by side, 10 px apart: a at x 0..40, b at 50..90.
fn twoButtons(raw: []align(mem.column_align) u8) Tree {
    const layout = @import("../layout/layout.zig");
    const Texts = @import("../core/texts.zig").Texts;
    var carver: mem.Carver = .{ .buf = raw };
    var t = Tree.init(&carver, 16);
    var tx = Texts.init(&carver, 1);
    const root = t.push(0, .none, &.{ .dir = .x, .size = .{ .px(200), .px(100) }, .gap = 10 });
    const a = t.push(root, id_a, &.{ .size = .{ .px(40), .px(40) } });
    const b = t.push(root, id_b, &.{ .size = .{ .px(40), .px(40) } });
    t.seal(root);
    t.c.sense[a] = @bitCast(Sense.button);
    t.c.sense[b] = @bitCast(Sense{ .hover = true, .click = true });
    layout.run(&t, &tx, .{ 200, 100 });
    return t;
}

/// Plays `src` through `step` and returns the state after each frame.
fn play(t: *const Tree, src: []const u8, out: []Interaction) !usize {
    var text: [16]u8 = undefined;
    var events: [8]Input.Event = undefined;
    var contacts: [4]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &events, .contacts = &contacts };
    var r: Replay = .{ .src = src };
    var s: Interaction = .{};
    var n: usize = 0;
    while (try r.next(buf)) |in| : (n += 1) {
        s.step(t, in);
        out[n] = s;
    }
    return n;
}

test "step: hover, press, release, click over the button that was pressed" {
    var raw: [64 * 1024]u8 align(mem.column_align) = undefined;
    const t = twoButtons(&raw);
    var f: [8]Interaction = undefined;
    const n = try play(&t,
        \\frame
        \\pointer 20 20
        \\frame
        \\buttons left
        \\frame
        \\frame
        \\buttons
        \\frame
        \\pointer 150 80
    , &f);
    try testing.expectEqual(@as(usize, 5), n);
    const a = @backingInt(id_a);
    // Hover only.
    try testing.expectEqual(a, f[0].hot);
    try testing.expectEqual(@as(u32, 1), f[0].hot_node);
    try testing.expectEqual(@as(u32, 0), f[0].active);
    try testing.expectEqual(@as(u32, 0), f[0].pressed);
    // Press: active and focused (a senses focus), pressed for this frame only.
    try testing.expectEqual(a, f[1].pressed);
    try testing.expectEqual(a, f[1].active);
    try testing.expectEqual(a, f[1].focus);
    try testing.expectEqual(@as(u32, 1), f[1].active_node);
    try testing.expectEqual(@as(u32, 0), f[2].pressed);
    try testing.expectEqual(a, f[2].active);
    // Release over it: released and clicked, no longer active, focus kept.
    try testing.expectEqual(a, f[3].released);
    try testing.expectEqual(a, f[3].clicked);
    try testing.expectEqual(@as(u32, 0), f[3].active);
    try testing.expectEqual(none, f[3].active_node);
    try testing.expectEqual(a, f[3].focus);
    // Nothing under the pointer.
    try testing.expectEqual(@as(u32, 0), f[4].hot);
    try testing.expectEqual(none, f[4].hot_node);
    try testing.expectEqual(@as(u32, 0), f[4].clicked);
    try testing.expectEqual([2]f32{ 130, 60 }, f[4].delta);
}

test "step: inactive ids have no row; held ids follow current rows and ignore padding" {
    var raw: [64 * 1024]u8 align(mem.column_align) = undefined;
    var t = twoButtons(&raw);
    var s: Interaction = .{ .active_node = 1 };

    // Hover does not create an active id, and a stale row must not survive.
    s.step(&t, &.{ .pointer = .{ 20, 20 } });
    try testing.expectEqual(@backingInt(id_a), s.hot);
    try testing.expectEqual(@as(u32, 0), s.active);
    try testing.expectEqual(none, s.active_node);

    s.step(&t, &.{ .pointer = .{ 20, 20 }, .buttons = .{ .left = true } });
    try testing.expectEqual(@backingInt(id_a), s.active);
    try testing.expectEqual(@as(u32, 1), s.active_node);

    // A rebuild may move the held widget. Keep resolving its stable id rather
    // than caching the old row or substituting the pointer's current hit.
    std.mem.swap(u32, &t.c.id[1], &t.c.id[2]);
    s.step(&t, &.{ .buttons = .{ .left = true } });
    try testing.expectEqual(@backingInt(id_a), s.active);
    try testing.expectEqual(@as(u32, 2), s.active_node);

    // Removing the held widget leaves capture by id intact until release, but
    // no live row matches. A stale occurrence in SIMD padding is not a match.
    t.c.id[2] = 0;
    t.c.id[t.len] = @backingInt(id_a);
    s.step(&t, &.{ .buttons = .{ .left = true } });
    try testing.expectEqual(@backingInt(id_a), s.active);
    try testing.expectEqual(none, s.active_node);

    s.step(&t, &.{});
    try testing.expectEqual(@backingInt(id_a), s.released);
    try testing.expectEqual(@as(u32, 0), s.active);
    try testing.expectEqual(none, s.active_node);
}

test "step: release elsewhere is not a click; pressing nothing clears active, keeps focus" {
    var raw: [64 * 1024]u8 align(mem.column_align) = undefined;
    const t = twoButtons(&raw);
    var f: [8]Interaction = undefined;
    _ = try play(&t,
        \\frame
        \\pointer 20 20
        \\buttons left
        \\frame
        \\pointer 70 20
        \\frame
        \\buttons
        \\frame
        \\buttons left
        \\frame
        \\buttons
        \\pointer 150 80
        \\frame
        \\buttons left
    , &f);
    const a = @backingInt(id_a);
    const b = @backingInt(id_b);
    try testing.expectEqual(a, f[0].active);
    // Moved onto b while held: a captures the pointer, so b is under it but not hot.
    try testing.expectEqual(b, f[1].under);
    try testing.expectEqual(@as(u32, 0), f[1].hot);
    try testing.expectEqual(none, f[1].hot_node);
    try testing.expectEqual(a, f[1].active);
    // Released over b: a released, nothing clicked.
    try testing.expectEqual(a, f[2].released);
    try testing.expectEqual(@as(u32, 0), f[2].clicked);
    // Pressing b, which does not sense focus, takes focus away from a (as in the prototype).
    try testing.expectEqual(b, f[3].pressed);
    try testing.expectEqual(@as(u32, 0), f[3].focus);
    // Released off any node: no click.
    try testing.expectEqual(b, f[4].released);
    try testing.expectEqual(@as(u32, 0), f[4].clicked);
    // Pressed on nothing: nothing active, nothing pressed, focus moves to nothing.
    try testing.expectEqual(@as(u32, 0), f[5].active);
    try testing.expectEqual(@as(u32, 0), f[5].pressed);
    try testing.expectEqual(@as(u32, 0), f[5].focus);
}

/// The response bits of `id` after each of `n` frames.
fn responses(f: []const Interaction, id: types.Id, out: []u8) void {
    for (f, out) |s, *o| o.* = @bitCast(s.response(id));
}

test "response: hover, held, pressed, released, clicked, focused as one bit set per frame" {
    var raw: [64 * 1024]u8 align(mem.column_align) = undefined;
    const t = twoButtons(&raw);
    var f: [8]Interaction = undefined;
    const n = try play(&t,
        \\frame
        \\pointer 20 20
        \\frame
        \\buttons left
        \\frame
        \\pointer 70 20
        \\frame
        \\pointer 20 20
        \\frame
        \\buttons
        \\frame
        \\pointer 70 20
    , &f);
    const R = types.Response;
    var a: [8]u8 = undefined;
    var b: [8]u8 = undefined;
    responses(f[0..n], id_a, a[0..n]);
    responses(f[0..n], id_b, b[0..n]);
    const bits = struct {
        fn of(r: R) u8 {
            return @bitCast(r);
        }
    }.of;
    try testing.expectEqualSlices(u8, &.{
        bits(.{ .hovered = true }),
        bits(.{ .hovered = true, .held = true, .pressed = true, .focused = true }),
        // Dragged off: still held, no longer hovered.
        bits(.{ .held = true, .focused = true }),
        bits(.{ .hovered = true, .held = true, .focused = true }),
        bits(.{ .hovered = true, .released = true, .clicked = true, .focused = true }),
        bits(.{ .focused = true }),
    }, a[0..n]);
    // b is under the pointer in frame 2 but a holds it, so b reports no hover.
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, bits(.{ .hovered = true }) }, b[0..n]);
    // Anonymous: nothing, even though the root (id 0) is never hot.
    for (f[0..n]) |s| try testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(s.response(.none))));
}

test "step: double click within double_time on the same id; long press once per hold" {
    var raw: [64 * 1024]u8 align(mem.column_align) = undefined;
    const t = twoButtons(&raw);
    var f: [16]Interaction = undefined;
    // dt 0.1: clicks end at frames 1, 3, 5 (0.2 s apart), then one on b, one on a 0.4+ s later.
    const n = try play(&t,
        \\frame
        \\dt 0.1
        \\pointer 20 20
        \\buttons left
        \\frame
        \\buttons
        \\frame
        \\buttons left
        \\frame
        \\buttons
        \\frame
        \\buttons left
        \\frame
        \\buttons
        \\frame
        \\pointer 70 20
        \\buttons left
        \\frame
        \\buttons
        \\frame
        \\pointer 20 20
        \\buttons left
        \\frame
        \\buttons
    , &f);
    try testing.expectEqual(@as(usize, 10), n);
    const a = @backingInt(id_a);
    var dbl: [10]u32 = undefined;
    for (f[0..n], &dbl) |s, *d| d.* = s.double_clicked;
    // Frame 3 pairs with 1; frame 5 starts a new pair; b at 7 breaks it; a at 9 is a single.
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0, a, 0, 0, 0, 0, 0, 0 }, &dbl);
    for (f[0..n]) |s| try testing.expectEqual(@as(u32, 0), s.long_pressed);

    const m = try play(&t,
        \\frame
        \\dt 0.2
        \\pointer 20 20
        \\buttons left
        \\frame
        \\frame
        \\frame
        \\frame
        \\frame
        \\buttons
        \\frame
        \\buttons left
        \\frame
        \\frame
        \\frame
    , &f);
    try testing.expectEqual(@as(usize, 10), m);
    var long: [10]u32 = undefined;
    for (f[0..m], &long) |s, *l| l.* = s.long_pressed;
    // Pressed at 0 s: 0.6 s is past 0.5 (0.4 is not), and it fires once. Again for the next hold.
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0, a, 0, 0, 0, 0, 0, a }, &long);
}

test "step: the held widget captures the pointer until release, even off the window" {
    var raw: [64 * 1024]u8 align(mem.column_align) = undefined;
    const t = twoButtons(&raw);
    var f: [8]Interaction = undefined;
    const n = try play(&t,
        \\frame
        \\pointer 20 20
        \\buttons left
        \\frame
        \\pointer 70 20
        \\frame
        \\pointer -1 -1
        \\frame
        \\pointer 70 20
        \\frame
        \\buttons
        \\frame
    , &f);
    try testing.expectEqual(@as(usize, 6), n);
    const a = @backingInt(id_a);
    const b = @backingInt(id_b);
    var hot: [6]u32 = undefined;
    var node: [6]u32 = undefined;
    var under: [6]u32 = undefined;
    for (f[0..n], &hot, &node, &under) |s, *h, *nd, *u| {
        h.* = s.hot;
        nd.* = s.hot_node;
        u.* = s.under;
    }
    // Held from frame 0 to 4: only a may be hot, and a is not under the pointer after frame 0.
    try testing.expectEqualSlices(u32, &.{ a, 0, 0, 0, b, b }, &hot);
    try testing.expectEqualSlices(u32, &.{ 1, none, none, none, 2, 2 }, &node);
    try testing.expectEqualSlices(u32, &.{ a, b, 0, b, b, b }, &under);
    // a stays active through the trip off the window; the release goes to a, no click.
    for (f[0..4]) |s| try testing.expectEqual(a, s.active);
    try testing.expectEqual(a, f[4].released);
    try testing.expectEqual(@as(u32, 0), f[4].clicked);
    try testing.expectEqual(@as(u8, @bitCast(types.Response{ .hovered = true })), @as(u8, @bitCast(f[4].response(id_b))));
}

test "step: drag starts past the threshold with the movement so far, then frame deltas" {
    var raw: [64 * 1024]u8 align(mem.column_align) = undefined;
    const t = twoButtons(&raw);
    var f: [8]Interaction = undefined;
    const n = try play(&t,
        \\frame
        \\pointer 20 20
        \\buttons left
        \\frame
        \\pointer 22 21
        \\frame
        \\pointer 25 20
        \\frame
        \\pointer 75 30
        \\frame
        \\pointer 74 30
        \\buttons
        \\frame
        \\pointer 74 30
        \\buttons left
    , &f);
    try testing.expectEqual(@as(usize, 6), n);
    const a = @backingInt(id_a);
    var dragging: [6]u32 = undefined;
    for (f[0..n], &dragging) |s, *d| d.* = s.dragging;
    // 2.2 px from the press is within 4; 5 px is past it. Pressing b right after the release
    // is a new press, not a continued drag.
    try testing.expectEqualSlices(u32, &.{ 0, 0, a, a, a, 0 }, &dragging);
    const want = [6][2]f32{ .{ 0, 0 }, .{ 0, 0 }, .{ 5, 0 }, .{ 50, 10 }, .{ -1, 0 }, .{ 0, 0 } };
    for (f[0..n], want) |s, w| {
        try testing.expectEqual(w, s.drag(id_a));
        try testing.expectEqual([2]f32{ 0, 0 }, s.drag(id_b));
        try testing.expectEqual([2]f32{ 0, 0 }, s.drag(.none));
    }
    // The release frame still moves the drag; the click is the prototype's: released over b.
    try testing.expectEqual(@as(u32, 0), f[4].clicked);

    // Re-pressing the widget just dragged starts below the threshold again.
    const m = try play(&t,
        \\frame
        \\pointer 20 20
        \\buttons left
        \\frame
        \\pointer 30 20
        \\frame
        \\buttons
        \\frame
        \\buttons left
        \\frame
        \\pointer 31 20
    , &f);
    for (f[0..m], [5]u32{ 0, a, a, 0, 0 }) |s, w| try testing.expectEqual(w, s.dragging);
}

test "Touches: each finger keeps the widget it pressed, by pointer id, whatever the row order" {
    var raw: [64 * 1024]u8 align(mem.column_align) = undefined;
    const t = twoButtons(&raw);
    var text: [16]u8 = undefined;
    var events: [8]Input.Event = undefined;
    var contacts: [4]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &events, .contacts = &contacts };
    // Finger 7 presses a, finger 9 presses b (rows swap in frame 1, where a third finger is
    // dropped: both slots are taken); 9 slides into the gap, 2 px from a, so within slop it is
    // over a, and lifts there (no click on b); 7 lifts on a (click); finger 3 then takes a
    // freed slot and presses b.
    var r: Replay = .{ .src =
        \\frame
        \\touch 7 20 20
        \\touch 9 70 20
        \\frame
        \\touch 9 70 20
        \\touch 7 21 20
        \\touch 3 150 80
        \\frame
        \\touch 7 21 20
        \\touch 9 42 20
        \\frame
        \\touch 7 21 20
        \\frame
        \\frame
        \\touch 3 70 20
    };
    var s: Touches(2) = .{};
    const R = types.Response;
    const want_a = [_]R{
        .{ .hovered = true, .held = true, .pressed = true },
        .{ .hovered = true, .held = true },
        // Finger 9 is over a now, but it did not press a: a is held by 7 only.
        .{ .hovered = true, .held = true },
        .{ .hovered = true, .held = true },
        // 7 lifted on a: a click. A lifted contact hovers nothing.
        .{ .released = true, .clicked = true },
        .{},
    };
    const want_b = [_]R{
        .{ .hovered = true, .held = true, .pressed = true },
        .{ .hovered = true, .held = true },
        .{ .held = true },
        // 9 lifted over a: b is released without a click.
        .{ .released = true },
        .{},
        .{ .hovered = true, .held = true, .pressed = true },
    };
    var f: usize = 0;
    while (try r.next(buf)) |in| : (f += 1) {
        s.step(&t, in);
        try testing.expectEqual(@as(u8, @bitCast(want_a[f])), @as(u8, @bitCast(s.response(id_a))));
        try testing.expectEqual(@as(u8, @bitCast(want_b[f])), @as(u8, @bitCast(s.response(id_b))));
        try testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(s.response(.none))));
    }
    try testing.expectEqual(@as(usize, 6), f);
}

test "step: hover intent after the pointer rests on one widget for hover_delay" {
    var raw: [64 * 1024]u8 align(mem.column_align) = undefined;
    const t = twoButtons(&raw);
    var f: [12]Interaction = undefined;
    // dt 0.2: moving within a from 0 s to 0.6 s, onto b at 0.8 s, back to a, then off.
    const n = try play(&t,
        \\frame
        \\dt 0.2
        \\pointer 20 20
        \\frame
        \\pointer 25 25
        \\frame
        \\pointer 22 22
        \\frame
        \\pointer 21 21
        \\frame
        \\pointer 70 20
        \\frame
        \\pointer 20 20
        \\frame
        \\pointer 150 80
        \\frame
    , &f);
    try testing.expectEqual(@as(usize, 8), n);
    const a = @backingInt(id_a);
    var intent: [8]u32 = undefined;
    for (f[0..n], &intent) |s, *i| i.* = s.hover_intent;
    // Moving within a keeps its clock: 0.6 s >= 0.5 at frame 3 (0.4 s is not). Each change of
    // widget restarts it; nothing under the pointer is no intent.
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0, a, 0, 0, 0, 0 }, &intent);
}

// ---- Ported from prototype/example.zig, test "host loop: layout, draw list, click, drag,
// idle": its click and drag parts at tier 0. The prototype's Context, Frame and widgets are
// tier 1 and 2; here the test is the host and the widgets are a few lines over `response`.

const id_reset = types.Id.from("reset");
const id_exposure = types.Id.from("exposure");

/// A toolbar with a Reset button and an exposure slider track, as the prototype's buildUi
/// lays them out, over an 800 x 600 viewport.
fn toolbar(raw: []align(mem.column_align) u8) Tree {
    const layout = @import("../layout/layout.zig");
    const Texts = @import("../core/texts.zig").Texts;
    var carver: mem.Carver = .{ .buf = raw };
    var t = Tree.init(&carver, 16);
    var tx = Texts.init(&carver, 1);
    const root = t.push(0, .none, &.{ .size = .{ .px(800), .px(600) } });
    const bar = t.push(root, types.Id.from("toolbar"), &.{ .dir = .x, .size = .{ .fill, .fit }, .pad = @splat(8), .gap = 8, .cross = .center });
    const reset = t.push(bar, id_reset, &.{ .size = .{ .px(60), .px(30) } });
    const track = t.push(bar, id_exposure, &.{ .dir = .x, .size = .{ .fill, .px(8) }, .min = .{ 40, 0 } });
    t.seal(root);
    t.c.sense[reset] = @bitCast(Sense.button);
    t.c.sense[track] = @bitCast(Sense.any);
    layout.run(&t, &tx, .{ 800, 600 });
    return t;
}

const App = struct {
    resets: u32 = 0,
    exposure: f32 = 1,

    /// The prototype's button and slider logic, against `Interaction` instead of `Frame`.
    fn update(app: *App, s: *const Interaction, t: *const Tree, in: *const Input) void {
        if (s.response(id_reset).clicked) {
            app.resets += 1;
            app.exposure = 1;
        }
        // While held, the value follows the pointer across last frame's rect of the held node.
        const r = s.response(id_exposure);
        const rect = t.rect(@min(s.active_node, t.cap - 1));
        const along = std.math.clamp((in.pointer[0] - rect.x0) / @max(rect.w(), 1), 0, 1);
        app.exposure = simd.selF(r.held, 0 + along * 4, app.exposure);
    }
};

test "host loop: click, drag" {
    var raw: [64 * 1024]u8 align(mem.column_align) = undefined;
    const t = toolbar(&raw);
    // The geometry the recording below aims at: Reset at 8..68 x 8..38, the track at 76..792
    // x 19..27 (716 wide, so 75% is x 613 and 25% is x 255).
    try testing.expectEqual(types.Rect{ .x0 = 8, .y0 = 8, .x1 = 68, .y1 = 38 }, t.rect(t.find(id_reset)));
    try testing.expectEqual(types.Rect{ .x0 = 76, .y0 = 19, .x1 = 792, .y1 = 27 }, t.rect(t.find(id_exposure)));

    var text: [16]u8 = undefined;
    var events: [8]Input.Event = undefined;
    var contacts: [4]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &events, .contacts = &contacts };
    var r: Replay = .{ .src =
        \\# 0: idle. 1-3: click Reset. 4-6: hold the slider at 75%. 7-8: drag it to 25%, release.
        \\frame
        \\viewport 800 600
        \\frame
        \\pointer 38 23
        \\frame
        \\buttons left
        \\frame
        \\buttons
        \\frame
        \\pointer 613 23
        \\frame
        \\buttons left
        \\frame
        \\frame
        \\pointer 255 40
        \\frame
        \\buttons
    };
    var s: Interaction = .{};
    var app: App = .{};
    var resets: [9]u32 = undefined;
    var exposure: [9]f32 = undefined;
    var dx: [9]f32 = undefined;
    var f: usize = 0;
    while (try r.next(buf)) |in| : (f += 1) {
        s.step(&t, in);
        app.update(&s, &t, in);
        resets[f] = app.resets;
        exposure[f] = app.exposure;
        dx[f] = s.drag(id_exposure)[0];
        // The pointer over Reset shows it hovered (the prototype checks the pointer cursor).
        if (f == 1) try testing.expect(s.response(id_reset).hovered);
    }
    try testing.expectEqual(@as(usize, 9), f);
    // The click counts on release, not on press.
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0, 1, 1, 1, 1, 1, 1 }, &resets);
    // Holding the slider at 75% of its track sets the value to 3 of 0..4; dragging to 25%
    // (off the track, which keeps it: capture) sets 1, and the release keeps it.
    try testing.expectEqualSlices(f32, &.{ 1, 1, 1, 1, 1, 3, 3, 1, 1 }, &exposure);
    // The drag starts at the move past the threshold and carries the whole movement.
    try testing.expectEqualSlices(f32, &.{ 0, 0, 0, 0, 0, 0, 0, 255 - 613, 0 }, &dx);
}
