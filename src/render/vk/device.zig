//! Physical device selection and the logical device with one graphics queue.
//!
//! A device qualifies when it supports Vulkan 1.3 with dynamicRendering and synchronization2,
//! has a queue family with graphics (and, given a surface, present support on that family),
//! and, given a surface, VK_KHR_swapchain. Among those the kind decides: discrete, then
//! integrated, virtual, CPU (lavapipe), other; ties keep enumeration order. One family does
//! both graphics and present: every implementation this targets has one, and it avoids
//! queue-ownership transfers.

const std = @import("std");
const loader = @import("loader.zig");
const c = loader.c;
const Error = loader.Error;
const check = loader.check;

pub const Pick = struct {
    physical: c.VkPhysicalDevice,
    family: u32,
    props: c.VkPhysicalDeviceProperties,
};

/// Higher is better; 0 never wins over a qualifying device.
fn kindRank(t: c.VkPhysicalDeviceType) u32 {
    return switch (t) {
        c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU => 5,
        c.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU => 4,
        c.VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU => 3,
        c.VK_PHYSICAL_DEVICE_TYPE_CPU => 2,
        else => 1,
    };
}

/// The best device for drawing (and presenting to `surface`, when given), or error.NoDevice.
pub fn pick(instance: *const loader.Instance, surface: c.VkSurfaceKHR) (Error || error{NoDevice})!Pick {
    const f = &instance.fns;
    var devices: [16]c.VkPhysicalDevice = undefined;
    var n: u32 = devices.len;
    try check(f.vkEnumeratePhysicalDevices.?(instance.handle, &n, &devices));
    var best: ?Pick = null;
    var best_rank: u32 = 0;
    for (devices[0..n]) |pd| {
        var props: c.VkPhysicalDeviceProperties = undefined;
        f.vkGetPhysicalDeviceProperties.?(pd, &props);
        if (props.apiVersion < loader.api_version) continue;
        var f13: c.VkPhysicalDeviceVulkan13Features = .{ .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES };
        var f2: c.VkPhysicalDeviceFeatures2 = .{ .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &f13 };
        f.vkGetPhysicalDeviceFeatures2.?(pd, &f2);
        if (f13.dynamicRendering == 0 or f13.synchronization2 == 0) continue;
        if (surface != null and !hasDeviceExtension(instance, pd, "VK_KHR_swapchain")) continue;
        const family = graphicsFamily(instance, pd, surface) orelse continue;
        const rank = kindRank(props.deviceType);
        if (rank > best_rank) {
            best = .{ .physical = pd, .family = family, .props = props };
            best_rank = rank;
        }
    }
    return best orelse error.NoDevice;
}

fn graphicsFamily(instance: *const loader.Instance, pd: c.VkPhysicalDevice, surface: c.VkSurfaceKHR) ?u32 {
    var families: [16]c.VkQueueFamilyProperties = undefined;
    var n: u32 = families.len;
    instance.fns.vkGetPhysicalDeviceQueueFamilyProperties.?(pd, &n, &families);
    for (families[0..n], 0..) |fam, i| {
        if (fam.queueFlags & c.VK_QUEUE_GRAPHICS_BIT == 0) continue;
        if (surface != null) {
            const sf = instance.surface orelse return null;
            var present: c.VkBool32 = 0;
            if (sf.vkGetPhysicalDeviceSurfaceSupportKHR.?(pd, @intCast(i), surface, &present) != c.VK_SUCCESS or present == 0) continue;
        }
        return @intCast(i);
    }
    return null;
}

fn hasDeviceExtension(instance: *const loader.Instance, pd: c.VkPhysicalDevice, name: []const u8) bool {
    var props: [512]c.VkExtensionProperties = undefined;
    var n: u32 = props.len;
    _ = instance.fns.vkEnumerateDeviceExtensionProperties.?(pd, null, &n, &props);
    return loader.hasName(props[0..n], name);
}

