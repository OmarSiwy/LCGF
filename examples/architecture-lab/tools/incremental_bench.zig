//! Compare forced full drawing with explicit incremental drawing on changing application frames.
//! Every measured result is checked against the full framebuffer, outside the timed region.
//! Usage: incremental_bench [samples [width height scale]]. No X11 transfer is timed.
const std = @import("std");
const builtin = @import("builtin");
const lcgf = @import("lcgf");
const application = @import("app");
const host = @import("host");
const limits = application.limits;
const Context = lcgf.context.Context;
const sw = lcgf.render_sw;
const max_samples = 2001;
const warmups = 32;

var context_bytes: [Context.requiredBytes(limits)]u8 align(lcgf.mem.column_align) = undefined;
var app: application.App = .{};
const ItemId = @typeInfo(@TypeOf(app.snapshot().selected)).optional.child;
const GlyphStorage = struct {
    quads: [limits.strings + 1]lcgf.draw_list.Quad = undefined,
    first: [limits.texts]u32 = undefined,
    count: [limits.texts]u32 = undefined,
    fn borrow(self: *GlyphStorage) host.Glyphs {
        return .{ .quads = &self.quads, .first = &self.first, .count = &self.count };
    }
};
var full_glyphs: GlyphStorage = .{};
var partial_glyphs: GlyphStorage = .{};
var full_samples: [max_samples]u64 = undefined;
var partial_samples: [max_samples]u64 = undefined;
var ui_samples: [max_samples]u64 = undefined;

