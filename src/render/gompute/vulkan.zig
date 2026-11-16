//! Presenting the Gompute back end's frames through Vulkan external memory, where the driver has
//! it (CUDA programming guide, Vulkan interoperability): Vulkan allocates the framebuffer with an
//! exportable POSIX file descriptor (VK_KHR_external_memory_fd), CUDA imports it
//! (cuImportExternalMemory) and maps it as a device buffer the kernels draw into, and Vulkan copies
//! it into an image: a texture the Vulkan back end samples (route 3 of src/render/iface.zig), or
//! the source of a copy to a swapchain image. No pixel crosses to the host.
//!
//! Built over the Vulkan back end's public device code (src/render/vk/), whose `Device.init`
//! enables no external-memory extension, so `device` here creates the `vk.device.Device` itself
//! with the one extra extension. Linux only (POSIX descriptors; Windows would use the
//! VK_KHR_external_memory_win32 handle the same way).
//!
//! Synchronisation is the simple kind: the host waits for CUDA before submitting the copy and
//! for the copy before the next frame. External semaphores would let the two queues overlap.

const std = @import("std");
const g = @import("gompute");
const vk = @import("vk");
const c = vk.c;
const check = vk.loader.check;

/// The CUDA driver calls the import needs, which Gompute's runtime does not load.
const Cuda = struct {
    cuImportExternalMemory: *const fn (*?*anyopaque, *const HandleDesc) callconv(.c) c_int,
    cuExternalMemoryGetMappedBuffer: *const fn (*u64, ?*anyopaque, *const BufferDesc) callconv(.c) c_int,
    cuDestroyExternalMemory: *const fn (?*anyopaque) callconv(.c) c_int,
    cuMemFree_v2: *const fn (u64) callconv(.c) c_int,

    /// CUDA_EXTERNAL_MEMORY_HANDLE_DESC (cuda.h).
    const HandleDesc = extern struct {
        type: c_uint,
        handle: extern union { fd: c_int, win32: extern struct { handle: ?*anyopaque, name: ?*const anyopaque } },
        size: u64,
        flags: c_uint = 0,
        reserved: [16]c_uint = @splat(0),
    };
    /// CUDA_EXTERNAL_MEMORY_BUFFER_DESC.
    const BufferDesc = extern struct { offset: u64, size: u64, flags: c_uint = 0, reserved: [16]c_uint = @splat(0) };
    const handle_type_opaque_fd = 1;

    /// libcuda is already open (Gompute opened it); this takes another reference.
    fn open() !Cuda {
        var lib = std.DynLib.open("libcuda.so.1") catch return error.NoCuda;
        var t: Cuda = undefined;
        inline for (@typeInfo(Cuda).@"struct".field_names) |name| {
            @field(t, name) = lib.lookup(@FieldType(Cuda, name), name) orelse return error.NoCuda;
        }
        return t;
    }
};

/// A Vulkan device on the GPU the kernels run on, with VK_KHR_external_memory_fd: what
/// `vk.device.Device.init` builds, plus the extension. Offscreen (no swapchain extension).
pub fn device(instance: *const vk.loader.Instance) !vk.device.Device {
    // ponytail: takes the device `pick` prefers (the discrete GPU); matching CUDA's device by
    // UUID (VkPhysicalDeviceIDProperties against cuDeviceGetUuid) is needed on a machine with two.
    const p = try vk.device.pick(instance, null);
    const priority: f32 = 1;
    var f13: c.VkPhysicalDeviceVulkan13Features = .{
        .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
        .dynamicRendering = c.VK_TRUE,
        .synchronization2 = c.VK_TRUE,
    };
    const extensions = [_][*:0]const u8{"VK_KHR_external_memory_fd"};
    var handle: c.VkDevice = null;
    try check(instance.fns.vkCreateDevice.?(p.physical, &.{
        .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = &f13,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &.{ .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = p.family, .queueCount = 1, .pQueuePriorities = &priority },
        .enabledExtensionCount = extensions.len,
        .ppEnabledExtensionNames = &extensions,
    }, null, &handle));
    const fns = vk.loader.load(vk.device.DeviceFns, instance.fns.vkGetDeviceProcAddr, handle) catch |e| {
        if (@as(c.PFN_vkDestroyDevice, @ptrCast(instance.fns.vkGetDeviceProcAddr.?(handle, "vkDestroyDevice")))) |destroy| destroy(handle, null);
        return e;
    };
    var queue: c.VkQueue = null;
    fns.vkGetDeviceQueue.?(handle, p.family, 0, &queue);
    var memory: c.VkPhysicalDeviceMemoryProperties = undefined;
    instance.fns.vkGetPhysicalDeviceMemoryProperties.?(p.physical, &memory);
    return .{ .handle = handle, .physical = p.physical, .family = p.family, .queue = queue, .props = p.props, .memory = memory, .fns = fns, .swapchain = null };
}

