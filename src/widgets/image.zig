//! Image (tier 2): a picture from a texture, as one quad sampling it. The pixels are the
//! application's: it decodes them (src/assets/png.zig at run time, `embed.embed` at compile
//! time), places them in a texture of its own or in an image atlas (src/assets/image_atlas.zig)
//! and hands the widget where they landed, an `Image`. Written against the public API of tiers
//! 0 and 1, after the recipe in base.zig; icon.zig is its small sibling (tinted coverage, fixed
//! size), this one shows colour pictures at their size or fitted to a box.
//!
//! Runtime: `image.image(f, th, pic, .{})`. Comptime: `image.ct.image(th, pic, .{})`.

const std = @import("std");
const base = @import("base.zig");
const types = @import("../core/types.zig");
const Input = @import("../core/input.zig").Input;
const Frame = @import("../runtime/frame.zig").Frame;
const spec_zig = @import("../comptime/spec.zig");
const image_atlas = @import("../assets/image_atlas.zig");
const embed = @import("../assets/embed.zig");
const Spec = spec_zig.Spec;
const Style = types.Style;
const Node = types.Node;
const Texture = types.Texture;
const Theme = base.Theme;
const a11y = @import("../a11y/tree.zig");

// ---- spec: what the image takes ---------------------------------------------------------------

/// Where a picture is: its texture, the rect it covers there (u0, v0, u1, v1), and its size,
/// logical pixels. Plain data the application fills when it uploads the picture; the widget
/// keeps nothing.
pub const Image = struct {
    texture: Texture = .white,
    uv: [4]f32 = .{ 0, 0, 1, 1 },
    size: [2]f32 = .{ 0, 0 },

    /// A picture packed in `atlas` at `r` (`Atlas.add`), the atlas uploaded as `texture`,
    /// shown at one logical pixel per texel.
    pub fn inAtlas(atlas: *const image_atlas.Atlas, r: image_atlas.Rect, texture: Texture) Image {
        return .{ .texture = texture, .uv = atlas.uv(r), .size = .{ @floatFromInt(r.w), @floatFromInt(r.h) } };
    }

    /// A decoded picture `e` uploaded whole as `texture`.
    pub fn whole(e: embed.Image, texture: Texture) Image {
        return .{ .texture = texture, .size = .{ @floatFromInt(e.w), @floatFromInt(e.h) } };
    }
};

/// How it is shown.
pub const Options = struct {
    /// The box it is shown in, logical pixels; null for its own size.
    box: ?[2]f32 = null,
    /// How it fits the box.
    fit: Fit = .contain,
};

/// How a picture fits a box (CSS `object-fit`).
pub const Fit = enum(u8) {
    /// Exactly the box; the picture is stretched.
    stretch,
    /// As large as fits inside the box, keeping its shape: the node is that size.
    contain,
    /// The whole box, keeping its shape: the middle of the picture, its overflow cut off
    /// (the texture rect shrinks).
    cover,
};

/// Why `pic` cannot be shown, or null: it needs a size above 0 and a texture rect that is
/// not empty, and a box, if any, above 0. The comptime builder stops compilation with it; the
/// runtime front end asserts it.
pub fn checkImage(pic: Image, opt: Options) ?[]const u8 {
    if (!(pic.size[0] > 0 and pic.size[1] > 0)) return "image: the picture needs a size above 0";
    if (!(pic.uv[2] > pic.uv[0] and pic.uv[3] > pic.uv[1])) return "image: the texture rect is empty";
    if (opt.box) |b| if (!(b[0] > 0 and b[1] > 0)) return "image: the box needs a size above 0";
    return null;
}

// ---- look -------------------------------------------------------------------------------------

/// What a picture becomes in a box: the node's size and the texture rect it shows.
pub const Placed = struct { size: [2]f32, uv: [4]f32 };

