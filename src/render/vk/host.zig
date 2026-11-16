//! An offscreen Vulkan host for tests and tools: the library, instance, device and queue an
//! application owns, render targets, sampled images and pixel read-back. Not part of the back
//! end: the renderer never creates or keeps any of these (vk.zig, "WHO OWNS WHAT").

const std = @import("std");
const loader = @import("loader.zig");
const device_mod = @import("device.zig");
const pass = @import("pass.zig");
const c = loader.c;
const Error = loader.Error;
const check = loader.check;
const Device = device_mod.Device;

/// One command buffer for work the host waits on (uploads, read-back): begin, record, submit.
pub const Once = struct {
    pool: c.VkCommandPool = null,
    cmd: c.VkCommandBuffer = null,
    fence: c.VkFence = null,

    pub fn init(d: *const Device) Error!Once {
        var o: Once = .{};
        try check(d.fns.vkCreateCommandPool.?(d.handle, &.{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .queueFamilyIndex = d.family,
        }, null, &o.pool));
        errdefer d.fns.vkDestroyCommandPool.?(d.handle, o.pool, null);
        try check(d.fns.vkAllocateCommandBuffers.?(d.handle, &.{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = o.pool,
            .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        }, &o.cmd));
        try check(d.fns.vkCreateFence.?(d.handle, &.{ .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO }, null, &o.fence));
        return o;
    }

    pub fn deinit(o: *Once, d: *const Device) void {
        d.fns.vkDestroyFence.?(d.handle, o.fence, null);
        d.fns.vkDestroyCommandPool.?(d.handle, o.pool, null);
    }

    pub fn begin(o: *Once, d: *const Device) Error!c.VkCommandBuffer {
        try check(d.fns.vkResetCommandPool.?(d.handle, o.pool, 0));
        try check(d.fns.vkBeginCommandBuffer.?(o.cmd, &.{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        }));
        return o.cmd;
    }

    /// Submits and waits until the GPU is done with it.
    pub fn submit(o: *Once, d: *const Device) Error!void {
        try check(d.fns.vkEndCommandBuffer.?(o.cmd));
        const info: c.VkCommandBufferSubmitInfo = .{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO, .commandBuffer = o.cmd };
        try check(d.fns.vkQueueSubmit2.?(d.queue, 1, &.{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
            .commandBufferInfoCount = 1,
            .pCommandBufferInfos = &info,
        }, o.fence));
        try check(d.fns.vkWaitForFences.?(d.handle, 1, &o.fence, c.VK_TRUE, std.math.maxInt(u64)));
        try check(d.fns.vkResetFences.?(d.handle, 1, &o.fence));
    }
};

pub const Host = struct {
    lib: loader.Library,
    instance: loader.Instance,
    device: Device,
    once: Once,

    /// Offscreen: no surface, no swapchain extension. Fills `h` in place.
    pub fn init(h: *Host) !void {
        h.lib = try loader.Library.open();
        errdefer h.lib.close();
        h.instance = try loader.Instance.init(&h.lib, .{});
        errdefer h.instance.deinit();
        h.device = try Device.init(&h.instance, try device_mod.pick(&h.instance, null), false);
        errdefer h.device.deinit();
        h.once = try Once.init(&h.device);
    }

    pub fn deinit(h: *Host) void {
        _ = h.device.fns.vkDeviceWaitIdle.?(h.device.handle);
        h.once.deinit(&h.device);
        h.device.deinit();
        h.instance.deinit();
        h.lib.close();
    }

    /// Copies `image` (in TRANSFER_SRC_OPTIMAL, 4 bytes per pixel) into `out` as packed rows.
    pub fn readback(h: *Host, image: c.VkImage, extent: c.VkExtent2D, out: []u8) !void {
        const d = &h.device;
        const size = @as(u64, extent.width) * extent.height * 4;
        std.debug.assert(out.len >= size);
        var staging = try d.createBuffer(size, c.VK_BUFFER_USAGE_TRANSFER_DST_BIT, true);
        defer d.destroyBuffer(&staging);
        const cmd = try h.once.begin(d);
        d.fns.vkCmdCopyImageToBuffer.?(cmd, image, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, staging.handle, 1, &.{
            .imageSubresource = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .layerCount = 1 },
            .imageExtent = .{ .width = extent.width, .height = extent.height, .depth = 1 },
        });
        try h.once.submit(d);
        @memcpy(out[0..@intCast(size)], staging.mapped);
    }

    /// A sampled RGBA8 image from `rgba` (`width * height * 4` bytes, rows packed), left in
    /// SHADER_READ_ONLY_OPTIMAL.
    pub fn sampled(h: *Host, width: u32, height: u32, rgba: []const u8) !device_mod.Image {
        const d = &h.device;
        std.debug.assert(rgba.len == @as(usize, width) * height * 4);
        var img = try d.createImage(.{ .width = width, .height = height, .usage = c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT });
        errdefer d.destroyImage(&img);
        var staging = try d.createBuffer(rgba.len, c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT, true);
        defer d.destroyBuffer(&staging);
        @memcpy(staging.mapped, rgba);
        const cmd = try h.once.begin(d);
        upload(d, cmd, img.handle, staging.handle, .{ .width = width, .height = height }, 0);
        try h.once.submit(d);
        return img;
    }
};

