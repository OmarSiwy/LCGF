//! The Zig side of the bindings' GPU gate (bindings/check/run.sh): one frame recorded through
//! `lcgf_render.gpu` on Vulkan (src/render/vk/gpu.zig) into the recorder (record.c). C++
//! (lcgf/gpu.hpp) and Rust (lcgf::gpu) record the same frame, and run.sh requires the three
//! logs to be equal: the same native calls, with the same arguments, in the same order.
//!
//! The frame, with made-up handles:
//!
//!   upload:  writeBuffer(buffer, 0, [1, 2, 3, 4] as f32), finish
//!   pass:    beginRenderPass(color: the 64 x 32 texture, clear 0, 0, 0, 1)
//!            setPipeline, setBindGroup(0), setVertexBuffer(0, buffer, 16),
//!            setIndexBuffer(buffer, uint16, 32), setViewport(0, 0, 64, 32, 0, 1),
//!            setScissorRect(8, 8, 16, 16), setBlendConstant(0.5, 0.25, 0, 1),
//!            draw(6, 1, 0, 0), drawIndexed(6, 2, 0, 0, 0), end
//!   inline:  RenderPass.wrap(800 x 600): setPipeline, setBindGroup(0),
//!            setScissorRect(10, 20, 30, 40), draw(3, 1, 0, 0), end
//!   compute: setPipeline, setBindGroup(0), dispatchWorkgroups(4, 1, 1), end
//!
//!   lcgf-gpu-dump <out.txt>

const std = @import("std");
const vk = @import("vk");
const gpu = vk.gpu;
const c = vk.c;
const shaders = @import("gpu_shaders");

extern fn lcgf_record_get_device_proc_addr(device: c.VkDevice, name: [*:0]const u8) c.PFN_vkVoidFunction;
extern fn lcgf_record_log(len: *usize) [*]const u8;

fn h(comptime T: type, v: usize) T {
    return @ptrFromInt(v);
}

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.next();
    const out_path = args.next() orelse return error.Usage;

    // A device whose function table is the recorder's.
    var d: vk.device.Device = undefined;
    d.fns = std.mem.zeroes(vk.device.DeviceFns);
    inline for (@typeInfo(vk.device.DeviceFns).@"struct".field_names) |name| {
        if (comptime std.mem.startsWith(u8, name, "vkCmd")) {
            @field(d.fns, name) = @ptrCast(lcgf_record_get_device_proc_addr(null, name));
        }
    }
    const dev: gpu.Device = .wrap(&d);
    const cmd = h(c.VkCommandBuffer, 0xc0);

    const R = gpu.Shader(shaders.textured);
    const K = gpu.Shader(shaders.fill);
    const pipeline: gpu.RenderPipeline(R) = .{ .pipeline = h(c.VkPipeline, 0x4000), .layout = h(c.VkPipelineLayout, 0x4001), .set_layouts = @splat(null) };
    const group: gpu.BindGroup(R, 0) = .{ .set = h(c.VkDescriptorSet, 0x5000), .layout = h(c.VkPipelineLayout, 0x4001) };
    const kpipe: gpu.ComputePipeline(K) = .{ .pipeline = h(c.VkPipeline, 0x4100), .layout = h(c.VkPipelineLayout, 0x4101), .set_layouts = @splat(null) };
    const kgroup: gpu.BindGroup(K, 0) = .{ .set = h(c.VkDescriptorSet, 0x5100), .layout = h(c.VkPipelineLayout, 0x4101) };
    const buffer: gpu.Buffer = .{ .handle = h(c.VkBuffer, 0x2000), .size = 64, .mapped = null };
    const texture: gpu.Texture = .{
        .image = h(c.VkImage, 0x3000),
        .view = h(c.VkImageView, 0x3001),
        .format = .rgba8_unorm,
        .width = 64,
        .height = 32,
        .samples = 1,
        .resting = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    };

    var up: gpu.Upload = .begin(dev, cmd);
    up.writeBuffer(buffer, 0, std.mem.asBytes(&[4]f32{ 1, 2, 3, 4 }));
    const enc = up.finish();

    var pass = enc.beginRenderPass(.{ .color_attachments = &.{.{ .view = texture.createView(), .clear_value = .{ .a = 1 } }} });
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, &group);
    pass.setVertexBuffer(0, buffer, 16);
    pass.setIndexBuffer(buffer, .uint16, 32);
    pass.setViewport(0, 0, 64, 32, 0, 1);
    pass.setScissorRect(8, 8, 16, 16);
    pass.setBlendConstant(.{ .r = 0.5, .g = 0.25, .b = 0, .a = 1 });
    pass.draw(6, 1, 0, 0);
    pass.drawIndexed(6, 2, 0, 0, 0);
    pass.end();

    var ui_pass: gpu.RenderPass = .wrap(dev, cmd, 800, 600);
    ui_pass.setPipeline(pipeline);
    ui_pass.setBindGroup(0, &group);
    ui_pass.setScissorRect(10, 20, 30, 40);
    ui_pass.draw(3, 1, 0, 0);
    ui_pass.end();

    var compute = enc.beginComputePass();
    compute.setPipeline(kpipe);
    compute.setBindGroup(0, &kgroup);
    compute.dispatchWorkgroups(4, 1, 1);
    compute.end();

    var len: usize = 0;
    const log = lcgf_record_log(&len);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = out_path, .data = log[0..len] });
}
