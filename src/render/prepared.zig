//! Portable surface preparation and ordinary frame integration. No resource registry,
//! callbacks, GPU objects or allocation: the host supplies pixels, uploads the returned
//! straight-alpha image, and binds its existing Texture handle. Each helper expands into
//! public decoration, software-renderer and compositor operations.

const std = @import("std");
const types = @import("../core/types.zig");
const mem = @import("../core/mem.zig");
const simd = @import("../core/simd.zig");
const tree = @import("../core/tree.zig");
const Texts = @import("../core/texts.zig").Texts;
const draw = @import("../draw/draw_list.zig");
const geometry = @import("../draw/geometry.zig");
const decoration = @import("../draw/decoration.zig");
const surface = @import("../draw/surface.zig");
const compositor = @import("../draw/compositor.zig");
const features = @import("../draw/features.zig");
const software = @import("sw/sw.zig");
const iface = @import("iface.zig");

pub const Error = decoration.Error || compositor.Error || error{
    BudgetExceeded,
    InvalidRange,
    MissingTexture,
    MissingGlyphs,
    MissingCustomImage,
    UnsupportedMaterial,
    UnsupportedFeature,
    MissingNodeMap,
    InvalidNodeMap,
    NoSpace,
    PaintRowRequired,
    GeometryChanged,
};

pub const Limits = struct {
    width: u32 = 8192,
    height: u32 = 8192,
    bytes: usize = 64 * 1024 * 1024,
    clips: u32 = 64,
    layers: u32 = 256,
    blur_sigma: f32 = 128,

    pub fn pixels(limits: Limits, width: u32, height: u32) Error!usize {
        if (width > limits.width or height > limits.height) return error.BudgetExceeded;
        const count = try surface.requiredPixels(width, height);
        const bytes = std.math.mul(usize, count, @sizeOf(u32)) catch return error.BudgetExceeded;
        if (bytes > limits.bytes) return error.BudgetExceeded;
        return count;
    }
};

pub const Painted = struct {
    /// Straight RGBA8, ready for every stock backend's existing texture upload operation.
    image: surface.Image,
    /// Border box before effects and conservative rectangle represented by the texture.
    source: types.Rect,
    rect: types.Rect,
    scale: f32,
};

/// Query before allocating/carving. Includes outside borders, outlines and shadow extents.
pub fn measure(shape: decoration.RoundedRect, description: decoration.Description, scale: f32, limits: Limits) Error!decoration.Dimensions {
    if (description.backgrounds.len + description.shadows.len > limits.layers) return error.BudgetExceeded;
    for (description.shadows) |shadow| if (shadow.sigma > limits.blur_sigma) return error.BudgetExceeded;
    const dims = try decoration.dimensions(try decoration.bounds(shape, description), scale);
    _ = try limits.pixels(dims.width, dims.height);
    return dims;
}

/// Bake the declared decoration model (including analytic box shadows) into supplied pixels.
/// True alpha-convolution shadows use compositor.dropShadow over a rendered surface instead.
/// `storage` is premultiplied scratch; `rgba` is the separate straight-alpha upload buffer.
pub fn bake(shape: decoration.RoundedRect, description: decoration.Description, scale: f32, clips: []const decoration.Clip, quality: decoration.Quality, limits: Limits, storage: []u32, rgba: []u32) Error!Painted {
    const dims = try measure(shape, description, scale, limits);
    if (clips.len > limits.clips) return error.BudgetExceeded;
    const count = try limits.pixels(dims.width, dims.height);
    const output_count = std.math.mul(usize, dims.width, dims.height) catch return error.BudgetExceeded;
    if (storage.len < count or rgba.len < output_count) return error.NoSpace;
    if (surface.overlaps(storage[0..count], rgba[0..output_count])) return error.AliasedStorage;
    try decoration.validateClips(clips);
    const target = try surface.init(storage, dims.width, dims.height);
    try decoration.rasterize(target, shape, description, .{ .origin = dims.origin, .scale = scale, .quality = quality, .clips = clips });
    try surface.exportRGBA(target, rgba, dims.width, .straight);
    return .{ .image = .{ .pixels = rgba[0..output_count], .width = dims.width, .height = dims.height, .stride = dims.width, .alpha = .straight }, .source = shape.rect, .rect = dims.rect, .scale = scale };
}

