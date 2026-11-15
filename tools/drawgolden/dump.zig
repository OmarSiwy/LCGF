//! Golden-image dumper for the draw features: builds one scene with the tier-0 passes of src/
//! (tree, layout, paint) and writes what tools/golden/gpu.py draws, into a directory:
//!
//!     zig build draw-dump -- <scene> <dir>     quad.wgsl, quads.bin, glyphs.bin, cmds.txt
//!
//! The shader is src/render/shaders/quad.wgsl and the instance layout is declared here from
//! `draw_list.Quad`, until a src/ renderer owns both. ci/jobs/draw-golden.sh renders every scene
//! and compares it with tools/drawgolden/ref/<scene>.png.
const std = @import("std");
const lcgr = @import("lcgr");
const Tree = lcgr.tree.Tree;
const Texts = lcgr.texts.Texts;
const Customs = lcgr.customs.Customs;
const DrawList = lcgr.draw_list.DrawList;
const Quad = lcgr.draw_list.Quad;
const Style = lcgr.types.Style;
const Color = lcgr.types.Color;
const Id = lcgr.types.Id;
const features = lcgr.features;

const wgsl = @embedFile("quad.wgsl");

/// gpu.py draws an 800x600 target.
const viewport = [2]f32{ 800, 600 };
const cap = 64;

/// Vertex attributes of `Quad` for the shader above: location, field, format.
const attrs = .{
    .{ 0, "rect", "float32x4" },
    .{ 1, "clip", "float32x4" },
    .{ 2, "params", "uint32x4" },
    .{ 3, "uv", "float32x4" },
    .{ 4, "fill", "unorm8x4" },
    .{ 5, "border_color", "unorm8x4" },
    .{ 6, "radii", "float32x4" },
    .{ 7, "border", "float32" },
};

const Scene = struct {
    t: Tree,
    tx: Texts,
    cu: Customs,
    d: DrawList,

    fn carve(carver: *lcgr.mem.Carver) Scene {
        return .{
            .t = Tree.init(carver, cap),
            .tx = Texts.init(carver, 4),
            .cu = Customs.init(carver, 4),
            .d = DrawList.init(carver, cap, 4, 4),
        };
    }
    const bytes = blk: {
        @setEvalBranchQuota(10_000);
        var counter: lcgr.mem.Carver = .{ .buf = null };
        _ = carve(&counter);
        break :blk counter.off;
    };

    /// A row of boxes at the top left, each 160x120.
    fn row(t: *Tree, boxes: []const Style) void {
        _ = t.push(0, Id.from("root"), &.{ .dir = .x, .size = .{ .px(viewport[0]), .px(viewport[1]) }, .pad = @splat(20), .gap = 20 });
        for (boxes) |s| {
            var b = s;
            b.size = .{ .px(160), .px(120) };
            _ = t.push(0, .none, &b);
        }
        t.seal(0);
    }
};

fn gradients(t: *Tree) void {
    Scene.row(t, &.{
        .{ .fill = .rgb(220, 40, 40), .params = features.linear(.rgb(40, 60, 220), 0) },
        .{ .fill = .rgb(40, 200, 80), .params = features.linear(.rgb(240, 220, 40), std.math.pi / 4.0), .radius = 24, .border = 3, .border_color = .white },
        .{ .fill = .white, .params = features.radial(.rgb(0, 0, 160), .{ 0.5, 0.5 }, 80) },
        .{ .fill = .rgb(255, 150, 30), .params = features.radial(.rgb(60, 20, 90), .{ 0.25, 0.25 }, 120), .radius = 60 },
    });
}

/// Cards on a light page, each with its shadow node underneath: offset (6, 8), sigma 2 to 16.
fn shadows(t: *Tree) void {
    _ = t.push(0, Id.from("root"), &.{ .dir = .x, .size = .{ .px(viewport[0]), .px(viewport[1]) }, .pad = @splat(40), .gap = 40, .fill = .rgb(230, 232, 236) });
    const sigmas = [_]f32{ 2, 6, 16 };
    const radii = [_]f32{ 0, 12, 40 };
    for (sigmas, radii) |sigma, r| {
        const card = t.push(0, .none, &.{ .size = .{ .px(180), .px(140) } });
        _ = t.push(card, .none, &.{ .float = true, .offset = .{ 6, 8 }, .size = .{ .px(180), .px(140) }, .radius = r, .fill = .rgba(0, 0, 0, 140), .params = features.shadow(sigma) });
        _ = t.push(card, .none, &.{ .float = true, .size = .{ .px(180), .px(140) }, .radius = r, .fill = .white });
        t.seal(card);
    }
    t.seal(0);
}

