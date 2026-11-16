//! The X11 shell: a window on an X server, spoken to over the wire protocol on the display's
//! Unix socket (wire.zig), so nothing is linked and no libxcb or libX11 is needed. It meets the
//! shell contract of src/shell/iface.zig: `poll` turns the server's events into `Input`,
//! `present` draws the frame with the software back end and sends the pixels with PutImage.
//!
//! A module of its own over `lcgr` (`zig build x11`), like the GL ES back end, because it calls
//! Linux directly (socket, poll); the core never imports it.
//!
//! Two types, so that one connection serves several windows: `Connection` (the socket and what
//! the server said at setup) and `Window` (one top-level window and the shell calls). Both live
//! where the caller puts them and must not move once opened: the connection routes events to
//! its windows by pointer.

const std = @import("std");
const linux = std.os.linux;
const lcgr = @import("lcgr");
const wire = lcgr.shell_x11_wire;
const keys = lcgr.shell_x11_keys;
const xim = lcgr.shell_x11_xim;
const Input = lcgr.input.Input;
const iface = lcgr.shell_iface;
const Events = iface.Events;
const context = lcgr.context;
const Platform = context.Platform;
const Output = context.Output;
const Pace = lcgr.scheduler.Pace;
const sw = lcgr.render_sw;
const render = lcgr.render_iface;
const Quad = lcgr.draw_list.Quad;
const Mono = lcgr.protocol.Mono;
const Color = lcgr.types.Color;
const inf = lcgr.types.inf;

pub const Error = error{
    UnsupportedDisplay,
    ConnectFailed,
    ConnectionClosed,
    /// The server answered a request with an error (`Connection.last_error`).
    RequestFailed,
    /// A reply larger than the read buffer.
    MessageTooLarge,
    NoExtension,
    /// `openIme`: no input method server of that name.
    NoInputMethod,
    TooManyWindows,
} || wire.Setup.Error;

/// Atoms the shell uses, interned at `open`. Field names are the atom names.
pub const Atoms = struct {
    WM_PROTOCOLS: u32 = 0,
    WM_DELETE_WINDOW: u32 = 0,
    _NET_WM_NAME: u32 = 0,
    UTF8_STRING: u32 = 0,
    RESOURCE_MANAGER: u32 = 0,
    CLIPBOARD: u32 = 0,
    TARGETS: u32 = 0,
    TEXT: u32 = 0,
    /// Where a paste is delivered, on the requesting window.
    LCGR_PASTE: u32 = 0,
    /// The XIM transport's ClientMessage types.
    _XIM_XCONNECT: u32 = 0,
    _XIM_PROTOCOL: u32 = 0,
    _XIM_MOREDATA: u32 = 0,
};

/// Predefined atoms.
const atom_atom = 4;
const atom_string = 31;

pub const max_windows = 8;