/// Reserve the one sparse paint-extra row while building the node, before its descendants.
/// Pass the returned row to Tree.pushRow or Frame.openRow. Layout border/padding remain real
/// layout inputs while the prepared texture owns the final appearance.
pub fn row(style: *const types.Style) tree.Template {
    var result = tree.Template.from(style);
    result.own = 1;
    result.prepared_texture = 1;
    return result;
}

/// Bind after layout and before Frame.finish/paint.emit. Reusing a texture handle with new
/// pixels increments revision, so Damage.frame sees the resource edit. No GPU call occurs.
pub fn bind(t: *tree.Tree, node: types.Node, painted: Painted, texture: types.Texture, revision: u32) Error!void {
    const n = node.ix();
    if (n >= t.len) return error.InvalidRange;
    const extra = t.c.extra[n];
    if (extra == 0) return error.PaintRowRequired;
    const actual = t.rect(n);
    if (!std.mem.eql(f32, &actual.array(), &painted.source.array())) return error.GeometryChanged;
    const bounds = painted.rect;
    const x = &t.x.row[extra];
    x.paint_outset = .{ actual.x0 - bounds.x0, actual.y0 - bounds.y0, bounds.x1 - actual.x1, bounds.y1 - actual.y1 };
    x.prepared_texture = 1;
    x.paint_revision = revision;
    x.uv = .{ 0, 0, 1, 1 };
    t.c.look[n].fill = types.Color.white.bitsOf();
    t.c.look[n].border_color = 0;
    t.c.look[n].params = @splat(0);
    t.c.look[n].texture = @backingInt(texture);
    t.c.look[n].material = @backingInt(types.Material.solid);
}

/// Optional node indices for the portable clipping/subtree path. Existing native rendering
/// needs no map and pays no per-node storage for one. Make the map before damage.cull.
pub const NodeMap = struct {
    quads: []u32,
    runs: []const u32,
    len: u32 = 0,

    pub fn init(carver: *mem.Carver, nodes: u32, text: *const Texts) NodeMap {
        return .{ .quads = carver.slice(u32, nodes), .runs = text.c.node[0..text.len] };
    }
};

/// Same row/layer ordering used for paint.emit/emitLayered. `order` empty means node order.
/// The returned map borrows Texts.node. It is invalidated by a subsequent tree/paint rebuild.
pub fn mapNodes(t: *const tree.Tree, text: *const Texts, list: *const draw.DrawList, order: []const u32, quads: []u32) Error!NodeMap {
    if (quads.len < list.quad_len) return error.NoSpace;
    if (order.len != 0 and order.len < t.len) return error.InvalidRange;
    var n: u32 = 0;
    for (0..t.len) |k| {
        const i = if (order.len == 0) k else order[k];
        if (i >= t.len) return error.InvalidRange;
        const look = t.c.look[i];
        if (((look.fill | look.border_color) >> 24) == 0 or geometry.nodeAlpha(t, i) <= 0 or !geometry.hasArea(geometry.nodeBounds(t, i))) continue;
        if (n >= list.quad_len) return error.InvalidNodeMap;
        quads[n] = @intCast(i);
        n += 1;
    }
    if (n != list.quad_len or text.len != list.run_len) return error.InvalidNodeMap;
    return .{ .quads = quads, .runs = text.c.node[0..text.len], .len = n };
}

