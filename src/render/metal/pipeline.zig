//! Quad pipelines from MSL: the library compiled from source at run time (as GPUI compiles its
//! shaders.metal), the instance layout of `draw_list.Quad` as a vertex descriptor, and
//! premultiplied blending, the same state as prototype/ui_wgpu.zig `createPipeline`.

const std = @import("std");
const lcgr = @import("lcgr");
const objc = @import("objc.zig");
const mtl = @import("mtl.zig");
const msl = @import("msl.zig");
const quad_shader = lcgr.quad_shader;
const Id = objc.Id;
const msg = objc.msg;
const U = objc.NSUInteger;

pub const Error = error{ ShaderCompile, MissingEntryPoint, PipelineFailed };

pub const Desc = struct {
    /// Format of the targets the pipeline draws into (the layer's, or an offscreen texture's).
    format: mtl.PixelFormat,
    sample_count: U = 1,
};

/// A render pipeline state for one quad material: `source` is a quad.wgsl variant in MSL with
/// its slots bound (`msl.bind`), entry points `vs` and `fs`. Caller releases it.
pub fn quad(device: Id, source: [:0]const u8, desc: Desc) Error!Id {
    const pool = objc.Pool.push();
    defer pool.pop();
    var err: ?Id = null;
    const library = msg(?Id, device, "newLibraryWithSource:options:error:", .{ objc.string(source), @as(?Id, null), &err }) orelse {
        logError("compiling MSL", err);
        return error.ShaderCompile;
    };
    defer objc.release(library);
    const vs = msg(?Id, library, "newFunctionWithName:", .{objc.string("vs")}) orelse return error.MissingEntryPoint;
    defer objc.release(vs);
    const fs = msg(?Id, library, "newFunctionWithName:", .{objc.string("fs")}) orelse return error.MissingEntryPoint;
    defer objc.release(fs);

    const pd = msg(Id, objc.class("MTLRenderPipelineDescriptor"), "new", .{});
    defer objc.release(pd);
    msg(void, pd, "setVertexFunction:", .{vs});
    msg(void, pd, "setFragmentFunction:", .{fs});
    msg(void, pd, "setVertexDescriptor:", .{instanceLayout()});
    msg(void, pd, "setRasterSampleCount:", .{desc.sample_count});
    const color = msg(Id, msg(Id, pd, "colorAttachments", .{}), "objectAtIndexedSubscript:", .{@as(U, 0)});
    msg(void, color, "setPixelFormat:", .{desc.format});
    // Premultiplied over: one, one minus source alpha, for colour and alpha.
    msg(void, color, "setBlendingEnabled:", .{@as(objc.BOOL, true)});
    msg(void, color, "setSourceRGBBlendFactor:", .{mtl.BlendFactor.one});
    msg(void, color, "setSourceAlphaBlendFactor:", .{mtl.BlendFactor.one});
    msg(void, color, "setDestinationRGBBlendFactor:", .{mtl.BlendFactor.one_minus_source_alpha});
    msg(void, color, "setDestinationAlphaBlendFactor:", .{mtl.BlendFactor.one_minus_source_alpha});
    return msg(?Id, device, "newRenderPipelineStateWithDescriptor:error:", .{ pd, &err }) orelse {
        logError("creating the quad pipeline", err);
        return error.PipelineFailed;
    };
}

/// One instance per `Quad` from buffer `msl.instance_buffer`, attributes as quad_shader.attrs.
/// Autoreleased.
fn instanceLayout() Id {
    const vd = msg(Id, objc.class("MTLVertexDescriptor"), "vertexDescriptor", .{});
    const attributes = msg(Id, vd, "attributes", .{});
    inline for (quad_shader.attrs) |a| {
        const at = msg(Id, attributes, "objectAtIndexedSubscript:", .{@as(U, a.location)});
        msg(void, at, "setFormat:", .{comptime mtl.vertexFormat(a.format)});
        msg(void, at, "setOffset:", .{@as(U, a.offset)});
        msg(void, at, "setBufferIndex:", .{@as(U, msl.instance_buffer)});
    }
    const layout = msg(Id, msg(Id, vd, "layouts", .{}), "objectAtIndexedSubscript:", .{@as(U, msl.instance_buffer)});
    msg(void, layout, "setStride:", .{@as(U, quad_shader.stride)});
    msg(void, layout, "setStepFunction:", .{mtl.VertexStepFunction.per_instance});
    msg(void, layout, "setStepRate:", .{@as(U, 1)});
    return vd;
}

fn logError(what: []const u8, err: ?Id) void {
    const text: [*:0]const u8 = if (err) |e| msg([*:0]const u8, msg(Id, e, "localizedDescription", .{}), "UTF8String", .{}) else "no error object";
    std.log.err("metal: {s}: {s}", .{ what, text });
}

const testing = std.testing;

test "pipeline: every quad attribute has a Metal vertex format" {
    inline for (quad_shader.attrs) |a| _ = comptime mtl.vertexFormat(a.format);
    try testing.expectEqual(mtl.VertexFormat.uchar4_normalized, comptime mtl.vertexFormat("unorm8x4"));
}