/// A framebuffer both APIs see: a device-local Vulkan buffer exported to CUDA. `address` goes to
/// `gompute.Device` as `Capacity.framebuffer`; `buffer` is what Vulkan copies from.
pub const Shared = struct {
    buffer: c.VkBuffer,
    memory: c.VkDeviceMemory,
    size: u64,
    external: ?*anyopaque,
    /// The CUDA device address of the buffer.
    address: u64,
    cuda: Cuda,

    /// `size` bytes, exported by Vulkan and imported into CUDA's current context (a
    /// `gompute.Device` on the same GPU must exist).
    pub fn init(d: *const vk.device.Device, instance: *const vk.loader.Instance, size: u64) !Shared {
        const cuda = try Cuda.open();
        const get_fd: c.PFN_vkGetMemoryFdKHR = @ptrCast(instance.fns.vkGetDeviceProcAddr.?(d.handle, "vkGetMemoryFdKHR"));
        var s: Shared = .{ .buffer = null, .memory = null, .size = size, .external = null, .address = 0, .cuda = cuda };
        const external_info: c.VkExternalMemoryBufferCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO,
            .handleTypes = c.VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT,
        };
        try check(d.fns.vkCreateBuffer.?(d.handle, &.{
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .pNext = &external_info,
            .size = size,
            .usage = c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        }, null, &s.buffer));
        errdefer d.fns.vkDestroyBuffer.?(d.handle, s.buffer, null);
        var req: c.VkMemoryRequirements = undefined;
        d.fns.vkGetBufferMemoryRequirements.?(d.handle, s.buffer, &req);
        const export_info: c.VkExportMemoryAllocateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO,
            .handleTypes = c.VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT,
        };
        try check(d.fns.vkAllocateMemory.?(d.handle, &.{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = &export_info,
            .allocationSize = req.size,
            .memoryTypeIndex = d.memoryType(req.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) orelse return error.OutOfMemory,
        }, null, &s.memory));
        errdefer d.fns.vkFreeMemory.?(d.handle, s.memory, null);
        try check(d.fns.vkBindBufferMemory.?(d.handle, s.buffer, s.memory, 0));

        var fd: c_int = -1;
        try check((get_fd orelse return error.MissingFunction)(d.handle, &.{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR,
            .memory = s.memory,
            .handleType = c.VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT,
        }, &fd));
        // On success CUDA owns the descriptor; on failure it is still ours to close.
        if (cuda.cuImportExternalMemory(&s.external, &.{ .type = Cuda.handle_type_opaque_fd, .handle = .{ .fd = fd }, .size = req.size }) != 0) {
            _ = std.c.close(fd);
            return error.ImportFailed;
        }
        errdefer _ = cuda.cuDestroyExternalMemory(s.external);
        if (cuda.cuExternalMemoryGetMappedBuffer(&s.address, s.external, &.{ .offset = 0, .size = size }) != 0) return error.ImportFailed;
        return s;
    }

    pub fn deinit(s: *Shared, d: *const vk.device.Device) void {
        _ = s.cuda.cuMemFree_v2(s.address); // a mapped buffer is freed like an allocation
        _ = s.cuda.cuDestroyExternalMemory(s.external);
        d.fns.vkDestroyBuffer.?(d.handle, s.buffer, null);
        d.fns.vkFreeMemory.?(d.handle, s.memory, null);
    }

    /// Records the copy of the shared framebuffer (`width` x `height`, rows packed) into
    /// `image`, which ends in SHADER_READ_ONLY_OPTIMAL for the Vulkan back end to sample. The
    /// host must have waited for CUDA (`gompute.Device.synchronize`) before submitting it.
    pub fn copyToImage(s: *const Shared, d: *const vk.device.Device, cmd: c.VkCommandBuffer, image: c.VkImage, from: c.VkImageLayout, width: u32, height: u32) void {
        vk.host.uploadRegion(d, cmd, image, s.buffer, 0, from, .{ .w = width, .h = height });
    }
};

