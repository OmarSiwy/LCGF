//! `lcgf_render.gpu` on Vulkan: WebGPU's object model, projected onto Vulkan 1.3 at compile time.
//! Every type is a plain struct of the Vulkan handles it stands for, with public fields, so the
//! raw API is a field read away (`pass.cmd`, `buffer.handle`). Nothing is pooled, counted,
//! tracked or validated at run time in release builds; there is no handle table and no dispatch.
//!
//! Who owns what (docs/guide/gpu.md):
//!   You:      the device, the command buffer, every object below, and the `Arena` they live in.
//!   Nothing:  the projection keeps no state between calls.
//!
//! A frame has phases, each its own type, so a hazard cannot be written:
//!
//!     var up = gpu.Upload.begin(dev, cmd);        // copies and writes only
//!     up.writeBuffer(uniforms, 0, bytes);
//!     var enc = up.finish();                      // one barrier: writes -> reads
//!     var pass = enc.beginRenderPass(.{ ... });   // reads only
//!     pass.setPipeline(pipeline); pass.setBindGroup(0, group); pass.draw(3, 1, 0, 0);
//!     pass.end();                                 // attachments left ready to sample
//!
//! Layout conventions instead of tracking. A texture rests in one layout between passes:
//! GENERAL if it has `storage_binding`, otherwise SHADER_READ_ONLY_OPTIMAL. `Upload.writeTexture`
//! and `Upload.prepare` bring a fresh texture there; a render pass moves its attachments to
//! COLOR_ATTACHMENT_OPTIMAL (from UNDEFINED when it clears, from the resting layout when it
//! loads) and back when it ends. A `RenderPass.wrap`ped pass is the host's and is left alone.

const std = @import("std");
const builtin = @import("builtin");
const lcgf = @import("lcgf");
const loader = @import("loader.zig");
const device_mod = @import("device.zig");
const c = loader.c;
const check = loader.check;
const desc = lcgf.gpu_desc;
const reflect = lcgf.gpu_reflect;

pub const Error = loader.Error || error{ OutOfArena, IncompatibleMemory, UnsupportedFormat, MissingShader };

pub const BufferUsage = desc.BufferUsage;
pub const BufferDescriptor = desc.BufferDescriptor;
pub const TextureUsage = desc.TextureUsage;
pub const TextureFormat = desc.TextureFormat;
pub const TextureDescriptor = desc.TextureDescriptor;
pub const SamplerDescriptor = desc.SamplerDescriptor;
pub const VertexFormat = desc.VertexFormat;
pub const VertexBufferLayout = desc.VertexBufferLayout;
pub const VertexAttribute = desc.VertexAttribute;
pub const PrimitiveTopology = desc.PrimitiveTopology;
pub const IndexFormat = desc.IndexFormat;
pub const BlendState = desc.BlendState;
pub const ColorTargetState = desc.ColorTargetState;
pub const RenderPipelineDescriptor = desc.RenderPipelineDescriptor;
pub const ComputePipelineDescriptor = desc.ComputePipelineDescriptor;
pub const LoadOp = desc.LoadOp;
pub const StoreOp = desc.StoreOp;
pub const Color = desc.Color;
pub const Target = desc.Target;
pub const Rect = desc.Rect;
pub const scissor = desc.scissor;

/// Which back end this projection is, for code that drops to the native API.
pub const native = .vk;
/// The Vulkan C API, as this back end translated it.
pub const vk = c;

/// Debug builds check what comptime cannot see (scissor bounds, a draw with no pipeline, write
/// alignment). The checks and their fields compile away in release builds.
const debug_checks = builtin.mode == .debug;

// ---------------------------------------------------------------------------------------------
// Device and memory

