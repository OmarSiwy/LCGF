//! Logical box dimensions and edges resolved to the existing physical layout columns.
//! This maps boxes and flow direction; vertical glyph shaping/orientation is a separate text
//! capability. No writing-mode state is hidden in the tree or its renderer.

const std = @import("std");
const types = @import("../core/types.zig");
const mem = @import("../core/mem.zig");
const simd = @import("../core/simd.zig");
const Tree = @import("../core/tree.zig").Tree;
const Flex = @import("flex.zig").Flex;

pub const WritingMode = enum(u8) { horizontal_tb, vertical_rl, vertical_lr, sideways_rl, sideways_lr };
pub const Direction = enum { ltr, rtl };
pub const Axis = enum { inline_axis, block_axis };
pub const Flow = struct {
    writing: WritingMode = .horizontal_tb,
    direction: Direction = .ltr,

    pub const Axes = struct { inline_axis: u1, block_axis: u1, inline_sign: f32, block_sign: f32 };

    pub fn axes(flow: Flow) Axes {
        const k = @backingInt(flow.writing);
        const inline_axes = [5]u1{ 0, 1, 1, 1, 1 };
        const inline_signs = [5]f32{ 1, 1, 1, 1, -1 };
        const block_signs = [5]f32{ 1, -1, 1, -1, 1 };
        return .{
            .inline_axis = inline_axes[k],
            .block_axis = 1 - inline_axes[k],
            .inline_sign = inline_signs[k] * (if (flow.direction == .ltr) @as(f32, 1) else -1),
            .block_sign = block_signs[k],
        };
    }

    /// inline-start, block-start, inline-end, block-end to left, top, right, bottom.
    pub fn edges(flow: Flow, logical: [4]f32) [4]f32 {
        const a = flow.axes();
        const i: usize = a.inline_axis;
        const b: usize = a.block_axis;
        const reverse_i = @as(usize, @intFromBool(a.inline_sign < 0)) * 2;
        const reverse_b = @as(usize, @intFromBool(a.block_sign < 0)) * 2;
        var out: [4]f32 = undefined;
        out[i + reverse_i] = logical[0];
        out[b + reverse_b] = logical[1];
        out[i + 2 - reverse_i] = logical[2];
        out[b + 2 - reverse_b] = logical[3];
        return out;
    }

    /// Logical inline/block sizes, directly usable as Style.size.
    pub fn sizes(flow: Flow, inline_size: types.Size, block_size: types.Size) [2]types.Size {
        const a = flow.axes();
        var out: [2]types.Size = undefined;
        out[a.inline_axis] = inline_size;
        out[a.block_axis] = block_size;
        return out;
    }

    /// A displacement along the logical axes, directly usable as Style.offset. Insets from
    /// an end edge still require the containing box; this is a signed displacement only.
    pub fn offset(flow: Flow, inline_delta: f32, block_delta: f32) [2]f32 {
        const a = flow.axes();
        var out: [2]f32 = undefined;
        out[a.inline_axis] = inline_delta * a.inline_sign;
        out[a.block_axis] = block_delta * a.block_sign;
        return out;
    }

    pub fn mainAxis(flow: Flow, axis: Axis) types.Axis {
        const a = flow.axes();
        return @fromBackingInt(if (axis == .inline_axis) a.inline_axis else a.block_axis);
    }

    /// Applies logical margins directly to the optional Flex table, before fitFlex.
    pub fn margins(flow: Flow, flex: *Flex, node: u32, logical: [4]f32) void {
        const values = flow.edges(logical);
        inline for (0..2) |a| {
            flex.c.margin_lo[a][node] = values[a];
            flex.c.margin_hi[a][node] = values[a + 2];
        }
    }
};

