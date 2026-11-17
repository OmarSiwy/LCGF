//! Input methods through `zwp_text_input_v3`. `Platform.wants_text` enables the text input
//! while the window has its focus, `Platform.ime_rect` places the candidate window,
//! `Platform.purpose` is its content type and `Platform.surrounding` with `selection` its
//! surrounding text; what the input method sends is double-buffered until `done`: the preedit
//! becomes `Events.composition`, committed text is typed (`Input.text` and a `.text` event).
//!
//! ponytail: delete_surrounding_text is ignored: `Input` has no way to say "delete n bytes
//! around the caret". Input methods that rewrite before the caret (some Korean and Thai ones)
//! need it; add it as an `Input.Event` kind when a text widget can apply it.

const std = @import("std");
const lcgf = @import("lcgf");
const wire = @import("wire.zig");
const Wayland = @import("wayland.zig").Wayland;
const Composition = lcgf.keyboard.Composition;
const Purpose = lcgf.keyboard.Purpose;
const Platform = lcgf.context.Platform;
const Rect = lcgf.types.Rect;

const op = struct {
    const manager_get_text_input = 1;
    const enable = 1;
    const disable = 2;
    const set_surrounding_text = 3;
    const set_content_type = 5;
    const set_cursor_rectangle = 6;
    const commit = 7;
};

pub const Ime = struct {
    text_input: u32 = 0,
    /// Surface with the text input's focus (enter, until leave); 0 for none.
    focus: u32 = 0,
    /// What was last sent: enabled, at `rect`, for `purpose`, with surrounding text hashed
    /// to `around` (with its selection).
    enabled: bool = false,
    rect: Rect = .{},
    purpose: Purpose = .normal,
    around: u64 = 0,
    /// Pending until `done`.
    preedit: [4096]u8 = undefined,
    preedit_len: u32 = 0,
    preedit_range: [2]u32 = .{ 0, 0 },
    commit: [4096]u8 = undefined,
    commit_len: u32 = 0,
    /// Applied at `done`: what `Events.composition` shows.
    shown: [4096]u8 = undefined,
    shown_len: u32 = 0,
    shown_range: [2]u32 = .{ 0, 0 },

    pub fn bind(m: *Ime, w: *Wayland) void {
        const manager = w.globals.get(.zwp_text_input_manager_v3);
        const seat = w.globals.get(.wl_seat);
        if (m.text_input != 0 or manager == 0 or seat == 0) return;
        m.text_input = w.new(.text_input);
        w.request(manager, op.manager_get_text_input, .{ m.text_input, seat });
    }

    pub fn composition(m: *const Ime) Composition {
        return .{ .text = m.shown[0..m.shown_len], .range = m.shown_range };
    }

    pub fn event(m: *Ime, w: *Wayland, opcode: u16, a: *wire.Args) void {
        switch (opcode) {
            0 => { // enter: surface. Enabled state does not survive a focus change.
                m.focus = a.uint();
                m.enabled = false;
            },
            1 => { // leave
                m.focus = 0;
                m.enabled = false;
                m.shown_len = 0;
            },
            2 => { // preedit_string: text, cursor_begin, cursor_end (bytes; -1 hides the cursor)
                const t = a.string();
                m.preedit_len = @intCast(@min(t.len, m.preedit.len));
                @memcpy(m.preedit[0..m.preedit_len], t[0..m.preedit_len]);
                const begin = a.int();
                const end = a.int();
                m.preedit_range = if (begin < 0 or end < 0) .{ m.preedit_len, m.preedit_len } else .{ @min(@as(u32, @intCast(begin)), m.preedit_len), @min(@as(u32, @intCast(end)), m.preedit_len) };
            },
            3 => { // commit_string: text
                const t = a.string();
                const n: u32 = @intCast(@min(t.len, m.commit.len - m.commit_len));
                @memcpy(m.commit[m.commit_len..][0..n], t[0..n]);
                m.commit_len += n;
            },
            5 => { // done: apply the pending preedit and commit, then clear them
                w.seat.typeText(m.commit[0..m.commit_len]);
                @memcpy(m.shown[0..m.preedit_len], m.preedit[0..m.preedit_len]);
                m.shown_len = m.preedit_len;
                m.shown_range = m.preedit_range;
                m.preedit_len = 0;
                m.preedit_range = .{ 0, 0 };
                m.commit_len = 0;
            },
            else => {},
        }
    }

    /// Enables, moves or disables the input method to match the frame's request, and sends its
    /// content type and surrounding text when they changed.
    pub fn apply(m: *Ime, w: *Wayland, p: *const Platform) void {
        if (m.text_input == 0 or m.focus == 0) return;
        const wants = p.wants_text;
        const around = std.hash.Wyhash.hash(@as(u64, @bitCast(p.selection)), p.surrounding);
        const same = std.meta.eql(p.ime_rect, m.rect) and p.purpose == m.purpose and around == m.around;
        if (wants == m.enabled and (!wants or same)) return;
        if (wants) {
            // Enabling resets the state, so content type and surrounding text go again.
            if (!m.enabled) w.request(m.text_input, op.enable, .{});
            if (!m.enabled or p.purpose != m.purpose) w.request(m.text_input, op.set_content_type, content_types.get(p.purpose));
            if (!m.enabled or around != m.around) {
                const text, const sel = window(p.surrounding, p.selection);
                w.request(m.text_input, op.set_surrounding_text, .{ text, @as(i32, @intCast(sel[1])), @as(i32, @intCast(sel[0])) });
            }
            const r = p.ime_rect;
            w.request(m.text_input, op.set_cursor_rectangle, .{ @as(i32, @intFromFloat(r.x0)), @as(i32, @intFromFloat(r.y0)), @as(i32, @intFromFloat(r.w())), @as(i32, @intFromFloat(r.h())) });
        } else {
            w.request(m.text_input, op.disable, .{});
            m.shown_len = 0;
        }
        w.request(m.text_input, op.commit, .{});
        m.enabled = wants;
        m.rect = p.ime_rect;
        m.purpose = p.purpose;
        m.around = around;
    }
};