/// Device-level functions this back end calls.
pub const DeviceFns = struct {
    vkDestroyDevice: c.PFN_vkDestroyDevice,
    vkGetDeviceQueue: c.PFN_vkGetDeviceQueue,
    vkDeviceWaitIdle: c.PFN_vkDeviceWaitIdle,
    vkQueueSubmit2: c.PFN_vkQueueSubmit2,
    vkQueueWaitIdle: c.PFN_vkQueueWaitIdle,
    vkCreateCommandPool: c.PFN_vkCreateCommandPool,
    vkDestroyCommandPool: c.PFN_vkDestroyCommandPool,
    vkResetCommandPool: c.PFN_vkResetCommandPool,
    vkAllocateCommandBuffers: c.PFN_vkAllocateCommandBuffers,
    vkBeginCommandBuffer: c.PFN_vkBeginCommandBuffer,
    vkEndCommandBuffer: c.PFN_vkEndCommandBuffer,
    vkCreateFence: c.PFN_vkCreateFence,
    vkDestroyFence: c.PFN_vkDestroyFence,
    vkWaitForFences: c.PFN_vkWaitForFences,
    vkResetFences: c.PFN_vkResetFences,
    vkCreateSemaphore: c.PFN_vkCreateSemaphore,
    vkDestroySemaphore: c.PFN_vkDestroySemaphore,
    vkCreateBuffer: c.PFN_vkCreateBuffer,
    vkDestroyBuffer: c.PFN_vkDestroyBuffer,
    vkGetBufferMemoryRequirements: c.PFN_vkGetBufferMemoryRequirements,
    vkBindBufferMemory: c.PFN_vkBindBufferMemory,
    vkCreateImage: c.PFN_vkCreateImage,
    vkDestroyImage: c.PFN_vkDestroyImage,
    vkGetImageMemoryRequirements: c.PFN_vkGetImageMemoryRequirements,
    vkBindImageMemory: c.PFN_vkBindImageMemory,
    vkCreateImageView: c.PFN_vkCreateImageView,
    vkDestroyImageView: c.PFN_vkDestroyImageView,
    vkCreateSampler: c.PFN_vkCreateSampler,
    vkDestroySampler: c.PFN_vkDestroySampler,
    vkAllocateMemory: c.PFN_vkAllocateMemory,
    vkFreeMemory: c.PFN_vkFreeMemory,
    vkMapMemory: c.PFN_vkMapMemory,
    vkUnmapMemory: c.PFN_vkUnmapMemory,
    vkCreateShaderModule: c.PFN_vkCreateShaderModule,
    vkDestroyShaderModule: c.PFN_vkDestroyShaderModule,
    vkCreatePipelineLayout: c.PFN_vkCreatePipelineLayout,
    vkDestroyPipelineLayout: c.PFN_vkDestroyPipelineLayout,
    vkCreateGraphicsPipelines: c.PFN_vkCreateGraphicsPipelines,
    vkDestroyPipeline: c.PFN_vkDestroyPipeline,
    vkCreateDescriptorSetLayout: c.PFN_vkCreateDescriptorSetLayout,
    vkDestroyDescriptorSetLayout: c.PFN_vkDestroyDescriptorSetLayout,
    vkCreateDescriptorPool: c.PFN_vkCreateDescriptorPool,
    vkDestroyDescriptorPool: c.PFN_vkDestroyDescriptorPool,
    vkAllocateDescriptorSets: c.PFN_vkAllocateDescriptorSets,
    vkUpdateDescriptorSets: c.PFN_vkUpdateDescriptorSets,
    vkCmdPipelineBarrier2: c.PFN_vkCmdPipelineBarrier2,
    vkCmdBeginRendering: c.PFN_vkCmdBeginRendering,
    vkCmdEndRendering: c.PFN_vkCmdEndRendering,
    vkCmdCopyImageToBuffer: c.PFN_vkCmdCopyImageToBuffer,
    vkCmdCopyBufferToImage: c.PFN_vkCmdCopyBufferToImage,
    vkCmdBindPipeline: c.PFN_vkCmdBindPipeline,
    vkCmdBindDescriptorSets: c.PFN_vkCmdBindDescriptorSets,
    vkCmdBindVertexBuffers: c.PFN_vkCmdBindVertexBuffers,
    vkCmdSetViewport: c.PFN_vkCmdSetViewport,
    vkCmdSetScissor: c.PFN_vkCmdSetScissor,
    vkCmdPushConstants: c.PFN_vkCmdPushConstants,
    vkCmdDraw: c.PFN_vkCmdDraw,
};

/// Swapchain functions, loaded when the device was created for a surface.
pub const SwapchainFns = struct {
    vkCreateSwapchainKHR: c.PFN_vkCreateSwapchainKHR,
    vkDestroySwapchainKHR: c.PFN_vkDestroySwapchainKHR,
    vkGetSwapchainImagesKHR: c.PFN_vkGetSwapchainImagesKHR,
    vkAcquireNextImageKHR: c.PFN_vkAcquireNextImageKHR,
    vkQueuePresentKHR: c.PFN_vkQueuePresentKHR,
};

