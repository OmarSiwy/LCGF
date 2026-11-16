//! Metal's enumerations and structs, by hand from the Metal headers (MTLPixelFormat.h,
//! MTLVertexDescriptor.h, MTLRenderPipeline.h, ...): only the values this back end uses.

const std = @import("std");
const objc = @import("objc.zig");
const U = objc.NSUInteger;

pub const PixelFormat = enum(U) {
    rgba8_unorm = 70,
    bgra8_unorm = 80,
    _,
};

/// MTLVertexFormat.
pub const VertexFormat = enum(U) {
    uchar4_normalized = 9,
    float = 28,
    float2 = 29,
    float4 = 31,
    uint4 = 39,
};

/// The Metal format of a WebGPU vertex format name, as quad_shader.attrs spells them.
pub fn vertexFormat(comptime wgpu_name: []const u8) VertexFormat {
    const names = .{ .{ "float32", .float }, .{ "float32x2", .float2 }, .{ "float32x4", .float4 }, .{ "uint32x4", .uint4 }, .{ "unorm8x4", .uchar4_normalized } };
    inline for (names) |n| if (comptime std.mem.eql(u8, n[0], wgpu_name)) return n[1];
    @compileError("mtl.vertexFormat: no Metal format for " ++ wgpu_name);
}

pub const VertexStepFunction = enum(U) { constant = 0, per_vertex = 1, per_instance = 2 };
pub const BlendFactor = enum(U) { zero = 0, one = 1, one_minus_source_alpha = 5 };
pub const PrimitiveType = enum(U) { triangle = 3, triangle_strip = 4 };
pub const CullMode = enum(U) { none = 0, front = 1, back = 2 };
pub const TriangleFillMode = enum(U) { fill = 0, lines = 1 };
/// MTLResourceOptions: shared storage (CPU-visible, the default) with write-combined CPU cache,
/// for buffers the CPU only writes.
pub const resource_shared_write_combined: U = 1;

pub const Viewport = extern struct { x: f64, y: f64, width: f64, height: f64, znear: f64 = 0, zfar: f64 = 1 };
pub const ScissorRect = extern struct { x: U, y: U, width: U, height: U };

/// An MTLRenderCommandEncoder: the `Pass` the renderer records into. These are the only
/// encoder calls the renderer makes; a host keeps `id` for its own.
pub const RenderEncoder = struct {
    id: objc.Id,

    pub fn setPipeline(e: RenderEncoder, p: objc.Id) void {
        objc.msg(void, e.id, "setRenderPipelineState:", .{p});
    }
    pub fn setVertexBuffer(e: RenderEncoder, buffer: objc.Id, offset: U, index: U) void {
        objc.msg(void, e.id, "setVertexBuffer:offset:atIndex:", .{ buffer, offset, index });
    }
    /// Small constant data (under 4 KB) copied into the command stream: no buffer to manage.
    pub fn setVertexBytes(e: RenderEncoder, bytes: []const u8, index: U) void {
        objc.msg(void, e.id, "setVertexBytes:length:atIndex:", .{ bytes.ptr, @as(U, bytes.len), index });
    }
    pub fn setFragmentBytes(e: RenderEncoder, bytes: []const u8, index: U) void {
        objc.msg(void, e.id, "setFragmentBytes:length:atIndex:", .{ bytes.ptr, @as(U, bytes.len), index });
    }
    pub fn setFragmentTexture(e: RenderEncoder, texture: objc.Id, index: U) void {
        objc.msg(void, e.id, "setFragmentTexture:atIndex:", .{ texture, index });
    }
    pub fn setFragmentSampler(e: RenderEncoder, sampler: objc.Id, index: U) void {
        objc.msg(void, e.id, "setFragmentSamplerState:atIndex:", .{ sampler, index });
    }
    pub fn setViewport(e: RenderEncoder, v: Viewport) void {
        objc.msg(void, e.id, "setViewport:", .{v});
    }
    pub fn setScissor(e: RenderEncoder, s: ScissorRect) void {
        objc.msg(void, e.id, "setScissorRect:", .{s});
    }
    pub fn setRaster(e: RenderEncoder) void {
        objc.msg(void, e.id, "setCullMode:", .{CullMode.none});
        objc.msg(void, e.id, "setTriangleFillMode:", .{TriangleFillMode.fill});
    }
    /// `instances` quads: a four-vertex strip each.
    pub fn drawQuads(e: RenderEncoder, instances: U) void {
        objc.msg(void, e.id, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{ PrimitiveType.triangle_strip, @as(U, 0), @as(U, 4), instances });
    }
};

pub const SamplerFilter = enum(U) { nearest = 0, linear = 1 };
pub const SamplerAddressMode = enum(U) { clamp_to_edge = 0 };
/// MTLTextureUsage bits.
pub const texture_usage_shader_read: U = 1;
pub const texture_usage_render_target: U = 4;
pub const Origin = extern struct { x: U = 0, y: U = 0, z: U = 0 };
pub const Size = extern struct { width: U, height: U, depth: U = 1 };
pub const Region = extern struct { origin: Origin = .{}, size: Size };
