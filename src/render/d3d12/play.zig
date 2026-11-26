//! Draws every render conformance scene (src/render/conformance.zig) with the Direct3D 12 back
//! end and writes each as a PNG, for comparison with the golden images (ci/jobs/d3d12.sh):
//!
//!     d3d12-play.exe OUT [offscreen|present]      ->  OUT/<scene>.png, OUT/canvas.png
//!
//! The drawing is scenes.zig's `Player`: offscreen into an RGBA8 texture, or presented through
//! a hidden window's waitable flip-model swapchain.
const std = @import("std");
const lcgf = @import("lcgf");
const scenes = @import("scenes.zig");
const conformance = lcgf.render_conformance;

var player: scenes.Player = undefined;
var canvas: conformance.CanvasStorage = undefined;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    var args = try init.minimal.args.iterateAllocator(gpa);
    _ = args.next();
    const out_path = args.next() orelse return error.MissingOutputDir;
    const mode = std.meta.stringToEnum(scenes.Mode, args.next() orelse "offscreen") orelse return error.UnknownMode;
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, out_path);
    var out = try cwd.openDir(io, out_path, .{});
    defer out.close(io);

    try player.init(mode);
    defer player.deinit();
    const px = try gpa.alloc(u8, scenes.width * scenes.height * 4);
    for (&conformance.scenes) |*s| {
        try player.draw(s, px);
        var name: [64]u8 = undefined;
        try out.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&name, "{s}.png", .{s.name}), .data = try png(gpa, scenes.width, scenes.height, px) });
    }
    // The canvas scene (golden tools/golden/ref/draw/canvas.png), offscreen in either mode.
    canvas.load();
    const sc = conformance.canvas_scene;
    const cw: u32 = @intFromFloat(sc.viewport[0]);
    const ch: u32 = @intFromFloat(sc.viewport[1]);
    const cpx = try gpa.alloc(u8, @as(usize, cw) * ch * 4);
    try player.drawCanvas(&canvas, cpx);
    try out.writeFile(io, .{ .sub_path = "canvas.png", .data = try png(gpa, cw, ch, cpx) });
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
