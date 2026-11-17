//! Draws every render conformance scene (src/render/conformance.zig) with the wgpu back end over
//! wgpu-native and writes each as a PNG, for comparison with the golden images
//! (ci/jobs/wgpu.sh):
//!
//!     wgpu-play OUT [SAMPLES]      ->  OUT/<scene>.png
//!
//! SAMPLES (default 1) above 1 draws through a multisampled target resolved into the image.
//!
//! Custom commands go through the host's loop (`iface.drawUntilCustom`), drawn by a pipeline of
//! the host's own, so the scene `custom` checks that the renderer rebinds all state after it.
//! The host side mirrors src/render/conformance/render.py, which drew the goldens: an RGBA8
//! target cleared to black, nearest sampling, scale 1, the same stand-in glyph atlas.
const std = @import("std");
const lcgf = @import("lcgf");
const native = @import("native.zig");
const host = native.host;
const c = native.c;
const conformance = lcgf.render_conformance;
const iface = lcgf.render_iface;

var st: conformance.Storage = .{};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    var args = try init.minimal.args.iterateAllocator(gpa);
    _ = args.next();
    const out_path = args.next() orelse return error.MissingOutputDir;
    const samples = try std.fmt.parseInt(u32, args.next() orelse "1", 10);
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, out_path);
    var out = try cwd.openDir(io, out_path, .{});
    defer out.close(io);

    var h = try host.Host.init();
    defer h.deinit();
    var ctx = native.Context.init(h.device);
    defer ctx.deinit();
    const sampler = host.nearestSampler(&h);
    defer c.wgpuSamplerRelease(sampler);
    var white = host.Image.init(&h, 1, 1, &.{ 0xff, 0xff, 0xff, 0xff });
    defer white.deinit();
    var gfx = native.Renderer.init(&ctx, .{ .format = c.WGPUTextureFormat_RGBA8Unorm, .sample_count = samples }, white.view, sampler);
    defer gfx.deinit();

    // The goldens' stand-in glyph atlas (render.py): 16x16 cells of 4x4 texels, every printable
    // byte a 2x3 block. Packed into a coverage atlas and uploaded like a real one.
    var atlas_px: [64 * 64]u8 = undefined;
    var sky: [3][64]u32 = undefined;
    var atlas = lcgf.raster_atlas.Atlas.init(64, 64, &atlas_px, .{ .x = &sky[0], .y = &sky[1], .w = &sky[2] });
    for (33..127) |byte| atlas.put(.{ .x = @intCast((byte & 15) * 4 + 1), .y = @intCast((byte >> 4) * 4 + 1), .w = 2, .h = 3 }, &@as([6]u8, @splat(255)));
    var atlas_tex = native.glyphs.GlyphTexture.init(h.device, 64, 64);
    defer atlas_tex.deinit();
    const atlas_handle = gfx.addTexture(&ctx, atlas_tex.view, sampler);

    for (&conformance.scenes) |*s| {
        st.load(s);
        const w: u32 = @intFromFloat(s.viewport[0]);
        const ht: u32 = @intFromFloat(s.viewport[1]);
        var target = host.Target.init(&h, w, ht, c.WGPUTextureFormat_RGBA8Unorm);
        defer target.deinit();

        _ = atlas_tex.upload(h.queue, &atlas);
        var glyphs = st.glyphs();
        glyphs.texture = atlas_handle;
        gfx.prepare(h.queue, &st.draw, glyphs, s.viewport, 1);
        const encoder = c.wgpuDeviceCreateCommandEncoder(h.device, null);
        var msaa: ?native.Multisample = if (samples > 1) .init(h.device, w, ht, c.WGPUTextureFormat_RGBA8Unorm, samples) else null;
        defer if (msaa) |*m| m.deinit();
        const pass = if (msaa) |m|
            host.beginPass(encoder, m.view, target.view, .{ 0, 0, 0, 1 })
        else
            host.beginPass(encoder, target.view, null, .{ 0, 0, 0, 1 });
        // The host's loop: UI draws up to each custom command, the host's own draw there.
        const scene = hostPipeline(h.device, w, ht, samples);
        defer c.wgpuRenderPipelineRelease(scene);
        var i = iface.drawUntilCustom(&gfx, pass, &st.draw, 0);
        while (i < st.draw.cmd_len) : (i = iface.drawUntilCustom(&gfx, pass, &st.draw, i + 1)) {
            const r = st.draw.customs[st.draw.command(i).custom].rect;
            const x0: u32 = @intFromFloat(std.math.clamp(r[0], 0, s.viewport[0]));
            const y0: u32 = @intFromFloat(std.math.clamp(r[1], 0, s.viewport[1]));
            const x1: u32 = @intFromFloat(std.math.clamp(r[2], r[0], s.viewport[0]));
            const y1: u32 = @intFromFloat(std.math.clamp(r[3], r[1], s.viewport[1]));
            c.wgpuRenderPassEncoderSetPipeline(pass, scene);
            c.wgpuRenderPassEncoderSetScissorRect(pass, x0, y0, x1 - x0, y1 - y0);
            c.wgpuRenderPassEncoderDraw(pass, 3, 1, 0, 0);
            c.wgpuRenderPassEncoderSetScissorRect(pass, 0, 0, w, ht);
        }
        host.endPass(pass);
        h.submit(encoder);

        const px = try gpa.alloc(u8, @as(usize, w) * ht * 4);
        try h.readback(&target, px);
        var name: [64]u8 = undefined;
        try out.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&name, "{s}.png", .{s.name}), .data = try png(gpa, w, ht, px) });
    }
}

