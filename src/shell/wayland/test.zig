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
