//! The quad pipeline from HLSL: the committed naga translation of quad.wgsl
//! (src/render/shaders/gen/stock.hlsl), compiled at run time by d3dcompiler_47 (shader model
//! 5.1, which register spaces need), one root signature every material shares, and one
//! pipeline state per material.
//!
//! Root signature, matching the WGSL bind groups as naga numbers them:
//!   0  root CBV      b0 space0  the globals (viewport, scale), a GPU address in the ring
//!   1  table, 1 SRV  t0 space1  `tex`, from the shader-visible heap (renderer.zig)
//!   static sampler   s0 space1  `samp`: nearest, clamped
//! naga emits group 1's sampler through a 2048-entry sampler heap and an index buffer (its
//! bindless model); `naga` below swaps that for the one static sampler, so a material needs no
//! sampler heap. The conformance goldens and every back end sample nearest.

const std = @import("std");
const lcgf = @import("lcgf");
const com = @import("com.zig");
const c = com.c;
const Error = com.Error;
const quad_shader = lcgf.quad_shader;

pub const root_globals = 0;
pub const root_texture = 1;

/// naga's HLSL for a quad shader variant, its sampler heap replaced by `samp` at s0 space1.
/// Compile error when the text does not have naga's sampler block, so a naga upgrade that
/// changes it fails the build instead of the pipeline.
pub fn naga(comptime hlsl: []const u8) [:0]const u8 {
    comptime {
        const first = "SamplerState nagaSamplerHeap[2048]";
        const last = "static const SamplerState samp = nagaSamplerHeap[nagaGroup1SamplerIndexArray[1]];";
        const a = std.mem.indexOf(u8, hlsl, first) orelse @compileError("no naga sampler heap in the HLSL");
        const b = (std.mem.findPos(u8, hlsl, a + first.len, last) orelse @compileError("no naga sampler index in the HLSL")) + last.len;
        return hlsl[0..a] ++ "SamplerState samp : register(s0, space1);" ++ hlsl[b..] ++ "\x00";
    }
}

pub const stock_hlsl = naga(@embedFile("stock_hlsl"));
pub const example_hlsl = naga(@embedFile("example_hlsl"));

/// HLSL to bytecode with d3dcompiler_47 (`target` "vs_5_1", "ps_5_1"). The compiler's message
/// goes to the log on failure.
pub fn compile(hlsl: []const u8, entry: [:0]const u8, target: [:0]const u8) Error!*com.Blob {
    var code: ?*com.Blob = null;
    var errors: ?*com.Blob = null;
    defer com.release(errors);
    const result = c.D3DCompile(hlsl.ptr, hlsl.len, "quad.hlsl", null, null, entry, target, c.D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, @ptrCast(&code), @ptrCast(&errors));
    if (result < 0) {
        if (errors) |e| std.log.warn("d3d12: {s}", .{e.bytes()});
        com.release(code);
        return error.ShaderCompile;
    }
    return code.?;
}

/// The root signature above, serialised (version 1.0) and created.
pub fn rootSignature(d: *com.Device) Error!*com.RootSignature {
    const srv: c.D3D12_DESCRIPTOR_RANGE = .{
        .RangeType = c.D3D12_DESCRIPTOR_RANGE_TYPE_SRV,
        .NumDescriptors = 1,
        .BaseShaderRegister = 0,
        .RegisterSpace = 1,
        .OffsetInDescriptorsFromTableStart = 0,
    };
    var params: [2]c.D3D12_ROOT_PARAMETER = std.mem.zeroes([2]c.D3D12_ROOT_PARAMETER);
    params[root_globals].ParameterType = c.D3D12_ROOT_PARAMETER_TYPE_CBV;
    params[root_globals].unnamed_0.Descriptor = .{ .ShaderRegister = 0, .RegisterSpace = 0 };
    params[root_globals].ShaderVisibility = c.D3D12_SHADER_VISIBILITY_ALL;
    params[root_texture].ParameterType = c.D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
    params[root_texture].unnamed_0.DescriptorTable = .{ .NumDescriptorRanges = 1, .pDescriptorRanges = &srv };
    params[root_texture].ShaderVisibility = c.D3D12_SHADER_VISIBILITY_PIXEL;
    const sampler: c.D3D12_STATIC_SAMPLER_DESC = .{
        .Filter = c.D3D12_FILTER_MIN_MAG_MIP_POINT,
        .AddressU = c.D3D12_TEXTURE_ADDRESS_MODE_CLAMP,
        .AddressV = c.D3D12_TEXTURE_ADDRESS_MODE_CLAMP,
        .AddressW = c.D3D12_TEXTURE_ADDRESS_MODE_CLAMP,
        .MipLODBias = 0,
        .MaxAnisotropy = 1,
        .ComparisonFunc = c.D3D12_COMPARISON_FUNC_NEVER,
        .BorderColor = c.D3D12_STATIC_BORDER_COLOR_TRANSPARENT_BLACK,
        .MinLOD = 0,
        .MaxLOD = c.D3D12_FLOAT32_MAX,
        .ShaderRegister = 0,
        .RegisterSpace = 1,
        .ShaderVisibility = c.D3D12_SHADER_VISIBILITY_PIXEL,
    };
    return serialiseRoot(d, &.{
        .NumParameters = params.len,
        .pParameters = &params,
        .NumStaticSamplers = 1,
        .pStaticSamplers = &sampler,
        .Flags = c.D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT,
    });
}

