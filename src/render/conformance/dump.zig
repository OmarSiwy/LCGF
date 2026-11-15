//! Writes every conformance scene for a real GPU to draw (conformance/render.py):
//!
//!     conformance-dump OUT     ->  OUT/<scene>/{quad.wgsl, quads.bin, glyphs.bin, cmds.txt}
//!
//! The same files as prototype/dump.zig, plus `size W H` in cmds.txt. The shader and vertex
//! layout come from prototype/ui_wgpu.zig (module `proto_wgpu`) until src/render has its own
//! WGSL (lane shaders, C0353).
const std = @import("std");
const lcgr = @import("lcgr");
const gfx = @import("proto_wgpu");
const conformance = lcgr.render_conformance;

var st: conformance.Storage = .{};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const out_path = args.next() orelse return error.MissingOutputDir;
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, out_path);
    var root = try cwd.openDir(io, out_path, .{});
    defer root.close(io);

    for (&conformance.scenes) |*s| {
        st.load(s);
        const d = &st.draw;
        try root.createDirPath(io, s.name);
        var dir = try root.openDir(io, s.name, .{});
        defer dir.close(io);
        try dir.writeFile(io, .{ .sub_path = "quad.wgsl", .data = comptime gfx.shader(gfx.default_material) });
        try dir.writeFile(io, .{ .sub_path = "quads.bin", .data = d.quadBytes() });
        try dir.writeFile(io, .{ .sub_path = "glyphs.bin", .data = std.mem.sliceAsBytes(st.glyph_quads[0..st.glyph_len]) });

        var text: [4096]u8 = undefined;
        var w = std.Io.Writer.fixed(&text);
        try w.print("size {d} {d}\nstride {d}\n", .{ s.viewport[0], s.viewport[1], gfx.quad_stride });
        for (gfx.quad_attrs) |a| try w.print("attr {d} {d} {s}\n", .{ a.location, a.offset, @tagName(a.format) });
        for (0..d.cmd_len) |i| switch (d.command(@intCast(i))) {
            .quads => |b| try w.print("quads {d} {d} {d} {d}\n", .{ b.first, b.count, @backingInt(b.texture), @backingInt(b.material) }),
            .text => |k| try w.print("text {d} {d}\n", .{ st.first[k], st.count[k] }),
            .custom => |k| try w.print("custom {d} {d} {d} {d} {d}\n", .{ d.customs[k].rect[0], d.customs[k].rect[1], d.customs[k].rect[2], d.customs[k].rect[3], d.customs[k].data }),
        };
        try dir.writeFile(io, .{ .sub_path = "cmds.txt", .data = w.buffered() });
    }
}

comptime {
    // The prototype's vertex layout must describe this Quad, byte for byte.
    std.debug.assert(gfx.quad_stride == @sizeOf(lcgr.draw_list.Quad));
}
