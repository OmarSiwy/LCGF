//! The Gompute back end (experimental, docs/DESIGN.md): the renderer's work as compute kernels
//! written in Zig (kernels.zig), launched on CUDA or HIP through Gompute, or called as plain
//! functions on the CPU when there is no driver or card. Outside the tiers and not exported from
//! lcgr.zig: it needs the Gompute package (build.zig.zon, lazy), so it is a module of its own over
//! lcgr (`zig build gompute`), never imported by it. Decisions and measurements: DECISION.md.
//!
//! The back end meets the render contract (src/render/iface.zig) by recording: `drawBatch` and
//! `drawText` append their quads, with the texture of each, to a `Recorder` (the pass), and the
//! host rasterises what was recorded with `rasterCpu` (or a GPU launch). A custom command
//! stops `iface.drawUntilCustom` as usual; the host rasterises what is recorded so far, draws its
//! own, clears the recorder and continues, so paint order holds across the host's draws.

const std = @import("std");
const g = @import("gompute");
const lcgr = @import("lcgr");
pub const kernels = @import("kernels.zig");
const iface = lcgr.render_iface;
const draw_list = lcgr.draw_list;
const Quad = draw_list.Quad;
const DrawList = draw_list.DrawList;
const Frame = kernels.Frame;
const Image = kernels.Image;

/// The pass: the frame's quads in paint order, each with its texture, in caller-owned rows.
pub const Recorder = struct {
    quads: []Quad,
    /// `types.Texture` of each quad: its row in the caller's `Image` table.
    tex: []u32,
    len: u32 = 0,

    pub fn append(r: *Recorder, quads: []const Quad, texture: lcgr.types.Texture) void {
        std.debug.assert(r.len + quads.len <= r.quads.len); // capacity is the caller's
        @memcpy(r.quads[r.len..][0..quads.len], quads);
        @memset(r.tex[r.len..][0..quads.len], @backingInt(texture));
        r.len += @intCast(quads.len);
    }
};

pub const Gompute = struct {
    pub const Queue = void;
    pub const Pass = *Recorder;

    quads: []const Quad = &.{},
    glyphs: iface.Glyphs = .{},

    pub fn prepare(b: *Gompute, _: void, draw: *const DrawList, glyphs: iface.Glyphs, _: [2]f32, _: f32) void {
        b.quads = draw.quads[0..draw.quad_len];
        b.glyphs = glyphs;
    }

    pub fn drawBatch(b: *const Gompute, r: *Recorder, batch: draw_list.Batch) void {
        r.append(b.quads[batch.first..][0..batch.count], batch.texture);
    }

    pub fn drawText(b: *const Gompute, r: *Recorder, run: u32) void {
        const gl = b.glyphs;
        r.append(gl.quads[gl.first[run]..][0..gl.count[run]], gl.texture);
    }
};

comptime {
    iface.check(Gompute);
}

/// The framebuffer the kernels draw into: `height` rows of `stride` pixels, caller-owned.
pub const Target = struct {
    px: []u32,
    width: u32,
    height: u32,
    stride: u32,
    /// Shift of red: 0 for RGBA8, 16 for BGRA8.
    red: u32 = 0,
    scale: f32 = 1,
};

/// Tile bins for a target: `kernels.Frame.tiles` x `cap` indices and one count per tile.
pub const Bins = struct {
    idx: []u32,
    count: []u32,
    cap: u32,

    /// u32s `idx` needs for a `width` x `height` target with `cap` quads per tile.
    pub fn len(width: u32, height: u32, cap: u32) usize {
        return @as(usize, (width + kernels.tile - 1) / kernels.tile) * ((height + kernels.tile - 1) / kernels.tile) * cap;
    }
};

/// The kernels' `Frame` for `rec` drawn into `t`.
pub fn frame(t: Target, rec: *const Recorder, bins: Bins) Frame {
    return .init(t.width, t.height, t.stride, t.red, t.scale, rec.len, bins.cap);
}

