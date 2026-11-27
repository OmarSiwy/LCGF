//! A real styling gallery built from the public CPU paint operations. The example allocates
//! its own temporary storage; the library primitives retain no allocator or rendering loop.
//! The wrapper supplies `lcgf` and `gallery_font` (src/example/font.zig), then exports the
//! returned premultiplied surface as straight RGBA before PNG/GPU texture use.
const std = @import("std");
const lcgf = @import("lcgf");
const font_asset = @import("gallery_font");
const surface = lcgf.surface;
const brushes = lcgf.brushes;
const decoration = lcgf.decoration;
const compositor = lcgf.compositor;
const paths = lcgf.paths;
const vector = lcgf.vector;
const projective = lcgf.projective;
const color = lcgf.color_math;
const simd = lcgf.simd;
const Rect = lcgf.types.Rect;

pub const width: u32 = 1000;
pub const height: u32 = 800;
const panel_width: u32 = 466;
const panel_height: u32 = 212;
const white: color.Rgba = .{ 1, 1, 1, 1 };
const clear: color.Rgba = .{ 0, 0, 0, 0 };
fn rgb(value: u32) color.Rgba {
    return .{ @as(f32, @floatFromInt(value >> 16)) / 255, @as(f32, @floatFromInt((value >> 8) & 255)) / 255, @as(f32, @floatFromInt(value & 255)) / 255, 1 };
}
fn rgba(value: u32, alpha: f32) color.Rgba {
    var c = rgb(value);
    c[3] = alpha;
    return c;
}
fn box(x: f32, y: f32, w: f32, h: f32) Rect {
    return .{ .x0 = x, .y0 = y, .x1 = x + w, .y1 = y + h };
}
fn newSurface(allocator: std.mem.Allocator, w: u32, h: u32) !surface.Surface {
    return surface.init(try allocator.alloc(u32, try surface.requiredPixels(w, h)), w, h);
}
fn fill(dst: surface.Surface, rect: Rect, radius: f32, brush: brushes.Brush) !void {
    try decoration.paintShape(dst, .{ .rect = rect, .radii = @splat(.{ radius, radius }) }, .{ .brush = brush }, .{});
}
fn solid(dst: surface.Surface, rect: Rect, radius: f32, value: color.Rgba) !void {
    try fill(dst, rect, radius, .{ .solid = value });
}

/// The font asset is 8-bit coverage with white implied (src/example/font.zig); the image brush
/// samples 32-bit texels, so the gallery expands it once, at compile time.
const atlas_pixels: [font_asset.image.alpha8.len]u32 = blk: {
    @setEvalBranchQuota(4 * font_asset.image.alpha8.len);
    var out: [font_asset.image.alpha8.len]u32 = undefined;
    for (font_asset.image.alpha8, &out) |a, *pixel| pixel.* = lcgf.types.Color.rgba(255, 255, 255, a).bitsOf();
    break :blk out;
};

/// Font pixels and source UVs are the repository's real printable-ASCII font. Mono supplies
/// exactly the same advance/line metrics as the application's normal text protocol.
fn label(allocator: std.mem.Allocator, dst: surface.Surface, text: []const u8, position: [2]i32, px: f32, tint: color.Rgba) !void {
    const mono: lcgf.protocol.Mono = .{};
    const advance = mono.advance * px;
    const line_height = mono.line * px;
    const w: u32 = @intFromFloat(@max(1, @ceil(advance * @as(f32, @floatFromInt(text.len)))));
    const h: u32 = @intFromFloat(@ceil(line_height));
    const image = try newSurface(allocator, w, h);
    const atlas: surface.Image = .{ .pixels = &atlas_pixels, .width = font_asset.image.width, .height = font_asset.image.height, .stride = font_asset.image.width, .alpha = .straight };
    for (text, 0..) |byte, i| {
        const uv = try font_asset.uv(byte);
        const x = @as(f32, @floatFromInt(i)) * advance;
        const rect = box(x, 0, advance, line_height);
        try decoration.paintShape(image, .{ .rect = rect }, .{ .brush = .{ .image = .{ .image = atlas, .source = .{ .x0 = uv[0] * @as(f32, @floatFromInt(atlas.width)), .y0 = uv[1] * @as(f32, @floatFromInt(atlas.height)), .x1 = uv[2] * @as(f32, @floatFromInt(atlas.width)), .y1 = uv[3] * @as(f32, @floatFromInt(atlas.height)) }, .destination = rect, .area = rect, .tint = tint } } }, .{ .quality = .one });
    }
    try compositor.composite(dst, image.view(), .{ .offset = position });
}

