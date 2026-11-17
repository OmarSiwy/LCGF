//! Runs one example (the `example` module, any examples/<name>/app.zig) in an X11 window:
//!
//!     zig build examples && zig-out/bin/example-<name> [seconds]
//!
//! The host loop of src/shell/x11/example.zig, except that the host draws each frame itself
//! (host.zig `draw`: under the UI, the UI, the custom rects) into the window's pixels and sends
//! them, instead of calling `Window.present`, which skips custom commands. Runs until the window
//! is closed, or for `seconds` (ci/run.sh examples-x11 runs each for 1 on Xvfb).

const std = @import("std");
const linux = std.os.linux;
const lcgf = @import("lcgf");
const x11 = @import("x11");
const host = @import("host");
const example = @import("example");
const context = lcgf.context;
const scheduler = lcgf.scheduler;
const sw = lcgf.render_sw;
const wire = lcgf.shell_x11_wire;
const Quad = lcgf.draw_list.Quad;

const limits: context.Limits = if (@hasDecl(example, "limits")) example.limits else .{ .nodes = 1024, .texts = 256 };
const max_w = 1920;
const max_h = 1200;

var conn: x11.Connection = .{};
var ctx_buffer: [context.Context.requiredBytes(limits)]u8 align(lcgf.mem.column_align) = undefined;
var pixels: [sw.Framebuffer.len(max_w, max_h)]u32 = undefined;
var glyphs: [8192]Quad = undefined;
var first: [limits.texts]u32 = undefined;
var count: [limits.texts]u32 = undefined;
var app: example.App = .{};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const env = init.environ_map;
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    const name = std.fs.path.basename(args.next() orelse "example");
    const seconds: f32 = if (args.next()) |s| try std.fmt.parseFloat(f32, s) else lcgf.types.inf;

    const display = env.get("DISPLAY") orelse return error.NoDisplay;
    var auth_path_buf: [512]u8 = undefined;
    const auth_path = env.get("XAUTHORITY") orelse if (env.get("HOME")) |home| try std.fmt.bufPrint(&auth_path_buf, "{s}/.Xauthority", .{home}) else "";
    const auth = std.Io.Dir.cwd().readFileAlloc(io, auth_path, init.gpa, .limited(1 << 20)) catch "";
    try conn.open(display, auth);
    defer conn.close();

    var w: x11.Window = undefined;
    try w.open(&conn, 800, 600, name, .{ .pixels = &pixels, .glyphs = &glyphs, .first = &first, .count = &count });
    defer w.close();
    var ctx = try context.Context.init(&ctx_buffer, limits);
    if (@hasDecl(example.App, "init")) app.init();

    const t0 = std.Io.Timestamp.now(io, .awake);
    var ev: host.Events = .{};
    var builds: u32 = 0;
    while (w.poll(&ev)) {
        if (ctx.needsFrame(&ev.in)) {
            var f = ctx.begin(&ev.in);
            app.build(&f, &ev);
            const out = f.end(.{});
            builds += 1;
            w.apply(&out.platform);
            present(&w, &out);
        }
        const elapsed: f32 = @floatCast(@as(f64, @floatFromInt(t0.durationTo(std.Io.Timestamp.now(io, .awake)).toNanoseconds())) / std.time.ns_per_s);
        if (elapsed >= seconds) break;
        w.wait(@min(scheduler.wake(&ctx, &ev.in), seconds - elapsed), scheduler.pace(&ctx));
    }

    var buf: [128]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &buf);
    try out.interface.print("{s}: {d} frames built, {d} presented, {d} server errors\n", .{ name, builds, w.presents, conn.errors });
    try out.interface.flush();
    if (w.presents == 0 or conn.errors != 0) return error.ExampleFailed;
}

/// `Window.present` with the host's own drawing: draw into the window's pixels, then send them
/// with PutImage in strips that fit the connection's output buffer.
fn present(w: *x11.Window, out: *const context.Output) void {
    w.presents += 1;
    const width: u32 = w.width;
    const rows: u32 = @intCast(@min(w.height, w.pixels.len / sw.Framebuffer.len(width, 1)));
    w.fb = .init(w.pixels, width, rows, .bgra8);
    host.draw(&app, &w.gfx.gfx, &w.fb, .{ .quads = w.glyphs.quads, .first = w.glyphs.first, .count = w.glyphs.count }, out, w.scale, w.background);
    const c = w.conn;
    const fb = &w.fb;
    const row_bytes = @as(usize, fb.stride) * 4;
    const max_bytes = @min(@as(usize, c.setup.max_request) * 4, c.out.len) - wire.put_image_head;
    const strip: u32 = @intCast(@max(1, @min(max_bytes / row_bytes, 0xffff)));
    var y: u32 = 0;
    while (y < fb.height) : (y += strip) {
        const h = @min(strip, fb.height - y);
        const px = std.mem.sliceAsBytes(fb.pixels[y * fb.stride ..][0 .. h * fb.stride]);
        _ = c.send(wire.put_image_head + px.len, putStrip, .{ w.id, w.gc, @as(u16, @intCast(fb.stride)), @as(u16, @intCast(h)), @as(i16, @intCast(y)), c.setup.root_depth, px });
    }
    c.flush() catch {};
    w.presented = true;
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    w.last_present = @as(f64, @floatFromInt(ts.sec)) + @as(f64, @floatFromInt(ts.nsec)) * 1e-9;
}

fn putStrip(b: *wire.Buf, drawable: u32, gc: u32, width: u16, h: u16, y: i16, depth: u8, px: []const u8) void {
    wire.putImage(b, drawable, gc, width, h, 0, y, depth);
    @memcpy(b.bytes[b.len..][0..px.len], px);
    b.len += px.len;
}
