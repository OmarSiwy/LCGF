//! The Wayland shell against a fake compositor: the test holds the other end of a socket pair,
//! sends the events a compositor would, and reads back the client's requests and the pixels of
//! the buffer it committed. Single-threaded: the test writes events, then the client polls.
//! The fake reads the client's object table (`Wayland.kinds`) to learn which id is which,
//! instead of carrying a protocol description.

const std = @import("std");
const lcgr = @import("lcgr");
const wire = @import("wire.zig");
const wl = @import("wayland.zig");
const Wayland = wl.Wayland;
const linux = std.os.linux;
const testing = std.testing;
const context = lcgr.context;
const iface = lcgr.shell_iface;
const Events = iface.Events;
const example = lcgr.shell_example;
const Color = lcgr.types.Color;
const Input = lcgr.input.Input;

/// A request the client sent, for assertions.
pub const Request = struct { kind: wl.Kind, id: u32, opcode: u16, arg0: u32, arg1: u32 };

pub const Fake = struct {
    conn: wire.Conn,
    serial: u32 = 100,
    pool: []align(4096) u8 = &.{},
    buffers: [8]Buffer = @splat(.{}),
    attached: u32 = 0,
    committed: u32 = 0,
    log: [512]Request = undefined,
    logged: usize = 0,
    /// The descriptor of the client's last wl_data_offer.receive, for the test to write into.
    received: i32 = -1,

    const Buffer = struct { id: u32 = 0, offset: u32 = 0, width: u32 = 0, height: u32 = 0, stride: u32 = 0 };

    pub fn deinit(f: *Fake) void {
        if (f.pool.len > 0) _ = linux.munmap(f.pool.ptr, f.pool.len);
        f.conn.close();
    }

    pub fn send(f: *Fake, id: u32, opcode: u16, args: anytype) void {
        f.conn.send(id, opcode, args) catch unreachable;
    }
    pub fn flush(f: *Fake) void {
        f.conn.flush() catch unreachable;
    }
    pub fn nextSerial(f: *Fake) u32 {
        f.serial += 1;
        return f.serial;
    }

    /// Advertises `globals` (interface names, at their newest version) and ends the start-up sync.
    pub fn start(f: *Fake, c: *const Wayland, globals: []const []const u8) void {
        for (globals, 1..) |g, name| f.send(c.registry, 0, .{ @as(u32, @intCast(name)), g, @as(u32, 99) });
        f.send(c.sync, 0, .{@as(u32, 0)});
        f.send(1, 1, .{c.sync}); // delete_id
        f.flush();
    }

    pub fn configure(f: *Fake, c: *const Wayland, width: i32, height: i32) void {
        f.send(c.toplevel, 0, .{ width, height, wire.Array{ .bytes = &.{} } });
        f.send(c.xdg_surface, 0, .{f.nextSerial()});
        f.flush();
    }

    /// Reads every request the client sent and answers the ones a compositor must: frame
    /// callbacks, buffer releases, delete_id for destroyed objects.
    pub fn pump(f: *Fake, c: *const Wayland) void {
        while (f.conn.fill() catch false) {}
        while (f.conn.next()) |m| {
            var a = m.args();
            const kind: wl.Kind = if (m.id < wl.max_objects) c.kinds[m.id] else .free;
            const arg0 = a.uint();
            const arg1 = a.uint();
            if (f.logged < f.log.len) f.log[f.logged] = .{ .kind = kind, .id = m.id, .opcode = m.opcode, .arg0 = arg0, .arg1 = arg1 };
            f.logged += 1;
            a = m.args();
            if (m.id >= 0xff00_0000 and m.opcode == 1) f.received = f.conn.takeFd();
            switch (kind) {
                .shm => if (m.opcode == 0) {
                    _ = a.uint();
                    const fd = f.conn.takeFd();
                    const size: usize = @intCast(a.int());
                    if (f.pool.len > 0) _ = linux.munmap(f.pool.ptr, f.pool.len);
                    const addr = linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .SHARED }, fd, 0);
                    std.debug.assert(linux.errno(addr) == .SUCCESS);
                    f.pool = @as([*]align(4096) u8, @ptrFromInt(addr))[0..size];
                    _ = linux.close(fd);
                },
                .shm_pool, .dead => if (kind == .shm_pool and m.opcode == 0) {
                    const b: Buffer = .{ .id = a.uint(), .offset = a.uint(), .width = a.uint(), .height = a.uint(), .stride = a.uint() };
                    for (&f.buffers) |*s| if (s.id == 0 or s.id == b.id) {
                        s.* = b;
                        break;
                    };
                } else {
                    // A destructor (buffer.destroy, pool.destroy): the id may be reused.
                    f.send(1, 1, .{m.id});
                },
                .surface => switch (m.opcode) {
                    1 => f.attached = arg0,
                    3 => f.send(arg0, 0, .{@as(u32, 0)}), // frame: done at once
                    6 => if (f.attached != 0) {
                        if (f.committed != 0 and f.committed != f.attached) f.send(f.committed, 0, .{});
                        f.committed = f.attached;
                        f.attached = 0;
                    },
                    else => {},
                },
                else => {},
            }
        }
        f.flush();
    }

    /// Whether the client sent `opcode` to an object of `kind` since the log was last cleared.
    pub fn sent(f: *const Fake, kind: wl.Kind, opcode: u16) ?Request {
        var found: ?Request = null;
        for (f.log[0..@min(f.logged, f.log.len)]) |r| if (r.kind == kind and r.opcode == opcode) {
            found = r;
        };
        return found;
    }

    /// Pixel (x, y) of the committed buffer.
    pub fn pixel(f: *const Fake, x: u32, y: u32) Color {
        const b = for (f.buffers) |b| {
            if (b.id == f.committed) break b;
        } else unreachable;
        const p = std.mem.readInt(u32, f.pool[b.offset + y * b.stride + x * 4 ..][0..4], .little);
        return .rgba(@truncate(p >> 16), @truncate(p >> 8), @truncate(p), @truncate(p >> 24));
    }
    pub fn committedSize(f: *const Fake) [2]u32 {
        for (f.buffers) |b| if (b.id == f.committed) return .{ b.width, b.height };
        return .{ 0, 0 };
    }
};

