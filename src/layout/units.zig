//! Typed lengths and bounded expressions resolved before writing ordinary layout inputs.
//! Pure values in, logical pixels / existing Size coefficients out. Caller-owned expression
//! scratch is optional; the common single-unit path needs none. No style registry is involved.

const std = @import("std");
const Size = @import("../core/types.zig").Size;

pub const Unit = enum {
    px,
    device_px,
    percent,
    em,
    rem,
    ex,
    ch,
    lh,
    rlh,
    vw,
    vh,
    vi,
    vb,
    vmin,
    vmax,
    svw,
    svh,
    lvw,
    lvh,
    dvw,
    dvh,
    cqw,
    cqh,
    cqi,
    cqb,
    cqmin,
    cqmax,
    pt,
    pc,
    inch,
    cm,
    mm,
    quarter_mm,
    safe_left,
    safe_top,
    safe_right,
    safe_bottom,
};
pub const Value = struct { amount: f32, unit: Unit = .px };

pub const Context = struct {
    /// The appropriate containing size for this property's percentage; null is indefinite.
    reference: ?f32 = null,
    /// Effective font size, after application/system text scaling.
    font_px: f32 = 16,
    root_font_px: f32 = 16,
    x_height: ?f32 = null,
    zero_advance: ?f32 = null,
    line_height: ?f32 = null,
    root_line_height: ?f32 = null,
    viewport: [2]f32 = .{ 0, 0 },
    small_viewport: ?[2]f32 = null,
    large_viewport: ?[2]f32 = null,
    dynamic_viewport: ?[2]f32 = null,
    container: ?[2]f32 = null,
    inline_axis: u1 = 0,
    device_scale: f32 = 1,
    /// left, top, right, bottom, logical pixels supplied by the host.
    safe_area: [4]f32 = @splat(0),
};

pub const Error = error{ Indefinite, NonFinite, NoSpace, InvalidExpression };

/// Resolves one value. Percentages/font metrics/container units requiring an unavailable
/// basis report Indefinite instead of guessing. Viewport variants default to the given
/// viewport when the host has no distinct small/large/dynamic geometry.
pub fn resolve(value: Value, cx: Context) Error!f32 {
    if (!std.math.isFinite(value.amount)) return error.NonFinite;
    if (value.amount == 0) return 0;
    const small = cx.small_viewport orelse cx.viewport;
    const large = cx.large_viewport orelse cx.viewport;
    const dynamic = cx.dynamic_viewport orelse cx.viewport;
    const unit: f32 = switch (value.unit) {
        .px => 1,
        .device_px => if (cx.device_scale > 0) 1 / cx.device_scale else return error.Indefinite,
        .percent => (cx.reference orelse return error.Indefinite) * 0.01,
        .em => cx.font_px,
        .rem => cx.root_font_px,
        .ex => cx.x_height orelse return error.Indefinite,
        .ch => cx.zero_advance orelse return error.Indefinite,
        .lh => cx.line_height orelse return error.Indefinite,
        .rlh => cx.root_line_height orelse return error.Indefinite,
        .vw => cx.viewport[0] * 0.01,
        .vh => cx.viewport[1] * 0.01,
        .vi => cx.viewport[cx.inline_axis] * 0.01,
        .vb => cx.viewport[1 - cx.inline_axis] * 0.01,
        .vmin => @min(cx.viewport[0], cx.viewport[1]) * 0.01,
        .vmax => @max(cx.viewport[0], cx.viewport[1]) * 0.01,
        .svw => small[0] * 0.01,
        .svh => small[1] * 0.01,
        .lvw => large[0] * 0.01,
        .lvh => large[1] * 0.01,
        .dvw => dynamic[0] * 0.01,
        .dvh => dynamic[1] * 0.01,
        .cqw => (cx.container orelse return error.Indefinite)[0] * 0.01,
        .cqh => (cx.container orelse return error.Indefinite)[1] * 0.01,
        .cqi => (cx.container orelse return error.Indefinite)[cx.inline_axis] * 0.01,
        .cqb => (cx.container orelse return error.Indefinite)[1 - cx.inline_axis] * 0.01,
        .cqmin => blk: {
            const c = cx.container orelse return error.Indefinite;
            break :blk @min(c[0], c[1]) * 0.01;
        },
        .cqmax => blk: {
            const c = cx.container orelse return error.Indefinite;
            break :blk @max(c[0], c[1]) * 0.01;
        },
        .pt => 96.0 / 72.0,
        .pc => 16,
        .inch => 96,
        .cm => 96.0 / 2.54,
        .mm => 96.0 / 25.4,
        .quarter_mm => 96.0 / 101.6,
        .safe_left => cx.safe_area[0],
        .safe_top => cx.safe_area[1],
        .safe_right => cx.safe_area[2],
        .safe_bottom => cx.safe_area[3],
    };
    const result = value.amount * unit;
    return if (std.math.isFinite(result)) result else error.NonFinite;
}