pub const Connection = struct {
    fd: i32 = -1,
    setup: wire.Setup = undefined,
    atoms: Atoms = .{},
    /// Sequence number of the last request sent (the server counts the same way).
    seq: u16 = 0,
    next_id: u32 = 0,
    windows: [max_windows]?*Window = @splat(null),
    out: [64 * 1024]u8 = undefined,
    out_len: usize = 0,
    in: [64 * 1024]u8 = undefined,
    /// Unread bytes are `in[in_at..in_len]`.
    in_at: usize = 0,
    in_len: usize = 0,
    /// Errors the server sent for requests nobody waited on, and the last one (32 bytes).
    errors: u32 = 0,
    last_error: [32]u8 = @splat(0),
    keymap: keys.Keymap = .{},
    /// A MappingNotify said the keyboard map changed; reloaded at the end of the next `pump`.
    keymap_stale: bool = false,
    /// Physical pixels per logical pixel for new windows (`wire.scale`), and whether a change
    /// of Xft.dpi or of the screen asks to read it again at the end of the next `pump`.
    scale: f32 = 1,
    scale_stale: bool = false,
    /// The screen's size for the fallback, from the setup and then RandR.
    screen_px: u16 = 0,
    screen_mm: u16 = 0,
    /// RandR's ScreenChangeNotify event code; 0 without RandR.
    randr_event: u8 = 0,
    /// The "cursor" font and a cursor per `context.Cursor`, created on first use; 0 is none.
    cursor_font: u32 = 0,
    cursors: [cursor_glyphs.len]u32 = @splat(0),
    /// What this application put on the clipboard, and the window that owns the CLIPBOARD
    /// selection for it (0 once another client took it).
    clip: [64 * 1024]u8 = undefined,
    clip_len: usize = 0,
    clip_owner: u32 = 0,
    /// The input method connection (`openIme`).
    ime: Ime = .{},
    /// A key event the input method gave back is being handled: it is not forwarded again.
    replaying: bool = false,
    /// Set when the socket failed or closed; every window's `poll` is false after it.
    err: ?Error = null,

    /// Connects to `display` (a `DISPLAY` value such as ":0") with the Xauthority file's bytes
    /// `xauthority` (empty when there is none or the server needs none), and interns `Atoms`.
    pub fn open(c: *Connection, display: []const u8, xauthority: []const u8) Error!void {
        c.* = .{};
        const d = try wire.Display.parse(display);
        var path_buf: [64]u8 = undefined;
        const path = d.path(&path_buf);
        c.fd = try connectUnix(path);
        errdefer _ = linux.close(c.fd);

        const auth = wire.cookie(xauthority, d.number);
        _ = c.send(wire.setupSize(auth), wire.setup, .{auth});
        c.seq = 0; // the setup is not a request
        try c.flush();
        try c.readAtLeast(8);
        const total = 8 + @as(usize, wire.get(u16, c.in[c.in_at..], 6)) * 4;
        if (total > c.in.len) return error.MessageTooLarge;
        try c.readAtLeast(total);
        c.setup = try wire.Setup.parse(c.in[c.in_at..][0..total], d.screen);
        c.in_at += total;

        // Pipelined: every InternAtom first, then the replies in order.
        const names = @typeInfo(Atoms).@"struct".field_names;
        var seqs: [names.len]u16 = undefined;
        inline for (names, &seqs) |name, *s| s.* = c.send(wire.internAtomSize(name), wire.internAtom, .{name});
        inline for (names, seqs) |name, s| @field(c.atoms, name) = wire.get(u32, try c.reply(s), 8);
        try c.loadKeymap();
        // Held keys repeat as presses alone (`.repeat`), where the server supports XKB.
        if (c.extension("XKEYBOARD")) |xkb| {
            const use = try c.reply(c.send(wire.xkb_use_extension_size, wire.xkbUseExtension, .{xkb}));
            if (use[1] != 0) _ = try c.reply(c.send(wire.xkb_per_client_flags_size, wire.xkbDetectableAutoRepeat, .{xkb}));
        } else |_| {}

        // Scale: Xft.dpi changes arrive as PropertyNotify on the root, screen changes from RandR.
        c.screen_px = c.setup.width_px;
        c.screen_mm = c.setup.width_mm;
        _ = c.send(wire.change_event_mask_size, wire.changeEventMask, .{ c.setup.root, wire.Mask.property_change });
        if (c.extension("RANDR")) |randr| {
            c.randr_event = (try c.reply(c.send(wire.queryExtensionSize("RANDR"), wire.queryExtension, .{"RANDR"})))[10];
            _ = c.send(wire.randr_select_input_size, wire.randrSelectInput, .{ randr, c.setup.root });
        } else |_| {}
        try c.readScale();
    }

    fn readScale(c: *Connection) Error!void {
        const r = try c.reply(c.send(wire.get_property_size, wire.getProperty, .{ c.setup.root, c.atoms.RESOURCE_MANAGER, false, 4096 }));
        const len = @min(wire.get(u32, r, 16) * (r[1] / 8), r.len - 32);
        c.scale = wire.scale(wire.resourceDpi(r[32..][0..len]), c.screen_px, c.screen_mm);
        for (c.windows) |slot| {
            if (slot) |w| w.setScale(c.scale);
        }
    }

    fn loadKeymap(c: *Connection) Error!void {
        const s = c.setup;
        const r = try c.reply(c.send(wire.get_keyboard_mapping_size, wire.getKeyboardMapping, .{ s.min_keycode, s.max_keycode - s.min_keycode + 1 }));
        c.keymap.load(r, s.min_keycode);
    }

    pub fn close(c: *Connection) void {
        if (c.fd >= 0) _ = linux.close(c.fd);
        c.fd = -1;
    }

    /// A new resource id.
    pub fn id(c: *Connection) u32 {
        const s = c.setup;
        c.next_id += 1;
        // Ids are base | (n shifted into the mask).
        return s.id_base | ((c.next_id << @as(u5, @intCast(@ctz(s.id_mask)))) & s.id_mask);
    }

    /// Writes one request of `size` bytes with `f(buf, args...)`; returns its sequence number.
    pub fn send(c: *Connection, size: usize, comptime f: anytype, args: anytype) u16 {
        if (c.out.len - c.out_len < size) c.flush() catch {};
        var b: wire.Buf = .{ .bytes = c.out[c.out_len..] };
        @call(.auto, f, .{&b} ++ args);
        std.debug.assert(b.len == size);
        c.out_len += size;
        c.seq +%= 1;
        return c.seq;
    }

    pub fn flush(c: *Connection) Error!void {
        const n = c.out_len;
        c.out_len = 0;
        try c.writeAll(c.out[0..n]);
    }

    fn writeAll(c: *Connection, bytes: []const u8) Error!void {
        if (c.err) |e| return e;
        var at: usize = 0;
        while (at < bytes.len) {
            const r = linux.write(c.fd, bytes[at..].ptr, bytes.len - at);
            switch (linux.errno(r)) {
                .SUCCESS => at += r,
                .INTR => {},
                else => return c.fail(error.ConnectionClosed),
            }
        }
    }

    fn fail(c: *Connection, e: Error) Error {
        c.err = e;
        return e;
    }

    /// Reads once from the socket, blocking. Moves unread bytes to the front first.
    fn readSome(c: *Connection) Error!void {
        if (c.err) |e| return e;
        if (c.in_at > 0) {
            std.mem.copyForwards(u8, c.in[0 .. c.in_len - c.in_at], c.in[c.in_at..c.in_len]);
            c.in_len -= c.in_at;
            c.in_at = 0;
        }
        if (c.in_len == c.in.len) return c.fail(error.MessageTooLarge);
        while (true) {
            const r = linux.read(c.fd, c.in[c.in_len..].ptr, c.in.len - c.in_len);
            switch (linux.errno(r)) {
                .SUCCESS => {
                    if (r == 0) return c.fail(error.ConnectionClosed);
                    c.in_len += r;
                    return;
                },
                .INTR => {},
                else => return c.fail(error.ConnectionClosed),
            }
        }
    }

    fn readAtLeast(c: *Connection, n: usize) Error!void {
        while (c.in_len - c.in_at < n) try c.readSome();
    }

    /// The next complete message in the read buffer, or null.
    fn message(c: *Connection) Error!?[]const u8 {
        const left = c.in_len - c.in_at;
        if (left < 32) return null;
        const size = wire.messageSize(c.in[c.in_at..][0..32]);
        if (size > c.in.len) return c.fail(error.MessageTooLarge);
        if (left < size) return null;
        const m = c.in[c.in_at..][0..size];
        c.in_at += size;
        return m;
    }

    /// Flushes, then reads until the reply to request `seq`, handling every event on the way.
    /// The reply is valid until the next read.
    pub fn reply(c: *Connection, seq: u16) Error![]const u8 {
        try c.flush();
        while (true) {
            while (try c.message()) |m| {
                const kind = m[0] & 0x7f;
                const mine = wire.get(u16, m, 2) == seq;
                if (kind == wire.reply and mine) return m;
                if (kind == wire.err and mine) {
                    @memcpy(&c.last_error, m[0..32]);
                    return error.RequestFailed;
                }
                c.handle(m);
            }
            try c.readSome();
        }
    }

    /// One round trip: afterwards the server has handled every request sent before it.
    pub fn sync(c: *Connection) Error!void {
        _ = try c.reply(c.send(wire.get_input_focus_size, wire.getInputFocus, .{}));
    }

    /// Sends what is queued and handles every event already sent, without blocking.
    pub fn pump(c: *Connection) Error!void {
        try c.flush();
        while (true) {
            while (try c.message()) |m| c.handle(m);
            var p = [_]linux.pollfd{.{ .fd = c.fd, .events = linux.POLL.IN }};
            const r = linux.poll(&p, 1, 0);
            if (linux.errno(r) != .SUCCESS or r == 0) break;
            try c.readSome();
        }
        try c.readImeProperties();
        if (c.scale_stale) {
            c.scale_stale = false;
            try c.readScale();
        }
        if (c.keymap_stale) {
            c.keymap_stale = false;
            try c.loadKeymap();
        }
    }

    /// Blocks until the socket has something to read or `seconds` pass (`inf`: no limit).
    pub fn waitReadable(c: *Connection, seconds: f32) void {
        if (c.err != null or c.in_len - c.in_at >= 32) return;
        const ms: i32 = if (seconds >= inf) -1 else @intFromFloat(@min(@ceil(@max(seconds, 0) * 1000), 1e9));
        var p = [_]linux.pollfd{.{ .fd = c.fd, .events = linux.POLL.IN }};
        _ = linux.poll(&p, 1, ms);
    }

    /// Routes an event to its window.
    fn handle(c: *Connection, m: []const u8) void {
        const kind = m[0] & 0x7f;
        if (kind == wire.err) {
            c.errors += 1;
            @memcpy(&c.last_error, m[0..32]);
            return;
        }
        if (kind == wire.mapping_notify and m[4] != 0) c.keymap_stale = true; // keyboard or modifiers
        if (kind == wire.selection_request) c.answer(m) catch {};
        if (kind == wire.client_message and c.ime.window != 0 and wire.get(u32, m, 4) == c.ime.window) return c.imeEvent(m);
        if (kind == wire.selection_clear and wire.get(u32, m, 12) == c.atoms.CLIPBOARD) c.clip_owner = 0;
        if (kind == wire.property_notify and wire.get(u32, m, 4) == c.setup.root and wire.get(u32, m, 8) == c.atoms.RESOURCE_MANAGER) c.scale_stale = true;
        if (c.randr_event != 0 and kind == c.randr_event) {
            // ScreenChangeNotify: the root's new size in pixels and millimetres.
            c.screen_px = wire.get(u16, m, 24);
            c.screen_mm = wire.get(u16, m, 28);
            c.scale_stale = true;
        }
        const target = wire.eventWindow(m);
        for (c.windows) |slot| {
            const w = slot orelse continue;
            if (w.id == target) w.handle(m);
        }
    }

    /// Connects to the XIM input method server `name` (what follows `@im=` in XMODIFIERS, such
    /// as "ibus" or "fcitx") for `locale` (such as "en_US"). Asynchronous: the handshake runs in
    /// later `poll`s, and windows use the IME once it is ready (`ime.state == .ready`) and a
    /// frame asks for text input. Over-the-spot: the server draws the composition next to the
    /// frame's `ime_rect` and sends committed text, which arrives as typed text. Keys the server
    /// does not use come back and are reported as usual.
    pub fn openIme(c: *Connection, name: []const u8, locale: []const u8) Error!void {
        var buf: [96]u8 = undefined;
        const server = std.fmt.bufPrint(&buf, "@server={s}", .{name}) catch return error.NoInputMethod;
        const atom = wire.get(u32, try c.reply(c.send(wire.internAtomSize(server), wire.internAtom, .{server})), 8);
        const owner = wire.get(u32, try c.reply(c.send(wire.get_selection_owner_size, wire.getSelectionOwner, .{atom})), 8);
        if (owner == 0) return error.NoInputMethod;
        c.ime = .{ .window = c.id() };
        try c.ime.init(c, locale);
        _ = c.send(wire.create_window_size, wire.createWindow, .{ c.ime.window, c.setup.root, 1, 1, 0 });
        const l = [5]u32{ c.ime.window, 0, 0, 0, 0 };
        const msg = wire.clientMessage(owner, c.atoms._XIM_XCONNECT, 32, std.mem.asBytes(&l));
        _ = c.send(wire.send_event_size, wire.sendEvent, .{ owner, 0, &msg });
        c.ime.state = .xconnect;
        try c.flush();
    }

    /// Reads the XIM messages that came as properties (their ClientMessage only names them).
    fn readImeProperties(c: *Connection) Error!void {
        const ime = &c.ime;
        // In order: more may be added while a reply is awaited.
        while (ime.pending_len > 0) {
            const p = ime.pending[0];
            std.mem.copyForwards([2]u32, ime.pending[0 .. ime.pending_len - 1], ime.pending[1..ime.pending_len]);
            ime.pending_len -= 1;
            const words = @min((p[1] + 3) / 4, ime.in.len / 4);
            const r = try c.reply(c.send(wire.get_property_size, wire.getProperty, .{ ime.window, p[0], true, @as(u32, @intCast(words)) }));
            const len = @min(wire.get(u32, r, 16) * (r[1] / 8), r.len - 32, ime.in.len);
            @memcpy(ime.in[0..len], r[32..][0..len]);
            ime.in_len = len;
            c.imeMessage();
        }
    }

    /// The XIM transport: a ClientMessage to our IM window.
    fn imeEvent(c: *Connection, m: []const u8) void {
        const ime = &c.ime;
        const a = c.atoms;
        const kind = wire.get(u32, m, 8);
        if (kind == a._XIM_XCONNECT and ime.state == .xconnect) {
            ime.server = wire.get(u32, m, 12);
            ime.major = wire.get(u32, m, 16);
            ime.dividing = wire.get(u32, m, 24);
            ime.state = .connect;
            var b: [12]u8 = undefined;
            var w: wire.Buf = .{ .bytes = &b };
            xim.connect(&w);
            c.imeSend(ime, b[0..w.len]);
        } else if (kind == a._XIM_MOREDATA or (kind == a._XIM_PROTOCOL and m[1] == 8)) {
            const n = @min(20, ime.in.len - ime.in_len);
            @memcpy(ime.in[ime.in_len..][0..n], m[12..][0..n]);
            ime.in_len += n;
            if (kind == a._XIM_PROTOCOL) c.imeMessage();
        } else if (kind == a._XIM_PROTOCOL and ime.pending_len < ime.pending.len) {
            // Format 32: the message is in a property of ours, read after this batch of events.
            ime.pending[ime.pending_len] = .{ wire.get(u32, m, 16), wire.get(u32, m, 12) };
            ime.pending_len += 1;
        }
    }

    /// Sends one XIM message over the transport the server chose: ClientMessages of 20 bytes
    /// (major 0, chained with _XIM_MOREDATA), or a property and a ClientMessage naming it
    /// (major 2, and major 1 above the dividing size).
    fn imeSend(c: *Connection, ime: *Ime, msg: []const u8) void {
        const a = c.atoms;
        if (ime.major == 0 or (ime.major == 1 and msg.len <= @min(ime.dividing, 20))) {
            var at: usize = 0;
            while (at < msg.len) : (at += 20) {
                const last = at + 20 >= msg.len;
                const chunk = msg[at..@min(at + 20, msg.len)];
                const e = wire.clientMessage(ime.server, if (last) a._XIM_PROTOCOL else a._XIM_MOREDATA, 8, chunk);
                _ = c.send(wire.send_event_size, wire.sendEvent, .{ ime.server, 0, &e });
            }
        } else {
            // Properties take turns, so the server can read one while the next is written.
            const prop = ime.props[ime.next_prop % ime.props.len];
            ime.next_prop +%= 1;
            _ = c.send(wire.changePropertySize(msg.len), wire.appendProperty, .{ ime.server, prop, atom_string, 8, msg });
            const l = [5]u32{ @intCast(msg.len), prop, 0, 0, 0 };
            const e = wire.clientMessage(ime.server, a._XIM_PROTOCOL, 32, std.mem.asBytes(&l));
            _ = c.send(wire.send_event_size, wire.sendEvent, .{ ime.server, 0, &e });
        }
        c.flush() catch {};
    }

    /// Handles the XIM message gathered in `ime.in`.
    fn imeMessage(c: *Connection) void {
        const ime = &c.ime;
        defer ime.in_len = 0;
        if (ime.in_len < 4) return;
        const msg = ime.in[0..@min(xim.size(&ime.in), ime.in_len)];
        var out: [64]u8 = undefined;
        var b: wire.Buf = .{ .bytes = &out };
        switch (msg[0]) {
            xim.op.connect_reply => {
                xim.open(&b, ime.locale[0..ime.locale_len]);
                ime.state = .open;
            },
            xim.op.open_reply => {
                const r = xim.openReply(msg);
                ime.im = r.im;
                ime.attrs = r.attrs;
                if (!r.attrs.complete()) {
                    ime.state = .failed;
                    return;
                }
                xim.encodingNegotiation(&b, ime.im);
                ime.state = .ready;
            },
            xim.op.set_event_mask => if (msg.len >= 16) {
                ime.forward_mask = wire.get(u32, msg, 8);
                ime.sync_mask = wire.get(u32, msg, 12);
            },
            xim.op.create_ic_reply => if (ime.creating) |w| {
                ime.creating = null;
                w.ic = wire.get(u16, msg, 6);
                if (w.applied.wants_text) {
                    xim.onIc(&b, xim.op.set_ic_focus, ime.im, w.ic);
                    w.ime_on = true;
                }
            },
            xim.op.forward_event => if (msg.len >= 44) {
                // A key the input method did not use: handled as if it came from the server.
                c.replaying = true;
                c.handle(msg[12..44]);
                c.replaying = false;
                if (wire.get(u16, msg, 8) & 1 != 0) xim.onIc(&b, xim.op.sync_reply, ime.im, wire.get(u16, msg, 6));
            },
            xim.op.commit => {
                const commit = xim.Commit.parse(msg);
                const ic = wire.get(u16, msg, 6);
                for (c.windows) |slot| {
                    const w = slot orelse continue;
                    if (w.ic != ic) continue;
                    var text: [512]u8 = undefined;
                    const n = xim.compoundToUtf8(commit.text, &text);
                    const f = &w.frames[w.cur];
                    if (n > 0) f.typedBytes(text[0..n]) else if (keys.codepoint(commit.keysym) != 0) f.typed(keys.codepoint(commit.keysym));
                }
                if (commit.flag & xim.Commit.synchronous != 0) xim.onIc(&b, xim.op.sync_reply, ime.im, ic);
            },
            xim.op.sync => xim.onIc(&b, xim.op.sync_reply, ime.im, wire.get(u16, msg, 6)),
            // The server refused something; keys are handled here from now on.
            xim.op.err => ime.state = .failed,
            else => {},
        }
        if (b.len > 0) c.imeSend(ime, out[0..b.len]);
    }

    /// Answers another client's request for the clipboard: the list of targets, or the text as
    /// UTF8_STRING, STRING or TEXT. No INCR transfers: the text goes in one property.
    fn answer(c: *Connection, m: []const u8) Error!void {
        const a = c.atoms;
        const requestor = wire.get(u32, m, 12);
        const selection = wire.get(u32, m, 16);
        const target = wire.get(u32, m, 20);
        var property = wire.get(u32, m, 24);
        if (property == 0) property = target; // an obsolete requestor
        const text = target == a.UTF8_STRING or target == atom_string or target == a.TEXT;
        const ours = selection == a.CLIPBOARD and c.clip_owner != 0;
        if (ours and target == a.TARGETS) {
            const targets = [_]u32{ a.TARGETS, a.UTF8_STRING, atom_string, a.TEXT };
            _ = c.send(wire.changePropertySize(16), wire.changeProperty, .{ requestor, property, atom_atom, 32, std.mem.sliceAsBytes(&targets) });
        } else if (ours and text) {
            const data = c.clip[0..c.clip_len];
            const kind = if (target == atom_string) atom_string else a.UTF8_STRING;
            _ = c.send(wire.change_property_head, wire.changePropertyHead, .{ requestor, property, kind, 8, data.len });
            try c.flush();
            try c.writeAll(data);
            try c.writeAll(("\x00\x00\x00")[0..wire.pad4(data.len)]);
        } else property = 0;
        const note = wire.selectionNotify(requestor, selection, target, property);
        _ = c.send(wire.send_event_size, wire.sendEvent, .{ requestor, 0, &note });
    }

    /// Major opcode of extension `name`.
    pub fn extension(c: *Connection, name: []const u8) Error!u8 {
        const r = try c.reply(c.send(wire.queryExtensionSize(name), wire.queryExtension, .{name}));
        if (r[8] == 0) return error.NoExtension;
        return r[9];
    }
};

