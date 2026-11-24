//! Comparable architecture and end-to-end CPU benchmarks. No window server or GPU.
//! Output includes percentile samples, observed state, and a hash of the actual pixels.
const std = @import("std");
const builtin = @import("builtin");
const lcgf = @import("lcgf");
const application = @import("app");
const host = @import("host");
const Context = lcgf.context.Context;
const Output = lcgf.context.Output;
const Events = lcgf.shell_iface.Events;
const limits = application.limits;
const max_samples = 2001;
const ui_batch = 8;

var storage: [Context.requiredBytes(limits)]u8 align(lcgf.mem.column_align) = undefined;
var glyph_quads: [limits.strings]lcgf.draw_list.Quad = undefined;
var first: [limits.texts]u32 = undefined;
var count: [limits.texts]u32 = undefined;
var samples: [max_samples]u64 = undefined;
var app: application.App = .{};

const Stats = struct {
    median_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
    min_ns: u64,
    max_ns: u64,
    samples: usize,
    iterations_per_sample: u32,
};

fn summarize(values: []u64, batch: u32) Stats {
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    return .{
        .median_ns = values[(values.len * 50 + 99) / 100 - 1] / batch,
        .p95_ns = values[(values.len * 95 + 99) / 100 - 1] / batch,
        .p99_ns = values[(values.len * 99 + 99) / 100 - 1] / batch,
        .min_ns = values[0] / batch,
        .max_ns = values[values.len - 1] / batch,
        .samples = values.len,
        .iterations_per_sample = batch,
    };
}

fn elapsed(io: std.Io, start: std.Io.Timestamp) u64 {
    return @intCast(start.durationTo(std.Io.Timestamp.now(io, .awake)).toNanoseconds());
}

fn frame(ctx: *Context, instance: anytype, events: *const Events) !Output {
    var f = ctx.begin(&events.in);
    instance.build(&f, events);
    const output = f.end(.{});
    if (!output.status.ok()) return error.FrameCapacityExceeded;
    if (instance.snapshot().command_overflow) return error.CommandCapacityExceeded;
    // Escape the pointed-to memory, not just counts; all layout/draw output stays observable.
    std.mem.doNotOptimizeAway(output.draw);
    std.mem.doNotOptimizeAway(output.tree);
    return output;
}

const ArchitectureResult = struct {
    name: []const u8,
    app_bytes: usize,
    ui_nodes: u32,
    records: u32,
    warm_ui: Stats,
    changed_filter_ui: Stats,
    checksum: u64,
};

fn architectureBench(comptime App: type, name: []const u8, io: std.Io, n: usize) !ArchitectureResult {
    // Each specialization owns one stationary application; no owner is copied into a handle.
    const Fixture = struct {
        var instance: App = .{};
    };
    const instance = &Fixture.instance;
    instance.* = .{};
    instance.init();
    var ctx = try Context.init(&storage, limits);
    const events: Events = .{};
    var output: Output = undefined;
    var checksum: u64 = 0;
    for (0..100) |_| output = try frame(&ctx, instance, &events);
    for (samples[0..n]) |*sample| {
        const start = std.Io.Timestamp.now(io, .awake);
        for (0..ui_batch) |_| {
            output = try frame(&ctx, instance, &events);
            checksum +%= output.tree.len + output.draw.cmd_len;
        }
        sample.* = elapsed(io, start);
    }
    const warm = summarize(samples[0..n], ui_batch);
    const nodes = output.tree.len;
    for (0..20) |i| {
        _ = instance.commit(&.{.{ .navigate = if (i % 2 == 0) .running else .completed }}, &.{}, &.{});
        _ = try frame(&ctx, instance, &events);
    }
    for (samples[0..n], 0..) |*sample, i| {
        const start = std.Io.Timestamp.now(io, .awake);
        _ = instance.commit(&.{.{ .navigate = if (i % 2 == 0) .running else .completed }}, &.{}, &.{});
        output = try frame(&ctx, instance, &events);
        sample.* = elapsed(io, start);
        checksum +%= instance.snapshot().visible_count;
    }
    return .{
        .name = name,
        .app_bytes = @sizeOf(App),
        .ui_nodes = nodes,
        .records = instance.snapshot().total,
        .warm_ui = warm,
        .changed_filter_ui = summarize(samples[0..n], 1),
        .checksum = checksum,
    };
}

