//! An offscreen wgpu-native host for tests and tools: the instance, adapter, device and queue a
//! real application owns, a render target, and pixel read-back. Not part of the back end: the
//! renderer never creates or keeps any of these (src/render/wgpu/wgpu.zig, "WHO OWNS WHAT").
//!
//! wgpu-native reports through C callbacks; here each one only stores its result for the
//! caller's loop, which polls until it is set.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("wgpu_c");

pub const Error = error{ NoAdapter, NoDevice, MapFailed };

pub fn sv(s: []const u8) c.WGPUStringView {
    return .{ .data = s.ptr, .length = s.len };
}

fn str(s: c.WGPUStringView) []const u8 {
    if (s.data == null) return "";
    return s.data[0..s.length];
}

/// Bounded wait: a callback that never comes is a failure, not a hang.
const max_polls = 10_000;

pub const Host = struct {
    instance: c.WGPUInstance,
    adapter: c.WGPUAdapter,
    device: c.WGPUDevice,
    queue: c.WGPUQueue,

    pub fn init() Error!Host {
        // One back end, not wgpu-native's default of all: every enabled back end is initialised
        // at instance creation, and the GL one loads the EGL driver it never uses (+46 MB
        // resident on lavapipe, +81 MB on NVIDIA; docs/research/render-select.md, section 3).
        var extras: c.WGPUInstanceExtras = .{
            .chain = .{ .sType = c.WGPUSType_InstanceExtras },
            .backends = if (builtin.target.os.tag.isDarwin()) c.WGPUInstanceBackend_Metal else c.WGPUInstanceBackend_Vulkan,
        };
        const instance = c.wgpuCreateInstance(&.{ .nextInChain = &extras.chain });
        var got_adapter: GotAdapter = .{};
        _ = c.wgpuInstanceRequestAdapter(instance, null, .{
            .mode = c.WGPUCallbackMode_AllowProcessEvents,
            .callback = onAdapter,
            .userdata1 = &got_adapter,
        });
        var polls: u32 = 0;
        while (!got_adapter.done and polls < max_polls) : (polls += 1) c.wgpuInstanceProcessEvents(instance);
        const adapter = got_adapter.adapter orelse return error.NoAdapter;

        var got_device: GotDevice = .{};
        _ = c.wgpuAdapterRequestDevice(adapter, &.{
            .uncapturedErrorCallbackInfo = .{ .callback = onError },
        }, .{
            .mode = c.WGPUCallbackMode_AllowProcessEvents,
            .callback = onDevice,
            .userdata1 = &got_device,
        });
        polls = 0;
        while (!got_device.done and polls < max_polls) : (polls += 1) c.wgpuInstanceProcessEvents(instance);
        const device = got_device.device orelse return error.NoDevice;
        return .{ .instance = instance, .adapter = adapter, .device = device, .queue = c.wgpuDeviceGetQueue(device) };
    }

    pub fn deinit(h: *Host) void {
        c.wgpuQueueRelease(h.queue);
        c.wgpuDeviceRelease(h.device);
        c.wgpuAdapterRelease(h.adapter);
        c.wgpuInstanceRelease(h.instance);
    }

    /// The adapter's device name, written into `buf` ("llvmpipe (LLVM ...)" on lavapipe).
    pub fn adapterName(h: *const Host, buf: []u8) []const u8 {
        var info: c.WGPUAdapterInfo = .{};
        _ = c.wgpuAdapterGetInfo(h.adapter, &info);
        defer c.wgpuAdapterInfoFreeMembers(info);
        const name = str(info.device);
        const n = @min(name.len, buf.len);
        @memcpy(buf[0..n], name[0..n]);
        return buf[0..n];
    }

    /// Submits one encoder's commands.
    pub fn submit(h: *const Host, encoder: c.WGPUCommandEncoder) void {
        const commands = c.wgpuCommandEncoderFinish(encoder, null);
        c.wgpuQueueSubmit(h.queue, 1, &commands);
        c.wgpuCommandBufferRelease(commands);
        c.wgpuCommandEncoderRelease(encoder);
    }

    /// Copies `t` into `out` as tightly packed rows of 4-byte pixels (`t.width * t.height * 4`).
    pub fn readback(h: *const Host, t: *const Target, out: []u8) Error!void {
        const row = t.width * 4;
        // Copies need rows padded to 256 bytes.
        const padded_row = std.mem.alignForward(u32, row, 256);
        const size = @as(u64, padded_row) * t.height;
        std.debug.assert(out.len >= @as(usize, row) * t.height);
        const staging = c.wgpuDeviceCreateBuffer(h.device, &.{
            .usage = c.WGPUBufferUsage_MapRead | c.WGPUBufferUsage_CopyDst,
            .size = size,
        });
        defer c.wgpuBufferRelease(staging);
        const encoder = c.wgpuDeviceCreateCommandEncoder(h.device, null);
        c.wgpuCommandEncoderCopyTextureToBuffer(encoder, &.{ .texture = t.texture, .aspect = c.WGPUTextureAspect_All }, &.{
            .layout = .{ .bytesPerRow = padded_row, .rowsPerImage = t.height },
            .buffer = staging,
        }, &.{ .width = t.width, .height = t.height, .depthOrArrayLayers = 1 });
        h.submit(encoder);

        var mapped: Mapped = .{};
        _ = c.wgpuBufferMapAsync(staging, c.WGPUMapMode_Read, 0, @intCast(size), .{
            .mode = c.WGPUCallbackMode_AllowProcessEvents,
            .callback = onMap,
            .userdata1 = &mapped,
        });
        var polls: u32 = 0;
        while (!mapped.done and polls < max_polls) : (polls += 1) {
            _ = c.wgpuDevicePoll(h.device, 1, null);
            c.wgpuInstanceProcessEvents(h.instance);
        }
        if (!mapped.ok) return error.MapFailed;
        const bytes: [*]const u8 = @ptrCast(c.wgpuBufferGetConstMappedRange(staging, 0, @intCast(size)));
        for (0..t.height) |y| @memcpy(out[y * row ..][0..row], bytes[y * padded_row ..][0..row]);
        c.wgpuBufferUnmap(staging);
    }
};

