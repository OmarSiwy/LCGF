//! The custom-node timing of docs/research/custom-webgpu/ (probe_guest.zig, the wgpu-native
//! guest), repeated with the same application drawing written against lcgf_render.gpu. Same
//! scene, same 56 × 56 node sampled by the native UI pass, same 2,000 serialized frames and the
//! same output line, so docs/research/custom-webgpu/measure.py can time both.
//!
//! The difference is where the node is drawn. The guest had its own WebGPU device on the shared
//! VkDevice, its own command encoder, a hand-off transition and a second submission per redraw.
//! Here the node's pass is recorded into the UI's own command buffer, ahead of the UI pass: one
//! submission, the projection's pass end as the hand-off.
//!
//!     custom-draw-projection native      the node is a static image (no custom drawing)
//!     custom-draw-projection cached      drawn once, sampled every frame
//!     custom-draw-projection projection  redrawn every frame
//!     custom-draw-projection check       compared, frame by frame, with static reference images
//!     custom-draw-projection nohandoff   control: ends the node's pass by hand, without the
//!                                        projection's layout hand-off (validation must object)
const std = @import("std");
const lcgf = @import("lcgf");
const vk = @import("vk.zig");
const vc = vk.c;
const vhost = vk.host;
const pass = vk.pass;
const loader = vk.loader;
const gpu = vk.gpu;
const conformance = lcgf.render_conformance;
const enabled = @import("custom_draw").enabled;
const Mode = enum { native, cached, projection, check, nohandoff };

const frames = 2000;
const W = 160;
const H = 120;
const NW = 56;
const NH = 56;

var st: [conformance.scenes.len]conformance.Storage = @splat(.{});