const limits: context.Limits = .{ .nodes = 1024, .texts = 256 };

/// Everything the example and the shell need, static.
pub const Fixture = struct {
    var ctx_buffer: [context.Context.requiredBytes(limits)]u8 align(lcgr.mem.column_align) = undefined;
    var glyphs: [512]lcgr.draw_list.Quad = undefined;
    var first: [limits.texts]u32 = undefined;
    var count: [limits.texts]u32 = undefined;

    pub fn ctx() !context.Context {
        return context.Context.init(&ctx_buffer, limits);
    }
    /// A client and a fake compositor on two ends of a socket pair.
    pub fn pair() struct { Wayland, Fake } {
        const fds = wire.pair();
        return .{
            Wayland.init(fds[0], .{ .title = "example" }, .{ .glyphs = &glyphs, .first = &first, .count = &count }),
            .{ .conn = .{ .fd = fds[1] } },
        };
    }
};

pub const core_globals = [_][]const u8{ "wl_compositor", "wl_shm", "xdg_wm_base" };

/// One turn of `iface.run` without the wait: null when the shell is done or no frame was needed.
pub fn turn(shell: *Wayland, ctx: *context.Context, app: *example.App, ev: *Events) ?context.Output {
    if (!shell.poll(ev)) return null;
    if (!ctx.needsFrame(&ev.in)) return null;
    var f = ctx.begin(&ev.in);
    app.build(&f, ev);
    const out = f.end(.{});
    shell.apply(&out.platform);
    shell.present(&out);
    return out;
}