/// A texture the pass draws into and `readback` copies from.
pub const Target = struct {
    texture: c.WGPUTexture,
    view: c.WGPUTextureView,
    width: u32,
    height: u32,

    pub fn init(h: *const Host, width: u32, height: u32, format: c.WGPUTextureFormat) Target {
        const texture = c.wgpuDeviceCreateTexture(h.device, &.{
            .usage = c.WGPUTextureUsage_RenderAttachment | c.WGPUTextureUsage_CopySrc,
            .dimension = c.WGPUTextureDimension_2D,
            .size = .{ .width = width, .height = height, .depthOrArrayLayers = 1 },
            .format = format,
            .mipLevelCount = 1,
            .sampleCount = 1,
        });
        return .{ .texture = texture, .view = c.wgpuTextureCreateView(texture, null), .width = width, .height = height };
    }

    pub fn deinit(t: *Target) void {
        c.wgpuTextureViewRelease(t.view);
        c.wgpuTextureRelease(t.texture);
    }
};

/// A sampled texture uploaded from caller pixels: `width * height` RGBA8 pixels, rows packed.
pub const Image = struct {
    texture: c.WGPUTexture,
    view: c.WGPUTextureView,

    pub fn init(h: *const Host, width: u32, height: u32, rgba: []const u8) Image {
        std.debug.assert(rgba.len == @as(usize, width) * height * 4);
        const size: c.WGPUExtent3D = .{ .width = width, .height = height, .depthOrArrayLayers = 1 };
        const texture = c.wgpuDeviceCreateTexture(h.device, &.{
            .usage = c.WGPUTextureUsage_TextureBinding | c.WGPUTextureUsage_CopyDst,
            .dimension = c.WGPUTextureDimension_2D,
            .size = size,
            .format = c.WGPUTextureFormat_RGBA8Unorm,
            .mipLevelCount = 1,
            .sampleCount = 1,
        });
        c.wgpuQueueWriteTexture(h.queue, &.{ .texture = texture, .aspect = c.WGPUTextureAspect_All }, rgba.ptr, rgba.len, &.{ .bytesPerRow = width * 4, .rowsPerImage = height }, &size);
        return .{ .texture = texture, .view = c.wgpuTextureCreateView(texture, null) };
    }

    pub fn deinit(img: *Image) void {
        c.wgpuTextureViewRelease(img.view);
        c.wgpuTextureRelease(img.texture);
    }
};