/// The host's device. A `*const` of the back end's own `Device` (its handle and function table).
pub const Device = struct {
    dev: *const device_mod.Device,

    pub fn wrap(d: *const device_mod.Device) Device {
        return .{ .dev = d };
    }

    pub fn createBuffer(device: Device, arena: *Arena, d: BufferDescriptor) Error!Buffer {
        const dv = device.dev;
        var b: Buffer = .{ .handle = null, .size = d.size, .mapped = null };
        try check(dv.fns.vkCreateBuffer.?(dv.handle, &.{
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .size = d.size,
            .usage = bufferUsage(d.usage),
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        }, null, &b.handle));
        errdefer dv.fns.vkDestroyBuffer.?(dv.handle, b.handle, null);
        var req: c.VkMemoryRequirements = undefined;
        dv.fns.vkGetBufferMemoryRequirements.?(dv.handle, b.handle, &req);
        const at = try arena.place(req);
        try check(dv.fns.vkBindBufferMemory.?(dv.handle, b.handle, arena.memory, at));
        if (arena.mapped) |base| b.mapped = base + @as(usize, @intCast(at));
        return b;
    }

    pub fn destroyBuffer(device: Device, b: Buffer) void {
        device.dev.fns.vkDestroyBuffer.?(device.dev.handle, b.handle, null);
    }

    /// Copies `out.len` bytes of `b` from `offset` into `out` (WebGPU's `mapAsync` +
    /// `getMappedRange`, synchronous: the caller knows the writes are done). `b` lives in a
    /// `.host` arena; its memory is coherent, so this is a copy.
    pub fn readBuffer(device: Device, b: Buffer, offset: u64, out: []u8) void {
        _ = device;
        @memcpy(out, b.mapped.?[@intCast(offset)..][0..out.len]);
    }

    pub fn createTexture(device: Device, arena: *Arena, d: TextureDescriptor) Error!Texture {
        const dv = device.dev;
        const format = try vkFormat(d.format);
        var t: Texture = .{
            .image = null,
            .view = null,
            .format = d.format,
            .width = d.size.width,
            .height = d.size.height,
            .samples = d.sample_count,
            .resting = if (d.usage.storage_binding) c.VK_IMAGE_LAYOUT_GENERAL else c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
        try check(dv.fns.vkCreateImage.?(dv.handle, &.{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .imageType = c.VK_IMAGE_TYPE_2D,
            .format = format,
            .extent = .{ .width = d.size.width, .height = d.size.height, .depth = 1 },
            .mipLevels = d.mip_level_count,
            .arrayLayers = d.size.depth_or_array_layers,
            .samples = d.sample_count,
            .tiling = c.VK_IMAGE_TILING_OPTIMAL,
            .usage = textureUsage(d.usage),
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        }, null, &t.image));
        errdefer dv.fns.vkDestroyImage.?(dv.handle, t.image, null);
        var req: c.VkMemoryRequirements = undefined;
        dv.fns.vkGetImageMemoryRequirements.?(dv.handle, t.image, &req);
        const at = try arena.place(req);
        try check(dv.fns.vkBindImageMemory.?(dv.handle, t.image, arena.memory, at));
        try check(dv.fns.vkCreateImageView.?(dv.handle, &.{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = t.image,
            .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
            .format = format,
            .subresourceRange = .{ .aspectMask = aspect(d.format), .levelCount = d.mip_level_count, .layerCount = 1 },
        }, null, &t.view));
        return t;
    }

    pub fn destroyTexture(device: Device, t: Texture) void {
        device.dev.fns.vkDestroyImageView.?(device.dev.handle, t.view, null);
        device.dev.fns.vkDestroyImage.?(device.dev.handle, t.image, null);
    }

    pub fn createSampler(device: Device, d: SamplerDescriptor) Error!Sampler {
        var s: Sampler = .{ .handle = null };
        try check(device.dev.fns.vkCreateSampler.?(device.dev.handle, &.{
            .sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .magFilter = filter(d.mag_filter),
            .minFilter = filter(d.min_filter),
            .mipmapMode = if (d.mipmap_filter == .linear) c.VK_SAMPLER_MIPMAP_MODE_LINEAR else c.VK_SAMPLER_MIPMAP_MODE_NEAREST,
            .addressModeU = address(d.address_mode_u),
            .addressModeV = address(d.address_mode_v),
            .addressModeW = address(d.address_mode_w),
            .compareEnable = @intFromBool(d.compare != null),
            .compareOp = if (d.compare) |f| compareOp(f) else c.VK_COMPARE_OP_NEVER,
            .minLod = d.lod_min_clamp,
            .maxLod = d.lod_max_clamp,
        }, null, &s.handle));
        return s;
    }

    pub fn destroySampler(device: Device, s: Sampler) void {
        device.dev.fns.vkDestroySampler.?(device.dev.handle, s.handle, null);
    }

    /// A render pipeline for shader `S` (`Shader(...)`). Its layout comes from the shader's
    /// reflected groups; `d.vertex.entry_point` and `d.fragment.entry_point` must exist in it.
    pub fn createRenderPipeline(device: Device, comptime S: type, d: RenderPipelineDescriptor) Error!RenderPipeline(S) {
        const dv = device.dev;
        var p: RenderPipeline(S) = .{ .pipeline = null, .layout = null, .set_layouts = @splat(null) };
        errdefer device.destroyRenderPipeline(p);
        try createLayout(dv, S, &p.set_layouts, &p.layout);
        const module = try shaderModule(dv, S.spirv);
        defer dv.fns.vkDestroyShaderModule.?(dv.handle, module, null);
        const frag = d.fragment orelse desc.FragmentState{ .targets = &.{} };
        const stages = [_]c.VkPipelineShaderStageCreateInfo{
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = module, .pName = d.vertex.entry_point.ptr },
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = module, .pName = frag.entry_point.ptr },
        };
        var bindings: [max_vertex_buffers]c.VkVertexInputBindingDescription = undefined;
        var attrs: [max_vertex_attributes]c.VkVertexInputAttributeDescription = undefined;
        var nattr: u32 = 0;
        for (d.vertex.buffers, 0..) |vb, slot| {
            bindings[slot] = .{ .binding = @intCast(slot), .stride = @intCast(vb.array_stride), .inputRate = if (vb.step_mode == .instance) c.VK_VERTEX_INPUT_RATE_INSTANCE else c.VK_VERTEX_INPUT_RATE_VERTEX };
            for (vb.attributes) |a| {
                attrs[nattr] = .{ .location = a.shader_location, .binding = @intCast(slot), .format = vertexFormat(a.format), .offset = @intCast(a.offset) };
                nattr += 1;
            }
        }
        const vertex_input: c.VkPipelineVertexInputStateCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .vertexBindingDescriptionCount = @intCast(d.vertex.buffers.len),
            .pVertexBindingDescriptions = &bindings,
            .vertexAttributeDescriptionCount = nattr,
            .pVertexAttributeDescriptions = &attrs,
        };
        const assembly: c.VkPipelineInputAssemblyStateCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .topology = topology(d.primitive.topology),
            .primitiveRestartEnable = @intFromBool(d.primitive.strip_index_format != null),
        };
        const viewport: c.VkPipelineViewportStateCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, .viewportCount = 1, .scissorCount = 1 };
        const raster: c.VkPipelineRasterizationStateCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .polygonMode = c.VK_POLYGON_MODE_FILL,
            .cullMode = switch (d.primitive.cull_mode) {
                .none => c.VK_CULL_MODE_NONE,
                .front => c.VK_CULL_MODE_FRONT_BIT,
                .back => c.VK_CULL_MODE_BACK_BIT,
            },
            // naga's SPIR-V flips y, so framebuffer winding is WebGPU's: ccw stays ccw.
            .frontFace = if (d.primitive.front_face == .ccw) c.VK_FRONT_FACE_COUNTER_CLOCKWISE else c.VK_FRONT_FACE_CLOCKWISE,
            .lineWidth = 1,
        };
        const multisample: c.VkPipelineMultisampleStateCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .rasterizationSamples = d.multisample.count,
            .pSampleMask = &d.multisample.mask,
            .alphaToCoverageEnable = @intFromBool(d.multisample.alpha_to_coverage_enabled),
        };
        var blends: [max_color_targets]c.VkPipelineColorBlendAttachmentState = undefined;
        var formats: [max_color_targets]c.VkFormat = undefined;
        for (frag.targets, 0..) |t, i| {
            formats[i] = try vkFormat(t.format);
            blends[i] = blendAttachment(t);
        }
        const blend: c.VkPipelineColorBlendStateCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .attachmentCount = @intCast(frag.targets.len),
            .pAttachments = &blends,
        };
        const dynamic_states = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR, c.VK_DYNAMIC_STATE_BLEND_CONSTANTS };
        const dynamic: c.VkPipelineDynamicStateCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .dynamicStateCount = dynamic_states.len,
            .pDynamicStates = &dynamic_states,
        };
        const rendering: c.VkPipelineRenderingCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
            .colorAttachmentCount = @intCast(frag.targets.len),
            .pColorAttachmentFormats = &formats,
        };
        try check(dv.fns.vkCreateGraphicsPipelines.?(dv.handle, null, 1, &.{
            .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .pNext = &rendering,
            .stageCount = if (d.fragment == null) 1 else 2,
            .pStages = &stages,
            .pVertexInputState = &vertex_input,
            .pInputAssemblyState = &assembly,
            .pViewportState = &viewport,
            .pRasterizationState = &raster,
            .pMultisampleState = &multisample,
            .pColorBlendState = &blend,
            .pDynamicState = &dynamic,
            .layout = p.layout,
        }, null, &p.pipeline));
        return p;
    }

    pub fn destroyRenderPipeline(device: Device, p: anytype) void {
        const dv = device.dev;
        if (p.pipeline != null) dv.fns.vkDestroyPipeline.?(dv.handle, p.pipeline, null);
        if (p.layout != null) dv.fns.vkDestroyPipelineLayout.?(dv.handle, p.layout, null);
        for (p.set_layouts) |l| if (l != null) dv.fns.vkDestroyDescriptorSetLayout.?(dv.handle, l, null);
    }

    pub fn createComputePipeline(device: Device, comptime S: type, d: ComputePipelineDescriptor) Error!ComputePipeline(S) {
        const dv = device.dev;
        var p: ComputePipeline(S) = .{ .pipeline = null, .layout = null, .set_layouts = @splat(null) };
        errdefer device.destroyComputePipeline(p);
        try createLayout(dv, S, &p.set_layouts, &p.layout);
        const module = try shaderModule(dv, S.spirv);
        defer dv.fns.vkDestroyShaderModule.?(dv.handle, module, null);
        try check(dv.fns.vkCreateComputePipelines.?(dv.handle, null, 1, &.{
            .sType = c.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
            .stage = .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_COMPUTE_BIT, .module = module, .pName = d.entry_point.ptr },
            .layout = p.layout,
        }, null, &p.pipeline));
        return p;
    }

    pub const destroyComputePipeline = destroyRenderPipeline;

    /// A bind group for group `g` of `pipeline`'s shader. `entries` has one field per binding the
    /// shader declares in that group (`Shader.Group(g)`); the compiler checks the set.
    pub fn createBindGroup(device: Device, arena: *Arena, pipeline: anytype, comptime g: u32, entries: @TypeOf(pipeline).Shader.Group(g)) Error!BindGroup(@TypeOf(pipeline).Shader, g) {
        const dv = device.dev;
        const S = @TypeOf(pipeline).Shader;
        var set: c.VkDescriptorSet = null;
        try check(dv.fns.vkAllocateDescriptorSets.?(dv.handle, &.{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .descriptorPool = arena.pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &pipeline.set_layouts[g],
        }, &set));
        const bindings = comptime S.module.group(g);
        var buffers: [bindings.len]c.VkDescriptorBufferInfo = undefined;
        var images: [bindings.len]c.VkDescriptorImageInfo = undefined;
        var writes: [bindings.len]c.VkWriteDescriptorSet = undefined;
        inline for (bindings, 0..) |b, i| {
            const v = @field(entries, b.name);
            writes[i] = .{
                .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .dstSet = set,
                .dstBinding = b.binding,
                .descriptorCount = 1,
                .descriptorType = comptime descriptorType(b.kind),
            };
            switch (comptime b.kind) {
                .uniform, .storage_read, .storage_read_write => {
                    buffers[i] = .{ .buffer = v.handle, .offset = 0, .range = c.VK_WHOLE_SIZE };
                    writes[i].pBufferInfo = &buffers[i];
                },
                .texture, .storage_texture => {
                    images[i] = .{ .imageView = v.view, .imageLayout = v.layout };
                    writes[i].pImageInfo = &images[i];
                },
                .sampler, .comparison_sampler => {
                    images[i] = .{ .sampler = v.handle };
                    writes[i].pImageInfo = &images[i];
                },
            }
        }
        dv.fns.vkUpdateDescriptorSets.?(dv.handle, writes.len, &writes, 0, null);
        return .{ .set = set, .layout = pipeline.layout };
    }
};