/// Glyphs of the core cursor font (X11 cursorfont.h) for each `context.Cursor`: left_ptr,
/// hand2, xterm, fleur, sb_h_double_arrow, sb_v_double_arrow. Desktops' Xcursor themes are
/// files read by libXcursor on the client; this shell draws the server's own glyphs instead.
const cursor_glyphs = [_]u16{ 68, 60, 152, 52, 108, 116 };

comptime {
    std.debug.assert(cursor_glyphs.len == @typeInfo(context.Cursor).@"enum".field_names.len);
}

/// The XIM connection of a `Connection`.
pub const Ime = struct {
    state: State = .off,
    /// Our window for the transport, and the server's.
    window: u32 = 0,
    server: u32 = 0,
    /// Transport version and dividing size from the server's _XIM_XCONNECT.
    major: u32 = 0,
    dividing: u32 = 20,
    im: u16 = 0,
    attrs: xim.Attrs = .{},
    /// Events (KeyPress 1, KeyRelease 2) to forward, and those to forward synchronously.
    forward_mask: u32 = 0,
    sync_mask: u32 = 0,
    /// The window whose XIM_CREATE_IC awaits its reply.
    creating: ?*Window = null,
    locale: [32]u8 = undefined,
    locale_len: usize = 0,
    /// Properties for messages sent that way, used in turn.
    props: [8]u32 = @splat(0),
    next_prop: u32 = 0,
    /// The message being gathered from ClientMessages, or read from a property.
    in: [4096]u8 = undefined,
    in_len: usize = 0,
    /// Properties named by format-32 _XIM_PROTOCOL messages: atom and length.
    pending: [8][2]u32 = undefined,
    pending_len: usize = 0,

    pub const State = enum { off, xconnect, connect, open, ready, failed };

    fn init(ime: *Ime, c: *Connection, locale: []const u8) Error!void {
        ime.locale_len = @min(locale.len, ime.locale.len);
        @memcpy(ime.locale[0..ime.locale_len], locale[0..ime.locale_len]);
        var seqs: [8]u16 = undefined;
        for (&seqs, 0..) |*s, i| {
            var name: [16]u8 = undefined;
            const n = std.fmt.bufPrint(&name, "_LCGR_XIM{d}", .{i}) catch unreachable;
            s.* = c.send(wire.internAtomSize(n), wire.internAtom, .{n});
        }
        for (seqs, &ime.props) |s, *p| p.* = wire.get(u32, try c.reply(s), 8);
    }

    /// Whether `w`'s key event `kind` goes to the input method instead of being handled here.
    fn forwards(ime: *const Ime, w: *const Window, kind: u8, replaying: bool) bool {
        const bit: u32 = if (kind == wire.key_press) 1 else 2;
        return ime.state == .ready and w.ic != 0 and w.ime_on and !replaying and ime.forward_mask & bit != 0;
    }
};

fn connectUnix(path: []const u8) Error!i32 {
    const r = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(r) != .SUCCESS) return error.ConnectFailed;
    const fd: i32 = @intCast(r);
    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    @memcpy(addr.path[0..path.len], path);
    if (linux.errno(linux.connect(fd, &addr, @sizeOf(linux.sockaddr.un))) == .SUCCESS) return fd;
    // Xwayland and some X servers listen only on the abstract socket of the same name.
    addr.path = @splat(0);
    @memcpy(addr.path[1..][0..path.len], path);
    if (linux.errno(linux.connect(fd, &addr, @intCast(@sizeOf(linux.sa_family_t) + 1 + path.len))) == .SUCCESS) return fd;
    _ = linux.close(fd);
    return error.ConnectFailed;
}

fn now() f64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(f64, @floatFromInt(ts.sec)) + @as(f64, @floatFromInt(ts.nsec)) * 1e-9;
}

