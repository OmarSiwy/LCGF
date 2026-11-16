//! The Wayland shell: a window on a Wayland compositor, speaking the wire protocol over the
//! socket itself (src/shell/wayland/wire.zig), so no libwayland is linked or loaded. It meets
//! the contract of src/shell/iface.zig: `poll` drains the socket without blocking and turns
//! what arrived into `Events`, `present` draws the frame with the software back end into shared
//! memory (`wl_shm`) and commits it, `wait` sleeps in poll(2) on the socket and an eventfd, and
//! `wake` writes that eventfd.
//!
//! Start-up is event-driven, so no call blocks on the compositor: `init` asks for the globals
//! and a `sync`; when the sync is done the needed globals are bound and the toplevel is created
//! and committed without a buffer; the first `xdg_surface.configure` makes the window ready
//! (`configured`) and `present` draws from then on. `connect` is the blocking shortcut for a
//! program: it waits until that first configure.
//!
//! Lessons from Zed's GPUI on Wayland (README, commit af8ea0d): ack every configure before the
//! next commit, never attach a buffer before the first configure, and answer `xdg_wm_base.ping`
//! or the compositor marks the window unresponsive.
//!
//! Linux only (sockets, memfd, eventfd). Built as its own module over `lcgr` (`zig build
//! wayland`), not exported from src/lcgr.zig, like the GL ES back end.

const std = @import("std");
const builtin = @import("builtin");
const lcgr = @import("lcgr");
const wire = @import("wire.zig");
const Seat = @import("input.zig").Seat;
const Data = @import("data.zig").Data;
const Ime = @import("ime.zig").Ime;
const linux = std.os.linux;
const iface = lcgr.shell_iface;
const Events = iface.Events;
const context = lcgr.context;
const Platform = context.Platform;
const Output = context.Output;
const Pace = lcgr.scheduler.Pace;
const Input = lcgr.input.Input;
const Quad = lcgr.draw_list.Quad;
const Mono = lcgr.protocol.Mono;
const render = lcgr.render_iface;
const sw = lcgr.render_sw;
const Color = lcgr.types.Color;

/// Object ids the client allocates are below this; the compositor's start at 0xff000000.
pub const max_objects = 256;

/// What each client object id is, so an event can be routed by its target id.
pub const Kind = enum(u8) {
    free,
    /// Destroyed by the client; its id is reusable once the compositor sends `delete_id`.
    dead,
    display,
    registry,
    /// The start-up `wl_display.sync`.
    sync,
    frame,
    compositor,
    shm,
    shm_pool,
    buffer,
    wm_base,
    surface,
    xdg_surface,
    toplevel,
    seat,
    pointer,
    keyboard,
    touch,
    viewporter,
    viewport,
    fractional_manager,
    fractional_scale,
    output,
    cursor_manager,
    cursor_device,
    data_manager,
    data_device,
    data_source,
    text_input_manager,
    text_input,
};

/// Interfaces bound from the registry, with the highest version this client speaks.
const Global = enum { wl_compositor, wl_shm, xdg_wm_base, wl_seat, wp_viewporter, wp_fractional_scale_manager_v1, wp_cursor_shape_manager_v1, wl_data_device_manager, zwp_text_input_manager_v3 };
const global_versions = std.enums.EnumArray(Global, u32).init(.{
    .wl_compositor = 6,
    .wl_shm = 1,
    .xdg_wm_base = 2,
    .wl_seat = 8,
    .wp_viewporter = 1,
    .wp_fractional_scale_manager_v1 = 1,
    .wp_cursor_shape_manager_v1 = 1,
    .wl_data_device_manager = 3,
    .zwp_text_input_manager_v3 = 1,
});
const global_kinds = std.enums.EnumArray(Global, Kind).init(.{
    .wl_compositor = .compositor,
    .wl_shm = .shm,
    .xdg_wm_base = .wm_base,
    .wl_seat = .seat,
    .wp_viewporter = .viewporter,
    .wp_fractional_scale_manager_v1 = .fractional_manager,
    .wp_cursor_shape_manager_v1 = .cursor_manager,
    .wl_data_device_manager = .data_manager,
    .zwp_text_input_manager_v3 = .text_input_manager,
});