/// Optional physical direction coefficients. Set them while building nodes, after resolving
/// any inherited writing mode in the application/style layer. Plain layout needs no table.
pub const Mirrors = struct {
    sign: [2][]f32,
    shift: [2][]f32,

    pub fn init(carver: *mem.Carver, capacity: u32) Mirrors {
        const cols = carver.columns(struct { sign: [2][]f32, shift: [2][]f32 }, simd.rows(capacity));
        inline for (0..2) |a| @memset(cols.sign[a], 1);
        return .{ .sign = cols.sign, .shift = cols.shift };
    }

    pub fn set(m: *Mirrors, node: u32, flow: Flow) void {
        const a = flow.axes();
        m.sign[a.inline_axis][node] = a.inline_sign;
        m.sign[a.block_axis][node] = a.block_sign;
    }
};

/// After place, before finalize/anchors: mirror each parent's children on its negative axes
/// and carry the displacement through descendants. Scalar forward dependency walk, branchless
/// per row; equivalent to rtl.mirror on horizontal RTL layouts, also handles block-axis reversal.
pub fn mirror(t: *Tree, m: *Mirrors) void {
    if (t.len == 0) return;
    inline for (0..2) |a| {
        m.shift[a][0] = 0;
        const pos = t.c.pos[a];
        const size = t.c.size[a];
        const lo = t.c.pad_lo[a];
        const hi = t.c.pad_hi[a];
        const sign = m.sign[a];
        const shift = m.shift[a];
        for (1..t.len) |i| {
            const parent = t.c.parent[i];
            const inner = size[parent] - lo[parent] - hi[parent];
            const rel = pos[i] - (pos[parent] - shift[parent]) - lo[parent];
            shift[i] = shift[parent] + (1 - sign[parent]) * 0.5 * (inner - size[i] - 2 * rel);
            pos[i] += shift[i];
        }
    }
}

test "logical edges sizes margins and reversed block flow reach physical box geometry" {
    const layout = @import("layout.zig");
    const Texts = @import("../core/texts.zig").Texts;
    var bytes: [64 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &bytes };
    var t: Tree = .init(&carver, 4);
    const tx: Texts = .init(&carver, 1);
    var flex: Flex = .init(&carver, 4);
    var mirrors: Mirrors = .init(&carver, 4);
    const flow: Flow = .{ .writing = .vertical_rl };
    const root = t.push(0, .none, &.{ .dir = flow.mainAxis(.block_axis), .pad = flow.edges(.{ 5, 10, 7, 12 }) });
    mirrors.set(root, flow);
    const first = t.push(root, .none, &.{ .size = flow.sizes(.px(20), .px(30)) });
    t.seal(first);
    const second = t.push(root, .none, &.{ .size = flow.sizes(.px(20), .px(30)) });
    t.seal(second);
    t.seal(root);
    layout.prepare(&t);
    inline for (.{ types.Axis.x, .y }, 0..) |axis, a| {
        layout.applyText(&t, &tx, axis);
        layout.fit(&t, axis);
        layout.resolve(&t, axis, ([2]f32{ 100, 80 })[a]);
    }
    layout.place(&t);
    mirror(&t, &mirrors);
    layout.finalize(&t);
    try std.testing.expectEqual([4]f32{ 60, 5, 90, 25 }, t.rect(first).array());
    try std.testing.expectEqual([4]f32{ 30, 5, 60, 25 }, t.rect(second).array());
    flow.margins(&flex, first, .{ 1, 2, 3, 4 });
    try std.testing.expectEqual([4]f32{ 4, 1, 2, 3 }, [4]f32{ flex.c.margin_lo[0][first], flex.c.margin_lo[1][first], flex.c.margin_hi[0][first], flex.c.margin_hi[1][first] });
    try std.testing.expectEqual([2]f32{ -4, 2 }, flow.offset(2, 4));
    const rtl: Flow = .{ .direction = .rtl };
    try std.testing.expectEqual([4]f32{ 3, 2, 1, 4 }, rtl.edges(.{ 1, 2, 3, 4 }));
    try std.testing.expectEqual(@as(u1, 1), flow.axes().inline_axis);
}
