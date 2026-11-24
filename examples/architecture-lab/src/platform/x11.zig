//! Linux/X11 adapter, adapted from LCGF's src/example/window.zig (MIT; see THIRD_PARTY.md).
//! The domain, presenters, and views have no X11 imports. Replace this file to change hosts.
const std = @import("std");
const lcgf = @import("lcgf");
const x11 = @import("x11");
const host = @import("host");
const application = @import("app");
const Context = lcgf.context.Context;
const limits = application.limits;
const use_incremental = application.options.incremental and @hasDecl(host, "Incremental");
const Retained = if (use_incremental) host.Incremental else struct {};

// Their addresses stay stable for the process lifetime. Context stores slices into storage.
var storage: [Context.requiredBytes(limits)]u8 align(lcgf.mem.column_align) = undefined;
var app: application.App = .{};
var connection: x11.Connection = .{};
var glyphs: [limits.strings]lcgf.draw_list.Quad = undefined;
var first: [limits.texts]u32 = undefined;
var count: [limits.texts]u32 = undefined;
var retained_storage: [if (use_incremental) host.Incremental.requiredBytes(limits) else 0]u8 align(lcgf.mem.column_align) = undefined;

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const seconds: f32 = if (args.next()) |arg| try std.fmt.parseFloat(f32, arg) else lcgf.types.inf;
    const display = init.environ_map.get("DISPLAY") orelse return error.NoDisplay;
    var auth_buffer: [512]u8 = undefined;
    const auth_path = init.environ_map.get("XAUTHORITY") orelse if (init.environ_map.get("HOME")) |home_path|
        try std.fmt.bufPrint(&auth_buffer, "{s}/.Xauthority", .{home_path})
    else
        "";
    const auth = std.Io.Dir.cwd().readFileAlloc(init.io, auth_path, init.gpa, .limited(1 << 20)) catch "";
    defer if (auth.len != 0) init.gpa.free(auth);
    try connection.open(display, auth);
    defer connection.close();

    // OS-facing pixel storage may allocate on creation and resize. It is not a domain arena.
    var pixels: std.ArrayList(u32) = .empty;
    defer pixels.deinit(init.gpa);
    var window: x11.Window = undefined;
    try window.open(&connection, 1000, 700, @tagName(application.options.architecture) ++ " / LCGF", .{ .pixels = pixels.items, .glyphs = &glyphs, .first = &first, .count = &count });
    defer window.close();
    var ctx = try Context.init(&storage, limits);
    var renderer: Retained = if (use_incremental) blk: {
        var carver: lcgf.mem.Carver = .{ .buf = &retained_storage };
        break :blk host.Incremental.init(&carver, limits);
    } else .{};
    app.init();
    var events: host.Events = .{};
    const start = std.Io.Timestamp.now(init.io, .awake);
    var frames: u64 = 0;
    while (window.poll(&events)) {
        if (ctx.needsFrame(&events.in)) {
            try window.fitPixels(&pixels, init.gpa);
            var frame = ctx.begin(&events.in);
            app.build(&frame, &events);
            const output = frame.end(.{});
            // Never present a silently truncated UI: raise limits deliberately when this fires.
            if (!output.status.ok()) return error.FrameCapacityExceeded;
            window.apply(&output.platform);
            const glyph_buffers: host.Glyphs = .{ .quads = window.glyphs.quads, .first = window.glyphs.first, .count = window.glyphs.count };
            if (use_incremental) {
                const update = renderer.draw(&app, &window.gfx.gfx, &window.fb, glyph_buffers, &output, window.scale, window.background);
                try window.presentPixelsRegions(update.boxes[0..update.len]);
            } else {
                host.draw(&app, &window.gfx.gfx, &window.fb, glyph_buffers, &output, window.scale, window.background);
                try window.presentPixels();
            }
            frames += 1;
        }
        const elapsed: f32 = @floatCast(@as(f64, @floatFromInt(start.durationTo(std.Io.Timestamp.now(init.io, .awake)).toNanoseconds())) / std.time.ns_per_s);
        if (elapsed >= seconds) break;
        window.wait(@min(lcgf.scheduler.wake(&ctx, &events.in), seconds - elapsed), lcgf.scheduler.pace(&ctx));
    }
    std.debug.print("{d} frames, {d} presented, {d} X11 errors\n", .{ frames, window.presents, connection.errors });
    if (connection.errors != 0) return error.WindowServerError;
}