/// Caller-owned exact clips from the actual ancestor geometry, before raster antialiasing.
/// A transformed rounded clip remains that transformed shape, not a radius on an AABB.
pub fn treeClips(t: *const tree.Tree, node: u32, storage: []decoration.Clip) Error![]const decoration.Clip {
    if (node >= t.len) return error.InvalidRange;
    const c = &t.c;
    var i = c.parent[geometry.paintSource(t, node)];
    var count: u32 = 0;
    while (true) {
        if (c.clips[i] != 0) {
            if (count == storage.len) return error.NoSpace;
            const extra = t.x.row[c.extra[i]];
            const inv = geometry.inverse(t.x.row[c.scope[i]].world) orelse return error.InvalidTransform;
            const r = t.rect(i);
            const x0 = r.x0 + extra.border;
            const y0 = r.y0 + extra.border;
            const x1 = @max(x0, r.x1 - extra.border);
            const y1 = @max(y0, r.y1 - extra.border);
            var radii: [4][2]f32 = undefined;
            inline for (0..4) |corner| radii[corner] = @splat(@max(0, extra.radii[corner] - extra.border));
            const shape = try decoration.normalize(.{ .rect = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 }, .radii = radii });
            storage[count] = .{ .rounded = .{ .shape = shape, .inverse = inv } };
            count += 1;
        }
        if (i == 0) break;
        i = c.parent[i];
    }
    return storage[0..count];
}

pub const Resources = struct {
    /// Straight, tightly packed RGBA8; row 0 conventionally contains software.Image.white.
    images: []const software.Image = &.{software.Image.white},
    glyphs: iface.Glyphs = .{},
    /// Images of custom draw contents in CustomDraw.rect, indexed by custom row. Supplying
    /// them makes custom content participate in group opacity/masks/filters like other kinds.
    customs: []const software.Image = &.{},
};

pub const TreeInput = struct { value: *const tree.Tree, nodes: NodeMap, scratch: []decoration.Clip };
pub const View = struct {
    origin: [2]f32 = .{ 0, 0 },
    scale: f32 = 1,
    quality: decoration.Quality = .four,
    clips: []const decoration.Clip = &.{},
    tree: ?TreeInput = null,
    /// Select a subtree without splitting native quad batches. Requires the node map.
    nodes: ?[2]u32 = null,
};

fn validImage(image: software.Image, dst: surface.Surface, scratch: surface.Surface) Error!void {
    if (surface.overlaps(image.pixels, dst.pixels) or surface.overlaps(image.pixels, scratch.pixels)) return error.AliasedStorage;
    if (image.width == 0 or image.height == 0) return error.InvalidSize;
    const needed = std.math.mul(usize, image.width, image.height) catch return error.InvalidSize;
    if (image.pixels.len < needed) return error.InsufficientStorage;
}

fn stock(q: *const draw.Quad) Error!features.Kind {
    return std.enums.fromInt(features.Kind, @as(u32, @bitCast(q.params[0]))) orelse error.UnsupportedFeature;
}

fn included(node: u32, range: ?[2]u32) bool {
    return if (range) |r| node >= r[0] and node < r[1] else true;
}

