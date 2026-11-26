//! Software renderer benchmark: whole frames drawn by src/render/sw, the same way `sw.Setup.draw`
//! draws them (clear, then every command), timed per frame.
//!
//! Scenes: the runtime scenes of bench/scenes (built once through `Frame`, their glyphs from
//! `protocol.Mono` over a stand-in atlas of antialiased cells) and synthetic sets that isolate
//! one kind of quad. Timings compare on one machine only (docs/CHECKS.md).
//!
//!   zig build swbench                         every scene at 1280x800
//!   zig build swbench -- --size 1920x1080     another framebuffer size
//!   zig build swbench -- --frames 100         frames per scene (median and p90 printed)
//!   zig build swbench -- --scene glyphs       one scene
//!   zig build swbench -- --dump DIR           also write each scene for bench/cairo (quads.bin,
//!                                             glyphs.bin, cmds.txt, atlas.bin)
//!   zig build swbench -- --png DIR            write each scene's frame as DIR/<scene>.png
//!   zig build swbench -- --threads 2         draw each frame with 2 threads (`sw.bands`), a band each
//!   zig build swbench -- --incremental       runtime scenes frame after frame, the pointer moving,
//!                                            redrawing only what changed (`Context.trackDamage`)
//!   zig build swbench -- --rgba-text          glyphs from the atlas's RGBA texels, not its alpha plane
//!   zig build swbench -- --dir DUMP           time a dumped frame (draw-dump, conformance-dump)
const std = @import("std");
const lcgf = @import("lcgf");
const scenes = @import("scenes");
const linux = std.os.linux;
const sw = lcgf.render_sw;
const Quad = lcgf.draw_list.Quad;
const Cmd = lcgf.draw_list.Cmd;
const Color = lcgf.types.Color;
const Context = lcgf.context.Context;

pub const std_options: std.Options = .{ .signal_stack_size = null };

const limits: lcgf.context.Limits = .{ .nodes = 4096, .texts = 2048, .strings = 128 * 1024, .anims = 1024 };
var ctx_buffer: [Context.requiredBytes(limits)]u8 align(lcgf.mem.column_align) = @splat(0);
const damage_limits: lcgf.context.Limits = blk: {
    var l = limits;
    l.damage = true;
    break :blk l;
};
var damage_buffer: [Context.requiredBytes(damage_limits)]u8 align(lcgf.mem.column_align) = @splat(0);

/// The stand-in glyph atlas: 16x16 cells of 8x16 texels, one per byte, as `Mono` addresses it.
const cell = [2]u32{ 8, 16 };
const atlas_w = 16 * cell[0];
const atlas_h = 16 * cell[1];
const atlas_tex: lcgf.types.Texture = @fromBackingInt(1);

