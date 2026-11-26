//! Custom cursor artwork as an ordinary last draw command. The caller owns and uploads the
//! image, retains the previous bounds, and requests Platform.cursor = .hidden while it is
//! visible. Enable Context.track_pointer while using an overlay, so unsensed moves repaint.
//!
//! For partial redraw: call bounds, add old/new bounds to scene damage, cull the complete
//! scene with that damage, then emit and render. The caller also damages old bounds when
//! the pointer leaves. No hidden retained state, resource registry or allocation.
const std = @import("std");
const types = @import("../core/types.zig");
const Input = @import("../core/input.zig").Input;
const draw = @import("draw_list.zig");
const damage = @import("damage.zig");

pub const Image = struct {
    texture: types.Texture,
    /// Logical pixels. Upload/select a higher resolution source at higher display scales.
    size: [2]f32,
    /// Logical offset from the top-left corner to the pointer's exact input position.
    hotspot: [2]f32 = .{ 0, 0 },
    uv: [4]f32 = .{ 0, 0, 1, 1 },
    tint: types.Color = .white,
};
pub const Error = error{ InvalidImage, InvalidGeometry, NoSpace };

pub fn bounds(input: Input, image: Image) Error!?types.Rect {
    for (image.size ++ image.hotspot ++ image.uv) |value| if (!std.math.isFinite(value)) return error.InvalidImage;
    if (image.size[0] <= 0 or image.size[1] <= 0 or image.hotspot[0] < 0 or image.hotspot[1] < 0 or image.hotspot[0] >= image.size[0] or image.hotspot[1] >= image.size[1]) return error.InvalidImage;
    for (input.pointer ++ input.viewport) |value| if (!std.math.isFinite(value)) return error.InvalidGeometry;
    if (input.viewport[0] < 0 or input.viewport[1] < 0) return error.InvalidGeometry;
    if (input.pointer[0] < 0 or input.pointer[1] < 0 or input.pointer[0] >= input.viewport[0] or input.pointer[1] >= input.viewport[1]) return null;
    const x = input.pointer[0] - image.hotspot[0];
    const y = input.pointer[1] - image.hotspot[1];
    return .{ .x0 = x, .y0 = y, .x1 = x + image.size[0], .y1 = y + image.size[1] };
}

pub fn damageBounds(region: *damage.Region, previous: ?types.Rect, current: ?types.Rect) void {
    if (previous) |r| region.add(.{ r.x0, r.y0, r.x1, r.y1 });
    if (current) |r| region.add(.{ r.x0, r.y0, r.x1, r.y1 });
}

/// After scene paint, preparation, ordering and optional damage culling. No tree node is
/// created: the cursor cannot take input focus or affect layout/accessibility. Returns the
/// bounds to retain for the next damage calculation. On error command counts are unchanged.
pub fn emit(list: *draw.DrawList, input: Input, image: Image) Error!?types.Rect {
    const rect = (try bounds(input, image)) orelse return null;
    const q = list.quad_len;
    const cmd = list.cmd_len;
    if (q >= list.quads.len or cmd >= list.cmd.kind.len or cmd >= list.cmd.first.len or cmd >= list.cmd.count.len or cmd >= list.cmd.key.len) return error.NoSpace;
    list.quads[q] = .{
        .rect = .{ rect.x0, rect.y0, rect.x1, rect.y1 },
        .clip = .{ 0, 0, input.viewport[0], input.viewport[1] },
        .params = @splat(0),
        .uv = image.uv,
        .radii = @splat(0),
        .fill = image.tint.bitsOf(),
        .border_color = 0,
        .border = 0,
        .opacity = 1,
    };
    list.cmd.kind[cmd] = @backingInt(draw.DrawList.Kind.quads);
    list.cmd.first[cmd] = q;
    list.cmd.count[cmd] = 1;
    list.cmd.key[cmd] = @as(u32, @backingInt(image.texture)) << 16;
    // Zero is in front of every depthOrder result. The image still blends in paint order.
    if (q < list.depth.quad.len) list.depth.quad[q] = 0;
    if (cmd < list.depth.cmd.len) list.depth.cmd[cmd] = 0;
    list.quad_len += 1;
    list.cmd_len += 1;
    return rect;
}

test "custom cursor uploads through ordinary image draw, respects hotspot and damages movement" {
    const mem = @import("../core/mem.zig");
    const sw = @import("../render/sw/sw.zig");
    const iface = @import("../render/iface.zig");
    const n = comptime blk: {
        var c: mem.Carver = .{ .buf = null };
        _ = draw.DrawList.init(&c, 8, 1, 1);
        break :blk c.off;
    };
    var bytes: [n]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &bytes };
    var list = draw.DrawList.init(&carver, 8, 1, 1);
    const sprite: Image = .{ .texture = @fromBackingInt(1), .size = .{ 4, 4 }, .hotspot = .{ 1, 2 } };
    const input: Input = .{ .pointer = .{ 3, 5 }, .viewport = .{ 8, 8 } };
    const first = try emit(&list, input, sprite);
    try std.testing.expectEqual(@as(f32, 2), first.?.x0);
    try std.testing.expectEqual(@as(f32, 3), first.?.y0);
    var pixels: [sw.Framebuffer.len(8, 8)]u32 = @splat(0);
    var fb = sw.Framebuffer.init(&pixels, 8, 8, .rgba8);
    const red = types.Color.rgb(255, 0, 0).bitsOf();
    const blue = types.Color.rgb(0, 0, 255).bitsOf();
    const images = [_]sw.Image{ .white, .{ .pixels = &.{ red, blue, blue, red }, .width = 2, .height = 2 } };
    var renderer: sw.Software = .{ .images = &images };
    renderer.prepare({}, &list, .{}, input.viewport, 1);
    iface.render(&renderer, .{ .fb = &fb, .scissor = fb.all() }, &list);
    try std.testing.expectEqual(red, fb.at(2, 3).bitsOf());
    try std.testing.expectEqual(blue, fb.at(5, 3).bitsOf());
    try std.testing.expectEqual(@as(u32, 0), fb.at(1, 3).bitsOf());
    var moved = input;
    moved.pointer = .{ 7, 6 };
    var region: damage.Region = .{};
    damageBounds(&region, first, try bounds(moved, sprite));
    try std.testing.expect(region.touches(.{ 2, 3, 3, 4 }));
    try std.testing.expect(region.touches(.{ 6, 4, 7, 5 }));
    moved.pointer = Input.outside;
    const commands = list.cmd_len;
    try std.testing.expectEqual(null, try emit(&list, moved, sprite));
    try std.testing.expectEqual(commands, list.cmd_len);
    var invalid = sprite;
    invalid.hotspot[0] = 4;
    try std.testing.expectError(error.InvalidImage, emit(&list, input, invalid));
    list.quad_len = @intCast(list.quads.len);
    try std.testing.expectError(error.NoSpace, emit(&list, input, sprite));
    try std.testing.expectEqual(commands, list.cmd_len);
}
