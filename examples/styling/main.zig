//! Regenerate the checked-in styling gallery with `zig build styling-gallery -Dgallery-output=output.png`.
const std = @import("std");
const lcgf = @import("lcgf");
const gallery = @import("gallery.zig");

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const path = args.next() orelse "styling-gallery.png";
    if (args.next() != null) return error.UnexpectedArgument;
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const dst = try lcgf.surface.init(try a.alloc(u32, try lcgf.surface.requiredPixels(gallery.width, gallery.height)), gallery.width, gallery.height);
    try gallery.render(a, dst);
    const pixels = try a.alloc(u32, gallery.width * gallery.height);
    try lcgf.surface.exportRGBA(dst, pixels, gallery.width, .straight);
    const stride = 1 + 4 * gallery.width;
    const raw = try a.alloc(u8, stride * gallery.height);
    for (0..gallery.height) |y| {
        raw[y * stride] = 0; // PNG's unfiltered scanline.
        for (0..gallery.width) |x| std.mem.writeInt(u32, raw[y * stride + 1 + 4 * x ..][0..4], pixels[y * gallery.width + x], .little);
    }
    const encoded = try lcgf.png.encodeForTest(a, gallery.width, gallery.height, 8, .rgba, false, &.{}, raw);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = encoded });
}