/// `wp_cursor_shape_device_v1` shapes (cursor-shape-v1.xml) by `Cursor`: default, pointer,
/// text, grab, ew-resize, ns-resize.
const cursor_shapes = std.enums.EnumArray(context.Cursor, u32).init(.{ .arrow = 1, .pointer = 4, .text = 9, .grab = 16, .resize_h = 26, .resize_v = 27 });

/// Opcodes used, from wayland.xml and xdg-shell.xml.
const op = struct {
    const display_sync = 0;
    const display_get_registry = 1;
    const registry_bind = 0;
    const compositor_create_surface = 0;
    const shm_create_pool = 0;
    const pool_create_buffer = 0;
    const pool_destroy = 1;
    const buffer_destroy = 0;
    const surface_attach = 1;
    const surface_frame = 3;
    const surface_commit = 6;
    const surface_set_buffer_scale = 8;
    const surface_damage_buffer = 9;
    const viewporter_get_viewport = 1;
    const viewport_set_destination = 2;
    const fractional_get_fractional_scale = 1;
    const cursor_manager_get_pointer = 1;
    const cursor_device_set_shape = 1;
    const wm_base_get_xdg_surface = 2;
    const wm_base_pong = 3;
    const xdg_surface_get_toplevel = 1;
    const xdg_surface_ack_configure = 4;
    const toplevel_set_title = 2;
    const toplevel_set_app_id = 3;
    const seat_get_pointer = 0;
    const seat_get_keyboard = 1;
    const seat_get_touch = 2;
};

/// `wl_shm` format: 32-bit ARGB, premultiplied, as one little-endian word: `sw`'s `.bgra8`.
const argb8888 = 0;

