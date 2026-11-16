//! keyboard: key events and typed text, delivered to the focused widget. Tier 0: no allocator,
//! no I/O. Reads `Input.events`, `Input.keys` and `Input.text` (prototype/ui.zig `Input.Keys`,
//! `Input.text`) and the focus that `Interaction` and `Focus` settled this frame.

const std = @import("std");
const simd = @import("../core/simd.zig");
const types = @import("../core/types.zig");
const Input = @import("../core/input.zig").Input;
const Interaction = @import("interaction.zig").Interaction;
const Focus = @import("focus.zig").Focus;
const mem = @import("../core/mem.zig");
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

    /// The clipboard commands `id` was given this frame: empty unless it is focused. Read from
    /// key presses (and repeats) with exactly `map.mods`; the widget then fills `Clipboard`.
    pub fn commands(k: *const Keyboard, id: Id, map: ClipboardKeys) Commands {
        return .{
            .select_all = k.pressed(id, map.select_all, map.mods),
            .copy = k.pressed(id, map.copy, map.mods),
            .cut = k.pressed(id, map.cut, map.mods),
            .paste = k.pressed(id, map.paste, map.mods),
        };
    }

    /// The composition for `id`: `ime` with its range clamped into its text and ordered, or
    /// an empty composition unless `id` is focused.
    pub fn composition(k: *const Keyboard, id: Id, ime: *const Composition) Composition {
        const len: u32 = @intCast(ime.text.len * @intFromBool(k.mine(id)));
        const a = @min(ime.range[0], len);
        const b = @min(ime.range[1], len);
        return .{ .text = ime.text[0..len], .range = .{ @min(a, b), @max(a, b) } };
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

/// The clipboard commands a focused widget can be given. A bit set: several in one frame
/// (Ctrl+A then Ctrl+C) are all reported, and the widget applies them in this bit order.
pub const Commands = bitpack struct(u8) {
    select_all: bool = false,
    copy: bool = false,
    cut: bool = false,
    paste: bool = false,
    _: u4 = 0,
};

/// Keys of the clipboard commands. USB HID scancodes with Ctrl, the Windows and Linux
/// convention; a macOS host sets `mods` to `.{ .cmd = true }`.
pub const ClipboardKeys = struct {
    mods: Input.Mods = .{ .ctrl = true },
    select_all: u8 = 0x04,
    copy: u8 = 0x06,
    cut: u8 = 0x1b,
    paste: u8 = 0x19,
};

/// Clipboard requests to the host, as platform output (prototype/ui.zig `Platform.clipboard`):
/// filled by widgets during the frame, applied by the host after it. No callback and no
/// clipboard access in the core.
pub const Clipboard = struct {
    /// Non-empty when the UI asks the host to put this UTF-8 on the clipboard. The bytes are
    /// the caller's and must stay valid until the host has read them, after the frame.
    set: []const u8 = "",
    /// The UI asks for the clipboard's text. The host delivers it as typed text (an
    /// `Input.text` and a `.text` event) in the next frame, to the widget focused then.
    paste: bool = false,

    /// Clears the requests, for the next frame.
    pub fn reset(o: *Clipboard) void {
        o.* = .{};
    }
    /// Copy and cut: put `text` on the clipboard.
    pub fn copy(o: *Clipboard, text: []const u8) void {
        o.set = text;
    }
    /// Paste: ask the host for the clipboard's text.
    pub fn requestPaste(o: *Clipboard) void {
        o.paste = true;
    }
};

/// What an input method (IME) is composing, filled by the host each frame beside `Input`, as
/// Iced 0.14's input method events carry it: the preedit text with an optional range in it.
/// Committed text is not here: it arrives as typed text (`Input.text`, a `.text` event), which
/// also ends the composition, so a widget that already handles typing handles commits.
pub const Composition = struct {
    /// UTF-8 being composed and not yet committed; empty when nothing is.
    text: []const u8 = "",
    /// Byte range of `text` the IME highlights (the converted clause); a caret when both ends
    /// are equal. Host data: `Keyboard.composition` clamps it before a widget slices with it.
    range: [2]u32 = .{ 0, 0 },
};

/// What the text input purpose is, so the host picks the right keyboard and IME behaviour
/// (Iced 0.14 `input_method::Purpose`).
pub const Purpose = enum(u8) { normal, secure, terminal };

/// A request to the host for text input, as platform output (prototype/ui.zig
/// `Platform.wants_text` and `ime_rect`): the focused text widget fills it during the frame;
/// the host shows the on-screen keyboard or enables the IME, puts its candidate window at
/// `rect`, and turns both off when no widget asked.
pub const TextInput = struct {
    wants_text: bool = false,
    /// Where the caret or composition is, in logical pixels: the IME's window goes next to it.
    rect: types.Rect = .{},
    purpose: Purpose = .normal,

    pub fn reset(o: *TextInput) void {
        o.* = .{};
    }
    /// Asks for text input at `rect`.
    pub fn request(o: *TextInput, rect: types.Rect, purpose: Purpose) void {
        o.* = .{ .wants_text = true, .rect = rect, .purpose = purpose };
    }
};

/// The shortcut table: one row per key combination the application binds to an action of
/// its own (Ctrl+S to save, F5 to run). Caller-owned columns; rows stay until `reset`.
pub const Shortcuts = struct {
    len: u32 = 0,
    cap: u32,
    /// `add` ran out of rows. The last row is overwritten; nothing is written out of bounds.
    overflow: bool = false,
    c: Columns,

    pub const Columns = struct {
        /// Scancode, as for `Input.Keys`.
        code: []u8,
        /// `Input.Mods` as its byte: these modifiers exactly, no more and no fewer.
        mods: []u8,
        /// The application's number for what the shortcut does.
        action: []u16,
    };

    pub fn init(carver: *mem.Carver, cap: u32) Shortcuts {
        std.debug.assert(cap > 0);
        return .{ .cap = cap, .c = carver.columns(Columns, simd.rows(cap)) };
    }
    pub fn reset(sh: *Shortcuts) void {
        sh.len = 0;
        sh.overflow = false;
    }
    /// Binds `code` with exactly `mods` to `action`. Returns the row.
    pub fn add(sh: *Shortcuts, code: u8, mods: Input.Mods, action: u16) u32 {
        const k = @min(sh.len, sh.cap - 1);
        sh.overflow = simd.orB(sh.overflow, sh.len >= sh.cap);
        sh.len = k + 1;
        sh.c.code[k] = code;
        sh.c.mods[k] = @bitCast(mods);
        sh.c.action[k] = action;
        return k;
    }
};

/// Writes to `out`, in event order, the action of every row of `sh` whose key went down (or
/// repeated) this frame with exactly its modifiers, and returns how many. Run before widgets
/// read `k`: an event that fires a shortcut is marked taken, so the focused widget does not
/// also get it. Events focus already used do not fire. Several rows bound to one combination
/// all fire. At most `out.len - 1` actions are kept (the filter writes one row past the last
/// kept one); later ones are dropped.
pub fn fire(sh: *const Shortcuts, k: *Keyboard, out: []u16) u32 {
    std.debug.assert(out.len > 0);
    const last: u32 = @intCast(out.len - 1);
    const c = &sh.c;
    var w: u32 = 0;
    for (k.in.events, 0..) |e, ei| {
        const live = simd.andB(simd.orB(e.kind == .press, e.kind == .repeat), !k.isTaken(@intCast(ei)));
        const mods: u8 = @bitCast(e.mods);
        var any = false;
        for (c.code[0..sh.len], c.mods[0..sh.len], c.action[0..sh.len]) |code, m, action| {
            const hit = simd.andB(live, simd.andB(code == e.code, m == mods));
            // Clamp the write, not the count: a clamped count became a branch (census).
            out[@min(w, last)] = action;
            w += @intFromBool(hit);
            any = simd.orB(any, hit);
        }
        k.taken |= @as(u64, @intFromBool(simd.andB(any, ei < 64))) << @intCast(ei & 63);
    }
    return @min(w, last);
}

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

test "fire: exact modifiers, event order, repeats, and the widget does not see what fired" {
    var raw: [4096]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var sh = Shortcuts.init(&carver, 4);
    const save: u16 = 1;
    const save_as: u16 = 2;
    const run: u16 = 3;
    // HID: 22 S, 62 F5.
    _ = sh.add(22, .{ .ctrl = true }, save);
    _ = sh.add(22, .{ .ctrl = true, .shift = true }, save_as);
    _ = sh.add(62, .{}, run);
    const queue = [_]Input.Event{
        .{ .kind = .press, .code = 22, .mods = .{ .ctrl = true, .shift = true } },
        .{ .kind = .press, .code = 22 }, // plain "s": typed, not a shortcut
        .{ .kind = .press, .code = 62 },
        .{ .kind = .repeat, .code = 62 },
        .{ .kind = .release, .code = 62 },
        .{ .kind = .press, .code = 22, .mods = .{ .ctrl = true } },
        .{ .kind = .press, .code = 22, .mods = .{ .ctrl = true, .alt = true } },
    };
    const in: Input = .{ .events = &queue };
    const it: Interaction = .{ .focus = @backingInt(field) };
    const fo: Focus = .{};
    var k = Keyboard.route(&it, &fo, &in);
    var out: [8]u16 = undefined;
    const n = fire(&sh, &k, &out);
    try testing.expectEqualSlices(u16, &.{ save_as, run, run, save }, out[0..n]);
    // The field gets the plain "s", the release and Ctrl+Alt+S, which nothing bound.
    var codes: [8]u8 = undefined;
    var m: usize = 0;
    var e = k.events(field);
    while (e.next()) |ev| : (m += 1) codes[m] = ev.code;
    try testing.expectEqualSlices(u8, &.{ 22, 62, 22 }, codes[0..m]);
    // Firing again on the same frame finds everything taken.
    try testing.expectEqual(0, fire(&sh, &k, &out));
    // A small `out` keeps what fits and drops the rest.
    var k2 = Keyboard.route(&it, &fo, &in);
    var small: [3]u16 = undefined;
    try testing.expectEqual(2, fire(&sh, &k2, &small));
    try testing.expectEqualSlices(u16, &.{ save_as, run }, small[0..2]);
}

test "fire: nothing bound fires nothing; overflow keeps the table in bounds" {
    var raw: [4096]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var sh = Shortcuts.init(&carver, 1);
    const queue = [_]Input.Event{.{ .kind = .press, .code = 4 }};
    const in: Input = .{ .events = &queue };
    const it: Interaction = .{};
    const fo: Focus = .{};
    var k = Keyboard.route(&it, &fo, &in);
    var out: [4]u16 = undefined;
    try testing.expectEqual(0, fire(&sh, &k, &out));
    _ = sh.add(5, .{}, 1);
    try testing.expect(!sh.overflow);
    try testing.expectEqual(0, sh.add(4, .{}, 9));
    try testing.expect(sh.overflow);
    try testing.expectEqual(1, fire(&sh, &k, &out));
    try testing.expectEqual(9, out[0]);
    sh.reset();
    try testing.expectEqual(0, sh.len);
}

test "commands: Ctrl+A, C, X, V reach the focused widget, which answers through Clipboard" {
    // A text field holding "hello" with "ell" selected, as a widget would keep it.
    const value = "hello";
    const sel = [2]usize{ 1, 4 };
    const queue = [_]Input.Event{
        .{ .kind = .press, .code = 0x06, .mods = .{ .ctrl = true } },
        .{ .kind = .press, .code = 0x19, .mods = .{ .ctrl = true } },
        .{ .kind = .press, .code = 0x1b, .mods = .{ .ctrl = true, .shift = true } }, // not cut
        .{ .kind = .press, .code = 0x04 }, // a plain "a"
    };
    const in: Input = .{ .events = &queue };
    const it: Interaction = .{ .focus = @backingInt(field) };
    const fo: Focus = .{};
    const k = Keyboard.route(&it, &fo, &in);
    const map: ClipboardKeys = .{};
    const cmd = k.commands(field, map);
    try testing.expectEqual(Commands{ .copy = true, .paste = true }, cmd);
    try testing.expectEqual(Commands{}, k.commands(other, map));

    var clip: Clipboard = .{};
    if (cmd.copy) clip.copy(value[sel[0]..sel[1]]);
    if (cmd.paste) clip.requestPaste();
    try testing.expectEqualStrings("ell", clip.set);
    try testing.expect(clip.paste);
    clip.reset();
    try testing.expectEqualStrings("", clip.set);
    try testing.expect(!clip.paste);

    // A macOS host binds Cmd: Ctrl+C is then not copy.
    const mac: ClipboardKeys = .{ .mods = .{ .cmd = true } };
    try testing.expectEqual(Commands{}, k.commands(field, mac));
    const cmd_a = [_]Input.Event{.{ .kind = .press, .code = 0x04, .mods = .{ .cmd = true } }};
    const in2: Input = .{ .events = &cmd_a };
    const k2 = Keyboard.route(&it, &fo, &in2);
    try testing.expectEqual(Commands{ .select_all = true }, k2.commands(field, mac));
}

test "composition: preedit and range go to the focused widget; the commit is typed text" {
    const it: Interaction = .{ .focus = @backingInt(field) };
    const fo: Focus = .{};
    // Frame 1: composing "nihon" with "hon" highlighted. Frame 2: the IME commits.
    const composing: Composition = .{ .text = "nihon", .range = .{ 2, 5 } };
    const in1: Input = .{};
    const k1 = Keyboard.route(&it, &fo, &in1);
    const c = k1.composition(field, &composing);
    try testing.expectEqualStrings("nihon", c.text);
    try testing.expectEqualStrings("hon", c.text[c.range[0]..c.range[1]]);
    try testing.expectEqualStrings("", k1.composition(other, &composing).text);
    try testing.expectEqualStrings("", k1.text(field));

    const commit = [_]Input.Event{.{ .kind = .text, .at = 0, .len = 6 }};
    const in2: Input = .{ .text = "\xe6\x97\xa5\xe6\x9c\xac", .events = &commit };
    const k2 = Keyboard.route(&it, &fo, &in2);
    try testing.expectEqualStrings("\xe6\x97\xa5\xe6\x9c\xac", k2.text(field));
    try testing.expectEqualStrings("", k2.composition(field, &.{}).text);

    // A range from the host past the end, or backwards, is clamped and ordered.
    const bad: Composition = .{ .text = "abc", .range = .{ 9, 1 } };
    try testing.expectEqual([2]u32{ 1, 3 }, k1.composition(field, &bad).range);

    // The widget asks the host for the IME next to its caret.
    var out: TextInput = .{};
    out.request(.{ .x0 = 10, .y0 = 20, .x1 = 11, .y1 = 36 }, .normal);
    try testing.expect(out.wants_text);
    try testing.expectEqual(@as(f32, 36), out.rect.y1);
    out.reset();
    try testing.expect(!out.wants_text);
}
