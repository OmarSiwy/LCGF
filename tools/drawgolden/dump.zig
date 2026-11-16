//! Golden-image dumper for the draw features: builds one scene with the tier-0 passes of src/
//! (tree, layout, paint) and writes what tools/golden/gpu.py draws, into a directory:
//!
//!     zig build draw-dump -- <scene> <dir>     quad.wgsl, quads.bin, glyphs.bin, cmds.txt
//!
//! The shader and instance layout are src/render/shaders/quad.zig's (`lcgr.quad_shader`). ci/jobs/draw-golden.sh renders every scene
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

const gfx = lcgr.quad_shader;

/// gpu.py draws an 800x600 target.
const viewport = [2]f32{ 800, 600 };
const cap = 64;

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

/// Dashed and dotted borders on plain, rounded and unfilled boxes.
fn borders(t: *Tree) void {
    const line: Color = .rgb(240, 240, 240);
    Scene.row(t, &.{
        .{ .border = 3, .border_color = line, .params = features.dashed(12, 6) },
        .{ .fill = .rgb(50, 70, 120), .border = 4, .border_color = .rgb(255, 200, 60), .radius = 16, .params = features.dashed(10, 10) },
        .{ .border = 6, .border_color = line, .params = features.dotted(6) },
        .{ .fill = .rgb(120, 40, 60), .border = 8, .border_color = .rgb(120, 220, 255), .params = features.dotted(4) },
    });
}

/// A panel at opacity 1, 0.5 and 0.5 inside 0.5, each holding a gradient, a bordered rounded
/// box and an image, over a striped background so the transparency shows.
fn opacity(t: *Tree) void {
    _ = t.push(0, Id.from("root"), &.{ .dir = .x, .size = .{ .px(viewport[0]), .px(viewport[1]) }, .pad = @splat(20), .gap = 20 });
    for (0..8) |k| _ = t.push(0, .none, &.{ .float = true, .offset = .{ 0, @floatFromInt(20 * k) }, .size = .{ .px(800), .px(10) }, .fill = .rgb(200, 200, 200) });
    const levels = [_][2]f32{ .{ 1, 1 }, .{ 0.5, 1 }, .{ 0.5, 0.5 } };
    for (levels) |lv| {
        const outer = t.push(0, .none, &.{ .opacity = lv[0], .size = .{ .px(220), .px(140) } });
        const panel = t.push(outer, .none, &.{ .opacity = lv[1], .dir = .x, .size = .{ .px(220), .px(140) }, .pad = @splat(10), .gap = 10, .fill = .rgb(40, 60, 120), .radius = 10 });
        _ = t.push(panel, .none, &.{ .size = .{ .px(60), .px(120) }, .fill = .rgb(255, 80, 80), .params = features.linear(.rgb(255, 230, 60), std.math.pi / 2.0) });
        _ = t.push(panel, .none, &.{ .size = .{ .px(60), .px(120) }, .fill = .rgb(80, 220, 120), .radius = 12, .border = 4, .border_color = .white });
        _ = t.push(panel, .none, &.{ .size = .{ .px(60), .px(120) }, .fill = .white, .texture = @fromBackingInt(1), .uv = .{ 0, 0.125, 0.5, 0.5 } });
        t.seal(panel);
        t.seal(outer);
    }
    t.seal(0);
}

/// A card turned 15 degrees, one scaled to 0.75, one skewed, and inside a turned panel a child
/// turned again (the angles add) over an untransformed outline of where layout put it.
fn transforms(t: *Tree) void {
    const rot = struct {
        fn by(deg: f32) [6]f32 {
            const a = deg * std.math.pi / 180.0;
            return .{ @cos(a), @sin(a), -@sin(a), @cos(a), 0, 0 };
        }
    }.by;
    _ = t.push(0, Id.from("root"), &.{ .dir = .x, .size = .{ .px(viewport[0]), .px(viewport[1]) }, .pad = @splat(40), .gap = 40 });
    const outline: Style = .{ .float = true, .size = .{ .px(140), .px(100) }, .border = 1, .border_color = .rgb(120, 120, 120) };
    const looks = [_]Style{
        .{ .fill = .rgb(90, 160, 255), .radius = 12, .transform = rot(15) },
        .{ .fill = .rgb(240, 120, 80), .border = 4, .border_color = .white, .transform = .{ 0.75, 0, 0, 0.75, 0, 0 } },
        .{ .fill = .rgb(120, 220, 140), .params = features.linear(.rgb(20, 60, 40), 0), .transform = .{ 1, 0, 0.4, 1, 0, 0 } },
    };
    for (looks) |look| {
        const slot = t.push(0, .none, &.{ .size = .{ .px(140), .px(100) } });
        _ = t.push(slot, .none, &outline);
        var s = look;
        s.float = true;
        s.size = .{ .px(140), .px(100) };
        _ = t.push(slot, .none, &s);
        t.seal(slot);
    }
    const panel = t.push(0, .none, &.{ .size = .{ .px(140), .px(100) }, .pad = @splat(30), .fill = .rgb(60, 60, 80), .transform = rot(-20) });
    _ = t.push(panel, .none, &.{ .size = .{ .px(80), .px(40) }, .fill = .rgb(250, 210, 90), .radius = 8, .transform = rot(-25) });
    t.seal(panel);
    t.seal(0);
}