/// Records a copy of `region` rows from `buffer` at `offset` into `image` (whole image in
/// UNDEFINED before, SHADER_READ_ONLY_OPTIMAL after; prior contents are kept only when the
/// image was already initialised, which is why `from` is the layout it is in now).
pub fn uploadRegion(d: *const Device, cmd: c.VkCommandBuffer, image: c.VkImage, buffer: c.VkBuffer, offset: u64, from: c.VkImageLayout, region: struct { x: i32 = 0, y: i32 = 0, w: u32, h: u32 }) void {
    var b: c.VkImageMemoryBarrier2 = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
        .srcStageMask = c.VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
        .dstStageMask = c.VK_PIPELINE_STAGE_2_COPY_BIT,
        .dstAccessMask = c.VK_ACCESS_2_TRANSFER_WRITE_BIT,
        .oldLayout = from,
        .newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = pass.color_range,
    };
    pass.barrier(d, cmd, (&b)[0..1]);
    d.fns.vkCmdCopyBufferToImage.?(cmd, buffer, image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &.{
        .bufferOffset = offset,
        .imageSubresource = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .layerCount = 1 },
        .imageOffset = .{ .x = region.x, .y = region.y },
        .imageExtent = .{ .width = region.w, .height = region.h, .depth = 1 },
    });
    b.srcStageMask = c.VK_PIPELINE_STAGE_2_COPY_BIT;
    b.srcAccessMask = c.VK_ACCESS_2_TRANSFER_WRITE_BIT;
    b.dstStageMask = c.VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT;
    b.dstAccessMask = c.VK_ACCESS_2_SHADER_SAMPLED_READ_BIT;
    b.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    b.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    pass.barrier(d, cmd, (&b)[0..1]);
}

fn upload(d: *const Device, cmd: c.VkCommandBuffer, image: c.VkImage, buffer: c.VkBuffer, extent: c.VkExtent2D, offset: u64) void {
    uploadRegion(d, cmd, image, buffer, offset, c.VK_IMAGE_LAYOUT_UNDEFINED, .{ .w = extent.width, .h = extent.height });
}

/// Nearest-texel sampling, clamped: what the golden images were drawn with.
pub fn nearestSampler(d: *const Device) Error!c.VkSampler {
    var s: c.VkSampler = null;
    try check(d.fns.vkCreateSampler.?(d.handle, &.{
        .sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .magFilter = c.VK_FILTER_NEAREST,
        .minFilter = c.VK_FILTER_NEAREST,
        .mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_NEAREST,
        .addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .maxLod = 32,
    }, null, &s));
    return s;
}

/// An RGBA8 image a pass draws into and `readback` copies from. With `samples` above 1 the pass
/// draws into `msaa` and resolves into `image`.
pub const Target = struct {
    image: device_mod.Image,
    msaa: ?device_mod.Image = null,

    pub fn init(d: *const Device, width: u32, height: u32, samples: u32) Error!Target {
        const usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
        var t: Target = .{ .image = try d.createImage(.{ .width = width, .height = height, .usage = usage }) };
        errdefer d.destroyImage(&t.image);
        if (samples > 1) t.msaa = try d.createImage(.{
            .width = width,
            .height = height,
            .usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT,
            .samples = samples,
        });
        return t;
    }

    pub fn deinit(t: *Target, d: *const Device) void {
        if (t.msaa) |*m| d.destroyImage(m);
        d.destroyImage(&t.image);
    }

    /// What `pass.begin` needs to draw into this target and clear it to `clear`.
    pub fn begin(t: *const Target, clear: [4]f32) pass.Begin {
        if (t.msaa) |m| return .{ .image = m.handle, .view = m.view, .extent = t.image.extent, .clear = clear, .resolve = .{ .image = t.image.handle, .view = t.image.view } };
        return .{ .image = t.image.handle, .view = t.image.view, .extent = t.image.extent, .clear = clear };
    }
};
