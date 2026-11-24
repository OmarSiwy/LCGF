//! Headless geometry census of the actual application, using the same Mono font
//! and atlas expansion as host.draw. This is a diagnostic, not a benchmark.
//! Usage: geometry [physical-width [physical-height [scale]]]
//! The build must provide `font` from the selected LCGF package's example/font.zig.

const std = @import("std");
const builtin = @import("builtin");
const lcgf = @import("lcgf");
const application = @import("app");
const host = @import("host");
const atlas = @import("font");
const Context = lcgf.context.Context;
const Output = lcgf.context.Output;
const Quad = lcgf.draw_list.Quad;
const Image = lcgf.render_sw.Image;
const limits = application.limits;

var app: application.App = .{};
var storage: [Context.requiredBytes(limits)]u8 align(lcgf.mem.column_align) = @splat(0);
// Mono reserves its final row. One extra row prevents truncating a completely
// full strings buffer; the emitted glyph count is also checked below.
var glyph_quads: [limits.strings + 1]Quad = undefined;
var first: [limits.texts]u32 = undefined;
var count: [limits.texts]u32 = undefined;
const glyphs: host.Glyphs = .{ .quads = &glyph_quads, .first = &first, .count = &count };

const Area = struct {
    count: u32 = 0,
    clipped_aabb_px2: f64 = 0,
    shader_box_px: f64 = 0,

    fn add(self: *Area, geometry: Geometry) void {
        self.count += 1;
        self.clipped_aabb_px2 += geometry.clipped_aabb_px2;
        self.shader_box_px += geometry.shader_box_px;
    }
};

/// Mutually exclusive categories, ordered by the existing whole-pixel shortcut
/// before the plainRect geometry predicate. These are eligibility, not a claim
/// about which path any particular framework revision actually dispatches.
const Class = enum {
    solid_rect,
    plain_white_rect,
    plain_textured_rect,
    general_white,
    general_textured,
};

const Classes = struct {
    solid_rect: Area = .{},
    plain_white_rect: Area = .{},
    plain_textured_rect: Area = .{},
    general_white: Area = .{},
    general_textured: Area = .{},

    fn add(self: *Classes, class: Class, geometry: Geometry) void {
        switch (class) {
            inline else => |tag| @field(self, @tagName(tag)).add(geometry),
        }
    }
};

const Summary = struct {
    total: Area = .{},
    classes: Classes = .{},
    // These independent properties overlap. Their areas must not be added.
    white_binding: Area = .{},
    solid_material: Area = .{},
    solid_feature: Area = .{},
    identity_transform: Area = .{},
    border_nonzero: Area = .{},
    border_at_shader_threshold: Area = .{},
    rounded_corners: Area = .{},
    rounded_clip: Area = .{},
    fractional_rect_physical: Area = .{},
    fractional_clip_physical: Area = .{},
    opacity_not_one: Area = .{},
    plain_rect_eligible: Area = .{},
    plain_white_fractional: Area = .{},
    legacy_general_fallback: Area = .{},
    solid_rect_with_corners: Area = .{},
    empty_clipped_aabb: Area = .{},

    fn add(self: *Summary, q: *const Quad, geometry: Geometry, facts: Facts, material: lcgf.types.Material) void {
        self.total.add(geometry);
        self.classes.add(facts.class, geometry);
        if (facts.white_binding) self.white_binding.add(geometry);
        if (material == .solid) self.solid_material.add(geometry);
        if (@as(u32, @bitCast(q.params[0])) == 0) self.solid_feature.add(geometry);
        if (identity(q)) self.identity_transform.add(geometry);
        if (q.border != 0) self.border_nonzero.add(geometry);
        if (q.border >= 0.001) self.border_at_shader_threshold.add(geometry);
        if (positive(q.radii)) self.rounded_corners.add(geometry);
        if (positive(q.clip_radii)) self.rounded_clip.add(geometry);
        if (geometry.fractional_rect) self.fractional_rect_physical.add(geometry);
        if (geometry.fractional_clip) self.fractional_clip_physical.add(geometry);
        if (q.opacity != 1) self.opacity_not_one.add(geometry);
        if (facts.plain_rect) self.plain_rect_eligible.add(geometry);
        if (facts.plain_rect and facts.white_binding and geometry.fractional_rect)
            self.plain_white_fractional.add(geometry);
        if (!facts.solid_rect) self.legacy_general_fallback.add(geometry);
        if (facts.solid_rect and positive(q.radii)) self.solid_rect_with_corners.add(geometry);
        if (geometry.clipped_aabb_px2 == 0) self.empty_clipped_aabb.add(geometry);
    }
};