const Scenario = enum { unchanged, hover, selection, scroll, theme, navigation, sidebar, invalidation };
const Stats = struct { median_ns: u64, p95_ns: u64, p99_ns: u64 };
const Result = struct {
    scenario: []const u8,
    ui: Stats,
    full_draw: Stats,
    incremental_draw: Stats,
    mean_damage_pixels: u64,
    mean_pixel_payload_bytes: u64,
    full_frames: u32,
    glyph_rebuild_frames: u32,
    changed_pixel_frames: u32,
    zero_damage_frames: u32,
    verified_frames: usize,
    pixel_hash: u64,
    pixel_sequence_hash: u64,
};
fn elapsed(io: std.Io, start: std.Io.Timestamp) u64 {
    return @intCast(start.durationTo(std.Io.Timestamp.now(io, .awake)).toNanoseconds());
}
fn summarize(values: []u64) Stats {
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    return .{
        .median_ns = values[(values.len * 50 + 99) / 100 - 1],
        .p95_ns = values[(values.len * 95 + 99) / 100 - 1],
        .p99_ns = values[(values.len * 99 + 99) / 100 - 1],
    };
}
fn change(scenario: Scenario, step: usize, events: *host.Events) void {
    switch (scenario) {
        .unchanged, .invalidation => {},
        .hover => events.in.pointer = if (step % 2 == 0) .{ 25, 25 } else .{ 250, 100 },
        .selection => _ = app.commit(&.{}, &.{}, &.{.{ .select = @as(ItemId, @fromBackingInt(@intCast(1 + step % 2))) }}),
        .scroll => _ = app.commit(&.{}, &.{}, &.{.{ .scroll = if (step % 2 == 0) 1 else 5 }}),
        .theme => _ = app.commit(&.{}, &.{.toggle_theme}, &.{}),
        .navigation => _ = app.commit(&.{.{ .navigate = if (step % 2 == 0) .running else .all }}, &.{}, &.{}),
        .sidebar => _ = app.commit(&.{}, &.{.toggle_sidebar}, &.{}),
    }
}
pub fn main(init: std.process.Init) !void {
    if (comptime !@hasDecl(host, "Incremental")) return error.FrameworkHasNoIncrementalHost;
    return run(init);
}
fn run(init: std.process.Init) !void {
    const Storage = struct {
        var bytes: [host.Incremental.requiredBytes(limits)]u8 align(lcgf.mem.column_align) = undefined;
    };
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const n = if (args.next()) |v| try std.fmt.parseInt(usize, v, 10) else 101;
    const width = if (args.next()) |v| try std.fmt.parseInt(u32, v, 10) else 800;
    const height = if (args.next()) |v| try std.fmt.parseInt(u32, v, 10) else 600;
    const scale = if (args.next()) |v| try std.fmt.parseFloat(f32, v) else 1;
    if (args.next() != null) return error.TooManyArguments;
    if (n < 101 or n > max_samples or width == 0 or height == 0 or width > 3840 or height > 2160 or !std.math.isFinite(scale) or scale < 0.5 or scale > 4)
        return error.InvalidArguments;
    const full_pixels = try init.gpa.alloc(u32, sw.Framebuffer.len(width, height));
    defer init.gpa.free(full_pixels);
    const partial_pixels = try init.gpa.alloc(u32, sw.Framebuffer.len(width, height));
    defer init.gpa.free(partial_pixels);
    var full_fb = sw.Framebuffer.init(full_pixels, width, height, .rgba8);
    var partial_fb = sw.Framebuffer.init(partial_pixels, width, height, .rgba8);
    const scenarios = std.enums.values(Scenario);
    var results: [scenarios.len]Result = undefined;
    for (scenarios, &results) |scenario, *result| {
        app = .{};
        app.init();
        var ctx = try Context.init(&context_bytes, limits);
        var carver: lcgf.mem.Carver = .{ .buf = &Storage.bytes };
        var cache = host.Incremental.init(&carver, limits);
        var full_gfx: sw.Software = .{};
        var partial_gfx: sw.Software = .{};
        @memset(full_pixels, 0);
        @memset(partial_pixels, 0);
        var events: host.Events = .{ .in = .{
            .viewport = .{ @as(f32, @floatFromInt(width)) / scale, @as(f32, @floatFromInt(height)) / scale },
            .scale = scale,
        } };
        var damage_pixels: u64 = 0;
        var full_frames: u32 = 0;
        var glyph_frames: u32 = 0;
        var changed_pixel_frames: u32 = 0;
        var zero_damage_frames: u32 = 0;
        var previous_hash: u64 = 0;
        var sequence = std.hash.Wyhash.init(0);
        for (0..warmups + n) |step| {
            change(scenario, step, &events);
            if (scenario == .invalidation) cache.invalidate();
            const ui_start = std.Io.Timestamp.now(init.io, .awake);
            var f = ctx.begin(&events.in);
            app.build(&f, &events);
            const output = f.end(.{});
            std.mem.doNotOptimizeAway(output.tree);
            std.mem.doNotOptimizeAway(output.texts);
            std.mem.doNotOptimizeAway(output.draw);
            const ui_ns = elapsed(init.io, ui_start);
            if (!output.status.ok() or app.snapshot().command_overflow) return error.FrameDidNotFit;
            var full_ns: u64 = 0;
            var partial_ns: u64 = 0;
            var update: host.Update = undefined;
            // Hold each order for two frames. Scene states alternate every frame,
            // so each state must occur both first and second within a four-frame cycle.
            for (0..2) |phase| {
                if ((phase + step / 2) % 2 == 0) {
                    const start = std.Io.Timestamp.now(init.io, .awake);
                    host.draw(&app, &full_gfx, &full_fb, full_glyphs.borrow(), &output, scale, .black);
                    std.mem.doNotOptimizeAway(full_pixels.ptr);
                    full_ns = elapsed(init.io, start);
                } else {
                    const start = std.Io.Timestamp.now(init.io, .awake);
                    update = cache.draw(&app, &partial_gfx, &partial_fb, partial_glyphs.borrow(), &output, scale, .black);
                    std.mem.doNotOptimizeAway(partial_pixels.ptr);
                    partial_ns = elapsed(init.io, start);
                }
            }
            if (!std.mem.eql(u32, full_pixels, partial_pixels)) {
                for (full_pixels, partial_pixels, 0..) |a, b, i| if (a != b) {
                    std.debug.print("{s} step {d}, pixel {d}: full={x} incremental={x}\n", .{ @tagName(scenario), step, i, a, b });
                    break;
                };
                return error.IncrementalPixelsDiffer;
            }
            const pixel_hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(full_pixels));
            const marker: u64 = @intCast(step);
            sequence.update(std.mem.asBytes(&marker));
            sequence.update(std.mem.asBytes(&pixel_hash));
            if (step >= warmups) {
                const i = step - warmups;
                full_samples[i] = full_ns;
                partial_samples[i] = partial_ns;
                ui_samples[i] = ui_ns;
                damage_pixels += update.pixelCount();
                full_frames += @intFromBool(update.full);
                glyph_frames += @intFromBool(update.glyphs_rebuilt);
                changed_pixel_frames += @intFromBool(pixel_hash != previous_hash);
                zero_damage_frames += @intFromBool(update.len == 0);
            }
            previous_hash = pixel_hash;
        }
        // A named changing scenario must actually change visible output at the
        // chosen size/scale; otherwise its timing would silently measure idle work.
        if (scenario != .unchanged and scenario != .invalidation and changed_pixel_frames == 0)
            return error.ScenarioDidNotChangePixels;
        result.* = .{
            .scenario = @tagName(scenario),
            .ui = summarize(ui_samples[0..n]),
            .full_draw = summarize(full_samples[0..n]),
            .incremental_draw = summarize(partial_samples[0..n]),
            .mean_damage_pixels = damage_pixels / n,
            .mean_pixel_payload_bytes = damage_pixels * 4 / n,
            .full_frames = full_frames,
            .glyph_rebuild_frames = glyph_frames,
            .changed_pixel_frames = changed_pixel_frames,
            .zero_damage_frames = zero_damage_frames,
            .verified_frames = warmups + n,
            .pixel_hash = previous_hash,
            .pixel_sequence_hash = sequence.final(),
        };
    }
    const report = .{
        .metadata = .{
            .zig = builtin.zig_version_string,
            .optimize = @tagName(builtin.mode),
            .arch = @tagName(builtin.cpu.arch),
            .os = @tagName(builtin.os.tag),
            .cpu_target = builtin.cpu.model.name,
            .simd_lanes = lcgf.simd.lanes,
            .architecture = @tagName(application.options.architecture),
            .framework = @tagName(application.options.framework),
            .framework_revision = application.options.framework_revision,
            .samples = n,
            .warmup_frames = warmups,
            .retained_bytes = @sizeOf(host.Incremental) + Storage.bytes.len,
            .scope = "One shared UI build per input frame, excluding the scenario's preceding input/state mutation. Full/incremental draw order changes every two frames to decouple it from alternating scene states. Bytewise framebuffer equality and sequence hashing run after every frame outside timing. Pixel payload is a calculated byte count, not timed X11 transport.",
        },
        .width = width,
        .height = height,
        .scale = scale,
        .full_pixel_payload_bytes = @as(u64, width) * height * 4,
        .cases = results,
    };
    var buffer: [32 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try std.json.Stringify.value(report, .{ .whitespace = .indent_2 }, &writer);
    try writer.writeByte('\n');
    var out_buffer: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(init.io, &out_buffer);
    try out.interface.writeAll(writer.buffered());
    try out.interface.flush();
}
