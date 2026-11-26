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
const lcgf = @import("lcgf");
const loader = @import("loader.zig");
const device_mod = @import("device.zig");
const c = loader.c;
const Error = loader.Error;
const check = loader.check;
const Device = device_mod.Device;
const types = lcgf.types;
const draw_list = lcgf.draw_list;
const quad_shader = lcgf.quad_shader;
const iface = lcgf.render_iface;
const DrawList = draw_list.DrawList;
const Quad = draw_list.Quad;
const gpu = @import("gpu.zig");

/// canvas.wgsl as SPIR-V, for the canvas pipeline (src/render/gpu/canvas.zig).
const canvas_source = struct {
    pub const wgsl = lcgf.canvas_shader.wgsl;
    pub const spv = @embedFile("canvas_spv");
};
pub const Canvas = lcgf.gpu_canvas.Canvas(gpu, canvas_source);

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

pub const Globals = lcgf.render_null.Globals;
pub const Glyphs = iface.Glyphs;

pub const Desc = struct {
    /// Format of the images the pass draws into (the swapchain's, or an offscreen target's).
    format: c.VkFormat,
    samples: u32 = 1,
    /// Capacities of each ring slot, which is host-visible memory (pinned system memory on a
    /// discrete GPU), `frames` times over: 136 bytes per quad. The defaults are what a frame
    /// of the default `Limits` can hold: one quad per node (4096), and a 1920x1080 screen
    /// filled with 8x16-pixel glyphs (16200). 2.8 MB per slot; the prototype's 16K and 32K
    /// were 6.5 MB, 13 MB with two slots. Raise them for larger frames: past them quads and
    /// glyphs are dropped.
    max_quads: u32 = 4 * 1024,
    max_glyphs: u32 = 16 * 1024,
    /// Frames the host lets the GPU work on while it prepares the next: one ring slot each.
    frames: u32 = 2,
    /// Canvas instance rows and polygon vertices kept on the GPU (`frames` copies of 32 and 8
    /// bytes each, host-visible); 0 rows: no canvas pipeline, and canvases draw nothing.
    canvas_rows: u32 = 0,
    canvas_verts: u32 = 0,
};

/// Bytes kept for the globals at the start of each slot: the largest
/// minUniformBufferOffsetAlignment the spec allows, so slot offsets are valid dynamic offsets
/// on every device.
const globals_slot = 256;

pub const max_materials = quad_shader.max_materials;