const Geometry = struct {
    physical_aabb: [4]f32,
    clipped_physical_aabb: [4]f32,
    clipped_aabb_px2: f64,
    shader_box_px: f64,
    fractional_rect: bool,
    fractional_clip: bool,
};

const Facts = struct {
    class: Class,
    white_binding: bool,
    solid_rect: bool,
    plain_rect: bool,
};

const Largest = struct {
    quad_index: u32,
    command_index: u32,
    texture: u16,
    material: u16,
    class: Class,
    white_binding: bool,
    plain_rect_eligible: bool,
    legacy_general_fallback: bool,
    rect: [4]f32,
    clip: [4]f32,
    radii: [4]f32,
    clip_radii: [4]f32,
    border: f32,
    opacity: f32,
    fill_rgba8: u32,
    xform: [6]f32,
    params_kind: []const u8,
    params_code: u32,
    geometry: Geometry,
};

var largest: [10]Largest = undefined;
var largest_len: usize = 0;

fn identity(q: *const Quad) bool {
    return std.mem.eql(f32, &q.xform, &.{ 1, 0, 0, 1, 0, 0 });
}

fn zero(values: [4]f32) bool {
    for (values) |value| if (value != 0) return false;
    return true;
}

fn positive(values: [4]f32) bool {
    for (values) |value| if (value > 0) return true;
    return false;
}

fn fractional(values: [4]f32, scale: f32) bool {
    for (values) |value| {
        const physical = value * scale;
        if (@floor(physical) != physical) return true;
    }
    return false;
}

fn classify(q: *const Quad, img: Image, geometry: Geometry) Facts {
    const is_identity = identity(q);
    const feature_zero = @as(u32, @bitCast(q.params[0])) == 0;
    const white_pixels = img.pixels.ptr == Image.white.pixels.ptr;
    const white_binding = white_pixels and img.width == 1 and img.height == 1;
    // Match the old renderer's solidRect predicate, including its border
    // threshold, unrestricted own radii, opacity and integer physical edges.
    const solid_rect = feature_zero and white_pixels and is_identity and
        !positive(q.clip_radii) and q.border < 0.001 and q.opacity == 1 and !geometry.fractional_rect;
    // Match plainRect with all features enabled. Texture/opacity are unrestricted;
    // a nonzero border or radius retains general shading, even below 0.001.
    const plain_rect = feature_zero and is_identity and zero(q.radii) and zero(q.clip_radii) and
        q.border == 0 and q.rect[2] > q.rect[0] and q.rect[3] > q.rect[1];
    return .{
        .class = if (solid_rect) .solid_rect else if (plain_rect)
            (if (white_binding) .plain_white_rect else .plain_textured_rect)
        else if (white_binding) .general_white else .general_textured,
        .white_binding = white_binding,
        .solid_rect = solid_rect,
        .plain_rect = plain_rect,
    };
}