test "wayland: the example opens a toplevel, follows configure and close, and its pixels arrive" {
    var ctx = try Fixture.ctx();
    var app: example.App = .{};
    var shell, var fake = Fixture.pair();
    defer shell.deinit();
    defer fake.deinit();
    var ev: Events = .{};

    // Globals, then the toplevel: created and committed without a buffer, not yet configured.
    fake.start(&shell, &core_globals);
    try testing.expect(shell.poll(&ev));
    fake.pump(&shell);
    try testing.expect(fake.sent(.xdg_surface, 1) != null); // get_toplevel
    try testing.expect(fake.sent(.toplevel, 2) != null); // set_title
    try testing.expect(fake.sent(.surface, 6) != null); // commit
    try testing.expect(fake.sent(.surface, 1) == null); // no buffer before the first configure
    try testing.expect(!shell.configured);

    // A ping is answered with a pong of the same serial.
    fake.send(shell.globals.get(.xdg_wm_base), 0, .{@as(u32, 77)});
    fake.configure(&shell, 800, 600);
    var out = turn(&shell, &ctx, &app, &ev).?;
    fake.pump(&shell);
    try testing.expectEqual(@as(u32, 77), fake.sent(.wm_base, 3).?.arg0);
    try testing.expectEqual(fake.serial, fake.sent(.xdg_surface, 4).?.arg0); // ack_configure
    try testing.expect(shell.configured);
    try testing.expectEqual([2]f32{ 800, 600 }, ev.in.viewport);
    try testing.expect(out.status.ok());
    try testing.expectEqual(lcgr.types.Rect{ .x0 = 160, .y0 = 50, .x1 = 800, .y1 = 600 }, out.tree.rect(out.tree.find(example.id_viewport)));

    // The committed buffer holds the frame: the same pixels the headless shell checks.
    try testing.expectEqual([2]u32{ 800, 600 }, fake.committedSize());
    const th = app.theme;
    try testing.expectEqual(th.panel, fake.pixel(80, 590));
    try testing.expectEqual(th.control, fake.pixel(12, 74));
    try testing.expectEqual(shell.background, fake.pixel(400, 300));
    try testing.expectEqual(th.text, fake.pixel(20, 70));

    // The settle frame, then idle: nothing is built or committed.
    _ = turn(&shell, &ctx, &app, &ev).?;
    try testing.expectEqual(null, turn(&shell, &ctx, &app, &ev));
    const presents = shell.presents;

    // A resize: a new frame at the new size, in new buffers.
    fake.configure(&shell, 1024, 768);
    out = turn(&shell, &ctx, &app, &ev).?;
    fake.pump(&shell);
    try testing.expectEqual(presents + 1, shell.presents);
    try testing.expectEqual([2]u32{ 1024, 768 }, fake.committedSize());
    try testing.expectEqual(lcgr.types.Rect{ .x0 = 160, .y0 = 50, .x1 = 1024, .y1 = 768 }, out.tree.rect(out.tree.find(example.id_viewport)));
    try testing.expectEqual(th.panel, fake.pixel(80, 760));

    // Close: the shell has no more frames.
    fake.send(shell.toplevel, 1, .{});
    fake.flush();
    try testing.expectEqual(null, turn(&shell, &ctx, &app, &ev));
    try testing.expectEqual(null, shell.err);
}

test "wayland: a compositor without xdg_wm_base fails the start-up and says why" {
    var shell, var fake = Fixture.pair();
    defer shell.deinit();
    defer fake.deinit();
    fake.start(&shell, &.{ "wl_compositor", "wl_shm" });
    var ev: Events = .{};
    try testing.expect(!shell.poll(&ev));
    try testing.expectEqual(error.MissingGlobal, shell.err.?);
}

test "wayland: the compositor hanging up ends the shell" {
    var shell, var fake = Fixture.pair();
    defer shell.deinit();
    fake.deinit();
    var ev: Events = .{};
    try testing.expect(!shell.poll(&ev));
    try testing.expectEqual(error.Disconnected, shell.err.?);
}

pub const seat_globals = core_globals ++ [_][]const u8{"wl_seat"};

/// A configured window with a pointer, keyboard and touch screen, after its first frame.
fn opened(shell: *Wayland, fake: *Fake, ctx: *context.Context, app: *example.App, ev: *Events) !void {
    fake.start(shell, &seat_globals);
    try testing.expect(shell.poll(ev));
    fake.send(shell.globals.get(.wl_seat), 0, .{@as(u32, 7)});
    fake.configure(shell, 800, 600);
    _ = turn(shell, ctx, app, ev);
    fake.pump(shell);
    try testing.expect(shell.seat.pointer != 0 and shell.seat.keyboard != 0 and shell.seat.touch != 0);
}

const btn_left: u32 = 0x110;

