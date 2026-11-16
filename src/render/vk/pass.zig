//! Recording a frame's render pass with dynamic rendering (Vulkan 1.3 core): no VkRenderPass or
//! VkFramebuffer objects to create, cache or recreate on resize; a pass is a begin and an end
//! around the draws, on any image view. Layout transitions are synchronization2 barriers.
//!
//!     pass.begin(&dev, cmd, .{ .image = img, .view = view, .extent = extent, .clear = .{ 0, 0, 0, 1 } });
//!     ... gfx.drawBatch(cmd, batch), the host's own vkCmd* ...
//!     pass.end(&dev, cmd, .{ .image = img, .layout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR });
//!
//! The command buffer between the two is the back end's `Pass`: the host records into it too.

const std = @import("std");
const loader = @import("loader.zig");
const device_mod = @import("device.zig");
const c = loader.c;
const Device = device_mod.Device;

pub const color_range: c.VkImageSubresourceRange = .{
    .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
    .levelCount = 1,
    .layerCount = 1,
};

pub const Begin = struct {
    image: c.VkImage,
    view: c.VkImageView,
    extent: c.VkExtent2D,
    /// Straight RGBA, 0 to 1; null loads what the image holds instead of clearing.
    clear: ?[4]f32 = .{ 0, 0, 0, 1 },
    /// The layout the image is in now. UNDEFINED discards its contents (fine when clearing).
    from: c.VkImageLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
    /// With multisampling: `image`/`view` are the multisampled target and this single-sample
    /// image is resolved into at the end of the pass.
    resolve: ?struct { image: c.VkImage, view: c.VkImageView } = null,
};

/// Moves `image` to the colour attachment layout and begins rendering into it.
pub fn begin(d: *const Device, cmd: c.VkCommandBuffer, b: Begin) void {
    var barriers: [2]c.VkImageMemoryBarrier2 = .{
        toAttachment(b.image, b.from),
        toAttachment(if (b.resolve) |r| r.image else null, c.VK_IMAGE_LAYOUT_UNDEFINED),
    };
    barrier(d, cmd, barriers[0 .. @as(usize, 1) + @intFromBool(b.resolve != null)]);
    const clear = b.clear orelse .{ 0, 0, 0, 0 };
    const attachment: c.VkRenderingAttachmentInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
        .imageView = b.view,
        .imageLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .resolveMode = if (b.resolve != null) c.VK_RESOLVE_MODE_AVERAGE_BIT else c.VK_RESOLVE_MODE_NONE,
        .resolveImageView = if (b.resolve) |r| r.view else null,
        .resolveImageLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .loadOp = if (b.clear != null) c.VK_ATTACHMENT_LOAD_OP_CLEAR else c.VK_ATTACHMENT_LOAD_OP_LOAD,
        // A multisampled target is only needed until it is resolved.
        .storeOp = if (b.resolve != null) c.VK_ATTACHMENT_STORE_OP_DONT_CARE else c.VK_ATTACHMENT_STORE_OP_STORE,
        .clearValue = .{ .color = .{ .float32 = clear } },
    };
    d.fns.vkCmdBeginRendering.?(cmd, &.{
        .sType = c.VK_STRUCTURE_TYPE_RENDERING_INFO,
        .renderArea = .{ .extent = b.extent },
        .layerCount = 1,
        .colorAttachmentCount = 1,
        .pColorAttachments = &attachment,
    });
}

pub const End = struct {
    /// The image that holds the result: the target, or the resolve image with multisampling.
    image: c.VkImage,
    /// PRESENT_SRC_KHR for a swapchain image, TRANSFER_SRC_OPTIMAL to read it back,
    /// SHADER_READ_ONLY_OPTIMAL to sample it in a later pass.
    layout: c.VkImageLayout,
};

/// Ends rendering and moves the result to the layout its next user needs.
pub fn end(d: *const Device, cmd: c.VkCommandBuffer, e: End) void {
    d.fns.vkCmdEndRendering.?(cmd);
    const b: c.VkImageMemoryBarrier2 = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
        .srcStageMask = c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
        .srcAccessMask = c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
        .dstStageMask = c.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
        .dstAccessMask = c.VK_ACCESS_2_MEMORY_READ_BIT,
        .oldLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .newLayout = e.layout,
        .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .image = e.image,
        .subresourceRange = color_range,
    };
    barrier(d, cmd, (&b)[0..1]);
}

fn toAttachment(image: c.VkImage, from: c.VkImageLayout) c.VkImageMemoryBarrier2 {
    return .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
        // Waits for whatever last touched the image: the presentation engine's read (ordered
        // by the acquire semaphore, signalled at this stage) or an earlier pass.
        .srcStageMask = c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
        .srcAccessMask = 0,
        .dstStageMask = c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
        .dstAccessMask = c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT | c.VK_ACCESS_2_COLOR_ATTACHMENT_READ_BIT,
        .oldLayout = from,
        .newLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = color_range,
    };
}

pub fn barrier(d: *const Device, cmd: c.VkCommandBuffer, images: []const c.VkImageMemoryBarrier2) void {
    d.fns.vkCmdPipelineBarrier2.?(cmd, &.{
        .sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
        .imageMemoryBarrierCount = @intCast(images.len),
        .pImageMemoryBarriers = images.ptr,
    });
}

const testing = std.testing;
const host = @import("host.zig");

test "pass: dynamic rendering clears an offscreen image and the pixels read back" {
    var h: host.Host = undefined;
    try h.init();
    defer h.deinit();
    var target = try host.Target.init(&h.device, 16, 8, 1);
    defer target.deinit(&h.device);
    const cmd = try h.once.begin(&h.device);
    begin(&h.device, cmd, .{ .image = target.image.handle, .view = target.image.view, .extent = target.image.extent, .clear = .{ 1, 0.5, 0, 1 } });
    end(&h.device, cmd, .{ .image = target.image.handle, .layout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL });
    try h.once.submit(&h.device);
    var px: [16 * 8 * 4]u8 = undefined;
    try h.readback(target.image.handle, target.image.extent, &px);
    for (0..16 * 8) |i| try testing.expectEqualSlices(u8, &.{ 255, 128, 0, 255 }, px[i * 4 ..][0..4]);
}