pub const Window = struct {
    conn: *Connection,
    id: u32,
    gc: u32,
    /// Size in physical pixels, from the last ConfigureNotify.
    width: u16,
    height: u16,
    /// Physical pixels per logical pixel.
    scale: f32 = 1,
    /// Held state, updated as events arrive.
    held: Input = .{},
    /// Per-frame state being gathered, and the one `poll` last handed out (its slices stay valid
    /// until the next `poll`).
    frames: [2]PerFrame = .{ .{}, .{} },
    cur: u1 = 0,
    is_open: bool = true,
    /// An Expose arrived: the window's pixels have to be sent again.
    damaged: bool = false,
    presented: bool = false,
    /// Set by `wake`; makes the next `poll` report a frame.
    woken: std.atomic.Value(bool) = .init(false),
    t0: f64,
    pixels: []u32,
    fb: sw.Framebuffer,
    gfx: sw.Software = .{},
    font: Mono = .{},
    glyphs: Glyphs,
    background: Color = .rgb(0, 0, 0),
    applied: Platform = .{},
    /// The window's XIM input context (0: none yet), whether it has the IME's focus, and where
    /// the spot was last put, in physical pixels.
    ic: u16 = 0,
    ime_on: bool = false,
    spot: [2]i16 = .{ 0, 0 },
    /// A SelectionNotify said the pasted text is in LCGR_PASTE; `poll` reads it.
    paste_ready: bool = false,
    /// The cursor the window shows, so `apply` sends only changes.
    cursor: ?context.Cursor = null,
    polls: u32 = 0,
    presents: u32 = 0,

    const PerFrame = struct {
        wheel: [2]f32 = .{ 0, 0 },
        /// Typed UTF-8 and key events, in order. A frame that overflows them drops the rest.
        text: [16 * 1024]u8 = undefined,
        text_len: u32 = 0,
        events: [64]Input.Event = undefined,
        events_len: u32 = 0,

        fn add(f: *PerFrame, e: Input.Event) void {
            if (f.events_len == f.events.len) return;
            f.events[f.events_len] = e;
            f.events_len += 1;
        }
        fn typed(f: *PerFrame, cp: u21) void {
            var utf8: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &utf8) catch return;
            f.typedBytes(utf8[0..n]);
        }
        /// UTF-8 as one `.text` event; dropped whole when it does not fit.
        fn typedBytes(f: *PerFrame, bytes: []const u8) void {
            if (f.text.len - f.text_len < bytes.len or f.events_len == f.events.len or bytes.len == 0) return;
            @memcpy(f.text[f.text_len..][0..bytes.len], bytes);
            f.add(.{ .kind = .text, .at = f.text_len, .len = @intCast(bytes.len) });
            f.text_len += @intCast(bytes.len);
        }
    };

    /// Caller-owned storage. `pixels` holds `sw.Framebuffer.len(w, h)` for the largest size the
    /// window will be drawn at (a bigger window draws its top-left part); `glyphs` one quad per
    /// byte of text in a frame, `first` and `count` one row per text run.
    pub const Buffers = struct {
        pixels: []u32,
        glyphs: []Quad,
        first: []u32,
        count: []u32,
    };
    const Glyphs = struct { quads: []Quad, first: []u32, count: []u32 };

    const events = wire.Mask.key_press | wire.Mask.key_release | wire.Mask.button_press |
        wire.Mask.button_release | wire.Mask.enter_window | wire.Mask.leave_window |
        wire.Mask.pointer_motion | wire.Mask.exposure | wire.Mask.structure_notify |
        wire.Mask.focus_change | wire.Mask.property_change;

    /// Creates and maps a `width` x `height` window (physical pixels) titled `title`.
    pub fn open(w: *Window, c: *Connection, width: u16, height: u16, title: []const u8, buf: Buffers) Error!void {
        const slot = std.mem.indexOfScalar(?*Window, &c.windows, null) orelse return error.TooManyWindows;
        const xid = c.id();
        w.* = .{
            .conn = c,
            .id = xid,
            .gc = c.id(),
            .width = width,
            .height = height,
            .t0 = now(),
            .pixels = buf.pixels,
            .fb = .init(buf.pixels, 0, 0, .bgra8),
            .glyphs = .{ .quads = buf.glyphs, .first = buf.first, .count = buf.count },
        };
        w.setScale(c.scale);
        const a = c.atoms;
        _ = c.send(wire.create_window_size, wire.createWindow, .{ xid, c.setup.root, width, height, events });
        _ = c.send(wire.create_gc_size, wire.createGc, .{ w.gc, xid });
        _ = c.send(wire.changePropertySize(title.len), wire.changeProperty, .{ xid, a._NET_WM_NAME, a.UTF8_STRING, 8, title });
        const protocols = std.mem.asBytes(&a.WM_DELETE_WINDOW);
        _ = c.send(wire.changePropertySize(4), wire.changeProperty, .{ xid, a.WM_PROTOCOLS, 4, 32, protocols }); // type ATOM
        _ = c.send(wire.window_size, wire.onWindow, .{ wire.op.map_window, xid });
        c.windows[slot] = w;
        try c.sync();
    }

    /// Destroys the window and stops routing events to it.
    pub fn close(w: *Window) void {
        const c = w.conn;
        for (&c.windows) |*slot| {
            if (slot.* == w) slot.* = null;
        }
        _ = c.send(wire.window_size, wire.onWindow, .{ wire.op.destroy_window, w.id });
        c.flush() catch {};
        w.is_open = false;
    }

    /// A new scale: the viewport and the held pointer are logical pixels, so both follow.
    fn setScale(w: *Window, s: f32) void {
        const in = &w.held;
        const ratio = w.scale / s;
        const outside = in.pointer[0] < 0;
        in.pointer = if (outside) in.pointer else .{ in.pointer[0] * ratio, in.pointer[1] * ratio };
        w.scale = s;
        in.viewport = .{ @as(f32, @floatFromInt(w.width)) / s, @as(f32, @floatFromInt(w.height)) / s };
    }

    fn handle(w: *Window, m: []const u8) void {
        const f = &w.frames[w.cur];
        const in = &w.held;
        switch (m[0] & 0x7f) {
            wire.motion_notify, wire.enter_notify => {
                const p = wire.Pointer.of(m);
                in.pointer = .{ @as(f32, @floatFromInt(p.x)) / w.scale, @as(f32, @floatFromInt(p.y)) / w.scale };
            },
            // Mode Normal only: the grab a button press starts also sends a Leave.
            wire.leave_notify => if (m[30] == 0) {
                in.pointer = .{ -1, -1 };
            },
            wire.button_press, wire.button_release => {
                const down = (m[0] & 0x7f) == wire.button_press;
                const p = wire.Pointer.of(m);
                in.pointer = .{ @as(f32, @floatFromInt(p.x)) / w.scale, @as(f32, @floatFromInt(p.y)) / w.scale };
                switch (m[1]) {
                    1 => in.buttons.left = down,
                    2 => in.buttons.middle = down,
                    3 => in.buttons.right = down,
                    // Wheel notches come as press and release of buttons 4 to 7; count the presses.
                    4 => f.wheel[1] += @floatFromInt(@intFromBool(down)),
                    5 => f.wheel[1] -= @floatFromInt(@intFromBool(down)),
                    6 => f.wheel[0] += @floatFromInt(@intFromBool(down)),
                    7 => f.wheel[0] -= @floatFromInt(@intFromBool(down)),
                    else => {},
                }
            },
            wire.configure_notify => {
                w.width = wire.get(u16, m, 20);
                w.height = wire.get(u16, m, 22);
                in.viewport = .{ @as(f32, @floatFromInt(w.width)) / w.scale, @as(f32, @floatFromInt(w.height)) / w.scale };
            },
            wire.key_press, wire.key_release => {
                const c = w.conn;
                if (!c.ime.forwards(w, m[0] & 0x7f, c.replaying)) return w.key(m);
                var out: [xim.forward_event_size]u8 = undefined;
                var b: wire.Buf = .{ .bytes = &out };
                const bit: u32 = if ((m[0] & 0x7f) == wire.key_press) 1 else 2;
                xim.forwardEvent(&b, c.ime.im, w.ic, @intFromBool(c.ime.sync_mask & bit != 0), m);
                c.imeSend(&c.ime, &out);
            },
            wire.focus_out => {
                // Keys released while another window has the focus never reach this one.
                in.keys = .{};
                in.mods = .{};
            },
            wire.expose => w.damaged = true,
            wire.destroy_notify => w.is_open = false,
            wire.selection_notify => {
                const a = w.conn.atoms;
                if (wire.get(u32, m, 12) == a.CLIPBOARD and wire.get(u32, m, 20) == a.LCGR_PASTE) w.paste_ready = true;
            },
            wire.client_message => {
                const a = w.conn.atoms;
                if (wire.get(u32, m, 8) == a.WM_PROTOCOLS and wire.get(u32, m, 12) == a.WM_DELETE_WINDOW) w.is_open = false;
            },
            else => {},
        }
    }

    /// A key event: the held keys and modifiers, a press, repeat or release, and the text the
    /// key types with no Ctrl, Alt or Super held (those make it a command).
    fn key(w: *Window, m: []const u8) void {
        const in = &w.held;
        const f = &w.frames[w.cur];
        const down = (m[0] & 0x7f) == wire.key_press;
        const state = wire.Pointer.of(m).state;
        const code = keys.hid(m[1]);
        // The state is from before the event; a modifier key's own transition is added here.
        var mods: Input.Mods = .{
            .shift = state & wire.State.shift != 0,
            .ctrl = state & wire.State.control != 0,
            .alt = state & wire.State.mod1 != 0,
            .cmd = state & wire.State.mod4 != 0,
        };
        switch (code) {
            0xe0, 0xe4 => mods.ctrl = down,
            0xe1, 0xe5 => mods.shift = down,
            0xe2, 0xe6 => mods.alt = down,
            0xe3, 0xe7 => mods.cmd = down,
            else => {},
        }
        in.mods = mods;
        const bit = @as(u64, 1) << @as(u6, @truncate(code));
        const held = in.keys.down(code);
        in.keys.bits[code >> 6] = if (down) in.keys.bits[code >> 6] | bit else in.keys.bits[code >> 6] & ~bit;
        if (code == 0) return;
        f.add(.{ .kind = if (!down) .release else if (held) .repeat else .press, .code = code, .mods = mods });
        if (!down or mods.ctrl or mods.alt or mods.cmd) return;
        const cp = keys.codepoint(w.conn.keymap.keysym(m[1], state));
        if (cp != 0) f.typed(cp);
    }

    /// Turns the IME on where the frame asks for text and off where it does not, and keeps its
    /// spot at the bottom left of `ime_rect`. The input context is created on first use.
    fn applyIme(w: *Window, p: *const Platform) void {
        const c = w.conn;
        const ime = &c.ime;
        if (ime.state != .ready) return;
        const spot: [2]i16 = .{ @intFromFloat(std.math.clamp(p.ime_rect.x0 * w.scale, -32768, 32767)), @intFromFloat(std.math.clamp(p.ime_rect.y1 * w.scale, -32768, 32767)) };
        var out: [64]u8 = undefined;
        var b: wire.Buf = .{ .bytes = &out };
        if (w.ic == 0) {
            if (!p.wants_text or ime.creating != null) return;
            ime.creating = w;
            w.spot = spot;
            xim.createIc(&b, ime.im, ime.attrs, w.id, spot[0], spot[1]);
            return c.imeSend(ime, out[0..b.len]);
        }
        if (p.wants_text != w.ime_on) {
            w.ime_on = p.wants_text;
            xim.onIc(&b, if (p.wants_text) xim.op.set_ic_focus else xim.op.unset_ic_focus, ime.im, w.ic);
            c.imeSend(ime, out[0..b.len]);
            b.len = 0;
        }
        if (p.wants_text and !std.meta.eql(spot, w.spot)) {
            w.spot = spot;
            xim.setSpot(&b, ime.im, w.ic, ime.attrs, spot[0], spot[1]);
            c.imeSend(ime, out[0..b.len]);
        }
    }

    /// Handles the server's pending events and gives this window's frame. False once the window
    /// was closed (by the user through the window manager, or `close`) or the connection failed
    /// (`conn.err`).
    pub fn poll(w: *Window, ev: *Events) bool {
        const c = w.conn;
        c.pump() catch return false;
        if (!w.is_open) return false;
        if (w.damaged and w.presented) w.send() catch return false;
        if (w.paste_ready) {
            w.paste_ready = false;
            w.readPaste() catch return false;
        }
        w.damaged = false;
        _ = w.woken.swap(false, .acq_rel);

        const t = now() - w.t0;
        w.held.dt = @floatCast(t - w.held.time);
        w.held.time = t;
        w.held.scale = w.scale;
        const f = &w.frames[w.cur];
        ev.in = w.held;
        ev.in.wheel = f.wheel;
        ev.in.text = f.text[0..f.text_len];
        ev.in.events = f.events[0..f.events_len];
        w.cur ^= 1;
        w.frames[w.cur] = .{};
        w.polls += 1;
        return true;
    }

    /// Asks for the clipboard's text. It arrives in a later `poll` as typed text (a `.text` event
    /// and `Input.text`), as `keyboard.Clipboard.paste` expects; nothing arrives when the
    /// clipboard is empty or holds no text. Text longer than a frame's text buffer is dropped.
    pub fn requestPaste(w: *Window) void {
        const a = w.conn.atoms;
        _ = w.conn.send(wire.convert_selection_size, wire.convertSelection, .{ w.id, a.CLIPBOARD, a.UTF8_STRING, a.LCGR_PASTE });
        w.conn.flush() catch {};
    }

    fn readPaste(w: *Window) Error!void {
        const c = w.conn;
        const words: u32 = @intCast(@min(w.frames[0].text.len, c.in.len - 32) / 4);
        const r = try c.reply(c.send(wire.get_property_size, wire.getProperty, .{ w.id, c.atoms.LCGR_PASTE, true, words }));
        const len = @min(wire.get(u32, r, 16) * (r[1] / 8), r.len - 32);
        if (wire.get(u32, r, 12) == 0) w.frames[w.cur].typedBytes(r[32..][0..len]);
    }

    /// Sets the cursor the frame asks for, when it changed, and puts the text the frame copied
    /// on the clipboard (the CLIPBOARD selection, owned by this window).
    pub fn apply(w: *Window, p: *const Platform) void {
        w.applied = p.*;
        w.applyIme(p);
        if (p.clipboard.len > 0) {
            const c = w.conn;
            c.clip_len = @min(p.clipboard.len, c.clip.len);
            @memcpy(c.clip[0..c.clip_len], p.clipboard[0..c.clip_len]);
            c.clip_owner = w.id;
            _ = c.send(wire.set_selection_owner_size, wire.setSelectionOwner, .{ w.id, c.atoms.CLIPBOARD });
            c.flush() catch {};
        }
        if (w.cursor != p.cursor) {
            w.cursor = p.cursor;
            const c = w.conn;
            const k = @backingInt(p.cursor);
            if (c.cursor_font == 0) {
                c.cursor_font = c.id();
                _ = c.send(wire.openFontSize("cursor"), wire.openFont, .{ c.cursor_font, "cursor" });
            }
            if (c.cursors[k] == 0) {
                c.cursors[k] = c.id();
                _ = c.send(wire.create_glyph_cursor_size, wire.createGlyphCursor, .{ c.cursors[k], c.cursor_font, cursor_glyphs[k] });
            }
            _ = c.send(wire.change_cursor_size, wire.changeCursor, .{ w.id, c.cursors[k] });
            c.flush() catch {};
        }
    }

    /// Draws the frame in software and sends it.
    pub fn present(w: *Window, out: *const Output) void {
        w.presents += 1;
        const width: u32 = w.width;
        // A window larger than the pixel buffer draws as many whole rows as fit.
        const rows: u32 = @intCast(@min(w.height, w.pixels.len / sw.Framebuffer.len(width, 1)));
        w.fb = .init(w.pixels, width, rows, .bgra8);
        const g = w.glyphs;
        const n = w.font.quads(out.draw, g.quads, .{ .first = g.first, .count = g.count });
        w.gfx.prepare({}, out.draw, .{ .quads = g.quads[0..n], .first = g.first, .count = g.count }, .{ 0, 0 }, w.scale);
        w.fb.clear(w.background);
        render.render(&w.gfx, .{ .fb = &w.fb, .scissor = w.fb.all() }, out.draw);
        w.send() catch {};
        w.presented = true;
    }

    /// Sends the framebuffer with PutImage, in strips that fit the server's request size. Rows
    /// are `stride` pixels; the padding past `width` falls outside the window and is clipped.
    fn send(w: *Window) Error!void {
        const c = w.conn;
        const fb = &w.fb;
        if (fb.width == 0 or fb.height == 0) return;
        const row_bytes = @as(usize, fb.stride) * 4;
        const max_bytes = @as(usize, c.setup.max_request) * 4 - wire.put_image_head;
        const strip: u32 = @intCast(@max(1, @min(max_bytes / row_bytes, 0xffff)));
        var y: u32 = 0;
        while (y < fb.height) : (y += strip) {
            const h = @min(strip, fb.height - y);
            _ = c.send(wire.put_image_head, wire.putImage, .{ w.id, w.gc, @as(u16, @intCast(fb.stride)), @as(u16, @intCast(h)), 0, @as(i16, @intCast(y)), c.setup.root_depth });
            try c.flush();
            try c.writeAll(std.mem.sliceAsBytes(fb.pixels[y * fb.stride ..][0 .. h * fb.stride]));
        }
    }

    /// Blocks until the server sends something or `seconds` pass (`inf`: no limit).
    pub fn wait(w: *Window, seconds: f32, pace: Pace) void {
        _ = pace;
        if (w.woken.load(.acquire)) return;
        w.conn.waitReadable(seconds);
    }

    /// Thread-safe: the next `poll` gives a frame.
    pub fn wake(w: *Window) void {
        w.woken.store(true, .release);
    }
};