pub const Renderer = struct {
    desc: Desc,
    /// The device it was created on; must outlive it.
    dev: *const Device,
    /// Set 0: the globals. Set 1: a texture and its sampler. Every pipeline shares both.
    globals_layout: c.VkDescriptorSetLayout = null,
    texture_layout: c.VkDescriptorSetLayout = null,
    pipeline_layout: c.VkPipelineLayout = null,
    pipelines: [max_materials]c.VkPipeline = @splat(null),
    material_count: u16 = 0,
    /// One host-visible, coherent buffer, mapped once for its whole life, cut into
    /// `desc.frames` slots of [globals | quads | glyph quads]. `prepare` writes slot `frame`
    /// with plain memcpy: no staging copy, no map/unmap, no per-frame allocation.
    ring: device_mod.Buffer = .{ .size = 0 },
    slot_bytes: u64 = 0,
    /// Offset of the slot the last `prepare` wrote.
    base: u64 = 0,
    /// Physical pixels: viewport * scale from the last `prepare`.
    extent: c.VkExtent2D = .{ .width = 0, .height = 0 },
    scale: f32 = 1,
    glyphs: Glyphs = .{},
    /// Set 0 points at the ring's globals; each draw picks the slot with a dynamic offset. Set
    /// i of `textures` is `Texture` i. All come from one pool sized once at init.
    pool: c.VkDescriptorPool = null,
    globals_set: c.VkDescriptorSet = null,
    textures: [max_textures]c.VkDescriptorSet = @splat(null),
    /// The views behind `textures`, for the canvas pipeline's glyph atlas.
    views: [max_textures]c.VkImageView = @splat(null),
    texture_count: u16 = 0,
    canvas: ?Canvas = null,
    list: ?*const DrawList = null,

    pub const max_textures = 64;

    /// `prepare` takes the frame slot (0 to `desc.frames - 1`): the host's frame index, whose
    /// fence it waited on, so the GPU is done reading that slot.
    pub const Queue = u32;
    /// The host's command buffer, inside `pass.begin` / `pass.end`. It is the raw Vulkan
    /// handle, not a wrapper: at a custom command (`iface.drawUntilCustom` stops there) the
    /// host records its own vkCmd* into it, with its own pipeline, layout, descriptor sets and
    /// push constants, then hands it back. Nothing needs restoring: the next UI draw rebinds
    /// every piece of state it uses. `customScissor` gives the custom rect in pixels.
    pub const Pass = c.VkCommandBuffer;

    /// `white` is a 1x1 opaque white image view; it becomes `Texture.white`.
    pub fn init(d: *const Device, desc: Desc, white: c.VkImageView, sampler: c.VkSampler) gpu.Error!Renderer {
        var r: Renderer = .{ .desc = desc, .dev = d };
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
        r.slot_bytes = std.mem.alignForward(u64, globals_slot + (@as(u64, desc.max_quads) + desc.max_glyphs) * quad_shader.stride, globals_slot);
        r.ring = try d.createBuffer(r.slot_bytes * desc.frames, c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, true);

        const sizes = [_]c.VkDescriptorPoolSize{
            .{ .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC, .descriptorCount = 1 },
            .{ .type = c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .descriptorCount = max_textures },
            .{ .type = c.VK_DESCRIPTOR_TYPE_SAMPLER, .descriptorCount = max_textures },
        };
        try check(d.fns.vkCreateDescriptorPool.?(d.handle, &.{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .maxSets = 1 + max_textures,
            .poolSizeCount = sizes.len,
            .pPoolSizes = &sizes,
        }, null, &r.pool));
        r.globals_set = try r.allocateSet(d, r.globals_layout);
        const globals_info: c.VkDescriptorBufferInfo = .{ .buffer = r.ring.handle, .offset = 0, .range = @sizeOf(Globals) };
        d.fns.vkUpdateDescriptorSets.?(d.handle, 1, &.{
            .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = r.globals_set,
            .dstBinding = 0,
            .descriptorCount = 1,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC,
            .pBufferInfo = &globals_info,
        }, 0, null);
        _ = try r.addTexture(d, white, sampler); // Texture.white
        if (desc.canvas_rows > 0) {
            r.canvas = @as(Canvas, undefined);
            try r.canvas.?.init(.wrap(d), .{ .format = gpu.fromVkFormat(desc.format), .samples = desc.samples }, .{ .rows = desc.canvas_rows, .verts = desc.canvas_verts, .frames = desc.frames });
        }
        return r;
    }

    pub fn deinit(r: *Renderer, d: *const Device) void {
        if (r.canvas) |*cv| cv.deinit(.wrap(d));
        r.canvas = null;
        if (r.pool != null) d.fns.vkDestroyDescriptorPool.?(d.handle, r.pool, null); // frees the sets
        r.pool = null;
        r.texture_count = 0;
        if (r.ring.handle != null) d.destroyBuffer(&r.ring);
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

    fn allocateSet(r: *const Renderer, d: *const Device, layout: c.VkDescriptorSetLayout) Error!c.VkDescriptorSet {
        var set: c.VkDescriptorSet = null;
        try check(d.fns.vkAllocateDescriptorSets.?(d.handle, &.{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .descriptorPool = r.pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &layout,
        }, &set));
        return set;
    }

    fn writeTexture(d: *const Device, set: c.VkDescriptorSet, view: c.VkImageView, sampler: c.VkSampler) void {
        const image: c.VkDescriptorImageInfo = .{ .imageView = view, .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
        const samp: c.VkDescriptorImageInfo = .{ .sampler = sampler };
        const writes = [_]c.VkWriteDescriptorSet{
            .{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .dstBinding = 0, .descriptorCount = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .pImageInfo = &image },
            .{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .dstBinding = 1, .descriptorCount = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_SAMPLER, .pImageInfo = &samp },
        };
        d.fns.vkUpdateDescriptorSets.?(d.handle, writes.len, &writes, 0, null);
    }

    /// Texture in: makes an image view (in SHADER_READ_ONLY_OPTIMAL) usable as `Style.texture`.
    /// The image, view and sampler stay yours, alive while a frame may sample them. Handles are
    /// indices in registration order; `Texture.white` is 0. Past `max_textures` the last entry
    /// is rewritten, as the prototype does; rewriting a set needs every frame that used it
    /// finished (Vulkan forbids updating a set a pending command buffer uses).
    pub fn addTexture(r: *Renderer, d: *const Device, view: c.VkImageView, sampler: c.VkSampler) Error!types.Texture {
        const i: u16 = @min(r.texture_count, max_textures - 1);
        if (i == r.texture_count) r.textures[i] = try r.allocateSet(d, r.texture_layout);
        writeTexture(d, r.textures[i], view, sampler);
        r.views[i] = view;
        r.texture_count = i + 1;
        return @fromBackingInt(i);
    }

    /// Points an existing handle at another view (a target recreated at a new size, an atlas
    /// that grew); nodes keep their `Style.texture`. Same rule as `addTexture`: no frame that
    /// samples the old set may still be pending. A stale handle clamps to the last entry.
    pub fn setTexture(r: *Renderer, d: *const Device, texture: types.Texture, view: c.VkImageView, sampler: c.VkSampler) void {
        const i = @min(@backingInt(texture), r.texture_count - 1);
        writeTexture(d, r.textures[i], view, sampler);
        r.views[i] = view;
    }

    /// Full state, every draw (iface.zig, "Full state rebinding"): pipeline, both sets, the
    /// instance buffer at this frame's slot, viewport and scissor. Handles are clamped rather
    /// than checked: a stale handle draws with the last valid entry.
    fn bind(r: *const Renderer, d: *const Device, cmd: c.VkCommandBuffer, material: types.Material, texture: types.Texture, at: u64) void {
        d.fns.vkCmdBindPipeline.?(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, r.pipelines[@min(@backingInt(material), r.material_count - 1)]);
        const sets = [_]c.VkDescriptorSet{ r.globals_set, r.textures[@min(@backingInt(texture), r.texture_count - 1)] };
        const dynamic_offset: u32 = @intCast(r.base);
        d.fns.vkCmdBindDescriptorSets.?(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, r.pipeline_layout, 0, sets.len, &sets, 1, &dynamic_offset);
        const offset: c.VkDeviceSize = r.base + at;
        d.fns.vkCmdBindVertexBuffers.?(cmd, 0, 1, &r.ring.handle, &offset);
        d.fns.vkCmdSetViewport.?(cmd, 0, 1, &.{ .width = @floatFromInt(r.extent.width), .height = @floatFromInt(r.extent.height), .minDepth = 0, .maxDepth = 1 });
        d.fns.vkCmdSetScissor.?(cmd, 0, 1, &.{ .extent = r.extent });
    }

    /// Offsets inside a slot.
    fn quadsAt(r: *const Renderer) u64 {
        _ = r;
        return globals_slot;
    }
    fn glyphsAt(r: *const Renderer) u64 {
        return globals_slot + @as(u64, r.desc.max_quads) * quad_shader.stride;
    }

    /// Uploads the frame into ring slot `frame`: three memcpy into mapped memory. Quads past
    /// `max_quads` (glyphs past `max_glyphs`) are dropped, as the wgpu back end does. Call before
    /// recording the frame's draws.
    pub fn prepare(r: *Renderer, frame: Queue, draw: *const DrawList, glyphs: Glyphs, viewport: [2]f32, scale: f32) void {
        r.base = @as(u64, frame % r.desc.frames) * r.slot_bytes;
        const slot = r.ring.mapped[@intCast(r.base)..][0..@intCast(r.slot_bytes)];
        const g: Globals = .{ .viewport = viewport, .scale = scale };
        @memcpy(slot[0..@sizeOf(Globals)], std.mem.asBytes(&g));
        const quad_bytes = draw.quadBytes();
        const qn = @min(quad_bytes.len, @as(usize, r.desc.max_quads) * quad_shader.stride);
        @memcpy(slot[@intCast(r.quadsAt())..][0..qn], quad_bytes[0..qn]);
        const glyph_bytes = std.mem.sliceAsBytes(glyphs.quads);
        const gn = @min(glyph_bytes.len, @as(usize, r.desc.max_glyphs) * quad_shader.stride);
        @memcpy(slot[@intCast(r.glyphsAt())..][0..gn], glyph_bytes[0..gn]);
        r.glyphs = glyphs;
        r.scale = scale;
        r.extent = .{ .width = @intFromFloat(@round(viewport[0] * scale)), .height = @intFromFloat(@round(viewport[1] * scale)) };
        r.list = draw;
        if (r.canvas) |*cv| {
            const atlas = @min(@backingInt(glyphs.texture), r.texture_count - 1);
            cv.prepare(.wrap(r.dev), null, draw, frame, scale, .{ r.extent.width, r.extent.height }, .{ .view = r.views[atlas], .image = null, .width = 0, .height = 0 }, atlas);
        }
    }

    /// Canvas command `k` (`iface.drawsCanvas`): one instanced draw per range, with the canvas
    /// pipeline, scissored to the node. Needs `Desc.canvas_rows`; the host calls
    /// `Instances.clearDirty` after `prepare` (src/render/gpu/canvas.zig).
    pub fn drawCanvas(r: *const Renderer, cmd: Pass, k: u32) void {
        const cv = if (r.canvas) |*cv| cv else return;
        var pass = gpu.RenderPass.wrap(.wrap(r.dev), cmd, r.extent.width, r.extent.height);
        cv.draw(&pass, r.list.?, k);
    }

    /// One instanced draw for a run of quads. `Pass` carries no device, so the renderer keeps
    /// the function table it was created with.
    pub fn drawBatch(r: *const Renderer, cmd: Pass, batch: draw_list.Batch) void {
        r.bind(r.dev, cmd, batch.material, batch.texture, r.quadsAt());
        r.dev.fns.vkCmdDraw.?(cmd, 4, batch.count, 0, batch.first);
    }

    /// One instanced draw for a text run's glyphs.
    pub fn drawText(r: *const Renderer, cmd: Pass, run: u32) void {
        r.drawGlyphSpan(cmd, r.glyphs.span(run));
    }

    /// The `span[1]` glyph quads from `span[0]`: consecutive text runs in one
    /// draw (`iface.drawUntilCustom`).
    pub fn drawGlyphSpan(r: *const Renderer, cmd: Pass, span: [2]u32) void {
        r.bind(r.dev, cmd, .solid, r.glyphs.texture, r.glyphsAt());
        r.dev.fns.vkCmdDraw.?(cmd, 4, span[1], 0, span[0]);
    }

    /// The scissor for an inline custom draw: `custom.rect` cut by `custom.clip`, in the
    /// physical pixels of the last `prepare`, inside the target. Pixels a quad would cover
    /// partly are included (floor the start, ceil the end); an empty result has zero extent.
    pub fn customScissor(r: *const Renderer, custom: draw_list.CustomDraw) c.VkRect2D {
        const w: f32 = @floatFromInt(r.extent.width);
        const h: f32 = @floatFromInt(r.extent.height);
        const x0 = std.math.clamp(@floor(@max(custom.rect[0], custom.clip[0]) * r.scale), 0, w);
        const y0 = std.math.clamp(@floor(@max(custom.rect[1], custom.clip[1]) * r.scale), 0, h);
        const x1 = std.math.clamp(@ceil(@min(custom.rect[2], custom.clip[2]) * r.scale), x0, w);
        const y1 = std.math.clamp(@ceil(@min(custom.rect[3], custom.clip[3]) * r.scale), y0, h);
        return .{
            .offset = .{ .x = @intFromFloat(x0), .y = @intFromFloat(y0) },
            .extent = .{ .width = @intFromFloat(x1 - x0), .height = @intFromFloat(y1 - y0) },
        };
    }

    /// Diagonal: the whole list, skipping custom draws. With custom draws, loop with
    /// `iface.drawUntilCustom` and draw each one yourself.
    pub fn render(r: *const Renderer, cmd: Pass, draw: *const DrawList) void {
        iface.render(r, cmd, draw);
    }
};

comptime {
    iface.check(Renderer);
}

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
const conformance = lcgf.render_conformance;

test "renderer: quad pipelines build from the committed SPIR-V on a real device" {
    var h: host.Host = undefined;
    try h.init();
    defer h.deinit();
    var white = try h.sampled(1, 1, &.{ 255, 255, 255, 255 });
    defer h.device.destroyImage(&white);
    const sampler = try host.nearestSampler(&h.device);
    defer h.device.fns.vkDestroySampler.?(h.device.handle, sampler, null);
    var r = try Renderer.init(&h.device, .{ .format = c.VK_FORMAT_R8G8B8A8_UNORM }, white.view, sampler);
    defer r.deinit(&h.device);
    try testing.expectEqual(@as(u16, 1), r.material_count);
    try testing.expect(r.pipelines[0] != null);
    const example = try r.addMaterial(&h.device, example_spv);
    try testing.expectEqual(@as(u16, 1), @backingInt(example));
    // Multisampled targets get their own pipelines.
    var msaa = try Renderer.init(&h.device, .{ .format = c.VK_FORMAT_B8G8R8A8_UNORM, .samples = 4 }, white.view, sampler);
    msaa.deinit(&h.device);
    // Past the cap the last entry is replaced, not written past.
    for (0..max_materials + 2) |_| _ = try r.addMaterial(&h.device, example_spv);
    try testing.expectEqual(@as(u16, max_materials), r.material_count);
}

test "renderer: a canvas uploads its rows once, then only dirty rows; each ring slot catches up" {
    var h: host.Host = undefined;
    try h.init();
    defer h.deinit();
    var white = try h.sampled(1, 1, &.{ 255, 255, 255, 255 });
    defer h.device.destroyImage(&white);
    const sampler = try host.nearestSampler(&h.device);
    defer h.device.fns.vkDestroySampler.?(h.device.handle, sampler, null);
    const sc = conformance.canvas_scene;
    var r = try Renderer.init(&h.device, .{ .format = c.VK_FORMAT_R8G8B8A8_UNORM, .canvas_rows = sc.rows, .canvas_verts = sc.verts }, white.view, sampler);
    defer r.deinit(&h.device);
    const st = try testing.allocator.create(conformance.CanvasStorage);
    defer testing.allocator.destroy(st);
    st.load();
    const s = &st.shapes;
    const cv = &r.canvas.?;
    // Each draw writes its head, its six palette rows and its one override.
    const uniforms = lcgf.canvas_shader.Uniforms.headBytes(sc.palette.layers.len) + 16;
    // A new batch: every row and vertex, into each slot on its first frame.
    for (0..2) |slot| {
        r.prepare(@intCast(slot), &st.draw, .{}, sc.viewport, 1);
        s.clearDirty();
        try testing.expectEqual(32 * s.len + 8 * s.vert_len + uniforms, cv.uploaded);
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(s.c.look[0..s.len]), cv.slots[slot].look.mapped.?[0 .. 16 * s.len]);
    }
    // A pan: the camera only.
    st.rows[0].camera.origin[0] += 1000;
    r.prepare(0, &st.draw, .{}, sc.viewport, 1);
    s.clearDirty();
    try testing.expectEqual(uniforms, cv.uploaded);
    // An edit of two rows: written into this frame's slot, and into the other on its turn.
    s.kill(3);
    s.kill(4);
    r.prepare(1, &st.draw, .{}, sc.viewport, 1);
    s.clearDirty();
    try testing.expectEqual(2 * 32 + uniforms, cv.uploaded);
    try testing.expect(cv.slots[0].look.mapped.?[16 * 3 + 1] & 2 == 0);
    r.prepare(0, &st.draw, .{}, sc.viewport, 1);
    s.clearDirty();
    try testing.expectEqual(2 * 32 + uniforms, cv.uploaded);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(s.c.look[0..s.len]), cv.slots[0].look.mapped.?[0 .. 16 * s.len]);
    r.prepare(1, &st.draw, .{}, sc.viewport, 1);
    try testing.expectEqual(uniforms, cv.uploaded);
}

