//! A host's own Direct3D 12 drawing for inline custom draws, as an application would write it:
//! the goldens' host draw (src/render/conformance/render.py `scene_pipe`), a gradient over the
//! target, scissored to the custom rect. Its own root signature (two root constants), pipeline,
//! topology, scissor and no blending, recorded straight into the command list the renderer
//! draws into (`Renderer.Pass` is the raw ID3D12GraphicsCommandList: no wrapper, no callback).
//! Afterwards the list holds nothing the UI set; the conformance scene `custom` checks that the
//! renderer rebinds everything (iface.zig, "Full state rebinding").
//!
//!     var i = iface.drawUntilCustom(&gfx, list, draw, 0);
//!     while (i < draw.cmd_len) : (i = iface.drawUntilCustom(&gfx, list, draw, i + 1))
//!         gradient.draw(list, gfx.customScissor(draw.customs[draw.command(i).custom]), gfx.extent);

const std = @import("std");
const com = @import("com.zig");
const pipeline = @import("pipeline.zig");
const c = com.c;
const Error = com.Error;

const hlsl =
    \\cbuffer size : register(b0) { float2 size; };
    \\float4 vs(uint i : SV_VertexID) : SV_Position {
    \\    return float4(float(i & 1u) * 4.0 - 1.0, float(i >> 1u) * 4.0 - 1.0, 0.0, 1.0);
    \\}
    \\float4 fs(float4 p : SV_Position) : SV_Target0 {
    \\    return float4(p.x / size.x * 0.5, 0.25, p.y / size.y * 0.6, 1.0);
    \\}
;

pub const Gradient = struct {
    root: *com.RootSignature,
    pso: *com.PipelineState,

    pub fn init(d: *com.Device, format: c.DXGI_FORMAT) Error!Gradient {
        var param: c.D3D12_ROOT_PARAMETER = std.mem.zeroes(c.D3D12_ROOT_PARAMETER);
        param.ParameterType = c.D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;
        param.unnamed_0.Constants = .{ .ShaderRegister = 0, .RegisterSpace = 0, .Num32BitValues = 2 };
        param.ShaderVisibility = c.D3D12_SHADER_VISIBILITY_PIXEL;
        const root = try pipeline.serialiseRoot(d, &.{ .NumParameters = 1, .pParameters = &param, .NumStaticSamplers = 0, .pStaticSamplers = null, .Flags = c.D3D12_ROOT_SIGNATURE_FLAG_NONE });
        errdefer com.release(root);
        const vs = try pipeline.compile(hlsl, "vs", "vs_5_1");
        defer com.release(vs);
        const ps = try pipeline.compile(hlsl, "fs", "ps_5_1");
        defer com.release(ps);
        var opaque_target = pipeline.premultiplied;
        opaque_target.BlendEnable = 0;
        const pso = try pipeline.create(d, root, format, .{ .vs = vs.bytes(), .ps = ps.bytes(), .layout = &.{}, .blend = opaque_target });
        return .{ .root = root, .pso = pso };
    }

    pub fn deinit(g: *Gradient) void {
        com.release(g.pso);
        com.release(g.root);
    }

    /// Draws the gradient inside `scissor` over a target of `extent` pixels, into the list the
    /// UI is drawing into. Leaves its own root signature, pipeline and scissor set.
    pub fn draw(g: *const Gradient, l: *com.GraphicsCommandList, scissor: c.D3D12_RECT, extent: [2]u32) void {
        if (scissor.right <= scissor.left or scissor.bottom <= scissor.top) return;
        const size = [2]f32{ @floatFromInt(extent[0]), @floatFromInt(extent[1]) };
        l.setGraphicsRootSignature(g.root);
        l.setPipelineState(g.pso);
        l.setGraphicsRoot32BitConstants(0, @ptrCast(&size), 0);
        l.iaSetPrimitiveTopology(c.D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        l.rsSetViewport(.{ .TopLeftX = 0, .TopLeftY = 0, .Width = size[0], .Height = size[1], .MinDepth = 0, .MaxDepth = 1 });
        l.rsSetScissorRect(scissor);
        l.drawInstanced(3, 1, 0, 0);
    }
};