const Geometry = struct {
    source: paths.TestBuffers(512, 8192) = .{},
    temporary: paths.TestBuffers(1024, 16384) = .{},
    strokes: paths.TestBuffers(1024, 16384) = .{},
    path: paths.Path = undefined,
    polyline: paths.Polyline = undefined,
    work: paths.Polyline = undefined,
    outline: paths.Polyline = undefined,
    accumulator: []f32 = &.{},
    coverage: []u8 = &.{},
    widths: [8192]f32 = undefined,
    fn create(allocator: std.mem.Allocator) !*Geometry {
        const g = try allocator.create(Geometry);
        g.* = .{};
        g.path = g.source.path();
        g.polyline = g.source.polyline();
        g.work = g.temporary.polyline();
        g.outline = g.strokes.polyline();
        g.accumulator = try allocator.alloc(f32, simd.rows(panel_width * panel_height + 2));
        g.coverage = try allocator.alloc(u8, simd.rows(panel_width * panel_height));
        return g;
    }
    fn paint(g: *Geometry, dst: surface.Surface, poly: *const paths.Polyline, brush: brushes.Brush) !void {
        const bounds = paths.bounds(poly);
        if (bounds.w == 0 or bounds.h == 0) return;
        if (g.accumulator.len < paths.accLen(bounds) or g.coverage.len < paths.imageLen(bounds)) return error.GalleryGeometryTooLarge;
        paths.fill(poly, bounds, .nonzero, g.strokes.scratch(), g.accumulator);
        paths.coverage(g.accumulator, g.coverage, @as(usize, bounds.w) * bounds.h);
        try vector.paintCoverage(dst, .{ .bytes = g.coverage, .box = bounds }, brush, .{ .quality = .one }, 1);
    }
};

fn panel(allocator: std.mem.Allocator, index: usize, title: []const u8, dark: bool) !surface.Surface {
    const dst = try newSurface(allocator, panel_width, panel_height);
    const background = rgb(if (dark) 0x122136 else 0xffffff);
    try solid(dst, box(0, 0, panel_width, panel_height), 16, background);
    try solid(dst, box(20, 20, 4, 20), 2, rgb(if (dark) 0x45d2c8 else 0x4b57d6));
    var text: [8]u8 = undefined;
    const tag = try std.fmt.bufPrint(&text, "0{d}", .{index});
    try label(allocator, dst, tag, .{ 34, 18 }, 16, rgb(if (dark) 0x73e3d5 else 0x4b57d6));
    try label(allocator, dst, title, .{ 68, 18 }, 16, rgb(if (dark) 0xf4f7fc else 0x17243b));
    return dst;
}
fn caption(allocator: std.mem.Allocator, dst: surface.Surface, text: []const u8, dark: bool) !void {
    try label(allocator, dst, text, .{ 20, 183 }, 12, rgb(if (dark) 0x9cacc4 else 0x63728b));
}