comptime {
    iface.check(Window);
}

// ---------------------------------------------------------------------------------------------
// Tests on a real X server. They run only when LCGR_X11_TEST_DISPLAY names one (ci/run.sh x11
// starts Xvfb for them): they create windows and move the pointer with XTEST, which must never
// happen on the desktop of whoever runs `zig build x11`.

const testing = std.testing;
const mem = lcgr.mem;
const example = lcgr.shell_example;
const Replay = lcgr.input.Replay;

fn testDisplay() ![]const u8 {
    return testing.environ.getPosix("LCGR_X11_TEST_DISPLAY") orelse error.SkipZigTest;
}

const example_limits: context.Limits = .{ .nodes = 1024, .texts = 256 };
const fb_w = 800;
const fb_h = 600;

const Fixture = struct {
    var conn: Connection = .{};
    var ctx_buffer: [context.Context.requiredBytes(example_limits)]u8 align(mem.column_align) = undefined;
    var pixels: [sw.Framebuffer.len(fb_w, fb_h)]u32 = undefined;
    var glyphs: [512]Quad = undefined;
    var first: [example_limits.texts]u32 = undefined;
    var count: [example_limits.texts]u32 = undefined;
    var text: [64]u8 = undefined;
    var events: [16]Input.Event = undefined;
    var contacts: [4]Input.Contact = undefined;

    const buffers: Window.Buffers = .{ .pixels = &pixels, .glyphs = &glyphs, .first = &first, .count = &count };
};

/// Fakes the input that takes the server from `from` to `to`: pointer motion and buttons, in
/// window coordinates (the window sits at the root's origin: Xvfb has no window manager).
fn inject(c: *Connection, xtest: u8, from: *const Input, to: *const Input) void {
    const root = c.setup.root;
    if (!std.meta.eql(from.pointer, to.pointer) and to.pointer[0] >= 0)
        _ = c.send(wire.fake_input_size, wire.fakeInput, .{ xtest, wire.motion_notify, 0, root, @as(i16, @intFromFloat(to.pointer[0])), @as(i16, @intFromFloat(to.pointer[1])) });
    const buttons = [_][2]bool{ .{ from.buttons.left, to.buttons.left }, .{ from.buttons.middle, to.buttons.middle }, .{ from.buttons.right, to.buttons.right } };
    for (buttons, 1..) |b, n| {
        if (b[0] == b[1]) continue;
        const kind: u8 = if (b[1]) wire.button_press else wire.button_release;
        _ = c.send(wire.fake_input_size, wire.fakeInput, .{ xtest, kind, @as(u8, @intCast(n)), root, 0, 0 });
    }
}

/// Polls until the window's held pointer and buttons are `want`'s: injected input reaches the
/// client some time after the request that faked it.
fn settle(w: *Window, ev: *Events, want: *const Input) !void {
    for (0..2000) |_| {
        w.conn.pump() catch {};
        if (std.meta.eql(w.held.pointer, want.pointer) and w.held.buttons == want.buttons) break;
        w.conn.waitReadable(0.005);
    } else return error.InputNeverArrived;
    try testing.expect(w.poll(ev));
}