/// One frame to draw: its quads, its glyph quads per text run, and the command list.
const Scene = struct {
    name: []const u8,
    width: u32,
    height: u32,
    background: Color,
    quads: []const Quad,
    glyph_quads: []const Quad,
    first: []const u32,
    count: []const u32,
    cmds: []const Cmd,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = std.heap.page_allocator;
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    var size = [2]u32{ 1280, 800 };
    var frames: u32 = 60;
    var only: ?[]const u8 = null;
    var dump: ?[]const u8 = null;
    var png_dir: ?[]const u8 = null;
    var dir: ?[]const u8 = null;
    var incremental = false;
    var coverage = true;
    var threads: u32 = 1;
    var band_count: u32 = 0;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--size")) {
            const s = args.next() orelse return error.MissingSize;
            const x = std.mem.indexOfScalar(u8, s, 'x') orelse return error.BadSize;
            size = .{ try std.fmt.parseInt(u32, s[0..x], 10), try std.fmt.parseInt(u32, s[x + 1 ..], 10) };
        } else if (std.mem.eql(u8, arg, "--frames")) {
            frames = try std.fmt.parseInt(u32, args.next() orelse return error.MissingCount, 10);
        } else if (std.mem.eql(u8, arg, "--scene")) {
            only = args.next() orelse return error.MissingScene;
        } else if (std.mem.eql(u8, arg, "--dump")) {
            dump = args.next() orelse return error.MissingPath;
        } else if (std.mem.eql(u8, arg, "--png")) {
            png_dir = args.next() orelse return error.MissingPath;
        } else if (std.mem.eql(u8, arg, "--threads")) {
            threads = try std.fmt.parseInt(u32, args.next() orelse return error.MissingCount, 10);
        } else if (std.mem.eql(u8, arg, "--bands")) {
            band_count = try std.fmt.parseInt(u32, args.next() orelse return error.MissingCount, 10);
        } else if (std.mem.eql(u8, arg, "--incremental")) {
            incremental = true;
        } else if (std.mem.eql(u8, arg, "--rgba-text")) {
            coverage = false;
        } else if (std.mem.eql(u8, arg, "--dir")) {
            dir = args.next() orelse return error.MissingPath;
        } else return error.UnknownArgument;
    }

    var pool: sw.bands.Pool = undefined;
    try pool.init(io, threads);
    defer pool.deinit();
    // A band a thread by default: each band walks every quad, so more bands cost more than
    // the balance they buy (10,000 quads in 8 bands: twice the time of 2).
    if (band_count == 0) band_count = threads;

    var atlas = makeAtlas();
    atlas.coverage = coverage;
    if (incremental) return runIncremental(io, gpa, &atlas, &pool, size, frames, only);
    var list: std.ArrayList(Scene) = .empty;
    if (dir) |path| {
        try list.append(gpa, try loadDump(io, gpa, path));
    } else {
        for (scenes.all[0..4]) |s| try list.append(gpa, try runtimeScene(gpa, s, size));
        try list.append(gpa, try synthetic(gpa, .rects, size));
        try list.append(gpa, try synthetic(gpa, .rounded, size));
        try list.append(gpa, try synthetic(gpa, .bordered, size));
        try list.append(gpa, try synthetic(gpa, .translucent, size));
        try list.append(gpa, try synthetic(gpa, .glyphs, size));
    }

    var buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &buf);
    const w = &out.interface;
    try w.print("{s:<12} {s:>9} {s:>8} {s:>9} {s:>9} {s:>9} {s:>8}\n", .{ "scene", "size", "quads", "glyphs", "min us", "median us", "p90 us" });
    for (list.items) |*s| {
        if (only) |name| if (!std.mem.eql(u8, name, s.name)) continue;
        const px = try gpa.alloc(u32, sw.Framebuffer.len(s.width, s.height));
        defer gpa.free(px);
        var fb = sw.Framebuffer.init(px, s.width, s.height, .rgba8);
        const samples = try gpa.alloc(u64, frames);
        defer gpa.free(samples);
        for (samples) |*t| {
            const t0 = now();
            drawFrame(s, &fb, &atlas, &pool, band_count);
            t.* = now() - t0;
        }
        std.mem.sort(u64, samples, {}, std.sort.asc(u64));
        var dims: [16]u8 = undefined;
        try w.print("{s:<12} {s:>9} {d:>8} {d:>9} {d:>9.1} {d:>9.1} {d:>8.1}\n", .{
            s.name,                            try std.fmt.bufPrint(&dims, "{d}x{d}", .{ s.width, s.height }),
            s.quads.len,                       s.glyph_quads.len,
            us(samples[0]),                    us(samples[samples.len / 2]),
            us(samples[samples.len * 9 / 10]),
        });
        try w.flush();
        if (png_dir) |p| try writePng(io, gpa, p, s.name, &fb);
        if (dump) |p| try writeDump(io, gpa, p, s, &atlas);
    }
    try w.flush();
}

/// What `sw.Setup.draw` does, with the command list of `s`.
fn drawFrame(s: *const Scene, fb: *sw.Framebuffer, atlas: *const Atlas, pool: *sw.bands.Pool, n: u32) void {
    const images = [_]sw.Image{ sw.Image.white, atlas.image() };
    const job: Job = .{
        .gfx = .{
            .quads = s.quads,
            .glyphs = .{ .quads = s.glyph_quads, .first = s.first, .count = s.count, .texture = atlas_tex },
            .images = &images,
        },
        .fb = fb,
        .commands = .{ .cmds = s.cmds, .cmd_len = @intCast(s.cmds.len) },
        .background = s.background,
    };
    pool.run(n, &job, Job.band);
}

