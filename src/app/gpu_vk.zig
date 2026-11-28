//! What every Vulkan GPU window of lcgf_app keeps besides where its frames go (a swapchain
//! over X11, shared images on Wayland): the application's memory and staging, the loop's
//! mapped write buffers, and the images src/app/gpu.zig's contract asks for, over one
//! `vk.Setup`. src/app/gpu_x11.zig and gpu_wayland.zig hand their contract calls to it.
//!
//! Contents
//!   pub const Kit = struct

const std = @import("std");
const vk = @import("vk");
const DrawList = @import("lcgf").draw_list.DrawList;
const gpu_loop = @import("gpu.zig");
const c = vk.c;
const gpu = vk.gpu;
const Image = vk.device.Image;
const ImageKind = gpu_loop.ImageKind;
const Channel = gpu_loop.Channel;

/// A Vulkan window's memory and images (the module doc). Filled in place by `open`.
pub const Kit = struct {
    g: *vk.Setup,
    arena: gpu.Arena,
    staging_arena: gpu.Arena,
    /// The application's staging, a frame slot each.
    staging: [2]gpu.Staging,
    /// Mapped buffers the loop's own texture writes go through, per channel and frame slot.
    writes: [3][2]vk.device.Buffer,

    /// Over setup `g`: `o.gpu_bytes` for `draw`, `o.staging_bytes` of staging per frame slot,
    /// and texture handles up to `handles` registered as white.
    pub fn open(k: *Kit, g: *vk.Setup, o: gpu_loop.Open, handles: u16) !void {
        std.debug.assert(o.staging_bytes > 0);
        k.g = g;
        const d = &g.device;
        const dev: gpu.Device = .wrap(d);
        k.arena = try .init(dev, .{ .bytes = o.gpu_bytes });
        errdefer k.arena.deinit();
        const staging_bytes = 2 * o.staging_bytes + (1 << 16);
        k.staging_arena = try .init(dev, .{ .bytes = staging_bytes, .memory = .host });
        errdefer k.staging_arena.deinit();
        for (&k.staging) |*s| s.* = try .init(dev, &k.staging_arena, o.staging_bytes);
        while (g.gfx.texture_count < handles) _ = try g.gfx.addTexture(d, g.white.view, g.sampler);
        k.writes = @splat(.{ .{ .size = 0 }, .{ .size = 0 } });
    }

    pub fn close(k: *Kit) void {
        const d = &k.g.device;
        for (&k.writes) |*ch| for (ch) |*b| if (b.handle != null) d.destroyBuffer(b);
        for (k.staging) |s| s.deinit(.wrap(d));
        k.staging_arena.deinit();
        k.arena.deinit();
    }

    pub fn waitIdle(k: *Kit) void {
        const d = &k.g.device;
        _ = d.fns.vkDeviceWaitIdle.?(d.handle);
    }

    pub fn createImage(k: *Kit, kind: ImageKind, size: [2]u32) !Image {
        std.debug.assert(size[0] > 0);
        std.debug.assert(size[1] > 0);
        const d = &k.g.device;
        const sampled = c.VK_IMAGE_USAGE_SAMPLED_BIT;
        return switch (kind) {
            // Read as white with its byte as alpha, as `sw.Image.alpha8` is.
            .coverage => d.createImage(.{
                .width = size[0],
                .height = size[1],
                .format = c.VK_FORMAT_R8_UNORM,
                .usage = sampled | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
                .components = .{
                    .r = c.VK_COMPONENT_SWIZZLE_ONE,
                    .g = c.VK_COMPONENT_SWIZZLE_ONE,
                    .b = c.VK_COMPONENT_SWIZZLE_ONE,
                    .a = c.VK_COMPONENT_SWIZZLE_R,
                },
            }),
            .rgba => d.createImage(.{
                .width = size[0],
                .height = size[1],
                .usage = sampled | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
            }),
            .target => d.createImage(.{
                .width = size[0],
                .height = size[1],
                .usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | sampled,
            }),
        };
    }

    pub fn destroyImage(k: *Kit, img: *Image) void {
        k.g.device.destroyImage(img);
    }

    pub fn extent(img: *const Image) [2]u32 {
        return .{ img.extent.width, img.extent.height };
    }

    pub fn bind(k: *Kit, handle: u16, img: *const Image) void {
        const g = k.g;
        g.gfx.setTexture(&g.device, @fromBackingInt(handle), img.view, g.sampler);
    }

    /// All of `img` from `bytes` in a submission of its own: for what `open` makes once.
    pub fn writeNow(k: *Kit, img: *Image, bytes: []const u8) !void {
        const g = k.g;
        const d = &g.device;
        std.debug.assert(bytes.len > 0);
        var staging = try d.createBuffer(bytes.len, c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT, true);
        defer d.destroyBuffer(&staging);
        @memcpy(staging.mapped[0..bytes.len], bytes);
        const cmd = try g.once.begin(d);
        const region: vk.host.Rect = .{ .w = img.extent.width, .h = img.extent.height };
        const from = c.VK_IMAGE_LAYOUT_UNDEFINED;
        vk.host.uploadRegion(d, cmd, img.handle, staging.handle, 0, from, region);
        try g.once.submit(d);
    }

    /// A surface's `.target` image as `draw` sees it: `format`, resting shader-readable.
    pub fn targetTexture(img: *const Image, format: gpu.TextureFormat) gpu.Texture {
        return .{
            .image = img.handle,
            .view = img.view,
            .format = format,
            .width = img.extent.width,
            .height = img.extent.height,
            .samples = 1,
            .resting = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
    }

    /// Room for `bytes` in frame slot `slot`'s buffer of `ch`: made again larger when short
    /// (the slot's last frame is done: the window's `begin` waited for it).
    pub fn stage(k: *Kit, slot: u32, ch: Channel, bytes: u64) ![]u8 {
        const b = &k.writes[@backingInt(ch)][slot];
        if (b.size < bytes) {
            const d = &k.g.device;
            if (b.handle != null) d.destroyBuffer(b);
            const source = c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
            b.* = try d.createBuffer(@max(bytes, 1 << 20), source, true);
        }
        return b.mapped[0..@intCast(bytes)];
    }

    /// Records into `cmd` a copy of `ch`'s staged bytes from `at` into rectangle `r` of `img`.
    // tidy: allow(too-many-parameters) the contract's copy, with the frame's slot and buffer
    pub fn copy(
        k: *Kit,
        cmd: c.VkCommandBuffer,
        slot: u32,
        ch: Channel,
        at: u64,
        img: *Image,
        r: gpu_loop.Rect,
        fresh: bool,
    ) void {
        const d = &k.g.device;
        const b = &k.writes[@backingInt(ch)][slot];
        const sampled = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        const from: c.VkImageLayout = if (fresh) c.VK_IMAGE_LAYOUT_UNDEFINED else sampled;
        const x: i32 = @intCast(r.x);
        const y: i32 = @intCast(r.y);
        const region: vk.host.Rect = .{ .x = x, .y = y, .w = r.w, .h = r.h };
        vk.host.uploadRegion(d, cmd, img.handle, b.handle, at, from, region);
    }

    /// The application's upload phase in `cmd`, through frame slot `slot`'s staging.
    pub fn gpuFrame(k: *Kit, cmd: c.VkCommandBuffer, slot: u32) gpu_loop.GpuParts(gpu) {
        const d = &k.g.device;
        k.staging[slot].rewind();
        return .{
            .device = .wrap(d),
            .arena = &k.arena,
            .upload = .beginStaged(.wrap(d), cmd, &k.staging[slot]),
        };
    }

    /// The renderer's list of the last rows given, and what its canvases last wrote.
    pub fn kept(k: *const Kit) ?*const DrawList {
        return k.g.gfx.list;
    }

    pub fn canvasUploaded(k: *const Kit) ?usize {
        const cv = k.g.gfx.canvas orelse return null;
        return cv.uploaded;
    }
};
