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

    /// Advances by one frame, from last frame's geometry and this frame's pointer.
    pub fn step(s: *Interaction, prev: *const Tree, in: *const Input) void {
        const node = hit.at(prev, in.pointer[0], in.pointer[1], .any);
        // Clamp instead of branching: the read stays in bounds when nothing is hit. The prototype
        // then selected the id on `node != none`; Zig 0.18's LLVM turns a select (or a mask) on a
        // loaded value into a `je` around the load (`pick` too). Selecting the address, between the
        // row and a constant 0 (`node +% 1` is 0 only for `none`), keeps the load unconditional.
        const row = @min(node, prev.cap - 1);
        const from = [2]*const u32{ &zero_id, &prev.c.id[row] };
        const under = from[@intFromBool(node +% 1 != 0)].*;
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
        // Anonymous rows have id 0, so nothing held must not search for 0: OR in all ones
        // (`none`) when `active` is 0 instead of the prototype's select.
        const idle = -%@as(u32, @intFromBool(s.active == 0));
        s.active_node = simd.find(prev.c.id, prev.len, s.active) | idle;
        s.delta = .{ in.pointer[0] - s.pointer[0], in.pointer[1] - s.pointer[1] };
        s.pointer = in.pointer;
        s.buttons = in.buttons;
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