/// Clears `px` to `value` on the CPU: the kernel's per-thread function, once per pixel.
pub fn fillCpu(px: []u32, value: u32) void {
    for (0..px.len) |i| kernels.fill(px.ptr, i, value);
}

/// Rasterises everything `rec` holds over `t` on the CPU: `kernels.bin` once per tile, then
/// `kernels.raster` once per pixel, the same functions the GPU runs once per thread.
pub fn rasterCpu(t: Target, rec: *const Recorder, images: []const Image, texels: []const u32, bins: Bins) void {
    const f = frame(t, rec, bins);
    std.debug.assert(bins.count.len >= f.tiles() and bins.idx.len >= @as(usize, f.tiles()) * bins.cap and bins.cap > 0);
    for (0..f.tiles()) |k| kernels.bin(f, rec.quads.ptr, bins.idx.ptr, bins.count.ptr, k);
    for (0..@as(usize, t.stride) * t.height) |i| kernels.raster(f, rec.quads.ptr, rec.tex.ptr, images.ptr, texels.ptr, bins.idx.ptr, bins.count.ptr, t.px.ptr, i);
}

/// The kernels on a GPU: CUDA or HIP, chosen at compile time. Owns the device buffers it creates
/// (sized once by `Capacity`); the host owns the loop and calls `clear`, `draw` and `download`.
/// `init` fails with Gompute's `error.InitFailed` or `error.NoDevice` on a machine without the
/// driver or a card: take the CPU path (`rasterCpu`) or another back end then.
pub fn Device(comptime backend: g.Backend) type {
    return struct {
        const Self = @This();
        const Raw = g.RawKernel("lcgr_raster", backend);
        pub const Buffer = Raw.Buffer;

        fill_k: g.RawKernel("lcgr_fill", backend),
        bin_k: g.RawKernel("lcgr_bin", backend),
        raster_k: Raw,
        cap: Capacity,
        quads: Buffer,
        tex: Buffer,
        images: Buffer,
        texels: Buffer,
        bin_idx: Buffer,
        bin_count: Buffer,
        /// The framebuffer, `cap.stride * cap.height` pixels, on the device.
        px: Buffer,

        pub const Capacity = struct {
            width: u32,
            height: u32,
            /// Row pitch in pixels (>= width).
            stride: u32,
            quads: u32,
            images: u32,
            texels: u32,
            bin_cap: u32 = 64,
        };

        pub fn init(ordinal: c_int, cap: Capacity) !Self {
            var d: Self = undefined;
            d.cap = cap;
            d.fill_k = try .init(ordinal);
            errdefer d.fill_k.deinit();
            d.bin_k = try .init(ordinal);
            errdefer d.bin_k.deinit();
            d.raster_k = try .init(ordinal);
            errdefer d.raster_k.deinit();
            const sizes = [_]usize{
                @as(usize, cap.quads) * @sizeOf(Quad),
                @as(usize, cap.quads) * 4,
                @as(usize, cap.images) * @sizeOf(Image),
                @as(usize, cap.texels) * 4,
                Bins.len(cap.width, cap.height, cap.bin_cap) * 4,
                Bins.len(cap.width, cap.height, 1) * 4,
                @as(usize, cap.stride) * cap.height * 4,
            };
            const bufs = [_]*Buffer{ &d.quads, &d.tex, &d.images, &d.texels, &d.bin_idx, &d.bin_count, &d.px };
            for (bufs, sizes, 0..) |b, n, k| {
                b.* = d.raster_k.alloc(@max(n, 4)) catch |err| {
                    for (bufs[0..k]) |done| done.free();
                    return err;
                };
            }
            return d;
        }

        pub fn deinit(d: *Self) void {
            for ([_]*Buffer{ &d.quads, &d.tex, &d.images, &d.texels, &d.bin_idx, &d.bin_count, &d.px }) |b| b.free();
            d.raster_k.deinit();
            d.bin_k.deinit();
            d.fill_k.deinit();
        }

        /// Uploads the texture table and its texels; once, or whenever they change.
        pub fn setImages(d: *Self, images: []const Image, texels: []const u32) !void {
            std.debug.assert(images.len <= d.cap.images and texels.len <= d.cap.texels);
            try d.images.upload(images.ptr, images.len * @sizeOf(Image));
            try d.texels.upload(texels.ptr, texels.len * 4);
        }

        /// Queues a clear of the device framebuffer to `value` (framebuffer byte order).
        pub fn clear(d: *Self, value: u32) !void {
            var len: u32 = d.cap.stride * d.cap.height;
            var v = value;
            try d.fill_k.launch(grid(len), .{ .x = kernels.block }, 0, &.{ d.px.argPtr(), g.interface.arg(&len), g.interface.arg(&v) });
        }

        /// Uploads what `rec` holds and queues `bin` and `raster` over the device framebuffer.
        /// Returns once queued; `download` (or `synchronize`) waits.
        pub fn draw(d: *Self, rec: *const Recorder, red: u32, scale: f32) !void {
            std.debug.assert(rec.len <= d.cap.quads);
            if (rec.len == 0) return;
            try d.quads.upload(rec.quads.ptr, rec.len * @sizeOf(Quad));
            try d.tex.upload(rec.tex.ptr, rec.len * 4);
            var f: Frame = .init(d.cap.width, d.cap.height, d.cap.stride, red, scale, rec.len, d.cap.bin_cap);
            try d.bin_k.launch(grid(f.tiles()), .{ .x = kernels.block }, 0, &.{ g.interface.arg(&f), d.quads.argPtr(), d.bin_idx.argPtr(), d.bin_count.argPtr() });
            try d.raster_k.launch(grid(@as(usize, f.stride) * f.height), .{ .x = kernels.block }, 0, &.{
                g.interface.arg(&f), d.quads.argPtr(), d.tex.argPtr(), d.images.argPtr(), d.texels.argPtr(), d.bin_idx.argPtr(), d.bin_count.argPtr(), d.px.argPtr(),
            });
        }

        /// Waits for the queued work and copies the framebuffer into `px` (`stride * height`).
        pub fn download(d: *Self, px: []u32) !void {
            std.debug.assert(px.len >= @as(usize, d.cap.stride) * d.cap.height);
            try d.raster_k.synchronize();
            try d.px.download(px.ptr, @as(usize, d.cap.stride) * d.cap.height * 4);
        }

        /// Copies `px` (`stride * height`) into the device framebuffer: how a host's inline custom
        /// draw, done on the CPU between `download` and this, gets back under the UI drawn later.
        pub fn upload(d: *Self, px: []const u32) !void {
            try d.px.upload(px.ptr, @as(usize, d.cap.stride) * d.cap.height * 4);
        }

        pub fn synchronize(d: *Self) !void {
            try d.raster_k.synchronize();
        }
    };
}