/// `pic` placed as `opt` says: its own size without a box, else fitted (`Fit`).
pub fn place(pic: Image, opt: Options) Placed {
    const box = opt.box orelse return .{ .size = pic.size, .uv = pic.uv };
    const sx = box[0] / pic.size[0];
    const sy = box[1] / pic.size[1];
    return switch (opt.fit) {
        .stretch => .{ .size = box, .uv = pic.uv },
        .contain => .{ .size = .{ pic.size[0] * @min(sx, sy), pic.size[1] * @min(sx, sy) }, .uv = pic.uv },
        .cover => blk: {
            // The part of the picture the box shows, per axis (1 on the axis that fits).
            const k = @max(sx, sy);
            const shown = [2]f32{ sx / k, sy / k };
            var uv = pic.uv;
            inline for (0..2) |a| {
                const span = pic.uv[a + 2] - pic.uv[a];
                const cut = span * (1 - shown[a]) * 0.5;
                uv[a] += cut;
                uv[a + 2] -= cut;
            }
            break :blk .{ .size = box, .uv = uv };
        },
    };
}

/// The image's node: one quad of `pic`'s texture over its placed rect (`place`), rounded by
/// the theme's radius, tinted from `tints`: white (the picture's own colours), or the control
/// colour while there is no picture yet (the white texture, a placeholder).
pub fn style(th: *const Theme, pic: Image, opt: Options) Style {
    const p = place(pic, opt);
    return .{
        .size = .{ .px(p.size[0]), .px(p.size[1]) },
        .texture = pic.texture,
        .uv = p.uv,
        .radius = th.radius,
        .fill = tints(th)[@intFromBool(pic.texture == .white)],
        .role = .image,
    };
}

/// An image's tint, indexed by "no picture yet": white, then the control colour.
pub fn tints(th: *const Theme) base.OnOff {
    return .{ .white, th.control };
}

// ---- behaviour: none ---------------------------------------------------------------------------

// An image takes no input: its node senses nothing (no `Frame.interact`, no id), so the hit
// test passes through it to what holds it, and focus and Tab never stop on it. A clickable
// picture is a button holding an image.

// ---- accessibility ------------------------------------------------------------------------------

/// Names the image at tree row `row` by the text of row `by` (`aria-labelledby`: its caption,
/// the alt text a page shows) in the caller's semantic columns. An image is an `image` (the
/// style's role) with no text of its own, value 0 and no states; without this it has no name,
/// which is right for one that only decorates a labelled control (WAI-ARIA: `alt=""`).
pub fn name(s: *a11y.Semantics, row: u32, by: u32) void {
    s.c.labelled_by[row] = by;
}

// ---- runtime front end ------------------------------------------------------------------------

/// Shows `pic` as one leaf.
pub fn image(f: *Frame, th: *const Theme, pic: Image, opt: Options) Node {
    std.debug.assert(checkImage(pic, opt) == null);
    return f.leaf(.none, style(th, pic, opt));
}

/// The image as a spec node.
pub const ct = struct {
    /// Shows `pic`. It binds no state and takes no input, so it has no id or field. What
    /// `checkImage` rejects is a compile error.
    pub fn image(comptime th: Theme, comptime pic: Image, comptime opt: Options) Spec {
        if (comptime checkImage(pic, opt)) |msg| @compileError(msg);
        return .{ .kind = .col, .style = style(&th, pic, opt) };
    }
};

// ---- tests --------------------------------------------------------------------------------

const testing = std.testing;

/// The test page: a caption over a picture at its size, and the same picture in a box.
fn Page(comptime th: Theme) type {
    const column: Style = .{ .dir = .y, .pad = @splat(8), .gap = 8 };
    return struct {
        pub const photo: Image = .{ .texture = @fromBackingInt(1), .uv = .{ 0, 0, 0.5, 0.5 }, .size = .{ 64, 48 } };
        pub const boxed: Options = .{ .box = .{ 96, 96 }, .fit = .cover };
        pub const thumb: Options = .{ .box = .{ 24, 24 } };
        pub const App = struct {
            zooms: u32 = 0,
            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.none, column);
                _ = base.label(f, &th, "Photo");
                _ = image(f, &th, photo, .{});
                _ = image(f, &th, photo, boxed);
                const b = f.open(.from("zoom"), base.buttonStyle(&th));
                const r = f.interact(b, .button);
                f.setFill(b, base.buttonFill(&th, r));
                _ = image(f, &th, photo, thumb);
                f.close();
                app.zooms += @intFromBool(r.clicked);
                f.close();
            }
        };
        pub const State = struct {
            caption: []const u8 = "Photo",
        };
        pub const spec = spec_zig.col(column, .{
            base.ct.label(th, .caption), ct.image(th, photo, .{}), ct.image(th, photo, boxed),
            blk: {
                var b = spec_zig.row(base.buttonStyle(&th), .{ct.image(th, photo, thumb)});
                b.id = "zoom";
                break :blk b;
            },
        });
        pub const Ui = base.ComptimeUi(State, spec, th);
        pub const Run = base.Harness(App, Ui, .{ .nodes = 32, .texts = 8, .customs = 1, .strings = 256, .depth = 8 });
    };
}

