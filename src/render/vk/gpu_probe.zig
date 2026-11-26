//! The projection's zero-cost check (ci/jobs/gpu-zero-cost.sh): the same custom draw recorded
//! twice over the same data, once with Vulkan calls written by hand (what the back end's own
//! Gradient.draw did before src/render/gpu/gradient.zig replaced it) and once through
//! lcgf_render.gpu. Each reads its application's state
//! through a pointer, laid out the same way, as a real draw function would. Built ReleaseFast;
//! the job disassembles both exported functions and requires the same instructions.

const gpu = @import("gpu.zig");
const device = @import("device.zig");
const c = gpu.vk;
const S = gpu.Shader(@import("gpu_shaders").gradient);

/// What a hand-written host keeps: its pipeline (with layout and set layouts) and its set.
const Native = extern struct {
    pipeline: c.VkPipeline,
    layout: c.VkPipelineLayout,
    set_layouts: [gpu.max_groups]c.VkDescriptorSetLayout,
    set: c.VkDescriptorSet,
    set_pipeline_layout: c.VkPipelineLayout,
};

/// The same through the projection's types.
const Projected = extern struct {
    pipeline: gpu.RenderPipeline(S),
    group: gpu.BindGroup(S, 0),
};

comptime {
    if (@sizeOf(Native) != @sizeOf(Projected)) @compileError("the probe's two states must have the same layout");
}

export fn probe_native(fns: *const device.DeviceFns, cmd: c.VkCommandBuffer, app: *const Native, x: u32, y: u32, w: u32, h: u32, tw: f32, th: f32) void {
    fns.vkCmdSetViewport.?(cmd, 0, 1, &.{ .x = 0, .y = 0, .width = tw, .height = th, .minDepth = 0, .maxDepth = 1 });
    fns.vkCmdSetScissor.?(cmd, 0, 1, &.{ .offset = .{ .x = @intCast(x), .y = @intCast(y) }, .extent = .{ .width = w, .height = h } });
    fns.vkCmdBindPipeline.?(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, app.pipeline);
    fns.vkCmdBindDescriptorSets.?(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, app.set_pipeline_layout, 0, 1, &app.set, 0, null);
    fns.vkCmdDraw.?(cmd, 3, 1, 0, 0);
}

export fn probe_gpu(fns: *const device.DeviceFns, cmd: c.VkCommandBuffer, app: *const Projected, x: u32, y: u32, w: u32, h: u32, tw: f32, th: f32) void {
    var pass: gpu.RenderPass = .{ .cmd = cmd, .fns = fns, .width = x + w, .height = y + h };
    pass.setViewport(0, 0, tw, th, 0, 1);
    pass.setScissorRect(x, y, w, h);
    pass.setPipeline(app.pipeline);
    pass.setBindGroup(0, &app.group);
    pass.draw(3, 1, 0, 0);
}