/// The colour of window pixel (x, y), read back from the server.
fn pixel(w: *Window, x: i16, y: i16) !Color {
    const c = w.conn;
    const r = try c.reply(c.send(wire.get_image_size, wire.getImage, .{ w.id, x, y, 1, 1 }));
    // bgra8 as the window's pixels; depth 24 keeps no alpha.
    return .{ .b = r[32], .g = r[33], .r = r[34], .a = 255 };
}

test "x11: the example runs from the input recording, and the window shows it" {
    const display = try testDisplay();
    const c = &Fixture.conn;
    try c.open(display, "");
    defer c.close();
    const xtest = try c.extension("XTEST");
    var w: Window = undefined;
    try w.open(c, fb_w, fb_h, "lcgr x11 test", Fixture.buffers);
    defer w.close();
    var ctx = try context.Context.init(&Fixture.ctx_buffer, example_limits);
    var app: example.App = .{};
    // Out of the window to start with, wherever an earlier test left the pointer.
    _ = c.send(wire.fake_input_size, wire.fakeInput, .{ xtest, wire.motion_notify, 0, c.setup.root, 1000, 760 });
    try c.sync();
    w.held.pointer = .{ -1, -1 };

    var replay: Replay = .{ .src = @embedFile("example.replay") };
    const buf: Replay.Buffers = .{ .text = &Fixture.text, .events = &Fixture.events, .contacts = &Fixture.contacts };
    var prev: Input = w.held;
    var ev: Events = .{};
    var frames: u32 = 0;
    while (try replay.next(buf)) |want| : (frames += 1) {
        inject(c, xtest, &prev, want);
        prev = want.*;
        try settle(&w, &ev, want);
        // The window's size is the recording's viewport.
        try testing.expectEqual(want.viewport, ev.in.viewport);
        if (!ctx.needsFrame(&ev.in)) continue;
        var f = ctx.begin(&ev.in);
        app.build(&f, &ev);
        const out = f.end(.{});
        w.apply(&out.platform);
        w.present(&out);
    }
    try testing.expectEqual(@as(u32, 15), frames);
    // What the recording did to the application, as with the headless shell.
    try testing.expectEqual(@as(u32, 13), app.builds);
    try testing.expectEqual(@as(u32, 1), app.resets);
    try testing.expectEqual(@as(u32, 4), app.layers);
    try testing.expectApproxEqAbs(@as(f32, 3), app.exposure, 0.01);
    try testing.expectEqual(context.Cursor.arrow, w.applied.cursor);
    // What the server shows: the sidebar's panel, a button face, the custom viewport left to the
    // host, a glyph cell of "Add layer".
    const th = app.theme;
    try testing.expectEqual(th.panel, try pixel(&w, 80, 590));
    try testing.expectEqual(th.control, try pixel(&w, 12, 74));
    try testing.expectEqual(w.background, try pixel(&w, 400, 300));
    try testing.expectEqual(th.text, try pixel(&w, 20, 70));
    try testing.expectEqual(@as(u32, 0), c.errors);
}

test "x11: closing the window ends poll" {
    const display = try testDisplay();
    const c = &Fixture.conn;
    try c.open(display, "");
    defer c.close();
    var w: Window = undefined;
    try w.open(c, 64, 64, "close", Fixture.buffers);
    var ev: Events = .{};
    try testing.expect(w.poll(&ev));
    try testing.expectEqual([2]f32{ 64, 64 }, ev.in.viewport);
    // What a window manager sends when the user clicks the close button.
    var msg: [32]u8 = @splat(0);
    msg[0] = wire.client_message;
    msg[1] = 32;
    std.mem.writeInt(u32, msg[4..8], w.id, .little);
    std.mem.writeInt(u32, msg[8..12], c.atoms.WM_PROTOCOLS, .little);
    std.mem.writeInt(u32, msg[12..16], c.atoms.WM_DELETE_WINDOW, .little);
    _ = c.send(wire.send_event_size, wire.sendEvent, .{ w.id, 0, &msg });
    try c.sync();
    try testing.expect(!w.poll(&ev));
    w.close();
}

test "x11: keys from the key recording become the recorded events and text" {
    const display = try testDisplay();
    const c = &Fixture.conn;
    try c.open(display, "");
    defer c.close();
    const xtest = try c.extension("XTEST");
    var w: Window = undefined;
    try w.open(c, fb_w, fb_h, "keys", Fixture.buffers);
    defer w.close();
    // Key events go to the focused window; with no window manager that is set by hand.
    _ = c.send(wire.set_input_focus_size, wire.setInputFocus, .{w.id});
    try c.sync();

    var replay: Replay = .{ .src = @embedFile("testdata/keys.replay") };
    const buf: Replay.Buffers = .{ .text = &Fixture.text, .events = &Fixture.events, .contacts = &Fixture.contacts };
    var ev: Events = .{};
    var frames: u32 = 0;
    while (try replay.next(buf)) |want| : (frames += 1) {
        for (want.events) |e| {
            if (e.kind == .text) continue;
            const kind: u8 = if (e.kind == .release) wire.key_release else wire.key_press;
            _ = c.send(wire.fake_input_size, wire.fakeInput, .{ xtest, kind, keys.keycodeOf(e.code), c.setup.root, 0, 0 });
        }
        // Wait until every event of the frame has arrived.
        for (0..2000) |_| {
            try c.pump();
            if (w.frames[w.cur].events_len >= want.events.len) break;
            c.waitReadable(0.005);
        } else return error.InputNeverArrived;
        try testing.expect(w.poll(&ev));
        try testing.expectEqualSlices(Input.Event, want.events, ev.in.events);
        try testing.expectEqualStrings(want.text, ev.in.text);
        try testing.expectEqual(want.mods, ev.in.mods);
    }
    try testing.expectEqual(@as(u32, 10), frames);
    try testing.expectEqual(Input.Keys{}, ev.in.keys);
}

test "x11: a held key repeats as presses" {
    const display = try testDisplay();
    const c = &Fixture.conn;
    try c.open(display, "");
    defer c.close();
    const xtest = try c.extension("XTEST");
    var w: Window = undefined;
    try w.open(c, 64, 64, "repeat", Fixture.buffers);
    defer w.close();
    _ = c.send(wire.set_input_focus_size, wire.setInputFocus, .{w.id});
    // Held past the server's autorepeat delay (660 ms by default), then released.
    const a_key = keys.keycodeOf(0x04);
    _ = c.send(wire.fake_input_size, wire.fakeInput, .{ xtest, wire.key_press, a_key, c.setup.root, 0, 0 });
    try c.flush();
    for (0..1000) |_| {
        try c.pump();
        if (w.frames[w.cur].events_len >= 4) break;
        c.waitReadable(0.005);
    } else return error.InputNeverArrived;
    _ = c.send(wire.fake_input_size, wire.fakeInput, .{ xtest, wire.key_release, a_key, c.setup.root, 0, 0 });
    try c.sync();
    for (0..1000) |_| {
        try c.pump();
        const f = &w.frames[w.cur];
        if (f.events[f.events_len - 1].kind == .release) break;
        c.waitReadable(0.005);
    } else return error.InputNeverArrived;
    var ev: Events = .{};
    try testing.expect(w.poll(&ev));
    // Press, then repeats, each with its text, and one release: no release-press pairs.
    const es = ev.in.events;
    try testing.expectEqual(Input.Event.Kind.press, es[0].kind);
    try testing.expectEqual(Input.Event.Kind.release, es[es.len - 1].kind);
    for (es[0 .. es.len - 1], 0..) |e, i| {
        const want: Input.Event.Kind = if (i % 2 == 1) .text else if (i == 0) .press else .repeat;
        try testing.expectEqual(want, e.kind);
    }
    try testing.expect(es.len >= 5);
    for (ev.in.text) |ch| try testing.expectEqual(@as(u8, 'a'), ch);
}

/// Pumps until `w.scale` is `want`.
fn waitScale(w: *Window, want: f32) !void {
    for (0..2000) |_| {
        try w.conn.pump();
        if (w.scale == want) return;
        w.conn.waitReadable(0.005);
    }
    return error.ScaleNeverChanged;
}

test "x11: the scale follows Xft.dpi and RandR's screen size" {
    const display = try testDisplay();
    const c = &Fixture.conn;
    try c.open(display, "");
    defer c.close();
    const xtest = try c.extension("XTEST");
    // Xvfb sets no Xft.dpi and reports a screen near 96 DPI.
    try testing.expectEqual(@as(f32, 1), c.scale);
    var w: Window = undefined;
    try w.open(c, fb_w, fb_h, "scale", Fixture.buffers);
    defer w.close();
    const root = c.setup.root;

    // A desktop sets Xft.dpi 192: every window doubles, its viewport and pointer halve.
    const res = "Xcursor.size:\t24\nXft.dpi:\t192\n";
    _ = c.send(wire.changePropertySize(res.len), wire.changeProperty, .{ root, c.atoms.RESOURCE_MANAGER, 31, 8, res }); // type STRING
    try waitScale(&w, 2);
    _ = c.send(wire.fake_input_size, wire.fakeInput, .{ xtest, wire.motion_notify, 0, root, 200, 100 });
    try c.sync();
    for (0..2000) |_| {
        try c.pump();
        if (w.held.pointer[0] == 100) break;
        c.waitReadable(0.005);
    }
    var ev: Events = .{};
    try testing.expect(w.poll(&ev));
    try testing.expectEqual(@as(f32, 2), ev.in.scale);
    try testing.expectEqual([2]f32{ 400, 300 }, ev.in.viewport);
    try testing.expectEqual([2]f32{ 100, 50 }, ev.in.pointer);

    // Without Xft.dpi the screen's physical size decides; RandR reports changes to it.
    _ = c.send(wire.delete_property_size, wire.deleteProperty, .{ root, c.atoms.RESOURCE_MANAGER });
    try waitScale(&w, 1);
    if (c.randr_event == 0) return error.SkipZigTest;
    const randr = try c.extension("RANDR");
    const s = c.setup;
    // The same pixels over half the millimetres: twice the DPI.
    _ = c.send(wire.randr_set_screen_size_size, wire.randrSetScreenSize, .{ randr, root, s.width_px, s.height_px, s.width_mm / 2, s.height_mm / 2 });
    const changed = waitScale(&w, 2);
    _ = c.send(wire.randr_set_screen_size_size, wire.randrSetScreenSize, .{ randr, root, s.width_px, s.height_px, s.width_mm, s.height_mm });
    try changed;
    try waitScale(&w, 1);
    try testing.expect(w.poll(&ev));
    try testing.expectEqual([2]f32{ 800, 600 }, ev.in.viewport);
}

