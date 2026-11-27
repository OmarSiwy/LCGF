//! Frame synchronisation and present: `count` frames in flight, each with its own command
//! buffer, fence and acquire semaphore, and one render-finished semaphore per swapchain image.
//!
//!     const f = try frames.begin(&dev, &chain);          // waits for this slot's last use
//!     gfx.prepare(f.slot, draw, glyphs, viewport, scale); // the ring slot is free now
//!     pass.begin(&dev, f.cmd, .{ .image = f.image, .view = f.view, .extent = chain.extent });
//!     gfx.render(f.cmd, draw);
//!     pass.end(&dev, f.cmd, .{ .image = f.image, .layout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR });
//!     _ = try frames.present(&dev, &chain, f);
//!
//! Why the semaphores are split that way: the acquire semaphore is free again once the
//! submission that waits on it has run, which this slot's fence proves; the render-finished
//! semaphore is waited on by the presentation engine, and only re-acquiring the same image
//! proves that wait is over, so it belongs to the image, not the slot.
//!
//! Resize and loss. error.OutOfDate from `begin` or `present` (and `.suboptimal`) means the
//! surface changed: call `resize` and go on. error.DeviceLost from any call means every object
//! made from the device is gone: deinit the renderer, these frames, the swapchain, your images
//! and the device, pick a device again from the same instance and rebuild them (the surface
//! and instance survive). error.SurfaceLost: the window is gone; recreate the surface too.
//!
//! The CPU blocks in exactly two places: the fence of the slot it is about to reuse, and the
//! acquire (FIFO paces it to the display). Nothing polls.

const std = @import("std");
const loader = @import("loader.zig");
const device_mod = @import("device.zig");
const swapchain = @import("swapchain.zig");
const c = loader.c;
const Error = loader.Error;
const check = loader.check;
const Device = device_mod.Device;
const Swapchain = swapchain.Swapchain;

pub const max_frames = 3;

pub const Frame = struct {
    /// 0 to count - 1: the renderer's ring slot (`Renderer.prepare`'s first argument).
    slot: u32,
    /// Recording, in this frame's command buffer.
    cmd: c.VkCommandBuffer,
    /// The acquired swapchain image.
    index: u32,
    image: c.VkImage,
    view: c.VkImageView,
};

pub const Presented = enum {
    ok,
    /// Presented, but the swapchain no longer matches the surface exactly: recreate it when
    /// convenient (swapchain.zig `recreate`).
    suboptimal,
};

