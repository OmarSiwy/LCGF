//! Draws every render conformance scene (src/render/conformance.zig) with the Metal back end
//! and writes each as a PNG, for comparison with the golden images (ci/jobs/metal.sh, macOS):
//!
//!     metal-play OUT      ->  OUT/<scene>.png, OUT/canvas.png
//!
//! The host side mirrors src/render/conformance/render.py, which drew the goldens: an RGBA8
//! target cleared to black, nearest sampling, scale 1, the same stand-in glyph atlas. Custom
//! commands are drawn between the UI's draws through lcgf_render.gpu
//! (src/render/gpu/gradient.zig, the same code every back end runs). The
//! target is managed storage, synchronised by a blit before it is read, so the same code runs
//! on Apple silicon and on Intel Macs with a discrete GPU.
const std = @import("std");
const lcgf = @import("lcgf");
const metal = @import("metal.zig");
const objc = metal.objc;
const mtl = metal.mtl;
const present = metal.present;
const conformance = lcgf.render_conformance;
const iface = lcgf.render_iface;
const Id = objc.Id;
const U = objc.NSUInteger;
const gpu = metal.gpu;
const Gradient = lcgf.gpu_gradient.Gradient(gpu, @import("gpu_shaders").gradient);

var st: conformance.Storage = .{};
var canvas: conformance.CanvasStorage = undefined;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    var args = try init.minimal.args.iterateAllocator(gpa);
    _ = args.next();
    const out_path = args.next() orelse return error.MissingOutputDir;
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, out_path);
    var out = try cwd.openDir(io, out_path, .{});
    defer out.close(io);

    try objc.load();
    const pool = objc.Pool.push();
    defer pool.pop();
    var dev = try metal.device.Device.init();
    defer dev.deinit();
    std.debug.print("metal-play: {s}\n", .{dev.name()});
    var gfx = try metal.Renderer.init(dev.device, .{ .format = .rgba8_unorm, .frames_in_flight = 1 });
    defer gfx.deinit();
    const atlas_px = standInAtlas();
    const atlas = try metal.texture.rgba8(dev.device, 64, 64, &atlas_px);
    defer objc.release(atlas);
    const atlas_handle = gfx.addTexture(atlas, null);
    var gdev: gpu.Device = .wrap(dev.device);
    var arena: gpu.Arena = try .init(gdev, .{ .bytes = 0 });
    var host_arena: gpu.Arena = try .init(gdev, .{ .bytes = 0, .memory = .host });
    var staging: gpu.Staging = try .init(gdev, &host_arena, 64 * 1024);
    defer staging.deinit(gdev);
    gdev.staging = &staging;
    var gradient: Gradient = try .init(gdev, &arena, .{ .format = .rgba8_unorm });
    defer gradient.deinit(gdev);

    for (&conformance.scenes) |*s| {
        const frame = objc.Pool.push();
        defer frame.pop();
        st.load(s);
        const w: u32 = @intFromFloat(s.viewport[0]);
        const h: u32 = @intFromFloat(s.viewport[1]);
        const target = try renderTarget(dev.device, w, h);
        defer objc.release(target);
        var glyphs = st.glyphs();
        glyphs.texture = atlas_handle;
        gfx.prepare({}, &st.draw, glyphs, s.viewport, 1);
        const cmd = objc.msg(Id, dev.queue, "commandBuffer", .{});
        // The frame's upload phase: the gradient's target size. Each frame waits for the last.
        staging.rewind();
        var up: gpu.Upload = .begin(gdev, cmd);
        gradient.upload(&up, gfx.extent[0], gfx.extent[1]);
        _ = up.finish();
        const pass = present.beginPass(cmd, target, .{ 0, 0, 0, 1 });
        // The host's loop: UI draws up to each custom command, the custom draw there.
        var gp: gpu.RenderPass = .wrap(gdev, pass.id, gfx.extent[0], gfx.extent[1]);
        var i = iface.drawUntilCustom(&gfx, pass, &st.draw, 0);
        while (i < st.draw.cmd_len) : (i = iface.drawUntilCustom(&gfx, pass, &st.draw, i + 1)) {
            const k = st.draw.customs[st.draw.command(i).custom];
            gradient.draw(&gp, gpu.scissor(k.rect, k.clip, gfx.scale, gfx.extent[0], gfx.extent[1]), gfx.extent[0], gfx.extent[1]);
        }
        present.endPass(pass);
        const blit = objc.msg(Id, cmd, "blitCommandEncoder", .{});
        objc.msg(void, blit, "synchronizeResource:", .{target});
        objc.msg(void, blit, "endEncoding", .{});
        objc.msg(void, cmd, "commit", .{});
        objc.msg(void, cmd, "waitUntilCompleted", .{});
        if (objc.msg(U, cmd, "status", .{}) != command_buffer_completed) return error.GpuError;
        const px = try gpa.alloc(u8, @as(usize, w) * h * 4);
        const region: mtl.Region = .{ .size = .{ .width = w, .height = h } };
        objc.msg(void, target, "getBytes:bytesPerRow:fromRegion:mipmapLevel:", .{ px.ptr, @as(U, w * 4), region, @as(U, 0) });
        var name: [64]u8 = undefined;
        try out.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&name, "{s}.png", .{s.name}), .data = try png(gpa, w, h, px) });
    }

    // The canvas scene (golden tools/golden/ref/draw/canvas.png), by a renderer with the canvas
    // pipeline.
    const sc = conformance.canvas_scene;
    canvas.load();
    var cgfx = try metal.CanvasRenderer.init(dev.device, .{ .format = .rgba8_unorm, .frames_in_flight = 1, .canvas_rows = sc.rows, .canvas_verts = sc.verts });
    defer cgfx.deinit();
    const catlas = cgfx.addTexture(atlas, null);
    const w: u32 = @intFromFloat(sc.viewport[0]);
    const h: u32 = @intFromFloat(sc.viewport[1]);
    const target = try renderTarget(dev.device, w, h);
    defer objc.release(target);
    cgfx.prepare({}, &canvas.draw, .{ .texture = catlas }, sc.viewport, 1);
    const cmd = objc.msg(Id, dev.queue, "commandBuffer", .{});
    const pass = present.beginPass(cmd, target, .{ 13.0 / 255.0, 13.0 / 255.0, 15.0 / 255.0, 1 });
    iface.render(&cgfx, pass, &canvas.draw);
    present.endPass(pass);
    const blit = objc.msg(Id, cmd, "blitCommandEncoder", .{});
    objc.msg(void, blit, "synchronizeResource:", .{target});
    objc.msg(void, blit, "endEncoding", .{});
    objc.msg(void, cmd, "commit", .{});
    objc.msg(void, cmd, "waitUntilCompleted", .{});
    if (objc.msg(U, cmd, "status", .{}) != command_buffer_completed) return error.GpuError;
    const px = try gpa.alloc(u8, @as(usize, w) * h * 4);
    const region: mtl.Region = .{ .size = .{ .width = w, .height = h } };
    objc.msg(void, target, "getBytes:bytesPerRow:fromRegion:mipmapLevel:", .{ px.ptr, @as(U, w * 4), region, @as(U, 0) });
    try out.writeFile(io, .{ .sub_path = "canvas.png", .data = try png(gpa, w, h, px) });
}