fn composed(allocator: std.mem.Allocator) !surface.Surface {
    const dst = try panel(allocator, 1, "COMPOSED DECORATION", false);
    var stops: [4]brushes.Segment = undefined;
    const ramp = try brushes.prepareStops(&.{ .{ .position = 0, .color = rgb(0x2c54ee) }, .{ .position = 0.45, .color = rgb(0x9b51e8) }, .{ .position = 0.7, .color = rgb(0xf36c9e) }, .{ .position = 1, .color = rgb(0xffc57a) } }, &stops, .{ .space = .oklab }, .pad);
    const card: decoration.RoundedRect = .{ .rect = box(27, 65, 196, 96), .radii = .{ .{ 30, 14 }, .{ 14, 30 }, .{ 30, 14 }, .{ 14, 30 } } };
    try decoration.paint(dst, card, .{
        .backgrounds = &.{ .{ .brush = .{ .linear = .{ .ramp = ramp, .from = .{ 25, 65 }, .to = .{ 225, 165 } } } }, .{ .brush = .{ .solid = rgba(0xffffff, 0.13) }, .clip = .content } },
        .padding = @splat(11),
        .border = .{ .edges = .{ .{ .width = 4, .brush = .{ .solid = rgb(0x2b46ae) } }, .{ .width = 3, .brush = .{ .solid = white }, .style = .dashed, .dash = 10, .gap = 5 }, .{ .width = 4, .brush = .{ .solid = rgb(0x7132a7) } }, .{ .width = 3, .brush = .{ .solid = rgba(0xffffff, 0.7) } } } },
        .shadows = &.{.{ .offset = .{ 0, 8 }, .sigma = 5, .spread = 1, .color = rgba(0x19365d, 0.27) }},
    }, .{ .quality = .sixteen });
    try label(allocator, dst, "LAYERED COLOR", .{ 55, 95 }, 15, white);
    try label(allocator, dst, "elliptical corners", .{ 48, 119 }, 11, rgba(0xffffff, 0.9));
    try decoration.paint(dst, .{ .rect = box(270, 83, 157, 60), .radii = @splat(.{ 16, 16 }) }, .{
        .backgrounds = &.{.{ .brush = .{ .solid = rgb(0x303a73) } }},
        .border = .{ .edges = @splat(.{ .width = 2, .brush = .{ .solid = rgb(0xa5afe9) } }) },
        .outline = .{ .width = 3, .offset = 5, .brush = .{ .solid = rgb(0x19b9b0) } },
        .shadows = &.{.{ .offset = .{ 0, 2 }, .sigma = 2, .color = rgba(0, 0.25), .inset = true }},
    }, .{});
    try label(allocator, dst, "FOCUS RING", .{ 298, 102 }, 14, white);
    try caption(allocator, dst, "MULTI-STOP / PER-EDGE BORDER / SHADOW / OUTLINE", false);
    return dst;
}

fn asset(allocator: std.mem.Allocator) !surface.Image {
    // Exact existing source asset: src/assets/testdata/icon16.png.
    const bytes = @embedFile("icon16.png");
    const info = try lcgf.png.info(bytes);
    const pixels = try allocator.alloc(u32, @as(usize, info.w) * info.h);
    const scratch = try allocator.alloc(u8, info.scratchBytes());
    _ = try lcgf.png.decode(bytes, std.mem.sliceAsBytes(pixels), scratch);
    return .{ .pixels = pixels, .width = info.w, .height = info.h, .stride = info.w, .alpha = .premultiplied };
}
fn images(allocator: std.mem.Allocator, source: surface.Image) !surface.Surface {
    const dst = try panel(allocator, 2, "IMAGE FIT + TILING", true);
    const placements = [_]Rect{ box(20, 64, 129, 92), box(168, 64, 129, 92), box(316, 64, 129, 92) };
    for (placements) |rect| try solid(dst, rect, 9, rgb(0x263950));
    const crop: Rect = .{ .x1 = 16, .y1 = 8 };
    const fit_modes = [_]brushes.Fit{ .contain, .cover };
    for (fit_modes, 0..) |mode, i| {
        const rect = placements[i];
        const fitted = try brushes.fitRect(.{ crop.w(), crop.h() }, rect, mode, .{ 0.5, 0.5 });
        try decoration.paintShape(dst, .{ .rect = rect, .radii = @splat(.{ 9, 9 }) }, .{ .brush = .{ .image = .{ .image = source, .source = crop, .destination = fitted, .area = rect, .sampling = .linear } } }, .{});
    }
    try decoration.paintShape(dst, .{ .rect = placements[2], .radii = @splat(.{ 9, 9 }) }, .{ .brush = .{ .image = .{ .image = source, .source = .{ .x1 = 16, .y1 = 16 }, .destination = box(316, 64, 28, 28), .area = placements[2], .repeat = .{ .round, .round }, .orientation = .rotate_90, .sampling = .nearest } } }, .{});
    try label(allocator, dst, "CONTAIN", .{ 51, 161 }, 11, rgb(0xced9ea));
    try label(allocator, dst, "COVER", .{ 210, 161 }, 11, rgb(0xced9ea));
    try label(allocator, dst, "ROUND + 90deg", .{ 337, 161 }, 11, rgb(0xced9ea));
    try caption(allocator, dst, "SOURCE PNG / CROP / ALIGNMENT / ORIENTATION", true);
    return dst;
}

