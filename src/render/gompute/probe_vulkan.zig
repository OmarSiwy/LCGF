//! Cost of presenting through Vulkan external memory (vulkan.zig) against reading back
//! (probe.zig `readback`), on CUDA device 0 and the NVIDIA Vulkan driver:
//!
//!     VK_ICD_FILENAMES=.../nvidia_icd.json gompute-vk-probe
//!
//! Per size: the median of 50 hand-overs of a cleared frame, from the GPU being done with the
//! kernels to the frame being in a Vulkan image ready to sample (copy recorded, submitted, waited).
const std = @import("std");
const vk = @import("vk");
const gc = @import("gompute.zig");
const vulkan = @import("vulkan.zig");
const c = vk.c;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var buf: [256]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &buf);
    const w = &out.interface;

    var h: vk.host.Host = undefined;
    h.lib = try vk.loader.Library.open();
    defer h.lib.close();
    h.instance = try vk.loader.Instance.init(&h.lib, .{});
    defer h.instance.deinit();
    h.device = try vulkan.device(&h.instance);
    defer h.device.deinit();
    h.once = try vk.host.Once.init(&h.device);
    defer h.once.deinit(&h.device);
    const d = &h.device;
    try w.print("vulkan device: {s}\n", .{d.name()});

    var probe = try gc.Device(.cuda).init(0, .{ .width = 1, .height = 1, .stride = 1, .quads = 1, .images = 1, .texels = 1 });
    defer probe.deinit();
    for ([_][2]u32{ .{ 800, 600 }, .{ 1920, 1080 }, .{ 3840, 2160 } }) |size| {
        var shared = try vulkan.Shared.init(d, &h.instance, @as(u64, size[0]) * size[1] * 4);
        defer shared.deinit(d);
        var dev = try gc.Device(.cuda).init(0, .{ .width = size[0], .height = size[1], .stride = size[0], .quads = 1, .images = 1, .texels = 1, .framebuffer = shared.address });
        defer dev.deinit();
        var image = try d.createImage(.{ .width = size[0], .height = size[1], .usage = c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT });
        defer d.destroyImage(&image);
        var layout: c.VkImageLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        var times: [50]u64 = undefined;
        for (&times) |*ns| {
            try dev.clear(0xff00_00ff);
            try dev.synchronize();
            const t0 = std.Io.Timestamp.now(io, .awake);
            const cmd = try h.once.begin(d);
            shared.copyToImage(d, cmd, image.handle, layout, size[0], size[1]);
            try h.once.submit(d);
            layout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
            ns.* = @intCast(t0.durationTo(std.Io.Timestamp.now(io, .awake)).toNanoseconds());
        }
        std.mem.sort(u64, &times, {}, std.sort.asc(u64));
        try w.print("vulkan hand-over {d}x{d}: {d} us\n", .{ size[0], size[1], times[times.len / 2] / 1000 });
        try w.flush();
    }
}
