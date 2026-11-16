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