fn corners(allocator: std.mem.Allocator) !surface.Surface {
    const dst = try panel(allocator, 3, "CORNERS + CONTOURS", false);
    const kinds = [_]decoration.Corner{ .round, .squircle, .bevel, .scoop, .notch };
    const names = [_][]const u8{ "ROUND", "SQUIRCLE", "BEVEL", "SCOOP", "NOTCH" };
    const colors = [_]u32{ 0x3867e8, 0x6650cd, 0xa94fa8, 0xd66382, 0xe28d59 };
    for (kinds, names, colors, 0..) |kind, name, value, i| {
        const x: f32 = 20 + @as(f32, @floatFromInt(i)) * 88;
        try decoration.paint(dst, .{ .rect = box(x + 3, 75, 70, 76), .radii = @splat(.{ 22, 22 }), .corners = @splat(kind) }, .{
            .backgrounds = &.{.{ .brush = .{ .solid = rgb(value) } }},
            .outline = .{ .width = 2, .offset = 4, .brush = .{ .solid = rgba(value, 0.35) } },
        }, .{ .quality = .sixteen });
        try label(allocator, dst, name, .{ @intFromFloat(x + if (i == 1) @as(f32, 0) else 13), 162 }, 10.5, rgb(0x53637c));
    }
    try caption(allocator, dst, "INDEPENDENT CORNERS / MATCHED OUTSIDE OUTLINES", false);
    return dst;
}

fn vectors(allocator: std.mem.Allocator, g: *Geometry) !surface.Surface {
    const dst = try panel(allocator, 4, "SVG + VECTOR STROKES", true);
    g.path.clear();
    g.path.moveTo(26, 101);
    g.path.cubicTo(90, 42, 200, 148, 278, 88);
    g.path.lineTo(340, 81);
    var marker_storage: [16]vector.Marker = undefined;
    const sites = try vector.markers(&g.path, &marker_storage);
    paths.flatten(&g.path, 0.15, &g.polyline);
    try vector.strokeDashed(&g.polyline, .{ .width = 4, .cap = .round, .join = .round }, .{ .array = &.{ 12, 5, 2, 5 }, .offset = 3, .cap = .round }, 0.15, &g.work, &g.outline);
    try g.paint(dst, &g.outline, .{ .solid = rgb(0x8ce8df) });
    for (sites) |site| {
        g.path.clear();
        g.path.moveTo(0, 0);
        g.path.lineTo(-10, -5);
        g.path.lineTo(-10, 5);
        g.path.close();
        paths.flatten(&g.path, 0.15, &g.polyline);
        try vector.transform(&g.polyline, try vector.markerTransform(site, .{ .orient = .auto_start_reverse }), &g.work);
        try g.paint(dst, &g.work, .{ .solid = rgb(0xffd488) });
    }
    g.path.clear();
    g.path.moveTo(26, 145);
    g.path.cubicTo(140, 105, 260, 190, 427, 137);
    paths.flattenWidths(&g.path, &.{ 1.5, 15 }, 0.15, &g.polyline, &g.widths);
    try vector.variableStroke(&g.polyline, &g.widths, 0.15, &g.outline);
    var segments: [3]brushes.Segment = undefined;
    const ramp = try brushes.prepareStops(&.{ .{ .position = 0, .color = rgb(0x508bff) }, .{ .position = 0.5, .color = rgb(0xc17afa) }, .{ .position = 1, .color = rgb(0xff9e9b) } }, &segments, .{ .space = .oklab }, .pad);
    try g.paint(dst, &g.outline, .{ .linear = .{ .ramp = ramp, .from = .{ 26, 145 }, .to = .{ 427, 137 } } });
    var gradient_rows: [2]lcgf.svg.Gradient = undefined;
    var stop_rows: [8]brushes.Stop = undefined;
    var svg_segments: [8]brushes.Segment = undefined;
    var stack: [8]lcgf.svg.Frame = undefined;
    var dashes: [16]f32 = undefined;
    var clips: [2]decoration.Clip = undefined;
    try lcgf.svg.paint("<svg viewBox='0 0 32 32'><defs><linearGradient id='g'><stop stop-color='#ffcf7a'/><stop offset='1' stop-color='#ff7f9f'/></linearGradient></defs><path fill='url(#g)' d='M16 1 20 11 31 12 23 20 25 31 16 25 7 31 9 20 1 12 12 11Z'/></svg>", dst, .{ .viewport = box(376, 62, 57, 57) }, .{ .path = &g.path, .centerline = &g.polyline, .work = &g.work, .outline = &g.outline, .fill = g.strokes.scratch(), .accumulator = g.accumulator, .coverage = g.coverage, .gradients = &gradient_rows, .stops = &stop_rows, .segments = &svg_segments, .stack = &stack, .dashes = &dashes, .clips = &clips });
    try caption(allocator, dst, "DASH PHASE / TANGENT MARKERS / TAPER / SVG", true);
    return dst;
}