const Default = Page(.default);
var harness: Default.Run = .{};

/// Tree rows: root 0, column 1, caption 2, the picture 3, the boxed picture 4, the button 5
/// holding the thumbnail 6.
const rows = struct {
    const natural = 3;
    const boxed = 4;
    const button = 5;
    const thumb = 6;
};

test "image: both front ends build one leaf per picture, at its size or the box's" {
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 240 } };
    const out = try h.frame(&in);
    const t = out.runtime.tree;
    try testing.expectEqual(@as(u32, 7), t.len);
    try testing.expectEqual(@as(f32, 64), t.rect(rows.natural).w());
    try testing.expectEqual(@as(f32, 48), t.rect(rows.natural).h());
    try testing.expectEqual(@as(f32, 96), t.rect(rows.boxed).w());
}

test "Image.inAtlas, Image.whole: the texture rect and size from src/assets" {
    var px: [64 * 64 * 4]u8 = undefined;
    var sx: [8]u32 = undefined;
    var sy: [8]u32 = undefined;
    var sw: [8]u32 = undefined;
    var a: image_atlas.Atlas = .init(64, 64, &px, .{ .x = &sx, .y = &sy, .w = &sw }, 32);
    const src: [16 * 8 * 4]u8 = @splat(255);
    const r = a.add(16, 8, &src).?;
    const pic: Image = .inAtlas(&a, r, @fromBackingInt(2));
    try testing.expectEqual([2]f32{ 16, 8 }, pic.size);
    try testing.expectEqual(a.uv(r), pic.uv);
    const icon = comptime embed.embed(@embedFile("../assets/testdata/icon16.png"));
    const w: Image = .whole(icon, @fromBackingInt(5));
    try testing.expectEqual([2]f32{ 16, 16 }, w.size);
    try testing.expectEqual([4]f32{ 0, 0, 1, 1 }, w.uv);
}

test "place: own size, stretch, contain and cover" {
    const pic: Image = .{ .uv = .{ 0, 0, 0.5, 1 }, .size = .{ 40, 20 } };
    try testing.expectEqual(Placed{ .size = .{ 40, 20 }, .uv = pic.uv }, place(pic, .{}));
    try testing.expectEqual(Placed{ .size = .{ 30, 30 }, .uv = pic.uv }, place(pic, .{ .box = .{ 30, 30 }, .fit = .stretch }));
    try testing.expectEqual(Placed{ .size = .{ 30, 15 }, .uv = pic.uv }, place(pic, .{ .box = .{ 30, 30 } }));
    // Cover: scaled to 60 x 30, half its width shown, the middle half of its texture rect.
    try testing.expectEqual(Placed{ .size = .{ 30, 30 }, .uv = .{ 0.125, 0, 0.375, 1 } }, place(pic, .{ .box = .{ 30, 30 }, .fit = .cover }));
}

test "style: the texture, a white tint, the theme's radius; a placeholder in the control colour" {
    const th: Theme = .default;
    const s = style(&th, Default.photo, .{});
    try testing.expectEqual(Default.photo.texture, s.texture);
    try testing.expectEqual(types.Color.white, s.fill);
    try testing.expectEqual(th.radius, s.radius);
    try testing.expectEqual(th.control, style(&th, .{ .size = .{ 8, 8 } }, .{}).fill);
}

const light: Theme = .{ .control = .rgb(200, 200, 205), .radius = 0 };

