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
    hot: u32 = 0,
    active: u32 = 0,
    focus: u32 = 0,
    pressed: u32 = 0,
    released: u32 = 0,
    clicked: u32 = 0,
    // Rows in the previous frame's tree, or `none`.
    hot_node: u32 = none,
    active_node: u32 = none,
    pointer: [2]f32 = .{ -1, -1 },
    delta: [2]f32 = .{ 0, 0 },
    buttons: Input.Buttons = .{},

    /// Advances by one frame, from last frame's geometry and this frame's pointer.
    pub fn step(s: *Interaction, prev: *const Tree, in: *const Input) void {
        const node = hit.at(prev, in.pointer[0], in.pointer[1], .any);
        // Clamp instead of branching: the read stays in bounds when nothing is hit. The prototype
        // then selected the id on `node != none`; Zig 0.18's LLVM turns a select (or a mask) on a
        // loaded value into a `je` around the load. Selecting the address instead, between the
        // row and a constant 0 (`node +% 1` is 0 only for `none`), keeps the load unconditional.
        const row = @min(node, prev.cap - 1);
        const from = [2]*const u32{ &zero_id, &prev.c.id[row] };
        const hot = from[@intFromBool(node +% 1 != 0)].*;
        const press = simd.andB(in.buttons.left, !s.buttons.left);
        const release = simd.andB(!in.buttons.left, s.buttons.left);
        const takes_focus = (prev.c.sense[row] & @as(u8, @bitCast(Sense{ .focus = true }))) != 0;

        s.clicked = simd.selU(simd.andB(release, simd.andB(s.active == hot, hot != 0)), hot, 0);
        s.released = simd.selU(release, s.active, 0);
        s.pressed = simd.selU(press, hot, 0);
        s.focus = simd.selU(press, simd.selU(takes_focus, hot, 0), s.focus);
        s.active = simd.selU(press, hot, simd.selU(release, 0, s.active));
        s.hot = hot;
        s.hot_node = node;
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
    // Moved onto b while held: b is hot, a stays active.
    try testing.expectEqual(b, f[1].hot);
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
