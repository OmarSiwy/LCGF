//! Draws every render conformance scene (src/render/conformance.zig) with the GL ES back end
//! and writes each as a PNG, for comparison with the golden images (ci/jobs/gles.sh):
//!
//!     gles-play OUT [es3|es2]      ->  OUT/<scene>.png
//!
//! es3 (default) is the instanced renderer on a GL ES 3 context, es2 the path without instancing
//! (es2.zig) on a GL ES 2 context.
//!
//! The host side mirrors src/render/conformance/render.py, which drew the goldens: an RGBA8
//! target cleared to black, nearest sampling, scale 1, the same stand-in glyph atlas. Custom
//! commands are drawn by the host's own program between the UI's draws (custom.zig).
const std = @import("std");
const lcgf = @import("lcgf");
const gles = @import("gles.zig");
const gl = gles.gl;
const host = gles.host;
const conformance = lcgf.render_conformance;
const iface = lcgf.render_iface;

var st: conformance.Storage = .{};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    var args = try init.minimal.args.iterateAllocator(gpa);
    _ = args.next();
    const out_path = args.next() orelse return error.MissingOutputDir;
    const es2 = std.mem.eql(u8, args.next() orelse "es3", "es2");
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, out_path);
    var out = try cwd.openDir(io, out_path, .{});
    defer out.close(io);

    var h: host.Host = undefined;
    try h.init(.{ .major = if (es2) 2 else 3 });
    defer h.deinit();
    std.debug.print("gles-play: {s}, {s}\n", .{ h.gl.glGetString(gl.RENDERER).?, h.gl.glGetString(gl.VERSION).? });
    const atlas = h.texture(64, 64, &standInAtlas());
    defer h.deleteTexture(atlas);
    var gradient = try gles.custom.Gradient.init(&h.gl);
    defer gradient.deinit();
    if (es2) {
        const scratch = try gpa.alignedAlloc(u8, .of(lcgf.draw_list.Quad), gles.es2.scratchBytes(.{}));
        var gfx = try gles.es2.Renderer.init(&h.gl, .{}, scratch);
        defer gfx.deinit();
        try drawScenes(io, gpa, out, &h, &gfx, &gradient, gfx.addTexture(atlas, 64, 64));
    } else {
        var gfx = try gles.Renderer.init(&h.gl, &h.gl3, .{});
        defer gfx.deinit();
        try drawScenes(io, gpa, out, &h, &gfx, &gradient, gfx.addTexture(atlas));
    }
}

fn drawScenes(io: std.Io, gpa: std.mem.Allocator, out: std.Io.Dir, h: *host.Host, gfx: anytype, gradient: *const gles.custom.Gradient, atlas: lcgf.types.Texture) !void {
    for (&conformance.scenes) |*s| {
        st.load(s);
        const w: u32 = @intFromFloat(s.viewport[0]);
        const ht: u32 = @intFromFloat(s.viewport[1]);
        var target = try host.Target.init(h, w, ht);
        defer target.deinit(h);
        var glyphs = st.glyphs();
        glyphs.texture = atlas;
        gfx.prepare({}, &st.draw, glyphs, s.viewport, 1);
        target.begin(h, .{ 0, 0, 0, 1 });
        // The host's loop: UI draws up to each custom command, its own program there.
        var i = iface.drawUntilCustom(gfx, {}, &st.draw, 0);
        while (i < st.draw.cmd_len) : (i = iface.drawUntilCustom(gfx, {}, &st.draw, i + 1)) {
            gradient.draw(gfx.customScissor(st.draw.customs[st.draw.command(i).custom]), gfx.extent);
        }
        const px = try gpa.alloc(u8, @as(usize, w) * ht * 4);
        h.readback(w, ht, px);
        try h.check();
        var name: [64]u8 = undefined;
        try out.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&name, "{s}.png", .{s.name}), .data = try png(gpa, w, ht, px) });
    }
}

/// render.py's stand-in glyph atlas: 16x16 cells of 4x4 texels, every printable byte a 2x3
/// block of opaque white.
fn standInAtlas() [64 * 64 * 4]u8 {
    var px: [64 * 64 * 4]u8 = @splat(0);
    for (33..127) |byte| {
        const cx = byte & 15;
        const cy = byte >> 4;
        for (1..4) |y| for (1..3) |x| {
            const o = ((cy * 4 + y) * 64 + cx * 4 + x) * 4;
            px[o..][0..4].* = @splat(0xff);
        };
    }
    return px;
}

/// RGBA rows as a PNG (filter byte 0 before each row).
fn png(gpa: std.mem.Allocator, w: u32, h: u32, rgba: []const u8) ![]const u8 {
    var raw: std.ArrayList(u8) = .empty;
    for (0..h) |y| {
        try raw.append(gpa, 0);
        try raw.appendSlice(gpa, rgba[y * w * 4 ..][0 .. w * 4]);
    }
    return lcgf.png.encodeForTest(gpa, w, h, 8, .rgba, false, &.{}, raw.items);
}
