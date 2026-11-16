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

    /// Waits until slot `next` is free, acquires an image and begins the slot's command
    /// buffer. error.OutOfDate: the swapchain must be recreated before drawing (the slot is
    /// left untouched, so calling again after recreating is fine).
    pub fn begin(f: *Frames, d: *const Device, chain: *const Swapchain) Error!Frame {
        const i = f.next;
        try check(d.fns.vkWaitForFences.?(d.handle, 1, &f.fences[i], c.VK_TRUE, std.math.maxInt(u64)));
        var index: u32 = 0;
        try check(d.swapchain.?.vkAcquireNextImageKHR.?(d.handle, chain.handle, std.math.maxInt(u64), f.acquired[i], null, &index));
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

    /// Blocks until every submitted frame is done.
    pub fn wait(f: *const Frames, d: *const Device) Error!void {
        try check(d.fns.vkWaitForFences.?(d.handle, f.count, &f.fences, c.VK_TRUE, std.math.maxInt(u64)));
    }
};

const testing = std.testing;
const pass = @import("pass.zig");

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