/// One block of device memory and one descriptor pool, owned by the caller. Resources are
/// placed by bumping an offset; `reset` forgets them all at once (destroy the objects first).
/// `.host` memory is mapped: buffers placed there have `mapped` set and can be written directly.
pub const Arena = struct {
    memory: c.VkDeviceMemory,
    type_index: u32,
    size: u64,
    used: u64 = 0,
    mapped: ?[*]u8,
    pool: c.VkDescriptorPool,
    dev: *const device_mod.Device,

    pub const Kind = enum { device, host };
    pub const Options = struct { bytes: u64, memory: Kind = .device, bind_groups: u32 = 64 };

    pub fn init(device: Device, o: Options) Error!Arena {
        const dv = device.dev;
        const flags: c.VkMemoryPropertyFlags = switch (o.memory) {
            .device => c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
            .host => c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        };
        const index = dv.memoryType(0xffff_ffff, flags) orelse return error.IncompatibleMemory;
        var a: Arena = .{ .memory = null, .type_index = index, .size = o.bytes, .mapped = null, .pool = null, .dev = dv };
        try check(dv.fns.vkAllocateMemory.?(dv.handle, &.{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = o.bytes,
            .memoryTypeIndex = index,
        }, null, &a.memory));
        errdefer dv.fns.vkFreeMemory.?(dv.handle, a.memory, null);
        if (o.memory == .host) {
            var ptr: ?*anyopaque = null;
            try check(dv.fns.vkMapMemory.?(dv.handle, a.memory, 0, o.bytes, 0, &ptr));
            a.mapped = @ptrCast(ptr);
        }
        const n = o.bind_groups;
        const sizes = [_]c.VkDescriptorPoolSize{
            .{ .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 4 * n },
            .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 4 * n },
            .{ .type = c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .descriptorCount = 4 * n },
            .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = n },
            .{ .type = c.VK_DESCRIPTOR_TYPE_SAMPLER, .descriptorCount = 2 * n },
        };
        try check(dv.fns.vkCreateDescriptorPool.?(dv.handle, &.{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .maxSets = n,
            .poolSizeCount = sizes.len,
            .pPoolSizes = &sizes,
        }, null, &a.pool));
        return a;
    }

    /// Frees the memory and the pool. Destroy the resources placed here first.
    pub fn deinit(a: *Arena) void {
        a.dev.fns.vkDestroyDescriptorPool.?(a.dev.handle, a.pool, null);
        a.dev.fns.vkFreeMemory.?(a.dev.handle, a.memory, null); // unmaps
        a.* = undefined;
    }

    /// Forgets every resource and bind group placed here. Destroy the resources first.
    pub fn reset(a: *Arena) void {
        a.used = 0;
        _ = a.dev.fns.vkResetDescriptorPool.?(a.dev.handle, a.pool, 0);
    }

    fn place(a: *Arena, req: c.VkMemoryRequirements) Error!u64 {
        if ((req.memoryTypeBits >> @intCast(a.type_index)) & 1 == 0) return error.IncompatibleMemory;
        const at = std.mem.alignForward(u64, a.used, req.alignment);
        if (at + req.size > a.size) return error.OutOfArena;
        a.used = at + req.size;
        return at;
    }
};

// ---------------------------------------------------------------------------------------------
// Objects

pub const Buffer = struct {
    handle: c.VkBuffer,
    size: u64,
    /// Set when the buffer lives in a `.host` arena: its bytes, written directly by the CPU.
    mapped: ?[*]u8,
};

pub const Texture = struct {
    image: c.VkImage,
    view: c.VkImageView,
    format: TextureFormat,
    width: u32,
    height: u32,
    samples: u32,
    /// The layout this texture keeps between passes (see the file comment).
    resting: c.VkImageLayout,

    /// The default view: the whole texture.
    pub fn createView(t: Texture) TextureView {
        return .{ .view = t.view, .image = t.image, .width = t.width, .height = t.height, .samples = t.samples, .layout = t.resting, .format = t.format };
    }
};

