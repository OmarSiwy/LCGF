//! The Zig side of the bindings' Metal gate (bindings/check/run.sh): resources, two pipelines,
//! their bind groups and one frame made through `lcgf_render.gpu` on Metal
//! (src/render/metal/gpu.zig), with the recording Objective-C runtime (objc_record.c) opened in
//! place of the system's. C++ (lcgf/gpu.hpp, LCGF_GPU_METAL) and Rust (lcgf::gpu, `metal`)
//! make the same, and run.sh requires the three logs to be equal: the same messages, with the
//! same arguments, in the same order, the MSL included (by length and hash).
//!
//!   setup:   staging (4 KiB, shared), buffers (64 B vertex/index/uniform, 256 B storage, 16 B
//!            uniform), a 64 x 32 RGBA8 texture, a linear sampler that repeats in u, the
//!            textured pipeline (one float32x2 vertex buffer, premultiplied blending, back faces
//!            culled), the fill compute pipeline, a bind group for each
//!   upload:  writeBuffer(buffer, 0, [1, 2, 3, 4] as f32), finish
//!   pass:    beginRenderPass(color: the texture, clear 0, 0, 0, 1)
//!            setPipeline, setBindGroup(0), setVertexBuffer(0, buffer, 16),
//!            setIndexBuffer(buffer, uint16, 32), setViewport(0, 0, 64, 32, 0, 1),
//!            setScissorRect(8, 8, 16, 16), setBlendConstant(0.5, 0.25, 0, 1),
//!            draw(6, 1, 0, 0), drawIndexed(6, 2, 0, 0, 0), end
//!   inline:  RenderPass.wrap(the host's encoder, 800 x 600): setPipeline, setBindGroup(0),
//!            setScissorRect(10, 20, 30, 40), draw(3, 1, 0, 0), end
//!   compute: setPipeline, setBindGroup(0), dispatchWorkgroups(4, 1, 1), end
//!   teardown: every object destroyed, in the reverse order
//!
//!   lcgf-metal-dump <liblcgf_objc_record.so> <out.txt>

const std = @import("std");
const metal = @import("metal");
const objc = metal.objc;
const gpu = metal.gpu;
const shaders = @import("gpu_shaders");
const Id = objc.Id;

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.next();
    const lib = args.next() orelse return error.Usage;
    const out_path = args.next() orelse return error.Usage;
    const libz: [:0]const u8 = lib;

    try objc.loadFrom(.{ .objc = libz, .metal = libz, .quartz_core = null });
    const device = objc.createSystemDefaultDevice() orelse return error.NoDevice;
    var dev: gpu.Device = .wrap(device);
    const queue = objc.msg(Id, device, "newCommandQueue", .{});
    const cmd = objc.msg(Id, queue, "commandBuffer", .{});

    var host = try gpu.Arena.init(dev, .{ .bytes = 1 << 16, .memory = .host });
    var arena = try gpu.Arena.init(dev, .{ .bytes = 1 << 20 });
    var staging = try gpu.Staging.init(dev, &host, 4096);
    dev.staging = &staging;
    const buffer = try dev.createBuffer(&arena, .{ .size = 64, .usage = .{ .vertex = true, .index = true, .uniform = true, .copy_dst = true } });
    const storage = try dev.createBuffer(&arena, .{ .size = 256, .usage = .{ .storage = true, .copy_src = true } });
    const base = try dev.createBuffer(&arena, .{ .size = 16, .usage = .{ .uniform = true, .copy_dst = true } });
    const texture = try dev.createTexture(&arena, .{ .size = .{ .width = 64, .height = 32 }, .format = .rgba8_unorm, .usage = .{ .texture_binding = true, .render_attachment = true } });
    const sampler = try dev.createSampler(.{ .address_mode_u = .repeat, .mag_filter = .linear, .min_filter = .linear });

    const R = gpu.Shader(shaders.textured);
    const K = gpu.Shader(shaders.fill);
    const pipeline = try dev.createRenderPipeline(R, .{
        .vertex = .{ .entry_point = "vs", .buffers = &.{.{ .array_stride = 8, .attributes = &.{.{ .format = .float32x2, .offset = 0, .shader_location = 0 }} }} },
        .fragment = .{ .entry_point = "fs", .targets = &.{.{ .format = .rgba8_unorm, .blend = .premultiplied }} },
        .primitive = .{ .cull_mode = .back },
    });
    const kpipe = try dev.createComputePipeline(K, .{ .entry_point = "main" });
    const group = try dev.createBindGroup(&arena, &pipeline, 0, .{ .params = buffer, .tex = texture.createView(), .smp = sampler });
    const kgroup = try dev.createBindGroup(&arena, &kpipe, 0, .{ .out = storage, .base = base });

    var up: gpu.Upload = .begin(dev, cmd);
    up.writeBuffer(buffer, 0, std.mem.asBytes(&[4]f32{ 1, 2, 3, 4 }));
    const enc = up.finish();

    var pass = enc.beginRenderPass(.{ .color_attachments = &.{.{ .view = texture.createView(), .clear_value = .{ .a = 1 } }} });
    pass.setPipeline(&pipeline);
    pass.setBindGroup(0, &group);
    pass.setVertexBuffer(0, buffer, 16);
    pass.setIndexBuffer(buffer, .uint16, 32);
    pass.setViewport(0, 0, 64, 32, 0, 1);
    pass.setScissorRect(8, 8, 16, 16);
    pass.setBlendConstant(.{ .r = 0.5, .g = 0.25, .b = 0, .a = 1 });
    pass.draw(6, 1, 0, 0);
    pass.drawIndexed(6, 2, 0, 0, 0);
    pass.end();

    const host_pass = objc.msg(Id, objc.class("MTLRenderPassDescriptor"), "renderPassDescriptor", .{});
    const host_encoder = objc.msg(Id, cmd, "renderCommandEncoderWithDescriptor:", .{host_pass});
    var ui_pass: gpu.RenderPass = .wrap(dev, host_encoder, 800, 600);
    ui_pass.setPipeline(&pipeline);
    ui_pass.setBindGroup(0, &group);
    ui_pass.setScissorRect(10, 20, 30, 40);
    ui_pass.draw(3, 1, 0, 0);
    ui_pass.end();

    var compute = enc.beginComputePass();
    compute.setPipeline(&kpipe);
    compute.setBindGroup(0, &kgroup);
    compute.dispatchWorkgroups(4, 1, 1);
    compute.end();

    dev.destroyComputePipeline(kpipe);
    dev.destroyRenderPipeline(pipeline);
    dev.destroySampler(sampler);
    dev.destroyTexture(texture);
    dev.destroyBuffer(base);
    dev.destroyBuffer(storage);
    dev.destroyBuffer(buffer);
    staging.deinit(dev);

    const handle = std.c.dlopen(libz, .{ .NOW = true }) orelse return error.NoLibrary;
    const log_fn: *const fn (*usize) callconv(.c) [*]const u8 = @ptrCast(@alignCast(std.c.dlsym(handle, "lcgf_objc_record_log") orelse return error.NoLog));
    var len: usize = 0;
    const log = log_fn(&len);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = out_path, .data = log[0..len] });
}
