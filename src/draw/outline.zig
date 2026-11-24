//! Outside focus/selection rings without a layout box or a retained decoration queue.
//! The small stock path consumes an ordinary transparent quad with a border. For patterned
//! or brush outlines use decoration.Description and its prepared-surface path.

const std = @import("std");
const types = @import("../core/types.zig");
const tree = @import("../core/tree.zig");

pub const Outline = struct {
    width: f32,
    color: types.Color,
    offset: f32 = 0,
    /// Source border-box radii. Absent derives them from the target's current style.
    radii: ?[4]f32 = null,
};

/// Append at the desired point in paint order. `target` must already exist; `parent` is the
/// current open container. The paint reference keeps geometry, opacity and clipping tied to
/// the target even when a surrounding component inserts a label/icon container.
pub fn append(t: *tree.Tree, parent: u32, target: types.Node, options: Outline) types.Node {
    if (t.len >= t.cap) {
        t.overflow = true;
        return .none;
    }
    std.debug.assert(target.ix() < t.len);
    std.debug.assert(std.math.isFinite(options.width) and options.width >= 0 and std.math.isFinite(options.offset));
    const source = target.ix();
    const radii = options.radii orelse tree.radiiOf(t.x.row[t.c.extra[source]].radii, t.c.look[source].radius);
    const growth = options.width + options.offset;
    const expanded: [4]f32 = @max(@as(@Vector(4, f32), radii) + @as(@Vector(4, f32), @splat(growth)), @as(@Vector(4, f32), @splat(0)));
    const n = t.push(parent, .none, &.{
        .float = true,
        .size = .{ .px(0), .px(0) },
        .border = options.width,
        .border_color = options.color,
        .radii = expanded,
        .paint_reference = source,
        .paint_outset = @splat(growth),
    });
    t.seal(n);
    return @fromBackingInt(n);
}

test "outside ring follows current border box without layout or input and escapes own clip" {
    const mem = @import("../core/mem.zig");
    const Texts = @import("../core/texts.zig").Texts;
    const Customs = @import("../core/customs.zig").Customs;
    const DrawList = @import("draw_list.zig").DrawList;
    var raw: [64 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var t = tree.Tree.init(&carver, 8);
    var text = Texts.init(&carver, 1);
    const custom = Customs.init(&carver, 1);
    var draw = DrawList.init(&carver, 8, 1, 1);
    const root = t.push(0, .none, &.{ .size = .{ .px(200), .px(100) }, .pad = @splat(10) });
    const button = t.push(root, .none, &.{ .size = .{ .px(80), .px(40) }, .pad = @splat(8), .border = 3, .border_color = .white, .fill = .black, .clip = true, .radius = 5 });
    const ring = append(&t, button, @fromBackingInt(button), .{ .width = 2, .offset = 3, .color = .rgb(20, 100, 255) });
    t.seal(button);
    t.seal(root);
    @import("../layout/layout.zig").run(&t, &text, .{ 200, 100 });
    @import("paint.zig").emit(&t, &text, &custom, "", &draw);
    try std.testing.expectEqual([4]f32{ 10, 10, 90, 50 }, t.rect(button).array());
    try std.testing.expectEqual([4]f32{ 5, 5, 95, 55 }, draw.quads[draw.quad_len - 1].rect);
    try std.testing.expectEqual(@as(f32, 0), t.c.flow[ring.ix()]);
    try std.testing.expectEqual(@as(u8, 0), t.c.sense[ring.ix()]);
    try std.testing.expectEqual(@as(f32, 3), t.border(button));
    try std.testing.expect(draw.quads[draw.quad_len - 1].clip[0] < 5);
}
