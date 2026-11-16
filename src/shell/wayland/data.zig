//! The clipboard through `wl_data_device`. Copy: the UI's `Platform.clipboard` becomes a
//! `wl_data_source` offering UTF-8 text, made the selection; when another client pastes, the
//! compositor sends `send` with a pipe and the text is written into it. Paste: the host calls
//! `Wayland.paste` (when a widget sets `keyboard.Clipboard.paste`); the selection's offer is
//! asked to `receive` into a pipe, which is read without blocking across polls (the source may
//! be this very client), and the text arrives as typed text in the poll that reads its end.

const std = @import("std");
const wire = @import("wire.zig");
const Wayland = @import("wayland.zig").Wayland;
const linux = std.os.linux;

/// MIME types this client reads and offers, one bit each.
pub const Mime = struct {
    pub const utf8: u8 = 1;
    pub const text: u8 = 2;
    pub const x11: u8 = 4;
    pub const uri_list: u8 = 8;
    pub const any_text = utf8 | text | x11;

    const names = [_][]const u8{ "text/plain;charset=utf-8", "text/plain", "UTF8_STRING", "text/uri-list" };

    fn bit(name: []const u8) u8 {
        for (names, 0..) |n, k| if (std.mem.eql(u8, n, name)) return @as(u8, 1) << @intCast(k);
        return 0;
    }
    /// The preferred type among `set`'s text types.
    fn bestText(set: u8) ?[]const u8 {
        for (names[0..3], 0..) |n, k| if (set & (@as(u8, 1) << @intCast(k)) != 0) return n;
        return null;
    }
};

/// Opcodes (wayland.xml).
const op = struct {
    const manager_create_data_source = 0;
    const manager_get_data_device = 1;
    const device_set_selection = 1;
    const source_offer = 0;
    const source_destroy = 1;
    const offer_receive = 1;
    const offer_destroy = 2;
};

/// Clipboard text this client holds or receives; longer text is cut.
/// ponytail: fixed capacity; grow it (or take a caller buffer) if large pastes matter.
pub const capacity = 64 * 1024;