pub const Frames = struct {
    count: u32,
    /// The slot the next `begin` uses.
    next: u32 = 0,
    /// How long `begin` waits for the slot's last frame and for an image before it gives up
    /// with error.NotShown. Forever by default; a window that must not block while hidden
    /// sets a bound (`setup.Window`).
    wait_ns: u64 = std.math.maxInt(u64),
    pools: [max_frames]c.VkCommandPool = @splat(null),
    cmds: [max_frames]c.VkCommandBuffer = @splat(null),
    fences: [max_frames]c.VkFence = @splat(null),
    acquired: [max_frames]c.VkSemaphore = @splat(null),
    rendered: [swapchain.max_images]c.VkSemaphore = @splat(null),

    /// `count` frames in flight (1 to `max_frames`); give the renderer the same number
    /// (`Desc.frames`).
    pub fn init(d: *const Device, count: u32) Error!Frames {
        std.debug.assert(count >= 1 and count <= max_frames);
        var f: Frames = .{ .count = count };
        errdefer f.deinit(d);
        const sem_info: c.VkSemaphoreCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
        for (0..count) |i| {
            try check(d.fns.vkCreateCommandPool.?(d.handle, &.{
                .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
                .flags = c.VK_COMMAND_POOL_CREATE_TRANSIENT_BIT,
                .queueFamilyIndex = d.family,
            }, null, &f.pools[i]));
            try check(d.fns.vkAllocateCommandBuffers.?(d.handle, &.{
                .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
                .commandPool = f.pools[i],
                .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
                .commandBufferCount = 1,
            }, &f.cmds[i]));
            // Signalled, so the first wait on each slot returns at once.
            try check(d.fns.vkCreateFence.?(d.handle, &.{
                .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
                .flags = c.VK_FENCE_CREATE_SIGNALED_BIT,
            }, null, &f.fences[i]));
            try check(d.fns.vkCreateSemaphore.?(d.handle, &sem_info, null, &f.acquired[i]));
        }
        for (&f.rendered) |*s| try check(d.fns.vkCreateSemaphore.?(d.handle, &sem_info, null, s));
        return f;
    }

    /// Waits for the GPU first: nothing may be destroyed while a frame still uses it.
    pub fn deinit(f: *Frames, d: *const Device) void {
        _ = d.fns.vkDeviceWaitIdle.?(d.handle);
        for (f.rendered) |s| if (s != null) d.fns.vkDestroySemaphore.?(d.handle, s, null);
        for (0..f.count) |i| {
            if (f.acquired[i] != null) d.fns.vkDestroySemaphore.?(d.handle, f.acquired[i], null);
            if (f.fences[i] != null) d.fns.vkDestroyFence.?(d.handle, f.fences[i], null);
            if (f.pools[i] != null) d.fns.vkDestroyCommandPool.?(d.handle, f.pools[i], null);
        }
        f.* = .{ .count = 0 };
    }

    pub const BeginError = Error || error{NotShown};

    /// Waits until slot `next` is free, acquires an image and begins the slot's command
    /// buffer. error.OutOfDate: the swapchain must be recreated before drawing (the slot is
    /// left untouched, so calling again after recreating is fine). error.NotShown: the slot's
    /// last frame or an image was not ready within `wait_ns`, as when the presentation engine
    /// holds every image of a window it is not showing; nothing was touched, so calling again
    /// later is fine.
    pub fn begin(f: *Frames, d: *const Device, chain: *const Swapchain) BeginError!Frame {
        const i = f.next;
        std.debug.assert(i < f.count);
        const waited = d.fns.vkWaitForFences.?(d.handle, 1, &f.fences[i], c.VK_TRUE, f.wait_ns);
        if (waited == c.VK_TIMEOUT) return error.NotShown;
        try check(waited);
        var index: u32 = 0;
        const acquire = d.swapchain.?.vkAcquireNextImageKHR.?;
        const got = acquire(d.handle, chain.handle, f.wait_ns, f.acquired[i], null, &index);
        if (got == c.VK_TIMEOUT or got == c.VK_NOT_READY) return error.NotShown;
        try check(got);
        // Reset only once a submission is sure to follow, or the next wait would never return.
        try check(d.fns.vkResetFences.?(d.handle, 1, &f.fences[i]));
        try check(d.fns.vkResetCommandPool.?(d.handle, f.pools[i], 0));
        try check(d.fns.vkBeginCommandBuffer.?(f.cmds[i], &.{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        }));
        return .{ .slot = i, .cmd = f.cmds[i], .index = index, .image = chain.images[index], .view = chain.views[index] };
    }

    /// Submits the frame (waiting for the acquire before colour output) and queues its image
    /// for presentation once rendering has finished.
    pub fn present(f: *Frames, d: *const Device, chain: *const Swapchain, frame: Frame) Error!Presented {
        try check(d.fns.vkEndCommandBuffer.?(frame.cmd));
        const acquire_wait: c.VkSemaphoreSubmitInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
            .semaphore = f.acquired[frame.slot],
            .stageMask = c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
        };
        const signal: c.VkSemaphoreSubmitInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
            .semaphore = f.rendered[frame.index],
            .stageMask = c.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
        };
        const cmd_info: c.VkCommandBufferSubmitInfo = .{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO, .commandBuffer = frame.cmd };
        try check(d.fns.vkQueueSubmit2.?(d.queue, 1, &.{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
            .waitSemaphoreInfoCount = 1,
            .pWaitSemaphoreInfos = &acquire_wait,
            .commandBufferInfoCount = 1,
            .pCommandBufferInfos = &cmd_info,
            .signalSemaphoreInfoCount = 1,
            .pSignalSemaphoreInfos = &signal,
        }, f.fences[frame.slot]));
        f.next = (frame.slot + 1) % f.count;
        const r = d.swapchain.?.vkQueuePresentKHR.?(d.queue, &.{
            .sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &f.rendered[frame.index],
            .swapchainCount = 1,
            .pSwapchains = &chain.handle,
            .pImageIndices = &frame.index,
        });
        try check(r);
        return if (r == c.VK_SUBOPTIMAL_KHR) .suboptimal else .ok;
    }

    /// Resize, or recovery from error.OutOfDate / `.suboptimal`: waits for the GPU, recreates
    /// the swapchain at `want` and the per-image semaphores. Those are replaced because a
    /// present that failed out-of-date may leave its semaphore signalled with no waiter, and a
    /// signalled semaphore cannot be signalled again. The renderer needs nothing: viewport and
    /// scissor are set per draw from `prepare`'s viewport, and the pipelines take any size.
    pub fn resize(f: *Frames, d: *const Device, chain: *Swapchain, instance: *const loader.Instance, surface: c.VkSurfaceKHR, want: c.VkExtent2D) Error!void {
        try chain.recreate(instance, d, surface, want);
        const sem_info: c.VkSemaphoreCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
        for (&f.rendered) |*s| {
            d.fns.vkDestroySemaphore.?(d.handle, s.*, null);
            s.* = null;
            try check(d.fns.vkCreateSemaphore.?(d.handle, &sem_info, null, s));
        }
    }

    /// Blocks until every submitted frame is done.
    pub fn wait(f: *const Frames, d: *const Device) Error!void {
        try check(d.fns.vkWaitForFences.?(d.handle, f.count, &f.fences, c.VK_TRUE, std.math.maxInt(u64)));
    }
};