/// One frame, drawn a band of rows at a time.
const Job = struct {
    gfx: sw.Software,
    fb: *sw.Framebuffer,
    commands: Commands,
    background: Color,

    fn band(j: *const Job, k: u32, n: u32) void {
        j.gfx.frame(.{ .fb = j.fb, .scissor = sw.tile(j.fb, k, n) }, &j.commands, j.background);
    }
};

/// A scene's command list as `sw.Software.frame` reads a `DrawList`'s.
const Commands = struct {
    cmds: []const Cmd,
    cmd_len: u32,

    pub fn command(c: *const Commands, i: u32) Cmd {
        return c.cmds[i];
    }
};

/// The runtime scenes as a host that keeps its pixels draws them: frame after frame with the
/// scene's own input and the pointer wandering over the window, each drawn by `sw.Setup.draw` over the last, which
/// redraws only the rects that changed. Times the draws after the first frame.
fn runIncremental(io: std.Io, gpa: std.mem.Allocator, atlas: *const Atlas, pool: *sw.bands.Pool, size: [2]u32, frames: u32, only: ?[]const u8) !void {
    var buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &buf);
    const w = &out.interface;
    try w.print("{s:<12} {s:>9} {s:>12} {s:>9} {s:>9} {s:>8}\n", .{ "scene", "size", "redrawn %", "min us", "median us", "p90 us" });
    const images = [_]sw.Image{ sw.Image.white, atlas.image() };
    for (scenes.all[0..4]) |scene| {
        if (only) |name| if (!std.mem.eql(u8, name, scene.name)) continue;
        var ctx = try Context.init(&damage_buffer, damage_limits);
        ctx.trackDamage();
        const th: lcgf.widgets_base.Theme = .{};
        const font: lcgf.protocol.Mono = .{};
        const px = try gpa.alloc(u32, sw.Framebuffer.len(size[0], size[1]));
        defer gpa.free(px);
        var fb = sw.Framebuffer.init(px, size[0], size[1], .rgba8);
        const glyph_quads = try gpa.alloc(Quad, damage_limits.strings);
        defer gpa.free(glyph_quads);
        var first: [damage_limits.texts]u32 = undefined;
        var count: [damage_limits.texts]u32 = undefined;
        var setup: sw.Setup = .{ .gfx = .{ .images = &images }, .pool = if (pool.count > 1) pool else null };
        const samples = try gpa.alloc(u64, frames);
        defer gpa.free(samples);
        var area: f64 = 0;
        for (0..frames + 1) |k| {
            var in: lcgf.input.Input = .{};
            scene.input(&in, @intCast(k));
            in.viewport = .{ @floatFromInt(size[0]), @floatFromInt(size[1]) };
            // The pointer wanders over the window, so hovers change from frame to frame.
            in.pointer = .{ @floatFromInt((40 + k * 37) % size[0]), @floatFromInt((20 + k * 53) % size[1]) };
            var f = ctx.begin(&in);
            scene.build(&f, &th);
            const d = f.end(font).draw;
            const n = font.quads(d, glyph_quads, .{ .first = &first, .count = &count });
            const t0 = now();
            setup.draw(&fb, d, .{ .quads = glyph_quads[0..n], .first = first[0..d.run_len], .count = count[0..d.run_len], .texture = atlas_tex }, .hex(0x0d0d0fff), 1);
            if (k > 0) {
                samples[k - 1] = now() - t0;
                area += @min(d.damage.pixels(), @as(f32, @floatFromInt(size[0] * size[1])));
            }
        }
        std.mem.sort(u64, samples, {}, std.sort.asc(u64));
        var dims: [16]u8 = undefined;
        try w.print("{s:<12} {s:>9} {d:>12.3} {d:>9.1} {d:>9.1} {d:>8.1}\n", .{
            scene.name,
            try std.fmt.bufPrint(&dims, "{d}x{d}", .{ size[0], size[1] }),
            100 * area / @as(f64, @floatFromInt(frames)) / @as(f64, @floatFromInt(size[0] * size[1])),
            us(samples[0]),
            us(samples[samples.len / 2]),
            us(samples[samples.len * 9 / 10]),
        });
        try w.flush();
    }
}

