//! `lcgf_render.gpu` on Direct3D 12: WebGPU's object model projected onto D3D12 at compile time.
//! Every type is a plain struct of D3D12 objects and descriptors with public fields
//! (`pass.list` is the `ID3D12GraphicsCommandList`, `buffer.resource` the `ID3D12Resource`).
//!
//! Bind groups are descriptor tables. A shader's root signature is built from its reflection:
//! for each group, one table of its buffers and textures (registers b/t/u = binding, space =
//! group, as naga numbers them) and, if it has samplers, one table of those. A bind group is a
//! run of descriptors in its arena's shader-visible heaps; `setBindGroup` sets the heaps and
//! one or two root tables. naga routes samplers through a 2048-entry heap and an index buffer;
//! `Shader` rewrites those declarations to plain `register(sB, spaceG)` samplers at compile time
//! (src/render/gpu/naga.zig).
//!
//! Resource states by convention, not tracking. A texture rests in one state: UNORDERED_ACCESS
//! with `storage_binding`, else shader-readable with `texture_binding`, else RENDER_TARGET. It is
//! created there. Writes move it to COPY_DEST and `finish` back; a render pass moves it to
//! RENDER_TARGET and `end` back. Buffers rest in COMMON, promoted implicitly by D3D12; the
//! buffers an upload wrote return to COMMON at `finish`. An `Upload` begins its command list.
//!
//! Writes go through the device's `Staging` ring (an UPLOAD heap buffer), copied on the queue,
//! so a frame in flight keeps its data: `Device.staging` must be set before an upload.
//!
//! Memory: each resource is a committed allocation. The `Arena` holds the descriptor heaps its
//! bind groups and render targets live in.

const std = @import("std");
const builtin = @import("builtin");
const lcgf = @import("lcgf");
const com = @import("com.zig");
const device_mod = @import("device.zig");
const pipeline_mod = @import("pipeline.zig");
const c = com.c;
const desc = lcgf.gpu_desc;
const reflect = lcgf.gpu_reflect;

pub const Error = com.Error || error{ OutOfArena, IncompatibleMemory, UnsupportedFormat, ShaderCompile, NoStaging };

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

pub const native = .d3d12;
/// The Direct3D 12 C API, as this back end translated it.
pub const d3d12 = c;

const debug_checks = builtin.mode == .debug;

pub const max_groups = 4;
pub const max_color_targets = 4;
pub const max_vertex_buffers = 8;
pub const max_vertex_attributes = 16;
const max_upload_writes = 32;

const shader_resource = c.D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE | c.D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;

fn raw(comptime T: type, obj: anytype) *T {
    return @ptrCast(@alignCast(obj));
}

// ---------------------------------------------------------------------------------------------
// Device and memory