const testing = std.testing;
const pass = @import("pass.zig");
const host = @import("host.zig");
const Renderer = @import("renderer.zig").Renderer;
const lcgf = @import("lcgf");
const conformance = lcgf.render_conformance;

test "frame: with every image held elsewhere, begin gives up after wait_ns: NotShown" {
    var h: swapchain.Headless = undefined;
    try h.init();
    defer h.deinit();
    const d = &h.device;
    var chain = try Swapchain.init(&h.instance, d, h.surface, .{ .width = 64, .height = 32 }, null);
    defer chain.deinit(d);
    var frames = try Frames.init(d, 2);
    defer frames.deinit(d);
    frames.wait_ns = 0;
    // What a compositor does with a window it is not showing: it keeps the images. Here the
    // test acquires them all itself, with a fence so nothing is left pending.
    var fence: c.VkFence = null;
    const info: c.VkFenceCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    try check(d.fns.vkCreateFence.?(d.handle, &info, null, &fence));
    defer d.fns.vkDestroyFence.?(d.handle, fence, null);
    const acquire = d.swapchain.?.vkAcquireNextImageKHR.?;
    var held: u32 = 0;
    while (held < chain.len) : (held += 1) {
        var index: u32 = 0;
        const r = acquire(d.handle, chain.handle, 0, null, fence, &index);
        if (r == c.VK_NOT_READY or r == c.VK_TIMEOUT) break;
        try check(r);
        try check(d.fns.vkWaitForFences.?(d.handle, 1, &fence, c.VK_TRUE, std.math.maxInt(u64)));
        try check(d.fns.vkResetFences.?(d.handle, 1, &fence));
    }
    try testing.expect(held >= 1);
    try testing.expectError(error.NotShown, frames.begin(d, &chain));
    // Nothing was touched: the slot is the same, and its fence still signalled.
    try testing.expectEqual(@as(u32, 0), frames.next);
    const signalled = d.fns.vkWaitForFences.?(d.handle, 1, &frames.fences[0], c.VK_TRUE, 0);
    try testing.expectEqual(c.VK_SUCCESS, signalled);
}