test "wayland: pointer events replay the example's recording" {
    // src/shell/testdata/example.replay as a compositor sends it: enter, motion, buttons.
    var ctx = try Fixture.ctx();
    var app: example.App = .{};
    var shell, var fake = Fixture.pair();
    defer shell.deinit();
    defer fake.deinit();
    var ev: Events = .{};
    try opened(&shell, &fake, &ctx, &app, &ev);
    while (turn(&shell, &ctx, &app, &ev) != null) {} // settle
    const p = shell.seat.pointer;

    // Click Reset, entering the window over it.
    fake.send(p, 0, .{ fake.nextSerial(), shell.surface, wire.Fixed.from(37), wire.Fixed.from(25) });
    fake.flush();
    _ = turn(&shell, &ctx, &app, &ev).?;
    try testing.expectEqual([2]f32{ 37, 25 }, ev.in.pointer);
    for ([_]u32{ 1, 0 }) |state| {
        fake.send(p, 3, .{ fake.nextSerial(), @as(u32, 0), btn_left, state });
        fake.flush();
        _ = turn(&shell, &ctx, &app, &ev).?;
    }
    try testing.expectEqual(@as(u32, 1), app.resets);

    // Click Add layer, then hold the exposure slider at 75% of its track.
    for ([_][2]f32{ .{ 54, 74 }, .{ 639, 25 } }) |at| {
        fake.send(p, 2, .{ @as(u32, 0), wire.Fixed.from(at[0]), wire.Fixed.from(at[1]) });
        fake.flush();
        _ = turn(&shell, &ctx, &app, &ev).?;
        for ([_]u32{ 1, 0 }) |state| {
            fake.send(p, 3, .{ fake.nextSerial(), @as(u32, 0), btn_left, state });
            fake.flush();
            _ = turn(&shell, &ctx, &app, &ev).?;
            try testing.expectEqual(state == 1, ev.in.buttons.left);
        }
    }
    try testing.expectEqual(@as(u32, 4), app.layers);
    try testing.expectApproxEqAbs(@as(f32, 3), app.exposure, 0.01);

    // Leave the window: no pointer, and the frame after settles to idle.
    fake.send(p, 1, .{ fake.nextSerial(), shell.surface });
    fake.flush();
    _ = turn(&shell, &ctx, &app, &ev).?;
    try testing.expectEqual([2]f32{ -1, -1 }, ev.in.pointer);
    _ = turn(&shell, &ctx, &app, &ev);
    try testing.expectEqual(null, turn(&shell, &ctx, &app, &ev));
}

test "wayland: wheel notches and touchpad pixels, signed as the core reads them" {
    var shell, var fake = Fixture.pair();
    defer shell.deinit();
    defer fake.deinit();
    fake.start(&shell, &seat_globals);
    var ev: Events = .{};
    _ = shell.poll(&ev);
    fake.send(shell.globals.get(.wl_seat), 0, .{@as(u32, 1)});
    fake.flush();
    _ = shell.poll(&ev);
    const p = shell.seat.pointer;
    // One notch down (value120 = 120, with its 15 px axis event): the core's wheel is -1.
    fake.send(p, 4, .{ @as(u32, 0), @as(u32, 0), wire.Fixed.from(15) });
    fake.send(p, 9, .{ @as(u32, 0), @as(i32, 120) });
    fake.send(p, 5, .{});
    fake.flush();
    _ = shell.poll(&ev);
    try testing.expectEqual([2]f32{ 0, -1 }, ev.in.wheel);
    try testing.expectEqual([2]f32{ 0, 0 }, ev.in.scroll);
    // A touchpad: pixels only, 12.5 to the right and 3 up.
    fake.send(p, 4, .{ @as(u32, 0), @as(u32, 1), wire.Fixed.from(12.5) });
    fake.send(p, 4, .{ @as(u32, 0), @as(u32, 0), wire.Fixed.from(-3) });
    fake.flush();
    _ = shell.poll(&ev);
    try testing.expectEqual([2]f32{ 0, 0 }, ev.in.wheel);
    try testing.expectEqual([2]f32{ -12.5, 3 }, ev.in.scroll);
    // Per poll: nothing new, nothing reported.
    _ = shell.poll(&ev);
    try testing.expectEqual([2]f32{ 0, 0 }, ev.in.scroll);
}

/// Sends `wl_keyboard.keymap` with `text` in a memfd, as a compositor does.
fn sendKeymap(fake: *Fake, keyboard: u32, text: []const u8) void {
    const fd: i32 = @intCast(linux.memfd_create("keymap", linux.MFD.CLOEXEC));
    _ = linux.write(fd, text.ptr, text.len);
    fake.send(keyboard, 0, .{ @as(u32, 1), wire.Fd{ .fd = fd }, @as(u32, @intCast(text.len)) });
}

