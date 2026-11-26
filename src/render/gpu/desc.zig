//! The descriptors of `lcgf_render.gpu`: WebGPU's object model as plain Zig data, shared by every
//! back end's projection (src/render/<back end>/gpu.zig). Names follow webgpu.h and the WebGPU
//! spec in Zig style: `GPUBufferUsage.UNIFORM` is `.{ .uniform = true }`, `GPUTextureFormat
//! "rgba8unorm"` is `.rgba8_unorm`, `vertexCount` is `vertex_count`.
//!
//! Nothing here touches a GPU API, an allocator or the OS. A projection converts a descriptor to
//! its native create-info; when the descriptor is comptime-known the conversion is folded, so the
//! create call takes a constant.
//!
//! Deliberate differences from WebGPU, each because the projection keeps no state for you:
//!   - Resources come from a caller-owned `Arena` (one native memory block), not the device.
//!   - Writes (`writeBuffer`, `writeTexture`) belong to the frame's `Upload` phase, not the queue.
//!   - A bind group is typed by the shader that declares it (`Shader.Group(n)`), so a missing or
//!     mistyped binding is a compile error instead of a validation message.

const std = @import("std");

pub const BufferUsage = bitpack struct(u32) {
    map_read: bool = false,
    map_write: bool = false,
    copy_src: bool = false,
    copy_dst: bool = false,
    index: bool = false,
    vertex: bool = false,
    uniform: bool = false,
    storage: bool = false,
    indirect: bool = false,
    _: u23 = 0,
};

pub const BufferDescriptor = struct {
    label: ?[]const u8 = null,
    size: u64,
    usage: BufferUsage,
};

pub const TextureUsage = bitpack struct(u32) {
    copy_src: bool = false,
    copy_dst: bool = false,
    texture_binding: bool = false,
    storage_binding: bool = false,
    render_attachment: bool = false,
    _: u27 = 0,
};

/// The formats every back end maps. A projection rejects one its API lacks at compile time
/// when the descriptor is comptime-known, and with `error.UnsupportedFormat` otherwise.
pub const TextureFormat = enum {
    r8_unorm,
    rg8_unorm,
    rgba8_unorm,
    rgba8_unorm_srgb,
    bgra8_unorm,
    bgra8_unorm_srgb,
    r16_float,
    rgba16_float,
    r32_float,
    rg32_float,
    rgba32_float,
    r32_uint,
    depth32_float,

    pub fn bytesPerPixel(f: TextureFormat) u32 {
        return switch (f) {
            .r8_unorm => 1,
            .rg8_unorm, .r16_float => 2,
            .rgba8_unorm, .rgba8_unorm_srgb, .bgra8_unorm, .bgra8_unorm_srgb, .r32_float, .r32_uint, .depth32_float => 4,
            .rgba16_float, .rg32_float => 8,
            .rgba32_float => 16,
        };
    }
};

pub const TextureDimension = enum { @"1d", @"2d", @"3d" };
pub const TextureViewDimension = enum { @"1d", @"2d", @"2d_array", cube, cube_array, @"3d" };

pub const Extent3D = struct { width: u32, height: u32 = 1, depth_or_array_layers: u32 = 1 };
pub const Origin3D = struct { x: u32 = 0, y: u32 = 0, z: u32 = 0 };

pub const TextureDescriptor = struct {
    label: ?[]const u8 = null,
    size: Extent3D,
    format: TextureFormat,
    usage: TextureUsage,
    dimension: TextureDimension = .@"2d",
    mip_level_count: u32 = 1,
    sample_count: u32 = 1,
};

pub const AddressMode = enum { clamp_to_edge, repeat, mirror_repeat };
pub const FilterMode = enum { nearest, linear };
pub const MipmapFilterMode = enum { nearest, linear };
pub const CompareFunction = enum { never, less, equal, less_equal, greater, not_equal, greater_equal, always };

pub const SamplerDescriptor = struct {
    label: ?[]const u8 = null,
    address_mode_u: AddressMode = .clamp_to_edge,
    address_mode_v: AddressMode = .clamp_to_edge,
    address_mode_w: AddressMode = .clamp_to_edge,
    mag_filter: FilterMode = .nearest,
    min_filter: FilterMode = .nearest,
    mipmap_filter: MipmapFilterMode = .nearest,
    lod_min_clamp: f32 = 0,
    lod_max_clamp: f32 = 32,
    compare: ?CompareFunction = null,
};

pub const VertexFormat = enum {
    float32,
    float32x2,
    float32x3,
    float32x4,
    uint32,
    uint32x2,
    uint32x4,
    sint32,
    unorm8x4,

    pub fn size(f: VertexFormat) u32 {
        return switch (f) {
            .float32, .uint32, .sint32, .unorm8x4 => 4,
            .float32x2, .uint32x2 => 8,
            .float32x3 => 12,
            .float32x4, .uint32x4 => 16,
        };
    }
};

pub const VertexStepMode = enum { vertex, instance };
pub const VertexAttribute = struct { format: VertexFormat, offset: u64, shader_location: u32 };
pub const VertexBufferLayout = struct {
    array_stride: u64,
    step_mode: VertexStepMode = .vertex,
    attributes: []const VertexAttribute,
};

pub const PrimitiveTopology = enum { point_list, line_list, line_strip, triangle_list, triangle_strip };
pub const FrontFace = enum { ccw, cw };
pub const CullMode = enum { none, front, back };
pub const IndexFormat = enum { uint16, uint32 };