/// Continuous transformed AABB clipped to q.clip and the physical viewport.
/// The second estimate follows the general shader's floor(... + 1) loop bounds,
/// but excludes extra SIMD lanes outside that box. Neither estimates alpha or
/// rounded-corner coverage, removes overlaps, or samples the font's transparency.
fn measure(q: *const Quad, dimensions: [2]u32, scale: f32) !Geometry {
    inline for (.{ q.rect, q.clip, q.radii, q.clip_radii, q.xform }) |values|
        for (values) |value| if (!std.math.isFinite(value)) return error.NonFiniteGeometry;
    if (!std.math.isFinite(q.border) or !std.math.isFinite(q.opacity)) return error.NonFiniteGeometry;
    const code: u32 = @bitCast(q.params[0]);
    const grow: f32 = if (code == 3) 3 * q.params[1] else 0;
    if (!std.math.isFinite(grow)) return error.NonFiniteGeometry;
    const x0 = q.rect[0] - grow;
    const y0 = q.rect[1] - grow;
    const x1 = q.rect[2] + grow;
    const y1 = q.rect[3] + grow;
    const a, const b, const c, const d, const tx, const ty = q.xform;
    var bounds: [4]f32 = .{ std.math.inf(f32), std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };
    for ([_][2]f32{ .{ x0, y0 }, .{ x1, y0 }, .{ x0, y1 }, .{ x1, y1 } }) |corner| {
        const x = (a * corner[0] + c * corner[1] + tx) * scale;
        const y = (b * corner[0] + d * corner[1] + ty) * scale;
        if (!std.math.isFinite(x) or !std.math.isFinite(y)) return error.NonFiniteGeometry;
        bounds[0] = @min(bounds[0], x);
        bounds[1] = @min(bounds[1], y);
        bounds[2] = @max(bounds[2], x);
        bounds[3] = @max(bounds[3], y);
    }
    const width: f32 = @floatFromInt(dimensions[0]);
    const height: f32 = @floatFromInt(dimensions[1]);
    const lo_x = @max(bounds[0], q.clip[0] * scale);
    const lo_y = @max(bounds[1], q.clip[1] * scale);
    const hi_x = @min(bounds[2], q.clip[2] * scale);
    const hi_y = @min(bounds[3], q.clip[3] * scale);
    const left = std.math.clamp(lo_x, 0, width);
    const top = std.math.clamp(lo_y, 0, height);
    const right = @max(left, std.math.clamp(hi_x, 0, width));
    const bottom = @max(top, std.math.clamp(hi_y, 0, height));
    const pixel_left = std.math.clamp(@floor(lo_x), 0, width);
    const pixel_top = std.math.clamp(@floor(lo_y), 0, height);
    const pixel_right = @max(pixel_left, std.math.clamp(@floor(hi_x + 1), 0, width));
    const pixel_bottom = @max(pixel_top, std.math.clamp(@floor(hi_y + 1), 0, height));
    return .{
        .physical_aabb = bounds,
        .clipped_physical_aabb = .{ left, top, right, bottom },
        .clipped_aabb_px2 = @as(f64, right - left) * @as(f64, bottom - top),
        .shader_box_px = @as(f64, pixel_right - pixel_left) * @as(f64, pixel_bottom - pixel_top),
        .fractional_rect = fractional(q.rect, scale),
        .fractional_clip = fractional(q.clip, scale),
    };
}

fn kindName(code: u32) []const u8 {
    return switch (code) {
        0 => "solid",
        1 => "linear",
        2 => "radial",
        3 => "shadow",
        4 => "nine_slice",
        5 => "dashed",
        6 => "dotted",
        else => "unknown_as_solid",
    };
}