test "renderer: a canvas batch that no longer fits starts the buffers over with this frame's" {
    var h: host.Host = undefined;
    try h.init();
    defer h.deinit();
    var white = try h.sampled(1, 1, &.{ 255, 255, 255, 255 });
    defer h.device.destroyImage(&white);
    const sampler = try host.nearestSampler(&h.device);
    defer h.device.fns.vkDestroySampler.?(h.device.handle, sampler, null);
    var r = try Renderer.init(&h.device, .{ .format = c.VK_FORMAT_R8G8B8A8_UNORM, .frames = 1, .canvas_rows = 90 }, white.view, sampler);
    defer r.deinit(&h.device);
    const canvas = lcgf.canvas;
    const B = struct {
        buf: [canvas.Instances.requiredBytes(40, 0, 1)]u8 align(lcgf.mem.column_align) = undefined,
        s: canvas.Instances = undefined,
        fn init(b: *@This(), cap: u32) void {
            var carver: lcgf.mem.Carver = .{ .buf = &b.buf };
            b.s = .init(&carver, cap, 0, 1);
            for (0..cap) |_| _ = b.s.segment(.{ 0, 0 }, .{ 10, 10 }, .{});
        }
    };
    var a: B = .{};
    var b: B = .{};
    var big: B = .{};
    a.init(30);
    b.init(30);
    big.init(40);
    const list_bytes = comptime blk: {
        var counter: lcgf.mem.Carver = .{ .buf = null };
        _ = DrawList.init(&counter, 1, 1, 2);
        break :blk counter.off;
    };
    var list_buf: [list_bytes]u8 align(lcgf.mem.column_align) = undefined;
    var carver: lcgf.mem.Carver = .{ .buf = &list_buf };
    var list = DrawList.init(&carver, 1, 1, 2);
    const pal: canvas.Palette = .{ .layers = &.{.of(.{})} };
    var rows: [2]draw_list.CanvasDraw = undefined;
    list.canvases = &rows;
    for (0..2) |k| {
        list.customs[k] = .{ .rect = .{ 0, 0, 16, 16 }, .clip = .{ 0, 0, 16, 16 }, .data = 0, .id = 0, .node = 0 };
        list.cmd.kind[k] = @backingInt(DrawList.Kind.canvas);
        list.cmd.first[k] = @intCast(k);
        list.cmd.count[k] = 1;
    }
    list.custom_len = 2;
    list.cmd_len = 2;
    const all: []const canvas.Range = &.{.{ .first = 0, .count = 40 }};
    const uniforms = lcgf.canvas_shader.Uniforms.headBytes(1);
    const cv = &r.canvas.?;
    rows = .{ .{ .instances = &a.s, .ranges = all, .palette = &pal, .camera = .{} }, .{ .instances = &b.s, .ranges = all, .palette = &pal, .camera = .{} } };
    r.prepare(0, &list, .{}, .{ 16, 16 }, 1);
    try testing.expectEqual(2 * (32 * 30 + uniforms), cv.uploaded);
    a.s.clearDirty();
    b.s.clearDirty();
    // 30 + 40 rows still fit after `a` once `b` is gone, but not after both: start over.
    rows[1].instances = &big.s;
    r.prepare(0, &list, .{}, .{ 16, 16 }, 1);
    try testing.expectEqual(32 * 30 + 32 * 40 + 2 * uniforms, cv.uploaded);
    try testing.expectEqual(@as(u32, 30), cv.batches[cv.find(&big.s).?].row_base);
    try testing.expectEqual(@as(?u32, null), cv.find(&b.s));
    a.s.clearDirty();
    big.s.clearDirty();
    r.prepare(0, &list, .{}, .{ 16, 16 }, 1);
    try testing.expectEqual(2 * uniforms, cv.uploaded);
}

