//! The Zig side of the runtime front end's gate (bindings/check/run.sh): bench/scenes/' scenes
//! built with `Context` and `Frame` in Zig, every frame, in the dump format of dump.zig.
//!
//!   lcgf-rt-dump <form|list|text|springs|resize|idle|kit> <frames> <out.bin> [nodes depth]
//!
//! `kit` is the gate's own scene (`Kit`): formatted text, the widgets by options, and springs
//! and tweens on a colour and an array, as C++ and Rust write them. `canvas` (`Plot`) is a
//! canvas batch built through lcgf.h's builders, drawn in two canvas nodes under a moving
//! camera, edited and hit-tested: after each frame's draw list, the batch's length and the row
//! hit at the pointer.
//!
//! `nodes depth` shrink the limits, so the tree and the stack overflow and the rows the
//! bindings push inline take the overflow paths too.
//!   lcgf-rt-dump rows <count> <out.bin>
//!
//! `rows` writes a sweep of styles, each as its 50 lcgf_style words then the 55 lcgf_row words
//! `Template.from` makes of it: the rows C++'s `lcgf::Row` and Rust's `Row::from` must equal.

const std = @import("std");
const lcgf = @import("lcgf");
const scenes = @import("scenes");
const Context = lcgf.context.Context;

const capacity = [_]u32{ 256, 256, 256, 2048, 256, 256 };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.next();
    const name = args.next() orelse return error.Usage;
    const frames = try std.fmt.parseInt(u32, args.next() orelse return error.Usage, 10);
    const out_path = args.next() orelse return error.Usage;
    if (std.mem.eql(u8, name, "rows")) {
        const words = try rowSweep(arena, frames);
        return std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = out_path, .data = std.mem.sliceAsBytes(words) });
    }
    const plot_scene = std.mem.eql(u8, name, "canvas");
    const kit_scene = plot_scene or std.mem.eql(u8, name, "kit");
    const k_scene = if (kit_scene) 0 else for (scenes.vs, 0..) |s, k| {
        if (std.mem.eql(u8, s.name, name)) break k;
    } else return error.UnknownScene;
    const s = &scenes.vs[k_scene];
    var kit: Kit = .{};
    const n: u32 = if (kit_scene) 64 else capacity[k_scene];
    var limits: lcgf.context.Limits = .{ .nodes = n, .texts = n, .strings = 32 * 1024, .anims = n };
    if (args.next()) |nodes| {
        limits.nodes = try std.fmt.parseInt(u32, nodes, 10);
        limits.depth = try std.fmt.parseInt(u32, args.next() orelse return error.Usage, 10);
    }
    const buf = try arena.alignedAlloc(u8, .fromByteUnits(lcgf.mem.column_align), Context.requiredBytes(limits));
    var ctx = try Context.init(buf, limits);
    const plot = try arena.create(Plot);
    if (plot_scene) {
        const rows = try arena.alloc(lcgf.draw_list.CanvasDraw, 2 * limits.customs);
        ctx.enableCanvas(rows);
        plot.init();
    }
    const th: lcgf.widgets_base.Theme = .{};
    var in: lcgf.input.Input = .{};
    var out: std.ArrayList(u8) = .empty;
    for (0..frames) |k| {
        if (plot_scene) Plot.input(&in, @intCast(k)) else if (kit_scene) Kit.input(&in, @intCast(k)) else s.input(&in, @intCast(k));
        // The bench scenes only hover; the gate also presses, so clicks and drags cross too.
        in.buttons = .{ .left = k % 6 < 2 };
        // Whether a frame is needed crosses the seam too (an `int` in lcgf.h).
        try out.appendSlice(arena, std.mem.asBytes(&@as(u32, @intFromBool(ctx.needsFrame(&in)))));
        var f = ctx.begin(&in);
        if (plot_scene) plot.build(&f, @intCast(k)) else if (kit_scene) kit.build(&f, &th, @intCast(k)) else s.build(&f, &th);
        const o = f.end(.{});
        const d = o.draw;
        const put = struct {
            fn put(g: std.mem.Allocator, l: *std.ArrayList(u8), v: u32) !void {
                try l.appendSlice(g, std.mem.asBytes(&v));
            }
        }.put;
        try put(arena, &out, d.quad_len);
        try out.appendSlice(arena, std.mem.sliceAsBytes(d.quads[0..d.quad_len]));
        try put(arena, &out, d.run_len);
        try out.appendSlice(arena, std.mem.sliceAsBytes(d.runs[0..d.run_len]));
        try put(arena, &out, @intCast(d.strings.len));
        try out.appendSlice(arena, d.strings);
        try put(arena, &out, d.cmd_len);
        for (0..d.cmd_len) |i| {
            try put(arena, &out, d.cmd.kind[i]);
            try put(arena, &out, d.cmd.first[i]);
            try put(arena, &out, d.cmd.count[i]);
            try put(arena, &out, d.cmd.key[i]);
        }
        try put(arena, &out, d.custom_len);
        const at = out.items.len;
        try out.appendSlice(arena, std.mem.sliceAsBytes(d.customs[0..d.custom_len]));
        // A canvas's damage key hashes the batch's address, which differs between processes.
        if (plot_scene) for (0..d.custom_len) |i| {
            @memset(out.items[at + i * @sizeOf(lcgf.draw_list.CustomDraw) + @offsetOf(lcgf.draw_list.CustomDraw, "data") ..][0..8], 0);
        };
        try put(arena, &out, 0xffff_ffff);
        try put(arena, &out, 0xffff_ffff);
        try put(arena, &out, @bitCast(o.wake));
        if (plot_scene) {
            try put(arena, &out, plot.s.len);
            const pal = plot.palette(@intCast(k));
            const hit = lcgf.canvas.hit(&plot.s, &pal, Plot.camera(@intCast(k)), &plot.all, in.pointer, 2);
            try put(arena, &out, hit orelse 0xffff_ffff);
            plot.s.clearDirty();
        }
    }
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = out_path, .data = out.items });
}