test "image: another theme restyles both front ends alike" {
    const S = struct {
        var h: Page(light).Run = .{};
    };
    S.h.init();
    const in: Input = .{ .viewport = .{ 320, 240 } };
    const out = try S.h.frame(&in);
    try testing.expectEqual(@as(f32, 0), out.comptime_.tree.c.look[rows.natural].radius);
    try testing.expectEqual(types.Color.white.bitsOf(), out.runtime.tree.c.look[rows.boxed].fill);
}

test "image: takes no input; a press on it goes to what holds it; tab order skips it" {
    const check = @import("check.zig");
    const h = &harness;
    h.init();
    var in: Input = .{ .viewport = .{ 320, 240 } };
    var out = try h.frame(&in);
    for ([2]u32{ rows.natural, rows.boxed }) |row| {
        const r = out.runtime.tree.rect(row);
        in.pointer = .{ (r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5 };
        in.buttons.left = true;
        _ = try h.frame(&in);
        try testing.expectEqual(@as(u32, 0), h.ctx.inter.active);
        try testing.expectEqual(@as(?Default.Ui.Events.Widget, null), h.ui.pointer.pressed);
        in.buttons.left = false;
        out = try h.frame(&in);
        try testing.expectEqual(@as(u32, 0), h.ctx.inter.focus);
        try testing.expectEqual(@as(u32, 0), h.ctx.inter.hot);
        try testing.expect(out.comptime_.event == null);
    }
    // Press and release on the thumbnail inside the button: the button is clicked, in both.
    const tr = out.runtime.tree.rect(rows.thumb);
    in.pointer = .{ (tr.x0 + tr.x1) * 0.5, (tr.y0 + tr.y1) * 0.5 };
    in.buttons.left = true;
    _ = try h.frame(&in);
    in.buttons.left = false;
    out = try h.frame(&in);
    try testing.expectEqual(@as(u32, 1), h.app.zooms);
    try testing.expect(out.comptime_.event != null and out.comptime_.event.? == .zoom);
    try check.expectInert(out.runtime.tree, &.{ rows.natural, rows.boxed, rows.thumb });
    try check.expectInert(out.comptime_.tree, &.{ rows.natural, rows.boxed, rows.thumb });
}

test "image: role image, named by its caption, value 0, no states, in both front ends" {
    const check = @import("check.zig");
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 240 } };
    const out = try h.frame(&in);
    var sb: check.SemBuf = undefined;
    const trees = [2]*const @import("../core/tree.zig").Tree{ out.runtime.tree, out.comptime_.tree };
    const texts = [2]*const @import("../core/texts.zig").Texts{ out.runtime.texts, &h.ui.tables.tx };
    const strings = [2][]const u8{ h.ctx.strings[h.ctx.cur].buf, h.ui.tables.strings.buf };
    const caption = rows.natural - 1;
    for (trees, texts, strings) |t, tx, str| {
        var sem = sb.init();
        name(&sem, rows.natural, caption);
        name(&sem, rows.boxed, caption);
        a11y.names(t, &sem);
        a11y.states(t, &sem);
        for ([3]u32{ rows.natural, rows.boxed, rows.thumb }) |r| {
            try testing.expectEqual(a11y.Role.image, @as(a11y.Role, @fromBackingInt(t.c.role[r])));
            try testing.expectEqual(@as(f32, 0), t.c.value[r]);
            try testing.expectEqual(@as(u8, 0), sem.c.state[r]);
        }
        try testing.expectEqualStrings("Photo", check.nameOf(&sem, tx, str, rows.natural));
        try testing.expectEqualStrings("Photo", check.nameOf(&sem, tx, str, rows.boxed));
        // The thumbnail only decorates its button: no name.
        try testing.expectEqual(types.none, sem.c.name[rows.thumb]);
    }
}

test "checkImage: a size, a texture rect and a box" {
    try testing.expectEqual(null, checkImage(Default.photo, .{}));
    try testing.expectEqualStrings("image: the picture needs a size above 0", checkImage(.{}, .{}).?);
    try testing.expectEqualStrings("image: the texture rect is empty", checkImage(.{ .size = .{ 1, 1 }, .uv = .{ 0.5, 0, 0.5, 1 } }, .{}).?);
    try testing.expectEqualStrings("image: the box needs a size above 0", checkImage(Default.photo, .{ .box = .{ 0, 10 } }).?);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
