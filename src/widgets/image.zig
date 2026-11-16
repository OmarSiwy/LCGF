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

/// The image's node: one quad of `pic`'s texture over its rect, at its size or the box's.
pub fn style(th: *const Theme, pic: Image, opt: Options) Style {
    _ = th;
    const size = opt.box orelse pic.size;
    return .{ .size = .{ .px(size[0]), .px(size[1]) }, .texture = pic.texture, .uv = pic.uv, .fill = .white, .role = .image };
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
        pub const boxed: Options = .{ .box = .{ 96, 96 } };
        pub const App = struct {
            pub fn build(app: *App, f: *Frame) void {
                _ = app;
                _ = f.open(.none, column);
                _ = base.label(f, &th, "Photo");
                _ = image(f, &th, photo, .{});
                _ = image(f, &th, photo, boxed);
                f.close();
            }
        };
        pub const State = struct {
            caption: []const u8 = "Photo",
        };
        pub const spec = spec_zig.col(column, .{ base.ct.label(th, .caption), ct.image(th, photo, .{}), ct.image(th, photo, boxed) });
        pub const Ui = base.ComptimeUi(State, spec, th);
        pub const Run = base.Harness(App, Ui, .{ .nodes = 32, .texts = 8, .customs = 1, .strings = 256, .depth = 8 });
    };
}

const Default = Page(.default);
var harness: Default.Run = .{};

/// Tree rows: root 0, column 1, caption 2, the picture 3, the boxed picture 4.
const rows = struct {
    const natural = 3;
    const boxed = 4;
};

test "image: both front ends build one leaf per picture, at its size or the box's" {
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 240 } };
    const out = try h.frame(&in);
    const t = out.runtime.tree;
    try testing.expectEqual(@as(u32, 5), t.len);
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
