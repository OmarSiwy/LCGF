//! Frame time of the benchmark scene (docs/CHECKS.md section 3: bench/scenes/rows.zig, 330 rows,
//! 3,961 nodes, 1,320 text runs) through three back ends on this machine, at 1280x720:
//!
//!     VK_ICD_FILENAMES=.../nvidia_icd.json gompute-bench-frame [frames]
//!
//!   sw        the software back end on one CPU core: clear, then `iface.render`
//!   gompute   record (`iface.render` into a Recorder), clear, upload, bin, raster, until the
//!             GPU is done; then again with the read-back into pinned memory (C0421)
//!   vk        the Vulkan back end: prepare, record, submit, until the GPU is done (as vk-probe)
//!
//! The frame is built once by lcgr's runtime front end; every back end draws the same draw list
//! and glyph quads, the glyphs over the white texture (the timing does not depend on the atlas).
//! Medians over `frames` (default 300) after 20 warm-up frames.
const std = @import("std");
const lcgr = @import("lcgr");
const vk = @import("vk");
const scenes = @import("src_scenes");
const gc = @import("gompute.zig");
const c = vk.c;
const iface = lcgr.render_iface;
const sw = lcgr.render_sw;
const Quad = lcgr.draw_list.Quad;
const Context = lcgr.context.Context;

const width = 1280;
const height = 720;
const limits: lcgr.context.Limits = .{ .nodes = 4096, .texts = 2048, .strings = 128 * 1024, .anims = 1024 };
var ctx_buffer: [Context.requiredBytes(limits)]u8 align(lcgr.mem.column_align) = undefined;
var ctx: Context = undefined;
var glyph_quads: [32 * 1024]Quad = undefined;
var first: [2048]u32 = undefined;
var count: [2048]u32 = undefined;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next();
    const frames: usize = if (args.next()) |a| try std.fmt.parseInt(usize, a, 10) else 300;
    var buf: [512]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &buf);
    const w = &out.interface;

    // The scene's first frame, laid out for a 1280x720 window.
    ctx = try Context.initZeroed(&ctx_buffer, limits);
    var in: lcgr.input.Input = .{};
    scenes.rows.scene.input(&in, 0);
    in.viewport = .{ width, height };
    var f = ctx.begin(&in);
    const th: lcgr.widgets_base.Theme = .{};
    scenes.rows.scene.build(&f, &th);
    const font: lcgr.protocol.Mono = .{};
    const draw = f.end(font).draw;
    const n_glyphs = font.quads(draw, &glyph_quads, .{ .first = &first, .count = &count });
    const glyphs: iface.Glyphs = .{ .quads = glyph_quads[0..n_glyphs], .first = first[0..draw.run_len], .count = count[0..draw.run_len] };
    try w.print("rows at {d}x{d}: {d} quads, {d} text runs, {d} glyph quads, {d} commands\n", .{ width, height, draw.quad_len, draw.run_len, n_glyphs, draw.cmd_len });
    try w.flush();
    const times = try gpa.alloc(u64, frames);
    defer gpa.free(times);

    { // sw
        const px = try gpa.alloc(u32, sw.Framebuffer.len(width, height));
        defer gpa.free(px);
        var fb = sw.Framebuffer.init(px, width, height, .rgba8);
        var s: sw.Software = .{};
        s.prepare({}, draw, glyphs, .{ width, height }, 1);
        for (0..frames + 20) |k| {
            const t0 = now(io);
            fb.clear(.black);
            iface.render(&s, .{ .fb = &fb, .scissor = fb.all() }, draw);
            if (k >= 20) times[k - 20] = since(io, t0);
        }
        try w.print("sw (1 core)         {d} us/frame\n", .{median(times)});
        try w.flush();
    }

    { // gompute on CUDA
        const total = draw.quad_len + n_glyphs;
        var dev = try gc.Device(.cuda).init(0, .{ .width = width, .height = height, .stride = width, .quads = total, .images = 1, .texels = 1 });
        defer dev.deinit();
        try dev.setImages(&.{.{ .first = 0, .width = 1, .height = 1 }}, &.{0xffff_ffff});
        const rq = try gpa.alloc(Quad, total);
        defer gpa.free(rq);
        const rt = try gpa.alloc(u32, total);
        defer gpa.free(rt);
        var b: gc.Gompute = .{};
        b.prepare({}, draw, glyphs, .{ width, height }, 1);
        const pinned_bytes = try dev.raster_k.allocPinned(width * height * 4);
        defer dev.raster_k.freePinned(pinned_bytes);
        var fb = sw.Framebuffer.init(@alignCast(std.mem.bytesAsSlice(u32, pinned_bytes)), width, height, .rgba8);
        for ([_]bool{ false, true }) |present| {
            for (0..frames + 20) |k| {
                const t0 = now(io);
                var rec: gc.Recorder = .{ .quads = rq, .tex = rt };
                iface.render(&b, &rec, draw);
                try dev.clear(0xff00_0000);
                try dev.draw(&rec, 0, 1);
                if (present) try dev.present(&fb) else try dev.synchronize();
                if (k >= 20) times[k - 20] = since(io, t0);
            }
            try w.print("gompute cuda{s} {d} us/frame\n", .{ if (present) " + read-back" else "            ", median(times) });
            try w.flush();
        }
    }

    { // vk
        var h: vk.host.Host = undefined;
        try h.init();
        defer h.deinit();
        const d = &h.device;
        const sampler = try vk.host.nearestSampler(d);
        defer d.fns.vkDestroySampler.?(d.handle, sampler, null);
        var white = try h.sampled(1, 1, &.{ 0xff, 0xff, 0xff, 0xff });
        defer d.destroyImage(&white);
        var gfx = try vk.Renderer.init(d, .{ .format = c.VK_FORMAT_R8G8B8A8_UNORM }, white.view, sampler);
        defer gfx.deinit(d);
        var target = try vk.host.Target.init(d, width, height, 1);
        defer target.deinit(d);
        for (0..frames + 20) |k| {
            const t0 = now(io);
            gfx.prepare(@intCast(k % 2), draw, glyphs, .{ width, height }, 1);
            const cmd = try h.once.begin(d);
            vk.pass.begin(d, cmd, target.begin(.{ 0, 0, 0, 1 }));
            gfx.render(cmd, draw);
            vk.pass.end(d, cmd, .{ .image = target.image.handle, .layout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL });
            try h.once.submit(d);
            if (k >= 20) times[k - 20] = since(io, t0);
        }
        try w.print("vk ({s}) {d} us/frame\n", .{ d.name(), median(times) });
        try w.flush();
    }
}

fn now(io: std.Io) std.Io.Timestamp {
    return std.Io.Timestamp.now(io, .awake);
}

fn since(io: std.Io, t0: std.Io.Timestamp) u64 {
    return @intCast(t0.durationTo(now(io)).toNanoseconds());
}

fn median(ns: []u64) u64 {
    std.mem.sort(u64, ns, {}, std.sort.asc(u64));
    return ns[ns.len / 2] / 1000;
}
