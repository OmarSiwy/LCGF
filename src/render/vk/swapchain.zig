//! The WSI swapchain: images the presentation engine shows, over the host's surface. The shell
//! creates the surface (it knows the window system); this only reads its capabilities.
//!
//! Choices, all fixed so behaviour does not vary by machine:
//!   format   B8G8R8A8_UNORM, else R8G8B8A8_UNORM, else the first offered, all with sRGB
//!            non-linear colour space. UNORM, not SRGB: the quad shader writes the same encoded
//!            values every other back end writes (the goldens are rgba8unorm).
//!   present  FIFO, the one mode every implementation has; it waits for vblank, so a frame
//!            loop that blocks in present does no extra work.
//!   images   minImageCount + 1, at most `max_images`, at most maxImageCount.
//!   usage    colour attachment, plus transfer source when offered (screenshots, tests).
//!
//! For tests and headless hosts, `headlessSurface` makes a VK_EXT_headless_surface surface.

const std = @import("std");
const loader = @import("loader.zig");
const device_mod = @import("device.zig");
const c = loader.c;
const Error = loader.Error;
const check = loader.check;
const Device = device_mod.Device;

pub const max_images = 8;

/// The instance extensions a headless host enables.
pub const headless_extensions = [_][*:0]const u8{ "VK_KHR_surface", "VK_EXT_headless_surface" };

pub fn headlessSurface(instance: *const loader.Instance) Error!c.VkSurfaceKHR {
    const create = instance.proc(c.PFN_vkCreateHeadlessSurfaceEXT, "vkCreateHeadlessSurfaceEXT") orelse return error.MissingExtension;
    var surface: c.VkSurfaceKHR = null;
    try check(create(instance.handle, &.{ .sType = c.VK_STRUCTURE_TYPE_HEADLESS_SURFACE_CREATE_INFO_EXT }, null, &surface));
    return surface;
}

pub fn destroySurface(instance: *const loader.Instance, surface: c.VkSurfaceKHR) void {
    instance.surface.?.vkDestroySurfaceKHR.?(instance.handle, surface, null);
}

