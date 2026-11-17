//! Writes every shader variant for validate.py (ci/jobs/shaders.sh):
//!
//!     shaders-dump OUT     ->  OUT/<variant>.wgsl, OUT/layout.txt (stride, attr lines as cmds.txt)
const std = @import("std");
const gfx = @import("lcgr").quad_shader;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const out_path = args.next() orelse return error.MissingOutputDir;
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, out_path);
    var dir = try cwd.openDir(io, out_path, .{});
    defer dir.close(io);

    var name: [64]u8 = undefined;
    const specialized = [_]gfx.Variant{
        .{ .name = "solid", .wgsl = gfx.stockFor(.{}) },
        .{ .name = "text", .wgsl = gfx.stockFor(.{ .text = true }) },
        .{ .name = "rounded-border", .wgsl = gfx.stockFor(.{ .radius = true, .border = true }) },
        .{ .name = "stock-features", .wgsl = gfx.stockFor(.{ .radius = true, .border = true, .image = true, .kinds = .full }) },
    };
    const variants: []const gfx.Variant = if (args.next()) |mode| blk: {
        if (!std.mem.eql(u8, mode, "--specialized")) return error.UnknownArgument;
        break :blk &specialized;
    } else &gfx.variants;
    for (variants) |v|
        try dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&name, "{s}.wgsl", .{v.name}), .data = v.wgsl });
    var text: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&text);
    try w.print("stride {d}\n", .{gfx.stride});
    for (gfx.attrs) |a| try w.print("attr {d} {d} {s}\n", .{ a.location, a.offset, a.format });
    try dir.writeFile(io, .{ .sub_path = "layout.txt", .data = w.buffered() });
}