test "wayland: keys become HID scancodes and the keymap's text, in order" {
    var shell, var fake = Fixture.pair();
    defer shell.deinit();
    defer fake.deinit();
    fake.start(&shell, &seat_globals);
    var ev: Events = .{};
    _ = shell.poll(&ev);
    fake.send(shell.globals.get(.wl_seat), 0, .{@as(u32, 2)});
    fake.flush();
    _ = shell.poll(&ev);
    const k = shell.seat.keyboard;
    sendKeymap(&fake, k, @embedFile("testdata/de.xkb"));
    // Focus arrives with the A key (evdev 30) already held.
    const held = [_]u32{30};
    fake.send(k, 1, .{ fake.nextSerial(), shell.surface, wire.Array{ .bytes = std.mem.sliceAsBytes(&held) } });
    fake.flush();
    _ = shell.poll(&ev);
    try testing.expect(ev.in.keys.down(0x04));

    // Release A; Shift+Z (German layout: evdev 21); ö; then Ctrl+V types nothing.
    const key = struct {
        fn send(f: *Fake, kb: u32, code: u32, state: u32) void {
            f.send(kb, 3, .{ f.nextSerial(), @as(u32, 0), code, state });
        }
    }.send;
    key(&fake, k, 30, 0);
    fake.send(k, 4, .{ fake.nextSerial(), @as(u32, 1), @as(u32, 0), @as(u32, 0), @as(u32, 0) });
    key(&fake, k, 21, 1);
    key(&fake, k, 21, 0);
    fake.send(k, 4, .{ fake.nextSerial(), @as(u32, 0), @as(u32, 0), @as(u32, 0), @as(u32, 0) });
    key(&fake, k, 39, 1);
    fake.send(k, 4, .{ fake.nextSerial(), @as(u32, 4), @as(u32, 0), @as(u32, 0), @as(u32, 0) });
    key(&fake, k, 47, 1);
    fake.flush();
    _ = shell.poll(&ev);
    try testing.expectEqualStrings("Z\xc3\xb6", ev.in.text);
    const E = Input.Event;
    const shift: Input.Mods = .{ .shift = true };
    const ctrl: Input.Mods = .{ .ctrl = true };
    try testing.expectEqualSlices(E, &.{
        .{ .kind = .release, .code = 0x04 },
        .{ .kind = .press, .code = 0x1c, .mods = shift }, // HID Y: the key's US label
        .{ .kind = .text, .mods = shift, .at = 0, .len = 1 },
        .{ .kind = .release, .code = 0x1c, .mods = shift },
        .{ .kind = .press, .code = 0x33 },
        .{ .kind = .text, .at = 1, .len = 2 },
        .{ .kind = .press, .code = 0x19, .mods = ctrl },
    }, ev.in.events);
    try testing.expect(ev.in.keys.down(0x33) and ev.in.keys.down(0x19) and !ev.in.keys.down(0x04));
    try testing.expectEqual(ctrl, ev.in.mods);
    // Per poll: the text and events are gone, held keys stay.
    _ = shell.poll(&ev);
    try testing.expectEqual(@as(usize, 0), ev.in.events.len);
    try testing.expect(ev.in.keys.down(0x19));
    // Losing focus lets go of everything.
    fake.send(k, 2, .{ fake.nextSerial(), shell.surface });
    fake.flush();
    _ = shell.poll(&ev);
    try testing.expectEqual(Input.Keys{}, ev.in.keys);
    try testing.expectEqual(Input.Mods{}, ev.in.mods);
}

