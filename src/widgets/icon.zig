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
const a11y = @import("../a11y/tree.zig");

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

/// The icon's node: exactly its size, one quad sampling `ic.texture` over `ic.uv`, tinted
/// with the theme's text colour, as a glyph is: a coverage icon takes the colour of the text
/// beside it.
pub fn style(th: *const Theme, ic: Icon) Style {
    return .{ .size = .{ .px(ic.size[0]), .px(ic.size[1]) }, .texture = ic.texture, .uv = ic.uv, .fill = th.text, .role = .image };
}

// ---- accessibility ------------------------------------------------------------------------

/// Names the icon at tree row `row` by the text of row `by` (`aria-labelledby`) in the
/// caller's semantic columns. An icon is an `image` (the style's role) with no text of its
/// own, so without this it has no name; value 0, no states. An icon that only decorates a
/// labelled control needs no name.
pub fn name(s: *a11y.Semantics, row: u32, by: u32) void {
    s.c.labelled_by[row] = by;
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

/// The example page: a 16 px icon before a label, and a 24 px icon inside a button, in both
/// front ends, in theme `th`. The icons use the white texture (a solid square), the stand-in
/// before an application atlas: the golden image renderer has no icon atlas.
pub fn Page(comptime th: Theme) type {
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

/// Input for `Page(.default)` at 320 x 200, one commented line per frame.
pub const replay = @embedFile("testdata/icon.replay");

/// The frames of `replay` kept as golden images (tools/widgetgolden/ref/icon-<name>.png).
pub const golden_frames = .{
    .{ "rest", 0 },
    .{ "hover", 3 },
};

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

test "icon: one quad of the icon's texture rect, tinted with the text colour; any theme alike" {
    const th = Theme.default;
    const atlas: types.Texture = @fromBackingInt(3);
    const s = style(&th, .{ .texture = atlas, .uv = .{ 0.25, 0, 0.5, 0.25 }, .size = .{ 20, 10 } });
    try testing.expectEqual(atlas, s.texture);
    try testing.expectEqual([4]f32{ 0.25, 0, 0.5, 0.25 }, s.uv);
    try testing.expectEqual(th.text, s.fill);
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 200 } };
    const out = try h.frame(&in);
    const t = out.runtime.tree;
    try testing.expectEqual(th.text.bitsOf(), t.c.look[rows.small].fill);
    try testing.expectEqual(th.text.bitsOf(), out.comptime_.tree.c.look[rows.large].fill);

    const Light = Page(.{ .text = .rgb(20, 20, 20), .control = .rgb(200, 200, 205) });
    const S = struct {
        var light: Light.Run = .{};
    };
    S.light.init();
    const lo = try S.light.frame(&in);
    try testing.expectEqual(types.Color.rgb(20, 20, 20).bitsOf(), lo.runtime.tree.c.look[rows.small].fill);
}

test "icon: takes no input; a press on it goes to what holds it; tab order skips it" {
    const check = @import("check.zig");
    const h = &harness;
    h.init();
    var in: Input = .{ .viewport = .{ 320, 200 } };
    var out = try h.frame(&in);
    // Press and release on the standalone icon: nothing held, nothing focused.
    var r = out.runtime.tree.rect(rows.small);
    in.pointer = .{ (r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5 };
    in.buttons.left = true;
    _ = try h.frame(&in);
    try testing.expectEqual(@as(u32, 0), h.ctx.inter.active);
    try testing.expectEqual(@as(?Default.Ui.Events.Widget, null), h.ui.pointer.pressed);
    in.buttons.left = false;
    out = try h.frame(&in);
    try testing.expectEqual(@as(u32, 0), h.ctx.inter.focus);
    // Press and release on the icon inside the button: the button is clicked, in both.
    r = out.runtime.tree.rect(rows.large);
    in.pointer = .{ (r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5 };
    in.buttons.left = true;
    _ = try h.frame(&in);
    in.buttons.left = false;
    out = try h.frame(&in);
    try testing.expectEqual(@as(u32, 1), h.app.saves);
    try testing.expect(out.comptime_.event != null and out.comptime_.event.? == .save);
    try check.expectInert(out.runtime.tree, &.{ rows.small, rows.large });
}

test "icon: role image, named by the text it is given, value 0, no states, in both front ends" {
    const check = @import("check.zig");
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 200 } };
    const out = try h.frame(&in);
    var sb: check.SemBuf = undefined;
    const trees = [2]*const @import("../core/tree.zig").Tree{ out.runtime.tree, out.comptime_.tree };
    const texts = [2]*const @import("../core/texts.zig").Texts{ out.runtime.texts, &h.ui.tables.tx };
    const strings = [2][]const u8{ h.ctx.strings[h.ctx.cur].buf, h.ui.tables.strings.buf };
    for (trees, texts, strings) |t, tx, str| {
        var sem = sb.init();
        name(&sem, rows.small, rows.small + 1);
        a11y.names(t, &sem);
        a11y.states(t, &sem);
        for ([2]u32{ rows.small, rows.large }) |r| {
            try testing.expectEqual(a11y.Role.image, @as(a11y.Role, @fromBackingInt(t.c.role[r])));
            try testing.expectEqual(@as(f32, 0), t.c.value[r]);
            try testing.expectEqual(@as(u8, 0), sem.c.state[r]);
        }
        try testing.expectEqualStrings("Documents", check.nameOf(&sem, tx, str, rows.small));
        try testing.expectEqual(types.none, sem.c.name[rows.large]);
    }
}

test "icon: the example replay gives the same frames in both front ends" {
    const Replay = @import("../core/input.zig").Replay;
    const h = &harness;
    h.init();
    var text: [16]u8 = undefined;
    var evs: [8]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &evs, .contacts = &contacts };
    var rp: Replay = .{ .src = replay };
    var clicks: [6]bool = undefined;
    var fills: [6]u32 = undefined;
    while (try rp.next(buf)) |in| {
        const k = h.frames;
        const out = try h.frame(in);
        clicks[k] = if (out.comptime_.event) |e| e == .save else false;
        fills[k] = out.runtime.tree.c.look[rows.button].fill;
        // The icons keep their look whatever the pointer does.
        try testing.expectEqual(Theme.default.text.bitsOf(), out.runtime.tree.c.look[rows.large].fill);
    }
    try testing.expectEqual(@as(u32, 6), h.frames);
    try testing.expectEqualSlices(bool, &.{ false, false, false, false, false, true }, &clicks);
    try testing.expectEqual(@as(u32, 1), h.app.saves);
    const c = Theme.default.controlFills();
    try testing.expectEqualSlices(u32, &.{ c[0].bitsOf(), c[0].bitsOf(), c[0].bitsOf(), c[1].bitsOf(), c[3].bitsOf(), c[1].bitsOf() }, &fills);
}

test "golden_frames: name frames the icon replay has" {
    inline for (golden_frames) |g| try testing.expect(g[1] < 6);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