/// Any root signature: serialised (version 1.0) and created.
pub fn serialiseRoot(d: *com.Device, desc: *const c.D3D12_ROOT_SIGNATURE_DESC) Error!*com.RootSignature {
    var blob: ?*com.Blob = null;
    var errors: ?*com.Blob = null;
    defer com.release(errors);
    const result = c.D3D12SerializeRootSignature(desc, c.D3D_ROOT_SIGNATURE_VERSION_1, @ptrCast(&blob), @ptrCast(&errors));
    if (result < 0) if (errors) |e| std.log.warn("d3d12: {s}", .{e.bytes()});
    try com.check(result);
    defer com.release(blob);
    return d.createRootSignature(blob.?.bytes());
}

/// DXGI formats of quad_shader.attrs, by name.
fn dxgiFormat(comptime name: []const u8) c.DXGI_FORMAT {
    const table = .{
        .{ "float32", c.DXGI_FORMAT_R32_FLOAT },
        .{ "float32x2", c.DXGI_FORMAT_R32G32_FLOAT },
        .{ "float32x4", c.DXGI_FORMAT_R32G32B32A32_FLOAT },
        .{ "uint32x4", c.DXGI_FORMAT_R32G32B32A32_UINT },
        .{ "unorm8x4", c.DXGI_FORMAT_R8G8B8A8_UNORM },
    };
    inline for (table) |row| if (comptime std.mem.eql(u8, row[0], name)) return row[1];
    @compileError("unknown vertex format " ++ name);
}

/// Per-instance input layout of `Quad`, from quad_shader.attrs: naga names attribute n
/// `LOCn`, so the semantic is "LOC" with index n.
pub const quad_layout: [quad_shader.attrs.len]c.D3D12_INPUT_ELEMENT_DESC = blk: {
    @setEvalBranchQuota(10_000);
    var out: [quad_shader.attrs.len]c.D3D12_INPUT_ELEMENT_DESC = undefined;
    for (quad_shader.attrs, &out) |a, *o| o.* = .{
        .SemanticName = "LOC",
        .SemanticIndex = a.location,
        .Format = dxgiFormat(a.format),
        .InputSlot = 0,
        .AlignedByteOffset = a.offset,
        .InputSlotClass = c.D3D12_INPUT_CLASSIFICATION_PER_INSTANCE_DATA,
        .InstanceDataStepRate = 1,
    };
    break :blk out;
};

/// Premultiplied-alpha blending (one, one-minus-src-alpha) on every channel.
pub const premultiplied: c.D3D12_RENDER_TARGET_BLEND_DESC = .{
    .BlendEnable = 1,
    .LogicOpEnable = 0,
    .SrcBlend = c.D3D12_BLEND_ONE,
    .DestBlend = c.D3D12_BLEND_INV_SRC_ALPHA,
    .BlendOp = c.D3D12_BLEND_OP_ADD,
    .SrcBlendAlpha = c.D3D12_BLEND_ONE,
    .DestBlendAlpha = c.D3D12_BLEND_INV_SRC_ALPHA,
    .BlendOpAlpha = c.D3D12_BLEND_OP_ADD,
    .LogicOp = c.D3D12_LOGIC_OP_NOOP,
    .RenderTargetWriteMask = c.D3D12_COLOR_WRITE_ENABLE_ALL,
};

pub const Stages = struct {
    vs: []const u8,
    ps: []const u8,
    layout: []const c.D3D12_INPUT_ELEMENT_DESC = &quad_layout,
    topology: c.D3D12_PRIMITIVE_TOPOLOGY_TYPE = c.D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE,
    blend: c.D3D12_RENDER_TARGET_BLEND_DESC = premultiplied,
};