/// The application: what custom_draw_sample.zig was for the guest, in lcgf_render.gpu.
const Drawing = struct {
    const S = gpu.Shader(@import("probe_shaders").node);

    arena: gpu.Arena,
    host_arena: gpu.Arena,
    staging: gpu.Staging,
    node: gpu.Texture,
    image: gpu.Texture,
    smp: gpu.Sampler,
    tint: gpu.Buffer,
    pipeline: gpu.RenderPipeline(S),
    group: gpu.BindGroup(S, 0),
    size: u32,

    fn init(a: *Drawing, dev: gpu.Device, size: u32) !void {
        a.size = size;
        a.arena = try .init(dev, .{ .bytes = 1 << 20 });
        a.host_arena = try .init(dev, .{ .bytes = 1 << 16, .memory = .host });
        a.staging = try .init(dev, &a.host_arena, 64 * 64 * 4);
        a.node = try dev.createTexture(&a.arena, .{ .size = .{ .width = NW, .height = NH }, .format = .rgba8_unorm, .usage = .{ .texture_binding = true, .render_attachment = true } });
        a.image = try dev.createTexture(&a.arena, .{ .size = .{ .width = size, .height = size }, .format = .rgba8_unorm, .usage = .{ .texture_binding = true, .copy_dst = true } });
        a.smp = try dev.createSampler(.{});
        a.tint = try dev.createBuffer(&a.arena, .{ .size = 16, .usage = .{ .uniform = true, .copy_dst = true } });
        a.pipeline = try dev.createRenderPipeline(S, .{ .fragment = .{ .targets = &.{.{ .format = .rgba8_unorm, .blend = .premultiplied }} } });
        a.group = try dev.createBindGroup(&a.arena, a.pipeline, 0, .{ .tint = a.tint, .tex = a.image.createView(), .smp = a.smp });
    }

    fn deinit(a: *Drawing, dev: gpu.Device) void {
        dev.destroyRenderPipeline(a.pipeline);
        dev.destroyBuffer(a.tint);
        dev.destroySampler(a.smp);
        dev.destroyTexture(a.image);
        dev.destroyTexture(a.node);
        a.staging.deinit(dev);
        a.host_arena.deinit();
        a.arena.deinit();
    }

    /// The app's image, once.
    fn load(a: *Drawing, up: *gpu.Upload) !void {
        var px: [64 * 64 * 4]u8 = undefined;
        for (0..64 * 64) |i| px[i * 4 ..][0..4].* = .{ @truncate(i), @truncate(i >> 6), 0x80, 0xff };
        try up.writeTexture(a.image, px[0 .. a.size * a.size * 4], a.size * 4);
    }

    /// The app's own pass into its node, cleared to `col`, then (with an `alpha`) the tinted
    /// image over it. The UI pass that follows samples the node.
    fn draw(a: *Drawing, up: *gpu.Upload, col: [4]u8, alpha: ?f32, handoff: bool) void {
        if (alpha) |opacity| up.writeBuffer(a.tint, 0, std.mem.asBytes(&[4]f32{ 1, 1, 1, opacity }));
        var enc = up.finish();
        var p = enc.beginRenderPass(.{ .color_attachments = &.{.{ .view = a.node.createView(), .clear_value = .{ .r = f(col[0]), .g = f(col[1]), .b = f(col[2]), .a = 1 } }} });
        if (alpha != null) {
            p.setPipeline(a.pipeline);
            p.setBindGroup(0, &a.group);
            p.draw(3, 1, 0, 0);
        }
        // The control reaches past the projection to the native call underneath, which it
        // always may: the pass's command buffer and function table are public.
        if (handoff) p.end() else p.fns.vkCmdEndRendering.?(p.cmd);
    }

    fn f(b: u8) f64 {
        return @as(f64, @floatFromInt(b)) / 255;
    }
};

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const mode = std.meta.stringToEnum(Mode, args.next() orelse "native") orelse return error.InvalidMode;
    if (!enabled and mode != .native) return error.CustomDrawingDisabled;
    const custom = enabled and mode != .native;
    const checking = mode == .check;

    // The host's device, as any LCGF Vulkan application has it: nothing added for custom drawing.
    var vh: vhost.Host = undefined;
    vh.lib = try loader.Library.open();
    vh.instance = try loader.Instance.init(&vh.lib, .{});
    const pick = try vk.device.pick(&vh.instance, null);
    vh.device = try vk.device.Device.init(&vh.instance, pick, false);
    vh.once = try vhost.Once.init(&vh.device);
    defer vh.deinit();
    const d = &vh.device;
    const dev: gpu.Device = .wrap(d);
    const vsampler = try vhost.nearestSampler(d);
    defer d.fns.vkDestroySampler.?(d.handle, vsampler, null);
    var vwhite = try vh.sampled(1, 1, &.{ 0xff, 0xff, 0xff, 0xff });
    defer d.destroyImage(&vwhite);
    var vgfx = try vk.Renderer.init(d, .{ .format = vc.VK_FORMAT_R8G8B8A8_UNORM }, vwhite.view, vsampler);

    var static_px: [NW * NH * 4]u8 = undefined;
    fill(&static_px, .{ 0x20, 0x60, 0xa0, 0xff });
    var static_img = try vh.sampled(NW, NH, &static_px);
    defer d.destroyImage(&static_img);

    var app: Drawing = undefined;
    if (custom) try app.init(dev, if (checking) NW else 64);
    defer if (custom) {
        _ = d.fns.vkDeviceWaitIdle.?(d.handle);
        app.deinit(dev);
    };
    defer vgfx.deinit(d);
    const node_view = if (custom) app.node.view else static_img.view;
    const node_tex = try vgfx.addTexture(d, node_view, vsampler);
    for (&st, &conformance.scenes) |*s, *scene| {
        s.load(scene);
        @import("custom_draw_scene").addNode(&s.draw, node_tex);
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
        const cmd = try vh.once.begin(d);
        const tb = now();
        if (custom and redraw) {
            redraws += @intFromBool(n >= warmup);
            // ---- the app's custom node: its own pass, in the UI's command buffer ----
            var up: gpu.Upload = .beginStaged(dev, cmd, &app.staging);
            if (n == 0) try app.load(&up);
            const k: f32 = @floatFromInt(n % 7);
            const alpha: ?f32 = if (!checking) k / 7 else if (n == colors.len) 1 else null;
            app.draw(&up, colors[n % colors.len], alpha, mode != .nohandoff);
        }
        const ta = now();
        // ---- LCGF's own frame, sampling the node ----
        vgfx.prepare(@intCast(n % 2), &s.draw, s.glyphs(), .{ W, H }, 1);
        pass.begin(d, cmd, target.begin(.{ 0, 0, 0, 1 }));
        vgfx.render(cmd, &s.draw);
        pass.end(d, cmd, .{ .image = target.image.handle, .layout = vc.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL });
        try vh.once.send(d);
        const t1 = now();
        try vh.once.wait(d);
        if (n < warmup) continue;
        app_ns += ta - tb;
        record_ns += t1 - t0;
        frame_ns += now() - t0;
        if (checking) {
            if (n >= colors.len) {
                for (0..NW * NH) |i| static_px[i * 4 ..][0..4].* = .{ @truncate(i), @truncate(i >> 6), 0x80, 0xff };
            } else fill(&static_px, colors[n]);
            bad_total += try compare(&vh, &vgfx, &target, s, &static_px, node_view, node_tex, vsampler);
        }
    }
    var line: [200]u8 = undefined;
    const msg = if (checking)
        try std.fmt.bufPrint(&line, "ready projection-check ({s}) frames={d} redraws={d} px_different={d}\n", .{ d.name(), n_frames, redraws, bad_total })
    else
        try std.fmt.bufPrint(&line, "ready {s} frames={d} redraws={d} cpu_us={d:.1} frame_us={d:.1} thread_us={d:.1} app_us={d:.1}\n", .{ @tagName(mode), n_frames, redraws, us(record_ns, n_frames), us(frame_ns, n_frames), us(threadCpu() - cpu0, n_frames), us(app_ns, n_frames) });
    _ = std.os.linux.write(1, msg.ptr, msg.len);
    if (bad_total != 0) return error.PixelMismatch;
}

/// The frame's pixels against the same scene drawn with the node as a static image of `px`.
fn compare(vh: *vhost.Host, vgfx: *vk.Renderer, target: *vhost.Target, s: *conformance.Storage, px: []const u8, node_view: vc.VkImageView, handle: lcgf.types.Texture, sampler: vc.VkSampler) !usize {
    const d = &vh.device;
    var got: [W * H * 4]u8 = undefined;
    try vh.readback(target.image.handle, .{ .width = W, .height = H }, &got);
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