fn perspectivePanel(allocator: std.mem.Allocator) !surface.Surface {
    const dst = try panel(allocator, 5, "PERSPECTIVE + CLIPS", false);
    const tile = try newSurface(allocator, 190, 105);
    var segments: [3]brushes.Segment = undefined;
    const ramp = try brushes.prepareStops(&.{ .{ .position = 0, .color = rgb(0x2187b9) }, .{ .position = 0.5, .color = rgb(0x40d2b7) }, .{ .position = 1, .color = rgb(0xc7ef9f) } }, &segments, .{}, .pad);
    try fill(tile, box(0, 0, 190, 105), 0, .{ .linear = .{ .ramp = ramp, .from = .{ 0, 0 }, .to = .{ 190, 105 } } });
    for (0..6) |i| try solid(tile, box(@as(f32, @floatFromInt(i)) * 38 - 15, 0, 7, 105), 0, rgba(0xffffff, 0.2));
    try label(allocator, tile, "PROJECTED", .{ 18, 31 }, 25, rgb(0x093b55));
    try label(allocator, tile, "TEXTURE PLANE", .{ 25, 65 }, 14, rgb(0x17677a));
    const first = try projective.prepare(.{ 1, 0.15, 24, -0.05, 0.82, 75, 0.0015, -0.0005, 1 });
    try projective.paint(dst, tile.view(), first, .{ .quality = .sixteen }, .{});
    const clip: decoration.Clip = .{ .rounded = .{ .shape = .{ .rect = box(250, 66, 184, 107), .radii = @splat(.{ 36, 28 }) } } };
    const second = try projective.prepare(.{ 1.08, 0.23, 232, -0.1, 1.08, 78, 0.00075, 0.0003, 1 });
    try projective.paint(dst, tile.view(), second, .{ .quality = .sixteen, .clips = &.{clip} }, .{});
    try decoration.paint(dst, clip.rounded.shape, .{ .outline = .{ .width = 1.5, .offset = 2, .brush = .{ .solid = rgba(0x247f89, 0.5) } } }, .{});
    try caption(allocator, dst, "PROJECTIVE UV / TRANSFORMED PLANE / ROUNDED CLIP", false);
    return dst;
}