/// One graphics pipeline into a single `format` target, no depth, no culling.
pub fn create(d: *com.Device, root: *com.RootSignature, format: c.DXGI_FORMAT, s: Stages) Error!*com.PipelineState {
    var desc: c.D3D12_GRAPHICS_PIPELINE_STATE_DESC = std.mem.zeroes(c.D3D12_GRAPHICS_PIPELINE_STATE_DESC);
    desc.pRootSignature = @ptrCast(@alignCast(root));
    desc.VS = .{ .pShaderBytecode = s.vs.ptr, .BytecodeLength = s.vs.len };
    desc.PS = .{ .pShaderBytecode = s.ps.ptr, .BytecodeLength = s.ps.len };
    desc.BlendState.RenderTarget[0] = s.blend;
    desc.SampleMask = 0xffff_ffff;
    desc.RasterizerState = .{
        .FillMode = c.D3D12_FILL_MODE_SOLID,
        .CullMode = c.D3D12_CULL_MODE_NONE,
        .FrontCounterClockwise = 0,
        .DepthBias = 0,
        .DepthBiasClamp = 0,
        .SlopeScaledDepthBias = 0,
        .DepthClipEnable = 1,
        .MultisampleEnable = 0,
        .AntialiasedLineEnable = 0,
        .ForcedSampleCount = 0,
        .ConservativeRaster = c.D3D12_CONSERVATIVE_RASTERIZATION_MODE_OFF,
    };
    desc.InputLayout = .{ .pInputElementDescs = s.layout.ptr, .NumElements = @intCast(s.layout.len) };
    desc.PrimitiveTopologyType = s.topology;
    desc.NumRenderTargets = 1;
    desc.RTVFormats[0] = format;
    desc.SampleDesc = .{ .Count = 1, .Quality = 0 };
    return d.createGraphicsPipelineState(&desc);
}

/// The quad pipeline for one material: `hlsl` is a full quad shader (`naga(...)` of a
/// translated variant) with entry points `vs` and `fs`.
pub fn quad(d: *com.Device, root: *com.RootSignature, format: c.DXGI_FORMAT, hlsl: []const u8) Error!*com.PipelineState {
    const vs = try compile(hlsl, "vs", "vs_5_1");
    defer com.release(vs);
    const ps = try compile(hlsl, "fs", "ps_5_1");
    defer com.release(ps);
    return create(d, root, format, .{ .vs = vs.bytes(), .ps = ps.bytes() });
}

const testing = std.testing;
const Device = @import("device.zig").Device;

test "pipeline: the sampler declaration retains Windows HLSL line endings" {
    const hlsl = comptime naga("SamplerState nagaSamplerHeap[2048];\r\n" ++
        "static const SamplerState samp = nagaSamplerHeap[nagaGroup1SamplerIndexArray[1]];\r\n" ++
        "float4 shade();\r\n");
    try std.testing.expect(std.mem.startsWith(u8, hlsl, "SamplerState samp : register(s0, space1);\r\nfloat4 shade();\r\n"));
}

test "pipeline: naga's sampler heap becomes one static sampler" {
    try testing.expect(std.mem.indexOf(u8, stock_hlsl, "nagaSamplerHeap") == null);
    try testing.expect(std.mem.indexOf(u8, stock_hlsl, "SamplerState samp : register(s0, space1);") != null);
    try testing.expect(std.mem.indexOf(u8, example_hlsl, "nagaGroup1SamplerIndexArray") == null);
}

test "pipeline: the root signature and quad pipelines build from the committed HLSL on a real device" {
    var d = try Device.init(.{ .adapter = .warp });
    defer d.deinit();
    const root = try rootSignature(d.handle);
    defer com.release(root);
    for ([_][:0]const u8{ stock_hlsl, example_hlsl }) |hlsl| {
        for ([_]c.DXGI_FORMAT{ c.DXGI_FORMAT_R8G8B8A8_UNORM, c.DXGI_FORMAT_B8G8R8A8_UNORM }) |format| {
            const p = try quad(d.handle, root, format, hlsl);
            com.release(p);
        }
    }
    // A shader that does not compile is an error, not a crash.
    try testing.expectError(error.ShaderCompile, compile("float4 vs() : SV_Position { return nope; }", "vs", "vs_5_1"));
}

test "quad_layout follows the shader's layout of Quad" {
    for (quad_shader.attrs, quad_layout) |a, b| {
        try testing.expectEqual(a.location, b.SemanticIndex);
        try testing.expectEqual(a.offset, b.AlignedByteOffset);
    }
    try testing.expectEqual(@as(c.DXGI_FORMAT, c.DXGI_FORMAT_R8G8B8A8_UNORM), quad_layout[4].Format);
}
