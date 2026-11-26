//! The portable rich-paint route crosses one explicit representation boundary: CPU effects
//! store premultiplied RGBA8, the uploaded texture is straight, and both stock draw backends
//! premultiply it exactly once. This real-driver regression compares that common subset on
//! ES 3 and ES 2. It does not compare distinct analytic shape/effect raster algorithms.

const std = @import("std");
const lcgf = @import("lcgf");
const host = @import("host.zig");
const renderer = @import("renderer.zig");
const es2 = @import("es2.zig");
const surface = lcgf.surface;
const brushes = lcgf.brushes;
const decoration = lcgf.decoration;
const compositor = lcgf.compositor;
const sw = lcgf.render_sw;
const testing = std.testing;

const image_width = 64;
const image_height = 64;
const target_width = 96;
const target_height = 80;
const storage_pixels = lcgf.simd.rows(image_width) * image_height;

fn preparedImage(upload: []u32) !void {
    var bake_storage: [storage_pixels]u32 = undefined;
    var bake_rgba: [image_width * image_height]u32 = undefined;
    var group_storage: [storage_pixels]u32 = undefined;
    var mask_storage: [storage_pixels]u32 = undefined;
    var result_storage: [storage_pixels]u32 = undefined;
    const group = try surface.init(&group_storage, image_width, image_height);
    const mask = try surface.init(&mask_storage, image_width, image_height);
    const result = try surface.init(&result_storage, image_width, image_height);
    var segments: [3]brushes.Segment = undefined;
    const ramp = try brushes.prepareStops(&.{
        .{ .position = 0, .color = .{ 1, 0.1, 0.05, 1 } },
        .{ .position = 0.45, .color = .{ 1, 0.8, 0.1, 1 } },
        .{ .position = 1, .color = .{ 0.05, 0.2, 1, 1 } },
    }, &segments, .{ .space = .oklab }, .pad);
    const painted = try lcgf.prepared.bake(.{
        .rect = .{ .x0 = 14, .y0 = 14, .x1 = 46, .y1 = 44 },
        .radii = .{ .{ 8, 5 }, .{ 3, 7 }, .{ 7, 9 }, .{ 4, 4 } },
    }, .{
        .backgrounds = &.{.{ .brush = .{ .linear = .{ .ramp = ramp, .from = .{ 14, 14 }, .to = .{ 46, 44 } } } }},
        .border = .{ .edges = .{
            .{ .width = 2, .brush = .{ .solid = .{ 1, 1, 1, 1 } } },
            .{ .width = 3, .brush = .{ .solid = .{ 0, 0, 0, 1 } }, .style = .dashed, .dash = 4, .gap = 2, .phase = 1 },
            .{ .width = 4, .brush = .{ .solid = .{ 0.8, 0.1, 1, 1 } } },
            .{ .width = 2, .brush = .{ .solid = .{ 0, 0, 0, 1 } }, .style = .double },
        } },
        .shadows = &.{.{ .offset = .{ 2, 3 }, .sigma = 2, .spread = 1, .color = .{ 0.05, 0.1, 0.2, 0.65 } }},
        .outline = .{ .width = 1, .offset = 2, .brush = .{ .solid = .{ 0.2, 0.4, 1, 1 } } },
    }, 1, &.{}, .sixteen, .{}, &bake_storage, &bake_rgba);
    try compositor.composite(group, painted.image, .{ .offset = .{ @intFromFloat(painted.rect.x0), @intFromFloat(painted.rect.y0) } });
    // A second opaque child overlaps the first: opacity belongs to the completed group.
    try decoration.paint(group, .{ .rect = .{ .x0 = 32, .y0 = 24, .x1 = 54, .y1 = 50 }, .radii = @splat(.{ 5, 5 }) }, .{ .backgrounds = &.{.{ .brush = .{ .solid = .{ 0.15, 0.8, 0.45, 1 } } }} }, .{ .quality = .sixteen });
    var mask_segments: [2]brushes.Segment = undefined;
    const mask_ramp = try brushes.prepareStops(&.{ .{ .position = 0, .color = .{ 1, 1, 1, 0.15 } }, .{ .position = 1, .color = .{ 1, 1, 1, 1 } } }, &mask_segments, .{}, .pad);
    try lcgf.masks.rasterize(mask, &.{.{
        .brush = .{ .linear = .{ .ramp = mask_ramp, .from = .{ 0, 0 }, .to = .{ image_width, 0 } } },
        .region = .{ .rect = .{ .x0 = 6, .y0 = 6, .x1 = 60, .y1 = 60 }, .radii = @splat(.{ 8, 12 }) },
    }}, .{ .quality = .sixteen }, 0);
    try compositor.applyMask(group, mask.view(), .{});
    try compositor.composite(result, group.view(), .{ .opacity = 0.65 });
    try surface.exportRGBA(result, upload, image_width, .straight);
    var translucent: usize = 0;
    var colorful: usize = 0;
    for (upload[0 .. image_width * image_height]) |pixel| {
        const alpha = pixel >> 24;
        translucent += @intFromBool(alpha > 0 and alpha < 255);
        colorful += @intFromBool(alpha > 0 and (pixel & 255) != ((pixel >> 16) & 255));
    }
    try testing.expect(translucent > 1000 and colorful > 500);
    // This is outside the control's border box, so it also proves the prepared shadow/outline
    // extent survives composition and is not accidentally reduced to the original rectangle.
    try testing.expect(upload[28 * image_width + 12] >> 24 > 0);
}