fn groups(allocator: std.mem.Allocator) !surface.Surface {
    const dst = try panel(allocator, 6, "GROUPS + BACKDROP", true);
    const group = try newSurface(allocator, panel_width, panel_height);
    try solid(group, box(38, 68, 91, 91), 45.5, rgb(0x2ccfc3));
    try decoration.paintShape(group, .{ .rect = box(89, 68, 91, 91), .radii = @splat(.{ 45.5, 45.5 }) }, .{ .brush = .{ .solid = rgb(0xbf60dc) }, .blend = .screen }, .{});
    var segments: [2]brushes.Segment = undefined;
    const ramp = try brushes.prepareStops(&.{ .{ .position = 0, .color = white }, .{ .position = 1, .color = clear } }, &segments, .{}, .pad);
    const mask = try newSurface(allocator, panel_width, panel_height);
    try fill(mask, box(0, 0, panel_width, panel_height), 0, .{ .linear = .{ .ramp = ramp, .from = .{ 100, 0 }, .to = .{ 205, 0 } } });
    try compositor.applyMask(group, mask.view(), .{});
    try compositor.composite(dst, group.view(), .{ .opacity = 0.75 });
    try label(allocator, dst, "SCREEN + MASK", .{ 49, 163 }, 11, rgb(0xa9b9cf));
    for (0..7) |i| {
        const tint = if (i % 2 == 0) rgb(0xe5a560) else rgb(0x547eaf);
        try solid(dst, box(238 + @as(f32, @floatFromInt(i)) * 29, 64, 15, 99), 6, tint);
    }
    const snapshot = try newSurface(allocator, panel_width, panel_height);
    const blurred = try newSurface(allocator, panel_width, panel_height);
    const temporary = try newSurface(allocator, panel_width, panel_height);
    try compositor.capture(snapshot, dst.view(), .{ 0, 0 }, .{ .clamp, .clamp });
    var kernel: [65]f32 = undefined;
    const weights = try compositor.gaussianKernel(4, &kernel);
    try compositor.blur(snapshot, blurred, temporary, weights, .{ .clamp, .clamp });
    try surface.clear(mask, clear);
    const glass: decoration.RoundedRect = .{ .rect = box(255, 77, 171, 76), .radii = @splat(.{ 16, 16 }) };
    try decoration.paintShape(mask, glass, .{ .brush = .{ .solid = white } }, .{});
    try compositor.applyMask(blurred, mask.view(), .{});
    try compositor.composite(dst, blurred.view(), .{});
    try decoration.paint(dst, glass, .{ .backgrounds = &.{.{ .brush = .{ .solid = rgba(0xeaf6ff, 0.13) } }}, .border = .{ .edges = @splat(.{ .width = 1.5, .brush = .{ .solid = rgba(0xffffff, 0.65) } }) } }, .{});
    try label(allocator, dst, "FROSTED", .{ 291, 101 }, 20, white);
    try label(allocator, dst, "BACKDROP BLUR", .{ 285, 163 }, 11, rgb(0xa9b9cf));
    try caption(allocator, dst, "ISOLATED ALPHA / MASK / BLEND / SNAPSHOT FILTER", true);
    return dst;
}

pub fn render(allocator: std.mem.Allocator, dst: surface.Surface) !void {
    try dst.validate();
    if (dst.width != width or dst.height != height) return error.GallerySizeMismatch;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try surface.clear(dst, rgb(0xe9eef5));
    try solid(dst, box(0, 0, width, 88), 0, rgb(0x0b1424));
    try label(a, dst, "LCGF / STYLING LAB", .{ 25, 17 }, 28, rgb(0xf2f6fc));
    try label(a, dst, "Real paint operations. Caller-owned storage. One compact texture path.", .{ 27, 57 }, 13, rgb(0xa9b9cf));
    try solid(dst, box(772, 26, 200, 30), 15, rgb(0x203c4f));
    try label(a, dst, "CPU REFERENCE RENDER", .{ 785, 33 }, 12, rgb(0x8fe5d4));
    const source = try asset(a);
    const geometry_storage = try Geometry.create(a);
    const panels = [_]surface.Surface{ try composed(a), try images(a, source), try corners(a), try vectors(a, geometry_storage), try perspectivePanel(a), try groups(a) };
    for (panels, 0..) |image, i| try compositor.composite(dst, image.view(), .{ .offset = .{ @as(i32, 24) + @as(i32, @intCast(i % 2)) * 486, @as(i32, 105) + @as(i32, @intCast(i / 2)) * 226 } });
    try label(a, dst, "RGBA is premultiplied internally; exported textures use straight alpha.", .{ 26, 778 }, 11, rgb(0x69778c));
}