/// Rounded clipping: a bordered rounded card whose children overflow it (a full-width band and
/// an image), a pill clipping a gradient bar through a non-clipping row, and a card with
/// different corners. Each over a square-cornered grey box so the clipped corners show.
fn roundedClip(t: *Tree) void {
    _ = t.push(0, Id.from("root"), &.{ .dir = .x, .size = .{ .px(viewport[0]), .px(viewport[1]) }, .pad = @splat(30), .gap = 30, .fill = .rgb(90, 90, 100) });
    const card = t.push(0, .none, &.{ .size = .{ .px(200), .px(150) }, .clip = true, .radius = 28, .border = 3, .border_color = .white, .fill = .rgb(30, 40, 70) });
    _ = t.push(card, .none, &.{ .size = .{ .px(240), .px(50) }, .fill = .rgb(240, 120, 80) });
    _ = t.push(card, .none, &.{ .size = .{ .px(240), .px(100) }, .fill = .white, .texture = @fromBackingInt(1), .uv = .{ 0, 0.125, 1, 0.5 } });
    t.seal(card);
    const pill = t.push(0, .none, &.{ .size = .{ .px(160), .px(40) }, .clip = true, .radius = 20, .fill = .rgb(20, 20, 20) });
    const row = t.push(pill, .none, &.{ .size = .{ .px(160), .px(40) } });
    _ = t.push(row, .none, &.{ .size = .{ .px(120), .px(40) }, .fill = .rgb(60, 200, 120), .params = features.linear(.rgb(250, 230, 60), 0) });
    t.seal(row);
    t.seal(pill);
    const odd = t.push(0, .none, &.{ .size = .{ .px(150), .px(150) }, .clip = true, .radii = .{ 60, 0, 30, 10 } });
    _ = t.push(odd, .none, &.{ .size = .{ .px(150), .px(150) }, .fill = .rgb(90, 160, 255) });
    t.seal(odd);
    t.seal(0);
}

const scenes = .{
    .{ "gradients", gradients },
    .{ "shadows", shadows },
    .{ "images", images },
    .{ "nine-slice", nineSlices },
    .{ "corners", corners },
    .{ "borders", borders },
    .{ "opacity", opacity },
    .{ "transforms", transforms },
    .{ "rounded-clip", roundedClip },
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
    lcgr.inherit.opacity(&sc.t);
    lcgr.inherit.transform(&sc.t);
    lcgr.inherit.clip(&sc.t);
    lcgr.paint.emit(&sc.t, &sc.tx, &sc.cu, "", &sc.d);

    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.createDirPathOpen(io, out_path, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "quad.wgsl", .data = gfx.wgsl });
    try dir.writeFile(io, .{ .sub_path = "quads.bin", .data = sc.d.quadBytes() });
    // No text in these scenes; one zero row, because gpu.py cannot upload an empty buffer.
    try dir.writeFile(io, .{ .sub_path = "glyphs.bin", .data = &@as([@sizeOf(Quad)]u8, @splat(0)) });

    var text: [16 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&text);
    try w.print("stride {d}\n", .{gfx.stride});
    for (gfx.attrs) |a| try w.print("attr {d} {d} {s}\n", .{ a.location, a.offset, a.format });
    for (0..sc.d.cmd_len) |i| switch (sc.d.command(@intCast(i))) {
        .quads => |b| try w.print("quads {d} {d} {d} {d}\n", .{ b.first, b.count, @backingInt(b.texture), @backingInt(b.material) }),
        .text, .custom => return error.SceneHasTextOrCustom,
    };
    try dir.writeFile(io, .{ .sub_path = "cmds.txt", .data = w.buffered() });
}
