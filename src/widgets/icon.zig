//! Icon (tier 2): a small picture from a texture, sized in logical pixels, as DVUI draws its
//! TinyVG icons. The picture is the application's: it rasterises the icon once (TinyVG
//! through src/draw/tinyvg.zig and src/draw/paths.zig, placed in a coverage atlas) and hands
//! the widget where it landed, an `Icon`. The widget draws one quad sampling it. Written
//! against the public API of tiers 0 and 1 (src/widgets/base.zig has the recipe).
//!
//! Runtime: `icon.icon(f, th, save_icon)`. Comptime: `icon.ct.icon(th, save_icon)`.

const std = @import("std");
const base = @import("base.zig");
const types = @import("../core/types.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const spec_zig = @import("../comptime/spec.zig");
const Spec = spec_zig.Spec;
const Style = types.Style;
const Node = types.Node;
const Theme = base.Theme;

/// Where a rasterised icon is: its texture, the rect it covers there (u0, v0, u1, v1), and
/// the size it is drawn at, logical pixels. Plain data; the application fills it when it
/// places the icon in its atlas (`paths.place`). `.white` with the full rect draws a solid
/// square, the stand-in before an atlas exists.
pub const Icon = struct {
    texture: types.Texture = .white,
    uv: [4]f32 = .{ 0, 0, 1, 1 },
    size: [2]f32 = .{ 16, 16 },
};

// ---- spec ---------------------------------------------------------------------------------

/// Draws `ic` as one leaf of its size.
pub fn icon(f: *Frame, th: *const Theme, ic: Icon) Node {
    return f.leaf(.none, style(th, ic));
}

/// The icon's node: exactly its size.
pub fn style(th: *const Theme, ic: Icon) Style {
    _ = th;
    return .{ .size = .{ .px(ic.size[0]), .px(ic.size[1]) } };
}

/// The icon as a spec node.
pub const ct = struct {
    /// Draws `ic`. It binds no state and takes no input, so it has no id or field. An icon
    /// of no size, or a texture rect that is empty, is a compile error.
    pub fn icon(comptime th: Theme, comptime ic: Icon) Spec {
        if (!(ic.size[0] > 0 and ic.size[1] > 0)) @compileError("an icon needs a size above 0");
        if (!(ic.uv[2] > ic.uv[0] and ic.uv[3] > ic.uv[1])) @compileError("an icon's texture rect is empty");
        return .{ .kind = .col, .style = style(&th, ic) };
    }
};

// ---- tests --------------------------------------------------------------------------------

const testing = std.testing;
const Input = @import("../core/input.zig").Input;

/// A 16 px icon before a label, and a 24 px icon inside a button.
fn Page(comptime th: Theme) type {
    const column: Style = .{ .dir = .y, .pad = @splat(8), .gap = 8 };
    const line: Style = .{ .dir = .x, .gap = th.gap, .cross = .center };
    return struct {
        pub const small: Icon = .{ .size = .{ 16, 16 } };
        pub const large: Icon = .{ .size = .{ 24, 24 } };
        pub const App = struct {
            saves: u32 = 0,
            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.none, column);
                _ = f.open(.none, line);
                _ = icon(f, &th, small);
                _ = base.label(f, &th, "Documents");
                f.close();
                const b = f.open(.from("save"), base.buttonStyle(&th));
                const r = f.interact(b, .button);
                f.setFill(b, base.buttonFill(&th, r));
                _ = icon(f, &th, large);
                f.close();
                app.saves += @intFromBool(r.clicked);
                f.close();
            }
        };
        pub const State = struct {
            docs: []const u8 = "Documents",
        };
        pub const spec = spec_zig.col(column, .{
            spec_zig.row(line, .{ ct.icon(th, small), base.ct.label(th, .docs) }),
            blk: {
                var b = spec_zig.row(base.buttonStyle(&th), .{ct.icon(th, large)});
                b.id = "save";
                break :blk b;
            },
        });
        pub const Ui = base.ComptimeUi(State, spec, th);
        pub const Run = base.Harness(App, Ui, .{ .nodes = 32, .texts = 8, .customs = 1, .strings = 256, .depth = 8 });
    };
}

const Default = Page(.default);
var harness: Default.Run = .{};

/// Tree rows: root 0, column 1, line 2, small icon 3, label 4, button 5, large icon 6.
const rows = struct {
    const small = 3;
    const button = 5;
    const large = 6;
};

test "icon: both front ends build one leaf of the icon's size" {
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 200 } };
    const out = try h.frame(&in);
    const t = out.runtime.tree;
    try testing.expectEqual(@as(u32, 7), t.len);
    try testing.expectEqual(@as(f32, 16), t.rect(rows.small).w());
    try testing.expectEqual(@as(f32, 16), t.rect(rows.small).h());
    try testing.expectEqual(@as(f32, 24), t.rect(rows.large).w());
    // The button fits its icon and its padding.
    try testing.expectEqual(24 + 2 * Theme.default.pad, t.rect(rows.button).w());
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
