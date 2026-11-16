//! keyboard: key events and typed text, delivered to the focused widget. Tier 0: no allocator,
//! no I/O. Reads `Input.events`, `Input.keys` and `Input.text` (prototype/ui.zig `Input.Keys`,
//! `Input.text`) and the focus that `Interaction` and `Focus` settled this frame.

const std = @import("std");
const simd = @import("../core/simd.zig");
const types = @import("../core/types.zig");
const Input = @import("../core/input.zig").Input;
const Interaction = @import("interaction.zig").Interaction;
const Focus = @import("focus.zig").Focus;
const Id = types.Id;

/// This frame's keyboard input, addressed to one widget. Plain data over the caller's `Input`;
/// valid while it is. Build it with `route` after `Focus.step`, then let each widget ask for
/// its share by id: a widget that is not focused gets nothing, and the focused one gets every
/// event the focus keys did not use (a Tab that moved focus is not also typed into the field).
pub const Keyboard = struct {
    in: *const Input,
    /// Id the keys go to, or 0 when nothing is focused.
    target: u32,
    /// Events not delivered, one bit per index into `in.events` (`Focus.taken`).
    taken: u64,

    /// Events of `in` for `it.focus`, minus those `fo` used to move focus.
    pub fn route(it: *const Interaction, fo: *const Focus, in: *const Input) Keyboard {
        return .{ .in = in, .target = it.focus, .taken = fo.taken };
    }

    fn mine(k: *const Keyboard, id: Id) bool {
        const n = @backingInt(id);
        return simd.andB(n != 0, n == k.target);
    }

    /// The events delivered to `id`, in order. Empty unless `id` is focused.
    pub fn events(k: *const Keyboard, id: Id) Iterator {
        const len: u32 = @intCast(k.in.events.len);
        return .{ .k = k, .i = simd.selU(k.mine(id), 0, len) };
    }

    pub const Iterator = struct {
        k: *const Keyboard,
        i: u32,

        pub fn next(r: *Iterator) ?Input.Event {
            const all = r.k.in.events;
            while (r.i < all.len) {
                const e = r.i;
                r.i += 1;
                if (!r.k.isTaken(e)) return all[e];
            }
            return null;
        }
    };

    fn isTaken(k: *const Keyboard, e: u32) bool {
        return simd.andB(e < 64, (k.taken >> @intCast(e & 63)) & 1 != 0);
    }

    /// `id` is focused and key `code` went down (or repeated) this frame with exactly `mods`
    /// held, in an event the focus keys did not use.
    pub fn pressed(k: *const Keyboard, id: Id, code: u8, mods: Input.Mods) bool {
        var it = k.events(id);
        var hit = false;
        while (it.next()) |e| {
            const went = simd.orB(e.kind == .press, e.kind == .repeat);
            const same = @as(u8, @bitCast(e.mods)) == @as(u8, @bitCast(mods));
            hit = simd.orB(hit, simd.andB(went, simd.andB(e.code == code, same)));
        }
        return hit;
    }

    /// `id` is focused and key `code` is held this frame (`Input.keys`).
    pub fn down(k: *const Keyboard, id: Id, code: u8) bool {
        return simd.andB(k.mine(id), k.in.keys.down(code));
    }

    /// The UTF-8 typed this frame (`Input.text`) if `id` is focused, else empty.
    pub fn text(k: *const Keyboard, id: Id) []const u8 {
        return k.in.text[0 .. k.in.text.len * @intFromBool(k.mine(id))];
    }
};

const testing = std.testing;

const field = Id.from("field");
const other = Id.from("other");

test "route: only the focused widget gets keys, held keys and text" {
    const queue = [_]Input.Event{
        .{ .kind = .press, .code = 4 },
        .{ .kind = .text, .at = 0, .len = 1 },
        .{ .kind = .release, .code = 4 },
    };
    var in: Input = .{ .text = "a", .events = &queue };
    in.keys.press(4);
    var it: Interaction = .{ .focus = @backingInt(field) };
    const fo: Focus = .{};
    const k = Keyboard.route(&it, &fo, &in);
    var got: [4]Input.Event.Kind = undefined;
    var n: usize = 0;
    var e = k.events(field);
    while (e.next()) |ev| : (n += 1) got[n] = ev.kind;
    try testing.expectEqualSlices(Input.Event.Kind, &.{ .press, .text, .release }, got[0..n]);
    try testing.expectEqualStrings("a", k.text(field));
    try testing.expect(k.down(field, 4));
    try testing.expect(k.pressed(field, 4, .{}));
    try testing.expect(!k.pressed(field, 4, .{ .ctrl = true }));
    try testing.expect(!k.pressed(field, 5, .{}));
    // Not focused, or anonymous: nothing.
    var o = k.events(other);
    try testing.expectEqual(null, o.next());
    try testing.expectEqualStrings("", k.text(other));
    try testing.expect(!k.down(other, 4));
    try testing.expect(!k.pressed(other, 4, .{}));
    it.focus = 0;
    const none_k = Keyboard.route(&it, &fo, &in);
    var z = none_k.events(.none);
    try testing.expectEqual(null, z.next());
    try testing.expectEqualStrings("", none_k.text(.none));
}

test "route: a Tab that moved focus is not delivered; other keys reach the new focus" {
    const Tree = @import("../core/tree.zig").Tree;
    const mem = @import("../core/mem.zig");
    const Scopes = @import("focus.zig").Scopes;
    const scan = @import("focus.zig").scan;
    var raw: [32 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var t = Tree.init(&carver, 8);
    var sc = Scopes.init(&carver, 8);
    const root = t.push(0, .none, &.{});
    for ([_]Id{ field, other }) |id| {
        const n = t.push(root, id, &.{});
        t.seal(n);
        t.c.sense[n] = @bitCast(types.Sense.button);
    }
    t.seal(root);
    scan(&t, &sc);
    // "x", Tab (moves from field to other), "y".
    const queue = [_]Input.Event{
        .{ .kind = .press, .code = 27 },
        .{ .kind = .press, .code = 43 },
        .{ .kind = .press, .code = 28 },
    };
    const in: Input = .{ .events = &queue };
    var it: Interaction = .{ .focus = @backingInt(field) };
    var fo: Focus = .{};
    it.step(&t, &in);
    fo.step(&it, &t, &sc, &in);
    const k = Keyboard.route(&it, &fo, &in);
    try testing.expectEqual(@backingInt(other), k.target);
    var codes: [4]u8 = undefined;
    var n: usize = 0;
    var e = k.events(other);
    while (e.next()) |ev| : (n += 1) codes[n] = ev.code;
    // The whole frame goes to the widget focused at its end; the Tab is gone.
    try testing.expectEqualSlices(u8, &.{ 27, 28 }, codes[0..n]);
    try testing.expect(!k.pressed(other, 43, .{}));
    // With no stop at all, Tab is the widget's (a text area may indent with it).
    t.c.sense[1] = 0;
    t.c.sense[2] = 0;
    scan(&t, &sc);
    it.focus = @backingInt(field);
    fo.step(&it, &t, &sc, &in);
    try testing.expectEqual(@as(u64, 0), fo.taken);
}