pub const Device = struct {
    dev: *const device_mod.Device,
    /// Where uploads copy from. Set it before the first `Upload.begin`.
    staging: ?*Staging = null,

    pub fn wrap(d: *const device_mod.Device) Device {
        return .{ .dev = d };
    }

    fn handle(device: Device) *com.Device {
        return device.dev.handle;
    }

    pub fn createBuffer(device: Device, arena: *Arena, d: BufferDescriptor) Error!Buffer {
        // Constant buffer views take whole 256-byte blocks.
        const size = if (d.usage.uniform) std.mem.alignForward(u64, d.size, 256) else d.size;
        const upload = arena.kind == .host;
        var rd = bufferDesc(size);
        if (d.usage.storage) rd.Flags = c.D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
        // An upload heap cannot hold an unordered-access resource (E_INVALIDARG): a host storage
        // buffer lives in a custom heap the CPU maps write-back, in system memory (L0).
        var heap = device_mod.heapProps(if (upload) c.D3D12_HEAP_TYPE_UPLOAD else c.D3D12_HEAP_TYPE_DEFAULT);
        if (upload and d.usage.storage) {
            heap.Type = c.D3D12_HEAP_TYPE_CUSTOM;
            heap.CPUPageProperty = c.D3D12_CPU_PAGE_PROPERTY_WRITE_BACK;
            heap.MemoryPoolPreference = c.D3D12_MEMORY_POOL_L0;
        }
        const state: c.D3D12_RESOURCE_STATES = if (upload and !d.usage.storage) c.D3D12_RESOURCE_STATE_GENERIC_READ else c.D3D12_RESOURCE_STATE_COMMON;
        const resource = try device.handle().createCommittedResource(&heap, &rd, state, null);
        return .{ .resource = resource, .address = resource.getGPUVirtualAddress(), .size = d.size, .mapped = if (upload) try resource.map(false) else null };
    }

    pub fn destroyBuffer(_: Device, b: Buffer) void {
        com.release(b.resource);
    }

    pub fn createTexture(device: Device, arena: *Arena, d: TextureDescriptor) Error!Texture {
        const format = try dxgiFormat(d.format);
        var rd: c.D3D12_RESOURCE_DESC = std.mem.zeroes(c.D3D12_RESOURCE_DESC);
        rd.Dimension = c.D3D12_RESOURCE_DIMENSION_TEXTURE2D;
        rd.Width = d.size.width;
        rd.Height = d.size.height;
        rd.DepthOrArraySize = @intCast(d.size.depth_or_array_layers);
        rd.MipLevels = @intCast(d.mip_level_count);
        rd.Format = format;
        rd.SampleDesc = .{ .Count = d.sample_count, .Quality = 0 };
        rd.Layout = c.D3D12_TEXTURE_LAYOUT_UNKNOWN;
        if (d.usage.render_attachment) rd.Flags |= c.D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
        if (d.usage.storage_binding) rd.Flags |= c.D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
        const resting: c.D3D12_RESOURCE_STATES = if (d.usage.storage_binding)
            c.D3D12_RESOURCE_STATE_UNORDERED_ACCESS
        else if (d.usage.texture_binding)
            shader_resource
        else if (d.usage.render_attachment)
            c.D3D12_RESOURCE_STATE_RENDER_TARGET
        else
            c.D3D12_RESOURCE_STATE_COMMON;
        const heap = device_mod.heapProps(c.D3D12_HEAP_TYPE_DEFAULT);
        const resource = try device.handle().createCommittedResource(&heap, &rd, resting, null);
        var t: Texture = .{ .resource = resource, .format = d.format, .width = d.size.width, .height = d.size.height, .samples = d.sample_count, .resting = resting, .rtv = .{ .ptr = 0 } };
        if (d.usage.render_attachment) {
            t.rtv = try arena.take(.rtv, 1);
            device.handle().createRenderTargetView(resource, null, t.rtv);
        }
        return t;
    }

    pub fn destroyTexture(_: Device, t: Texture) void {
        com.release(t.resource);
    }

    /// A sampler is a descriptor in D3D12: this is its description, written into a bind group's
    /// sampler table when the group is made.
    pub fn createSampler(_: Device, d: SamplerDescriptor) Error!Sampler {
        const linear_min = d.min_filter == .linear;
        const linear_mag = d.mag_filter == .linear;
        const linear_mip = d.mipmap_filter == .linear;
        var filter: c.D3D12_FILTER = @intCast(@as(u32, @intFromBool(linear_mip)) | (@as(u32, @intFromBool(linear_mag)) << 2) | (@as(u32, @intFromBool(linear_min)) << 4));
        if (d.compare != null) filter |= 0x80; // D3D12_FILTER_REDUCTION_TYPE_COMPARISON
        return .{ .desc = .{
            .Filter = filter,
            .AddressU = addressMode(d.address_mode_u),
            .AddressV = addressMode(d.address_mode_v),
            .AddressW = addressMode(d.address_mode_w),
            .MipLODBias = 0,
            .MaxAnisotropy = 1,
            .ComparisonFunc = if (d.compare) |f| compareFunc(f) else c.D3D12_COMPARISON_FUNC_NEVER,
            .BorderColor = .{ 0, 0, 0, 0 },
            .MinLOD = d.lod_min_clamp,
            .MaxLOD = d.lod_max_clamp,
        } };
    }

    pub fn destroySampler(_: Device, _: Sampler) void {}

    pub fn createRenderPipeline(device: Device, comptime S: type, d: RenderPipelineDescriptor) Error!RenderPipeline(S) {
        const root = try rootSignature(device.handle(), S);
        errdefer com.release(root);
        const frag = d.fragment orelse desc.FragmentState{ .targets = &.{} };
        const vs = try pipeline_mod.compile(S.hlsl, d.vertex.entry_point, "vs_5_1");
        defer com.release(vs);
        const ps = try pipeline_mod.compile(S.hlsl, frag.entry_point, "ps_5_1");
        defer com.release(ps);
        var p: RenderPipeline(S) = .{ .pso = undefined, .root = root, .topology = topology(d.primitive.topology) };
        var elements: [max_vertex_attributes]c.D3D12_INPUT_ELEMENT_DESC = undefined;
        var n: u32 = 0;
        for (d.vertex.buffers, 0..) |vb, slot| {
            p.strides[slot] = @intCast(vb.array_stride);
            for (vb.attributes) |a| {
                elements[n] = .{
                    .SemanticName = "LOC",
                    .SemanticIndex = a.shader_location,
                    .Format = vertexFormat(a.format),
                    .InputSlot = @intCast(slot),
                    .AlignedByteOffset = @intCast(a.offset),
                    .InputSlotClass = if (vb.step_mode == .instance) c.D3D12_INPUT_CLASSIFICATION_PER_INSTANCE_DATA else c.D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA,
                    .InstanceDataStepRate = @intFromBool(vb.step_mode == .instance),
                };
                n += 1;
            }
        }
        var pd: c.D3D12_GRAPHICS_PIPELINE_STATE_DESC = std.mem.zeroes(c.D3D12_GRAPHICS_PIPELINE_STATE_DESC);
        pd.pRootSignature = @ptrCast(@alignCast(root));
        pd.VS = .{ .pShaderBytecode = vs.bytes().ptr, .BytecodeLength = vs.bytes().len };
        pd.PS = .{ .pShaderBytecode = ps.bytes().ptr, .BytecodeLength = ps.bytes().len };
        for (frag.targets, 0..) |t, i| {
            pd.BlendState.RenderTarget[i] = blendDesc(t);
            pd.RTVFormats[i] = try dxgiFormat(t.format);
        }
        pd.BlendState.AlphaToCoverageEnable = @intFromBool(d.multisample.alpha_to_coverage_enabled);
        pd.SampleMask = d.multisample.mask;
        pd.RasterizerState = .{
            .FillMode = c.D3D12_FILL_MODE_SOLID,
            .CullMode = switch (d.primitive.cull_mode) {
                .none => c.D3D12_CULL_MODE_NONE,
                .front => c.D3D12_CULL_MODE_FRONT,
                .back => c.D3D12_CULL_MODE_BACK,
            },
            .FrontCounterClockwise = @intFromBool(d.primitive.front_face == .ccw),
            .DepthBias = 0,
            .DepthBiasClamp = 0,
            .SlopeScaledDepthBias = 0,
            .DepthClipEnable = 1,
            .MultisampleEnable = @intFromBool(d.multisample.count > 1),
            .AntialiasedLineEnable = 0,
            .ForcedSampleCount = 0,
            .ConservativeRaster = c.D3D12_CONSERVATIVE_RASTERIZATION_MODE_OFF,
        };
        pd.InputLayout = .{ .pInputElementDescs = &elements, .NumElements = n };
        pd.IBStripCutValue = if (d.primitive.strip_index_format) |f| (if (f == .uint16) c.D3D12_INDEX_BUFFER_STRIP_CUT_VALUE_0xFFFF else c.D3D12_INDEX_BUFFER_STRIP_CUT_VALUE_0xFFFFFFFF) else c.D3D12_INDEX_BUFFER_STRIP_CUT_VALUE_DISABLED;
        pd.PrimitiveTopologyType = switch (d.primitive.topology) {
            .point_list => c.D3D12_PRIMITIVE_TOPOLOGY_TYPE_POINT,
            .line_list, .line_strip => c.D3D12_PRIMITIVE_TOPOLOGY_TYPE_LINE,
            .triangle_list, .triangle_strip => c.D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE,
        };
        pd.NumRenderTargets = @intCast(frag.targets.len);
        pd.SampleDesc = .{ .Count = d.multisample.count, .Quality = 0 };
        p.pso = try device.handle().createGraphicsPipelineState(&pd);
        return p;
    }

    pub fn destroyRenderPipeline(_: Device, p: anytype) void {
        com.release(p.pso);
        com.release(p.root);
    }

    pub fn createComputePipeline(device: Device, comptime S: type, d: ComputePipelineDescriptor) Error!ComputePipeline(S) {
        const root = try rootSignature(device.handle(), S);
        errdefer com.release(root);
        const cs = try pipeline_mod.compile(S.hlsl, d.entry_point, "cs_5_1");
        defer com.release(cs);
        var pd: c.D3D12_COMPUTE_PIPELINE_STATE_DESC = std.mem.zeroes(c.D3D12_COMPUTE_PIPELINE_STATE_DESC);
        pd.pRootSignature = @ptrCast(@alignCast(root));
        pd.CS = .{ .pShaderBytecode = cs.bytes().ptr, .BytecodeLength = cs.bytes().len };
        const dv = raw(c.ID3D12Device, device.handle());
        var pso: ?*anyopaque = null;
        try com.check(dv.lpVtbl.*.CreateComputePipelineState.?(dv, &pd, &com.PipelineState.iid, &pso));
        return .{ .pso = @ptrCast(pso.?), .root = root };
    }

    pub const destroyComputePipeline = destroyRenderPipeline;

    /// A bind group for group `g` of `pipeline`'s shader: its descriptors, written into a run
    /// of the arena's shader-visible heaps.
    pub fn createBindGroup(device: Device, arena: *Arena, pipeline: anytype, comptime g: u32, entries: Deref(@TypeOf(pipeline)).Shader.Group(g)) Error!BindGroup(Deref(@TypeOf(pipeline)).Shader, g) {
        const S = Deref(@TypeOf(pipeline)).Shader;
        const plan = comptime tablePlan(S.module, g);
        const dv = raw(c.ID3D12Device, device.handle());
        var bg: BindGroup(S, g) = .{ .resources = .{ .ptr = 0 }, .samplers = .{ .ptr = 0 }, .heaps = .{ arena.resources, arena.samplers } };
        const res_cpu = if (plan.resources > 0) try arena.take(.resources, plan.resources) else c.D3D12_CPU_DESCRIPTOR_HANDLE{ .ptr = 0 };
        const smp_cpu = if (plan.samplers > 0) try arena.take(.samplers, plan.samplers) else c.D3D12_CPU_DESCRIPTOR_HANDLE{ .ptr = 0 };
        if (plan.resources > 0) bg.resources = arena.gpuOf(.resources, res_cpu);
        if (plan.samplers > 0) bg.samplers = arena.gpuOf(.samplers, smp_cpu);
        comptime var r: u32 = 0;
        comptime var s: u32 = 0;
        inline for (comptime S.module.group(g)) |b| {
            const v = @field(entries, b.name);
            const at: c.D3D12_CPU_DESCRIPTOR_HANDLE = .{ .ptr = res_cpu.ptr + r * arena.stride(.resources) };
            switch (comptime b.kind) {
                .uniform => {
                    dv.lpVtbl.*.CreateConstantBufferView.?(dv, &.{ .BufferLocation = v.address, .SizeInBytes = @intCast(std.mem.alignForward(u64, v.size, 256)) }, at);
                    r += 1;
                },
                .storage_read => {
                    var sd: c.D3D12_SHADER_RESOURCE_VIEW_DESC = std.mem.zeroes(c.D3D12_SHADER_RESOURCE_VIEW_DESC);
                    sd.Format = c.DXGI_FORMAT_R32_TYPELESS;
                    sd.ViewDimension = c.D3D12_SRV_DIMENSION_BUFFER;
                    sd.Shader4ComponentMapping = c.D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
                    sd.unnamed_0.Buffer = .{ .FirstElement = 0, .NumElements = @intCast(v.size / 4), .StructureByteStride = 0, .Flags = c.D3D12_BUFFER_SRV_FLAG_RAW };
                    device.handle().createShaderResourceView(v.resource, &sd, at);
                    r += 1;
                },
                .storage_read_write => {
                    var ud: c.D3D12_UNORDERED_ACCESS_VIEW_DESC = std.mem.zeroes(c.D3D12_UNORDERED_ACCESS_VIEW_DESC);
                    ud.Format = c.DXGI_FORMAT_R32_TYPELESS;
                    ud.ViewDimension = c.D3D12_UAV_DIMENSION_BUFFER;
                    ud.unnamed_0.Buffer = .{ .FirstElement = 0, .NumElements = @intCast(v.size / 4), .StructureByteStride = 0, .CounterOffsetInBytes = 0, .Flags = c.D3D12_BUFFER_UAV_FLAG_RAW };
                    dv.lpVtbl.*.CreateUnorderedAccessView.?(dv, raw(c.ID3D12Resource, v.resource), null, &ud, at);
                    r += 1;
                },
                .texture => {
                    device.handle().createShaderResourceView(v.resource, null, at);
                    r += 1;
                },
                .storage_texture => {
                    dv.lpVtbl.*.CreateUnorderedAccessView.?(dv, raw(c.ID3D12Resource, v.resource), null, null, at);
                    r += 1;
                },
                .sampler, .comparison_sampler => {
                    dv.lpVtbl.*.CreateSampler.?(dv, &v.desc, .{ .ptr = smp_cpu.ptr + s * arena.stride(.samplers) });
                    s += 1;
                },
            }
        }
        return bg;
    }
};