pub const PrimitiveState = struct {
    topology: PrimitiveTopology = .triangle_list,
    strip_index_format: ?IndexFormat = null,
    front_face: FrontFace = .ccw,
    cull_mode: CullMode = .none,
};

pub const BlendFactor = enum { zero, one, src, one_minus_src, src_alpha, one_minus_src_alpha, dst, one_minus_dst, dst_alpha, one_minus_dst_alpha, constant, one_minus_constant };
pub const BlendOperation = enum { add, subtract, reverse_subtract, min, max };
pub const BlendComponent = struct {
    operation: BlendOperation = .add,
    src_factor: BlendFactor = .one,
    dst_factor: BlendFactor = .zero,
};
pub const BlendState = struct {
    color: BlendComponent,
    alpha: BlendComponent,

    /// What the UI draws with: premultiplied colour over what is there.
    pub const premultiplied: BlendState = .{
        .color = .{ .src_factor = .one, .dst_factor = .one_minus_src_alpha },
        .alpha = .{ .src_factor = .one, .dst_factor = .one_minus_src_alpha },
    };
    /// Straight alpha.
    pub const alpha_blending: BlendState = .{
        .color = .{ .src_factor = .src_alpha, .dst_factor = .one_minus_src_alpha },
        .alpha = .{ .src_factor = .one, .dst_factor = .one_minus_src_alpha },
    };
};

pub const ColorWriteMask = bitpack struct(u4) {
    red: bool = true,
    green: bool = true,
    blue: bool = true,
    alpha: bool = true,
    pub const all: ColorWriteMask = .{};
};

pub const ColorTargetState = struct {
    format: TextureFormat,
    /// Null replaces what is there (no blending).
    blend: ?BlendState = null,
    write_mask: ColorWriteMask = .all,
};

pub const MultisampleState = struct { count: u32 = 1, mask: u32 = 0xffff_ffff, alpha_to_coverage_enabled: bool = false };

pub const VertexState = struct {
    entry_point: [:0]const u8 = "vs",
    buffers: []const VertexBufferLayout = &.{},
};

pub const FragmentState = struct {
    entry_point: [:0]const u8 = "fs",
    targets: []const ColorTargetState,
};

pub const RenderPipelineDescriptor = struct {
    label: ?[]const u8 = null,
    vertex: VertexState = .{},
    primitive: PrimitiveState = .{},
    multisample: MultisampleState = .{},
    fragment: ?FragmentState = null,
};

pub const ComputePipelineDescriptor = struct {
    label: ?[]const u8 = null,
    entry_point: [:0]const u8 = "main",
};

pub const LoadOp = enum { load, clear };
pub const StoreOp = enum { store, discard };
pub const Color = struct { r: f64 = 0, g: f64 = 0, b: f64 = 0, a: f64 = 0 };

/// Where a frame's pixels go, as the host made it: the projection reads the format and sample
/// count from here so a pipeline matches the pass it draws in.
pub const Target = struct { format: TextureFormat, samples: u32 = 1, width: u32 = 0, height: u32 = 0 };

/// A rectangle in framebuffer pixels, rows from the top (WebGPU's scissor convention).
pub const Rect = struct { x: u32, y: u32, width: u32, height: u32 };

/// The scissor of a custom command (`DrawList.customs[k]`): its rect cut by its clip, scaled to
/// pixels and kept inside a `width` × `height` target. The same arithmetic every back end's
/// `customScissor` uses, so a custom draw clips identically everywhere.
pub fn scissor(rect: [4]f32, clip: [4]f32, scale: f32, width: u32, height: u32) Rect {
    const w: f32 = @floatFromInt(width);
    const h: f32 = @floatFromInt(height);
    const x0 = std.math.clamp(@floor(@max(rect[0], clip[0]) * scale), 0, w);
    const y0 = std.math.clamp(@floor(@max(rect[1], clip[1]) * scale), 0, h);
    const x1 = std.math.clamp(@ceil(@min(rect[2], clip[2]) * scale), x0, w);
    const y1 = std.math.clamp(@ceil(@min(rect[3], clip[3]) * scale), y0, h);
    return .{ .x = @intFromFloat(x0), .y = @intFromFloat(y0), .width = @intFromFloat(x1 - x0), .height = @intFromFloat(y1 - y0) };
}

const testing = std.testing;

test "desc: the custom scissor matches the Vulkan back end's arithmetic" {
    const open: [4]f32 = .{ -1e6, -1e6, 1e6, 1e6 };
    try testing.expectEqual(Rect{ .x = 16, .y = 16, .width = 288, .height = 208 }, scissor(.{ 8, 8, 152, 112 }, open, 2, 320, 240));
    try testing.expectEqual(Rect{ .x = 0, .y = 200, .width = 301, .height = 40 }, scissor(.{ -10, 100.25, 400, 300 }, .{ 0, 0, 150.2, 1e6 }, 2, 320, 240));
    try testing.expectEqual(@as(u32, 0), scissor(.{ 50, 50, 60, 60 }, .{ 70, 70, 80, 80 }, 1, 320, 240).width);
}

test "desc: usage flags pack like webgpu.h's bits" {
    try testing.expectEqual(@as(u32, 0x40), @as(u32, @bitCast(BufferUsage{ .uniform = true })));
    try testing.expectEqual(@as(u32, 0x08 | 0x20), @as(u32, @bitCast(BufferUsage{ .copy_dst = true, .vertex = true })));
    try testing.expectEqual(@as(u32, 0x10), @as(u32, @bitCast(TextureUsage{ .render_attachment = true })));
}