/// A runtime scene's first frame at `size`, copied out of the context.
fn runtimeScene(gpa: std.mem.Allocator, scene: scenes.Scene, size: [2]u32) !Scene {
    var ctx = try Context.init(&ctx_buffer, limits);
    const th: lcgf.widgets_base.Theme = .{};
    var in: lcgf.input.Input = .{};
    const font: lcgf.protocol.Mono = .{};
    scene.input(&in, 0);
    in.viewport = .{ @floatFromInt(size[0]), @floatFromInt(size[1]) };
    var f = ctx.begin(&in);
    scene.build(&f, &th);
    const d = f.end(font).draw;
    const glyph_quads = try gpa.alloc(Quad, @max(d.strings.len, 1));
    const first = try gpa.alloc(u32, @max(d.run_len, 1));
    const count = try gpa.alloc(u32, @max(d.run_len, 1));
    // The stand-in atlas is texture 1: point every glyph quad at it.
    const n = font.quads(d, glyph_quads, .{ .first = first, .count = count });
    const cmds = try gpa.alloc(Cmd, d.cmd_len);
    for (cmds, 0..) |*c, i| c.* = d.command(@intCast(i));
    return .{
        .name = scene.name,
        .width = size[0],
        .height = size[1],
        .background = .hex(0x0d0d0fff),
        .quads = try gpa.dupe(Quad, d.quads[0..d.quad_len]),
        .glyph_quads = glyph_quads[0..n],
        .first = first[0..d.run_len],
        .count = count[0..d.run_len],
        .cmds = cmds,
    };
}

const Synthetic = enum { rects, rounded, bordered, translucent, glyphs };

/// Isolated quad kinds over the frame: 10,000 boxes of 24x16 (or 40,000 glyph cells of 7x16.8 at
/// fractional x, as `Mono` places 14 px text), in a fixed pseudo-random spread.
fn synthetic(gpa: std.mem.Allocator, kind: Synthetic, size: [2]u32) !Scene {
    var rng = std.Random.DefaultPrng.init(0x5eed);
    const r = rng.random();
    const fw: f32 = @floatFromInt(size[0]);
    const fh: f32 = @floatFromInt(size[1]);
    const n: u32 = if (kind == .glyphs) 40_000 else 10_000;
    const quads = try gpa.alloc(Quad, n);
    for (quads, 0..) |*q, i| {
        const glyph = kind == .glyphs;
        const qw: f32 = if (glyph) 7 else 24;
        const qh: f32 = if (glyph) 16.8 else 16;
        // Glyphs run in lines of text; boxes land on whole pixels.
        const x = if (glyph) @as(f32, @floatFromInt(i % 180)) * 7 + 2 else @floor(r.float(f32) * (fw - qw));
        const y = if (glyph) @as(f32, @floatFromInt((i / 180) % 47)) * 16.8 + 2 else @floor(r.float(f32) * (fh - qh));
        const byte: u8 = @intCast(33 + i % 94);
        const c: u32 = 0xff000000 | r.int(u32);
        q.* = .{
            .rect = .{ x, y, x + qw, y + qh },
            .clip = .{ 0, 0, fw, fh },
            .params = @splat(0),
            .uv = if (glyph) cellUv(byte) else .{ 0, 0, 1, 1 },
            .radii = if (kind == .rounded or kind == .bordered) @splat(6) else @splat(0),
            .fill = switch (kind) {
                .translucent => (c & 0x00ffffff) | 0x80000000,
                .glyphs => 0xffe8e8e8,
                else => c,
            },
            .border_color = 0xff808080,
            .border = if (kind == .bordered) 1 else 0,
            .opacity = 1,
        };
    }
    const cmds = try gpa.alloc(Cmd, 1);
    const first = try gpa.alloc(u32, 1);
    const count = try gpa.alloc(u32, 1);
    first[0] = 0;
    count[0] = n;
    if (kind == .glyphs) {
        cmds[0] = .{ .text = 0 };
    } else {
        cmds[0] = .{ .quads = .{ .first = 0, .count = n, .texture = .white, .material = .solid } };
    }
    return .{
        .name = @tagName(kind),
        .width = size[0],
        .height = size[1],
        .background = .hex(0x0d0d0fff),
        .quads = if (kind == .glyphs) &.{} else quads,
        .glyph_quads = if (kind == .glyphs) quads else &.{},
        .first = first,
        .count = count,
        .cmds = cmds,
    };
}