/// Blocks of `kernels.block` threads covering `n` items.
pub fn grid(n: usize) g.Dim3 {
    return g.Dim3.linear(n, kernels.block);
}

const testing = std.testing;
const conformance = lcgr.render_conformance;
const sw = lcgr.render_sw;

test "fill: the CPU path and, when present, the CUDA device write the same pixels" {
    var cpu: [1000]u32 = @splat(0);
    fillCpu(&cpu, 0xff20_4060);
    for (cpu) |p| try testing.expectEqual(0xff20_4060, p);

    if (comptime !g.available(.cuda)) return;
    var k = g.RawKernel("lcgr_fill", .cuda).init(0) catch return; // no driver or no card
    defer k.deinit();
    var buf = try k.alloc(@sizeOf(@TypeOf(cpu)));
    defer buf.free();
    var len: u32 = cpu.len;
    var value: u32 = 0xff20_4060;
    try k.launch(grid(len), .{ .x = kernels.block }, 0, &.{ buf.argPtr(), g.interface.arg(&len), g.interface.arg(&value) });
    try k.synchronize();
    var gpu: [1000]u32 = @splat(0);
    try buf.download(&gpu, @sizeOf(@TypeOf(gpu)));
    try testing.expectEqualSlices(u32, &cpu, &gpu);
}