test "renderer: prepare writes each frame into its own slot of the mapped ring" {
    var h: host.Host = undefined;
    try h.init();
    defer h.deinit();
    var white = try h.sampled(1, 1, &.{ 255, 255, 255, 255 });
    defer h.device.destroyImage(&white);
    const sampler = try host.nearestSampler(&h.device);
    defer h.device.fns.vkDestroySampler.?(h.device.handle, sampler, null);
    var r = try Renderer.init(&h.device, .{ .format = c.VK_FORMAT_R8G8B8A8_UNORM, .max_quads = 4, .max_glyphs = 4, .frames = 2 }, white.view, sampler);
    defer r.deinit(&h.device);
    try testing.expectEqual(@as(u64, 0), r.slot_bytes % globals_slot);
    try testing.expectEqual(r.slot_bytes * 2, r.ring.mapped.len);

    var st: conformance.Storage = .{};
    st.load(&conformance.scenes[2]); // text: 2 quads, 8 glyphs (4 kept)
    r.prepare(0, &st.draw, st.glyphs(), .{ 160, 120 }, 2);
    try testing.expectEqual(c.VkExtent2D{ .width = 320, .height = 240 }, r.extent);
    const s0 = r.ring.mapped[0..@intCast(r.slot_bytes)];
    try testing.expectEqualSlices(u8, std.mem.asBytes(&Globals{ .viewport = .{ 160, 120 }, .scale = 2 }), s0[0..@sizeOf(Globals)]);
    try testing.expectEqualSlices(u8, st.draw.quadBytes(), s0[globals_slot..][0 .. 2 * @sizeOf(Quad)]);
    const glyphs_at: usize = @intCast(r.glyphsAt());
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(st.glyph_quads[0..4]), s0[glyphs_at..][0 .. 4 * @sizeOf(Quad)]);

    // The next frame goes to slot 1 and leaves slot 0, which the GPU may still read, alone.
    const before = s0[globals_slot..][0..@sizeOf(Quad)].*;
    st.load(&conformance.scenes[0]);
    r.prepare(1, &st.draw, st.glyphs(), .{ 160, 120 }, 1);
    try testing.expectEqual(r.slot_bytes, r.base);
    try testing.expectEqualSlices(u8, &before, s0[globals_slot..][0..@sizeOf(Quad)]);
    try testing.expectEqualSlices(u8, st.draw.quadBytes(), r.ring.mapped[@intCast(r.base + globals_slot)..][0 .. 3 * @sizeOf(Quad)]);
    r.prepare(2, &st.draw, st.glyphs(), .{ 160, 120 }, 1); // wraps to slot 0
    try testing.expectEqual(@as(u64, 0), r.base);
}