/// Size percentages remain deferred native coefficients when their parent is indefinite.
/// Other units resolve now. This preserves the layout engine's existing percent dependency
/// behavior and avoids inserting a hidden re-measure or convergence loop.
pub fn size(value: Value, cx: Context) Error!Size {
    if (value.unit == .percent and cx.reference == null) {
        if (!std.math.isFinite(value.amount)) return error.NonFinite;
        return .pct(@max(value.amount * 0.01, 0));
    }
    return .px(@max(try resolve(value, cx), 0));
}

/// Reverse Polish expression instructions. Addition/subtraction/min/max consume two values;
/// clamp consumes min, preferred, max. Scale multiplies the top value by a unitless scalar.
pub const Op = union(enum) { value: Value, add, subtract, min, max, clamp, scale: f32 };

/// Bounded calc/min/max/clamp evaluation; all stack storage is the caller's. Invalid programs
/// and nonfinite intermediate results are rejected instead of leaking invalid geometry.
pub fn evaluate(program: []const Op, cx: Context, scratch: []f32) Error!f32 {
    var n: usize = 0;
    for (program) |op| {
        switch (op) {
            .value => |v| {
                if (n == scratch.len) return error.NoSpace;
                scratch[n] = try resolve(v, cx);
                n += 1;
            },
            .scale => |v| {
                if (n == 0) return error.InvalidExpression;
                scratch[n - 1] *= v;
            },
            .clamp => {
                if (n < 3) return error.InvalidExpression;
                scratch[n - 3] = @max(scratch[n - 3], @min(scratch[n - 2], scratch[n - 1]));
                n -= 2;
            },
            else => {
                if (n < 2) return error.InvalidExpression;
                const a = scratch[n - 2];
                const b = scratch[n - 1];
                scratch[n - 2] = switch (op) {
                    .add => a + b,
                    .subtract => a - b,
                    .min => @min(a, b),
                    .max => @max(a, b),
                    else => unreachable,
                };
                n -= 1;
            },
        }
        if (n > 0 and !std.math.isFinite(scratch[n - 1])) return error.NonFinite;
    }
    return if (n == 1) scratch[0] else error.InvalidExpression;
}

test "relative units and expressions feed real layout without a manager or hidden passes" {
    const mem = @import("../core/mem.zig");
    const Tree = @import("../core/tree.zig").Tree;
    const Texts = @import("../core/texts.zig").Texts;
    const layout = @import("layout.zig");
    var bytes: [16 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &bytes };
    var tree: Tree = .init(&carver, 3);
    var tx: Texts = .init(&carver, 1);
    const cx: Context = .{ .viewport = .{ 400, 200 }, .font_px = 20, .zero_advance = 10, .safe_area = .{ 0, 12, 0, 0 } };
    const root = tree.push(0, .none, &.{ .pad = .{ 0, try resolve(.{ .amount = 1, .unit = .safe_top }, cx), 0, 0 } });
    const child = tree.push(root, .none, &.{ .size = .{ try size(.{ .amount = 50, .unit = .percent }, cx), try size(.{ .amount = 2, .unit = .em }, cx) } });
    tree.seal(child);
    tree.seal(root);
    layout.run(&tree, &tx, .{ 400, 200 });
    try std.testing.expectEqual(@as(f32, 200), tree.c.size[0][child]);
    try std.testing.expectEqual(@as(f32, 40), tree.c.size[1][child]);
    try std.testing.expectEqual(@as(f32, 12), tree.c.pos[1][child]);
    var scratch: [4]f32 = undefined;
    // clamp(16px, 10vw - 1ch, 32px) = 30px.
    const result = try evaluate(&.{ .{ .value = .{ .amount = 16 } }, .{ .value = .{ .amount = 10, .unit = .vw } }, .{ .value = .{ .amount = 1, .unit = .ch } }, .subtract, .{ .value = .{ .amount = 32 } }, .clamp }, cx, &scratch);
    try std.testing.expectEqual(30, result);
    try std.testing.expectError(error.Indefinite, resolve(.{ .amount = 50, .unit = .cqi }, cx));
    try std.testing.expectError(error.Indefinite, resolve(.{ .amount = 50, .unit = .percent }, cx));
    try std.testing.expectError(error.InvalidExpression, evaluate(&.{.add}, cx, &scratch));
    try std.testing.expectError(error.NoSpace, evaluate(&.{.{ .value = .{ .amount = 1 } }}, cx, &.{}));
}
