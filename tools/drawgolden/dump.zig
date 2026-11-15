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
    .{ 6, "radius", "float32x2" }, // radius and border, adjacent
};
comptime {
    std.debug.assert(@offsetOf(Quad, "border") == @offsetOf(Quad, "radius") + 4);
}

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

const scenes = .{
    .{ "gradients", gradients },
    .{ "shadows", shadows },
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