/// Texture 1, which gpu.py binds to its stand-in 64x64 glyph atlas (16x16 cells of 4x4 texels,
/// nearest sampling): the whole atlas, a UV rect of rows 2 to 7 tinted, one cell, and a rounded
/// image.
fn images(t: *Tree) void {
    const atlas: lcgr.types.Texture = @fromBackingInt(1);
    Scene.row(t, &.{
        .{ .fill = .white, .texture = atlas },
        .{ .fill = .rgb(120, 200, 255), .texture = atlas, .uv = .{ 0, 0.125, 1, 0.5 } },
        .{ .fill = .rgb(255, 200, 80), .texture = atlas, .uv = .{ 1.0 / 16.0, 2.0 / 16.0, 2.0 / 16.0, 3.0 / 16.0 } },
        .{ .fill = .white, .texture = atlas, .uv = .{ 0, 0.25, 0.5, 0.5 }, .radius = 30, .border = 4, .border_color = .rgb(255, 80, 80) },
    });
}

/// One 4x4-texel atlas cell (byte 33: texels x 1-2, y 1-3 set) cut one texel in from every side
/// and drawn with 12-pixel borders at three sizes: the border cells keep 12 pixels.
fn nineSlices(t: *Tree) void {
    const atlas: lcgr.types.Texture = @fromBackingInt(1);
    _ = t.push(0, Id.from("root"), &.{ .dir = .x, .size = .{ .px(viewport[0]), .px(viewport[1]) }, .pad = @splat(20), .gap = 20 });
    const sizes = [_][2]f32{ .{ 160, 120 }, .{ 60, 60 }, .{ 300, 40 } };
    for (sizes) |wh| _ = t.push(0, .none, &.{
        .size = .{ .px(wh[0]), .px(wh[1]) },
        .fill = .rgb(255, 210, 120),
        .texture = atlas,
        .uv = .{ 1.0 / 16.0, 2.0 / 16.0, 2.0 / 16.0, 3.0 / 16.0 },
        .params = features.nineSlice(@splat(12), @splat(0.25)),
    });
    t.seal(0);
}

/// Per-corner radii, including a corner larger than half the box (capped) and a bordered tab.
fn corners(t: *Tree) void {
    Scene.row(t, &.{
        .{ .fill = .rgb(90, 160, 255), .radii = .{ 0, 20, 40, 60 } },
        .{ .fill = .rgb(240, 120, 80), .radius = 30, .radii = .{ -1, 0, -1, 0 }, .border = 4, .border_color = .white },
        .{ .fill = .rgb(120, 220, 140), .radii = .{ 24, 24, 0, 0 } },
        .{ .fill = .rgb(250, 210, 90), .radii = .{ 200, 4, 200, 4 } },
    });
}

const scenes = .{
    .{ "gradients", gradients },
    .{ "shadows", shadows },
    .{ "images", images },
    .{ "nine-slice", nineSlices },
    .{ "corners", corners },
};

var buf: [Scene.bytes]u8 align(lcgr.mem.column_align) = undefined;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const name = args.next() orelse return error.Usage;
    const out_path = args.next() orelse return error.Usage;

    var carver: lcgr.mem.Carver = .{ .buf = &buf };
    var sc = Scene.carve(&carver);
    var found = false;
    inline for (scenes) |s| {
        if (std.mem.eql(u8, name, s[0])) {
            s[1](&sc.t);
            found = true;
        }
    }
    if (!found) return error.UnknownScene;
    lcgr.layout.run(&sc.t, &sc.tx, viewport);
    lcgr.paint.emit(&sc.t, &sc.tx, &sc.cu, "", &sc.d);

    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.createDirPathOpen(io, out_path, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "quad.wgsl", .data = wgsl });
    try dir.writeFile(io, .{ .sub_path = "quads.bin", .data = sc.d.quadBytes() });
    // No text in these scenes; one zero row, because gpu.py cannot upload an empty buffer.
    try dir.writeFile(io, .{ .sub_path = "glyphs.bin", .data = &@as([@sizeOf(Quad)]u8, @splat(0)) });

    var text: [16 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&text);
    try w.print("stride {d}\n", .{@sizeOf(Quad)});
    inline for (attrs) |a| try w.print("attr {d} {d} {s}\n", .{ a[0], @offsetOf(Quad, a[1]), a[2] });
    for (0..sc.d.cmd_len) |i| switch (sc.d.command(@intCast(i))) {
        .quads => |b| try w.print("quads {d} {d} {d} {d}\n", .{ b.first, b.count, @backingInt(b.texture), @backingInt(b.material) }),
        .text, .custom => return error.SceneHasTextOrCustom,
    };
    try dir.writeFile(io, .{ .sub_path = "cmds.txt", .data = w.buffered() });
}