/// The gate's scene for what lcgf.h's runtime functions add to the reference widgets: a label
/// formatted into the frame (`lcgf_rt_label_written`), a text leaf (`lcgf_rt_text_written`),
/// the widgets, a colour and an array on springs, a tween. Floats are formatted at values every
/// language writes alike (quarters).
const Kit = struct {
    on: bool = false,
    gain: f32 = 1,

    fn input(in: *lcgf.input.Input, k: u32) void {
        in.viewport = .{ 400, 300 };
        in.pointer = .{ @as(f32, @floatFromInt((k * 13) % 400)) + 0.5, @as(f32, @floatFromInt((k * 7) % 120)) + 0.5 };
        in.dt = 1.0 / 60.0;
    }

    fn build(kit: *Kit, f: *lcgf.frame.Frame, th: *const lcgf.widgets_base.Theme, k: u32) void {
        const w = lcgf.widgets_base;
        _ = f.open(.from("kit"), .{ .pad = @splat(8), .gap = 4 });
        _ = f.textf("Frame {d}: {d:.2}", .{ k, @as(f32, @floatFromInt(k)) * 0.25 }, w.labelText(th));
        _ = f.textf("items {d}", .{k % 7}, .{ .px = 16, .color = .rgb(255, 200, 0) });
        _ = w.button(f, th, .from("save"), "Save");
        _ = w.checkbox(f, th, .from("loud"), &kit.on, "Loud");
        _ = w.slider(f, th, .from("gain"), &kit.gain, 0, 4);
        const phase = (k / 30) % 2 == 0;
        const ink_to: lcgf.types.Color = if (phase) .rgb(200, 40, 40) else .rgb(40, 40, 200);
        const ink = f.animate(.from("ink"), ink_to, .{});
        const box = f.animate(.from("box"), [2]f32{ if (phase) 40 else 90, 12 }, .{});
        const bar = f.tween(.from("slide"), @as(f32, if ((k / 45) % 2 == 0) 20 else 120), 0.5, .out_cubic);
        _ = f.leaf(.from("swatch"), .{ .size = .{ .px(box[0]), .px(box[1]) }, .fill = ink });
        _ = f.leaf(.from("bar"), .{ .size = .{ .px(bar), .px(6) }, .fill = .rgb(90, 90, 90) });
        // The styling rows through the bindings' inline push: a parent that cycles through all,
        // hidden (layout only) and collapsed participation, under it a child with extras, a
        // floating ring painted from it, a transformed child and a plain one that inherits.
        const part: lcgf.types.Participation = switch ((k / 20) % 3) {
            0 => .all,
            1 => .hidden,
            else => .collapsed,
        };
        _ = f.open(.from("styled"), .{ .dir = .x, .gap = 4, .participation = part, .cursor = .pointer });
        const card = f.leaf(.from("card"), .{ .size = .{ .px(40), .px(20) }, .fill = .rgb(60, 120, 60), .radii = .{ 2, 6, 2, 6 } });
        _ = f.leaf(.from("ring"), .{ .float = true, .paint_reference = card.ix(), .paint_outset = @splat(2), .border = 1, .border_color = .rgb(240, 240, 240) });
        _ = f.leaf(.from("tilt"), .{ .size = .{ .px(20), .px(20) }, .fill = .rgb(120, 60, 60), .transform = .{ 1, 0.25, 0, 1, 0, 0 }, .transform_origin = .{ 0, 0 } });
        _ = f.leaf(.from("plain"), .{ .size = .{ .px(10), .px(10) }, .fill = .rgb(60, 60, 120) });
        f.close();
        f.close();
    }
};