/// Paint ordinary draw commands into a caller surface. Every participating kind is supplied
/// before the pass; unsupported materials/missing images return errors before pixels change.
/// `scratch` has the same dimensions and different storage. It is reused for each primitive,
/// then exact clip coverage is applied before compositing. For isolated groups, draw a subtree
/// here, run the public filters/masks, and composite that completed surface once.
pub fn drawRange(dst: surface.Surface, scratch: surface.Surface, list: *const draw.DrawList, first: u32, count: u32, resources: Resources, view: View, limits: Limits) Error!void {
    try dst.validate();
    try scratch.validate();
    _ = try limits.pixels(dst.width, dst.height);
    if (dst.width != scratch.width or dst.height != scratch.height) return error.SizeMismatch;
    if (surface.overlaps(dst.pixels, scratch.pixels)) return error.AliasedStorage;
    if (first > list.cmd_len or count > list.cmd_len - first) return error.InvalidRange;
    if (!std.math.isFinite(view.scale) or view.scale <= 0 or !std.math.isFinite(view.origin[0]) or !std.math.isFinite(view.origin[1])) return error.InvalidScale;
    if (view.clips.len > limits.clips) return error.BudgetExceeded;
    try decoration.validateClips(view.clips);
    if (view.nodes != null and view.tree == null) return error.MissingNodeMap;
    if (view.tree) |input| {
        if (input.nodes.len < list.quad_len or input.nodes.runs.len < list.run_len) return error.InvalidNodeMap;
    }
    // Validate each referenced resource and clip depth before the first write.
    for (first..first + count) |command| switch (list.command(@intCast(command))) {
        .quads => |batch| {
            if (batch.material != .solid) return error.UnsupportedMaterial;
            if (@backingInt(batch.texture) >= resources.images.len) return error.MissingTexture;
            try validImage(resources.images[@backingInt(batch.texture)], dst, scratch);
            if (batch.first > list.quad_len or batch.count > list.quad_len - batch.first) return error.InvalidRange;
            for (batch.first..batch.first + batch.count) |i| {
                _ = try stock(&list.quads[i]);
                if (view.tree) |input| if ((try treeClips(input.value, input.nodes.quads[i], input.scratch)).len + view.clips.len > limits.clips) return error.BudgetExceeded;
            }
        },
        .text => |run| {
            if (run >= list.run_len or run >= resources.glyphs.first.len or run >= resources.glyphs.count.len) return error.MissingGlyphs;
            const span = resources.glyphs.span(run);
            if (span[0] > resources.glyphs.quads.len or span[1] > resources.glyphs.quads.len - span[0]) return error.InvalidRange;
            if (@backingInt(resources.glyphs.texture) >= resources.images.len) return error.MissingTexture;
            try validImage(resources.images[@backingInt(resources.glyphs.texture)], dst, scratch);
            for (resources.glyphs.quads[span[0]..][0..span[1]]) |*q| _ = try stock(q);
            if (view.tree) |input| if ((try treeClips(input.value, input.nodes.runs[run], input.scratch)).len + view.clips.len > limits.clips) return error.BudgetExceeded;
        },
        .custom => |custom| {
            if (custom >= list.custom_len or custom >= resources.customs.len) return error.MissingCustomImage;
            try validImage(resources.customs[custom], dst, scratch);
            if (view.tree) |input| if ((try treeClips(input.value, list.customs[custom].node, input.scratch)).len + view.clips.len > limits.clips) return error.BudgetExceeded;
        },
    };
    for (first..first + count) |command| switch (list.command(@intCast(command))) {
        .quads => |batch| for (batch.first..batch.first + batch.count) |i| {
            const node = if (view.tree) |input| input.nodes.quads[i] else types.none;
            if (!included(node, view.nodes)) continue;
            const clips = if (view.tree) |input| try treeClips(input.value, node, input.scratch) else &.{};
            try paintQuad(dst, scratch, list.quads[i], resources.images[@backingInt(batch.texture)], view, clips);
        },
        .text => |run| {
            const node = if (view.tree) |input| input.nodes.runs[run] else types.none;
            if (!included(node, view.nodes)) continue;
            const clips = if (view.tree) |input| try treeClips(input.value, node, input.scratch) else &.{};
            const span = resources.glyphs.span(run);
            for (resources.glyphs.quads[span[0]..][0..span[1]]) |q| try paintQuad(dst, scratch, q, resources.images[@backingInt(resources.glyphs.texture)], view, clips);
        },
        .custom => |custom| {
            const c = list.customs[custom];
            if (!included(c.node, view.nodes)) continue;
            const clips = if (view.tree) |input| try treeClips(input.value, c.node, input.scratch) else &.{};
            const q: draw.Quad = .{ .rect = c.rect, .clip = c.clip, .params = @splat(0), .uv = .{ 0, 0, 1, 1 }, .radii = @splat(0), .fill = 0xffffffff, .border_color = 0, .border = 0, .opacity = c.opacity, .xform = c.xform, .clip_radii = c.clip_radii };
            try paintQuad(dst, scratch, q, resources.customs[custom], view, clips);
        },
    };
}