pub const TextureView = struct {
    view: c.VkImageView,
    image: c.VkImage,
    width: u32,
    height: u32,
    samples: u32 = 1,
    /// The layout shaders see it in (its texture's resting layout).
    layout: c.VkImageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    format: TextureFormat = .rgba8_unorm,
};

pub const Sampler = struct { handle: c.VkSampler };

/// A shader: `source` is a namespace with `wgsl` (the WGSL text) and `spv` (naga's SPIR-V of
/// it), as the build's `addShaders` step makes. Reflected at compile time.
pub fn Shader(comptime source: type) type {
    if (!@hasDecl(source, "spv")) @compileError("shader has no SPIR-V: build it with addShaders for the vk back end");
    return struct {
        pub const module = reflect.parse(source.wgsl);
        pub const spirv: []const u32 = words(source.spv);
        /// The fields a bind group of group `g` is created from.
        pub fn Group(comptime g: u32) type {
            return module.Group(g, Buffer, TextureView, Sampler);
        }
    };
}

fn words(comptime bytes: []const u8) []const u32 {
    comptime {
        std.debug.assert(bytes.len % 4 == 0);
        var w: [bytes.len / 4]u32 = undefined;
        @memcpy(std.mem.sliceAsBytes(&w), bytes);
        const final = w;
        return &final;
    }
}

pub fn RenderPipeline(comptime S: type) type {
    return extern struct {
        pipeline: c.VkPipeline,
        layout: c.VkPipelineLayout,
        set_layouts: [max_groups]c.VkDescriptorSetLayout,
        pub const Shader = S;
    };
}

pub fn ComputePipeline(comptime S: type) type {
    return extern struct {
        pipeline: c.VkPipeline,
        layout: c.VkPipelineLayout,
        set_layouts: [max_groups]c.VkDescriptorSetLayout,
        pub const Shader = S;
    };
}

/// A descriptor set and the layout it binds with. `index` is the group it was made for: binding
/// it at another index does not compile.
pub fn BindGroup(comptime S: type, comptime g: u32) type {
    return extern struct {
        set: c.VkDescriptorSet,
        layout: c.VkPipelineLayout,
        pub const Shader = S;
        pub const index = g;
    };
}

// ---------------------------------------------------------------------------------------------
// Frame phases

/// The write phase of a frame: copies and writes only, recorded into the host's command buffer
/// outside any render pass. `finish` ends it with one barrier and returns the draw phase.
pub const Upload = struct {
    cmd: c.VkCommandBuffer,
    fns: *const device_mod.DeviceFns,
    staging: ?*Staging = null,
    images: [max_upload_images]c.VkImageMemoryBarrier2 = undefined,
    image_count: u32 = 0,

    pub fn begin(device: Device, cmd: c.VkCommandBuffer) Upload {
        return .{ .cmd = cmd, .fns = &device.dev.fns };
    }

    /// With a staging ring for texture writes.
    pub fn beginStaged(device: Device, cmd: c.VkCommandBuffer, staging: *Staging) Upload {
        return .{ .cmd = cmd, .fns = &device.dev.fns, .staging = staging };
    }

    /// Writes `bytes` into `buffer` at `offset`, ordered on the queue like WebGPU's
    /// `writeBuffer`: recorded into the command buffer, so a frame still in flight keeps the
    /// old contents. Offset and length are multiples of 4; the buffer has `copy_dst`.
    pub fn writeBuffer(up: *Upload, buffer: Buffer, offset: u64, bytes: []const u8) void {
        if (debug_checks) std.debug.assert(offset % 4 == 0 and bytes.len % 4 == 0 and offset + bytes.len <= buffer.size);
        var at: usize = 0;
        while (at < bytes.len) {
            const n = @min(bytes.len - at, 65536);
            up.fns.vkCmdUpdateBuffer.?(up.cmd, buffer.handle, offset + at, n, bytes[at..].ptr);
            at += n;
        }
    }

    /// Replaces the whole first mip level of `t` with `rgba` (rows of `bytes_per_row`), through
    /// the staging ring. Contents not written are lost: the texture starts from UNDEFINED.
    pub fn writeTexture(up: *Upload, t: Texture, bytes: []const u8, bytes_per_row: u32) Error!void {
        const s = up.staging orelse return error.OutOfArena;
        const at = try s.push(bytes);
        up.toLayout(t.image, c.VK_IMAGE_LAYOUT_UNDEFINED, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, c.VK_PIPELINE_STAGE_2_NONE, 0, c.VK_PIPELINE_STAGE_2_COPY_BIT, c.VK_ACCESS_2_TRANSFER_WRITE_BIT);
        up.fns.vkCmdCopyBufferToImage.?(up.cmd, s.buffer.handle, t.image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &.{
            .bufferOffset = at,
            .bufferRowLength = bytes_per_row / t.format.bytesPerPixel(),
            .imageSubresource = .{ .aspectMask = aspect(t.format), .layerCount = 1 },
            .imageExtent = .{ .width = t.width, .height = t.height, .depth = 1 },
        });
        up.rest(t.image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, t.resting);
    }

    /// Brings a texture that was never written into its resting layout (a render target before
    /// its first `load`, a storage texture before its first dispatch).
    pub fn prepare(up: *Upload, t: Texture) void {
        up.rest(t.image, c.VK_IMAGE_LAYOUT_UNDEFINED, t.resting);
    }

    fn toLayout(up: *Upload, image: c.VkImage, from: c.VkImageLayout, to: c.VkImageLayout, src_stage: u64, src_access: u64, dst_stage: u64, dst_access: u64) void {
        imageBarrier(up.fns, up.cmd, image, from, to, src_stage, src_access, dst_stage, dst_access);
    }

    fn rest(up: *Upload, image: c.VkImage, from: c.VkImageLayout, to: c.VkImageLayout) void {
        if (debug_checks) std.debug.assert(up.image_count < max_upload_images);
        up.images[up.image_count] = layoutBarrier(image, from, to, c.VK_PIPELINE_STAGE_2_COPY_BIT, c.VK_ACCESS_2_TRANSFER_WRITE_BIT, c.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, c.VK_ACCESS_2_SHADER_READ_BIT | c.VK_ACCESS_2_SHADER_WRITE_BIT | c.VK_ACCESS_2_COLOR_ATTACHMENT_READ_BIT);
        up.image_count += 1;
    }

    /// Ends the write phase: one global barrier from every transfer write to every read that
    /// follows, plus the layout moves of the textures written. Returns the draw phase.
    pub fn finish(up: *Upload) Encoder {
        const memory: c.VkMemoryBarrier2 = .{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER_2,
            .srcStageMask = c.VK_PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
            .srcAccessMask = c.VK_ACCESS_2_TRANSFER_WRITE_BIT,
            .dstStageMask = c.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
            .dstAccessMask = c.VK_ACCESS_2_MEMORY_READ_BIT,
        };
        up.fns.vkCmdPipelineBarrier2.?(up.cmd, &.{
            .sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
            .memoryBarrierCount = 1,
            .pMemoryBarriers = &memory,
            .imageMemoryBarrierCount = up.image_count,
            .pImageMemoryBarriers = &up.images,
        });
        return .{ .cmd = up.cmd, .fns = up.fns };
    }
};