/// `set_content_type`'s hint and purpose for each `Purpose`. A password is hidden and
/// sensitive (no learning, no suggestions).
const content_types = std.enums.EnumArray(Purpose, struct { u32, u32 }).init(.{
    .normal = .{ 0, 0 },
    .secure = .{ 0x40 | 0x80, 8 },
    .terminal = .{ 0, 13 },
    .number = .{ 0, 3 },
    .phone = .{ 0, 4 },
    .email = .{ 0, 6 },
    .url = .{ 0, 5 },
});

/// The protocol takes under 4000 bytes of surrounding text.
const max_surrounding = 3999;

/// At most `max_surrounding` bytes of `text` around the selection, cut at character starts,
/// and the selection (anchor, cursor) inside that window, clamped to it.
fn window(text: []const u8, sel: [2]u32) struct { []const u8, [2]u32 } {
    var lo: usize = (@min(sel[0], sel[1], text.len)) -| max_surrounding / 2;
    while (lo < text.len and text[lo] & 0xc0 == 0x80) lo += 1;
    var hi: usize = @min(text.len, lo + max_surrounding);
    while (hi < text.len and text[hi] & 0xc0 == 0x80) hi -= 1;
    var at: [2]u32 = undefined;
    for (sel, 0..) |x, i| at[i] = @intCast(std.math.clamp(x, lo, hi) - lo);
    return .{ text[lo..hi], at };
}

test "window: short text whole; long text cut around the caret at character starts" {
    try std.testing.expectEqual(@as(usize, 5), window("hello", .{ 2, 9 })[0].len);
    try std.testing.expectEqual([2]u32{ 2, 5 }, window("hello", .{ 2, 9 })[1]);
    var long: [6000]u8 = undefined; // 3000 two-byte characters
    for (0..3000) |i| long[2 * i ..][0..2].* = "\xc3\xa9".*;
    const text, const at = window(&long, .{ 4001, 4001 });
    try std.testing.expect(text.len <= max_surrounding);
    try std.testing.expect(text[0] == 0xc3 and std.unicode.utf8ValidateSlice(text));
    try std.testing.expectEqualSlices(u8, long[4001 - at[0] ..][0..text.len], text);
}