test "wayland: touch points are contacts, and a quick tap is still seen" {
    var shell, var fake = Fixture.pair();
    defer shell.deinit();
    defer fake.deinit();
    fake.start(&shell, &seat_globals);
    var ev: Events = .{};
    _ = shell.poll(&ev);
    fake.send(shell.globals.get(.wl_seat), 0, .{@as(u32, 4)});
    fake.flush();
    _ = shell.poll(&ev);
    const t = shell.seat.touch;
    fake.send(t, 0, .{ fake.nextSerial(), @as(u32, 0), shell.surface, @as(i32, 5), wire.Fixed.from(10), wire.Fixed.from(20) });
    fake.send(t, 3, .{});
    fake.flush();
    _ = shell.poll(&ev);
    try testing.expectEqualSlices(Input.Contact, &.{.{ .id = 5, .pos = .{ 10, 20 } }}, ev.in.contacts);
    // A second finger taps (down and up before the poll) while the first moves.
    fake.send(t, 2, .{ @as(u32, 0), @as(i32, 5), wire.Fixed.from(11), wire.Fixed.from(22) });
    fake.send(t, 0, .{ fake.nextSerial(), @as(u32, 0), shell.surface, @as(i32, 6), wire.Fixed.from(50), wire.Fixed.from(60) });
    fake.send(t, 1, .{ fake.nextSerial(), @as(u32, 0), @as(i32, 6) });
    fake.flush();
    _ = shell.poll(&ev);
    try testing.expectEqualSlices(Input.Contact, &.{
        .{ .id = 5, .pos = .{ 11, 22 } },
        .{ .id = 6, .down = false, .pos = .{ 50, 60 } },
    }, ev.in.contacts);
    // The lifted finger is gone the poll after.
    _ = shell.poll(&ev);
    try testing.expectEqual(@as(usize, 1), ev.in.contacts.len);
}

test "wayland: fractional scale 1.5 draws 1200 x 900 pixels shown at 800 x 600" {
    var ctx = try Fixture.ctx();
    var app: example.App = .{};
    var shell, var fake = Fixture.pair();
    defer shell.deinit();
    defer fake.deinit();
    var ev: Events = .{};
    fake.start(&shell, &(core_globals ++ [_][]const u8{ "wp_viewporter", "wp_fractional_scale_manager_v1" }));
    _ = shell.poll(&ev);
    fake.pump(&shell);
    const frac = fake.sent(.fractional_manager, 1).?.arg0;
    try testing.expect(shell.viewport != 0);
    fake.send(frac, 0, .{@as(u32, 180)}); // preferred_scale: 1.5 * 120
    fake.configure(&shell, 800, 600);
    const out = turn(&shell, &ctx, &app, &ev).?;
    fake.pump(&shell);
    try testing.expectEqual(@as(f32, 1.5), ev.in.scale);
    try testing.expectEqual([2]f32{ 800, 600 }, ev.in.viewport);
    // Layout stays logical; the buffer is physical, and the viewport maps it back.
    try testing.expectEqual(lcgr.types.Rect{ .x0 = 160, .y0 = 50, .x1 = 800, .y1 = 600 }, out.tree.rect(out.tree.find(example.id_viewport)));
    try testing.expectEqual([2]u32{ 1200, 900 }, fake.committedSize());
    const dest = fake.sent(.viewport, 2).?;
    try testing.expectEqual([2]u32{ 800, 600 }, [2]u32{ dest.arg0, dest.arg1 });
    try testing.expect(fake.sent(.surface, 8) == null); // no integer buffer scale
    try testing.expectEqual(app.theme.panel, fake.pixel(120, 885));
    try testing.expectEqual(shell.background, fake.pixel(600, 450));
    // Moving to a scale-1.25 output: the next frame is redrawn at 1000 x 750.
    fake.send(frac, 0, .{@as(u32, 150)});
    fake.flush();
    _ = turn(&shell, &ctx, &app, &ev).?;
    fake.pump(&shell);
    try testing.expectEqual([2]u32{ 1000, 750 }, fake.committedSize());
}

test "wayland: without fractional scaling, the integer buffer scale" {
    var ctx = try Fixture.ctx();
    var app: example.App = .{};
    var shell, var fake = Fixture.pair();
    defer shell.deinit();
    defer fake.deinit();
    var ev: Events = .{};
    fake.start(&shell, &core_globals);
    _ = shell.poll(&ev);
    fake.send(shell.surface, 2, .{@as(i32, 2)}); // preferred_buffer_scale
    fake.configure(&shell, 400, 300);
    _ = turn(&shell, &ctx, &app, &ev).?;
    fake.pump(&shell);
    try testing.expectEqual(@as(f32, 2), ev.in.scale);
    try testing.expectEqual([2]u32{ 800, 600 }, fake.committedSize());
    try testing.expectEqual(@as(u32, 2), fake.sent(.surface, 8).?.arg0);
    try testing.expectEqual(app.theme.panel, fake.pixel(160, 590));
}