pub const Swapchain = struct {
    handle: c.VkSwapchainKHR,
    format: c.VkFormat,
    extent: c.VkExtent2D,
    usage: c.VkImageUsageFlags,
    images: [max_images]c.VkImage = @splat(null),
    views: [max_images]c.VkImageView = @splat(null),
    len: u32 = 0,

    /// A swapchain over `surface` at `want` when the surface leaves the size to the swapchain
    /// (Wayland, headless), else at the surface's size. `old` (or null) is retired by the new
    /// one; the caller destroys it after.
    pub fn init(instance: *const loader.Instance, d: *const Device, surface: c.VkSurfaceKHR, want: c.VkExtent2D, old: c.VkSwapchainKHR) Error!Swapchain {
        const sf = instance.surface orelse return error.MissingExtension;
        const sc = d.swapchain orelse return error.MissingExtension;
        var caps: c.VkSurfaceCapabilitiesKHR = undefined;
        try check(sf.vkGetPhysicalDeviceSurfaceCapabilitiesKHR.?(d.physical, surface, &caps));
        var formats: [64]c.VkSurfaceFormatKHR = undefined;
        var n: u32 = formats.len;
        try check(sf.vkGetPhysicalDeviceSurfaceFormatsKHR.?(d.physical, surface, &n, &formats));
        if (n == 0) return error.Unknown;
        const format = chooseFormat(formats[0..n]);
        const extent = chooseExtent(caps, want);
        var count = @min(caps.minImageCount + 1, max_images);
        if (caps.maxImageCount != 0) count = @min(count, caps.maxImageCount);
        const usage: c.VkImageUsageFlags = @as(c.VkImageUsageFlags, c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT) | (caps.supportedUsageFlags & c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
        const opaque_alpha: c.VkCompositeAlphaFlagBitsKHR = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
        const alpha: c.VkCompositeAlphaFlagBitsKHR = if (caps.supportedCompositeAlpha & opaque_alpha != 0)
            opaque_alpha
        else
            caps.supportedCompositeAlpha & (~caps.supportedCompositeAlpha +% 1); // lowest offered bit

        var s: Swapchain = .{ .handle = null, .format = format.format, .extent = extent, .usage = usage };
        try check(sc.vkCreateSwapchainKHR.?(d.handle, &.{
            .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .surface = surface,
            .minImageCount = count,
            .imageFormat = format.format,
            .imageColorSpace = format.colorSpace,
            .imageExtent = extent,
            .imageArrayLayers = 1,
            .imageUsage = usage,
            .imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .preTransform = caps.currentTransform,
            .compositeAlpha = alpha,
            .presentMode = c.VK_PRESENT_MODE_FIFO_KHR,
            .clipped = c.VK_TRUE,
            .oldSwapchain = old,
        }, null, &s.handle));
        errdefer s.deinit(d);
        var len: u32 = max_images;
        try check(sc.vkGetSwapchainImagesKHR.?(d.handle, s.handle, &len, &s.images));
        for (s.images[0..len], s.views[0..len]) |img, *view| {
            try check(d.fns.vkCreateImageView.?(d.handle, &.{
                .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .image = img,
                .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
                .format = format.format,
                .subresourceRange = color_range,
            }, null, view));
            s.len += 1;
        }
        return s;
    }

    pub fn deinit(s: *Swapchain, d: *const Device) void {
        for (s.views[0..s.len]) |v| d.fns.vkDestroyImageView.?(d.handle, v, null);
        if (s.handle != null) d.swapchain.?.vkDestroySwapchainKHR.?(d.handle, s.handle, null);
        s.len = 0;
        s.handle = null;
    }
};

pub const color_range: c.VkImageSubresourceRange = .{
    .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
    .levelCount = 1,
    .layerCount = 1,
};

fn chooseFormat(formats: []const c.VkSurfaceFormatKHR) c.VkSurfaceFormatKHR {
    for ([_]c.VkFormat{ c.VK_FORMAT_B8G8R8A8_UNORM, c.VK_FORMAT_R8G8B8A8_UNORM }) |want| {
        for (formats) |f| if (f.format == want and f.colorSpace == c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) return f;
    }
    return formats[0];
}

/// 0xffff_ffff in currentExtent means the swapchain decides the size.
fn chooseExtent(caps: c.VkSurfaceCapabilitiesKHR, want: c.VkExtent2D) c.VkExtent2D {
    if (caps.currentExtent.width != 0xffff_ffff) return caps.currentExtent;
    return .{
        .width = std.math.clamp(want.width, caps.minImageExtent.width, caps.maxImageExtent.width),
        .height = std.math.clamp(want.height, caps.minImageExtent.height, caps.maxImageExtent.height),
    };
}

const testing = std.testing;

/// Instance, headless surface and presenting device, for tests.
pub const TestHost = struct {
    lib: loader.Library,
    instance: loader.Instance,
    surface: c.VkSurfaceKHR,
    device: Device,

    pub fn init(h: *TestHost) !void {
        h.lib = try loader.Library.open();
        errdefer h.lib.close();
        h.instance = try loader.Instance.init(&h.lib, .{ .extensions = &headless_extensions });
        errdefer h.instance.deinit();
        h.surface = try headlessSurface(&h.instance);
        errdefer destroySurface(&h.instance, h.surface);
        h.device = try Device.init(&h.instance, try device_mod.pick(&h.instance, h.surface), true);
    }

    pub fn deinit(h: *TestHost) void {
        h.device.deinit();
        destroySurface(&h.instance, h.surface);
        h.instance.deinit();
        h.lib.close();
    }
};

test "swapchain: a headless surface gets a FIFO swapchain at the requested size" {
    var h: TestHost = undefined;
    try h.init();
    defer h.deinit();
    var s = try Swapchain.init(&h.instance, &h.device, h.surface, .{ .width = 160, .height = 120 }, null);
    defer s.deinit(&h.device);
    try testing.expectEqual(@as(u32, 160), s.extent.width);
    try testing.expectEqual(@as(u32, 120), s.extent.height);
    try testing.expect(s.len >= 2 and s.len <= max_images);
    try testing.expect(s.format == c.VK_FORMAT_B8G8R8A8_UNORM or s.format == c.VK_FORMAT_R8G8B8A8_UNORM);
    for (s.views[0..s.len]) |v| try testing.expect(v != null);

    // A new swapchain retires the old one; the old one is destroyed after.
    var next = try Swapchain.init(&h.instance, &h.device, h.surface, .{ .width = 200, .height = 150 }, s.handle);
    defer next.deinit(&h.device);
    s.deinit(&h.device);
    try testing.expectEqual(@as(u32, 200), next.extent.width);
}

test "swapchain: format and extent choice" {
    const offered = [_]c.VkSurfaceFormatKHR{
        .{ .format = c.VK_FORMAT_B8G8R8A8_SRGB, .colorSpace = c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR },
        .{ .format = c.VK_FORMAT_R8G8B8A8_UNORM, .colorSpace = c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR },
    };
    try testing.expectEqual(@as(c.VkFormat, c.VK_FORMAT_R8G8B8A8_UNORM), chooseFormat(&offered).format);
    try testing.expectEqual(@as(c.VkFormat, c.VK_FORMAT_B8G8R8A8_SRGB), chooseFormat(offered[0..1]).format);
    var caps: c.VkSurfaceCapabilitiesKHR = std.mem.zeroes(c.VkSurfaceCapabilitiesKHR);
    caps.currentExtent = .{ .width = 0xffff_ffff, .height = 0xffff_ffff };
    caps.minImageExtent = .{ .width = 1, .height = 1 };
    caps.maxImageExtent = .{ .width = 100, .height = 100 };
    try testing.expectEqual(@as(u32, 100), chooseExtent(caps, .{ .width = 300, .height = 50 }).width);
    caps.currentExtent = .{ .width = 640, .height = 480 };
    try testing.expectEqual(@as(u32, 640), chooseExtent(caps, .{ .width = 300, .height = 50 }).width);
}