fn paintQuad(dst: surface.Surface, scratch: surface.Surface, source: draw.Quad, image: software.Image, view: View, clips: []const decoration.Clip) Error!void {
    if (!geometry.hasArea(geometry.quadBounds(source)) or geometry.inverse(source.xform) == null) return;
    try surface.clear(scratch, @splat(0));
    var q = source;
    q.xform[4] -= view.origin[0];
    q.xform[5] -= view.origin[1];
    q.clip[0] -= view.origin[0];
    q.clip[2] -= view.origin[0];
    q.clip[1] -= view.origin[1];
    q.clip[3] -= view.origin[1];
    if (view.tree != null) q.clip_radii = @splat(0);
    var framebuffer: software.Framebuffer = .{ .pixels = scratch.pixels, .width = scratch.width, .height = scratch.height, .stride = @intCast(scratch.stride), .format = .rgba8 };
    const target: software.Target = .{ .fb = &framebuffer, .scissor = framebuffer.all() };
    switch (try stock(&q)) {
        inline else => |kind| software.shade(kind, target, &q, image, view.scale),
    }
    if (clips.len != 0 or view.clips.len != 0) try applyClips(scratch, clips, view);
    try compositor.composite(dst, scratch.view(), .{});
}

/// Applies the intersection at each coverage sample, avoiding double-darkening where two
/// identical rounded edges meet. Useful directly for a host-rasterized custom surface too.
pub fn applyClips(dst: surface.Surface, clips: []const decoration.Clip, view: View) Error!void {
    if (!std.math.isFinite(view.scale) or view.scale <= 0 or !std.math.isFinite(view.origin[0]) or !std.math.isFinite(view.origin[1])) return error.InvalidScale;
    try dst.validate();
    try decoration.validateClips(clips);
    try decoration.validateClips(view.clips);
    const samples: u32 = switch (view.quality) {
        .one => 1,
        .four => 2,
        .sixteen => 4,
    };
    const scale = simd.f(view.scale);
    for (0..dst.height) |y| {
        var x: usize = 0;
        while (x < simd.padded(dst.width)) : (x += simd.lanes) {
            var coverage: simd.F = @splat(0);
            const column: simd.F = @floatFromInt(simd.iota + simd.u(@intCast(x)));
            for (0..samples) |sy| for (0..samples) |sx| {
                const xx = (column + simd.f((@as(f32, @floatFromInt(sx)) + 0.5) / @as(f32, @floatFromInt(samples)))) / scale + simd.f(view.origin[0]);
                const yy = simd.f((@as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(sy)) + 0.5) / @as(f32, @floatFromInt(samples))) / view.scale + view.origin[1]);
                coverage += decoration.clipCoverage(clips, xx, yy) * decoration.clipCoverage(view.clips, xx, yy);
            };
            coverage /= simd.f(@floatFromInt(samples * samples));
            var pixel = surface.load(dst, x, y);
            inline for (0..4) |channel| pixel[channel] *= coverage;
            surface.store(dst, x, y, pixel);
        }
    }
}