/// The gate's canvas scene: rt_check.cpp's and rt_check.rs's `Plot` build the same batch
/// through lcgf.h's builders. Values are ones every language computes alike (quarters).
const Plot = struct {
    const canvas = lcgf.canvas;
    buf: [canvas.Instances.requiredBytes(32, 16, 8)]u8 align(lcgf.mem.column_align) = undefined,
    s: canvas.Instances = undefined,
    all: [1]canvas.Range = undefined,
    const layers = [_]canvas.Layer{
        .of(.{ .stroke = .rgb(230, 230, 230), .width = 1 }),
        .of(.{ .stroke = .rgb(90, 200, 255), .fill = .rgba(40, 90, 160, 180), .width = 1.5 }),
        .of(.{ .stroke = .rgb(255, 120, 60), .fill = .rgb(255, 200, 60), .width = 2, .fill_on = false }),
    };
    const marks = [_]canvas.Override{.{ .range = .{ .first = 2, .count = 3 }, .color = 0xff00ff80 }};
    const sub = [_]canvas.Range{.{ .first = 1, .count = 4 }};

    fn init(p: *Plot) void {
        var carver: lcgf.mem.Carver = .{ .buf = &p.buf };
        p.s = .init(&carver, 32, 16, 8);
        const s = &p.s;
        for (0..8) |i| {
            const x: i32 = @intCast(i * 100);
            _ = s.segment(.{ x, 0 }, .{ x + 80, @intCast(50 * (i % 3)) }, .{ .weight = @intCast(i % 4 + 1), .cap = @fromBackingInt(@intCast(i % 3)), .dash = @intCast((i % 2) * 2) });
        }
        _ = s.polyline(&.{ .{ 0, 200 }, .{ 150, 260 }, .{ 300, 200 }, .{ 450, 300 } }, .{ .dash = 1, .cap = .round });
        _ = s.rect(.{ 500, 0 }, .{ 700, 150 }, .{ .layer = 1, .radius = 20 });
        _ = s.circle(.{ 800, 100 }, 60, .{ .layer = 2 });
        _ = s.arc(.{ 100, 400 }, 80, .{ .layer = 1, .start = 0.5, .sweep = 4, .cap = .round, .dash = 2 });
        _ = s.polygon(&.{ .{ 300, 350 }, .{ 500, 380 }, .{ 420, 500 }, .{ 350, 450 } }, .{ .layer = 1, .stroke = true });
        _ = s.glyphs("Hi", .{ 600, 400 }, .{ .px = 40, .turns = 1 });
        p.all = .{s.since(0)};
    }

    fn input(in: *lcgf.input.Input, k: u32) void {
        in.viewport = .{ 400, 300 };
        in.pointer = .{ @as(f32, @floatFromInt((k * 17) % 400)) + 0.5, @as(f32, @floatFromInt((k * 11) % 300)) + 0.5 };
        in.dt = 1.0 / 60.0;
    }

    fn camera(k: u32) canvas.Camera {
        return .{ .origin = .{ @intCast(k * 7), -@as(i64, k * 3) }, .scale = 0.5 + 0.25 * @as(f32, @floatFromInt(k % 4)), .offset = .{ 10, 10 }, .zoom = @floatFromInt(1 + k % 3) };
    }

    fn palette(_: *const Plot, k: u32) canvas.Palette {
        return .{ .layers = &layers, .zoom_scale = k % 2 == 1 };
    }

    fn build(p: *Plot, f: *lcgf.frame.Frame, k: u32) void {
        if (k % 10 == 9) p.s.kill((k / 10) % p.s.len);
        const pal = &palettes[k % 2];
        _ = f.open(.from("plot-root"), .{ .size = .{ .fill, .fill } });
        _ = f.canvas(.from("plot"), .{ .size = .{ .fill, .fill } }, &p.s, .{ .camera = camera(k), .palette = pal, .ranges = &p.all, .overrides = &marks });
        _ = f.canvas(.from("overlay"), .{ .float = true, .size = .{ .px(120), .px(80) } }, &p.s, .{ .camera = camera(k), .palette = pal, .ranges = &sub });
        f.close();
    }

    const palettes = [2]canvas.Palette{ .{ .layers = &layers }, .{ .layers = &layers, .zoom_scale = true } };
};