/// The host gradient of the conformance `custom` scene (src/render/sw/play.zig).
fn hostGradient(px: []u32, stride: u32, w: u32, h: u32, rect: [4]f32) void {
    const wf: f32 = @floatFromInt(w);
    const hf: f32 = @floatFromInt(h);
    for (@intFromFloat(rect[1])..@intFromFloat(rect[3])) |y| for (@intFromFloat(rect[0])..@intFromFloat(rect[2])) |x| {
        const fx = @as(f32, @floatFromInt(x)) + 0.5;
        const fy = @as(f32, @floatFromInt(y)) + 0.5;
        const c: lcgr.types.Color = .rgb(unorm(fx / wf * 0.5), unorm(0.25), unorm(fy / hf * 0.6));
        px[y * stride + x] = c.bitsOf();
    };
}

fn unorm(x: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(x, 0, 1) * 255));
}

/// The stand-in glyph atlas of sw-play: 16x16 cells of 4x4 texels, every printable byte a block.
fn atlas() [64 * 64]u32 {
    var a: [64 * 64]u32 = @splat(0);
    for (33..127) |byte| for (1..4) |y| for (1..3) |x| {
        a[((byte >> 4) * 4 + y) * 64 + (byte & 15) * 4 + x] = 0xffff_ffff;
    };
    return a;
}

test "raster: every conformance scene on the CPU path matches the software back end" {
    const w = 160;
    const h = 120;
    const glyph_atlas = atlas();
    var texels: [1 + 64 * 64]u32 = undefined;
    texels[0] = 0xffff_ffff;
    @memcpy(texels[1..], &glyph_atlas);
    const images = [_]Image{ .{ .first = 0, .width = 1, .height = 1 }, .{ .first = 1, .width = 64, .height = 64 } };
    const sw_images = [_]sw.Image{ sw.Image.white, .{ .pixels = &glyph_atlas, .width = 64, .height = 64 } };
    const atlas_tex: lcgr.types.Texture = @fromBackingInt(1);

    var rq: [conformance.max_quads + conformance.max_glyphs]Quad = undefined;
    var rt: [rq.len]u32 = undefined;
    var bin_idx: [Bins.len(w, h, 16)]u32 = undefined;
    var bin_count: [Bins.len(w, h, 1)]u32 = undefined;
    var mine: [sw.Framebuffer.len(w, h)]u32 = undefined;
    var ref: [sw.Framebuffer.len(w, h)]u32 = undefined;

    // A capacity of 2 overflows the tiles where two quads overlap the full-screen panel, so
    // both of `raster`'s paths are exercised (`overflowed`); 16 fits every tile.
    var overflowed = false;
    for ([_]u32{ 2, 16 }) |cap| for (&conformance.scenes) |*scene| {
        const bins: Bins = .{ .idx = &bin_idx, .count = &bin_count, .cap = cap };
        var st: conformance.Storage = .{};
        st.load(scene);
        var glyphs = st.glyphs();
        glyphs.texture = atlas_tex;

        var fb = sw.Framebuffer.init(&ref, w, h, .rgba8);
        fb.clear(.black);
        var s: sw.Software = .{ .images = &sw_images };
        s.prepare({}, &st.draw, glyphs, scene.viewport, 1);
        const sw_target: sw.Target = .{ .fb = &fb, .scissor = fb.all() };
        var i = iface.drawUntilCustom(&s, sw_target, &st.draw, 0);
        while (i < st.draw.cmd_len) : (i = iface.drawUntilCustom(&s, sw_target, &st.draw, i + 1))
            hostGradient(fb.pixels, fb.stride, w, h, st.draw.customs[st.draw.command(i).custom].rect);

        const t: Target = .{ .px = &mine, .width = w, .height = h, .stride = fb.stride };
        fillCpu(&mine, lcgr.types.Color.black.bitsOf());
        var gc: Gompute = .{};
        gc.prepare({}, &st.draw, glyphs, scene.viewport, 1);
        var rec: Recorder = .{ .quads = &rq, .tex = &rt };
        var j = iface.drawUntilCustom(&gc, &rec, &st.draw, 0);
        while (j < st.draw.cmd_len) : (j = iface.drawUntilCustom(&gc, &rec, &st.draw, j + 1)) {
            rasterCpu(t, &rec, &images, &texels, bins);
            rec.len = 0;
            hostGradient(&mine, fb.stride, w, h, st.draw.customs[st.draw.command(j).custom].rect);
        }
        rasterCpu(t, &rec, &images, &texels, bins);

        for (0..h) |y| try testing.expectEqualSlices(u32, ref[y * fb.stride ..][0..w], mine[y * fb.stride ..][0..w]);
        overflowed = overflowed or std.mem.max(u32, bin_count[0..frame(t, &rec, bins).tiles()]) >= cap;
    };
    try testing.expect(overflowed);
}

