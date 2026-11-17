//! Linked size probe. Every entry point takes runtime data so the linker keeps the renderer.
const ui = @import("lcgf");
const sw = ui.render_sw;
const mode = @import("probe_options").mode;

const spec = switch (mode) {
    0 => ui.spec.col(.{ .fill = .white }, .{}),
    1 => ui.spec.col(.{ .fill = .white, .border = 1, .radius = 4 }, .{ui.spec.label(.caption)}),
    else => ui.spec.Spec{ .kind = .col, .widget = struct {} },
};
const use = ui.ct_features.usage(spec);
const Software = sw.SoftwareFor(use);
const shader = ui.quad_shader.stockFor(use);

export fn stock_shader() [*]const u8 {
    return shader.ptr;
}
export fn paint(fb: *sw.Framebuffer, d: *const ui.draw_list.DrawList, glyphs: *const ui.render_iface.Glyphs, images: [*]const sw.Image, count: usize, scale: f32) void {
    var gfx: Software = .{};
    if (use.image or use.text) gfx.images = images[0..count];
    gfx.prepare({}, d, glyphs.*, .{ 0, 0 }, scale);
    ui.render_iface.render(&gfx, .{ .fb = fb, .scissor = fb.all() }, d);
}

// A byte-indexed 16x16 atlas with 4x4 cells. The fixture's pixels distinguish every cell.
const atlas = blk: {
    @setEvalBranchQuota(10000);
    var src: [64 * 64]u8 = undefined;
    for (&src, 0..) |*v, i| v.* = @truncate((i * 53) ^ (i / 64 * 17));
    break :blk if (mode == 2) src else if (use.text) ui.protocol.StaticAtlas(&.{"Settings"}).pixels(u8, .{ 4, 4 }, &src) else [0]u8{};
};

export fn atlas_pixels() ?[*]const u8 {
    return if (atlas.len > 0) &atlas else null;
}
