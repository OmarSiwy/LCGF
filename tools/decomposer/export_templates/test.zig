const std = @import("std");
const page = @import("page");
const lcgf = @import("lcgf");
const font = @import("font");

test "render the editable Zig page into a software framebuffer" {
    const alloc = std.testing.allocator;
    const width = 320;
    const height = 200;
    var app: page.Page = .{};
    const frame = app.frame(&.{ .viewport = .{ width, height } });
    try std.testing.expect(frame.tree.len > 0);

    const sw = lcgf.render_sw;
    const pixels = try alloc.alloc(u32, sw.Framebuffer.len(width, height));
    defer alloc.free(pixels);
    var fb = sw.Framebuffer.init(pixels, width, height, .rgba8);
    fb.clear(.black);

    const draw = frame.draw;
    var glyph_count: usize = 0;
    for (draw.runs[0..draw.run_len]) |run| glyph_count += run.bytes;
    const quads = try alloc.alloc(lcgf.draw_list.Quad, glyph_count);
    defer alloc.free(quads);
    const first = try alloc.alloc(u32, draw.run_len);
    defer alloc.free(first);
    const count = try alloc.alloc(u32, draw.run_len);
    defer alloc.free(count);
    const used = try (lcgf.protocol.Mono{}).quadsFor(font, draw, quads, .{ .first = first, .count = count });
    var renderer: sw.Software = .{ .images = &.{ sw.Image.white, font.image } };
    renderer.prepare({}, draw, .{ .quads = quads[0..used], .first = first, .count = count, .texture = @fromBackingInt(1) }, .{ width, height }, 1);
    lcgf.render_iface.render(&renderer, .{ .fb = &fb, .scissor = fb.all() }, draw);
}