test "wayland: before wl_surface v6, the scale of the output the window entered" {
    var shell, var fake = Fixture.pair();
    defer shell.deinit();
    defer fake.deinit();
    var ev: Events = .{};
    fake.start(&shell, &(core_globals ++ [_][]const u8{"wl_output"}));
    _ = shell.poll(&ev);
    const out = shell.outputs[0].id;
    fake.send(out, 3, .{@as(i32, 3)}); // scale
    fake.flush();
    _ = shell.poll(&ev);
    try testing.expectEqual(@as(f32, 1), ev.in.scale); // not on that output yet
    fake.send(shell.surface, 0, .{out}); // enter
    fake.flush();
    _ = shell.poll(&ev);
    try testing.expectEqual(@as(f32, 3), ev.in.scale);
    fake.send(shell.surface, 1, .{out}); // leave
    fake.flush();
    _ = shell.poll(&ev);
    try testing.expectEqual(@as(f32, 1), ev.in.scale);
}

test "wayland: the cursor the UI asks for, set again after each enter" {
    var ctx = try Fixture.ctx();
    var app: example.App = .{};
    var shell, var fake = Fixture.pair();
    defer shell.deinit();
    defer fake.deinit();
    var ev: Events = .{};
    fake.start(&shell, &(seat_globals ++ [_][]const u8{"wp_cursor_shape_manager_v1"}));
    try testing.expect(shell.poll(&ev));
    fake.send(shell.globals.get(.wl_seat), 0, .{@as(u32, 1)});
    fake.configure(&shell, 800, 600);
    while (turn(&shell, &ctx, &app, &ev) != null) {}
    fake.pump(&shell);
    try testing.expectEqual(shell.seat.pointer, fake.sent(.cursor_manager, 1).?.arg1); // get_pointer
    try testing.expect(fake.sent(.cursor_device, 1) == null); // no pointer in the window yet

    // Enter over Reset: the button's hand, with the enter's serial.
    const p = shell.seat.pointer;
    const enter = fake.nextSerial();
    fake.send(p, 0, .{ enter, shell.surface, wire.Fixed.from(37), wire.Fixed.from(25) });
    fake.flush();
    fake.logged = 0;
    _ = turn(&shell, &ctx, &app, &ev).?;
    fake.pump(&shell);
    try testing.expectEqual(Request{ .kind = .cursor_device, .id = shell.cursor_device, .opcode = 1, .arg0 = enter, .arg1 = 4 }, fake.sent(.cursor_device, 1).?);

    // Away from it: the arrow (default).
    fake.send(p, 2, .{ @as(u32, 0), wire.Fixed.from(400), wire.Fixed.from(400) });
    fake.flush();
    fake.logged = 0;
    _ = turn(&shell, &ctx, &app, &ev).?;
    fake.pump(&shell);
    try testing.expectEqual(@as(u32, 1), fake.sent(.cursor_device, 1).?.arg1);

    // Leave and come back at the same place: same shape, new serial, so it is sent again.
    fake.send(p, 1, .{ fake.nextSerial(), shell.surface });
    const again = fake.nextSerial();
    fake.send(p, 0, .{ again, shell.surface, wire.Fixed.from(400), wire.Fixed.from(400) });
    fake.flush();
    fake.logged = 0;
    _ = shell.poll(&ev);
    shell.apply(&.{ .cursor = .arrow });
    fake.pump(&shell);
    try testing.expectEqual(again, fake.sent(.cursor_device, 1).?.arg0);
    // Unchanged after that: nothing is sent.
    fake.logged = 0;
    shell.apply(&.{ .cursor = .arrow });
    fake.pump(&shell);
    try testing.expect(fake.sent(.cursor_device, 1) == null);
}

/// Reads all of pipe `fd` (blocking) into `buf`.
fn readAll(fd: i32, buf: []u8) []u8 {
    var n: usize = 0;
    while (n < buf.len) {
        const rc = linux.read(fd, buf[n..].ptr, buf.len - n);
        if (rc == 0 or linux.errno(rc) != .SUCCESS) break;
        n += rc;
    }
    return buf[0..n];
}

