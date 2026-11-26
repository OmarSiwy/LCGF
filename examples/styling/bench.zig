//! Reproducible Linux CPU measurements for the styling workload categories. Allocations occur
//! only before/after measured loops. Full software redraw is deliberate; damage is reported
//! separately so a host's incremental presentation policy cannot hide raster work.
const std = @import("std");
const lcgf = @import("lcgf");
const Context = lcgf.context.Context;
const Frame = lcgf.frame.Frame;
const Id = lcgf.types.Id;
const Color = lcgf.types.Color;
const Scene = enum { dense_static, theme_switch, sparse_motion, technical_canvas, effects_panel };
const frames = 129;
const width = 1280;
const height = 720;
const limits: lcgf.context.Limits = .{ .nodes = 1024, .texts = 1, .customs = 1, .strings = 1, .anims = 32, .tweens = 1, .flips = 1, .signals = 1, .depth = 8, .timers = 1, .memos = 1 };
var context_memory: [Context.requiredBytes(limits)]u8 align(lcgf.mem.column_align) = undefined;
var damage_memory: [128 * 1024]u8 align(lcgf.mem.column_align) = undefined;
var framebuffer_pixels: [lcgf.render_sw.Framebuffer.len(width, height)]u32 = undefined;
const phase_names = [_][]const u8{ "build_and_input", "layout", "paint_and_damage", "software_raster", "frame" };
const Result = struct {
    scene: Scene,
    samples: [phase_names.len][frames]u64 = undefined,
    nodes: u32 = 0,
    commands: u32 = 0,
    dirty_pixels: f64 = 0,
    peak_offscreen_bytes: usize = 0,
    passes: u32 = 0,
    output_checksum: u32 = 0,
};
fn now() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}
fn build(f: *Frame, scene: Scene, frame: u32) !void {
    if (scene == .technical_canvas) {
        var placements: [4]lcgf.special_layout.Placement = undefined;
        const sidebar: f32 = if (frame % 64 < 32) 200 else 260;
        _ = try lcgf.special_layout.dock(.{ .x1 = width, .y1 = height }, &.{ .{ .size = .{ width, 38 } }, .{ .size = .{ sidebar, height } }, .{ .size = .{ width, 28 } }, .{ .size = .{ width, height } } }, &.{ .top, .left, .bottom, .fill }, 4, &placements);
        for (placements[0..3], 0..) |placement, i| _ = f.leaf(Id.from("dock").with(@intCast(i)), lcgf.special_layout.style(placement, .{ .fill = .rgb(31, 44, 62) }, .{ 0, 0 }));
        var canvas_style = lcgf.special_layout.style(placements[3], .{ .fill = .rgb(14, 20, 30), .clip = true }, .{ 0, 0 });
        canvas_style.radius = 8;
        _ = f.open(Id.from("canvas"), canvas_style);
        const zoom = 1 + @as(f32, @floatFromInt(frame % 60)) / 180;
        _ = f.open(Id.from("canvas-content"), .{ .size = .{ .px(1800), .px(1100) }, .transform = .{ zoom, 0, 0, zoom, -@as(f32, @floatFromInt(frame)) * 2, -12 } });
        for (0..60) |i| {
            const at: f32 = @floatFromInt(i * 30);
            _ = f.leaf(Id.from("grid-x").with(@intCast(i)), .{ .float = true, .offset = .{ at, 0 }, .size = .{ .px(1), .px(1100) }, .fill = .rgb(38, 52, 70) });
            _ = f.leaf(Id.from("grid-y").with(@intCast(i)), .{ .float = true, .offset = .{ 0, at }, .size = .{ .px(1800), .px(1) }, .fill = .rgb(38, 52, 70) });
        }
        for (0..160) |i| _ = f.leaf(Id.from("symbol").with(@intCast(i)), .{ .float = true, .offset = .{ @floatFromInt(15 + (i % 20) * 78), @floatFromInt(15 + (i / 20) * 88) }, .size = .{ .px(56), .px(48) }, .fill = .rgba(42, 127, 149, 230), .border = 1, .border_color = .rgb(112, 211, 202), .radius = 4 });
        f.close();
        f.close();
        return;
    }
    const environment: lcgf.style.environment.Environment = .{ .dark = if (scene == .theme_switch) frame % 2 == 0 else true };
    const model = lcgf.theme_recipes.model;
    const tokens = model.tokenRows(if (environment.dark.?) lcgf.theme.dark else lcgf.theme.light, environment);
    const scopes = [_]lcgf.style.tokens.Scope{.{ .entries = &tokens }};
    for (0..768) |i| {
        const id = Id.from("control").with(@intCast(i));
        var style = (try model.button.resolve(model.Parts.root, .{ .tokens = .{ .scopes = &scopes }, .environment = environment, .states = .{ .selected = i % 17 == 0 } }, null)).box;
        style.float = true;
        style.size = .{ .px(34), .px(23) };
        style.offset = .{ @floatFromInt(6 + (i % 32) * 39), @floatFromInt(6 + (i / 32) * 29) };
        if (scene == .sparse_motion and i < 8) style.offset[0] += f.animate(id.with(1), if (frame % 64 < 32) 0 else 12, .{});
        const node = f.leaf(id, style);
        _ = f.interact(node, .button);
    }
}
fn frameBench(scene: Scene) !Result {
    var result: Result = .{ .scene = scene };
    var ctx = try Context.init(&context_memory, limits);
    var carver: lcgf.mem.Carver = .{ .buf = &damage_memory };
    var damage = lcgf.damage.Damage.init(&carver, limits.nodes);
    var fb = lcgf.render_sw.Framebuffer.init(&framebuffer_pixels, width, height, .rgba8);
    var software: lcgf.render_sw.Setup = .{};
    for (0..frames) |k| {
        var times: [5]u64 = undefined;
        times[0] = now();
        var frame = ctx.begin(&.{ .viewport = .{ width, height }, .time = @as(f64, @floatFromInt(k)) / 60 });
        try build(&frame, scene, @intCast(k));
        times[1] = now();
        try frame.layoutRounded(.{}, .{ .mode = .nearest, .scale = 1 });
        times[2] = now();
        const output = frame.finish();
        if (!output.status.ok()) return error.InsufficientBenchmarkCapacity;
        _ = damage.frame(output.tree, output.texts, &ctx.customs[ctx.cur], "");
        const damaged = lcgf.damage.Region.scissor(damage.region.bounds(), .{ width, height }, 1);
        times[3] = now();
        software.draw(&fb, output.draw, .{}, .rgb(10, 16, 24), 1);
        times[4] = now();
        for (0..4) |p| result.samples[p][k] = times[p + 1] - times[p];
        result.samples[4][k] = times[4] - times[0];
        if (k != 0) result.dirty_pixels += @floatFromInt(@as(u64, damaged[2]) * damaged[3]);
        result.nodes = output.tree.len;
        result.commands = output.draw.cmd_len;
        result.output_checksum +%= framebuffer_pixels[(k * 7919) % framebuffer_pixels.len];
    }
    result.dirty_pixels /= frames - 1;
    return result;
}
fn effectBench(a: std.mem.Allocator) !Result {
    var result: Result = .{ .scene = .effects_panel };
    const ew = 320;
    const eh = 180;
    const count = try lcgf.surface.requiredPixels(ew, eh);
    const raw = try a.alloc(u32, count * 6);
    defer a.free(raw);
    var images: [6]lcgf.surface.Surface = undefined;
    for (&images, 0..) |*dst, i| dst.* = try lcgf.surface.init(raw[i * count ..][0..count], ew, eh);
    var kernel: [64]f32 = undefined;
    const nodes = [_]lcgf.effects.Node{
        .{ .operation = .{ .blur_xy = .{ .sigma = .{ 3, 1 } } } },
        .{ .a = .{ .node = 0 }, .operation = .{ .matrix = lcgf.compositor.saturate(0.4) } },
        .{ .a = .{ .node = 1 }, .b = .{ .external = 0 }, .operation = .{ .composite = .{ .opacity = 0.55, .blend = .screen } } },
    };
    for (0..frames) |k| {
        const start = now();
        const stops = [_]lcgf.brushes.Stop{ .{ .position = 0, .color = .{ 0.1, 0.8, 0.7, 1 } }, .{ .position = 1, .color = .{ 0.8, 0.2, 0.6, 0.8 } } };
        var segments: [2]lcgf.brushes.Segment = undefined;
        const ramp = try lcgf.brushes.prepareStops(&stops, &segments, .{}, .pad);
        const shift: f32 = @floatFromInt(k % 32);
        try lcgf.decoration.rasterize(images[0], .{ .rect = .{ .x1 = ew, .y1 = eh }, .radii = @splat(.{ 16, 16 }) }, .{ .backgrounds = &.{.{ .brush = .{ .linear = .{ .from = .{ shift, 0 }, .to = .{ 320 + shift, 180 }, .ramp = ramp } } }} }, .{});
        const source_done = now();
        const report = try lcgf.effects.run(&nodes, &.{images[0].view()}, .{ .outputs = images[1..4], .work = images[4..6].*, .kernel = &kernel }, .{});
        const end = now();
        result.samples[0][k] = 0;
        result.samples[1][k] = 0;
        result.samples[2][k] = source_done - start;
        result.samples[3][k] = end - source_done;
        result.samples[4][k] = end - start;
        result.passes = report.passes + 1;
        result.peak_offscreen_bytes = raw.len * 4 + @sizeOf(@TypeOf(kernel));
        result.output_checksum +%= report.image.pixels[(k * 7919) % report.image.pixels.len];
    }
    result.dirty_pixels = ew * eh;
    return result;
}
fn us(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1000;
}
pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const path = args.next() orelse "styling-benchmark.json";
    if (args.next() != null) return error.UnexpectedArgument;
    var json: std.Io.Writer.Allocating = .init(init.gpa);
    defer json.deinit();
    const w = &json.writer;
    try w.print("{{\"toolchain\":\"{s}\",\"backend\":\"CPU software full redraw\",\"scale\":1,\"warm_frames\":{d},\"explicit_allocations_per_measured_frame\":0,\"context_bytes\":{d},\"context_node_capacity\":{d},\"quad_bytes\":{d},\"look_bytes\":{d},\"scenes\":[", .{ @import("builtin").zig_version_string, frames - 1, context_memory.len, limits.nodes, @sizeOf(lcgf.draw_list.Quad), @sizeOf(lcgf.tree.Look) });
    for (std.enums.values(Scene), 0..) |scene, i| {
        var result = if (scene == .effects_panel) try effectBench(init.gpa) else try frameBench(scene);
        try w.print("{s}{{\"name\":\"{s}\",\"resolution\":[{d},{d}],\"nodes\":{d},\"draw_commands\":{d},\"mean_damage_bbox_pixels\":{d:.2},\"peak_offscreen_bytes\":{d},\"surface_passes\":{d},\"checksum\":{d},\"phases\":{{", .{ if (i == 0) "" else ",", @tagName(scene), if (scene == .effects_panel) @as(u32, 320) else width, if (scene == .effects_panel) @as(u32, 180) else height, result.nodes, result.commands, result.dirty_pixels, result.peak_offscreen_bytes, result.passes, result.output_checksum });
        for (phase_names, &result.samples, 0..) |name, *samples, p| {
            const first = samples[0];
            std.mem.sort(u64, samples[1..], {}, std.sort.asc(u64));
            try w.print("{s}\"{s}\":{{\"first_frame_us\":{d:.3},\"p50_us\":{d:.3},\"p95_us\":{d:.3},\"p99_us\":{d:.3}}}", .{ if (p == 0) "" else ",", name, us(first), us(samples[1 + (frames - 1) / 2]), us(samples[1 + (frames - 1) * 95 / 100]), us(samples[1 + (frames - 1) * 99 / 100]) });
        }
        try w.writeAll("}}");
    }
    try w.writeAll("]}\n");
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = json.writer.buffered() });
}