test "frame: frames in flight acquire, clear and present a headless swapchain" {
    var h: swapchain.Headless = undefined;
    try h.init();
    defer h.deinit();
    const d = &h.device;
    var chain = try Swapchain.init(&h.instance, d, h.surface, .{ .width = 64, .height = 32 }, null);
    defer chain.deinit(d);
    var frames = try Frames.init(d, 2);
    defer frames.deinit(d);
    var slots: [6]u32 = undefined;
    for (&slots, 0..) |*slot, n| {
        const f = try frames.begin(d, &chain);
        slot.* = f.slot;
        try testing.expect(f.index < chain.len);
        const v: f32 = @floatFromInt(n);
        pass.begin(d, f.cmd, .{ .image = f.image, .view = f.view, .extent = chain.extent, .clear = .{ v / 8, 0, 0, 1 } });
        pass.end(d, f.cmd, .{ .image = f.image, .layout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR });
        try testing.expectEqual(Presented.ok, try frames.present(d, &chain, f));
    }
    try testing.expectEqualSlices(u32, &.{ 0, 1, 0, 1, 0, 1 }, &slots);
    try frames.wait(d);
}

/// Draws conformance scene `rects` at `viewport` through one frame of the loop and returns
/// the presented pixel at (x, y), RGBA.
fn drawRects(d: *const Device, frames: *Frames, chain: *const Swapchain, gfx: *Renderer, viewport: [2]f32, at: [2][2]u32) ![2][4]u8 {
    var st: conformance.Storage = .{};
    st.load(&conformance.scenes[0]);
    const bytes = @as(u64, chain.extent.width) * chain.extent.height * 4;
    var staging = try d.createBuffer(bytes, c.VK_BUFFER_USAGE_TRANSFER_DST_BIT, true);
    defer d.destroyBuffer(&staging);
    const f = try frames.begin(d, chain);
    gfx.prepare(f.slot, &st.draw, st.glyphs(), viewport, 1);
    pass.begin(d, f.cmd, .{ .image = f.image, .view = f.view, .extent = chain.extent });
    gfx.render(f.cmd, &st.draw);
    pass.end(d, f.cmd, .{ .image = f.image, .layout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL });
    d.fns.vkCmdCopyImageToBuffer.?(f.cmd, f.image, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, staging.handle, 1, &.{
        .imageSubresource = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .layerCount = 1 },
        .imageExtent = .{ .width = chain.extent.width, .height = chain.extent.height, .depth = 1 },
    });
    pass.transition(d, f.cmd, f.image, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR);
    _ = try frames.present(d, chain, f);
    try frames.wait(d);
    var out: [2][4]u8 = undefined;
    for (at, &out) |p, *o| {
        o.* = staging.mapped[(@as(usize, p[1]) * chain.extent.width + p[0]) * 4 ..][0..4].*;
        if (chain.format == c.VK_FORMAT_B8G8R8A8_UNORM) std.mem.swap(u8, &o[0], &o[2]);
    }
    return out;
}

const panel = [4]u8{ 30, 31, 36, 255 };
const black = [4]u8{ 0, 0, 0, 255 };