/// A ring of mapped memory for texture writes, in a `.host` arena. One per frame in flight;
/// `rewind` it when that frame's previous use has completed.
pub const Staging = struct {
    buffer: Buffer,
    used: u64 = 0,

    pub fn init(device: Device, arena: *Arena, bytes: u64) Error!Staging {
        if (arena.mapped == null) return error.IncompatibleMemory;
        return .{ .buffer = try device.createBuffer(arena, .{ .size = bytes, .usage = .{ .copy_src = true } }) };
    }

    pub fn deinit(s: Staging, device: Device) void {
        device.destroyBuffer(s.buffer);
    }

    pub fn rewind(s: *Staging) void {
        s.used = 0;
    }

    fn push(s: *Staging, bytes: []const u8) Error!u64 {
        const at = std.mem.alignForward(u64, s.used, 16);
        if (at + bytes.len > s.buffer.size) return error.OutOfArena;
        @memcpy(s.buffer.mapped.?[@intCast(at)..][0..bytes.len], bytes);
        s.used = at + bytes.len;
        return at;
    }
};

pub const ColorAttachment = struct {
    view: TextureView,
    resolve_target: ?TextureView = null,
    load_op: LoadOp = .clear,
    store_op: StoreOp = .store,
    clear_value: Color = .{},
};

pub const RenderPassDescriptor = struct {
    color_attachments: []const ColorAttachment,
};

/// The read phase of a frame: render and compute passes.
pub const Encoder = struct {
    cmd: c.VkCommandBuffer,
    fns: *const device_mod.DeviceFns,

    /// Begins a pass the projection owns: it moves the attachments into place, clears or
    /// loads them, sets the viewport and scissor to the whole target (WebGPU's defaults), and
    /// `end` leaves them in their resting layout, ready to sample.
    pub fn beginRenderPass(e: Encoder, d: RenderPassDescriptor) RenderPass {
        var p: RenderPass = .{ .cmd = e.cmd, .fns = e.fns, .width = 0, .height = 0 };
        var barriers: [2 * max_color_targets]c.VkImageMemoryBarrier2 = undefined;
        var infos: [max_color_targets]c.VkRenderingAttachmentInfo = undefined;
        var nb: u32 = 0;
        for (d.color_attachments, 0..) |a, i| {
            const from: c.VkImageLayout = if (a.load_op == .clear) c.VK_IMAGE_LAYOUT_UNDEFINED else a.view.layout;
            barriers[nb] = layoutBarrier(a.view.image, from, c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, c.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, c.VK_ACCESS_2_MEMORY_READ_BIT | c.VK_ACCESS_2_MEMORY_WRITE_BIT, c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, c.VK_ACCESS_2_COLOR_ATTACHMENT_READ_BIT | c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT);
            nb += 1;
            p.ends[p.end_count] = .{ .image = a.view.image, .layout = a.view.layout };
            p.end_count += 1;
            if (a.resolve_target) |r| {
                barriers[nb] = layoutBarrier(r.image, c.VK_IMAGE_LAYOUT_UNDEFINED, c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, c.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, c.VK_ACCESS_2_MEMORY_READ_BIT, c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT);
                nb += 1;
                p.ends[p.end_count] = .{ .image = r.image, .layout = r.layout };
                p.end_count += 1;
            }
            const cv = a.clear_value;
            infos[i] = .{
                .sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
                .imageView = a.view.view,
                .imageLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                .resolveMode = if (a.resolve_target != null) c.VK_RESOLVE_MODE_AVERAGE_BIT else c.VK_RESOLVE_MODE_NONE,
                .resolveImageView = if (a.resolve_target) |r| r.view else null,
                .resolveImageLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                .loadOp = if (a.load_op == .clear) c.VK_ATTACHMENT_LOAD_OP_CLEAR else c.VK_ATTACHMENT_LOAD_OP_LOAD,
                .storeOp = if (a.store_op == .store) c.VK_ATTACHMENT_STORE_OP_STORE else c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
                .clearValue = .{ .color = .{ .float32 = .{ @floatCast(cv.r), @floatCast(cv.g), @floatCast(cv.b), @floatCast(cv.a) } } },
            };
            p.width = a.view.width;
            p.height = a.view.height;
        }
        e.fns.vkCmdPipelineBarrier2.?(e.cmd, &.{ .sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO, .imageMemoryBarrierCount = nb, .pImageMemoryBarriers = &barriers });
        e.fns.vkCmdBeginRendering.?(e.cmd, &.{
            .sType = c.VK_STRUCTURE_TYPE_RENDERING_INFO,
            .renderArea = .{ .extent = .{ .width = p.width, .height = p.height } },
            .layerCount = 1,
            .colorAttachmentCount = @intCast(d.color_attachments.len),
            .pColorAttachments = &infos,
        });
        p.owned = true;
        p.setViewport(0, 0, @floatFromInt(p.width), @floatFromInt(p.height), 0, 1);
        p.setScissorRect(0, 0, p.width, p.height);
        return p;
    }

    pub fn beginComputePass(e: Encoder) ComputePass {
        return .{ .cmd = e.cmd, .fns = e.fns };
    }
};

