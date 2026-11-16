//! Input methods through `zwp_text_input_v3`. `Platform.wants_text` enables the text input
//! while the window has its focus and `Platform.ime_rect` places the candidate window; what
//! the input method sends is double-buffered until `done`: the preedit becomes
//! `Events.composition`, committed text is typed (`Input.text` and a `.text` event).
//!
//! ponytail: no surrounding text and no delete_surrounding_text: the widgets do not expose the
//! text around the caret to the shell. Input methods that rewrite before the caret (some
//! Korean and Thai ones) need it; add it with a host call that passes the surrounding text.

const std = @import("std");
const lcgr = @import("lcgr");
const wire = @import("wire.zig");
const Wayland = @import("wayland.zig").Wayland;
const Composition = lcgr.keyboard.Composition;
const Rect = lcgr.types.Rect;

const op = struct {
    const manager_get_text_input = 1;
    const enable = 1;
    const disable = 2;
    const set_content_type = 5;
    const set_cursor_rectangle = 6;
    const commit = 7;
};

pub const Ime = struct {
    text_input: u32 = 0,
    /// Surface with the text input's focus (enter, until leave); 0 for none.
    focus: u32 = 0,
    /// What was last sent: enabled, at `rect`.
    enabled: bool = false,
    rect: Rect = .{},
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

    /// Enables, moves or disables the input method to match the frame's request.
    pub fn apply(m: *Ime, w: *Wayland, wants: bool, rect: Rect) void {
        if (m.text_input == 0 or m.focus == 0) return;
        if (wants == m.enabled and (!wants or std.meta.eql(rect, m.rect))) return;
        if (wants) {
            if (!m.enabled) {
                w.request(m.text_input, op.enable, .{});
                w.request(m.text_input, op.set_content_type, .{ @as(u32, 0), @as(u32, 0) });
            }
            w.request(m.text_input, op.set_cursor_rectangle, .{ @as(i32, @intFromFloat(rect.x0)), @as(i32, @intFromFloat(rect.y0)), @as(i32, @intFromFloat(rect.w())), @as(i32, @intFromFloat(rect.h())) });
        } else {
            w.request(m.text_input, op.disable, .{});
            m.shown_len = 0;
        }
        w.request(m.text_input, op.commit, .{});
        m.enabled = wants;
        m.rect = rect;
    }
};