fn cellUv(byte: u8) [4]f32 {
    const x: f32 = @floatFromInt(byte % 16);
    const y: f32 = @floatFromInt(byte / 16);
    return .{ x / 16, y / 16, (x + 1) / 16, (y + 1) / 16 };
}

/// Antialiased stand-in glyphs: each cell holds an ellipse ring whose shape depends on the byte,
/// white with the coverage as alpha, as a glyph atlas is, so edges carry partial coverage as real
/// glyphs do.
const Atlas = struct {
    px: [atlas_w * atlas_h]u32,
    a8: [atlas_w * atlas_h]u8,
    /// Whether text gets the 8-bit plane (`sw.Image.alpha8`); off times the RGBA texel path.
    coverage: bool = true,

    fn image(a: *const Atlas) sw.Image {
        return .{ .pixels = &a.px, .width = atlas_w, .height = atlas_h, .alpha8 = if (a.coverage) &a.a8 else &.{} };
    }
};

fn makeAtlas() Atlas {
    var out: Atlas = .{ .px = @splat(0), .a8 = @splat(0) };
    for (0..256) |b| {
        const rx = 2.0 + @as(f32, @floatFromInt(b % 3));
        const ry = 4.0 + @as(f32, @floatFromInt(b % 5));
        for (0..cell[1]) |y| for (0..cell[0]) |x| {
            const dx = (@as(f32, @floatFromInt(x)) + 0.5 - 4) / rx;
            const dy = (@as(f32, @floatFromInt(y)) + 0.5 - 8) / ry;
            const d = @abs(@sqrt(dx * dx + dy * dy) - 0.8) * @min(rx, ry);
            const a: u32 = @intFromFloat(@round(std.math.clamp(1.2 - d, 0, 1) * 255));
            const i = ((b / 16) * cell[1] + y) * atlas_w + (b % 16) * cell[0] + x;
            out.px[i] = 0x00ffffff | (a << 24);
            out.a8[i] = @intCast(a);
        };
    }
    return out;
}

/// A frame dumped by draw-dump or conformance-dump, read as sw-play reads it.
fn loadDump(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !Scene {
    var d = try std.Io.Dir.cwd().openDir(io, path, .{});
    defer d.close(io);
    const text = try d.readFileAlloc(io, "cmds.txt", gpa, .limited(1 << 20));
    const quads = try readQuads(io, d, "quads.bin", gpa);
    const glyph_quads = try readQuads(io, d, "glyphs.bin", gpa);
    var width: u32 = 800;
    var height: u32 = 600;
    var first: std.ArrayList(u32) = .empty;
    var count: std.ArrayList(u32) = .empty;
    var cmds: std.ArrayList(Cmd) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        const key = f.next().?;
        var v: [5]f32 = undefined;
        for (&v) |*x| x.* = std.fmt.parseFloat(f32, f.next() orelse "0") catch 0;
        if (std.mem.eql(u8, key, "size")) {
            width = @intFromFloat(v[0]);
            height = @intFromFloat(v[1]);
        } else if (std.mem.eql(u8, key, "quads")) {
            const tex: lcgf.types.Texture = if (v[2] == 0) .white else atlas_tex;
            try cmds.append(gpa, .{ .quads = .{ .first = @intFromFloat(v[0]), .count = @intFromFloat(v[1]), .texture = tex, .material = .solid } });
        } else if (std.mem.eql(u8, key, "text")) {
            try cmds.append(gpa, .{ .text = @intCast(first.items.len) });
            try first.append(gpa, @intFromFloat(v[0]));
            try count.append(gpa, @intFromFloat(v[1]));
        }
    }
    return .{
        .name = std.fs.path.basename(path),
        .width = width,
        .height = height,
        .background = .hex(0x0d0d0fff),
        .quads = quads,
        .glyph_quads = glyph_quads,
        .first = first.items,
        .count = count.items,
        .cmds = cmds.items,
    };
}