/// A render pass: the host's command buffer inside dynamic rendering, and the function table.
pub const RenderPass = struct {
    cmd: c.VkCommandBuffer,
    fns: *const device_mod.DeviceFns,
    width: u32,
    height: u32,
    owned: bool = false,
    ends: [2 * max_color_targets]End = undefined,
    end_count: u32 = 0,
    debug: if (debug_checks) struct { pipeline: bool = false } else void = if (debug_checks) .{} else {},

    const End = struct { image: c.VkImage, layout: c.VkImageLayout };

    /// A pass the host began itself (the UI's pass, for an inline custom draw). `end` leaves
    /// it to the host. `width` × `height` is its target, for the debug scissor check.
    pub fn wrap(device: Device, cmd: c.VkCommandBuffer, width: u32, height: u32) RenderPass {
        return .{ .cmd = cmd, .fns = &device.dev.fns, .width = width, .height = height };
    }

    pub inline fn setPipeline(p: *RenderPass, pipeline: anytype) void {
        if (debug_checks) p.debug.pipeline = true;
        p.fns.vkCmdBindPipeline.?(p.cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.pipeline);
    }

    /// `group` is a `BindGroup` or a pointer to one. Through a pointer the set's address is
    /// the caller's own field, as hand-written code would pass it; by value it is a local copy
    /// of the set alone, never of the whole group.
    pub inline fn setBindGroup(p: *RenderPass, comptime index: u32, group: anytype) void {
        comptime checkIndex(Deref(@TypeOf(group)), index);
        p.fns.vkCmdBindDescriptorSets.?(p.cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, group.layout, index, 1, setPtr(group), 0, null);
    }

    pub inline fn setVertexBuffer(p: *RenderPass, slot: u32, buffer: Buffer, offset: u64) void {
        p.fns.vkCmdBindVertexBuffers.?(p.cmd, slot, 1, &buffer.handle, &offset);
    }

    pub inline fn setIndexBuffer(p: *RenderPass, buffer: Buffer, format: IndexFormat, offset: u64) void {
        p.fns.vkCmdBindIndexBuffer.?(p.cmd, buffer.handle, offset, if (format == .uint16) c.VK_INDEX_TYPE_UINT16 else c.VK_INDEX_TYPE_UINT32);
    }

    pub inline fn setViewport(p: *RenderPass, x: f32, y: f32, w: f32, h: f32, min_depth: f32, max_depth: f32) void {
        p.fns.vkCmdSetViewport.?(p.cmd, 0, 1, &.{ .x = x, .y = y, .width = w, .height = h, .minDepth = min_depth, .maxDepth = max_depth });
    }

    pub inline fn setScissorRect(p: *RenderPass, x: u32, y: u32, w: u32, h: u32) void {
        if (debug_checks) std.debug.assert(x + w <= p.width and y + h <= p.height);
        p.fns.vkCmdSetScissor.?(p.cmd, 0, 1, &.{ .offset = .{ .x = @intCast(x), .y = @intCast(y) }, .extent = .{ .width = w, .height = h } });
    }

    pub inline fn setBlendConstant(p: *RenderPass, color: Color) void {
        const k: [4]f32 = .{ @floatCast(color.r), @floatCast(color.g), @floatCast(color.b), @floatCast(color.a) };
        p.fns.vkCmdSetBlendConstants.?(p.cmd, &k);
    }

    pub inline fn draw(p: *RenderPass, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void {
        if (debug_checks) std.debug.assert(p.debug.pipeline);
        p.fns.vkCmdDraw.?(p.cmd, vertex_count, instance_count, first_vertex, first_instance);
    }

    pub inline fn drawIndexed(p: *RenderPass, index_count: u32, instance_count: u32, first_index: u32, base_vertex: i32, first_instance: u32) void {
        if (debug_checks) std.debug.assert(p.debug.pipeline);
        p.fns.vkCmdDrawIndexed.?(p.cmd, index_count, instance_count, first_index, base_vertex, first_instance);
    }

    /// Ends a pass the projection began, leaving its attachments in their resting layout. A
    /// wrapped pass is the host's: nothing happens.
    pub fn end(p: *RenderPass) void {
        if (!p.owned) return;
        p.fns.vkCmdEndRendering.?(p.cmd);
        var barriers: [2 * max_color_targets]c.VkImageMemoryBarrier2 = undefined;
        for (p.ends[0..p.end_count], 0..) |e, i| barriers[i] = layoutBarrier(e.image, c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, e.layout, c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT, c.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, c.VK_ACCESS_2_MEMORY_READ_BIT);
        p.fns.vkCmdPipelineBarrier2.?(p.cmd, &.{ .sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO, .imageMemoryBarrierCount = p.end_count, .pImageMemoryBarriers = &barriers });
        p.owned = false;
    }
};

pub const ComputePass = struct {
    cmd: c.VkCommandBuffer,
    fns: *const device_mod.DeviceFns,

    pub inline fn setPipeline(p: *ComputePass, pipeline: anytype) void {
        p.fns.vkCmdBindPipeline.?(p.cmd, c.VK_PIPELINE_BIND_POINT_COMPUTE, pipeline.pipeline);
    }

    pub inline fn setBindGroup(p: *ComputePass, comptime index: u32, group: anytype) void {
        comptime checkIndex(Deref(@TypeOf(group)), index);
        p.fns.vkCmdBindDescriptorSets.?(p.cmd, c.VK_PIPELINE_BIND_POINT_COMPUTE, group.layout, index, 1, setPtr(group), 0, null);
    }

    pub inline fn dispatchWorkgroups(p: *ComputePass, x: u32, y: u32, z: u32) void {
        p.fns.vkCmdDispatch.?(p.cmd, x, y, z);
    }

    /// One global barrier from the dispatches' writes to every read after them.
    pub fn end(p: *ComputePass) void {
        const memory: c.VkMemoryBarrier2 = .{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER_2,
            .srcStageMask = c.VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT,
            .srcAccessMask = c.VK_ACCESS_2_SHADER_WRITE_BIT,
            .dstStageMask = c.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
            .dstAccessMask = c.VK_ACCESS_2_MEMORY_READ_BIT,
        };
        p.fns.vkCmdPipelineBarrier2.?(p.cmd, &.{ .sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO, .memoryBarrierCount = 1, .pMemoryBarriers = &memory });
    }
};

fn Deref(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |ptr| ptr.child,
        else => T,
    };
}

inline fn setPtr(group: anytype) *const c.VkDescriptorSet {
    if (@typeInfo(@TypeOf(group)) == .pointer) return &group.set;
    const set = group.set;
    return &set;
}

fn checkIndex(comptime G: type, comptime index: u32) void {
    if (!@hasDecl(G, "index")) @compileError("setBindGroup takes a BindGroup made by createBindGroup");
    if (G.index != index) @compileError(std.fmt.comptimePrint("bind group made for @group({d}) set at index {d}", .{ G.index, index }));
}

// ---------------------------------------------------------------------------------------------
// Conversions, folded at compile time when the descriptor is known

pub const max_groups = 4;
pub const max_color_targets = 4;
pub const max_vertex_buffers = 8;
pub const max_vertex_attributes = 16;
const max_upload_images = 16;

fn createLayout(dv: *const device_mod.Device, comptime S: type, set_layouts: *[max_groups]c.VkDescriptorSetLayout, layout: *c.VkPipelineLayout) Error!void {
    const groups = comptime S.module.groupCount();
    if (groups > max_groups) @compileError("more than 4 bind groups");
    inline for (0..groups) |g| {
        const bindings = comptime S.module.group(g);
        var lb: [bindings.len]c.VkDescriptorSetLayoutBinding = undefined;
        inline for (bindings, 0..) |b, i| lb[i] = .{
            .binding = b.binding,
            .descriptorType = comptime descriptorType(b.kind),
            .descriptorCount = 1,
            .stageFlags = c.VK_SHADER_STAGE_ALL,
        };
        try check(dv.fns.vkCreateDescriptorSetLayout.?(dv.handle, &.{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .bindingCount = bindings.len,
            .pBindings = &lb,
        }, null, &set_layouts[g]));
    }
    try check(dv.fns.vkCreatePipelineLayout.?(dv.handle, &.{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = groups,
        .pSetLayouts = set_layouts,
    }, null, layout));
}

