//! The clipboard through `wl_data_device`. Copy: the UI's `Platform.clipboard` becomes a
//! `wl_data_source` offering UTF-8 text, made the selection; when another client pastes, the
//! compositor sends `send` with a pipe and the text is written into it. Paste: the host calls
//! `Wayland.paste` (when a widget sets `keyboard.Clipboard.paste`); the selection's offer is
//! asked to `receive` into a pipe, which is read without blocking across polls (the source may
//! be this very client), and the text arrives as typed text in the poll that reads its end.
//!
//! File drop: a drag that offers `text/uri-list` is accepted (copy) on enter and its list read
//! at once, so widgets see the files while they hover (`gestures.Files`); `drop` is reported
//! in the poll after both the drop and the whole list arrived, then the offer is finished.

const std = @import("std");
const wire = @import("wire.zig");
const Wayland = @import("wayland.zig").Wayland;
const Files = @import("lcgr").gestures.Files;
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
    const offer_accept = 0;
    const offer_receive = 1;
    const offer_destroy = 2;
    const offer_finish = 3;
    const offer_set_actions = 4;
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
    /// The drag over a window: its offer (0 for none), the surface and position, the
    /// uri-list being read and the paths decoded from it.
    drag: u32 = 0,
    drag_surface: u32 = 0,
    drag_pos: [2]f32 = .{ -1, -1 },
    drag_fd: i32 = -1,
    dropped: bool = false,
    uris: [capacity]u8 = undefined,
    uris_len: usize = 0,
    names: [capacity]u8 = undefined,
    ends: [256]u32 = undefined,
    nfiles: u32 = 0,

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
            1 => { // enter: serial, surface, x, y, offer
                const serial = a.uint();
                d.endDrag(w);
                d.drag_surface = a.uint();
                d.drag_pos = .{ a.fixed(), a.fixed() };
                const id = a.uint();
                const o = d.offer(id) orelse return;
                if (o.mimes & Mime.uri_list == 0) {
                    w.request(id, op.offer_accept, .{ serial, wire.Array{ .bytes = "" } }); // null: not accepted
                    return;
                }
                d.drag = id;
                w.request(id, op.offer_accept, .{ serial, @as([]const u8, "text/uri-list") });
                w.request(id, op.offer_set_actions, .{ @as(u32, 1), @as(u32, 1) }); // copy
                var p: [2]i32 = undefined;
                if (linux.errno(linux.pipe2(&p, .{ .CLOEXEC = true, .NONBLOCK = true })) != .SUCCESS) return;
                w.request(id, op.offer_receive, .{ @as([]const u8, "text/uri-list"), wire.Fd{ .fd = p[1] } });
                d.drag_fd = p[0];
            },
            2 => if (!d.dropped) d.endDrag(w), // leave
            3 => { // motion: time, x, y
                _ = a.uint();
                d.drag_pos = .{ a.fixed(), a.fixed() };
            },
            4 => d.dropped = d.drag != 0, // drop
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

    /// Reads what the drag's uri-list pipe has; at its end, decodes the paths.
    pub fn readDrag(d: *Data) void {
        while (d.drag_fd >= 0) {
            var scratch: [4096]u8 = undefined;
            const room = d.uris[d.uris_len..];
            const buf = if (room.len > 0) room else &scratch;
            const rc = linux.read(d.drag_fd, buf.ptr, buf.len);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .AGAIN, .INTR => return,
                else => {},
            }
            if (rc == 0 or linux.errno(rc) != .SUCCESS) {
                _ = linux.close(d.drag_fd);
                d.drag_fd = -1;
                d.nfiles = parseUriList(d.uris[0..d.uris_len], &d.names, &d.ends);
                return;
            }
            if (room.len > 0) d.uris_len += rc;
        }
    }

    /// The files over window `surface` this poll.
    pub fn files(d: *const Data, surface: u32) Files {
        if (d.drag == 0 or d.drag_surface != surface) return .{};
        const n = if (d.drag_fd < 0) d.nfiles else 0;
        return .{
            .names = d.names[0..if (n > 0) d.ends[n - 1] else 0],
            .ends = d.ends[0..n],
            .pos = d.drag_pos,
            .hover = true,
            .drop = d.dropped and d.drag_fd < 0,
        };
    }

    /// After a poll reported the drop: tell the source it is done, and forget the drag.
    pub fn endPoll(d: *Data, w: *Wayland) void {
        if (!d.dropped or d.drag_fd >= 0) return;
        w.request(d.drag, op.offer_finish, .{});
        d.endDrag(w);
    }

    fn endDrag(d: *Data, w: *Wayland) void {
        if (d.drag_fd >= 0) _ = linux.close(d.drag_fd);
        d.drop(w, d.drag);
        d.drag = 0;
        d.drag_surface = 0;
        d.drag_fd = -1;
        d.dropped = false;
        d.uris_len = 0;
        d.nfiles = 0;
    }

    /// Forgets offer `id` and destroys it.
    pub fn drop(d: *Data, w: *Wayland, id: u32) void {
        const o = d.offer(id) orelse return;
        w.request(id, op.offer_destroy, .{});
        o.* = .{};
    }

    pub fn deinit(d: *Data) void {
        if (d.paste_fd >= 0) _ = linux.close(d.paste_fd);
        if (d.drag_fd >= 0) _ = linux.close(d.drag_fd);
        d.paste_fd = -1;
        d.drag_fd = -1;
    }
};

/// Local paths of a `text/uri-list` (RFC 2483: one URI per CRLF line, `#` comments), percent-
/// decoded into `names` with `ends[k]` the end of path `k`. `file://` URIs with an empty or
/// `localhost` host only; others are skipped. Returns the number of paths.
pub fn parseUriList(list: []const u8, names: []u8, ends: []u32) u32 {
    var n: u32 = 0;
    var at: usize = 0;
    var lines = std.mem.tokenizeAny(u8, list, "\r\n");
    while (lines.next()) |line| {
        if (line[0] == '#' or n == ends.len) continue;
        const rest = if (std.mem.startsWith(u8, line, "file://")) line[7..] else continue;
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse continue;
        const host = rest[0..slash];
        if (host.len > 0 and !std.mem.eql(u8, host, "localhost")) continue;
        const start = at;
        var i: usize = slash;
        while (i < rest.len and at < names.len) : (at += 1) {
            const hex = if (rest[i] == '%' and i + 2 < rest.len) std.fmt.parseInt(u8, rest[i + 1 .. i + 3], 16) catch null else null;
            names[at] = hex orelse rest[i];
            i += if (hex != null) 3 else 1;
        }
        if (at == start) continue;
        ends[n] = @intCast(at);
        n += 1;
    }
    return n;
}

test "uri-list: local paths, percent-decoded; comments and remote hosts skipped" {
    var names: [256]u8 = undefined;
    var ends: [8]u32 = undefined;
    const list = "# from a file manager\r\nfile:///home/u/a%20b.png\r\nfile://localhost/tmp/x\r\nhttps://example.org/y\r\nfile://remote/z\r\nfile:///caf%C3%A9.txt\r\n";
    const n = parseUriList(list, &names, &ends);
    try std.testing.expectEqual(@as(u32, 3), n);
    const fs: Files = .{ .names = names[0..ends[n - 1]], .ends = ends[0..n] };
    try std.testing.expectEqualStrings("/home/u/a b.png", fs.path(0));
    try std.testing.expectEqualStrings("/tmp/x", fs.path(1));
    try std.testing.expectEqualStrings("/caf\xc3\xa9.txt", fs.path(2));
}