test "wayland: copy offers the UI's text, paste types the selection's" {
    var shell, var fake = Fixture.pair();
    defer shell.deinit();
    defer fake.deinit();
    var ev: Events = .{};
    fake.start(&shell, &(seat_globals ++ [_][]const u8{"wl_data_device_manager"}));
    _ = shell.poll(&ev);
    fake.send(shell.globals.get(.wl_seat), 0, .{@as(u32, 3)});
    fake.flush();
    _ = shell.poll(&ev);
    fake.pump(&shell);
    try testing.expect(shell.data.device != 0);
    try testing.expectEqual(shell.globals.get(.wl_seat), fake.sent(.data_manager, 1).?.arg1); // get_data_device

    // Copy, after a click (the selection needs an input serial).
    const click = fake.nextSerial();
    fake.send(shell.seat.pointer, 3, .{ click, @as(u32, 0), @as(u32, 0x110), @as(u32, 1) });
    fake.flush();
    _ = shell.poll(&ev);
    shell.apply(&.{ .clipboard = "hello" });
    fake.pump(&shell);
    const source = fake.sent(.data_manager, 0).?.arg0;
    try testing.expectEqual(Request{ .kind = .data_device, .id = shell.data.device, .opcode = 1, .arg0 = source, .arg1 = click }, fake.sent(.data_device, 1).?);
    try testing.expect(fake.sent(.data_source, 0) != null); // offer
    // The same text next frame is not offered again.
    fake.logged = 0;
    shell.apply(&.{ .clipboard = "hello" });
    fake.pump(&shell);
    try testing.expect(fake.sent(.data_manager, 0) == null);

    // Another client pastes: the compositor asks for the text through a pipe.
    var p: [2]i32 = undefined;
    _ = linux.pipe2(&p, .{ .CLOEXEC = true });
    fake.send(source, 1, .{ @as([]const u8, "text/plain;charset=utf-8"), wire.Fd{ .fd = p[1] } });
    fake.flush();
    _ = shell.poll(&ev);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("hello", readAll(p[0], &buf));
    _ = linux.close(p[0]);

    // Another client copies: an offer, its types, then the selection.
    const offer: u32 = 0xff00_0001;
    fake.send(shell.data.device, 0, .{offer});
    fake.send(offer, 0, .{@as([]const u8, "text/html")});
    fake.send(offer, 0, .{@as([]const u8, "text/plain;charset=utf-8")});
    fake.send(shell.data.device, 5, .{offer});
    fake.send(source, 2, .{}); // cancelled: ours is no longer the selection
    fake.flush();
    _ = shell.poll(&ev);
    try testing.expectEqual(offer, shell.data.selection);
    try testing.expectEqual(@as(u32, 0), shell.data.source);
    try testing.expectEqual(@as(u8, 1), shell.data.offer(offer).?.mimes);

    // Paste: receive into a pipe; the text is typed in the poll that reads its end.
    try testing.expect(shell.paste());
    fake.pump(&shell);
    try testing.expect(fake.received >= 0);
    _ = linux.write(fake.received, "w\xc3\xb6rld", 6);
    _ = shell.poll(&ev);
    try testing.expectEqualStrings("", ev.in.text); // not finished yet
    _ = linux.close(fake.received);
    _ = shell.poll(&ev);
    try testing.expectEqualStrings("w\xc3\xb6rld", ev.in.text);
    try testing.expectEqualSlices(Input.Event, &.{.{ .kind = .text, .at = 0, .len = 6 }}, ev.in.events);
    _ = shell.poll(&ev);
    try testing.expectEqualStrings("", ev.in.text);

    // Pasting this client's own copy does not deadlock: the read waits across polls.
    shell.apply(&.{ .clipboard = "self" });
    fake.pump(&shell);
    const own = fake.sent(.data_manager, 0).?.arg0;
    fake.send(shell.data.device, 0, .{offer + 1});
    fake.send(offer + 1, 0, .{@as([]const u8, "UTF8_STRING")});
    fake.send(shell.data.device, 5, .{offer + 1});
    fake.flush();
    _ = shell.poll(&ev);
    try testing.expect(shell.paste());
    fake.pump(&shell);
    // The compositor forwards the receive to the source: this client.
    fake.send(own, 1, .{ @as([]const u8, "UTF8_STRING"), wire.Fd{ .fd = fake.received } });
    fake.flush();
    _ = shell.poll(&ev);
    try testing.expectEqualStrings("self", ev.in.text);
}

test "wayland: nothing to paste" {
    var shell, var fake = Fixture.pair();
    defer shell.deinit();
    defer fake.deinit();
    fake.start(&shell, &(seat_globals ++ [_][]const u8{"wl_data_device_manager"}));
    var ev: Events = .{};
    _ = shell.poll(&ev);
    try testing.expect(!shell.paste());
}