fn readQuads(io: std.Io, d: std.Io.Dir, name: []const u8, gpa: std.mem.Allocator) ![]const Quad {
    const bytes = d.readFileAlloc(io, name, gpa, .limited(1 << 26)) catch |e| switch (e) {
        error.FileNotFound => return &.{},
        else => return e,
    };
    const q = try gpa.alloc(Quad, bytes.len / @sizeOf(Quad));
    @memcpy(std.mem.sliceAsBytes(q), bytes[0 .. q.len * @sizeOf(Quad)]);
    return q;
}

/// The scene in the dump format sw-play reads, plus the atlas as raw RGBA words, for bench/cairo.
fn writeDump(io: std.Io, gpa: std.mem.Allocator, path: []const u8, s: *const Scene, atlas: *const Atlas) !void {
    const cwd = std.Io.Dir.cwd();
    const sub = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ path, s.name });
    try cwd.createDirPath(io, sub);
    var d = try cwd.openDir(io, sub, .{});
    defer d.close(io);
    try d.writeFile(io, .{ .sub_path = "quads.bin", .data = std.mem.sliceAsBytes(s.quads) });
    try d.writeFile(io, .{ .sub_path = "glyphs.bin", .data = std.mem.sliceAsBytes(s.glyph_quads) });
    try d.writeFile(io, .{ .sub_path = "atlas.bin", .data = std.mem.sliceAsBytes(&atlas.px) });
    var text: std.ArrayList(u8) = .empty;
    try text.print(gpa, "size {d} {d}\natlas {d} {d}\n", .{ s.width, s.height, atlas_w, atlas_h });
    for (s.cmds) |c| switch (c) {
        .quads => |b| try text.print(gpa, "quads {d} {d} {d}\n", .{ b.first, b.count, @backingInt(b.texture) }),
        .text => |run| try text.print(gpa, "text {d} {d}\n", .{ s.first[run], s.count[run] }),
        .custom => {},
    };
    try d.writeFile(io, .{ .sub_path = "cmds.txt", .data = text.items });
}

/// RGBA rows as a PNG with stored deflate blocks, as sw-play writes them.
fn writePng(io: std.Io, gpa: std.mem.Allocator, path: []const u8, name: []const u8, fb: *const sw.Framebuffer) !void {
    var raw: std.ArrayList(u8) = .empty;
    for (0..fb.height) |y| {
        try raw.append(gpa, 0);
        for (0..fb.width) |x| try raw.appendSlice(gpa, &@as([4]u8, @bitCast(fb.at(@intCast(x), @intCast(y)).bitsOf())));
    }
    var z: std.ArrayList(u8) = .empty;
    try z.appendSlice(gpa, &.{ 0x78, 0x01 });
    var rest = raw.items;
    while (true) {
        const n: u16 = @intCast(@min(rest.len, 0xffff));
        const last = n == rest.len;
        try z.append(gpa, @intFromBool(last));
        try z.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, n)));
        try z.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, ~n)));
        try z.appendSlice(gpa, rest[0..n]);
        rest = rest[n..];
        if (last) break;
    }
    try z.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u32, std.hash.Adler32.hash(raw.items))));
    var png: std.ArrayList(u8) = .empty;
    try png.appendSlice(gpa, "\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], fb.width, .big);
    std.mem.writeInt(u32, ihdr[4..8], fb.height, .big);
    ihdr[8..13].* = .{ 8, 6, 0, 0, 0 };
    for ([_]struct { []const u8, []const u8 }{ .{ "IHDR", &ihdr }, .{ "IDAT", z.items }, .{ "IEND", "" } }) |c| {
        try png.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(c[1].len))));
        try png.appendSlice(gpa, c[0]);
        try png.appendSlice(gpa, c[1]);
        var crc = std.hash.Crc32.init();
        crc.update(c[0]);
        crc.update(c[1]);
        try png.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u32, crc.final())));
    }
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, path);
    const file = try std.fmt.allocPrint(gpa, "{s}/{s}.png", .{ path, name });
    try cwd.writeFile(io, .{ .sub_path = file, .data = png.items });
}

fn us(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1000;
}

fn now() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}
