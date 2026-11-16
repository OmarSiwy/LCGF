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
    TooManyWindows,
} || wire.Setup.Error;

/// Atoms the shell uses, interned at `open`. Field names are the atom names.
pub const Atoms = struct {
    WM_PROTOCOLS: u32 = 0,
    WM_DELETE_WINDOW: u32 = 0,
    _NET_WM_NAME: u32 = 0,
    UTF8_STRING: u32 = 0,
};

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
        const target = wire.eventWindow(m);
        for (c.windows) |slot| {
            const w = slot orelse continue;
            if (w.id == target) w.handle(m);
        }
    }

    /// Major opcode of extension `name`.
    pub fn extension(c: *Connection, name: []const u8) Error!u8 {
        const r = try c.reply(c.send(wire.queryExtensionSize(name), wire.queryExtension, .{name}));
        if (r[8] == 0) return error.NoExtension;
        return r[9];
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
    polls: u32 = 0,
    presents: u32 = 0,

    const PerFrame = struct {
        wheel: [2]f32 = .{ 0, 0 },
        /// Typed UTF-8 and key events, in order. A frame that overflows them drops the rest.
        text: [256]u8 = undefined,
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
            if (f.text.len - f.text_len < n or f.events_len == f.events.len) return;
            @memcpy(f.text[f.text_len..][0..n], utf8[0..n]);
            f.add(.{ .kind = .text, .at = f.text_len, .len = n });
            f.text_len += n;
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
        w.held.viewport = .{ @floatFromInt(width), @floatFromInt(height) };
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
            wire.key_press, wire.key_release => w.key(m),
            wire.focus_out => {
                // Keys released while another window has the focus never reach this one.
                in.keys = .{};
                in.mods = .{};
            },
            wire.expose => w.damaged = true,
            wire.destroy_notify => w.is_open = false,
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

    /// Handles the server's pending events and gives this window's frame. False once the window
    /// was closed (by the user through the window manager, or `close`) or the connection failed
    /// (`conn.err`).
    pub fn poll(w: *Window, ev: *Events) bool {
        const c = w.conn;
        c.pump() catch return false;
        if (!w.is_open) return false;
        if (w.damaged and w.presented) w.send() catch return false;
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

    pub fn apply(w: *Window, p: *const Platform) void {
        w.applied = p.*;
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