test "prepared texture binds a current layout box and preserves layout border metrics" {
    var raw: [64 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var t = tree.Tree.init(&carver, 8);
    var text = Texts.init(&carver, 1);
    const custom = @import("../core/customs.zig").Customs.init(&carver, 1);
    var list = draw.DrawList.init(&carver, 8, 1, 1);
    const root = t.push(0, .none, &.{ .size = .{ .px(100), .px(80) }, .pad = @splat(10) });
    const template = row(&.{ .size = .{ .px(40), .px(20) }, .border = 2, .clip = true });
    const box = t.pushRow(root, .none, &template);
    t.seal(box);
    t.seal(root);
    @import("../layout/layout.zig").run(&t, &text, .{ 100, 80 });
    var storage: [8192]u32 = undefined;
    var upload: [8192]u32 = undefined;
    const layers = [_]decoration.Layer{.{ .brush = .{ .solid = .{ 0.2, 0.4, 0.8, 1 } } }};
    const baked = try bake(.{ .rect = t.rect(box) }, .{ .backgrounds = &layers, .outline = .{ .width = 2, .offset = 1, .brush = .{ .solid = .{ 1, 1, 0, 1 } } } }, 1, &.{}, .four, .{}, &storage, &upload);
    try bind(&t, @fromBackingInt(box), baked, @fromBackingInt(1), 7);
    @import("../draw/paint.zig").emit(&t, &text, &custom, "", &list);
    try std.testing.expectEqual(@as(f32, 2), t.border(box));
    try std.testing.expectEqual(baked.rect.array(), list.quads[0].rect);
    try std.testing.expectEqual(@as(f32, 0), list.quads[0].border);
    try std.testing.expectEqual(@as(u32, 7), t.x.row[t.c.extra[box]].paint_revision);
    try std.testing.expectError(error.BudgetExceeded, measure(.{ .rect = t.rect(box) }, .{}, 100, .{ .width = 64 }));
}

test "ordinary quad text and custom commands participate in an exact clipped isolated group" {
    var raw: [64 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var t = tree.Tree.init(&carver, 8);
    var text = Texts.init(&carver, 1);
    var custom = @import("../core/customs.zig").Customs.init(&carver, 1);
    var list = draw.DrawList.init(&carver, 8, 1, 1);
    const root = t.push(0, .none, &.{ .size = .{ .px(32), .px(32) }, .clip = true, .radius = 16 });
    const box = t.push(root, .none, &.{ .size = .{ .px(32), .px(32) }, .fill = .white });
    const child = t.push(root, .none, &.{ .float = true, .size = .{ .px(32), .px(32) } });
    t.c.custom[child] = custom.push(child, .none, 0);
    const label = t.push(root, .none, &.{ .float = true, .offset = .{ 12, 6 }, .size = .{ .px(4), .px(4) } });
    t.c.text[label] = text.push(label, .{ .start = 0, .bytes = 1 }, &.{ .px = 4, .color = .rgb(0, 0, 255) });
    const font: @import("../text/protocol.zig").Mono = .{ .advance = 1, .line = 1 };
    font.measure(&text);
    t.seal(root);
    @import("../layout/layout.zig").run(&t, &text, .{ 32, 32 });
    @import("../draw/paint.zig").emit(&t, &text, &custom, "X", &list);
    var glyph_quads: [2]draw.Quad = undefined;
    var first: [1]u32 = undefined;
    var count: [1]u32 = undefined;
    const glyph_count = font.quads(&list, &glyph_quads, .{ .first = &first, .count = &count });
    const glyphs: iface.Glyphs = .{ .quads = glyph_quads[0..glyph_count], .first = &first, .count = &count };
    var map: [8]u32 = undefined;
    var clips: [8]decoration.Clip = undefined;
    const nodes = try mapNodes(&t, &text, &list, &.{}, &map);
    var group_pixels: [2048]u32 = undefined;
    var scratch_pixels: [2048]u32 = undefined;
    var output_pixels: [2048]u32 = undefined;
    const group = try surface.init(&group_pixels, 32, 32);
    const scratch = try surface.init(&scratch_pixels, 32, 32);
    const output = try surface.init(&output_pixels, 32, 32);
    const image: software.Image = .{ .pixels = &.{types.Color.rgb(255, 0, 0).bitsOf()}, .width = 1, .height = 1 };
    try std.testing.expectError(error.MissingCustomImage, drawRange(group, scratch, &list, 0, list.cmd_len, .{}, .{}, .{}));
    try std.testing.expectError(error.MissingGlyphs, drawRange(group, scratch, &list, 0, list.cmd_len, .{ .customs = &.{image} }, .{}, .{}));
    try drawRange(group, scratch, &list, 0, list.cmd_len, .{ .customs = &.{image}, .glyphs = glyphs }, .{ .tree = .{ .value = &t, .nodes = nodes, .scratch = &clips } }, .{});
    try compositor.composite(output, group.view(), .{ .opacity = 0.5 });
    try std.testing.expectEqual(@as(u32, 0), output.pixels[0]);
    try std.testing.expectEqual(@as(u32, 128), output.pixels[16 * output.stride + 16] >> 24);
    try std.testing.expectEqual(@as(u32, 128), output.pixels[16 * output.stride + 16] & 255);
    try std.testing.expectEqual(@as(u32, 0x80800000), output.pixels[8 * output.stride + 14]);
    try std.testing.expectEqual(label, nodes.runs[0]);
    try std.testing.expectEqual(box, nodes.quads[0]);
}