test "renderer: the custom scissor is the rect cut by its clip, in pixels, inside the target" {
    var r: Renderer = undefined;
    r.extent = .{ .width = 320, .height = 240 };
    r.scale = 2;
    const open: [4]f32 = .{ -1e6, -1e6, 1e6, 1e6 };
    var sc = r.customScissor(.{ .rect = .{ 8, 8, 152, 112 }, .clip = open, .data = 0, .id = 0, .node = 0 });
    try testing.expectEqual(c.VkRect2D{ .offset = .{ .x = 16, .y = 16 }, .extent = .{ .width = 288, .height = 208 } }, sc);
    sc = r.customScissor(.{ .rect = .{ -10, 100.25, 400, 300 }, .clip = .{ 0, 0, 150.2, 1e6 }, .data = 0, .id = 0, .node = 0 });
    try testing.expectEqual(c.VkRect2D{ .offset = .{ .x = 0, .y = 200 }, .extent = .{ .width = 301, .height = 40 } }, sc);
    sc = r.customScissor(.{ .rect = .{ 50, 50, 60, 60 }, .clip = .{ 70, 70, 80, 80 }, .data = 0, .id = 0, .node = 0 });
    try testing.expectEqual(@as(u32, 0), sc.extent.width * sc.extent.height);
}

test "quad_attrs follow the shader's layout of Quad" {
    try testing.expectEqual(@as(u32, @sizeOf(Quad)), quad_shader.stride);
    for (quad_shader.attrs, quad_attrs) |a, b| {
        try testing.expectEqual(a.location, b.location);
        try testing.expectEqual(a.offset, b.offset);
    }
    try testing.expectEqual(@as(c.VkFormat, c.VK_FORMAT_R8G8B8A8_UNORM), quad_attrs[4].format);
}