test "device: CUDA draws every conformance scene with the CPU path's pixels; HIP compiles" {
    std.testing.refAllDecls(Device(.hip)); // no AMD card here: compile-only
    if (comptime !g.available(.cuda)) return;
    const w = 160;
    const h = 120;
    const stride = 160;
    const glyph_atlas = atlas();
    var texels: [1 + 64 * 64]u32 = undefined;
    texels[0] = 0xffff_ffff;
    @memcpy(texels[1..], &glyph_atlas);
    const images = [_]Image{ .{ .first = 0, .width = 1, .height = 1 }, .{ .first = 1, .width = 64, .height = 64 } };
    var dev = Device(.cuda).init(0, .{ .width = w, .height = h, .stride = stride, .quads = 64, .images = 2, .texels = texels.len, .bin_cap = 4 }) catch |err| switch (err) {
        error.InitFailed, error.NoDevice => return, // no driver or no card
        else => return err,
    };
    defer dev.deinit();
    try dev.setImages(&images, &texels);

    var rq: [64]Quad = undefined;
    var rt: [64]u32 = undefined;
    var bin_idx: [Bins.len(w, h, 4)]u32 = undefined;
    var bin_count: [Bins.len(w, h, 1)]u32 = undefined;
    const bins: Bins = .{ .idx = &bin_idx, .count = &bin_count, .cap = 4 };
    var cpu: [stride * h]u32 = undefined;
    var gpu: [stride * h]u32 = undefined;
    const black = lcgr.types.Color.black.bitsOf();
    for (&conformance.scenes) |*scene| {
        var st: conformance.Storage = .{};
        st.load(scene);
        var glyphs = st.glyphs();
        glyphs.texture = @fromBackingInt(1);
        var gc: Gompute = .{};
        gc.prepare({}, &st.draw, glyphs, scene.viewport, 1);
        const t: Target = .{ .px = &cpu, .width = w, .height = h, .stride = stride };

        fillCpu(&cpu, black);
        try dev.clear(black);
        var rec: Recorder = .{ .quads = &rq, .tex = &rt };
        var j = iface.drawUntilCustom(&gc, &rec, &st.draw, 0);
        while (j < st.draw.cmd_len) : (j = iface.drawUntilCustom(&gc, &rec, &st.draw, j + 1)) {
            const rect = st.draw.customs[st.draw.command(j).custom].rect;
            rasterCpu(t, &rec, &images, &texels, bins);
            hostGradient(&cpu, stride, w, h, rect);
            // The host's draw on the CPU between two GPU segments: down, draw, up.
            try dev.draw(&rec, 0, 1);
            try dev.download(&gpu);
            hostGradient(&gpu, stride, w, h, rect);
            try dev.upload(&gpu);
            rec.len = 0;
        }
        rasterCpu(t, &rec, &images, &texels, bins);
        try dev.draw(&rec, 0, 1);
        try dev.download(&gpu);
        try testing.expectEqualSlices(u32, &cpu, &gpu);
    }
}
