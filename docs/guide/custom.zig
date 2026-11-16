//! The examples of docs/guide/custom.md, compiled and run by `zig build docs`. Every ```zig
//! block of the guide is a verbatim piece of this file (docs/guide/snippets.py checks that).
//! The back end is `render_null.Null`, which records the calls a GPU back end would make, so
//! the routes can be checked without a GPU.

const std = @import("std");
const testing = std.testing;
const lcgr = @import("lcgr");
const Context = lcgr.context.Context;
const Frame = lcgr.frame.Frame;
const types = lcgr.types;

const limits: lcgr.context.Limits = .{ .nodes = 32, .texts = 4, .customs = 4 };
var buffer: [Context.requiredBytes(limits)]u8 align(lcgr.mem.column_align) = undefined;

// -- material
const quad_shader = lcgr.quad_shader;
var materials: quad_shader.Materials = .{};
const stripes_wgsl = quad_shader.shader(quad_shader.example_material);
// -- end

/// What the host's own scene draws: here, a record of each inline draw.
const Scene = struct {
    draws: u32 = 0,
    rect: [4]f32 = @splat(0),
    data: u64 = 0,
};

// -- build
fn build(f: *Frame, video: types.Texture, stripes: types.Material) void {
    _ = f.open(.from("page"), .{ .dir = .x, .size = .{ .fill, .fill }, .gap = 8, .pad = @splat(8) });
    // Route 3: a texture you rendered, shown as an ordinary, rounded, clipped quad. The
    // fill multiplies it; a node with neither a fill nor a border colour paints nothing.
    _ = f.leaf(.from("video"), .{ .size = .{ .px(160), .px(90) }, .radius = 8, .fill = .white, .texture = video });
    // Route 2: a rect the host draws itself, in paint order; `data` says what.
    _ = f.custom(.from("3d"), .{ .size = .{ .fill, .fill } }, 7);
    // A material: your fragment function in the quad shader.
    _ = f.leaf(.from("busy"), .{ .size = .{ .px(40), .fill }, .fill = .rgb(40, 40, 60), .material = stripes });
    f.close();
}
// -- end

test "custom rendering: texture, inline draw and material in one pass" {
    var ctx = try Context.init(&buffer, limits);
    var in: lcgr.input.Input = .{ .viewport = .{ 640, 200 } };
    const null_ = lcgr.render_null;
    var calls: [64]null_.Call = undefined;
    var log: null_.Log = .{ .calls = &calls };
    const queue = &log;
    const pass = &log;
    var gfx: null_.Null = .{};
    var scene: Scene = .{};
    // A wgpu host gets this handle from `Renderer.addTexture(device, view, sampler)`.
    const video: types.Texture = @fromBackingInt(1);
    // -- material
    const stripes = materials.add(stripes_wgsl); // a wgpu host calls `Renderer.addMaterial(device, stripes_wgsl)`
    // -- end

    var f = ctx.begin(&in);
    build(&f, video, stripes);
    const out = f.end(.{});
    const draw = out.draw;

    // -- loop
    gfx.prepare(queue, draw, .{}, in.viewport, 1); // uploads, before the pass begins
    // Route 1, under: your draws here are behind the UI.
    var i = lcgr.render_iface.drawUntilCustom(&gfx, pass, draw, 0);
    while (i < draw.cmd_len) : (i = lcgr.render_iface.drawUntilCustom(&gfx, pass, draw, i + 1)) {
        const c = draw.customs[draw.command(i).custom];
        pass.push(.host); // your pipeline: scissor to c.clip, draw into c.rect
        scene.draws += 1;
        scene.rect = c.rect;
        scene.data = c.data;
    }
    // Route 1, over: your draws here are on top of the UI.
    // -- end

    try testing.expectEqual(1, scene.draws);
    try testing.expectEqual(7, scene.data);
    try testing.expectEqual(out.tree.rect(out.tree.find(.from("3d"))), types.Rect{ .x0 = scene.rect[0], .y0 = scene.rect[1], .x1 = scene.rect[2], .y1 = scene.rect[3] });
    // Every UI draw after the host's sets its whole state again.
    try testing.expect(null_.rebindsAfterHost(log.recorded()));
    // The texture and the material each reached a draw.
    var saw_video = false;
    var saw_stripes = false;
    for (log.recorded()) |call| switch (call) {
        .group => |g| saw_video = saw_video or (g.index == 1 and g.texture == video),
        .pipeline => |m| saw_stripes = saw_stripes or m == stripes,
        else => {},
    };
    try testing.expect(saw_video);
    try testing.expect(saw_stripes);
    try testing.expectEqualStrings(stripes_wgsl, materials.source(stripes));
}