test "x11: the cursor the frame asks for is the one the server shows" {
    const display = try testDisplay();
    const c = &Fixture.conn;
    try c.open(display, "");
    defer c.close();
    const xtest = try c.extension("XTEST");
    const xfixes = try c.extension("XFIXES");
    _ = try c.reply(c.send(wire.xfixes_query_version_size, wire.xfixesQueryVersion, .{xfixes}));
    var w: Window = undefined;
    try w.open(c, 200, 200, "cursor", Fixture.buffers);
    defer w.close();
    _ = c.send(wire.fake_input_size, wire.fakeInput, .{ xtest, wire.motion_notify, 0, c.setup.root, 100, 100 });

    // Each shape shows a different glyph (size and hot spot) and a different cursor object.
    const Shape = struct { size: [4]u16, serial: u32 };
    var shapes: [cursor_glyphs.len]Shape = undefined;
    for (&shapes, 0..) |*sh, k| {
        w.apply(&.{ .cursor = @fromBackingInt(@intCast(k)) });
        const r = try c.reply(c.send(wire.xfixes_get_cursor_image_size, wire.xfixesGetCursorImage, .{xfixes}));
        sh.* = .{ .size = .{ wire.get(u16, r, 12), wire.get(u16, r, 14), wire.get(u16, r, 16), wire.get(u16, r, 18) }, .serial = wire.get(u32, r, 20) };
        for (shapes[0..k]) |other| try testing.expect(other.serial != sh.serial and !std.meta.eql(other.size, sh.size));
    }
    // Back to the arrow: the same cursor as before, created once.
    w.apply(&.{ .cursor = .arrow });
    const r = try c.reply(c.send(wire.xfixes_get_cursor_image_size, wire.xfixesGetCursorImage, .{xfixes}));
    try testing.expectEqual(shapes[0].serial, wire.get(u32, r, 20));
    try testing.expectEqual(@as(u32, 0), c.errors);
}

test "x11: copy in one application, paste in another" {
    const display = try testDisplay();
    const Other = struct {
        var conn: Connection = .{};
        var pixels: [64 * 64]u32 = undefined;
    };
    const a = &Fixture.conn;
    const b = &Other.conn;
    try a.open(display, "");
    defer a.close();
    try b.open(display, "");
    defer b.close();
    var wa: Window = undefined;
    try wa.open(a, 64, 64, "copy", Fixture.buffers);
    defer wa.close();
    var bufs = Fixture.buffers;
    bufs.pixels = &Other.pixels;
    var wb: Window = undefined;
    try wb.open(b, 64, 64, "paste", bufs);
    defer wb.close();

    // A frame of the first application copies; the second pastes. Both run their loops.
    const text = "h\xc3\xa9llo, X11 \xe2\x9c\x93";
    wa.apply(&.{ .clipboard = text });
    try a.sync();
    wb.requestPaste();
    var ev: Events = .{};
    for (0..2000) |_| {
        try testing.expect(wa.poll(&ev));
        try testing.expect(wb.poll(&ev));
        if (ev.in.text.len > 0) break;
        b.waitReadable(0.005);
    } else return error.PasteNeverArrived;
    try testing.expectEqualStrings(text, ev.in.text);
    try testing.expectEqual(@as(usize, 1), ev.in.events.len);
    try testing.expectEqual(Input.Event.Kind.text, ev.in.events[0].kind);

    // The owner lists its targets.
    _ = b.send(wire.convert_selection_size, wire.convertSelection, .{ wb.id, b.atoms.CLIPBOARD, b.atoms.TARGETS, b.atoms.LCGR_PASTE });
    for (0..2000) |_| {
        _ = wa.poll(&ev);
        try b.pump();
        if (wb.paste_ready) break;
        b.waitReadable(0.005);
    } else return error.TargetsNeverArrived;
    wb.paste_ready = false;
    const r = try b.reply(b.send(wire.get_property_size, wire.getProperty, .{ wb.id, b.atoms.LCGR_PASTE, true, 16 }));
    try testing.expectEqual(@as(u32, atom_atom), wire.get(u32, r, 8));
    const want = [_]u32{ b.atoms.TARGETS, b.atoms.UTF8_STRING, atom_string, b.atoms.TEXT };
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&want), r[32..][0..16]);

    // Another client takes the clipboard: the first no longer answers for it.
    wb.apply(&.{ .clipboard = "theirs" });
    for (0..2000) |_| {
        _ = wa.poll(&ev);
        if (a.clip_owner == 0) break;
        a.waitReadable(0.005);
    } else return error.ClearNeverArrived;
    wa.requestPaste();
    for (0..2000) |_| {
        try testing.expect(wb.poll(&ev));
        try testing.expect(wa.poll(&ev));
        if (ev.in.text.len > 0) break;
        a.waitReadable(0.005);
    } else return error.PasteNeverArrived;
    try testing.expectEqualStrings("theirs", ev.in.text);
}