pub const Data = struct {
    device: u32 = 0,
    /// Offers the compositor introduced (ids from 0xff000000), with the types each offers.
    offers: [4]Offer = @splat(.{}),
    /// The offer that is the current selection; 0 for none.
    selection: u32 = 0,
    /// The source this client made the selection, and the text it offers.
    source: u32 = 0,
    owned: [capacity]u8 = undefined,
    owned_len: usize = 0,
    /// The read end of a paste in progress, and what arrived so far.
    paste_fd: i32 = -1,
    pasted: [capacity]u8 = undefined,
    pasted_len: usize = 0,

    pub const Offer = struct { id: u32 = 0, mimes: u8 = 0 };

    /// Creates the data device once the seat and the manager are both bound.
    pub fn bind(d: *Data, w: *Wayland) void {
        const manager = w.globals.get(.wl_data_device_manager);
        const seat = w.globals.get(.wl_seat);
        if (d.device != 0 or manager == 0 or seat == 0) return;
        d.device = w.new(.data_device);
        w.request(manager, op.manager_get_data_device, .{ d.device, seat });
    }

    pub fn offer(d: *Data, id: u32) ?*Offer {
        for (&d.offers) |*o| if (o.id == id and id != 0) return o;
        return null;
    }

    /// Events of the data device, its offers and the source.
    pub fn deviceEvent(d: *Data, w: *Wayland, opcode: u16, a: *wire.Args) void {
        switch (opcode) {
            0 => { // data_offer: new id. A full table drops its oldest non-selection offer.
                const id = a.uint();
                const slot = for (&d.offers) |*o| {
                    if (o.id == 0) break o;
                } else for (&d.offers) |*o| {
                    if (o.id != d.selection) {
                        w.request(o.id, op.offer_destroy, .{});
                        break o;
                    }
                } else unreachable;
                slot.* = .{ .id = id };
            },
            5 => { // selection: offer or null
                const id = a.uint();
                if (d.selection != id) d.drop(w, d.selection);
                d.selection = id;
            },
            else => {},
        }
    }

    pub fn offerEvent(d: *Data, id: u32, opcode: u16, a: *wire.Args) void {
        const o = d.offer(id) orelse return;
        if (opcode == 0) o.mimes |= Mime.bit(a.string()); // offer: mime type
    }

    pub fn sourceEvent(d: *Data, w: *Wayland, opcode: u16, a: *wire.Args) void {
        switch (opcode) {
            1 => { // send: mime type, fd. The text fits a pipe's buffer, so the write is whole.
                _ = a.string();
                const fd = w.conn.takeFd();
                var at: usize = 0;
                while (fd >= 0 and at < d.owned_len) {
                    const rc = linux.write(fd, d.owned[at..].ptr, d.owned_len - at);
                    if (linux.errno(rc) != .SUCCESS) break;
                    at += rc;
                }
                _ = linux.close(fd);
            },
            2 => { // cancelled: another client owns the selection now
                w.destroy(d.source, op.source_destroy);
                d.source = 0;
                d.owned_len = 0;
            },
            else => {},
        }
    }

    /// Makes `text` the selection, unless this client already offers exactly that.
    pub fn set(d: *Data, w: *Wayland, text: []const u8) void {
        if (d.device == 0 or text.len == 0) return;
        const t = text[0..@min(text.len, capacity)];
        if (d.source != 0 and std.mem.eql(u8, t, d.owned[0..d.owned_len])) return;
        if (d.source != 0) w.destroy(d.source, op.source_destroy);
        @memcpy(d.owned[0..t.len], t);
        d.owned_len = t.len;
        d.source = w.new(.data_source);
        w.request(w.globals.get(.wl_data_device_manager), op.manager_create_data_source, .{d.source});
        for (Mime.names[0..3]) |n| w.request(d.source, op.source_offer, .{n});
        w.request(d.device, op.device_set_selection, .{ d.source, w.seat.serial });
    }

    /// Starts reading the selection's text, if it has any. False when there is nothing to paste
    /// or a paste is already under way.
    pub fn paste(d: *Data, w: *Wayland) bool {
        const o = d.offer(d.selection) orelse return false;
        const mime = Mime.bestText(o.mimes) orelse return false;
        if (d.paste_fd >= 0) return false;
        var p: [2]i32 = undefined;
        if (linux.errno(linux.pipe2(&p, .{ .CLOEXEC = true, .NONBLOCK = true })) != .SUCCESS) return false;
        w.request(o.id, op.offer_receive, .{ mime, wire.Fd{ .fd = p[1] } });
        d.paste_fd = p[0];
        d.pasted_len = 0;
        return true;
    }

    /// Reads what the paste's pipe has. At its end, the text is typed into this poll.
    pub fn readPaste(d: *Data, w: *Wayland) void {
        while (d.paste_fd >= 0) {
            var scratch: [4096]u8 = undefined;
            const room = d.pasted[d.pasted_len..];
            const buf = if (room.len > 0) room else &scratch;
            const rc = linux.read(d.paste_fd, buf.ptr, buf.len);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .AGAIN, .INTR => return,
                else => return d.endPaste(w),
            }
            if (rc == 0) return d.endPaste(w);
            if (room.len > 0) d.pasted_len += rc;
        }
    }

    fn endPaste(d: *Data, w: *Wayland) void {
        _ = linux.close(d.paste_fd);
        d.paste_fd = -1;
        w.seat.typeText(d.pasted[0..d.pasted_len]);
    }

    /// Forgets offer `id` and destroys it.
    pub fn drop(d: *Data, w: *Wayland, id: u32) void {
        const o = d.offer(id) orelse return;
        w.request(id, op.offer_destroy, .{});
        o.* = .{};
    }

    pub fn deinit(d: *Data) void {
        if (d.paste_fd >= 0) _ = linux.close(d.paste_fd);
        d.paste_fd = -1;
    }
};
