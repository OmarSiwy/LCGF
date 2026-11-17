//! Draws every render conformance scene (src/render/conformance.zig) with the Vulkan back end
//! and writes each as a PNG, for comparison with the golden images (ci/jobs/vk.sh):
//!
//!     vk-play OUT [offscreen|present] [SAMPLES]      ->  OUT/<scene>.png
//!
//! The drawing is scenes.zig's `Player`: offscreen into an RGBA8 image, or present through a
//! headless swapchain; SAMPLES (default 1) above 1 resolves a multisampled target.
const std = @import("std");
const lcgf = @import("lcgf");
const scenes = @import("scenes.zig");
const conformance = lcgf.render_conformance;

var player: scenes.Player = undefined;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    var args = try init.minimal.args.iterateAllocator(gpa);
    _ = args.next();
    const out_path = args.next() orelse return error.MissingOutputDir;
    const mode = std.meta.stringToEnum(scenes.Mode, args.next() orelse "offscreen") orelse return error.UnknownMode;
    const samples = try std.fmt.parseInt(u32, args.next() orelse "1", 10);
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, out_path);
    var out = try cwd.openDir(io, out_path, .{});
    defer out.close(io);

    try player.init(mode, samples);
    defer player.deinit();
    const w = scenes.size.width;
    const h = scenes.size.height;
    const px = try gpa.alloc(u8, @as(usize, w) * h * 4);
    for (&conformance.scenes) |*s| {
        try player.draw(s, px);
        var name: [64]u8 = undefined;
        try out.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&name, "{s}.png", .{s.name}), .data = try png(gpa, w, h, px) });
    }
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