pub const Wayland = struct {
    conn: wire.Conn,
    kinds: [max_objects]Kind = @splat(.free),
    /// Bound globals by interface; 0 when the compositor has none.
    globals: std.enums.EnumArray(Global, u32) = .initFill(0),
    registry: u32 = 0,
    sync: u32 = 0,
    surface: u32 = 0,
    xdg_surface: u32 = 0,
    toplevel: u32 = 0,
    /// Set when the compositor scales fractionally (wp_viewporter and wp_fractional_scale_v1).
    viewport: u32 = 0,
    /// The compositor sends wl_surface.preferred_buffer_scale, so outputs are not consulted.
    preferred: bool = false,
    outputs: [8]struct { id: u32, scale: i32 = 1, on: bool = false } = undefined,
    nout: u32 = 0,
    /// The first configure arrived: `present` may attach buffers.
    configured: bool = false,
    /// The compositor asked to close the window, or the connection failed (`err`).
    closed: bool = false,
    err: ?Error = null,
    /// Size from the last `xdg_toplevel.configure` not yet acked; 0 lets the client choose.
    pending: [2]i32 = .{ 0, 0 },
    /// Window size in logical pixels.
    size: [2]f32,
    /// Physical pixels per logical pixel.
    scale: f32 = 1,
    shm: Shm = .{},
    /// Held input, carried from frame to frame.
    in: Input = .{},
    seat: Seat = .{},
    /// Clipboard (data.zig).
    data: Data = .{},
    /// Input method (ime.zig).
    ime: Ime = .{},
    /// The cursor last set, and the pointer enter it was set for.
    cursor: context.Cursor = .arrow,
    cursor_serial: u32 = 0,
    cursor_device: u32 = 0,
    /// Clock of `Input.time`: the first poll is time 0.
    t0: ?linux.timespec = null,
    /// Wakes `wait` from another thread (`wake`).
    wake_fd: i32,
    woken: std.atomic.Value(bool) = .init(false),
    options: Options,
    gfx: sw.Software = .{},
    font: Mono = .{},
    glyphs: Buffers,
    /// What `present` clears to before drawing.
    background: Color = .rgb(0, 0, 0),
    polls: u32 = 0,
    presents: u32 = 0,
    /// Frames `present` could not show because the compositor still held both buffers.
    dropped: u32 = 0,

    pub const Error = error{ Disconnected, Protocol, MissingGlobal, OutOfIds, OutOfMemory };

    pub const Options = struct {
        title: []const u8 = "lcgr",
        app_id: []const u8 = "lcgr",
        /// Logical size until the compositor picks one.
        size: [2]f32 = .{ 800, 600 },
    };

    /// Caller-owned storage for drawing text: one quad per byte of text in a frame, and one
    /// `first` and `count` row per text run (as src/shell/headless.zig).
    pub const Buffers = struct {
        glyphs: []Quad,
        first: []u32,
        count: []u32,
    };

    /// A shell on the connected socket `fd` (`wire.connect`), which it then owns. Sends the
    /// start-up requests; the window appears through the events `poll` handles.
    pub fn init(fd: i32, options: Options, buf: Buffers) Wayland {
        var w: Wayland = .{
            .conn = .{ .fd = fd },
            .size = options.size,
            .options = options,
            .glyphs = buf,
            .wake_fd = @intCast(@as(isize, @bitCast(linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK)))),
        };
        w.kinds[1] = .display;
        w.registry = w.new(.registry);
        w.request(1, op.display_get_registry, .{w.registry});
        w.sync = w.new(.sync);
        w.request(1, op.display_sync, .{w.sync});
        w.flush();
        return w;
    }

    /// `init`, then poll and wait until the window is configured (or fails). For a program
    /// that has nothing else to do meanwhile.
    pub fn connect(fd: i32, options: Options, buf: Buffers) Error!Wayland {
        var w = init(fd, options, buf);
        while (!w.configured and !w.closed) {
            w.dispatch();
            if (!w.configured and !w.closed) w.sleep(-1);
        }
        if (w.err) |e| return e;
        return w;
    }

    pub fn deinit(w: *Wayland) void {
        w.shm.unmap();
        w.data.deinit();
        w.conn.close();
        _ = linux.close(w.wake_fd);
    }

    /// Drains the socket into `ev`. False once the window is closed or the connection failed.
    pub fn poll(w: *Wayland, ev: *Events) bool {
        w.dispatch();
        w.data.bind(w);
        w.ime.bind(w);
        w.data.readPaste(w);
        w.flush();
        _ = w.woken.swap(false, .acquire);
        w.drainWake();
        w.polls += 1;
        w.in.viewport = w.size;
        w.in.scale = w.scale;
        const now = monotonic();
        const t = elapsed(w.t0 orelse now, now);
        if (w.t0 == null) w.t0 = now;
        w.in.dt = @floatCast(t - w.in.time);
        w.in.time = t;
        w.seat.fill(&w.in);
        ev.in = w.in;
        ev.composition = w.ime.composition();
        return !w.closed;
    }

    /// Applies the frame's cursor through wp_cursor_shape_v1. A shape holds only while the
    /// pointer stays in the window, so it is sent again after each enter.
    pub fn apply(w: *Wayland, p: *const Platform) void {
        const s = &w.seat;
        if (w.cursor_device == 0 and s.pointer != 0 and w.globals.get(.wp_cursor_shape_manager_v1) != 0) {
            w.cursor_device = w.new(.cursor_device);
            w.request(w.globals.get(.wp_cursor_shape_manager_v1), op.cursor_manager_get_pointer, .{ w.cursor_device, s.pointer });
        }
        if (s.pointer_focus != 0 and (p.cursor != w.cursor or s.enter_serial != w.cursor_serial)) {
            w.request(w.cursor_device, op.cursor_device_set_shape, .{ s.enter_serial, cursor_shapes.get(p.cursor) });
            w.cursor = p.cursor;
            w.cursor_serial = s.enter_serial;
        }
        w.data.set(w, p.clipboard);
        w.ime.apply(w, p.wants_text, p.ime_rect);
        w.flush();
    }

    /// Asks for the clipboard's text, which arrives as typed text (`Input.text` and a `.text`
    /// event) in a later poll. The host calls it when a widget asks to paste
    /// (`keyboard.Clipboard.paste`): `Platform` carries no paste request. False when the
    /// clipboard holds no text.
    pub fn paste(w: *Wayland) bool {
        const ok = w.data.paste(w);
        w.flush();
        return ok;
    }

    /// Draws the frame into a free shared-memory buffer and commits it. Before the first
    /// configure there is nothing to draw into yet, so the frame is skipped.
    pub fn present(w: *Wayland, out: *const Output) void {
        if (!w.configured or w.closed) return;
        const px = physical(w.size, w.scale);
        if (px[0] != w.shm.width or px[1] != w.shm.height) w.resizeBuffers(px) catch |e| return w.fail(e);
        const slot = for (0..2) |k| {
            if (!w.shm.busy[k]) break k;
        } else {
            w.dropped += 1;
            return;
        };
        var fb = w.shm.framebuffer(slot);
        const g = w.glyphs;
        const n = w.font.quads(out.draw, g.glyphs, .{ .first = g.first, .count = g.count });
        w.gfx.prepare({}, out.draw, .{ .quads = g.glyphs[0..n], .first = g.first, .count = g.count }, .{ 0, 0 }, w.scale);
        fb.clear(w.background);
        render.render(&w.gfx, .{ .fb = &fb, .scissor = fb.all() }, out.draw);
        w.shm.busy[slot] = true;
        w.request(w.surface, op.surface_attach, .{ w.shm.buffers[slot], @as(i32, 0), @as(i32, 0) });
        // Fractional scale draws `px` pixels and has the compositor show them at the logical
        // size; the integer fallback (wl_surface.preferred_buffer_scale) tells it the factor.
        if (w.viewport != 0) {
            w.request(w.viewport, op.viewport_set_destination, .{ @as(i32, @intFromFloat(w.size[0])), @as(i32, @intFromFloat(w.size[1])) });
        } else {
            w.request(w.surface, op.surface_set_buffer_scale, .{@as(i32, @intFromFloat(w.scale))});
        }
        w.request(w.surface, op.surface_damage_buffer, .{ @as(i32, 0), @as(i32, 0), @as(i32, @intCast(px[0])), @as(i32, @intCast(px[1])) });
        w.request(w.surface, op.surface_commit, .{});
        w.flush();
        w.presents += 1;
    }

    /// Sleeps until the compositor sends something, `wake` is called, or `seconds` pass.
    pub fn wait(w: *Wayland, seconds: f32, pace: Pace) void {
        _ = pace;
        w.flush();
        if (w.closed or w.woken.load(.acquire)) return;
        const ms: i32 = if (seconds >= 2_000_000) -1 else @intFromFloat(@ceil(@max(seconds, 0) * 1000));
        w.sleep(ms);
    }

    /// Thread-safe: ends a `wait` in progress and has the next `poll` report a frame.
    pub fn wake(w: *Wayland) void {
        w.woken.store(true, .release);
        const one: u64 = 1;
        _ = linux.write(w.wake_fd, std.mem.asBytes(&one), 8);
    }

    fn sleep(w: *Wayland, ms: i32) void {
        var fds = [3]linux.pollfd{
            .{ .fd = w.conn.fd, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = w.wake_fd, .events = linux.POLL.IN, .revents = 0 },
            // A paste in progress (poll ignores -1).
            .{ .fd = w.data.paste_fd, .events = linux.POLL.IN, .revents = 0 },
        };
        _ = linux.poll(&fds, fds.len, ms);
    }

    fn drainWake(w: *Wayland) void {
        var v: u64 = 0;
        _ = linux.read(w.wake_fd, std.mem.asBytes(&v), 8);
    }

    /// Reads and handles everything the compositor has sent, then sends what that produced.
    pub fn dispatch(w: *Wayland) void {
        w.seat.begin();
        while (!w.closed) {
            const more = w.conn.fill() catch |e| return w.fail(if (e == error.Overflow) error.Protocol else error.Disconnected);
            while (w.conn.next()) |m| w.handle(m);
            if (!more) break;
        }
        w.flush();
    }

    fn handle(w: *Wayland, m: wire.Msg) void {
        var a = m.args();
        // Objects the compositor created (from 0xff000000) are data offers.
        if (m.id >= max_objects) return w.data.offerEvent(m.id, m.opcode, &a);
        const kind = w.kinds[m.id];
        switch (kind) {
            .display => switch (m.opcode) {
                0 => w.fail(error.Protocol), // error: object, code, message
                1 => { // delete_id
                    const id = a.uint();
                    if (id < max_objects) w.kinds[id] = .free;
                },
                else => {},
            },
            .registry => if (m.opcode == 0) {
                const name = a.uint();
                const interface = a.string();
                const version = a.uint();
                // Every output, for the integer scale of compositors before wl_surface v6.
                if (std.mem.eql(u8, interface, "wl_output") and version >= 2 and w.nout < w.outputs.len) {
                    const id = w.new(.output);
                    w.request(w.registry, op.registry_bind, .{ name, interface, @as(u32, 2), id });
                    w.outputs[w.nout] = .{ .id = id };
                    w.nout += 1;
                    return;
                }
                const g = std.meta.stringToEnum(Global, interface) orelse return;
                const id = w.new(global_kinds.get(g));
                w.request(w.registry, op.registry_bind, .{ name, interface, @min(version, global_versions.get(g)), id });
                w.globals.set(g, id);
            },
            .sync => if (m.opcode == 0) {
                w.kinds[m.id] = .dead;
                w.createWindow();
            },
            .wm_base => if (m.opcode == 0) w.request(m.id, op.wm_base_pong, .{a.uint()}),
            .xdg_surface => if (m.opcode == 0) {
                w.request(m.id, op.xdg_surface_ack_configure, .{a.uint()});
                if (w.pending[0] > 0 and w.pending[1] > 0) w.size = .{ @floatFromInt(w.pending[0]), @floatFromInt(w.pending[1]) };
                w.configured = true;
            },
            .toplevel => switch (m.opcode) {
                0 => w.pending = .{ a.int(), a.int() }, // configure: width, height, states
                1 => w.closed = true,
                else => {},
            },
            .buffer => if (m.opcode == 0) { // release
                for (0..2) |k| w.shm.busy[k] = w.shm.busy[k] and w.shm.buffers[k] != m.id;
            },
            .seat => if (m.opcode == 0) { // capabilities: pointer 1, keyboard 2, touch 4
                const caps = a.uint();
                const want = [3]struct { u32, *u32, Kind, u16 }{
                    .{ 1, &w.seat.pointer, .pointer, op.seat_get_pointer },
                    .{ 2, &w.seat.keyboard, .keyboard, op.seat_get_keyboard },
                    .{ 4, &w.seat.touch, .touch, op.seat_get_touch },
                };
                // ponytail: a device that goes away keeps its object; release it if a seat
                // that loses and regains devices ever matters.
                for (want) |d| if (caps & d[0] != 0 and d[1].* == 0) {
                    d[1].* = w.new(d[2]);
                    w.request(m.id, d[3], .{d[1].*});
                };
            },
            .pointer => w.seat.pointerEvent(m.opcode, &a),
            .keyboard => w.seat.keyboardEvent(m.opcode, &a, &w.conn),
            .touch => w.seat.touchEvent(m.opcode, &a),
            // preferred_buffer_scale: the integer scale, used without fractional scaling.
            .surface => switch (m.opcode) {
                0, 1 => { // enter, leave: output
                    const id = a.uint();
                    for (w.outputs[0..w.nout]) |*o| o.on = if (o.id == id) m.opcode == 0 else o.on;
                    w.outputScale();
                },
                2 => { // preferred_buffer_scale
                    w.preferred = true;
                    if (w.viewport == 0) w.scale = @floatFromInt(@max(a.int(), 1));
                },
                else => {},
            },
            .output => if (m.opcode == 3) { // scale
                const id = m.id;
                const factor = a.int();
                for (w.outputs[0..w.nout]) |*o| o.scale = if (o.id == id) @max(factor, 1) else o.scale;
                w.outputScale();
            },
            // preferred_scale: the scale times 120.
            .fractional_scale => if (m.opcode == 0) {
                w.scale = @as(f32, @floatFromInt(@max(a.uint(), 1))) / 120;
            },
            .data_device => w.data.deviceEvent(w, m.opcode, &a),
            .data_source => w.data.sourceEvent(w, m.opcode, &a),
            .text_input => w.ime.event(w, m.opcode, &a),
            .frame => if (m.opcode == 0) {
                w.kinds[m.id] = .dead;
            },
            else => {},
        }
    }

    /// Without fractional scaling or wl_surface v6: the largest scale of the outputs the
    /// window is on, as before preferred_buffer_scale existed.
    fn outputScale(w: *Wayland) void {
        if (w.viewport != 0 or w.preferred) return;
        var scale: i32 = 1;
        for (w.outputs[0..w.nout]) |o| scale = if (o.on) @max(scale, o.scale) else scale;
        w.scale = @floatFromInt(scale);
    }

    /// After the start-up sync: every global is known, so create the window.
    fn createWindow(w: *Wayland) void {
        inline for (.{ .wl_compositor, .wl_shm, .xdg_wm_base }) |g| {
            if (w.globals.get(g) == 0) return w.fail(error.MissingGlobal);
        }
        w.surface = w.new(.surface);
        w.request(w.globals.get(.wl_compositor), op.compositor_create_surface, .{w.surface});
        w.xdg_surface = w.new(.xdg_surface);
        w.request(w.globals.get(.xdg_wm_base), op.wm_base_get_xdg_surface, .{ w.xdg_surface, w.surface });
        w.toplevel = w.new(.toplevel);
        w.request(w.xdg_surface, op.xdg_surface_get_toplevel, .{w.toplevel});
        w.request(w.toplevel, op.toplevel_set_title, .{w.options.title});
        w.request(w.toplevel, op.toplevel_set_app_id, .{w.options.app_id});
        if (w.globals.get(.wp_viewporter) != 0 and w.globals.get(.wp_fractional_scale_manager_v1) != 0) {
            w.viewport = w.new(.viewport);
            w.request(w.globals.get(.wp_viewporter), op.viewporter_get_viewport, .{ w.viewport, w.surface });
            const frac = w.new(.fractional_scale);
            w.request(w.globals.get(.wp_fractional_scale_manager_v1), op.fractional_get_fractional_scale, .{ frac, w.surface });
        }
        w.request(w.surface, op.surface_commit, .{});
    }

    /// Two buffers of `px` pixels in one new pool, replacing the old ones. A buffer the
    /// compositor still holds is destroyed anyway: wl_buffer.destroy is allowed at any time and
    /// the compositor keeps showing its copy until the next commit.
    fn resizeBuffers(w: *Wayland, px: [2]u32) Error!void {
        for (w.shm.buffers) |b| if (b != 0) w.destroy(b, op.buffer_destroy);
        if (w.shm.pool != 0) w.destroy(w.shm.pool, op.pool_destroy);
        w.shm.unmap();
        w.shm = .{};
        const stride: u32 = @intCast(sw.Framebuffer.len(px[0], 1) * 4);
        const one = std.mem.alignForward(usize, @as(usize, stride) * px[1], 64);
        const fd_rc = linux.memfd_create("lcgr-wayland", linux.MFD.CLOEXEC);
        if (linux.errno(fd_rc) != .SUCCESS) return error.OutOfMemory;
        const fd: i32 = @intCast(fd_rc);
        if (linux.errno(linux.ftruncate(fd, @intCast(one * 2))) != .SUCCESS) {
            _ = linux.close(fd);
            return error.OutOfMemory;
        }
        const addr = linux.mmap(null, one * 2, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
        if (linux.errno(addr) != .SUCCESS) {
            _ = linux.close(fd);
            return error.OutOfMemory;
        }
        w.shm = .{ .map = @as([*]align(4096) u8, @ptrFromInt(addr))[0 .. one * 2], .width = px[0], .height = px[1], .stride = stride, .one = one };
        w.shm.pool = w.new(.shm_pool);
        w.request(w.globals.get(.wl_shm), op.shm_create_pool, .{ w.shm.pool, wire.Fd{ .fd = fd }, @as(i32, @intCast(one * 2)) });
        for (0..2) |k| {
            w.shm.buffers[k] = w.new(.buffer);
            w.request(w.shm.pool, op.pool_create_buffer, .{ w.shm.buffers[k], @as(i32, @intCast(one * k)), @as(i32, @intCast(px[0])), @as(i32, @intCast(px[1])), @as(i32, @intCast(stride)), @as(u32, argb8888) });
        }
    }

    /// A new client object id of `kind`: the lowest free one.
    pub fn new(w: *Wayland, kind: Kind) u32 {
        for (w.kinds[2..], 2..) |k, id| if (k == .free) {
            w.kinds[id] = kind;
            return @intCast(id);
        };
        w.fail(error.OutOfIds);
        return 0;
    }

    /// Sends a destructor request; the id is reused after the compositor's `delete_id`.
    pub fn destroy(w: *Wayland, id: u32, opcode: u16) void {
        w.request(id, opcode, .{});
        w.kinds[id] = .dead;
    }

    pub fn request(w: *Wayland, id: u32, opcode: u16, args: anytype) void {
        if (w.closed or id == 0) return;
        w.conn.send(id, opcode, args) catch w.fail(error.Disconnected);
    }

    fn flush(w: *Wayland) void {
        if (w.closed) return;
        w.conn.flush() catch w.fail(error.Disconnected);
    }

    fn fail(w: *Wayland, e: Error) void {
        if (w.err == null) w.err = e;
        w.closed = true;
    }
};