pub const Device = struct {
    handle: c.VkDevice,
    physical: c.VkPhysicalDevice,
    family: u32,
    queue: c.VkQueue,
    props: c.VkPhysicalDeviceProperties,
    memory: c.VkPhysicalDeviceMemoryProperties,
    fns: DeviceFns,
    /// Null for a device created without a surface.
    swapchain: ?SwapchainFns,

    /// One queue from `p.family`; VK_KHR_swapchain when `presents`.
    pub fn init(instance: *const loader.Instance, p: Pick, presents: bool) Error!Device {
        const priority: f32 = 1;
        const queue_info: c.VkDeviceQueueCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .queueFamilyIndex = p.family,
            .queueCount = 1,
            .pQueuePriorities = &priority,
        };
        var f13: c.VkPhysicalDeviceVulkan13Features = .{
            .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
            .dynamicRendering = c.VK_TRUE,
            .synchronization2 = c.VK_TRUE,
        };
        const extensions = [_][*:0]const u8{"VK_KHR_swapchain"};
        var handle: c.VkDevice = null;
        try check(instance.fns.vkCreateDevice.?(p.physical, &.{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pNext = &f13,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &queue_info,
            .enabledExtensionCount = @intFromBool(presents),
            .ppEnabledExtensionNames = &extensions,
        }, null, &handle));
        const get = instance.fns.vkGetDeviceProcAddr;
        const fns = load(DeviceFns, get, handle) catch |e| {
            if (@as(c.PFN_vkDestroyDevice, @ptrCast(get.?(handle, "vkDestroyDevice")))) |destroy| destroy(handle, null);
            return e;
        };
        var queue: c.VkQueue = null;
        fns.vkGetDeviceQueue.?(handle, p.family, 0, &queue);
        var memory: c.VkPhysicalDeviceMemoryProperties = undefined;
        instance.fns.vkGetPhysicalDeviceMemoryProperties.?(p.physical, &memory);
        return .{
            .handle = handle,
            .physical = p.physical,
            .family = p.family,
            .queue = queue,
            .props = p.props,
            .memory = memory,
            .fns = fns,
            .swapchain = if (presents) load(SwapchainFns, get, handle) catch null else null,
        };
    }

    pub fn deinit(d: *Device) void {
        d.fns.vkDestroyDevice.?(d.handle, null);
    }

    /// The first memory type allowed by `type_bits` with all of `flags`, or null.
    pub fn memoryType(d: *const Device, type_bits: u32, flags: c.VkMemoryPropertyFlags) ?u32 {
        for (0..d.memory.memoryTypeCount) |i| {
            const allowed = (type_bits >> @intCast(i)) & 1 != 0;
            if (allowed and d.memory.memoryTypes[i].propertyFlags & flags == flags) return @intCast(i);
        }
        return null;
    }

    /// The device name from its properties ("llvmpipe (LLVM ...)" on lavapipe).
    pub fn name(d: *const Device) []const u8 {
        return std.mem.sliceTo(&d.props.deviceName, 0);
    }
};

const load = loader.load;

const testing = std.testing;

test "device: picks a Vulkan 1.3 device with a graphics queue and creates it" {
    var lib = try loader.Library.open();
    defer lib.close();
    var instance = try loader.Instance.init(&lib, .{});
    defer instance.deinit();
    const p = try pick(&instance, null);
    try testing.expect(p.props.apiVersion >= loader.api_version);
    var d = try Device.init(&instance, p, false);
    defer d.deinit();
    try testing.expect(d.queue != null);
    try testing.expect(d.swapchain == null);
    try testing.expect(d.name().len > 0);
    // Host-visible coherent memory exists on every implementation (the spec requires it).
    try testing.expect(d.memoryType(0xffff_ffff, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) != null);
    try testing.expectEqual(null, d.memoryType(0, 0));
    try check(d.fns.vkDeviceWaitIdle.?(d.handle));
}

test "device: kinds rank discrete over integrated over CPU" {
    try testing.expect(kindRank(c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) > kindRank(c.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU));
    try testing.expect(kindRank(c.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU) > kindRank(c.VK_PHYSICAL_DEVICE_TYPE_CPU));
    try testing.expect(kindRank(c.VK_PHYSICAL_DEVICE_TYPE_OTHER) > 0);
}