/// The descriptor heaps bind groups and render targets live in, owned by the caller. `.host`
/// also makes the arena's buffers UPLOAD-heap memory, mapped for the CPU.
pub const Arena = struct {
    kind: Kind,
    resources: *com.DescriptorHeap,
    samplers: *com.DescriptorHeap,
    rtvs: *com.DescriptorHeap,
    used: [3]u32 = .{ 0, 0, 0 },
    capacity: [3]u32,
    strides: [3]u32,

    pub const Kind = enum { device, host };
    pub const Options = struct { bytes: u64, memory: Kind = .device, bind_groups: u32 = 64 };
    const Which = enum(u2) { resources, samplers, rtv };

    pub fn init(device: Device, o: Options) Error!Arena {
        const d = device.handle();
        const n = o.bind_groups;
        const counts = [3]u32{ 8 * n, 4 * n, n };
        const kinds = [3]c.D3D12_DESCRIPTOR_HEAP_TYPE{ c.D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, c.D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER, c.D3D12_DESCRIPTOR_HEAP_TYPE_RTV };
        var heaps: [3]*com.DescriptorHeap = undefined;
        var strides: [3]u32 = undefined;
        for (0..3) |i| {
            heaps[i] = try d.createDescriptorHeap(&.{
                .Type = kinds[i],
                .NumDescriptors = counts[i],
                .Flags = if (i < 2) c.D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE else c.D3D12_DESCRIPTOR_HEAP_FLAG_NONE,
                .NodeMask = 0,
            });
            strides[i] = d.getDescriptorHandleIncrementSize(kinds[i]);
        }
        return .{ .kind = o.memory, .resources = heaps[0], .samplers = heaps[1], .rtvs = heaps[2], .capacity = counts, .strides = strides };
    }

    pub fn deinit(a: *Arena) void {
        com.release(a.rtvs);
        com.release(a.samplers);
        com.release(a.resources);
    }

    /// Forgets every bind group and render target view placed here.
    pub fn reset(a: *Arena) void {
        a.used = .{ 0, 0, 0 };
    }

    fn heap(a: *const Arena, w: Which) *com.DescriptorHeap {
        return switch (w) {
            .resources => a.resources,
            .samplers => a.samplers,
            .rtv => a.rtvs,
        };
    }

    fn stride(a: *const Arena, w: Which) u32 {
        return a.strides[@backingInt(w)];
    }

    fn take(a: *Arena, w: Which, n: u32) Error!c.D3D12_CPU_DESCRIPTOR_HANDLE {
        const i = @backingInt(w);
        if (a.used[i] + n > a.capacity[i]) return error.OutOfArena;
        const at = a.heap(w).cpuStart().ptr + a.used[i] * a.strides[i];
        a.used[i] += n;
        return .{ .ptr = at };
    }

    fn gpuOf(a: *const Arena, w: Which, cpu: c.D3D12_CPU_DESCRIPTOR_HANDLE) c.D3D12_GPU_DESCRIPTOR_HANDLE {
        const h = a.heap(w);
        return .{ .ptr = h.gpuStart().ptr + (cpu.ptr - h.cpuStart().ptr) };
    }
};