fn shaderModule(dv: *const device_mod.Device, spirv: []const u32) Error!c.VkShaderModule {
    var module: c.VkShaderModule = null;
    try check(dv.fns.vkCreateShaderModule.?(dv.handle, &.{
        .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = spirv.len * 4,
        .pCode = spirv.ptr,
    }, null, &module));
    return module;
}

fn descriptorType(comptime k: reflect.Kind) c.VkDescriptorType {
    return switch (k) {
        .uniform => c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .storage_read, .storage_read_write => c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        .texture => c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
        .storage_texture => c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,
        .sampler, .comparison_sampler => c.VK_DESCRIPTOR_TYPE_SAMPLER,
    };
}

fn bufferUsage(u: BufferUsage) c.VkBufferUsageFlags {
    var f: c.VkBufferUsageFlags = 0;
    if (u.copy_src or u.map_read) f |= c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
    if (u.copy_dst or u.map_write) f |= c.VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    if (u.index) f |= c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT;
    if (u.vertex) f |= c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT;
    if (u.uniform) f |= c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT;
    if (u.storage) f |= c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
    if (u.indirect) f |= c.VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT;
    return f;
}

fn textureUsage(u: TextureUsage) c.VkImageUsageFlags {
    var f: c.VkImageUsageFlags = 0;
    if (u.copy_src) f |= c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    if (u.copy_dst) f |= c.VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    if (u.texture_binding) f |= c.VK_IMAGE_USAGE_SAMPLED_BIT;
    if (u.storage_binding) f |= c.VK_IMAGE_USAGE_STORAGE_BIT;
    if (u.render_attachment) f |= c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    return f;
}

pub fn vkFormat(f: TextureFormat) Error!c.VkFormat {
    return switch (f) {
        .r8_unorm => c.VK_FORMAT_R8_UNORM,
        .rg8_unorm => c.VK_FORMAT_R8G8_UNORM,
        .rgba8_unorm => c.VK_FORMAT_R8G8B8A8_UNORM,
        .rgba8_unorm_srgb => c.VK_FORMAT_R8G8B8A8_SRGB,
        .bgra8_unorm => c.VK_FORMAT_B8G8R8A8_UNORM,
        .bgra8_unorm_srgb => c.VK_FORMAT_B8G8R8A8_SRGB,
        .r16_float => c.VK_FORMAT_R16_SFLOAT,
        .rgba16_float => c.VK_FORMAT_R16G16B16A16_SFLOAT,
        .r32_float => c.VK_FORMAT_R32_SFLOAT,
        .rg32_float => c.VK_FORMAT_R32G32_SFLOAT,
        .rgba32_float => c.VK_FORMAT_R32G32B32A32_SFLOAT,
        .r32_uint => c.VK_FORMAT_R32_UINT,
        .depth32_float => c.VK_FORMAT_D32_SFLOAT,
    };
}

/// The projection's format for a native one, for hosts that made their own target.
pub fn fromVkFormat(f: c.VkFormat) TextureFormat {
    return switch (f) {
        c.VK_FORMAT_B8G8R8A8_UNORM => .bgra8_unorm,
        c.VK_FORMAT_B8G8R8A8_SRGB => .bgra8_unorm_srgb,
        c.VK_FORMAT_R8G8B8A8_SRGB => .rgba8_unorm_srgb,
        else => .rgba8_unorm,
    };
}

fn aspect(f: TextureFormat) c.VkImageAspectFlags {
    return if (f == .depth32_float) c.VK_IMAGE_ASPECT_DEPTH_BIT else c.VK_IMAGE_ASPECT_COLOR_BIT;
}

fn vertexFormat(f: VertexFormat) c.VkFormat {
    return switch (f) {
        .float32 => c.VK_FORMAT_R32_SFLOAT,
        .float32x2 => c.VK_FORMAT_R32G32_SFLOAT,
        .float32x3 => c.VK_FORMAT_R32G32B32_SFLOAT,
        .float32x4 => c.VK_FORMAT_R32G32B32A32_SFLOAT,
        .uint32 => c.VK_FORMAT_R32_UINT,
        .uint32x2 => c.VK_FORMAT_R32G32_UINT,
        .uint32x4 => c.VK_FORMAT_R32G32B32A32_UINT,
        .sint32 => c.VK_FORMAT_R32_SINT,
        .unorm8x4 => c.VK_FORMAT_R8G8B8A8_UNORM,
    };
}

fn topology(t: PrimitiveTopology) c.VkPrimitiveTopology {
    return switch (t) {
        .point_list => c.VK_PRIMITIVE_TOPOLOGY_POINT_LIST,
        .line_list => c.VK_PRIMITIVE_TOPOLOGY_LINE_LIST,
        .line_strip => c.VK_PRIMITIVE_TOPOLOGY_LINE_STRIP,
        .triangle_list => c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        .triangle_strip => c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP,
    };
}

fn filter(f: desc.FilterMode) c.VkFilter {
    return if (f == .linear) c.VK_FILTER_LINEAR else c.VK_FILTER_NEAREST;
}

fn address(a: desc.AddressMode) c.VkSamplerAddressMode {
    return switch (a) {
        .clamp_to_edge => c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .repeat => c.VK_SAMPLER_ADDRESS_MODE_REPEAT,
        .mirror_repeat => c.VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT,
    };
}

fn compareOp(f: desc.CompareFunction) c.VkCompareOp {
    return switch (f) {
        .never => c.VK_COMPARE_OP_NEVER,
        .less => c.VK_COMPARE_OP_LESS,
        .equal => c.VK_COMPARE_OP_EQUAL,
        .less_equal => c.VK_COMPARE_OP_LESS_OR_EQUAL,
        .greater => c.VK_COMPARE_OP_GREATER,
        .not_equal => c.VK_COMPARE_OP_NOT_EQUAL,
        .greater_equal => c.VK_COMPARE_OP_GREATER_OR_EQUAL,
        .always => c.VK_COMPARE_OP_ALWAYS,
    };
}

fn blendFactor(f: desc.BlendFactor) c.VkBlendFactor {
    return switch (f) {
        .zero => c.VK_BLEND_FACTOR_ZERO,
        .one => c.VK_BLEND_FACTOR_ONE,
        .src => c.VK_BLEND_FACTOR_SRC_COLOR,
        .one_minus_src => c.VK_BLEND_FACTOR_ONE_MINUS_SRC_COLOR,
        .src_alpha => c.VK_BLEND_FACTOR_SRC_ALPHA,
        .one_minus_src_alpha => c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
        .dst => c.VK_BLEND_FACTOR_DST_COLOR,
        .one_minus_dst => c.VK_BLEND_FACTOR_ONE_MINUS_DST_COLOR,
        .dst_alpha => c.VK_BLEND_FACTOR_DST_ALPHA,
        .one_minus_dst_alpha => c.VK_BLEND_FACTOR_ONE_MINUS_DST_ALPHA,
        .constant => c.VK_BLEND_FACTOR_CONSTANT_COLOR,
        .one_minus_constant => c.VK_BLEND_FACTOR_ONE_MINUS_CONSTANT_COLOR,
    };
}