test "frame: a resize recreates the swapchain and the same renderer draws the new size" {
    var h: swapchain.Headless = undefined;
    try h.init();
    defer h.deinit();
    const d = &h.device;
    var chain = try Swapchain.init(&h.instance, d, h.surface, .{ .width = 160, .height = 120 }, null);
    defer chain.deinit(d);
    var frames = try Frames.init(d, 2);
    defer frames.deinit(d);
    var once = try host.Once.init(d);
    defer once.deinit(d);
    const white = try testWhite(d, &once);
    defer {
        var w = white;
        d.destroyImage(&w);
    }
    const sampler = try host.nearestSampler(d);
    defer d.fns.vkDestroySampler.?(d.handle, sampler, null);
    var gfx = try Renderer.init(d, .{ .format = chain.format, .frames = 2, .max_quads = 8, .max_glyphs = 8 }, white.view, sampler);
    defer gfx.deinit(d);

    // `rects` fills its 160x120 viewport with the panel colour.
    var px = try drawRects(d, &frames, &chain, &gfx, .{ 160, 120 }, .{ .{ 4, 4 }, .{ 159, 119 } });
    try testing.expectEqualSlices(u8, &panel, &px[0]);
    try testing.expectEqualSlices(u8, &panel, &px[1]);

    // The window grows: same renderer, new swapchain; outside the panel is the clear colour.
    try frames.resize(d, &chain, &h.instance, h.surface, .{ .width = 200, .height = 150 });
    try testing.expectEqual(@as(u32, 200), chain.extent.width);
    px = try drawRects(d, &frames, &chain, &gfx, .{ 200, 150 }, .{ .{ 4, 4 }, .{ 190, 140 } });
    try testing.expectEqualSlices(u8, &panel, &px[0]);
    try testing.expectEqualSlices(u8, &black, &px[1]);

    // A minimised window has no swapchain; the old one is kept.
    try testing.expectError(error.ZeroExtent, frames.resize(d, &chain, &h.instance, h.surface, .{ .width = 0, .height = 0 }));
    try testing.expectEqual(@as(u32, 200), chain.extent.width);
}

test "frame: after device loss everything is rebuilt from the same instance and surface" {
    // Lavapipe cannot lose its device on purpose, so this runs the recovery sequence the header
    // describes on a live device: tear down everything device-derived, pick again, rebuild,
    // draw. What it shows is that nothing outlives the device by accident.
    var h: swapchain.Headless = undefined;
    try h.init();
    defer h.deinit();
    for (0..2) |round| {
        if (round == 1) {
            h.device.deinit();
            h.device = try Device.init(&h.instance, try device_mod.pick(&h.instance, h.surface), true);
        }
        const d = &h.device;
        var chain = try Swapchain.init(&h.instance, d, h.surface, .{ .width = 160, .height = 120 }, null);
        defer chain.deinit(d);
        var frames = try Frames.init(d, 2);
        defer frames.deinit(d);
        var once = try host.Once.init(d);
        defer once.deinit(d);
        var white = try testWhite(d, &once);
        defer d.destroyImage(&white);
        const sampler = try host.nearestSampler(d);
        defer d.fns.vkDestroySampler.?(d.handle, sampler, null);
        var gfx = try Renderer.init(d, .{ .format = chain.format, .frames = 2, .max_quads = 8, .max_glyphs = 8 }, white.view, sampler);
        defer gfx.deinit(d);
        const px = try drawRects(d, &frames, &chain, &gfx, .{ 160, 120 }, .{ .{ 4, 4 }, .{ 100, 30 } });
        try testing.expectEqualSlices(u8, &panel, &px[0]);
    }
}

test "frame: device loss and out-of-date reach the host as errors" {
    try testing.expectError(error.DeviceLost, check(c.VK_ERROR_DEVICE_LOST));
    try testing.expectError(error.OutOfDate, check(c.VK_ERROR_OUT_OF_DATE_KHR));
    try testing.expectError(error.SurfaceLost, check(c.VK_ERROR_SURFACE_LOST_KHR));
}

fn testWhite(d: *const Device, once: *host.Once) !device_mod.Image {
    const img = try d.createImage(.{ .width = 1, .height = 1, .usage = c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT });
    var staging = try d.createBuffer(4, c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT, true);
    defer d.destroyBuffer(&staging);
    @memcpy(staging.mapped, &[4]u8{ 255, 255, 255, 255 });
    const cmd = try once.begin(d);
    host.uploadRegion(d, cmd, img.handle, staging.handle, 0, c.VK_IMAGE_LAYOUT_UNDEFINED, .{ .w = 1, .h = 1 });
    try once.submit(d);
    return img;
}
