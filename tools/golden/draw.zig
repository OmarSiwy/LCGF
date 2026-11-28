//! Golden-image dumper for the draw features: builds one scene with the tier-0 passes of src/
//! (tree, layout, paint) and writes what tools/golden/gpu.py draws, into a directory:
//!
//!     zig build draw-dump -- <scene> <dir> [scale]     quad.wgsl, quads.bin, glyphs.bin, cmds.txt
//!
//! `scale` (default 1) is the physical pixels per logical pixel the scene is drawn at: the draw
//! list is the same, and cmds.txt's `scale` line tells gpu.py and sw-play to draw it on a target
//! that many times 800x600.
//!
//! `paragraphs` draws styled text: glyphs from `MonoParagraphs.quads` over the stand-in atlas.
//! `labels` draws canvas labels in the repository's test face through the text service's
//! distance atlas (src/app/labels.zig) at camera scales 0.5 to 8, its atlas in
//! canvas-atlas.bin (a `canvas-atlas` w h file line: alpha bytes, row by row).
//!
//! The shader and instance layout are src/render/shaders/quad.zig's (`lcgf.quad_shader`). ci/jobs/draw-golden.sh renders every scene
//! and compares it with tools/golden/ref/draw/<scene>.png.
const std = @import("std");
const lcgf = @import("lcgf");
const Tree = lcgf.tree.Tree;
const Texts = lcgf.texts.Texts;
const Customs = lcgf.customs.Customs;
const DrawList = lcgf.draw_list.DrawList;
const Quad = lcgf.draw_list.Quad;
const Style = lcgf.types.Style;
const Color = lcgf.types.Color;
const Id = lcgf.types.Id;
const features = lcgf.features;

const gfx = lcgf.quad_shader;

/// gpu.py draws an 800x600 target.
const viewport = [2]f32{ 800, 600 };
const cap = 64;

