//! Offscreen shared-device experiment. See docs/research/custom-webgpu/README.md.
const std = @import("std");
const lcgf = @import("lcgf");
const vk = @import("vk.zig");
const vc = vk.c;
const vhost = vk.host;
const pass = vk.pass;
const loader = vk.loader;
const native = @import("wgpu_native");
const whost = native.host;
const c = native.c;
const Drawing = @import("custom_draw_sample");
const conformance = lcgf.render_conformance;
const enabled = @import("custom_draw").enabled;
const Mode = enum { native, cached, guest, check, nohandoff };

const frames = 2000;
const W = 160;
const H = 120;

const NW = 56;
const NH = 56;

var st: [conformance.scenes.len]conformance.Storage = @splat(.{});

const Import = extern struct {
    gipa: vc.PFN_vkGetInstanceProcAddr,
    instance: vc.VkInstance,
    api_version: u32,
    physical: vc.VkPhysicalDevice,
    device: vc.VkDevice,
    family: u32,
    queue_index: u32,
    ext_count: usize,
    exts: [*]const [*:0]const u8,
};
const Requirements = extern struct {
    ext_count: usize,
    exts: [32][*:0]const u8,
    features: vc.VkPhysicalDeviceFeatures,
    timeline: u32,
    robust_image: u32,
};
extern fn wgpuVulkanDeviceRequirements(imp: *const Import, out: *Requirements) void;
extern fn wgpuCreateDeviceFromVulkan(imp: *const Import) c.WGPUDevice;
extern fn wgpuDeviceCreateTextureFromVkImage(device: c.WGPUDevice, image: vc.VkImage, desc: *const c.WGPUTextureDescriptor) c.WGPUTexture;
extern fn wgpuCommandEncoderTransitionTexture(encoder: c.WGPUCommandEncoder, texture: c.WGPUTexture, usage: c.WGPUTextureUsage) void;

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const mode = std.meta.stringToEnum(Mode, args.next() orelse "native") orelse return error.InvalidMode;
    if (!enabled and mode != .native) return error.CustomDrawingDisabled;
    const guest = enabled and mode != .native;
    const checking = mode == .check;

    // LCGR: instance, physical device, then a device with what wgpu needs added.
    var vh: vhost.Host = undefined;
    vh.lib = try loader.Library.open();
    vh.instance = try loader.Instance.init(&vh.lib, .{
        // The pinned HAL requests VK_KHR_swapchain even for this headless device.
        .extensions = if (guest) &.{"VK_KHR_surface"} else &.{},
    });
    const pick = try vk.device.pick(&vh.instance, null);
    var imp: Import = .{
        .gipa = vh.instance.getInstanceProcAddr,
        .instance = vh.instance.handle,
        .api_version = loader.api_version,
        .physical = pick.physical,
        .device = null,
        .family = pick.family,
        .queue_index = 0,
        .ext_count = 0,
        .exts = undefined,
    };
    var req: Requirements = undefined;
    vh.device = if (guest) blk: {
        wgpuVulkanDeviceRequirements(&imp, &req);
        break :blk try initGuestDevice(&vh.instance, pick, &req);
    } else try vk.device.Device.init(&vh.instance, pick, false);
    vh.once = try vhost.Once.init(&vh.device);
    defer vh.deinit();
    const d = &vh.device;
    const vsampler = try vhost.nearestSampler(d);
    defer d.fns.vkDestroySampler.?(d.handle, vsampler, null);
    var vwhite = try vh.sampled(1, 1, &.{ 0xff, 0xff, 0xff, 0xff });
    defer d.destroyImage(&vwhite);
    var vgfx = try vk.Renderer.init(d, .{ .format = vc.VK_FORMAT_R8G8B8A8_UNORM }, vwhite.view, vsampler);

    // The node's image: LCGR's, device-local, drawn by the app, sampled by LCGR.
    var node = try d.createImage(.{ .width = NW, .height = NH, .usage = vc.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | vc.VK_IMAGE_USAGE_SAMPLED_BIT });
    defer d.destroyImage(&node);
    var static_px: [NW * NH * 4]u8 = undefined;
    fill(&static_px, .{ 0x20, 0x60, 0xa0, 0xff });
    var static_img = try vh.sampled(NW, NH, &static_px);
    defer d.destroyImage(&static_img);
    defer vgfx.deinit(d);
    const node_tex = try vgfx.addTexture(d, if (guest) node.view else static_img.view, vsampler);
    for (&st, &conformance.scenes) |*s, *scene| {
        s.load(scene);
        @import("custom_draw_scene").addNode(&s.draw, node_tex);
    }

    // The app: a guest WGPUDevice on LCGR's VkDevice and queue.
    var h: whost.Host = .{ .instance = null, .adapter = null, .device = null, .queue = null };
    var tex: c.WGPUTexture = null;
    var tex_view: c.WGPUTextureView = null;
    var drawing: Drawing = undefined;
    defer if (guest) {
        _ = c.wgpuDevicePoll(h.device, 1, null);
        drawing.deinit();
        c.wgpuTextureViewRelease(tex_view);
        c.wgpuTextureRelease(tex);
        c.wgpuQueueRelease(h.queue);
        c.wgpuDeviceRelease(h.device);
    };
    if (guest) {
        imp.device = d.handle;
        imp.ext_count = req.ext_count;
        imp.exts = &req.exts;
        h.device = wgpuCreateDeviceFromVulkan(&imp);
        h.queue = c.wgpuDeviceGetQueue(h.device);
        tex = wgpuDeviceCreateTextureFromVkImage(h.device, node.handle, &.{
            .usage = c.WGPUTextureUsage_RenderAttachment | c.WGPUTextureUsage_TextureBinding,
            .dimension = c.WGPUTextureDimension_2D,
            .size = .{ .width = NW, .height = NH, .depthOrArrayLayers = 1 },
            .format = c.WGPUTextureFormat_RGBA8Unorm,
            .mipLevelCount = 1,
            .sampleCount = 1,
        });
        tex_view = c.wgpuTextureCreateView(tex, null);
        drawing = Drawing.init(h.device, h.queue, if (checking) NW else 64);
    }

    var target = try vhost.Target.init(d, W, H, 1);
    defer target.deinit(d);
    const colors = [_][4]u8{ .{ 0xff, 0, 0, 0xff }, .{ 0, 0xff, 0, 0xff }, .{ 0, 0, 0xff, 0xff }, .{ 0x80, 0x80, 0x80, 0xff } };
    var record_ns: u64 = 0;
    var frame_ns: u64 = 0;
    var app_ns: u64 = 0;
    var bad_total: usize = 0;
    var cpu0 = threadCpu();
    var redraws: usize = 0;
    const n_frames: usize = if (checking) colors.len + 2 else if (mode == .nohandoff) 1 else frames;
    const warmup: usize = @intFromBool(!checking and mode != .nohandoff);
    for (0..n_frames + warmup) |n| {
        if (n == warmup) cpu0 = threadCpu();
        const s = &st[n % st.len];
        const t0 = now();
        // In check mode the last frame reuses the patterned texture from the previous scene.
        const redraw = switch (mode) {
            .native => false,
            .cached => n == 0,
            .check => n <= colors.len,
            else => true,
        };
        if (guest and redraw) {
            redraws += @intFromBool(n >= warmup);
            // ---- the app's custom node: its own pass into the texture LCGR handed it ----
            const k: f32 = @floatFromInt(n % 7);
            const col = colors[n % colors.len];
            const enc = c.wgpuDeviceCreateCommandEncoder(h.device, null);
            const alpha: ?f32 = if (!checking) k / 7 else if (n == colors.len) 1 else null;
            drawing.draw(h.queue, enc, tex_view, col, alpha);
            // ---- LCGR closes it: hand-off transition, submit on the shared queue ----
            if (mode != .nohandoff) wgpuCommandEncoderTransitionTexture(enc, tex, c.WGPUTextureUsage_TextureBinding);
            h.submit(enc);
            _ = c.wgpuDevicePoll(h.device, 0, null);
        }
        const ta = now();
        // ---- LCGR's own frame, sampling the node ----
        vgfx.prepare(@intCast(n % 2), &s.draw, s.glyphs(), .{ W, H }, 1);
        const cmd = try vh.once.begin(d);
        pass.begin(d, cmd, target.begin(.{ 0, 0, 0, 1 }));
        vgfx.render(cmd, &s.draw);
        pass.end(d, cmd, .{ .image = target.image.handle, .layout = vc.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL });
        try vh.once.send(d);
        const t1 = now();
        try vh.once.wait(d);
        if (n < warmup) continue;
        app_ns += ta - t0;
        record_ns += t1 - t0;
        frame_ns += now() - t0;
        if (checking) {
            if (n >= colors.len) {
                for (0..NW * NH) |i| static_px[i * 4 ..][0..4].* = .{ @truncate(i), @truncate(i >> 6), 0x80, 0xff };
            } else fill(&static_px, colors[n]);
            bad_total += try compare(&vh, &vgfx, &target, s, &static_px, node.view, node_tex, vsampler);
        }
    }
    var line: [200]u8 = undefined;
    const msg = if (checking)
        try std.fmt.bufPrint(&line, "ready guest-check ({s}) frames={d} redraws={d} px_different={d}\n", .{ d.name(), n_frames, redraws, bad_total })
    else
        try std.fmt.bufPrint(&line, "ready {s} frames={d} redraws={d} cpu_us={d:.1} frame_us={d:.1} thread_us={d:.1} app_us={d:.1}\n", .{ @tagName(mode), n_frames, redraws, us(record_ns, n_frames), us(frame_ns, n_frames), us(threadCpu() - cpu0, n_frames), us(app_ns, n_frames) });
    _ = std.os.linux.write(1, msg.ptr, msg.len);
    if (bad_total != 0) return error.PixelMismatch;
}