const plan = lcgf.abi_plan;
const Style = lcgf.types.Style;
const Template = lcgf.tree.Template;
const style_words = plan.wordsOf(Style);
const row_words = plan.wordsOf(Template);

/// Styles with each field off its default half the time, drawn from values that reach every
/// branch of `Template.from`: each size kind, ties, signed zeros, infinities, NaN, textures with
/// and without a fill, negative and set corners.
fn rowSweep(arena: std.mem.Allocator, count: u32) ![]u32 {
    comptime std.debug.assert(style_words == 59 and row_words == 66);
    const floats = [_]f32{ 0, -0.0, 1, -1, 0.5, 8, 123.25, -7, std.math.inf(f32), -std.math.inf(f32), std.math.nan(f32), 1e-30, 3e38, 2 };
    const colors = [_]u32{ 0, 0xffffffff, 0x00ff8040, 0x80102030, 0x01000000, 0x00ffffff };
    var rng = std.Random.DefaultPrng.init(0x1a47_2cab);
    const r = rng.random();
    const out = try arena.alloc(u32, count * (style_words + row_words));
    var defaults: [style_words]u32 = undefined;
    plan.put(Style, .{}, &defaults);
    for (0..count) |k| {
        const w = out[k * (style_words + row_words) ..][0..style_words];
        w.* = defaults;
        for (0..style_words) |i| {
            if (r.boolean()) continue;
            w[i] = switch (i) {
                0 => r.uintLessThan(u32, 16), // participation bits
                1 => if (r.boolean()) std.math.maxInt(u32) else r.uintLessThan(u32, @typeInfo(lcgf.types.Cursor).@"enum".field_names.len), // cursor
                2, 18, 19, 22 => r.uintLessThan(u32, 2), // dir, shrink, float, clip
                3, 5 => r.uintLessThan(u32, 4), // size kind
                16, 17 => r.uintLessThan(u32, 3), // main, cross
                25, 26 => colors[r.uintLessThan(usize, colors.len)], // fill, border_color
                29, 30 => if (r.boolean()) 0 else r.uintLessThan(u32, 0x10000), // texture, material
                52 => if (r.boolean()) std.math.maxInt(u32) else r.uintLessThan(u32, 64), // paint_reference
                57 => r.uintLessThan(u32, 8), // role
                else => @bitCast(floats[r.uintLessThan(usize, floats.len)]),
            };
        }
        const st = plan.get(Style, w);
        plan.put(Template, .from(&st), out[k * (style_words + row_words) + style_words ..][0..row_words]);
    }
    return out;
}
