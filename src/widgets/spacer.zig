//! Spacer (tier 2): empty space that pushes its siblings apart, as a flexible gap in a row or
//! column: `[Open] [Save] <spacer> [Close]` puts Close at the far end. One leaf node, no state,
//! nothing painted. Written against the public API of tiers 0 and 1 (src/widgets/base.zig has
//! the recipe).
//!
//! Runtime: `spacer.spacer(f, .x)`. Comptime: `spacer.ct.spacer(.x)`.

const std = @import("std");
const base = @import("base.zig");
const types = @import("../core/types.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const spec_zig = @import("../comptime/spec.zig");
const Spec = spec_zig.Spec;
const Style = types.Style;
const Node = types.Node;
const Axis = types.Axis;
const Theme = base.Theme;

// ---- spec ---------------------------------------------------------------------------------

/// Space along `axis`, the axis of the row (`.x`) or column (`.y`) it sits in.
pub fn spacer(f: *Frame, axis: Axis) Node {
    return f.leaf(.none, style(axis));
}

/// The spacer's node: it fills what is left along `axis` (`Size.fill`), so siblings after it
/// go to the far end, and is 0 across, so it never widens its parent. Unpainted in every
/// theme; the axis picks the size by table index.
pub fn style(axis: Axis) Style {
    const sizes = [2][2]types.Size{ .{ .fill, .px(0) }, .{ .px(0), .fill } };
    return .{ .size = sizes[@backingInt(axis)] };
}

/// The spacer as a spec node.
pub const ct = struct {
    /// Space along `axis`. It binds no state and takes no input, so it has no id or field;
    /// `axis` must be an `Axis` literal (a compile error otherwise).
    pub fn spacer(comptime axis: Axis) Spec {
        return .{ .kind = .col, .style = style(axis) };
    }
};

// ---- tests --------------------------------------------------------------------------------

const testing = std.testing;
const Input = @import("../core/input.zig").Input;

/// A toolbar row of two buttons, a spacer and a third button, and a column with a label, a
/// spacer and a label at its foot.
fn Page(comptime th: Theme) type {
    const bar: Style = .{ .dir = .x, .size = .{ .fill, .fit }, .pad = @splat(8), .gap = 8, .fill = th.panel };
    const side: Style = .{ .dir = .y, .size = .{ .px(120), .fill }, .pad = @splat(8) };
    const page: Style = .{ .dir = .y, .size = .{ .fill, .fill } };
    return struct {
        pub const App = struct {
            closes: u32 = 0,
            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.none, page);
                _ = f.open(.none, bar);
                _ = base.button(f, &th, .from("open"), "Open");
                _ = base.button(f, &th, .from("save"), "Save");
                _ = spacer(f, .x);
                app.closes += @intFromBool(base.button(f, &th, .from("close"), "Close").clicked);
                f.close();
                _ = f.open(.none, side);
                _ = base.label(f, &th, "Top");
                _ = spacer(f, .y);
                _ = base.label(f, &th, "Foot");
                f.close();
                f.close();
            }
        };
        pub const State = struct {
            open_text: []const u8 = "Open",
            save_text: []const u8 = "Save",
            close_text: []const u8 = "Close",
            top: []const u8 = "Top",
            foot: []const u8 = "Foot",
        };
        pub const spec = spec_zig.col(page, .{
            spec_zig.row(bar, .{ base.ct.button(th, .open, .open_text), base.ct.button(th, .save, .save_text), ct.spacer(.x), base.ct.button(th, .close, .close_text) }),
            spec_zig.col(side, .{ base.ct.label(th, .top), ct.spacer(.y), base.ct.label(th, .foot) }),
        });
        pub const Ui = base.ComptimeUi(State, spec, th);
        pub const Run = base.Harness(App, Ui, .{ .nodes = 32, .texts = 8, .customs = 1, .strings = 256, .depth = 8 });
    };
}

const Default = Page(.default);
var harness: Default.Run = .{};

test "spacer: both front ends build one empty leaf where it is placed" {
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 200 } };
    const out = try h.frame(&in);
    const t = out.runtime.tree;
    // root, page, bar, open+label, save+label, spacer, close+label, side, top, spacer, foot
    try testing.expectEqual(@as(u32, 14), t.len);
    try testing.expectEqual(t.c.end[7], 8);
    try testing.expectEqual(t.c.end[12], 13);
}

test "spacer: takes the space left, pushing later siblings to the far end; paints nothing" {
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 200 } };
    const out = try h.frame(&in);
    const t = out.runtime.tree;
    const bar = t.rect(2);
    const close = t.rect(t.find(.from("close")));
    const gap = t.rect(7);
    try testing.expectEqual(bar.x1 - 8, close.x1);
    try testing.expectEqual(t.rect(t.find(.from("save"))).x1 + 8, gap.x0);
    try testing.expectEqual(close.x0 - 8, gap.x1);
    try testing.expectEqual(@as(f32, 0), gap.h());
    const side = t.rect(10);
    try testing.expectEqual(side.y1 - 8, t.rect(13).y1);
    try testing.expectEqual(@as(f32, 0), t.rect(12).w());
    // Drawn: the bar and three buttons; neither spacer has a quad.
    try testing.expectEqual(@as(u32, 4), out.runtime.draw.quad_len);
    try testing.expectEqual(types.Color.transparent.bitsOf(), t.c.look[7].fill);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
