//! The Vulkan back end proper: draws a `DrawList` into the host's command buffer. Meets the
//! contract in src/render/iface.zig, as the wgpu back end does (prototype/ui_wgpu.zig
//! `Renderer`): `prepare`, `drawBatch`, `drawText`, `render`.
//!
//! WHO OWNS WHAT
//!   You:       instance, device, queue, surface, swapchain, command buffers, the pass
//!              (`pass.begin` / `pass.end`), synchronisation, every image you draw into.
//!   Renderer:  the quad pipelines, their layouts, and what `init` lists below.
//!
//! The shaders are the committed SPIR-V that naga translated from quad.wgsl
//! (src/render/shaders/gen/stock.spv): the same source and vertex layout every back end uses.

const std = @import("std");
const lcgr = @import("lcgr");
const loader = @import("loader.zig");
const device_mod = @import("device.zig");
const c = loader.c;
const Error = loader.Error;
const check = loader.check;
const Device = device_mod.Device;
const types = lcgr.types;
const draw_list = lcgr.draw_list;
const quad_shader = lcgr.quad_shader;
const iface = lcgr.render_iface;
const DrawList = draw_list.DrawList;
const Quad = draw_list.Quad;

/// quad.wgsl's stock shader as SPIR-V (both entry points, `vs` and `fs`). Copied into a
/// u32-aligned array: vkCreateShaderModule reads words.
pub const stock_spv = aligned(@embedFile("stock_spv"));
/// The example material (quad_shader.example_material) as SPIR-V.
pub const example_spv = aligned(@embedFile("example_spv"));

fn aligned(comptime bytes: []const u8) *const [bytes.len / 4]u32 {
    const words = comptime blk: {
        std.debug.assert(bytes.len % 4 == 0);
        var w: [bytes.len / 4]u32 = undefined;
        @memcpy(std.mem.sliceAsBytes(&w), bytes);
        break :blk w;
    };
    return &words;
}

/// Vertex formats of quad_shader.attrs, by name.
fn vkFormat(comptime name: []const u8) c.VkFormat {
    const table = .{
        .{ "float32", c.VK_FORMAT_R32_SFLOAT },
        .{ "float32x2", c.VK_FORMAT_R32G32_SFLOAT },
        .{ "float32x4", c.VK_FORMAT_R32G32B32A32_SFLOAT },
        .{ "uint32x4", c.VK_FORMAT_R32G32B32A32_UINT },
        .{ "unorm8x4", c.VK_FORMAT_R8G8B8A8_UNORM },
    };
    inline for (table) |row| if (comptime std.mem.eql(u8, row[0], name)) return row[1];
    @compileError("unknown vertex format " ++ name);
}

/// Per-instance vertex layout of `Quad`, from quad_shader.attrs so the shader, the dumpers and
/// every back end read the same bytes.
pub const quad_attrs: [quad_shader.attrs.len]c.VkVertexInputAttributeDescription = blk: {
    @setEvalBranchQuota(10_000);
    var out: [quad_shader.attrs.len]c.VkVertexInputAttributeDescription = undefined;
    for (quad_shader.attrs, &out) |a, *o| o.* = .{ .location = a.location, .binding = 0, .format = vkFormat(a.format), .offset = a.offset };
    break :blk out;
};

pub const Globals = lcgr.render_null.Globals;
pub const Glyphs = iface.Glyphs;

pub const Desc = struct {
    /// Format of the images the pass draws into (the swapchain's, or an offscreen target's).
    format: c.VkFormat,
    samples: u32 = 1,
};

pub const max_materials = quad_shader.max_materials;

pub const Renderer = struct {
    desc: Desc,
    /// Set 0: the globals. Set 1: a texture and its sampler. Every pipeline shares both.
    globals_layout: c.VkDescriptorSetLayout = null,
    texture_layout: c.VkDescriptorSetLayout = null,
    pipeline_layout: c.VkPipelineLayout = null,
    pipelines: [max_materials]c.VkPipeline = @splat(null),
    material_count: u16 = 0,

    pub fn init(d: *const Device, desc: Desc) Error!Renderer {
        var r: Renderer = .{ .desc = desc };
        errdefer r.deinit(d);
        const globals_binding: c.VkDescriptorSetLayoutBinding = .{
            .binding = 0,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC,
            .descriptorCount = 1,
            .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
        };
        try check(d.fns.vkCreateDescriptorSetLayout.?(d.handle, &.{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .bindingCount = 1,
            .pBindings = &globals_binding,
        }, null, &r.globals_layout));
        const texture_bindings = [_]c.VkDescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
            .{ .binding = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
        };
        try check(d.fns.vkCreateDescriptorSetLayout.?(d.handle, &.{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .bindingCount = texture_bindings.len,
            .pBindings = &texture_bindings,
        }, null, &r.texture_layout));
        const set_layouts = [_]c.VkDescriptorSetLayout{ r.globals_layout, r.texture_layout };
        try check(d.fns.vkCreatePipelineLayout.?(d.handle, &.{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .setLayoutCount = set_layouts.len,
            .pSetLayouts = &set_layouts,
        }, null, &r.pipeline_layout));
        _ = try r.addMaterial(d, stock_spv); // Material.solid
        return r;
    }

    pub fn deinit(r: *Renderer, d: *const Device) void {
        for (r.pipelines[0..r.material_count]) |p| d.fns.vkDestroyPipeline.?(d.handle, p, null);
        r.material_count = 0;
        if (r.pipeline_layout != null) d.fns.vkDestroyPipelineLayout.?(d.handle, r.pipeline_layout, null);
        if (r.texture_layout != null) d.fns.vkDestroyDescriptorSetLayout.?(d.handle, r.texture_layout, null);
        if (r.globals_layout != null) d.fns.vkDestroyDescriptorSetLayout.?(d.handle, r.globals_layout, null);
        r.pipeline_layout = null;
        r.texture_layout = null;
        r.globals_layout = null;
    }

    /// A quad pipeline with your fragment logic: `quad_shader.shader(your_wgsl_fn)` translated
    /// to SPIR-V (src/render/shaders/translate.sh does it for the shipped variants). Past
    /// `max_materials` the last entry is replaced, as the prototype does.
    pub fn addMaterial(r: *Renderer, d: *const Device, spirv: []const u32) Error!types.Material {
        const i: u16 = @min(r.material_count, max_materials - 1);
        const pipeline = try createPipeline(d, r.pipeline_layout, spirv, r.desc);
        if (i < r.material_count) d.fns.vkDestroyPipeline.?(d.handle, r.pipelines[i], null);
        r.pipelines[i] = pipeline;
        r.material_count = i + 1;
        return @fromBackingInt(i);
    }
};