comptime {
    iface.check(Wayland);
}

/// The window's buffers in shared memory: two of `width` x `height`, `one` bytes apart.
const Shm = struct {
    map: []align(4096) u8 = &.{},
    pool: u32 = 0,
    buffers: [2]u32 = .{ 0, 0 },
    /// The compositor has the buffer and has not released it.
    busy: [2]bool = .{ false, false },
    width: u32 = 0,
    height: u32 = 0,
    stride: u32 = 0,
    one: usize = 0,

    fn framebuffer(s: *const Shm, slot: usize) sw.Framebuffer {
        const px: [*]u32 = @ptrCast(@alignCast(s.map[s.one * slot ..].ptr));
        return .init(px[0 .. s.one / 4], s.width, s.height, .bgra8);
    }
    fn unmap(s: *Shm) void {
        if (s.map.len > 0) _ = linux.munmap(s.map.ptr, s.map.len);
        s.map = &.{};
    }
};

fn monotonic() linux.timespec {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return ts;
}

fn elapsed(from: linux.timespec, to: linux.timespec) f64 {
    return @as(f64, @floatFromInt(to.sec - from.sec)) + @as(f64, @floatFromInt(to.nsec - from.nsec)) / std.time.ns_per_s;
}

fn physical(size: [2]f32, scale: f32) [2]u32 {
    return .{ @intFromFloat(@max(@round(size[0] * scale), 1)), @intFromFloat(@max(@round(size[1] * scale), 1)) };
}

test {
    _ = wire;
    _ = @import("xkb.zig");
    _ = @import("test.zig");
}