fn initGuestDevice(instance: *const loader.Instance, pick: vk.device.Pick, req: *const Requirements) !vk.device.Device {
    var f12: vc.VkPhysicalDeviceVulkan12Features = .{
        .sType = vc.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
        .timelineSemaphore = req.timeline,
    };
    const priority: f32 = 1;
    const queue_info: vc.VkDeviceQueueCreateInfo = .{
        .sType = vc.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = pick.family,
        .queueCount = 1,
        .pQueuePriorities = &priority,
    };
    var f13: vc.VkPhysicalDeviceVulkan13Features = .{
        .sType = vc.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
        .pNext = &f12,
        .dynamicRendering = vc.VK_TRUE,
        .synchronization2 = vc.VK_TRUE,
        .robustImageAccess = req.robust_image,
    };
    var handle: vc.VkDevice = null;
    try loader.check(instance.fns.vkCreateDevice.?(pick.physical, &.{
        .sType = vc.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = &f13,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queue_info,
        .enabledExtensionCount = @intCast(req.ext_count),
        .ppEnabledExtensionNames = &req.exts,
        .pEnabledFeatures = &req.features,
    }, null, &handle));
    return vk.device.Device.fromOwnedHandle(instance, pick, false, handle);
}

/// Guest frame's pixels against the same scene drawn with the node as a static image of `col`.
fn compare(vh: *vhost.Host, vgfx: *vk.Renderer, target: *vhost.Target, s: *conformance.Storage, px: []const u8, node_view: vc.VkImageView, handle: lcgf.types.Texture, sampler: vc.VkSampler) !usize {
    const d = &vh.device;
    var got: [W * H * 4]u8 = undefined;
    try vh.readback(target.image.handle, .{ .width = W, .height = H }, &got);
    // The reference: re-point the node's handle at a static image of the same colour.
    var ref = try vh.sampled(NW, NH, px);
    defer d.destroyImage(&ref);
    vgfx.setTexture(d, handle, ref.view, sampler);
    vgfx.prepare(0, &s.draw, s.glyphs(), .{ W, H }, 1);
    const cmd = try vh.once.begin(d);
    pass.begin(d, cmd, target.begin(.{ 0, 0, 0, 1 }));
    vgfx.render(cmd, &s.draw);
    pass.end(d, cmd, .{ .image = target.image.handle, .layout = vc.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL });
    try vh.once.submit(d);
    var want: [W * H * 4]u8 = undefined;
    try vh.readback(target.image.handle, .{ .width = W, .height = H }, &want);
    vgfx.setTexture(d, handle, node_view, sampler);
    var bad: usize = 0;
    for (0..W * H) |i| {
        if (!std.mem.eql(u8, got[i * 4 ..][0..4], want[i * 4 ..][0..4])) bad += 1;
    }
    // Catch a vacuous pass if both images omit the node.
    const start = (56 * W + 96) * 4;
    if (!std.mem.eql(u8, got[start..][0..4], px[0..4])) return error.NodeMissing;
    return bad;
}

fn fill(px: []u8, col: [4]u8) void {
    var i: usize = 0;
    while (i < px.len) : (i += 4) px[i..][0..4].* = col;
}

fn now() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn threadCpu() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.THREAD_CPUTIME_ID, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn us(total_ns: u64, count: usize) f64 {
    return @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(count)) / 1000;
}