/// An UPLOAD-heap ring the frame's writes copy from. One per frame in flight; `rewind` it when
/// that frame's previous use has completed.
pub const Staging = struct {
    buffer: Buffer,
    used: u64 = 0,

    pub fn init(device: Device, arena: *Arena, bytes: u64) Error!Staging {
        if (arena.kind != .host) return error.IncompatibleMemory;
        return .{ .buffer = try device.createBuffer(arena, .{ .size = bytes, .usage = .{ .copy_src = true } }) };
    }

    pub fn deinit(s: Staging, device: Device) void {
        device.destroyBuffer(s.buffer);
    }

    pub fn rewind(s: *Staging) void {
        s.used = 0;
    }

    fn reserve(s: *Staging, n: u64, alignment: u64) Error!u64 {
        const at = std.mem.alignForward(u64, s.used, alignment);
        if (at + n > s.buffer.size) return error.OutOfArena;
        s.used = at + n;
        return at;
    }
};

// ---------------------------------------------------------------------------------------------
// Objects

pub const Buffer = struct {
    resource: *com.Resource,
    /// Its GPU virtual address.
    address: u64,
    size: u64,
    /// Set in a `.host` arena (UPLOAD heap).
    mapped: ?[*]u8,
};

pub const Texture = struct {
    resource: *com.Resource,
    format: TextureFormat,
    width: u32,
    height: u32,
    samples: u32,
    /// The state it keeps between passes (see the file comment).
    resting: c.D3D12_RESOURCE_STATES,
    /// Its render target view, if it is a render attachment.
    rtv: c.D3D12_CPU_DESCRIPTOR_HANDLE,

    pub fn createView(t: Texture) TextureView {
        return .{ .resource = t.resource, .rtv = t.rtv, .width = t.width, .height = t.height, .samples = t.samples, .resting = t.resting, .format = t.format };
    }
};

pub const TextureView = struct {
    resource: *com.Resource,
    rtv: c.D3D12_CPU_DESCRIPTOR_HANDLE = .{ .ptr = 0 },
    width: u32,
    height: u32,
    samples: u32 = 1,
    resting: c.D3D12_RESOURCE_STATES = shader_resource,
    format: TextureFormat = .rgba8_unorm,
};

pub const Sampler = struct { desc: c.D3D12_SAMPLER_DESC };

/// A shader: `source` is a namespace with `wgsl` and naga's HLSL of it (`hlsl`), as
/// `addGpuShaders` makes for d3d12. Its samplers are rewritten here (see the file comment).
pub fn Shader(comptime source: type) type {
    if (!@hasDecl(source, "hlsl")) @compileError("shader has no HLSL: build it with addGpuShaders for the d3d12 back end");
    return struct {
        pub const module = reflect.parse(source.wgsl);
        pub const hlsl: [:0]const u8 = lcgf.gpu_naga.hlsl(source.hlsl);
        pub fn Group(comptime g: u32) type {
            return module.Group(g, Buffer, TextureView, Sampler);
        }
    };
}

pub fn RenderPipeline(comptime S: type) type {
    return struct {
        pso: *com.PipelineState,
        root: *com.RootSignature,
        topology: c.D3D12_PRIMITIVE_TOPOLOGY,
        strides: [max_vertex_buffers]u32 = @splat(0),
        pub const Shader = S;
    };
}

pub fn ComputePipeline(comptime S: type) type {
    return struct {
        pso: *com.PipelineState,
        root: *com.RootSignature,
        pub const Shader = S;
    };
}

/// A bind group: where its descriptor tables start in the arena's two shader-visible heaps.
pub fn BindGroup(comptime S: type, comptime g: u32) type {
    return struct {
        resources: c.D3D12_GPU_DESCRIPTOR_HANDLE,
        samplers: c.D3D12_GPU_DESCRIPTOR_HANDLE,
        heaps: [2]*com.DescriptorHeap,
        pub const Shader = S;
        pub const index = g;
    };
}

// ---------------------------------------------------------------------------------------------
// Root signature, from the reflection

const Plan = struct { resources: u32, samplers: u32 };

fn tablePlan(comptime m: reflect.Module, comptime g: u32) Plan {
    var p: Plan = .{ .resources = 0, .samplers = 0 };
    for (m.group(g)) |b| {
        if (b.kind == .sampler or b.kind == .comparison_sampler) p.samplers += 1 else p.resources += 1;
    }
    return p;
}

/// The root parameter of group `g`'s resource table, and of its sampler table (one after it).
fn rootParam(comptime m: reflect.Module, comptime g: u32) u32 {
    var n: u32 = 0;
    for (0..g) |k| {
        const p = tablePlan(m, k);
        n += @as(u32, @intFromBool(p.resources > 0)) + @intFromBool(p.samplers > 0);
    }
    return n;
}

fn rootSignature(d: *com.Device, comptime S: type) Error!*com.RootSignature {
    const m = S.module;
    const groups = comptime m.groupCount();
    const total = comptime m.bindings.len;
    var ranges: [@max(total, 1)]c.D3D12_DESCRIPTOR_RANGE = undefined;
    var params: [2 * @as(usize, @max(groups, 1))]c.D3D12_ROOT_PARAMETER = undefined;
    var nr: u32 = 0;
    var np: u32 = 0;
    inline for (0..groups) |g| {
        inline for (.{ false, true }) |sampler_table| {
            const first = nr;
            comptime var k: u32 = 0;
            inline for (comptime m.group(g)) |b| {
                const is_sampler = comptime (b.kind == .sampler or b.kind == .comparison_sampler);
                if (is_sampler == sampler_table) {
                    ranges[nr] = .{
                        .RangeType = comptime rangeType(b.kind),
                        .NumDescriptors = 1,
                        .BaseShaderRegister = b.binding,
                        .RegisterSpace = g,
                        .OffsetInDescriptorsFromTableStart = k,
                    };
                    nr += 1;
                    k += 1;
                }
            }
            if (nr > first) {
                params[np] = std.mem.zeroes(c.D3D12_ROOT_PARAMETER);
                params[np].ParameterType = c.D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
                params[np].unnamed_0.DescriptorTable = .{ .NumDescriptorRanges = nr - first, .pDescriptorRanges = &ranges[first] };
                params[np].ShaderVisibility = c.D3D12_SHADER_VISIBILITY_ALL;
                np += 1;
            }
        }
    }
    return pipeline_mod.serialiseRoot(d, &.{
        .NumParameters = np,
        .pParameters = &params,
        .NumStaticSamplers = 0,
        .pStaticSamplers = null,
        .Flags = c.D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT,
    });
}