const Scene = struct {
    t: Tree,
    tx: Texts,
    cu: Customs,
    d: DrawList,

    fn carve(carver: *lcgf.mem.Carver) Scene {
        return .{
            .t = Tree.init(carver, cap),
            .tx = Texts.init(carver, 4),
            .cu = Customs.init(carver, 4),
            .d = DrawList.init(carver, cap, 4, 4),
        };
    }
    const bytes = blk: {
        @setEvalBranchQuota(10_000);
        var counter: lcgf.mem.Carver = .{ .buf = null };
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

/// Texture 2: four ramp rows of 64 texels (`features.rampPixels`), one per box below.
const ramp_w = 64;
const ramp_rows = 4;
fn rampTexture() [ramp_w * ramp_rows]u32 {
    const stops = [ramp_rows][]const features.Stop{
        &.{ .{ .color = .rgb(220, 40, 40), .at = 0 }, .{ .color = .rgb(250, 220, 40), .at = 0.5 }, .{ .color = .rgb(40, 60, 220), .at = 1 } },
        &.{ .{ .color = .rgb(20, 20, 30), .at = 0 }, .{ .color = .rgb(40, 200, 120), .at = 0.3 }, .{ .color = .rgb(240, 240, 240), .at = 0.6 }, .{ .color = .rgb(160, 40, 200), .at = 1 } },
        &.{ .{ .color = .white, .at = 0 }, .{ .color = .rgb(255, 150, 30), .at = 0.4 }, .{ .color = .rgba(60, 20, 90, 0), .at = 1 } },
        // Hard stops: stripes.
        &.{ .{ .color = .rgb(255, 0, 0), .at = 0.25 }, .{ .color = .rgb(0, 200, 0), .at = 0.25 }, .{ .color = .rgb(0, 200, 0), .at = 0.75 }, .{ .color = .rgb(0, 0, 255), .at = 0.75 } },
    };
    var px: [ramp_w * ramp_rows]u32 = undefined;
    for (stops, 0..) |st, r| features.rampPixels(st, px[r * ramp_w ..][0..ramp_w]);
    return px;
}

/// Gradients of more than two colours from the ramp rows of texture 2: three stops left to
/// right, four at 45 degrees in a rounded, bordered box, a radial fade to transparent, and
/// hard stops top to bottom.
fn ramps(t: *Tree) void {
    const tex: lcgf.types.Texture = @fromBackingInt(2);
    const row = struct {
        fn uv(r: f32) [4]f32 {
            return .{ 0, r / ramp_rows, 1, (r + 1) / ramp_rows };
        }
    }.uv;
    Scene.row(t, &.{
        .{ .fill = .white, .texture = tex, .uv = row(0), .params = features.linearRamp(0) },
        .{ .fill = .white, .texture = tex, .uv = row(1), .params = features.linearRamp(std.math.pi / 4.0), .radius = 24, .border = 3, .border_color = .white },
        .{ .fill = .white, .texture = tex, .uv = row(2), .params = features.radialRamp(.{ 0.5, 0.5 }, 80) },
        .{ .fill = .white, .texture = tex, .uv = row(3), .params = features.linearRamp(std.math.pi / 2.0), .radius = 60 },
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
    const atlas: lcgf.types.Texture = @fromBackingInt(1);
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
    const atlas: lcgf.types.Texture = @fromBackingInt(1);
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
    .{ "ramps", ramps },
    .{ "shadows", shadows },
    .{ "images", images },
    .{ "nine-slice", nineSlices },
    .{ "corners", corners },
    .{ "borders", borders },
    .{ "opacity", opacity },
    .{ "transforms", transforms },
    .{ "rounded-clip", roundedClip },
};

var buf: [Scene.bytes]u8 align(lcgf.mem.column_align) = undefined;
var canvas_storage: lcgf.render_conformance.CanvasStorage = undefined;

/// Writes the canvas scene (conformance.CanvasStorage): canvas.bin (pos then look, 32 bytes a
/// row, interleaved), verts.bin, canvas.wgsl (the GPU back ends' canvas shader), quad.wgsl and
/// its layout (gpu.py needs them), colors.bin (a colour a row), and in cmds.txt the palette (a
/// `layer` stroke fill width flags line per layer, colours as rgba8 u32), then per canvas
/// command its node (`canvas` rect clip opacity xform radii), camera (origin as two i64s,
/// scale, offset), ranges and overrides.
fn canvasScene(io: std.Io, out_path: []const u8, scale: f32) !void {
    const sc = lcgf.render_conformance.canvas_scene;
    const st = &canvas_storage;
    st.load();
    const s = &st.shapes;
    if (s.overflow) return error.SceneOverflow;
    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.createDirPathOpen(io, out_path, .{});
    defer dir.close(io);
    var rows: [sc.rows][8]u32 = undefined;
    for (0..s.len) |i| rows[i] = @as([4]u32, @bitCast(s.c.pos[i])) ++ s.c.look[i];
    try dir.writeFile(io, .{ .sub_path = "canvas.bin", .data = std.mem.sliceAsBytes(rows[0..s.len]) });
    try dir.writeFile(io, .{ .sub_path = "verts.bin", .data = std.mem.sliceAsBytes(s.verts[0..@max(s.vert_len, 1)]) });
    try dir.writeFile(io, .{ .sub_path = "colors.bin", .data = std.mem.sliceAsBytes(s.colors[0..s.len]) });
    try dir.writeFile(io, .{ .sub_path = "canvas.wgsl", .data = lcgf.canvas_shader.wgsl });
    try dir.writeFile(io, .{ .sub_path = "quad.wgsl", .data = gfx.wgsl });
    // No quads or text; one zero row each, because gpu.py cannot upload an empty buffer.
    try dir.writeFile(io, .{ .sub_path = "quads.bin", .data = &@as([@sizeOf(Quad)]u8, @splat(0)) });
    try dir.writeFile(io, .{ .sub_path = "glyphs.bin", .data = &@as([@sizeOf(Quad)]u8, @splat(0)) });
    var text: [16 * 1024]u8 = undefined;
    var t = std.Io.Writer.fixed(&text);
    try t.print("stride {d}\nscale {d}\n", .{ gfx.stride, scale });
    for (gfx.attrs) |a| try t.print("attr {d} {d} {s}\n", .{ a.location, a.offset, a.format });
    for (sc.palette.layers) |l| try t.print("layer {d} {d} {d} {d}\n", .{ l.stroke, l.fill, l.width, l.flags });
    for (0..st.draw.cmd_len) |i| {
        const k = st.draw.command(@intCast(i)).canvas;
        const n = st.draw.customs[k];
        const c = st.draw.canvases[k];
        try t.print("canvas", .{});
        for (n.rect ++ n.clip ++ [1]f32{n.opacity} ++ n.xform ++ n.clip_radii) |x| try t.print(" {d}", .{x});
        try t.print("\n", .{});
        const cam = c.camera;
        try t.print("camera {d} {d} {d} {d} {d}\n", .{ cam.origin[0], cam.origin[1], cam.scale, cam.offset[0], cam.offset[1] });
        for (c.ranges) |r| try t.print("range {d} {d}\n", .{ r.first, r.count });
        for (c.overrides) |o| try t.print("override {d} {d} {d}\n", .{ o.range.first, o.range.count, o.color });
    }
    try dir.writeFile(io, .{ .sub_path = "cmds.txt", .data = t.buffered() });
}

const app_text = @import("app_text");
const label_options: app_text.labels.Options = .{ .atlas = .{ 256, 128 }, .images = 64, .label_glyphs = 32 };
const text_options: app_text.Options = .{ .atlas = .{ 16, 16 }, .images = 8, .texts = 1, .quads = 8 };
var label_buf: [app_text.labels.Labels.requiredBytes(label_options)]u8 align(lcgf.mem.column_align) = undefined;
var text_buf: [app_text.Text.requiredBytes(text_options)]u8 align(lcgf.mem.column_align) = undefined;
var label_shapes_buf: [lcgf.canvas.Instances.requiredBytes(64, 1, 1, .{})]u8 align(lcgf.mem.column_align) = undefined;

/// Canvas labels (src/app/labels.zig): "R1 10k Vout" 13 px tall at camera scale 1, and "GND"
/// turned a quarter beside it, in five canvas nodes one under the other at camera scales 0.5,
/// 1, 2, 4 and 8 (the turned label clipped by the taller nodes). A world unit is a hundredth of
/// a logical pixel at scale 1. Written as `canvasScene` writes the canvas scene, with the
/// distance atlas in canvas-atlas.bin.
fn labelScene(io: std.Io, out_path: []const u8, scale: f32) !void {
    const canvas = lcgf.canvas;
    const t = try app_text.Text.init(&text_buf, text_options, &.{.{ .bytes = @embedFile("layout.ttf") }});
    var labels = app_text.labels.Labels.init(&label_buf, label_options);
    var carver: lcgf.mem.Carver = .{ .buf = &label_shapes_buf };
    var s = canvas.Instances.init(&carver, 64, 1, 1, .{});
    _ = try labels.label(&t, &s, "R1 10k Vout", .{ .origin = .{ 0, 0 }, .px = 1300 });
    _ = try labels.label(&t, &s, "GND", .{ .origin = .{ 7600, -900 }, .px = 1300, .turns = 1 });
    if (labels.overflow or s.overflow) return error.SceneOverflow;
    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.createDirPathOpen(io, out_path, .{});
    defer dir.close(io);
    var rows: [64][8]u32 = undefined;
    for (0..s.len) |i| rows[i] = @as([4]u32, @bitCast(s.c.pos[i])) ++ s.c.look[i];
    try dir.writeFile(io, .{ .sub_path = "canvas.bin", .data = std.mem.sliceAsBytes(rows[0..s.len]) });
    try dir.writeFile(io, .{ .sub_path = "verts.bin", .data = &@as([8]u8, @splat(0)) });
    try dir.writeFile(io, .{ .sub_path = "canvas-atlas.bin", .data = labels.atlas.pixels });
    try dir.writeFile(io, .{ .sub_path = "canvas.wgsl", .data = lcgf.canvas_shader.wgsl });
    try dir.writeFile(io, .{ .sub_path = "quad.wgsl", .data = gfx.wgsl });
    try dir.writeFile(io, .{ .sub_path = "quads.bin", .data = &@as([@sizeOf(Quad)]u8, @splat(0)) });
    try dir.writeFile(io, .{ .sub_path = "glyphs.bin", .data = &@as([@sizeOf(Quad)]u8, @splat(0)) });
    var text: [16 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&text);
    try w.print("stride {d}\nscale {d}\n", .{ gfx.stride, scale });
    for (gfx.attrs) |a| try w.print("attr {d} {d} {s}\n", .{ a.location, a.offset, a.format });
    try w.print("canvas-atlas {d} {d} canvas-atlas.bin\n", .{ labels.atlas.w, labels.atlas.h });
    const white: u32 = @bitCast(Color.white);
    try w.print("layer {d} 0 1 2\n", .{white});
    var top: f32 = 4;
    for ([_]f32{ 0.5, 1, 2, 4, 8 }) |zoom| {
        const h = 13 * zoom * 1.4 + 4;
        try w.print("canvas 4 {d} 796 {d} 4 {d} 796 {d} 1 1 0 0 1 0 0 0 0 0 0\n", .{ top, top + h, top, top + h });
        try w.print("camera 0 0 {d} 4 {d}\n", .{ zoom / 100, 13 * zoom + 2 });
        try w.print("range 0 {d}\n", .{s.len});
        top += h + 4;
    }
    try dir.writeFile(io, .{ .sub_path = "cmds.txt", .data = w.buffered() });
}

/// Styled text (MonoParagraphs): a tall line with letter spacing, spans in other sizes and
/// colours, underline with line-through, and a wrapped paragraph clamped to two lines with an
/// ellipsis. Its glyph quads are `MonoParagraphs.quads`'s over the stand-in atlas, and the
/// decorations are the draw list's own quads, so the pixels check both.
fn paragraphScene(io: std.Io, out_path: []const u8, scale: f32) !void {
    var carver: lcgf.mem.Carver = .{ .buf = &buf };
    var sc = Scene.carve(&carver);
    var bytes: [256]u8 = undefined;
    var strings: lcgf.strings.Strings = .{ .buf = &bytes };
    const t = &sc.t;
    const tx = &sc.tx;
    _ = t.push(0, Id.from("root"), &.{ .size = .{ .px(viewport[0]), .px(viewport[1]) }, .pad = @splat(20), .gap = 16 });
    const Run = struct { text: []const u8, ts: lcgf.types.TextStyle, style: Style = .{} };
    const runs = [_]Run{
        .{ .text = "TALL LINE, SPACED", .ts = .{ .px = 20 } },
        .{ .text = "SPANS: BIG RED, SMALL BLUE.", .ts = .{ .px = 20 } },
        .{ .text = "UNDER AND THROUGH", .ts = .{ .px = 20, .color = .rgb(255, 220, 120) } },
        .{ .text = "A LONG PARAGRAPH THAT WRAPS INTO A NARROW BOX AND IS CUT SHORT AT TWO LINES", .ts = .{ .px = 16, .wrap = true }, .style = .{ .size = .{ .px(300), .fit }, .shrink = true } },
    };
    for (runs) |r| {
        const k = t.push(0, .none, &r.style);
        t.c.text[k] = tx.push(k, strings.add(r.text), &r.ts);
    }
    t.seal(0);
    const Span = lcgf.protocol.Span;
    const spans = [_]Span{
        .{ .start = 7, .style = .{ .px = 32, .color = .rgb(255, 80, 80) } },
        .{ .start = 14, .style = .{ .px = 20 } },
        .{ .start = 16, .style = .{ .px = 12, .color = .rgb(100, 160, 255) } },
        .{ .start = 26, .style = .{ .px = 20 } },
    };
    const font: lcgf.protocol.MonoParagraphs = .{
        .rows = &.{ 0, 1, 2, 3 },
        .styles = &.{ 0, 1, 2, 3 },
        .table = &.{ .{ .line_height = .{ .px = 44 }, .letter_spacing = 3 }, .{}, .{}, .{ .max_lines = 2, .ellipsis = true } },
        .decorations = &.{ .{}, .{}, .{ .underline = true, .strike = true, .thickness = 2 }, .{} },
        .spans = &.{ &.{}, &spans, &.{}, &.{} },
        .strings = strings.buf[0..strings.len],
    };
    font.measure(tx);
    lcgf.layout.prepare(t);
    lcgf.layout.applyText(t, tx, .x);
    lcgf.layout.fit(t, .x);
    lcgf.layout.resolve(t, .x, viewport[0]);
    lcgf.layout.textAvail(t, tx);
    font.wrap(tx);
    lcgf.layout.applyText(t, tx, .y);
    lcgf.layout.fit(t, .y);
    lcgf.layout.resolve(t, .y, viewport[1]);
    lcgf.layout.place(t);
    lcgf.layout.finalize(t);
    lcgf.inherit.opacity(t);
    lcgf.inherit.transform(t);
    lcgf.inherit.clip(t);
    lcgf.paint.emit(t, tx, &sc.cu, strings.buf[0..strings.len], &sc.d);
    font.decorate(&sc.d, tx);
    var glyphs: [256]Quad = undefined;
    var first: [4]u32 = undefined;
    var count: [4]u32 = undefined;
    const n = font.quads(&sc.d, tx, &glyphs, .{ .first = &first, .count = &count });

    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.createDirPathOpen(io, out_path, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "quad.wgsl", .data = gfx.wgsl });
    try dir.writeFile(io, .{ .sub_path = "quads.bin", .data = sc.d.quadBytes() });
    try dir.writeFile(io, .{ .sub_path = "glyphs.bin", .data = std.mem.sliceAsBytes(glyphs[0..n]) });
    var text: [16 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&text);
    try w.print("stride {d}\nscale {d}\n", .{ gfx.stride, scale });
    for (gfx.attrs) |a| try w.print("attr {d} {d} {s}\n", .{ a.location, a.offset, a.format });
    for (0..sc.d.cmd_len) |i| switch (sc.d.command(@intCast(i))) {
        .quads => |b| try w.print("quads {d} {d} {d} {d}\n", .{ b.first, b.count, @backingInt(b.texture), @backingInt(b.material) }),
        .text => |k| try w.print("text {d} {d}\n", .{ first[k], count[k] }),
        .custom, .canvas => return error.SceneHasCustom,
    };
    try dir.writeFile(io, .{ .sub_path = "cmds.txt", .data = w.buffered() });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const name = args.next() orelse return error.Usage;
    const out_path = args.next() orelse return error.Usage;
    const scale = if (args.next()) |a| try std.fmt.parseFloat(f32, a) else 1;
    if (!(scale > 0)) return error.Usage;

    var carver: lcgf.mem.Carver = .{ .buf = &buf };
    var sc = Scene.carve(&carver);
    var found = false;
    inline for (scenes) |s| {
        if (std.mem.eql(u8, name, s[0])) {
            s[1](&sc.t);
            found = true;
        }
    }
    if (std.mem.eql(u8, name, "canvas")) return canvasScene(io, out_path, scale);
    if (std.mem.eql(u8, name, "paragraphs")) return paragraphScene(io, out_path, scale);
    if (std.mem.eql(u8, name, "labels")) return labelScene(io, out_path, scale);
    if (!found) return error.UnknownScene;
    lcgf.layout.run(&sc.t, &sc.tx, viewport);
    lcgf.inherit.opacity(&sc.t);
    lcgf.inherit.transform(&sc.t);
    lcgf.inherit.clip(&sc.t);
    lcgf.paint.emit(&sc.t, &sc.tx, &sc.cu, "", &sc.d);

    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.createDirPathOpen(io, out_path, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "quad.wgsl", .data = gfx.wgsl });
    try dir.writeFile(io, .{ .sub_path = "quads.bin", .data = sc.d.quadBytes() });
    // No text in these scenes; one zero row, because gpu.py cannot upload an empty buffer.
    try dir.writeFile(io, .{ .sub_path = "glyphs.bin", .data = &@as([@sizeOf(Quad)]u8, @splat(0)) });

    var text: [16 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&text);
    try w.print("stride {d}\nscale {d}\n", .{ gfx.stride, scale });
    for (gfx.attrs) |a| try w.print("attr {d} {d} {s}\n", .{ a.location, a.offset, a.format });
    for (0..sc.d.cmd_len) |i| switch (sc.d.command(@intCast(i))) {
        .quads => |b| try w.print("quads {d} {d} {d} {d}\n", .{ b.first, b.count, @backingInt(b.texture), @backingInt(b.material) }),
        .text, .custom, .canvas => return error.SceneHasTextOrCustom,
    };
    if (std.mem.eql(u8, name, "ramps")) {
        const px = rampTexture();
        try dir.writeFile(io, .{ .sub_path = "ramps.rgba", .data = std.mem.sliceAsBytes(&px) });
        try w.print("texture 2 {d} {d} ramps.rgba\n", .{ ramp_w, ramp_rows });
    }
    try dir.writeFile(io, .{ .sub_path = "cmds.txt", .data = w.buffered() });
}