fn blendOp(o: desc.BlendOperation) c.VkBlendOp {
    return switch (o) {
        .add => c.VK_BLEND_OP_ADD,
        .subtract => c.VK_BLEND_OP_SUBTRACT,
        .reverse_subtract => c.VK_BLEND_OP_REVERSE_SUBTRACT,
        .min => c.VK_BLEND_OP_MIN,
        .max => c.VK_BLEND_OP_MAX,
    };
}

fn blendAttachment(t: ColorTargetState) c.VkPipelineColorBlendAttachmentState {
    const m = t.write_mask;
    var mask: c.VkColorComponentFlags = 0;
    if (m.red) mask |= c.VK_COLOR_COMPONENT_R_BIT;
    if (m.green) mask |= c.VK_COLOR_COMPONENT_G_BIT;
    if (m.blue) mask |= c.VK_COLOR_COMPONENT_B_BIT;
    if (m.alpha) mask |= c.VK_COLOR_COMPONENT_A_BIT;
    const b = t.blend orelse return .{ .colorWriteMask = mask };
    return .{
        .blendEnable = c.VK_TRUE,
        .srcColorBlendFactor = blendFactor(b.color.src_factor),
        .dstColorBlendFactor = blendFactor(b.color.dst_factor),
        .colorBlendOp = blendOp(b.color.operation),
        .srcAlphaBlendFactor = blendFactor(b.alpha.src_factor),
        .dstAlphaBlendFactor = blendFactor(b.alpha.dst_factor),
        .alphaBlendOp = blendOp(b.alpha.operation),
        .colorWriteMask = mask,
    };
}

fn layoutBarrier(image: c.VkImage, from: c.VkImageLayout, to: c.VkImageLayout, src_stage: u64, src_access: u64, dst_stage: u64, dst_access: u64) c.VkImageMemoryBarrier2 {
    return .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
        .srcStageMask = src_stage,
        .srcAccessMask = src_access,
        .dstStageMask = dst_stage,
        .dstAccessMask = dst_access,
        .oldLayout = from,
        .newLayout = to,
        .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .levelCount = 1, .layerCount = 1 },
    };
}

fn imageBarrier(fns: *const device_mod.DeviceFns, cmd: c.VkCommandBuffer, image: c.VkImage, from: c.VkImageLayout, to: c.VkImageLayout, src_stage: u64, src_access: u64, dst_stage: u64, dst_access: u64) void {
    const b = layoutBarrier(image, from, to, src_stage, src_access, dst_stage, dst_access);
    fns.vkCmdPipelineBarrier2.?(cmd, &.{ .sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO, .imageMemoryBarrierCount = 1, .pImageMemoryBarriers = &b });
}

const testing = std.testing;
const host = @import("host.zig");
const pass_mod = @import("pass.zig");
const shaders = @import("gpu_shaders");

/// The host side of lcgf.gpu_check on Vulkan: one-shot command buffers, readback through a copy.
const Check = struct {
    h: *host.Host,

    pub fn upload(k: *Check, staging: *Staging) !Upload {
        return .beginStaged(.wrap(&k.h.device), try k.h.once.begin(&k.h.device), staging);
    }
    pub fn submit(k: *Check) !void {
        try k.h.once.submit(&k.h.device);
    }
    pub fn readTexture(k: *Check, t: Texture, out: []u8) !void {
        const d = &k.h.device;
        const cmd = try k.h.once.begin(d);
        pass_mod.transition(d, cmd, t.image, t.resting, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL);
        try k.h.once.submit(d);
        try k.h.readback(t.image, .{ .width = t.width, .height = t.height }, out);
    }
    pub fn readBuffer(k: *Check, b: Buffer, out: []u8) !void {
        Device.wrap(&k.h.device).readBuffer(b, 0, out);
    }
};

test "gpu: upload, render to a texture, sample it in a second pass, on a real device" {
    var h: host.Host = undefined;
    try h.init();
    defer h.deinit();
    var k: Check = .{ .h = &h };
    try lcgf.gpu_check.renderToTexture(@This(), shaders, .wrap(&h.device), &k);
}

test "gpu: a compute pass writes a storage buffer the host reads" {
    var h: host.Host = undefined;
    try h.init();
    defer h.deinit();
    var k: Check = .{ .h = &h };
    try lcgf.gpu_check.compute(@This(), shaders, .wrap(&h.device), &k);
}

test "gpu: the gpu guide's picture (docs/guide/gpu.zig), offscreen and read back" {
    const guide = @import("guide_gpu");
    var h: host.Host = undefined;
    try h.init();
    defer h.deinit();
    const dev: Device = .wrap(&h.device);
    var arena: Arena = try .init(dev, .{ .bytes = 1 << 20 });
    defer arena.deinit();
    var host_arena: Arena = try .init(dev, .{ .bytes = 1 << 16, .memory = .host });
    defer host_arena.deinit();
    var staging: Staging = try .init(dev, &host_arena, 1 << 12);
    defer staging.deinit(dev);
    var picture = try guide.Picture(@This(), shaders.textured).init(dev, &arena, .{ .format = .rgba8_unorm });
    defer picture.deinit(dev);
    const target = try dev.createTexture(&arena, .{ .size = .{ .width = 8, .height = 8 }, .format = .rgba8_unorm, .usage = .{ .texture_binding = true, .render_attachment = true, .copy_src = true } });
    defer dev.destroyTexture(target);
    var k: Check = .{ .h = &h };
    var up = try k.upload(&staging);
    try picture.upload(&up, .{ 1, 1, 1, 1 });
    picture.drawInto(up.finish(), target);
    try k.submit();
    var px: [8 * 8 * 4]u8 = undefined;
    try k.readTexture(target, &px);
    // Each texel of the 2 × 2 checker is a 4 × 4 block.
    for ([_][3]usize{ .{ 1, 1, 0 }, .{ 6, 1, 1 }, .{ 1, 6, 2 }, .{ 6, 6, 3 } }) |e|
        try testing.expectEqualSlices(u8, guide.checker[e[2] * 4 ..][0..4], px[(e[1] * 8 + e[0]) * 4 ..][0..4]);
}

test "gpu: types are the native handles, with nothing hidden" {
    try testing.expectEqual(2 * @sizeOf(usize), @sizeOf(BindGroup(Shader(shaders.gradient), 0)));
    try testing.expectEqual(@sizeOf(c.VkSampler), @sizeOf(Sampler));
    try testing.expectEqual(@as(c.VkFormat, c.VK_FORMAT_B8G8R8A8_UNORM), try vkFormat(.bgra8_unorm));
}