fn rangeType(comptime k: reflect.Kind) c.D3D12_DESCRIPTOR_RANGE_TYPE {
    return switch (k) {
        .uniform => c.D3D12_DESCRIPTOR_RANGE_TYPE_CBV,
        .storage_read, .texture => c.D3D12_DESCRIPTOR_RANGE_TYPE_SRV,
        .storage_read_write, .storage_texture => c.D3D12_DESCRIPTOR_RANGE_TYPE_UAV,
        .sampler, .comparison_sampler => c.D3D12_DESCRIPTOR_RANGE_TYPE_SAMPLER,
    };
}

// ---------------------------------------------------------------------------------------------
// Frame phases

const Written = struct { resource: *com.Resource, after: c.D3D12_RESOURCE_STATES };

/// The write phase: copies from the device's staging ring, recorded into the host's command
/// list before any pass. `finish` returns what it wrote to its resting state.
pub const Upload = struct {
    list: *com.GraphicsCommandList,
    dev: *com.Device,
    staging: *Staging,
    written: [max_upload_writes]Written = undefined,
    count: u32 = 0,

    pub fn begin(device: Device, list: *com.GraphicsCommandList) Upload {
        return .{ .list = list, .dev = device.handle(), .staging = device.staging.? };
    }

    pub fn beginStaged(device: Device, list: *com.GraphicsCommandList, staging: *Staging) Upload {
        return .{ .list = list, .dev = device.handle(), .staging = staging };
    }

    pub fn writeBuffer(up: *Upload, buffer: Buffer, offset: u64, bytes: []const u8) void {
        if (debug_checks) std.debug.assert(offset % 4 == 0 and bytes.len % 4 == 0 and offset + bytes.len <= buffer.size);
        const at = up.staging.reserve(bytes.len, 4) catch @panic("lcgf_render.gpu: the staging ring is full");
        @memcpy(up.staging.buffer.mapped.?[@intCast(at)..][0..bytes.len], bytes);
        const l = raw(c.ID3D12GraphicsCommandList, up.list);
        // COMMON is promoted to COPY_DEST by the copy itself.
        l.lpVtbl.*.CopyBufferRegion.?(l, raw(c.ID3D12Resource, buffer.resource), offset, raw(c.ID3D12Resource, up.staging.buffer.resource), at, bytes.len);
        up.wrote(buffer.resource, c.D3D12_RESOURCE_STATE_COMMON);
    }

    pub fn writeTexture(up: *Upload, t: Texture, bytes: []const u8, bytes_per_row: u32) Error!void {
        const rd = t.resource.getDesc();
        var footprint: c.D3D12_PLACED_SUBRESOURCE_FOOTPRINT = undefined;
        var total: u64 = 0;
        up.dev.getCopyableFootprints(&rd, &footprint, &total);
        const at = try up.staging.reserve(total, c.D3D12_TEXTURE_DATA_PLACEMENT_ALIGNMENT);
        const row = t.width * t.format.bytesPerPixel();
        const dst = up.staging.buffer.mapped.? + @as(usize, @intCast(at));
        for (0..t.height) |y| @memcpy(dst[y * footprint.Footprint.RowPitch ..][0..row], bytes[y * bytes_per_row ..][0..row]);
        footprint.Offset = at;
        if (t.resting != c.D3D12_RESOURCE_STATE_COPY_DEST) up.list.resourceBarrier(&.{device_mod.transition(t.resource, t.resting, c.D3D12_RESOURCE_STATE_COPY_DEST)});
        var to: c.D3D12_TEXTURE_COPY_LOCATION = std.mem.zeroes(c.D3D12_TEXTURE_COPY_LOCATION);
        to.pResource = raw(c.ID3D12Resource, t.resource);
        to.Type = c.D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        var from: c.D3D12_TEXTURE_COPY_LOCATION = std.mem.zeroes(c.D3D12_TEXTURE_COPY_LOCATION);
        from.pResource = raw(c.ID3D12Resource, up.staging.buffer.resource);
        from.Type = c.D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
        from.unnamed_0.PlacedFootprint = footprint;
        up.list.copyTextureRegion(&to, &from);
        up.wrote(t.resource, t.resting);
    }

    /// Textures are created in their resting state: nothing to do.
    pub fn prepare(_: *Upload, _: Texture) void {}

    fn wrote(up: *Upload, resource: *com.Resource, after: c.D3D12_RESOURCE_STATES) void {
        for (up.written[0..up.count]) |w| if (w.resource == resource) return;
        if (debug_checks) std.debug.assert(up.count < max_upload_writes);
        up.written[up.count] = .{ .resource = resource, .after = after };
        up.count += 1;
    }

    /// Everything written returns from COPY_DEST to its resting state, in one barrier call.
    pub fn finish(up: *Upload) Encoder {
        var barriers: [max_upload_writes]c.D3D12_RESOURCE_BARRIER = undefined;
        for (up.written[0..up.count], 0..) |w, i| barriers[i] = device_mod.transition(w.resource, c.D3D12_RESOURCE_STATE_COPY_DEST, w.after);
        if (up.count > 0) up.list.resourceBarrier(barriers[0..up.count]);
        return .{ .list = up.list };
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

pub const Encoder = struct {
    list: *com.GraphicsCommandList,

    /// Moves the attachments to RENDER_TARGET, sets them, clears them when asked, and sets
    /// the viewport and scissor to the whole target. `end` moves them back.
    pub fn beginRenderPass(e: Encoder, d: RenderPassDescriptor) RenderPass {
        var p: RenderPass = .{ .list = e.list, .width = 0, .height = 0, .owned = true };
        var rtvs: [max_color_targets]c.D3D12_CPU_DESCRIPTOR_HANDLE = undefined;
        var barriers: [max_color_targets]c.D3D12_RESOURCE_BARRIER = undefined;
        var nb: usize = 0;
        for (d.color_attachments, 0..) |a, i| {
            rtvs[i] = a.view.rtv;
            if (a.view.resting != c.D3D12_RESOURCE_STATE_RENDER_TARGET) {
                barriers[nb] = device_mod.transition(a.view.resource, a.view.resting, c.D3D12_RESOURCE_STATE_RENDER_TARGET);
                nb += 1;
            }
            p.attachments[i] = .{ .view = a.view, .resolve = a.resolve_target };
            p.width = a.view.width;
            p.height = a.view.height;
        }
        p.count = @intCast(d.color_attachments.len);
        if (nb > 0) e.list.resourceBarrier(barriers[0..nb]);
        const l = raw(c.ID3D12GraphicsCommandList, e.list);
        l.lpVtbl.*.OMSetRenderTargets.?(l, p.count, &rtvs, 0, null);
        for (d.color_attachments) |a| if (a.load_op == .clear) {
            const cv = a.clear_value;
            e.list.clearRenderTargetView(a.view.rtv, .{ @floatCast(cv.r), @floatCast(cv.g), @floatCast(cv.b), @floatCast(cv.a) });
        };
        p.setViewport(0, 0, @floatFromInt(p.width), @floatFromInt(p.height), 0, 1);
        p.setScissorRect(0, 0, p.width, p.height);
        return p;
    }

    pub fn beginComputePass(e: Encoder) ComputePass {
        return .{ .list = e.list };
    }
};

pub const RenderPass = struct {
    list: *com.GraphicsCommandList,
    width: u32,
    height: u32,
    owned: bool = false,
    attachments: [max_color_targets]struct { view: TextureView, resolve: ?TextureView } = undefined,
    count: u32 = 0,
    strides: [max_vertex_buffers]u32 = @splat(0),
    debug: if (debug_checks) struct { pipeline: bool = false } else void = if (debug_checks) .{} else {},

    /// The pass the host is recording (the UI's, for an inline custom draw).
    pub fn wrap(_: Device, list: *com.GraphicsCommandList, width: u32, height: u32) RenderPass {
        return .{ .list = list, .width = width, .height = height };
    }

    pub fn setPipeline(p: *RenderPass, pipeline: anytype) void {
        if (debug_checks) p.debug.pipeline = true;
        p.list.setGraphicsRootSignature(pipeline.root);
        p.list.setPipelineState(pipeline.pso);
        p.list.iaSetPrimitiveTopology(pipeline.topology);
        p.strides = pipeline.strides;
    }

    pub fn setBindGroup(p: *RenderPass, comptime index: u32, group: anytype) void {
        const G = Deref(@TypeOf(group));
        comptime checkIndex(G, index);
        const plan = comptime tablePlan(G.Shader.module, index);
        const param = comptime rootParam(G.Shader.module, index);
        p.list.setDescriptorHeaps(&group.heaps);
        if (plan.resources > 0) p.list.setGraphicsRootDescriptorTable(param, group.resources);
        if (plan.samplers > 0) p.list.setGraphicsRootDescriptorTable(param + @as(u32, @intFromBool(plan.resources > 0)), group.samplers);
    }

    pub fn setVertexBuffer(p: *RenderPass, slot: u32, buffer: Buffer, offset: u64) void {
        const l = raw(c.ID3D12GraphicsCommandList, p.list);
        const view: c.D3D12_VERTEX_BUFFER_VIEW = .{ .BufferLocation = buffer.address + offset, .SizeInBytes = @intCast(buffer.size - offset), .StrideInBytes = p.strides[slot] };
        l.lpVtbl.*.IASetVertexBuffers.?(l, slot, 1, &view);
    }

    pub fn setIndexBuffer(p: *RenderPass, buffer: Buffer, format: IndexFormat, offset: u64) void {
        const l = raw(c.ID3D12GraphicsCommandList, p.list);
        const view: c.D3D12_INDEX_BUFFER_VIEW = .{ .BufferLocation = buffer.address + offset, .SizeInBytes = @intCast(buffer.size - offset), .Format = if (format == .uint16) c.DXGI_FORMAT_R16_UINT else c.DXGI_FORMAT_R32_UINT };
        l.lpVtbl.*.IASetIndexBuffer.?(l, &view);
    }

    pub fn setViewport(p: *RenderPass, x: f32, y: f32, w: f32, h: f32, min_depth: f32, max_depth: f32) void {
        p.list.rsSetViewport(.{ .TopLeftX = x, .TopLeftY = y, .Width = w, .Height = h, .MinDepth = min_depth, .MaxDepth = max_depth });
    }

    pub fn setScissorRect(p: *RenderPass, x: u32, y: u32, w: u32, h: u32) void {
        if (debug_checks) std.debug.assert(x + w <= p.width and y + h <= p.height);
        p.list.rsSetScissorRect(.{ .left = @intCast(x), .top = @intCast(y), .right = @intCast(x + w), .bottom = @intCast(y + h) });
    }

    pub fn setBlendConstant(p: *RenderPass, color: Color) void {
        const l = raw(c.ID3D12GraphicsCommandList, p.list);
        const k: [4]f32 = .{ @floatCast(color.r), @floatCast(color.g), @floatCast(color.b), @floatCast(color.a) };
        l.lpVtbl.*.OMSetBlendFactor.?(l, &k);
    }

    pub fn draw(p: *RenderPass, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void {
        if (debug_checks) std.debug.assert(p.debug.pipeline);
        p.list.drawInstanced(vertex_count, instance_count, first_vertex, first_instance);
    }

    pub fn drawIndexed(p: *RenderPass, index_count: u32, instance_count: u32, first_index: u32, base_vertex: i32, first_instance: u32) void {
        if (debug_checks) std.debug.assert(p.debug.pipeline);
        const l = raw(c.ID3D12GraphicsCommandList, p.list);
        l.lpVtbl.*.DrawIndexedInstanced.?(l, index_count, instance_count, first_index, base_vertex, first_instance);
    }

    /// Resolves multisampled attachments and returns every attachment to its resting state.
    /// A wrapped pass is the host's.
    pub fn end(p: *RenderPass) void {
        if (!p.owned) return;
        const l = raw(c.ID3D12GraphicsCommandList, p.list);
        for (p.attachments[0..p.count]) |a| {
            if (a.resolve) |r| {
                p.list.resourceBarrier(&.{
                    device_mod.transition(a.view.resource, c.D3D12_RESOURCE_STATE_RENDER_TARGET, c.D3D12_RESOURCE_STATE_RESOLVE_SOURCE),
                    device_mod.transition(r.resource, r.resting, c.D3D12_RESOURCE_STATE_RESOLVE_DEST),
                });
                l.lpVtbl.*.ResolveSubresource.?(l, raw(c.ID3D12Resource, r.resource), 0, raw(c.ID3D12Resource, a.view.resource), 0, dxgiFormat(a.view.format) catch unreachable);
                p.list.resourceBarrier(&.{
                    device_mod.transition(a.view.resource, c.D3D12_RESOURCE_STATE_RESOLVE_SOURCE, c.D3D12_RESOURCE_STATE_RENDER_TARGET),
                    device_mod.transition(r.resource, c.D3D12_RESOURCE_STATE_RESOLVE_DEST, r.resting),
                });
            }
            if (a.view.resting != c.D3D12_RESOURCE_STATE_RENDER_TARGET)
                p.list.resourceBarrier(&.{device_mod.transition(a.view.resource, c.D3D12_RESOURCE_STATE_RENDER_TARGET, a.view.resting)});
        }
        p.owned = false;
    }
};

pub const ComputePass = struct {
    list: *com.GraphicsCommandList,

    pub fn setPipeline(p: *ComputePass, pipeline: anytype) void {
        const l = raw(c.ID3D12GraphicsCommandList, p.list);
        l.lpVtbl.*.SetComputeRootSignature.?(l, raw(c.ID3D12RootSignature, pipeline.root));
        p.list.setPipelineState(pipeline.pso);
    }

    pub fn setBindGroup(p: *ComputePass, comptime index: u32, group: anytype) void {
        const G = Deref(@TypeOf(group));
        comptime checkIndex(G, index);
        const plan = comptime tablePlan(G.Shader.module, index);
        const param = comptime rootParam(G.Shader.module, index);
        const l = raw(c.ID3D12GraphicsCommandList, p.list);
        p.list.setDescriptorHeaps(&group.heaps);
        if (plan.resources > 0) l.lpVtbl.*.SetComputeRootDescriptorTable.?(l, param, group.resources);
        if (plan.samplers > 0) l.lpVtbl.*.SetComputeRootDescriptorTable.?(l, param + @as(u32, @intFromBool(plan.resources > 0)), group.samplers);
    }

    pub fn dispatchWorkgroups(p: *ComputePass, x: u32, y: u32, z: u32) void {
        const l = raw(c.ID3D12GraphicsCommandList, p.list);
        l.lpVtbl.*.Dispatch.?(l, x, y, z);
    }

    /// One UAV barrier over every resource: the dispatches' writes before any later access.
    pub fn end(p: *ComputePass) void {
        var b: c.D3D12_RESOURCE_BARRIER = std.mem.zeroes(c.D3D12_RESOURCE_BARRIER);
        b.Type = c.D3D12_RESOURCE_BARRIER_TYPE_UAV;
        p.list.resourceBarrier(&.{b});
    }
};

fn Deref(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |ptr| ptr.child,
        else => T,
    };
}

fn checkIndex(comptime G: type, comptime index: u32) void {
    if (!@hasDecl(G, "index")) @compileError("setBindGroup takes a BindGroup made by createBindGroup");
    if (G.index != index) @compileError(std.fmt.comptimePrint("bind group made for @group({d}) set at index {d}", .{ G.index, index }));
}

// ---------------------------------------------------------------------------------------------
// Conversions

fn bufferDesc(size: u64) c.D3D12_RESOURCE_DESC {
    var rd: c.D3D12_RESOURCE_DESC = std.mem.zeroes(c.D3D12_RESOURCE_DESC);
    rd.Dimension = c.D3D12_RESOURCE_DIMENSION_BUFFER;
    rd.Width = size;
    rd.Height = 1;
    rd.DepthOrArraySize = 1;
    rd.MipLevels = 1;
    rd.Format = c.DXGI_FORMAT_UNKNOWN;
    rd.SampleDesc = .{ .Count = 1, .Quality = 0 };
    rd.Layout = c.D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    return rd;
}

pub fn dxgiFormat(f: TextureFormat) Error!c.DXGI_FORMAT {
    return switch (f) {
        .r8_unorm => c.DXGI_FORMAT_R8_UNORM,
        .rg8_unorm => c.DXGI_FORMAT_R8G8_UNORM,
        .rgba8_unorm => c.DXGI_FORMAT_R8G8B8A8_UNORM,
        .rgba8_unorm_srgb => c.DXGI_FORMAT_R8G8B8A8_UNORM_SRGB,
        .bgra8_unorm => c.DXGI_FORMAT_B8G8R8A8_UNORM,
        .bgra8_unorm_srgb => c.DXGI_FORMAT_B8G8R8A8_UNORM_SRGB,
        .r16_float => c.DXGI_FORMAT_R16_FLOAT,
        .rgba16_float => c.DXGI_FORMAT_R16G16B16A16_FLOAT,
        .r32_float => c.DXGI_FORMAT_R32_FLOAT,
        .rg32_float => c.DXGI_FORMAT_R32G32_FLOAT,
        .rgba32_float => c.DXGI_FORMAT_R32G32B32A32_FLOAT,
        .r32_uint => c.DXGI_FORMAT_R32_UINT,
        .depth32_float => c.DXGI_FORMAT_D32_FLOAT,
    };
}

fn vertexFormat(f: VertexFormat) c.DXGI_FORMAT {
    return switch (f) {
        .float32 => c.DXGI_FORMAT_R32_FLOAT,
        .float32x2 => c.DXGI_FORMAT_R32G32_FLOAT,
        .float32x3 => c.DXGI_FORMAT_R32G32B32_FLOAT,
        .float32x4 => c.DXGI_FORMAT_R32G32B32A32_FLOAT,
        .uint32 => c.DXGI_FORMAT_R32_UINT,
        .uint32x2 => c.DXGI_FORMAT_R32G32_UINT,
        .uint32x4 => c.DXGI_FORMAT_R32G32B32A32_UINT,
        .sint32 => c.DXGI_FORMAT_R32_SINT,
        .sint32x2 => c.DXGI_FORMAT_R32G32_SINT,
        .sint32x4 => c.DXGI_FORMAT_R32G32B32A32_SINT,
        .unorm8x4 => c.DXGI_FORMAT_R8G8B8A8_UNORM,
    };
}

fn topology(t: PrimitiveTopology) c.D3D12_PRIMITIVE_TOPOLOGY {
    return switch (t) {
        .point_list => c.D3D_PRIMITIVE_TOPOLOGY_POINTLIST,
        .line_list => c.D3D_PRIMITIVE_TOPOLOGY_LINELIST,
        .line_strip => c.D3D_PRIMITIVE_TOPOLOGY_LINESTRIP,
        .triangle_list => c.D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST,
        .triangle_strip => c.D3D_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP,
    };
}

fn addressMode(a: desc.AddressMode) c.D3D12_TEXTURE_ADDRESS_MODE {
    return switch (a) {
        .clamp_to_edge => c.D3D12_TEXTURE_ADDRESS_MODE_CLAMP,
        .repeat => c.D3D12_TEXTURE_ADDRESS_MODE_WRAP,
        .mirror_repeat => c.D3D12_TEXTURE_ADDRESS_MODE_MIRROR,
    };
}

fn compareFunc(f: desc.CompareFunction) c.D3D12_COMPARISON_FUNC {
    // D3D12_COMPARISON_FUNC_NEVER .. ALWAYS are 1 .. 8 in WebGPU's order.
    return @intCast(1 + @backingInt(f));
}

fn blendFactor(f: desc.BlendFactor) c.D3D12_BLEND {
    return switch (f) {
        .zero => c.D3D12_BLEND_ZERO,
        .one => c.D3D12_BLEND_ONE,
        .src => c.D3D12_BLEND_SRC_COLOR,
        .one_minus_src => c.D3D12_BLEND_INV_SRC_COLOR,
        .src_alpha => c.D3D12_BLEND_SRC_ALPHA,
        .one_minus_src_alpha => c.D3D12_BLEND_INV_SRC_ALPHA,
        .dst => c.D3D12_BLEND_DEST_COLOR,
        .one_minus_dst => c.D3D12_BLEND_INV_DEST_COLOR,
        .dst_alpha => c.D3D12_BLEND_DEST_ALPHA,
        .one_minus_dst_alpha => c.D3D12_BLEND_INV_DEST_ALPHA,
        .constant => c.D3D12_BLEND_BLEND_FACTOR,
        .one_minus_constant => c.D3D12_BLEND_INV_BLEND_FACTOR,
    };
}

fn blendOp(o: desc.BlendOperation) c.D3D12_BLEND_OP {
    return switch (o) {
        .add => c.D3D12_BLEND_OP_ADD,
        .subtract => c.D3D12_BLEND_OP_SUBTRACT,
        .reverse_subtract => c.D3D12_BLEND_OP_REV_SUBTRACT,
        .min => c.D3D12_BLEND_OP_MIN,
        .max => c.D3D12_BLEND_OP_MAX,
    };
}

fn blendDesc(t: ColorTargetState) c.D3D12_RENDER_TARGET_BLEND_DESC {
    const m = t.write_mask;
    const mask: u8 = @as(u8, @intFromBool(m.red)) | (@as(u8, @intFromBool(m.green)) << 1) | (@as(u8, @intFromBool(m.blue)) << 2) | (@as(u8, @intFromBool(m.alpha)) << 3);
    var b: c.D3D12_RENDER_TARGET_BLEND_DESC = pipeline_mod.premultiplied;
    b.RenderTargetWriteMask = mask;
    const s = t.blend orelse {
        b.BlendEnable = 0;
        return b;
    };
    b.BlendEnable = 1;
    b.SrcBlend = blendFactor(s.color.src_factor);
    b.DestBlend = blendFactor(s.color.dst_factor);
    b.BlendOp = blendOp(s.color.operation);
    b.SrcBlendAlpha = blendFactor(s.alpha.src_factor);
    b.DestBlendAlpha = blendFactor(s.alpha.dst_factor);
    b.BlendOpAlpha = blendOp(s.alpha.operation);
    return b;
}

const testing = std.testing;
const shaders = @import("gpu_shaders");

test "gpu: naga's sampler heap becomes registered samplers, at compile time" {
    const S = Shader(shaders.textured);
    try testing.expect(std.mem.indexOf(u8, S.hlsl, "nagaSamplerHeap") == null);
    try testing.expect(std.mem.indexOf(u8, S.hlsl, "SamplerIndexArray") == null);
    try testing.expect(std.mem.indexOf(u8, S.hlsl, "SamplerState smp : register(s2, space0);") != null);
}

test "gpu: root parameters follow the groups and their sampler tables" {
    const m = comptime reflect.parse(
        \\@group(0) @binding(0) var<uniform> a: vec4f;
        \\@group(0) @binding(1) var s: sampler;
        \\@group(1) @binding(0) var t: texture_2d<f32>;
    );
    try testing.expectEqual(0, comptime rootParam(m, 0));
    try testing.expectEqual(2, comptime rootParam(m, 1));
    try testing.expectEqual(Plan{ .resources = 1, .samplers = 1 }, comptime tablePlan(m, 0));
}

const host = @import("host.zig");

/// The host side of lcgf.gpu_check on Direct3D 12: one-shot command lists, readback through a
/// READBACK-heap copy.
const Check = struct {
    d: *device_mod.Device,
    once: *host.Once,

    pub fn upload(k: *Check, staging: *Staging) !Upload {
        staging.rewind();
        return .beginStaged(.wrap(k.d), try k.once.begin(), staging);
    }
    pub fn submit(k: *Check) !void {
        try k.once.submit(k.d);
    }
    pub fn readTexture(k: *Check, t: Texture, out: []u8) !void {
        var rb = try host.Readback.init(k.d, t.width, t.height);
        defer rb.deinit();
        const l = try k.once.begin();
        l.resourceBarrier(&.{device_mod.transition(t.resource, t.resting, c.D3D12_RESOURCE_STATE_COPY_SOURCE)});
        rb.copy(l, t.resource);
        l.resourceBarrier(&.{device_mod.transition(t.resource, c.D3D12_RESOURCE_STATE_COPY_SOURCE, t.resting)});
        try k.once.submit(k.d);
        try rb.read(out);
    }
    pub fn readBuffer(k: *Check, b: Buffer, out: []u8) !void {
        const back = try k.d.createBuffer(out.len, c.D3D12_HEAP_TYPE_READBACK);
        defer com.release(back);
        const l = try k.once.begin();
        const rl = raw(c.ID3D12GraphicsCommandList, l);
        rl.lpVtbl.*.CopyBufferRegion.?(rl, raw(c.ID3D12Resource, back), 0, raw(c.ID3D12Resource, b.resource), 0, out.len);
        try k.once.submit(k.d);
        const p = try back.map(true);
        defer back.unmap();
        @memcpy(out, p[0..out.len]);
    }
};

test "gpu: upload, render to a texture, sample it in a second pass (WARP, or vkd3d under Wine)" {
    var d = try device_mod.Device.init(.{ .adapter = .warp });
    defer d.deinit();
    var once = try host.Once.init(&d);
    defer once.deinit();
    var k: Check = .{ .d = &d, .once = &once };
    try lcgf.gpu_check.renderToTexture(@This(), shaders, .wrap(&d), &k);
}

test "gpu: instanced draws from a first instance, integer attributes, an offset buffer (WARP, or vkd3d under Wine)" {
    var d = try device_mod.Device.init(.{ .adapter = .warp });
    defer d.deinit();
    var once = try host.Once.init(&d);
    defer once.deinit();
    var k: Check = .{ .d = &d, .once = &once };
    try lcgf.gpu_check.instancing(@This(), shaders, .wrap(&d), &k);
}

test "gpu: a compute pass writes a storage buffer the host reads (WARP, or vkd3d under Wine)" {
    var d = try device_mod.Device.init(.{ .adapter = .warp });
    defer d.deinit();
    var once = try host.Once.init(&d);
    defer once.deinit();
    var k: Check = .{ .d = &d, .once = &once };
    try lcgf.gpu_check.compute(@This(), shaders, .wrap(&d), &k);
}