const testing = std.testing;
const lcgr = @import("lcgr");
const gc = @import("gompute.zig");
const conformance = lcgr.render_conformance;
const iface = lcgr.render_iface;

/// The Vulkan host of these tests on the external-memory device, or null without one.
fn host(h: *vk.host.Host) !bool {
    h.lib = vk.loader.Library.open() catch return false;
    errdefer h.lib.close();
    h.instance = try vk.loader.Instance.init(&h.lib, .{});
    errdefer h.instance.deinit();
    h.device = device(&h.instance) catch |err| switch (err) {
        error.NoDevice, error.MissingExtension => {
            h.instance.deinit();
            h.lib.close();
            return false;
        },
        else => return err,
    };
    errdefer h.device.deinit();
    h.once = try vk.host.Once.init(&h.device);
    return true;
}

test "vulkan: CUDA draws into Vulkan memory, Vulkan copies it into an image, the pixels are the CPU path's" {
    if (comptime !g.available(.cuda)) return;
    const w = 160;
    const h = 120;
    var dev_probe = gc.Device(.cuda).init(0, .{ .width = 1, .height = 1, .stride = 1, .quads = 1, .images = 1, .texels = 1 }) catch |err| switch (err) {
        error.InitFailed, error.NoDevice => return, // no CUDA here
        else => return err,
    };
    dev_probe.deinit();
    var vh: vk.host.Host = undefined;
    if (!try host(&vh)) return; // no Vulkan device with external memory
    defer vh.deinit();
    if (!std.mem.startsWith(u8, vh.device.name(), "NVIDIA")) return; // the export must come from the GPU CUDA runs on (not lavapipe)
    const d = &vh.device;

    var shared = try Shared.init(d, &vh.instance, w * h * 4);
    defer shared.deinit(d);
    const white = [_]gc.kernels.Image{.{ .first = 0, .width = 1, .height = 1 }};
    var dev = try gc.Device(.cuda).init(0, .{ .width = w, .height = h, .stride = w, .quads = 8, .images = 1, .texels = 1, .framebuffer = shared.address });
    defer dev.deinit();
    try dev.setImages(&white, &.{0xffff_ffff});
    var image = try d.createImage(.{ .width = w, .height = h, .usage = c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT });
    defer d.destroyImage(&image);

    var rq: [8]lcgr.draw_list.Quad = undefined;
    var rt: [8]u32 = undefined;
    var bin_idx: [gc.Bins.len(w, h, 4)]u32 = undefined;
    var bin_count: [gc.Bins.len(w, h, 1)]u32 = undefined;
    var cpu: [w * h]u32 = undefined;
    var got: [w * h * 4]u8 = undefined;
    for (conformance.scenes[0..2]) |*scene| { // rects and clip: no text, no custom draw
        var st: conformance.Storage = .{};
        st.load(scene);
        var b: gc.Gompute = .{};
        b.prepare({}, &st.draw, st.glyphs(), scene.viewport, 1);
        var rec: gc.Recorder = .{ .quads = &rq, .tex = &rt };
        iface.render(&b, &rec, &st.draw);
        gc.fillCpu(&cpu, 0xff00_0000);
        gc.rasterCpu(.{ .px = &cpu, .width = w, .height = h, .stride = w }, &rec, &white, &.{0xffff_ffff}, .{ .idx = &bin_idx, .count = &bin_count, .cap = 4 });

        try dev.clear(0xff00_0000);
        try dev.draw(&rec, 0, 1);
        try dev.synchronize();
        const cmd = try vh.once.begin(d);
        shared.copyToImage(d, cmd, image.handle, c.VK_IMAGE_LAYOUT_UNDEFINED, w, h);
        vk.pass.transition(d, cmd, image.handle, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL);
        try vh.once.submit(d);
        try vh.readback(image.handle, .{ .width = w, .height = h }, &got);
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&cpu), &got);
    }
}

test {
    std.testing.refAllDecls(Shared);
}