/// Nearest-texel sampling, clamped: what the golden images were drawn with.
pub fn nearestSampler(h: *const Host) c.WGPUSampler {
    return c.wgpuDeviceCreateSampler(h.device, &.{
        .addressModeU = c.WGPUAddressMode_ClampToEdge,
        .addressModeV = c.WGPUAddressMode_ClampToEdge,
        .addressModeW = c.WGPUAddressMode_ClampToEdge,
        .magFilter = c.WGPUFilterMode_Nearest,
        .minFilter = c.WGPUFilterMode_Nearest,
        .mipmapFilter = c.WGPUMipmapFilterMode_Nearest,
        .lodMaxClamp = 32,
        .maxAnisotropy = 1,
    });
}

/// Begins a pass over `view` that clears it to `clear` (straight RGBA, 0 to 1). With `resolve`,
/// `view` is a multisampled texture (`native.Multisample`) resolved into `resolve` at the end.
pub fn beginPass(encoder: c.WGPUCommandEncoder, view: c.WGPUTextureView, resolve: c.WGPUTextureView, clear: [4]f64) c.WGPURenderPassEncoder {
    const attachment: c.WGPURenderPassColorAttachment = .{
        .view = view,
        .resolveTarget = resolve,
        .depthSlice = c.WGPU_DEPTH_SLICE_UNDEFINED,
        .loadOp = c.WGPULoadOp_Clear,
        .storeOp = c.WGPUStoreOp_Store,
        .clearValue = .{ .r = clear[0], .g = clear[1], .b = clear[2], .a = clear[3] },
    };
    return c.wgpuCommandEncoderBeginRenderPass(encoder, &.{ .colorAttachmentCount = 1, .colorAttachments = &attachment });
}

/// Ends and releases a pass.
pub fn endPass(pass: c.WGPURenderPassEncoder) void {
    c.wgpuRenderPassEncoderEnd(pass);
    c.wgpuRenderPassEncoderRelease(pass);
}

const GotAdapter = struct { done: bool = false, adapter: c.WGPUAdapter = null };
const GotDevice = struct { done: bool = false, device: c.WGPUDevice = null };
const Mapped = struct { done: bool = false, ok: bool = false };

fn onAdapter(status: c.WGPURequestAdapterStatus, adapter: c.WGPUAdapter, message: c.WGPUStringView, out: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const got: *GotAdapter = @ptrCast(@alignCast(out));
    if (status != c.WGPURequestAdapterStatus_Success) std.debug.print("wgpu: no adapter: {s}\n", .{str(message)});
    got.adapter = if (status == c.WGPURequestAdapterStatus_Success) adapter else null;
    got.done = true;
}

fn onDevice(status: c.WGPURequestDeviceStatus, device: c.WGPUDevice, message: c.WGPUStringView, out: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const got: *GotDevice = @ptrCast(@alignCast(out));
    if (status != c.WGPURequestDeviceStatus_Success) std.debug.print("wgpu: no device: {s}\n", .{str(message)});
    got.device = if (status == c.WGPURequestDeviceStatus_Success) device else null;
    got.done = true;
}

fn onMap(status: c.WGPUMapAsyncStatus, message: c.WGPUStringView, out: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const got: *Mapped = @ptrCast(@alignCast(out));
    if (status != c.WGPUMapAsyncStatus_Success) std.debug.print("wgpu: map failed: {s}\n", .{str(message)});
    got.ok = status == c.WGPUMapAsyncStatus_Success;
    got.done = true;
}

/// A validation error is a bug in the caller or the back end: stop with wgpu's message.
fn onError(_: [*c]const c.WGPUDevice, kind: c.WGPUErrorType, message: c.WGPUStringView, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    std.debug.panic("wgpu error {d}: {s}", .{ kind, str(message) });
}