/// The goldens' host draw for a custom command (render.py `scene_pipe`): one triangle over the
/// whole target, a gradient over position, replacing what is under it; the scissor limits it to
/// the custom rect. Its own pipeline and layout: the UI's state is gone after it.
fn hostPipeline(device: c.WGPUDevice, w: u32, h: u32, samples: u32) c.WGPURenderPipeline {
    var buf: [512]u8 = undefined;
    const wgsl = std.fmt.bufPrint(&buf,
        \\@vertex fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {{
        \\  return vec4f(f32(i & 1u) * 4.0 - 1.0, f32(i >> 1u) * 4.0 - 1.0, 0.0, 1.0); }}
        \\@fragment fn fs(@builtin(position) p: vec4f) -> @location(0) vec4f {{
        \\  return vec4f(p.x / {d}.0 * 0.5, 0.25, p.y / {d}.0 * 0.6, 1.0); }}
    , .{ w, h }) catch unreachable;
    const source: c.WGPUShaderSourceWGSL = .{ .chain = .{ .sType = c.WGPUSType_ShaderSourceWGSL }, .code = host.sv(wgsl) };
    const module = c.wgpuDeviceCreateShaderModule(device, &.{ .nextInChain = @constCast(&source.chain) });
    defer c.wgpuShaderModuleRelease(module);
    const color: c.WGPUColorTargetState = .{ .format = c.WGPUTextureFormat_RGBA8Unorm, .writeMask = c.WGPUColorWriteMask_All };
    const fragment: c.WGPUFragmentState = .{ .module = module, .entryPoint = host.sv("fs"), .targetCount = 1, .targets = &color };
    return c.wgpuDeviceCreateRenderPipeline(device, &.{
        .vertex = .{ .module = module, .entryPoint = host.sv("vs") },
        .primitive = .{ .topology = c.WGPUPrimitiveTopology_TriangleList },
        .multisample = .{ .count = samples, .mask = 0xffff_ffff },
        .fragment = &fragment,
    });
}

/// RGBA rows as a PNG with stored (uncompressed) deflate blocks.
fn png(gpa: std.mem.Allocator, w: u32, h: u32, rgba: []const u8) ![]const u8 {
    var raw: std.ArrayList(u8) = .empty;
    for (0..h) |y| {
        try raw.append(gpa, 0); // filter: none
        try raw.appendSlice(gpa, rgba[y * w * 4 ..][0 .. w * 4]);
    }
    var z: std.ArrayList(u8) = .empty;
    try z.appendSlice(gpa, &.{ 0x78, 0x01 });
    var rest = raw.items;
    while (true) {
        const n: u16 = @intCast(@min(rest.len, 0xffff));
        const last = n == rest.len;
        try z.append(gpa, @intFromBool(last));
        try z.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, n)));
        try z.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, ~n)));
        try z.appendSlice(gpa, rest[0..n]);
        rest = rest[n..];
        if (last) break;
    }
    try z.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u32, std.hash.Adler32.hash(raw.items))));

    var file: std.ArrayList(u8) = .empty;
    try file.appendSlice(gpa, "\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8..13].* = .{ 8, 6, 0, 0, 0 };
    for ([_]struct { []const u8, []const u8 }{ .{ "IHDR", &ihdr }, .{ "IDAT", z.items }, .{ "IEND", "" } }) |chunk| {
        try file.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(chunk[1].len))));
        try file.appendSlice(gpa, chunk[0]);
        try file.appendSlice(gpa, chunk[1]);
        var crc = std.hash.Crc32.init();
        crc.update(chunk[0]);
        crc.update(chunk[1]);
        try file.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u32, crc.final())));
    }
    return file.items;
}