/// An input method server for the IME test, on a connection of its own: the server side of
/// the XIM transport and the messages a client sends. Typing k twice composes, Space commits
/// "日本" (as COMPOUND_TEXT with a UTF-8 segment), every other key comes back unused.
const FakeIme = struct {
    conn: *Connection,
    /// The selection window, and the window for this client.
    owner: u32,
    window: u32 = 0,
    /// How it talks to the client: `Ime.imeSend` with the client's window as the far end.
    to: Ime = .{},
    major: u32,
    in: [4096]u8 = undefined,
    in_len: usize = 0,
    focused: bool = false,
    spot: [2]i16 = .{ -1, -1 },
    composing: u32 = 0,
    sync_replies: u32 = 0,
    ics: u32 = 0,
    /// ClientMessages that arrived while waiting for a reply, handled next.
    queue: [64][32]u8 = undefined,
    queued: usize = 0,

    const im = 3;
    const ic = 9;

    fn start(f: *FakeIme, display: []const u8, name: []const u8) !void {
        const c = f.conn;
        try c.open(display, "");
        f.owner = c.id();
        _ = c.send(wire.create_window_size, wire.createWindow, .{ f.owner, c.setup.root, 1, 1, 0 });
        var buf: [64]u8 = undefined;
        const server = try std.fmt.bufPrint(&buf, "@server={s}", .{name});
        const atom = wire.get(u32, try c.reply(c.send(wire.internAtomSize(server), wire.internAtom, .{server})), 8);
        _ = c.send(wire.set_selection_owner_size, wire.setSelectionOwner, .{ f.owner, atom });
        try f.to.init(c, "");
        try c.sync();
    }

    /// Handles what the client sent so far.
    fn step(f: *FakeIme) !void {
        const c = f.conn;
        try c.flush();
        var p = [_]linux.pollfd{.{ .fd = c.fd, .events = linux.POLL.IN }};
        if (linux.poll(&p, 1, 0) == 1) try c.readSome();
        while (try c.message()) |m| f.keep(m);
        var i: usize = 0;
        while (i < f.queued) : (i += 1) {
            const m: []const u8 = &f.queue[i];
            const a = c.atoms;
            const kind = wire.get(u32, m, 8);
            if (kind == a._XIM_XCONNECT) {
                f.window = c.id();
                _ = c.send(wire.create_window_size, wire.createWindow, .{ f.window, c.setup.root, 1, 1, 0 });
                f.to.server = wire.get(u32, m, 12);
                f.to.major = f.major;
                const l = [5]u32{ f.window, f.major, 0, 20, 0 };
                const e = wire.clientMessage(f.to.server, a._XIM_XCONNECT, 32, std.mem.asBytes(&l));
                _ = c.send(wire.send_event_size, wire.sendEvent, .{ f.to.server, 0, &e });
            } else if (kind == a._XIM_MOREDATA or (kind == a._XIM_PROTOCOL and m[1] == 8)) {
                @memcpy(f.in[f.in_len..][0..20], m[12..32]);
                f.in_len += 20;
                if (kind == a._XIM_PROTOCOL) try f.message();
            } else if (kind == a._XIM_PROTOCOL) {
                // Connection.reply would drop the ClientMessages that come meanwhile; keep them.
                const len = wire.get(u32, m, 12);
                const seq = c.send(wire.get_property_size, wire.getProperty, .{ f.window, wire.get(u32, m, 16), true, (len + 3) / 4 });
                try c.flush();
                const r = while (true) {
                    const got = try c.message() orelse {
                        try c.readSome();
                        continue;
                    };
                    if (got[0] == wire.reply and wire.get(u16, got, 2) == seq) break got;
                    f.keep(got);
                };
                const n = wire.get(u32, r, 16);
                @memcpy(f.in[0..n], r[32..][0..n]);
                f.in_len = n;
                try f.message();
            }
        }
        f.queued = 0;
        try c.flush();
    }

    fn keep(f: *FakeIme, m: []const u8) void {
        if ((m[0] & 0x7f) != wire.client_message) return;
        std.debug.assert(f.queued < f.queue.len);
        f.queue[f.queued] = m[0..32].*;
        f.queued += 1;
    }

    fn message(f: *FakeIme) !void {
        defer f.in_len = 0;
        const msg = f.in[0..xim.size(&f.in)];
        var out: [256]u8 = undefined;
        var b: wire.Buf = .{ .bytes = &out };
        switch (msg[0]) {
            xim.op.connect => {
                try testing.expectEqual(@as(u8, 'l'), msg[4]);
                head(&b, xim.op.connect_reply, 4);
                b.int(u16, 1);
                b.int(u16, 0);
            },
            xim.op.open => {
                try testing.expectEqualStrings("en_US", msg[5..][0..msg[4]]);
                const ic_attrs = [_][]const u8{ "inputStyle", "clientWindow", "focusWindow", "preeditAttributes", "spotLocation", "separatorofNestedList" };
                var n: usize = 0;
                for (ic_attrs) |a| n += 6 + a.len + wire.pad4(2 + a.len);
                head(&b, xim.op.open_reply, 8 + n);
                b.int(u16, im);
                b.int(u16, 0); // no IM attributes
                b.int(u16, @intCast(n));
                b.zeros(2);
                for (ic_attrs, 0..) |a, id| {
                    b.int(u16, @intCast(id));
                    b.int(u16, 3);
                    b.int(u16, @intCast(a.len));
                    @memcpy(out[b.len..][0..a.len], a);
                    b.len += a.len;
                    b.zeros(wire.pad4(2 + a.len));
                }
                f.send(out[0..b.len]);
                b.len = 0;
                // Static event flow: forward key presses and releases.
                head(&b, xim.op.set_event_mask, 12);
                b.int(u16, im);
                b.int(u16, 0);
                b.int(u32, 3);
                b.int(u32, 0);
            },
            xim.op.encoding_negotiation => {
                head(&b, xim.op.encoding_negotiation_reply, 8);
                b.int(u16, im);
                b.int(u16, 0);
                b.int(i16, 0);
                b.zeros(2);
            },
            xim.op.create_ic => {
                f.ics += 1;
                // inputStyle, clientWindow, focusWindow, then preeditAttributes holding the spot.
                try testing.expectEqual(@as(u32, xim.style_preedit_position | xim.style_status_nothing), wire.get(u32, msg, 12));
                f.spot = .{ wire.get(i16, msg, 40), wire.get(i16, msg, 42) };
                head(&b, xim.op.create_ic_reply, 4);
                b.int(u16, im);
                b.int(u16, ic);
            },
            xim.op.set_ic_values => {
                f.spot = .{ wire.get(i16, msg, 20), wire.get(i16, msg, 22) };
                head(&b, xim.op.set_ic_values_reply, 4);
                b.int(u16, im);
                b.int(u16, ic);
            },
            xim.op.set_ic_focus => f.focused = true,
            xim.op.unset_ic_focus => f.focused = false,
            xim.op.sync_reply => f.sync_replies += 1,
            xim.op.forward_event => {
                const ev = msg[12..44];
                const press = (ev[0] & 0x7f) == wire.key_press;
                const code = keys.hid(ev[1]);
                const eaten = code == 0x0e or (code == 0x2c and (f.composing > 0 or !press));
                if (eaten) {
                    // k composes; Space commits what was composed. Releases of both are eaten.
                    if (!press) return;
                    if (code == 0x0e) {
                        f.composing += 1;
                        return;
                    }
                    f.composing = 0;
                    const ct = "\x1b%G\xe6\x97\xa5\xe6\x9c\xac\x1b%@";
                    head(&b, xim.op.commit, 8 + ct.len + wire.pad4(ct.len));
                    b.int(u16, im);
                    b.int(u16, ic);
                    b.int(u16, xim.Commit.synchronous | 2);
                    b.int(u16, ct.len);
                    b.str(ct);
                } else {
                    // Not used: back to the client, which must answer the synchronous flag.
                    head(&b, xim.op.forward_event, 40);
                    b.int(u16, im);
                    b.int(u16, ic);
                    b.int(u16, 1);
                    b.int(u16, 0);
                    @memcpy(out[b.len..][0..32], ev);
                    b.len += 32;
                }
            },
            else => {},
        }
        if (b.len > 0) f.send(out[0..b.len]);
    }

    fn head(b: *wire.Buf, major: u8, body: usize) void {
        b.int(u8, major);
        b.int(u8, 0);
        b.int(u16, @intCast(body / 4));
    }

    fn send(f: *FakeIme, msg: []const u8) void {
        f.conn.imeSend(&f.to, msg);
    }
};

test "x11: IME over XIM: compose, commit, keys it does not use, spot and focus" {
    const display = try testDisplay();
    // Major 0 carries messages in ClientMessages only; 2 in properties.
    for ([_]u32{ 0, 2 }) |major| {
        const S = struct {
            var server: Connection = .{};
        };
        var fake: FakeIme = .{ .conn = &S.server, .owner = 0, .major = major };
        try fake.start(display, "lcgrtest");
        defer S.server.close();

        const c = &Fixture.conn;
        try c.open(display, "");
        defer c.close();
        const xtest = try c.extension("XTEST");
        var w: Window = undefined;
        try w.open(c, 200, 100, "ime", Fixture.buffers);
        defer w.close();
        _ = c.send(wire.set_input_focus_size, wire.setInputFocus, .{w.id});
        try testing.expectError(error.NoInputMethod, c.openIme("nosuchim", "en_US"));
        try c.openIme("lcgrtest", "en_US");

        var ev: Events = .{};
        const Until = struct {
            fn run(cw: *Window, f: *FakeIme, e: *Events, comptime cond: fn (*Window, *FakeIme, *Events) bool) !void {
                for (0..2000) |_| {
                    try f.step();
                    try testing.expect(cw.poll(e));
                    if (cond(cw, f, e)) return;
                    cw.conn.waitReadable(0.002);
                }
                return error.ImeNeverAnswered;
            }
        };
        try Until.run(&w, &fake, &ev, struct {
            fn f(cw: *Window, _: *FakeIme, _: *Events) bool {
                return cw.conn.ime.state == .ready;
            }
        }.f);
        try testing.expectEqual(@as(u32, 3), c.ime.forward_mask);

        // A frame asks for text with the caret at (10, 20)..(12, 40): the IC is made, focused,
        // and its spot is the caret's bottom left.
        w.apply(&.{ .wants_text = true, .ime_rect = .{ .x0 = 10, .y0 = 20, .x1 = 12, .y1 = 40 } });
        try Until.run(&w, &fake, &ev, struct {
            fn f(cw: *Window, fk: *FakeIme, _: *Events) bool {
                return cw.ime_on and fk.focused;
            }
        }.f);
        try testing.expectEqual([2]i16{ 10, 40 }, fake.spot);

        // k k Space a: the first three are the input method's, "日本" is committed, a comes back.
        for ([_]u8{ 0x0e, 0x0e, 0x2c, 0x04 }) |code| {
            for ([_]u8{ wire.key_press, wire.key_release }) |kind|
                _ = c.send(wire.fake_input_size, wire.fakeInput, .{ xtest, kind, keys.keycodeOf(code), c.setup.root, 0, 0 });
        }
        try c.flush();
        var events: [16]Input.Event = undefined;
        var n: usize = 0;
        var text: [64]u8 = undefined;
        var n_text: usize = 0;
        for (0..2000) |_| {
            try fake.step();
            try testing.expect(w.poll(&ev));
            for (ev.in.events) |e| {
                var copy = e;
                if (e.kind == .text) {
                    copy.at = @intCast(n_text);
                    @memcpy(text[n_text..][0..e.len], ev.in.typed(e));
                    n_text += e.len;
                }
                events[n] = copy;
                n += 1;
            }
            if (n > 0 and events[n - 1].kind == .release and events[n - 1].code == 0x04) break;
            c.waitReadable(0.002);
        } else return error.ImeNeverAnswered;
        try testing.expectEqualStrings("\xe6\x97\xa5\xe6\x9c\xaca", text[0..n_text]);
        try testing.expectEqualSlices(Input.Event, &.{
            .{ .kind = .text, .at = 0, .len = 6 },
            .{ .kind = .press, .code = 0x04 },
            .{ .kind = .text, .at = 6, .len = 1 },
            .{ .kind = .release, .code = 0x04 },
        }, events[0..n]);
        // The commit and the two returned events were synchronous; each was answered.
        try Until.run(&w, &fake, &ev, struct {
            fn f(_: *Window, fk: *FakeIme, _: *Events) bool {
                return fk.sync_replies >= 3;
            }
        }.f);
        try testing.expectEqual(@as(u32, 3), fake.sync_replies);

        // The caret moves; then no widget wants text and keys stay here.
        w.apply(&.{ .wants_text = true, .ime_rect = .{ .x0 = 30, .y0 = 20, .x1 = 32, .y1 = 40 } });
        try Until.run(&w, &fake, &ev, struct {
            fn f(_: *Window, fk: *FakeIme, _: *Events) bool {
                return fk.spot[0] == 30;
            }
        }.f);
        w.apply(&.{});
        try Until.run(&w, &fake, &ev, struct {
            fn f(_: *Window, fk: *FakeIme, _: *Events) bool {
                return !fk.focused;
            }
        }.f);
        _ = c.send(wire.fake_input_size, wire.fakeInput, .{ xtest, wire.key_press, keys.keycodeOf(0x0e), c.setup.root, 0, 0 });
        _ = c.send(wire.fake_input_size, wire.fakeInput, .{ xtest, wire.key_release, keys.keycodeOf(0x0e), c.setup.root, 0, 0 });
        try Until.run(&w, &fake, &ev, struct {
            fn f(_: *Window, _: *FakeIme, e: *Events) bool {
                return std.mem.eql(u8, e.in.text, "k");
            }
        }.f);
        try testing.expectEqual(@as(u32, 1), fake.ics);
        try testing.expectEqual(@as(u32, 0), fake.composing);
        try testing.expectEqual(@as(u32, 0), c.errors);
        try testing.expectEqual(@as(u32, 0), S.server.errors);
    }
}