/// Triangle strip of four vertices per instance, no depth, premultiplied-alpha blending (one,
/// one-minus-src-alpha), viewport and scissor dynamic so a resize needs no new pipeline.
fn createPipeline(d: *const Device, layout: c.VkPipelineLayout, spirv: []const u32, desc: Desc) Error!c.VkPipeline {
    var module: c.VkShaderModule = null;
    try check(d.fns.vkCreateShaderModule.?(d.handle, &.{
        .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = spirv.len * 4,
        .pCode = spirv.ptr,
    }, null, &module));
    defer d.fns.vkDestroyShaderModule.?(d.handle, module, null);
    const stages = [_]c.VkPipelineShaderStageCreateInfo{
        .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = module, .pName = "vs" },
        .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = module, .pName = "fs" },
    };
    const binding: c.VkVertexInputBindingDescription = .{ .binding = 0, .stride = quad_shader.stride, .inputRate = c.VK_VERTEX_INPUT_RATE_INSTANCE };
    const vertex_input: c.VkPipelineVertexInputStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        .vertexBindingDescriptionCount = 1,
        .pVertexBindingDescriptions = &binding,
        .vertexAttributeDescriptionCount = quad_attrs.len,
        .pVertexAttributeDescriptions = &quad_attrs,
    };
    const assembly: c.VkPipelineInputAssemblyStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP,
    };
    const viewport: c.VkPipelineViewportStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .viewportCount = 1,
        .scissorCount = 1,
    };
    const raster: c.VkPipelineRasterizationStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .polygonMode = c.VK_POLYGON_MODE_FILL,
        .cullMode = c.VK_CULL_MODE_NONE,
        .frontFace = c.VK_FRONT_FACE_COUNTER_CLOCKWISE,
        .lineWidth = 1,
    };
    const multisample: c.VkPipelineMultisampleStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .rasterizationSamples = desc.samples,
    };
    const blend_attachment: c.VkPipelineColorBlendAttachmentState = .{
        .blendEnable = c.VK_TRUE,
        .srcColorBlendFactor = c.VK_BLEND_FACTOR_ONE,
        .dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
        .colorBlendOp = c.VK_BLEND_OP_ADD,
        .srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE,
        .dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
        .alphaBlendOp = c.VK_BLEND_OP_ADD,
        .colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT,
    };
    const blend: c.VkPipelineColorBlendStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .attachmentCount = 1,
        .pAttachments = &blend_attachment,
    };
    const dynamic_states = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
    const dynamic: c.VkPipelineDynamicStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .dynamicStateCount = dynamic_states.len,
        .pDynamicStates = &dynamic_states,
    };
    // Dynamic rendering: the pipeline names the attachment format instead of a render pass.
    const rendering: c.VkPipelineRenderingCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
        .colorAttachmentCount = 1,
        .pColorAttachmentFormats = &desc.format,
    };
    var pipeline: c.VkPipeline = null;
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
        .layout = layout,
    }, null, &pipeline));
    return pipeline;
}

const testing = std.testing;
const host = @import("host.zig");

test "renderer: quad pipelines build from the committed SPIR-V on a real device" {
    var h: host.Host = undefined;
    try h.init();
    defer h.deinit();
    var r = try Renderer.init(&h.device, .{ .format = c.VK_FORMAT_R8G8B8A8_UNORM });
    defer r.deinit(&h.device);
    try testing.expectEqual(@as(u16, 1), r.material_count);
    try testing.expect(r.pipelines[0] != null);
    const example = try r.addMaterial(&h.device, example_spv);
    try testing.expectEqual(@as(u16, 1), @backingInt(example));
    // Multisampled targets get their own pipelines.
    var msaa = try Renderer.init(&h.device, .{ .format = c.VK_FORMAT_B8G8R8A8_UNORM, .samples = 4 });
    msaa.deinit(&h.device);
    // Past the cap the last entry is replaced, not written past.
    for (0..max_materials + 2) |_| _ = try r.addMaterial(&h.device, example_spv);
    try testing.expectEqual(@as(u16, max_materials), r.material_count);
}

test "quad_attrs follow the shader's layout of Quad" {
    try testing.expectEqual(@as(u32, @sizeOf(Quad)), quad_shader.stride);
    for (quad_shader.attrs, quad_attrs) |a, b| {
        try testing.expectEqual(a.location, b.location);
        try testing.expectEqual(a.offset, b.offset);
    }
    try testing.expectEqual(@as(c.VkFormat, c.VK_FORMAT_R8G8B8A8_UNORM), quad_attrs[4].format);
}
