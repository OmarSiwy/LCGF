//! Writes every conformance scene for a real GPU to draw (conformance/render.py):
//!
//!     conformance-dump OUT     ->  OUT/<scene>/{quad.wgsl, quads.bin, glyphs.bin, cmds.txt}
//!
//! The same files as prototype/dump.zig, plus `size W H` in cmds.txt. The shader and vertex
//! layout are src/render/shaders/quad.zig's (`lcgr.quad_shader`).
const std = @import("std");
const lcgr = @import("lcgr");
const gfx = lcgr.quad_shader;
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
        try dir.writeFile(io, .{ .sub_path = "quad.wgsl", .data = gfx.wgsl });
        try dir.writeFile(io, .{ .sub_path = "quads.bin", .data = d.quadBytes() });
        try dir.writeFile(io, .{ .sub_path = "glyphs.bin", .data = std.mem.sliceAsBytes(st.glyph_quads[0..st.glyph_len]) });

        var text: [4096]u8 = undefined;
        var w = std.Io.Writer.fixed(&text);
        try w.print("size {d} {d}\nstride {d}\n", .{ s.viewport[0], s.viewport[1], gfx.stride });
        for (gfx.attrs) |a| try w.print("attr {d} {d} {s}\n", .{ a.location, a.offset, a.format });
        for (0..d.cmd_len) |i| switch (d.command(@intCast(i))) {
            .quads => |b| try w.print("quads {d} {d} {d} {d}\n", .{ b.first, b.count, @backingInt(b.texture), @backingInt(b.material) }),
            .text => |k| try w.print("text {d} {d}\n", .{ st.first[k], st.count[k] }),
            .custom => |k| try w.print("custom {d} {d} {d} {d} {d}\n", .{ d.customs[k].rect[0], d.customs[k].rect[1], d.customs[k].rect[2], d.customs[k].rect[3], d.customs[k].data }),
        };
        try dir.writeFile(io, .{ .sub_path = "cmds.txt", .data = w.buffered() });
    }
}
