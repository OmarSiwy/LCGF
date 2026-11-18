//! The shells' example application (src/shell/example.zig) in an X11 window:
//!
//!     zig build x11-example && zig-out/bin/x11-example [seconds]
//!
//! Connects to `DISPLAY` with the cookie from `XAUTHORITY` (or ~/.Xauthority), opens the input
//! method named in `XMODIFIERS` when there is one, and runs the host loop of
//! src/shell/iface.zig `run` until the window is closed, or for `seconds` (ci/run.sh x11 runs it
//! for 2 on Xvfb). Prints how many frames it built and drew.

const std = @import("std");
const lcgf = @import("lcgf");
const x11 = @import("x11.zig");
const context = lcgf.context;
const scheduler = lcgf.scheduler;
const Quad = lcgf.draw_list.Quad;
const example = lcgf.shell_example;
const Events = lcgf.shell_iface.Events;

const limits: context.Limits = .{ .nodes = 1024, .texts = 256 };

var conn: x11.Connection = .{};
var ctx_buffer: [context.Context.requiredBytes(limits)]u8 align(lcgf.mem.column_align) = undefined;
var glyphs: [4096]Quad = undefined;
var first: [limits.texts]u32 = undefined;
var count: [limits.texts]u32 = undefined;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const env = init.environ_map;
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const seconds: f32 = if (args.next()) |s| try std.fmt.parseFloat(f32, s) else lcgf.types.inf;

    const display = env.get("DISPLAY") orelse return error.NoDisplay;
    var auth_path_buf: [512]u8 = undefined;
    const auth_path = env.get("XAUTHORITY") orelse if (env.get("HOME")) |home| try std.fmt.bufPrint(&auth_path_buf, "{s}/.Xauthority", .{home}) else "";
    const auth = std.Io.Dir.cwd().readFileAlloc(io, auth_path, init.gpa, .limited(1 << 20)) catch "";
    try conn.open(display, auth);
    defer conn.close();
    if (env.get("XMODIFIERS")) |m| {
        if (std.mem.startsWith(u8, m, "@im=")) conn.openIme(m[4..], "en_US") catch {};
    }

    var pixels: std.ArrayList(u32) = .empty;
    defer pixels.deinit(init.gpa);
    var w: x11.Window = undefined;
    try w.open(&conn, 800, 600, "lcgf example", .{ .pixels = pixels.items, .glyphs = &glyphs, .first = &first, .count = &count });
    defer w.close();
    var ctx = try context.Context.init(&ctx_buffer, limits);
    var app: example.App = .{};

    // `iface.run`, with a time limit.
    const t0 = std.Io.Timestamp.now(io, .awake);
    var ev: Events = .{};
    while (w.poll(&ev)) {
        if (ctx.needsFrame(&ev.in)) {
            try w.fitPixels(&pixels, init.gpa);
            var f = ctx.begin(&ev.in);
            app.build(&f, &ev);
            const out = f.end(.{});
            w.apply(&out.platform);
            w.present(&out);
        }
        const elapsed: f32 = @floatCast(@as(f64, @floatFromInt(t0.durationTo(std.Io.Timestamp.now(io, .awake)).toNanoseconds())) / std.time.ns_per_s);
        if (elapsed >= seconds) break;
        w.wait(@min(scheduler.wake(&ctx, &ev.in), seconds - elapsed), scheduler.pace(&ctx));
    }

    var buf: [128]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &buf);
    try out.interface.print("x11-example: {d} frames built, {d} presented, {d} polls, {d} server errors\n", .{ app.builds, w.presents, w.polls, conn.errors });
    try out.interface.flush();
    if (w.presents == 0 or conn.errors != 0) return error.ExampleFailed;
}
