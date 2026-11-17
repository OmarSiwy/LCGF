//! Stock wgpu-native v29 exposes borrowed MTLDevice and MTLTexture handles.
//! Separate queues use CPU completion waits in this serialized experiment.
const std = @import("std");
const lcgf = @import("lcgf");
const metal = @import("metal.zig");
const objc = metal.objc;
const Id = objc.Id;
const U = objc.NSUInteger;
const native = @import("wgpu_native");
const c = native.c;
const Host = native.host.Host;
const Drawing = @import("custom_draw_sample");

const width = 160;
const height = 120;
const side = 56;
const Pixels = [width * height * 4]u8;
const Node = [side * side * 4]u8;
var scene: lcgf.render_conformance.Storage = .{};

pub fn main(init: std.process.Init) !void {
    try objc.load();
    const pool = objc.Pool.push();
    defer pool.pop();
    var host = try Host.init();
    defer host.deinit();
    const device: Id = @ptrCast(c.wgpuDeviceGetNativeMetalDevice(host.device) orelse return error.NoMetalDevice);
    const queue = objc.msg(?Id, device, "newCommandQueue", .{}) orelse return error.NoMetalQueue;
    defer objc.release(queue);
    const tex = c.wgpuDeviceCreateTexture(host.device, &.{
        .usage = c.WGPUTextureUsage_RenderAttachment | c.WGPUTextureUsage_TextureBinding,
        .dimension = c.WGPUTextureDimension_2D,
        .size = .{ .width = side, .height = side, .depthOrArrayLayers = 1 },
        .format = c.WGPUTextureFormat_RGBA8Unorm,
        .mipLevelCount = 1,
        .sampleCount = 1,
    });
    defer c.wgpuTextureRelease(tex);
    const view = c.wgpuTextureCreateView(tex, null);
    defer c.wgpuTextureViewRelease(view);
    const image: Id = @ptrCast(c.wgpuTextureGetNativeMetalTexture(tex) orelse return error.NoMetalTexture);
    var gfx = try metal.Renderer.init(device, .{ .format = .rgba8_unorm });
    defer gfx.deinit();
    const handle = gfx.addTexture(image, null);
    scene.load(&lcgf.render_conformance.scenes[0]);
    @import("custom_draw_scene").addNode(&scene.draw, handle);
    gfx.prepare({}, &scene.draw, scene.glyphs(), .{ width, height }, 1);
    const target = try targetTexture(device);
    defer objc.release(target);
    const app = Drawing.init(host.device, host.queue, side);
    defer app.deinit();

    var expected: Node = undefined;
    for (0..6) |n| {
        const colors = [_][4]u8{ .{ 255, 0, 0, 255 }, .{ 0, 255, 0, 255 }, .{ 0, 0, 255, 255 }, .{ 128, 128, 128, 255 } };
        if (n < 5) {
            const color = colors[n % colors.len];
            try redraw(&host, app, view, color, if (n == 4) 1 else null);
            for (0..side * side) |i| expected[i * 4 ..][0..4].* = if (n == 4) .{ @truncate(i), @truncate(i >> 6), 128, 255 } else color;
        }
        gfx.setTexture(handle, image);
        var actual: Pixels = undefined;
        try render(&gfx, queue, target, &actual);
        const reference_image = try metal.texture.rgba8(device, side, side, &expected);
        defer objc.release(reference_image);
        gfx.setTexture(handle, reference_image);
        var reference: Pixels = undefined;
        try render(&gfx, queue, target, &reference);
        const corner = (56 * width + 96) * 4;
        if (!std.mem.eql(u8, actual[corner..][0..4], expected[0..4])) return error.CustomNodeMissing;
        if (!std.mem.eql(u8, &actual, &reference)) return error.PixelMismatch;
    }
    const name = objc.msg([*:0]const u8, objc.msg(Id, device, "name", .{}), "UTF8String", .{});
    std.debug.print("metal-webgpu device={s} frames=6 redraws=5 px_different=0\n", .{name});
    gfx.setTexture(handle, image);
    for (0..5) |round| {
        for (0..2) |order| {
            const dirty = (round + order) % 2 == 1;
            const start = std.Io.Clock.awake.now(init.io);
            const frames = 200;
            for (0..frames) |i| {
                const frame_pool = objc.Pool.push();
                defer frame_pool.pop();
                if (dirty) try redraw(&host, app, view, .{ 0, 0, 0, 255 }, @as(f32, @floatFromInt(i % 8)) / 7.0);
                try render(&gfx, queue, target, null);
            }
            const elapsed: f64 = @floatFromInt(start.durationTo(std.Io.Clock.awake.now(init.io)).toNanoseconds());
            std.debug.print("metal-webgpu round={d} mode={s} frames={d} frame_us={d:.2}\n", .{ round, if (dirty) "redrawn" else "cached", frames, elapsed / frames / 1000 });
        }
    }
}

fn redraw(host: *Host, app: Drawing, view: c.WGPUTextureView, color: [4]u8, alpha: ?f32) !void {
    const encoder = c.wgpuDeviceCreateCommandEncoder(host.device, null);
    app.draw(host.queue, encoder, view, color, alpha);
    host.submit(encoder);
    if (c.wgpuDevicePoll(host.device, 1, null) == 0) return error.WebGpuWorkOutstanding;
}

fn targetTexture(device: Id) !Id {
    const desc = objc.msg(Id, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{
        metal.mtl.PixelFormat.rgba8_unorm, @as(U, width), @as(U, height), @as(objc.BOOL, false),
    });
    objc.msg(void, desc, "setUsage:", .{metal.mtl.texture_usage_render_target});
    objc.msg(void, desc, "setStorageMode:", .{metal.mtl.storage_mode_managed});
    return objc.msg(?Id, device, "newTextureWithDescriptor:", .{desc}) orelse error.NoTarget;
}

fn render(gfx: *metal.Renderer, queue: Id, target: Id, pixels: ?*Pixels) !void {
    const cmd = objc.msg(Id, queue, "commandBuffer", .{});
    const pass = metal.present.beginPass(cmd, target, .{ 0, 0, 0, 1 });
    gfx.render(pass, &scene.draw);
    metal.present.endPass(pass);
    if (pixels != null) {
        const blit = objc.msg(Id, cmd, "blitCommandEncoder", .{});
        objc.msg(void, blit, "synchronizeResource:", .{target});
        objc.msg(void, blit, "endEncoding", .{});
    }
    objc.msg(void, cmd, "commit", .{});
    objc.msg(void, cmd, "waitUntilCompleted", .{});
    if (objc.msg(U, cmd, "status", .{}) != 4) return error.MetalCommandFailed;
    if (pixels) |out| {
        const region: metal.mtl.Region = .{ .size = .{ .width = width, .height = height } };
        objc.msg(void, target, "getBytes:bytesPerRow:fromRegion:mipmapLevel:", .{ out[0..].ptr, @as(U, width * 4), region, @as(U, 0) });
    }
}