/// MTLCommandBufferStatusCompleted.
const command_buffer_completed: U = 4;

/// An RGBA8 render target the CPU can read back. Caller releases it.
fn renderTarget(device: Id, w: u32, h: u32) !Id {
    const desc = objc.msg(Id, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{ mtl.PixelFormat.rgba8_unorm, @as(U, w), @as(U, h), @as(objc.BOOL, false) });
    objc.msg(void, desc, "setUsage:", .{mtl.texture_usage_render_target | mtl.texture_usage_shader_read});
    objc.msg(void, desc, "setStorageMode:", .{mtl.storage_mode_managed});
    return objc.msg(?Id, device, "newTextureWithDescriptor:", .{desc}) orelse error.TextureFailed;
}

/// render.py's stand-in glyph atlas: 16x16 cells of 4x4 texels, every printable byte a 2x3
/// block of opaque white.
fn standInAtlas() [64 * 64 * 4]u8 {
    var px: [64 * 64 * 4]u8 = @splat(0);
    for (33..127) |byte| {
        const cx = byte & 15;
        const cy = byte >> 4;
        for (1..4) |y| for (1..3) |x| {
            const o = ((cy * 4 + y) * 64 + cx * 4 + x) * 4;
            px[o..][0..4].* = @splat(0xff);
        };
    }
    return px;
}

/// RGBA rows as a PNG (filter byte 0 before each row).
fn png(gpa: std.mem.Allocator, w: u32, h: u32, rgba: []const u8) ![]const u8 {
    var raw: std.ArrayList(u8) = .empty;
    for (0..h) |y| {
        try raw.append(gpa, 0);
        try raw.appendSlice(gpa, rgba[y * w * 4 ..][0 .. w * 4]);
    }
    return lcgf.png.encodeForTest(gpa, w, h, 8, .rgba, false, &.{}, raw.items);
}