fn compareRenderer(comptime major: u8, h: *host.Host, gfx: anytype, texture: lcgf.types.Texture, upload: []const u32) !void {
    try testing.expectEqual(@as(u16, 1), @backingInt(texture));
    var storage: lcgf.render_conformance.Storage = .{};
    const quads = [_]lcgf.draw_list.Quad{.{
        .rect = .{ 0, 0, image_width, image_height },
        .clip = .{ 0, 0, target_width, target_height },
        .params = @splat(0),
        .uv = .{ 0, 0, 1, 1 },
        .radii = @splat(0),
        .fill = lcgf.types.Color.white.bitsOf(),
        .border_color = 0,
        .border = 0,
        .opacity = 0.83,
        .xform = .{ 1, 0, 0, 1, 9, 7 },
    }};
    const batch: lcgf.draw_list.Batch = .{ .first = 0, .count = 1, .texture = texture, .material = .solid };
    const commands = [_]lcgf.draw_list.Cmd{.{ .quads = batch }};
    const scene: lcgf.render_conformance.Scene = .{ .name = "prepared-styling", .viewport = .{ target_width, target_height }, .quads = &quads, .cmds = &commands, .draws = &.{.{ .source = .quads, .first = 0, .count = 1 }} };
    storage.load(&scene);
    var gpu_target = try host.Target.init(h, target_width, target_height);
    defer gpu_target.deinit(h);
    var pixels: [sw.Framebuffer.len(target_width, target_height)]u32 = undefined;
    var framebuffer = sw.Framebuffer.init(&pixels, target_width, target_height, .rgba8);
    var cpu: sw.Software = .{ .images = &.{ sw.Image.white, .{ .pixels = upload, .width = image_width, .height = image_height } } };
    cpu.prepare({}, &storage.draw, .{}, scene.viewport, 1);
    gfx.prepare({}, &storage.draw, .{}, scene.viewport, 1);
    // Transparent readback catches double premultiplication; an opaque colored backdrop also
    // exercises the destination contribution. Both use the same nearest 1:1 texture samples.
    for ([_]lcgf.types.Color{ .transparent, .rgb(35, 53, 71) }) |background| {
        framebuffer.clear(background);
        cpu.drawBatch(.{ .fb = &framebuffer, .scissor = framebuffer.all() }, batch);
        gpu_target.begin(h, .{ @as(f32, @floatFromInt(background.r)) / 255, @as(f32, @floatFromInt(background.g)) / 255, @as(f32, @floatFromInt(background.b)) / 255, @as(f32, @floatFromInt(background.a)) / 255 });
        gfx.drawBatch({}, batch);
        var rgba: [target_width * target_height * 4]u8 = undefined;
        h.readback(target_width, target_height, &rgba);
        try h.check();
        var maximum: u16 = 0;
        var bad_channels: usize = 0;
        for (0..target_height) |y| for (0..target_width) |x| {
            const expected: [4]u8 = @bitCast(framebuffer.at(@intCast(x), @intCast(y)).bitsOf());
            for (expected, rgba[(y * target_width + x) * 4 ..][0..4]) |want, got| {
                const delta: u16 = @intCast(@abs(@as(i16, want) - @as(i16, got)));
                maximum = @max(maximum, delta);
                bad_channels += @intFromBool(delta > 2);
            }
        };
        // Two byte values allow GL fixed-function blend rounding/mediump interpolation on
        // ES2. A double-premultiplied color is tens of values wrong and cannot pass this gate.
        if (bad_channels > 0) std.debug.print("prepared styling ES{d}: {d} channels exceed 2/255, max {d}/255\n", .{ major, bad_channels, maximum });
        try testing.expectEqual(@as(usize, 0), bad_channels);
    }
}

fn check(comptime major: u8) !void {
    var upload: [image_width * image_height]u32 = undefined;
    try preparedImage(&upload);
    var h: host.Host = undefined;
    try h.init(.{ .major = major });
    defer h.deinit();
    const texture = h.texture(image_width, image_height, std.mem.sliceAsBytes(&upload));
    defer h.deleteTexture(texture);
    if (major == 2) {
        const desc: es2.Desc = .{ .max_quads = 1, .max_glyphs = 1 };
        const scratch = try testing.allocator.alignedAlloc(u8, .of(lcgf.draw_list.Quad), es2.scratchBytes(desc));
        defer testing.allocator.free(scratch);
        var gfx = try es2.Renderer.init(&h.gl, desc, scratch);
        defer gfx.deinit();
        try compareRenderer(major, &h, &gfx, gfx.addTexture(texture, image_width, image_height), &upload);
    } else {
        var gfx = try renderer.Renderer.init(&h.gl, &h.gl3, .{ .max_quads = 1, .max_glyphs = 1 });
        defer gfx.deinit();
        try compareRenderer(major, &h, &gfx, gfx.addTexture(texture), &upload);
    }
    try h.check();
}

test "ES3 prepared gradient border shadow isolated mask texture agrees with software within two bytes" {
    try check(3);
}

test "ES2 prepared gradient border shadow isolated mask texture agrees with software within two bytes" {
    try check(2);
}
