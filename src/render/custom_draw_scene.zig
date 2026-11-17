//! Append a 56 × 56 sampled node to a 160 × 120 conformance scene.
const lcgf = @import("lcgf");

pub fn addNode(dl: *lcgf.draw_list.DrawList, texture: lcgf.types.Texture) void {
    const q = dl.quad_len;
    dl.quads[q] = .{
        .rect = .{ 96, 56, 152, 112 },
        .clip = .{ -1e6, -1e6, 1e6, 1e6 },
        .params = .{ 0, 0, 0, 0 },
        .uv = .{ 0, 0, 1, 1 },
        .radii = @splat(0),
        .fill = 0xffff_ffff,
        .border_color = 0,
        .border = 0,
        .opacity = 1,
    };
    dl.quad_len += 1;
    const i = dl.cmd_len;
    dl.cmd.kind[i] = @backingInt(lcgf.draw_list.DrawList.Kind.quads);
    dl.cmd.first[i] = q;
    dl.cmd.count[i] = 1;
    dl.cmd.key[i] = @as(u32, @backingInt(texture)) << 16;
    dl.cmd_len += 1;
}
