//! A host's own pipeline for inline custom draws, as an application would write one: the
//! goldens' host draw (src/render/conformance/render.py `scene_pipe`), a gradient over the
//! target, scissored to the custom rect. It has its own pipeline layout and push constants,
//! so after it the pass holds nothing the UI set; the conformance scene `custom` checks that
//! the renderer rebinds everything (iface.zig, "Full state rebinding").
//!
//!     var i = iface.drawUntilCustom(&gfx, cmd, draw, 0);
//!     while (i < draw.cmd_len) : (i = iface.drawUntilCustom(&gfx, cmd, draw, i + 1))
//!         gradient.draw(&dev, cmd, gfx.customScissor(draw.customs[draw.command(i).custom]), gfx.extent);
//!
//! Shaders: custom/gradient.{vert,frag}, compiled to SPIR-V with glslangValidator and
//! committed (`nix develop .#shaders -c glslangValidator -V src/render/vk/custom/gradient.frag
//! -o src/render/vk/custom/gradient.frag.spv`, the same for .vert).

const std = @import("std");
const loader = @import("loader.zig");
const device_mod = @import("device.zig");
const c = loader.c;
const Error = loader.Error;
const check = loader.check;
const Device = device_mod.Device;

const vert_spv align(4) = @embedFile("custom/gradient.vert.spv").*;
const frag_spv align(4) = @embedFile("custom/gradient.frag.spv").*;

pub const Gradient = struct {
    layout: c.VkPipelineLayout = null,
    pipeline: c.VkPipeline = null,

    pub fn init(d: *const Device, format: c.VkFormat, samples: u32) Error!Gradient {
        var g: Gradient = .{};
        errdefer g.deinit(d);
        const range: c.VkPushConstantRange = .{ .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT, .size = 8 };
        try check(d.fns.vkCreatePipelineLayout.?(d.handle, &.{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pushConstantRangeCount = 1,
            .pPushConstantRanges = &range,
        }, null, &g.layout));
        var modules: [2]c.VkShaderModule = .{ null, null };
        defer for (modules) |m| if (m != null) d.fns.vkDestroyShaderModule.?(d.handle, m, null);
        for ([_][]const u8{ &vert_spv, &frag_spv }, &modules) |code, *m| try check(d.fns.vkCreateShaderModule.?(d.handle, &.{
            .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .codeSize = code.len,
            .pCode = @ptrCast(@alignCast(code.ptr)),
        }, null, m));
        const stages = [_]c.VkPipelineShaderStageCreateInfo{
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = modules[0], .pName = "main" },
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = modules[1], .pName = "main" },
        };
        const vertex_input: c.VkPipelineVertexInputStateCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
        const assembly: c.VkPipelineInputAssemblyStateCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        };
        const viewport: c.VkPipelineViewportStateCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, .viewportCount = 1, .scissorCount = 1 };
        const raster: c.VkPipelineRasterizationStateCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .polygonMode = c.VK_POLYGON_MODE_FILL,
            .cullMode = c.VK_CULL_MODE_NONE,
            .lineWidth = 1,
        };
        const multisample: c.VkPipelineMultisampleStateCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, .rasterizationSamples = samples };
        // Replaces what is under it, as render.py's host pipeline does (no blending).
        const blend_attachment: c.VkPipelineColorBlendAttachmentState = .{
            .colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT,
        };
        const blend: c.VkPipelineColorBlendStateCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, .attachmentCount = 1, .pAttachments = &blend_attachment };
        const dynamic_states = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
        const dynamic: c.VkPipelineDynamicStateCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO, .dynamicStateCount = dynamic_states.len, .pDynamicStates = &dynamic_states };
        const rendering: c.VkPipelineRenderingCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO, .colorAttachmentCount = 1, .pColorAttachmentFormats = &format };
        try check(d.fns.vkCreateGraphicsPipelines.?(d.handle, null, 1, &.{
            .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .pNext = &rendering,
            .stageCount = stages.len,
            .pStages = &stages,
            .pVertexInputState = &vertex_input,
            .pInputAssemblyState = &assembly,
            .pViewportState = &viewport,
            .pRasterizationState = &raster,
            .pMultisampleState = &multisample,
            .pColorBlendState = &blend,
            .pDynamicState = &dynamic,
            .layout = g.layout,
        }, null, &g.pipeline));
        return g;
    }

    pub fn deinit(g: *Gradient, d: *const Device) void {
        if (g.pipeline != null) d.fns.vkDestroyPipeline.?(d.handle, g.pipeline, null);
        if (g.layout != null) d.fns.vkDestroyPipelineLayout.?(d.handle, g.layout, null);
        g.* = .{};
    }

    /// Records the gradient into `cmd` inside `scissor`, over a target of `extent` pixels. Leaves
    /// its own pipeline, layout, viewport and scissor bound.
    pub fn draw(g: *const Gradient, d: *const Device, cmd: c.VkCommandBuffer, scissor: c.VkRect2D, extent: c.VkExtent2D) void {
        if (scissor.extent.width == 0 or scissor.extent.height == 0) return;
        const size = [2]f32{ @floatFromInt(extent.width), @floatFromInt(extent.height) };
        d.fns.vkCmdBindPipeline.?(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, g.pipeline);
        d.fns.vkCmdSetViewport.?(cmd, 0, 1, &.{ .width = size[0], .height = size[1], .minDepth = 0, .maxDepth = 1 });
        d.fns.vkCmdSetScissor.?(cmd, 0, 1, &scissor);
        d.fns.vkCmdPushConstants.?(cmd, g.layout, c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, 8, &size);
        d.fns.vkCmdDraw.?(cmd, 3, 1, 0, 0);
    }
};
