//! The application's side of the experiment. The drawing inputs are ordinary WebGPU handles.
const native = @import("wgpu_native");
const c = native.c;
const whost = native.host;
const Drawing = @This();

pipeline: c.WGPURenderPipeline,
group: c.WGPUBindGroup,
tint: c.WGPUBuffer,

pub fn init(device: c.WGPUDevice, queue: c.WGPUQueue, size: u32) Drawing {
    // Use the existing sample texture and sampler helpers for fixture setup.
    const h = whost.Host{ .device = device, .queue = queue, .instance = null, .adapter = null };
    var px: [64 * 64 * 4]u8 = undefined;
    for (0..64 * 64) |i| px[i * 4 ..][0..4].* = .{ @truncate(i), @truncate(i >> 6), 0x80, 0xff };

    var app_img = whost.Image.init(&h, size, size, px[0 .. size * size * 4]);
    defer app_img.deinit();
    const sampler = whost.nearestSampler(&h);
    defer c.wgpuSamplerRelease(sampler);
    const app_pipe = appPipeline(device);
    const tint = c.wgpuDeviceCreateBuffer(device, &.{ .usage = c.WGPUBufferUsage_Uniform | c.WGPUBufferUsage_CopyDst, .size = 16 });
    const entries = [_]c.WGPUBindGroupEntry{ .{ .binding = 0, .buffer = tint, .size = 16 }, .{ .binding = 1, .textureView = app_img.view }, .{ .binding = 2, .sampler = sampler } };
    const layout = c.wgpuRenderPipelineGetBindGroupLayout(app_pipe, 0);
    defer c.wgpuBindGroupLayoutRelease(layout);
    const app_group = c.wgpuDeviceCreateBindGroup(device, &.{ .layout = layout, .entryCount = entries.len, .entries = &entries });
    return .{ .pipeline = app_pipe, .group = app_group, .tint = tint };
}

/// Record the app's own pass. The framework submits this encoder after the callback returns.
pub fn draw(app: Drawing, queue: c.WGPUQueue, encoder: c.WGPUCommandEncoder, target: c.WGPUTextureView, col: [4]u8, alpha: ?f32) void {
    const rp = whost.beginPass(encoder, target, null, .{ f(col[0]), f(col[1]), f(col[2]), 1 });
    if (alpha) |opacity| {
        c.wgpuQueueWriteBuffer(queue, app.tint, 0, &[4]f32{ 1, 1, 1, opacity }, 16);
        c.wgpuRenderPassEncoderSetPipeline(rp, app.pipeline);
        c.wgpuRenderPassEncoderSetBindGroup(rp, 0, app.group, 0, null);
        c.wgpuRenderPassEncoderDraw(rp, 3, 1, 0, 0);
    }
    whost.endPass(rp);
}

pub fn deinit(app: Drawing) void {
    c.wgpuBindGroupRelease(app.group);
    c.wgpuRenderPipelineRelease(app.pipeline);
    c.wgpuBufferRelease(app.tint);
}

fn f(b: u8) f64 {
    return @as(f64, @floatFromInt(b)) / 255;
}

const app_wgsl =
    \\@group(0) @binding(0) var<uniform> tint: vec4f;
    \\@group(0) @binding(1) var tex: texture_2d<f32>;
    \\@group(0) @binding(2) var smp: sampler;
    \\struct V { @builtin(position) pos: vec4f, @location(0) uv: vec2f };
    \\@vertex fn vs(@builtin(vertex_index) i: u32) -> V {
    \\  let uv = vec2f(f32((i << 1u) & 2u), f32(i & 2u));
    \\  return V(vec4f(uv * vec2f(2.0, -2.0) + vec2f(-1.0, 1.0), 0.0, 1.0), uv);
    \\}
    \\@fragment fn fs(v: V) -> @location(0) vec4f { return textureSample(tex, smp, v.uv) * tint; }
;

fn appPipeline(device: c.WGPUDevice) c.WGPURenderPipeline {
    const source: c.WGPUShaderSourceWGSL = .{ .chain = .{ .sType = c.WGPUSType_ShaderSourceWGSL }, .code = whost.sv(app_wgsl) };
    const module = c.wgpuDeviceCreateShaderModule(device, &.{ .nextInChain = @constCast(&source.chain) });
    defer c.wgpuShaderModuleRelease(module);
    const premul: c.WGPUBlendComponent = .{ .operation = c.WGPUBlendOperation_Add, .srcFactor = c.WGPUBlendFactor_One, .dstFactor = c.WGPUBlendFactor_OneMinusSrcAlpha };
    const blend: c.WGPUBlendState = .{ .color = premul, .alpha = premul };
    const color: c.WGPUColorTargetState = .{ .format = c.WGPUTextureFormat_RGBA8Unorm, .blend = &blend, .writeMask = c.WGPUColorWriteMask_All };
    const fragment: c.WGPUFragmentState = .{ .module = module, .entryPoint = whost.sv("fs"), .targetCount = 1, .targets = &color };
    return c.wgpuDeviceCreateRenderPipeline(device, &.{
        .vertex = .{ .module = module, .entryPoint = whost.sv("vs") },
        .primitive = .{ .topology = c.WGPUPrimitiveTopology_TriangleList },
        .multisample = .{ .count = 1, .mask = 0xffff_ffff },
        .fragment = &fragment,
    });
}
