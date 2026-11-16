//! Separator (tier 2): a thin rule between groups of widgets, across its parent. Horizontal
//! in a column, vertical in a row. One leaf node, no state. Written against the public API of
//! tiers 0 and 1 (src/widgets/base.zig has the recipe).
//!
//! Runtime: `separator.separator(f, th, .horizontal)`.
//! Comptime: `separator.ct.separator(th, .horizontal)`.

const std = @import("std");
const base = @import("base.zig");
const types = @import("../core/types.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const spec_zig = @import("../comptime/spec.zig");
const Spec = spec_zig.Spec;
const Style = types.Style;
const Node = types.Node;
const Theme = base.Theme;

/// Which way the rule runs: a horizontal rule separates rows of a column, a vertical one the
/// items of a row.
pub const Orientation = enum(u1) { horizontal, vertical };

// ---- spec ---------------------------------------------------------------------------------

/// A rule across the parent, `orientation` picking which way.
pub fn separator(f: *Frame, th: *const Theme, orientation: Orientation) Node {
    return f.leaf(.none, style(th, orientation));
}

/// The rule's node: it fills its parent along its length and is 1 px thick.
pub fn style(th: *const Theme, orientation: Orientation) Style {
    _ = th;
    const sizes = [2][2]types.Size{ .{ .fill, .px(1) }, .{ .px(1), .fill } };
    return .{ .size = sizes[@backingInt(orientation)] };
}

/// The separator as a spec node.
pub const ct = struct {
    /// A rule across its parent. It binds no state and takes no input, so it has no id or
    /// field; `orientation` must be an `Orientation` literal (a compile error otherwise).
    pub fn separator(comptime th: Theme, comptime orientation: Orientation) Spec {
        return .{ .kind = .col, .style = style(&th, orientation) };
    }
};

// ---- tests --------------------------------------------------------------------------------

const testing = std.testing;
const Input = @import("../core/input.zig").Input;

/// Two labels split by a horizontal rule, then a row of two labels split by a vertical one.
fn Page(comptime th: Theme) type {
    const column: Style = .{ .dir = .y, .size = .{ .px(200), .fit }, .pad = @splat(8), .gap = 8 };
    const row: Style = .{ .dir = .x, .size = .{ .fill, .fit }, .gap = 8 };
    return struct {
        pub const App = struct {
            pub fn build(_: *App, f: *Frame) void {
                _ = f.open(.none, column);
                _ = base.label(f, &th, "Above");
                _ = separator(f, &th, .horizontal);
                _ = base.label(f, &th, "Below");
                _ = f.open(.none, row);
                _ = base.label(f, &th, "Left");
                _ = separator(f, &th, .vertical);
                _ = base.label(f, &th, "Right");
                f.close();
                f.close();
            }
        };
        pub const State = struct {
            above: []const u8 = "Above",
            below: []const u8 = "Below",
            left: []const u8 = "Left",
            right: []const u8 = "Right",
        };
        pub const spec = spec_zig.col(column, .{
            base.ct.label(th, .above),
            ct.separator(th, .horizontal),
            base.ct.label(th, .below),
            spec_zig.row(row, .{ base.ct.label(th, .left), ct.separator(th, .vertical), base.ct.label(th, .right) }),
        });
        pub const Ui = base.ComptimeUi(State, spec, th);
        pub const Run = base.Harness(App, Ui, .{ .nodes = 32, .texts = 8, .customs = 1, .strings = 256, .depth = 8 });
    };
}

const Default = Page(.default);
var harness: Default.Run = .{};

test "separator: both front ends build the rule across its parent, 1 px thick" {
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 200 } };
    const out = try h.frame(&in);
    const t = out.runtime.tree;
    // root, column, above, rule, below, row, left, rule, right
    try testing.expectEqual(@as(u32, 9), t.len);
    const col_r = t.rect(1);
    const h_rule = t.rect(3);
    try testing.expectEqual(col_r.x0 + 8, h_rule.x0);
    try testing.expectEqual(col_r.x1 - 8, h_rule.x1);
    try testing.expectEqual(@as(f32, 1), h_rule.h());
    const row_r = t.rect(5);
    const v_rule = t.rect(7);
    try testing.expectEqual(@as(f32, 1), v_rule.w());
    try testing.expectEqual(row_r.y0, v_rule.y0);
    try testing.expectEqual(row_r.y1, v_rule.y1);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