fn emit(init: std.process.Init, path: ?[]const u8, value: anytype) !void {
    var json_buffer: [32 * 1024]u8 = undefined;
    var json = std.Io.Writer.fixed(&json_buffer);
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &json);
    try json.writeByte('\n');
    if (path) |p| try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = p, .data = json.buffered() });
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    try stdout.interface.writeAll(json.buffered());
    try stdout.interface.flush();
}

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    var width: u32 = 800;
    var height: u32 = 600;
    var scale: f32 = 1;
    var n: usize = 301;
    var path: ?[]const u8 = null;
    var architectures = false;
    var architecture_start: usize = 0;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--architectures")) {
            architectures = true;
        } else if (std.mem.eql(u8, arg, "--architecture-start")) {
            architecture_start = try std.fmt.parseInt(usize, args.next() orelse return error.MissingArgument, 10);
        } else if (std.mem.eql(u8, arg, "--width")) {
            width = try std.fmt.parseInt(u32, args.next() orelse return error.MissingArgument, 10);
        } else if (std.mem.eql(u8, arg, "--height")) {
            height = try std.fmt.parseInt(u32, args.next() orelse return error.MissingArgument, 10);
        } else if (std.mem.eql(u8, arg, "--scale")) {
            scale = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--samples")) {
            n = try std.fmt.parseInt(usize, args.next() orelse return error.MissingArgument, 10);
        } else if (std.mem.eql(u8, arg, "--json")) {
            path = args.next() orelse return error.MissingArgument;
        } else return error.UnknownArgument;
    }
    if (n < 101 or n > max_samples or width == 0 or height == 0 or width > 3840 or height > 2160 or !std.math.isFinite(scale) or scale < 0.5 or scale > 4) return error.InvalidArgument;
    if (architectures and (width != 800 or height != 600 or scale != 1)) return error.ArchitectureComparisonRequires800x600AtScale1;
    const metadata = .{
        .zig = builtin.zig_version_string,
        .optimize = @tagName(builtin.mode),
        .arch = @tagName(builtin.cpu.arch),
        .os = @tagName(builtin.os.tag),
        .cpu_target = builtin.cpu.model.name,
        .simd_lanes = lcgf.simd.lanes,
        .framework = @tagName(application.options.framework),
        .framework_revision = application.options.framework_revision,
        .context_bytes = storage.len,
        .warmup_frames = 100,
        .filter_warmup_transitions = 20,
        .ui_distribution = "Percentiles of 8-frame batch averages, not individual-frame tail latency",
        .idle_distribution = "Percentiles of 1000 scheduler-call batch averages",
    };
    if (architectures) {
        var results: [5]ArchitectureResult = undefined;
        for (&results, 0..) |*result, i| {
            result.* = switch ((i + architecture_start % 5) % 5) {
                0 => try architectureBench(application.Viper, "viper", init.io, n),
                1 => try architectureBench(application.Mvp, "mvp", init.io, n),
                2 => try architectureBench(application.Mvvp, "mvvp", init.io, n),
                3 => try architectureBench(application.Mvvm, "mvvm", init.io, n),
                4 => try architectureBench(application.MvvmC, "mvvm_c", init.io, n),
                else => unreachable,
            };
        }
        return emit(init, path, .{ .metadata = metadata, .scope = "800x600 CPU UI preparation; changed_filter_ui includes a 100000-row projection rebuild", .architectures = results });
    }

    var ctx = try Context.init(&storage, limits);
    app.init();
    const events: Events = .{ .in = .{ .viewport = .{ @as(f32, @floatFromInt(width)) / scale, @as(f32, @floatFromInt(height)) / scale }, .scale = scale } };
    const pixels = try init.gpa.alloc(u32, lcgf.render_sw.Framebuffer.len(width, height));
    defer init.gpa.free(pixels);
    @memset(pixels, 0);
    var fb = lcgf.render_sw.Framebuffer.init(pixels, width, height, .rgba8);
    var gfx: lcgf.render_sw.Software = .{};
    const glyphs: host.Glyphs = .{ .quads = &glyph_quads, .first = &first, .count = &count };
    var output: Output = undefined;
    var checksum: u64 = 0;
    for (0..100) |_| {
        output = try frame(&ctx, &app, &events);
        host.draw(&app, &gfx, &fb, glyphs, &output, scale, .rgb(0, 0, 0));
    }
    for (samples[0..n]) |*sample| {
        const start = std.Io.Timestamp.now(init.io, .awake);
        for (0..ui_batch) |_| {
            output = try frame(&ctx, &app, &events);
            checksum +%= output.tree.len + output.draw.cmd_len;
        }
        sample.* = elapsed(init.io, start);
    }
    const ui = summarize(samples[0..n], ui_batch);
    for (samples[0..n]) |*sample| {
        const start = std.Io.Timestamp.now(init.io, .awake);
        host.draw(&app, &gfx, &fb, glyphs, &output, scale, .rgb(0, 0, 0));
        std.mem.doNotOptimizeAway(pixels.ptr);
        sample.* = elapsed(init.io, start);
    }
    const render = summarize(samples[0..n], 1);
    const raster_hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(pixels));
    for (samples[0..n]) |*sample| {
        const start = std.Io.Timestamp.now(init.io, .awake);
        output = try frame(&ctx, &app, &events);
        host.draw(&app, &gfx, &fb, glyphs, &output, scale, .rgb(0, 0, 0));
        std.mem.doNotOptimizeAway(pixels.ptr);
        sample.* = elapsed(init.io, start);
        checksum +%= output.tree.len + output.draw.cmd_len;
    }
    const full = summarize(samples[0..n], 1);
    const full_hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(pixels));
    if (full_hash != raster_hash) return error.PixelHashChangedDuringStaticWorkload;
    var requested: u32 = 0;
    const idle_batch = 1000;
    for (samples[0..n]) |*sample| {
        const start = std.Io.Timestamp.now(init.io, .awake);
        for (0..idle_batch) |_| {
            // A real poll can observe new input and externally posted wake flags.
            std.mem.doNotOptimizeAway(&ctx);
            std.mem.doNotOptimizeAway(&events);
            requested += @intFromBool(ctx.needsFrame(&events.in));
        }
        sample.* = elapsed(init.io, start);
    }
    if (requested != 0) return error.IdleDidNotSettle;
    try emit(init, path, .{
        .metadata = metadata,
        .architecture = @tagName(application.options.architecture),
        .scope = "CPU UI and actual software pixels; excludes X11 transfer, GPU work, input-to-display latency and vsync",
        .width = width,
        .height = height,
        .scale = scale,
        .records = app.snapshot().total,
        .ui_nodes = output.tree.len,
        .app_bytes = @sizeOf(application.App),
        .ui = ui,
        .software_draw = render,
        .full_cpu_frame = full,
        .idle_scheduler = summarize(samples[0..n], idle_batch),
        .idle_requested_frames = requested,
        .pixel_hash = full_hash,
        .checksum = checksum,
    });
}