fn keepLargest(entry: Largest) void {
    if (largest_len < largest.len) {
        largest[largest_len] = entry;
        largest_len += 1;
    } else if (entry.geometry.clipped_aabb_px2 > largest[largest.len - 1].geometry.clipped_aabb_px2) {
        largest[largest.len - 1] = entry;
    } else return;
    var at = largest_len - 1;
    while (at > 0 and largest[at].geometry.clipped_aabb_px2 > largest[at - 1].geometry.clipped_aabb_px2) : (at -= 1)
        std.mem.swap(Largest, &largest[at], &largest[at - 1]);
}

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const width = if (args.next()) |arg| try std.fmt.parseInt(u32, arg, 10) else 800;
    const height = if (args.next()) |arg| try std.fmt.parseInt(u32, arg, 10) else 600;
    const scale = if (args.next()) |arg| try std.fmt.parseFloat(f32, arg) else 1;
    if (args.next() != null) return error.TooManyArguments;
    if (width == 0 or height == 0 or !std.math.isFinite(scale) or scale <= 0) return error.InvalidArgument;
    const viewport: [2]f32 = .{ @as(f32, @floatFromInt(width)) / scale, @as(f32, @floatFromInt(height)) / scale };
    for (viewport) |value| if (!std.math.isFinite(value)) return error.InvalidArgument;
    const events: host.Events = .{ .in = .{ .viewport = viewport, .scale = scale } };
    var context = try Context.init(&storage, limits);
    app.init();
    var output: Output = undefined;
    // The second frame has valid preceding geometry, just as a settled snapshot.
    for (0..2) |_| {
        var frame = context.begin(&events.in);
        app.build(&frame, &events);
        output = frame.end(.{});
        if (!output.status.ok()) return error.FrameCapacityExceeded;
        if (app.snapshot().command_overflow) return error.CommandCapacityExceeded;
    }
    const mono: lcgf.protocol.Mono = .{};
    const glyph_count = try mono.quadsFor(atlas, output.draw, glyphs.quads, .{ .first = glyphs.first, .count = glyphs.count });
    var expected_glyphs: u32 = 0;
    for (output.draw.runs[0..output.draw.run_len]) |run| expected_glyphs += run.bytes;
    if (glyph_count != expected_glyphs) return error.GlyphCapacityExceeded;
    const images: []const Image = if (@hasDecl(application.App, "images")) app.images() else &.{Image.white};
    var regular: Summary = .{};
    var glyph: Summary = .{};
    var custom_commands: u32 = 0;
    const draw = output.draw;
    for (0..draw.cmd_len) |command_index| switch (draw.command(@intCast(command_index))) {
        .quads => |batch| {
            const texture = @backingInt(batch.texture);
            if (texture >= images.len) return error.MissingImageBinding;
            if (batch.first > draw.quad_len or batch.count > draw.quad_len - batch.first) return error.InvalidDrawRange;
            for (draw.quads[batch.first..][0..batch.count], 0..) |*q, offset| {
                const geometry = try measure(q, .{ width, height }, scale);
                const facts = classify(q, images[texture], geometry);
                regular.add(q, geometry, facts, batch.material);
                const code: u32 = @bitCast(q.params[0]);
                keepLargest(.{
                    .quad_index = batch.first + @as(u32, @intCast(offset)),
                    .command_index = @intCast(command_index),
                    .texture = texture,
                    .material = @backingInt(batch.material),
                    .class = facts.class,
                    .white_binding = facts.white_binding,
                    .plain_rect_eligible = facts.plain_rect,
                    .legacy_general_fallback = !facts.solid_rect,
                    .rect = q.rect,
                    .clip = q.clip,
                    .radii = q.radii,
                    .clip_radii = q.clip_radii,
                    .border = q.border,
                    .opacity = q.opacity,
                    .fill_rgba8 = q.fill,
                    .xform = q.xform,
                    .params_kind = kindName(code),
                    .params_code = code,
                    .geometry = geometry,
                });
            }
        },
        .text => |run| {
            if (run >= draw.run_len) return error.InvalidDrawRange;
            const start = glyphs.first[run];
            const len = glyphs.count[run];
            if (start > glyph_count or len > glyph_count - start) return error.InvalidDrawRange;
            for (glyphs.quads[start..][0..len]) |*q| {
                const geometry = try measure(q, .{ width, height }, scale);
                glyph.add(q, geometry, classify(q, atlas.image, geometry), .solid);
            }
        },
        .custom => custom_commands += 1,
    };
    const report = .{
        .diagnostic = "application_geometry",
        .framework = @tagName(application.options.framework),
        .framework_revision = application.options.framework_revision,
        .architecture = @tagName(application.options.architecture),
        .zig = builtin.zig_version_string,
        .physical_viewport = .{ width, height },
        .logical_viewport = viewport,
        .scale = scale,
        .frames_built = 2,
        .scope = "Geometry only; normal Frame.end and the exact host Mono/atlas glyph expansion; no timings or framebuffer",
        .area_definition = "Per-quad clipped transformed AABB area in physical pixels squared; shadows expand by 3 sigma. Overlaps and transparent glyph cells count; rounded corners, alpha, and occlusion do not reduce the estimate.",
        .shader_box_definition = "General shader floor(lower)/floor(upper + 1) loop-box estimate after rectangular clipping; not actual pixel work for solidRect, and excludes masked SIMD lanes.",
        .classification_definition = "Eligibility only, independent of renderer revision. classes partition each total, checking solidRect first. Other property groups overlap. legacy_general_fallback means not eligible for the original solidRect shortcut.",
        .plain_rect_definition = "Solid feature, identity transform, positive size, exactly zero border, radii and clip radii; texture and opacity unrestricted. plain_white_fractional additionally has a white binding and fractional physical rect edges.",
        .counts = .{
            .nodes = output.tree.len,
            .text_runs = draw.run_len,
            .regular_quads = draw.quad_len,
            .generated_glyph_quads = glyph_count,
            .draw_commands = draw.cmd_len,
            .custom_commands_unmeasured = custom_commands,
        },
        .font_atlas = .{ .width = atlas.image.width, .height = atlas.image.height },
        .regular = regular,
        .glyph = glyph,
        .largest_regular_quads = largest[0..largest_len],
    };
    var json_buffer: [64 * 1024]u8 = undefined;
    var json = std.Io.Writer.fixed(&json_buffer);
    try std.json.Stringify.value(report, .{ .whitespace = .indent_2 }, &json);
    try json.writeByte('\n');
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    try stdout.interface.writeAll(json.buffered());
    try stdout.interface.flush();
}
