//! Renderer support is a checked data contract. Exact means the declared model, within its
//! documented raster precision; it does not mean CSS/SVG conformance. A portable preparation
//! decision is explicit: the caller supplies the surfaces and uploads the resulting texture.

const std = @import("std");
const draw = @import("../draw/draw_list.zig");
const types = @import("../core/types.zig");
const tree = @import("../core/tree.zig");
const features = @import("../draw/features.zig");
const geometry = @import("../draw/geometry.zig");
const decoration = @import("../draw/decoration.zig");
const brushes = @import("../draw/brushes.zig");
const prepared = @import("prepared.zig");
const iface = @import("iface.zig");

pub const Feature = enum {
    solid,
    image,
    image_sampling,
    glyphs,
    border,
    circular_corners,
    affine,
    rectangle_clip,
    rounded_clip,
    exact_clip_chain,
    multistop_gradient,
    conic_gradient,
    repeated_image,
    layered_background,
    per_edge_border,
    elliptical_corners,
    shaped_corners,
    outline,
    analytic_box_shadow,
    alpha_shadow,
    isolated_opacity,
    mask,
    blend,
    color_filter,
    convolution,
    backdrop,
    projective_plane,
    depth_scene,
    linear_hdr,
    native_material,
    custom_material,
    inline_custom,
    canvas,
};
pub const Set = std.enums.EnumSet(Feature);
pub const Support = enum { exact, approximation, unsupported };
pub const Route = enum { direct, prepared };
pub const Policy = struct {
    preparation: bool = true,
    approximations: Set = .{},
};
pub const Profile = struct {
    /// The actual stock shader specialization; stripped features are rejected by checkDraw.
    native: features.Usage = .all,
    /// CPU preparation can feed ordinary RGBA8 texture upload on every stock renderer.
    portable: bool = false,
    /// These are separate host capabilities, never inferred from an operating-system name.
    linear_hdr: bool = false,
    native_material: bool = false,
    custom_material: bool = false,
    inline_custom: bool = false,
    depth_scene: bool = false,
    /// The back end draws `canvas` commands (it declares `drawCanvas`: sw); the others draw
    /// nothing for them, and `checkDraw` reports a canvas as `UnsupportedFeature`.
    canvas: bool = false,

    pub const stock: Profile = .{};
    pub const portable_sdr: Profile = .{ .portable = true };
};
pub const Finding = struct { feature: Feature, support: Support, route: Route };
pub const Plan = struct {
    direct: Set = .{},
    prepared: Set = .{},
    approximations: Set = .{},
    /// The first unsatisfied requirement, retaining its identity for an inspector.
    rejected: ?Finding = null,

    pub fn require(value: Plan) Error!void {
        if (value.rejected) |failure| return if (failure.support == .approximation) error.ApproximationRejected else error.UnsupportedFeature;
    }
};
pub const Error = prepared.Error || error{ ApproximationRejected, PreparationRequired, InvalidDrawList };

pub fn support(profile: Profile, feature: Feature) Finding {
    const direct: Support = switch (feature) {
        .solid, .affine, .rectangle_clip, .rounded_clip => .exact,
        .image => if (profile.native.image) .exact else .unsupported,
        .glyphs => if (profile.native.text) .exact else .unsupported,
        .border => if (profile.native.border) .exact else .unsupported,
        .circular_corners => if (profile.native.radius) .exact else .unsupported,
        .analytic_box_shadow => if (profile.native.kinds.contains(.shadow)) .approximation else .unsupported,
        .linear_hdr => if (profile.linear_hdr) .exact else .unsupported,
        .native_material => if (profile.native_material) .exact else .unsupported,
        .custom_material => if (profile.custom_material) .exact else .unsupported,
        .inline_custom => if (profile.inline_custom) .exact else .unsupported,
        .depth_scene => if (profile.depth_scene) .exact else .unsupported,
        .canvas => if (profile.canvas) .exact else .unsupported,
        else => .unsupported,
    };
    if (direct != .unsupported) return .{ .feature = feature, .support = direct, .route = .direct };
    const portable = switch (feature) {
        .linear_hdr, .native_material, .custom_material, .inline_custom, .depth_scene, .canvas => false,
        else => profile.portable,
    };
    return .{ .feature = feature, .support = if (portable) (if (feature == .analytic_box_shadow) .approximation else .exact) else .unsupported, .route = .prepared };
}

/// No mutation. An inspector can show every planned route before the host commits resources.
pub fn plan(requirements: Set, profile: Profile, policy: Policy) Plan {
    var result: Plan = .{};
    for (std.enums.values(Feature)) |feature| {
        if (!requirements.contains(feature)) continue;
        const finding = support(profile, feature);
        const rejected = finding.support == .unsupported or (finding.route == .prepared and !policy.preparation) or
            (finding.support == .approximation and !policy.approximations.contains(feature));
        if (rejected and result.rejected == null) result.rejected = finding;
        if (finding.route == .direct) result.direct.insert(feature) else result.prepared.insert(feature);
        if (finding.support == .approximation) result.approximations.insert(feature);
    }
    return result;
}

fn brushRequirements(set: *Set, brush: brushes.Brush) void {
    switch (brush) {
        .solid => set.insert(.solid),
        .linear, .radial, .two_circle => set.insert(.multistop_gradient),
        .conic, .sweep => set.insert(.conic_gradient),
        .image => |image| {
            set.insert(.image);
            // The portable brush owns its sampler and LOD contract; stock quad sampling is
            // backend-defined and cannot promise the same linear/mipmap result.
            set.insert(.image_sampling);
            if (image.repeat[0] != .none or image.repeat[1] != .none) set.insert(.repeated_image);
        },
    }
}

/// Requirements are derived from data that the actual rasterizer will consume.
pub fn decorationRequirements(shape: decoration.RoundedRect, value: decoration.Description, clips: []const decoration.Clip) Set {
    var result: Set = .{};
    for (shape.radii, shape.corners) |r, corner| {
        if (r[0] != 0 or r[1] != 0) result.insert(if (r[0] == r[1]) .circular_corners else .elliptical_corners);
        if (corner != .round) result.insert(.shaped_corners);
    }
    if (value.backgrounds.len > 1) result.insert(.layered_background);
    for (value.backgrounds) |layer| brushRequirements(&result, layer.brush);
    if (value.border) |border| for (border.edges) |edge| if (edge.width > 0 and edge.style != .none) {
        result.insert(.per_edge_border);
        brushRequirements(&result, edge.brush);
    };
    if (value.outline) |outline| {
        result.insert(.outline);
        brushRequirements(&result, outline.brush);
    }
    if (value.shadows.len != 0) result.insert(.analytic_box_shadow);
    if (clips.len != 0) result.insert(.exact_clip_chain);
    return result;
}

/// Checked preparation. Approximate box shadows require explicit acceptance; true content
/// shadows use compositor.dropShadow/effects.shadow. Missing budgets return before raster.
pub fn bake(shape: decoration.RoundedRect, value: decoration.Description, scale: f32, clips: []const decoration.Clip, quality: decoration.Quality, profile: Profile, policy: Policy, limits: prepared.Limits, storage: []u32, rgba: []u32) Error!prepared.Painted {
    if (!profile.portable or !policy.preparation) return error.PreparationRequired;
    try plan(decorationRequirements(shape, value, clips), profile, policy).require();
    return prepared.bake(shape, value, scale, clips, quality, limits, storage, rgba);
}

fn checkQuad(q: draw.Quad, profile: Profile, policy: Policy) Error!void {
    const kind = std.enums.fromInt(features.Kind, @as(u32, @bitCast(q.params[0]))) orelse return error.UnsupportedFeature;
    if (!profile.native.kinds.contains(kind)) return error.UnsupportedFeature;
    var requested: Set = .initOne(.solid);
    if (q.border != 0) requested.insert(.border);
    if (@reduce(.Or, @as(@Vector(4, f32), q.radii) > @as(@Vector(4, f32), @splat(0)))) requested.insert(.circular_corners);
    if (kind == .shadow) requested.insert(.analytic_box_shadow);
    try plan(requested, profile, policy).require();
}

/// Validate the exact stock specialization and draw resources before a backend sees commands.
/// `t` supplies semantics that the compact GPU quad cannot retain, notably nested/rotated
/// rounded clipping. A prepared route returns PreparationRequired for caller-owned lowering.
pub fn checkDraw(list: *const draw.DrawList, glyphs: iface.Glyphs, t: ?*const tree.Tree, profile: Profile, policy: Policy) Error!void {
    if (t) |value| {
        for (1..value.xlen) |r| {
            const i = value.x.node[r];
            const extra = value.x.row[r];
            if (value.c.clips[i] == 0) continue;
            const rounded = @reduce(.Or, @as(@Vector(4, f32), extra.radii) > @as(@Vector(4, f32), @splat(0)));
            if (!rounded) continue;
            var exact_chain = !std.mem.eql(f32, &extra.world, &geometry.identity);
            var p = i;
            while (p != 0) {
                p = value.c.parent[p];
                exact_chain = exact_chain or value.c.clips[p] != 0;
            }
            if (exact_chain) {
                const decision = plan(.initOne(.exact_clip_chain), profile, policy);
                try decision.require();
                return error.PreparationRequired;
            }
        }
    }
    for (0..list.cmd_len) |i| switch (list.command(@intCast(i))) {
        .quads => |batch| {
            if (batch.first > list.quad_len or batch.count > list.quad_len - batch.first) return error.InvalidDrawList;
            if (batch.material != .solid and !profile.custom_material) return error.UnsupportedMaterial;
            if (batch.texture != .white and !profile.native.image) return error.UnsupportedFeature;
            if (batch.material == .solid) for (list.quads[batch.first..][0..batch.count]) |quad| try checkQuad(quad, profile, policy);
        },
        .text => |run| {
            if (!profile.native.text) return error.UnsupportedFeature;
            if (run >= list.run_len or run >= glyphs.first.len or run >= glyphs.count.len) return error.MissingGlyphs;
            const span = glyphs.span(run);
            if (span[0] > glyphs.quads.len or span[1] > glyphs.quads.len - span[0]) return error.InvalidDrawList;
            for (glyphs.quads[span[0]..][0..span[1]]) |quad| try checkQuad(quad, profile, policy);
        },
        .custom => |index| {
            if (index >= list.custom_len) return error.InvalidDrawList;
            if (!profile.inline_custom) return error.UnsupportedFeature;
        },
        .canvas => |index| {
            if (index >= list.custom_len or index >= list.canvases.len) return error.InvalidDrawList;
            if (!profile.canvas) return error.UnsupportedFeature;
        },
    };
}

/// Normal rendering with validation. Custom interleaving uses checkDraw followed by the
/// public drawUntilCustom loop, so this diagonal rejects inline commands instead of skipping.
pub fn render(backend: anytype, pass: @TypeOf(backend.*).Pass, list: *const draw.DrawList, glyphs: iface.Glyphs, t: ?*const tree.Tree, profile: Profile, policy: Policy) Error!void {
    var plain = profile;
    plain.inline_custom = false;
    try checkDraw(list, glyphs, t, plain, policy);
    iface.render(backend, pass, list);
}

test "capability decisions reject unaccepted approximation before preparing pixels" {
    var premultiplied: [4096]u32 = @splat(0x12345678);
    var upload: [4096]u32 = undefined;
    const shape: decoration.RoundedRect = .{ .rect = .{ .x0 = 10, .y0 = 10, .x1 = 30, .y1 = 30 } };
    const shadows = [_]decoration.Shadow{.{ .sigma = 2, .color = .{ 0, 0, 0, 0.5 } }};
    const description: decoration.Description = .{ .shadows = &shadows };
    try std.testing.expectError(error.ApproximationRejected, bake(shape, description, 1, &.{}, .four, .portable_sdr, .{}, .{}, &premultiplied, &upload));
    try std.testing.expectEqual(@as(u32, 0x12345678), premultiplied[0]);
    const accepted = try bake(shape, description, 1, &.{}, .four, .portable_sdr, .{ .approximations = .initOne(.analytic_box_shadow) }, .{}, &premultiplied, &upload);
    try std.testing.expect(accepted.image.width > 20);
    try std.testing.expectError(error.UnsupportedFeature, plan(.initOne(.depth_scene), .portable_sdr, .{}).require());
    try plan(.initOne(.linear_hdr), .{ .linear_hdr = true }, .{}).require();
}

test "checked rendering rejects stripped shaders before an ordinary backend draw" {
    const mem = @import("../core/mem.zig");
    const software = @import("sw/sw.zig");
    var raw: [8192]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var list = draw.DrawList.init(&carver, 2, 1, 1);
    list.quads[0] = .{ .rect = .{ 0, 0, 8, 8 }, .clip = .{ 0, 0, 8, 8 }, .params = features.linear(.rgb(0, 0, 255), 0), .uv = .{ 0, 0, 1, 1 }, .fill = types.Color.rgb(255, 0, 0).bitsOf(), .border_color = 0, .radii = @splat(0), .border = 0, .opacity = 1, .xform = geometry.identity, .clip_radii = @splat(0) };
    list.quad_len = 1;
    list.cmd_len = 1;
    list.cmd.kind[0] = @backingInt(draw.DrawList.Kind.quads);
    list.cmd.first[0] = 0;
    list.cmd.count[0] = 1;
    list.cmd.key[0] = 0;
    var pixels: [256]u32 = @splat(0);
    var framebuffer = software.Framebuffer.init(&pixels, 8, 8, .rgba8);
    const target: software.Target = .{ .fb = &framebuffer, .scissor = framebuffer.all() };
    var backend: software.SoftwareFor(.all) = .{};
    backend.prepare({}, &list, .{}, .{ 8, 8 }, 1);
    try std.testing.expectError(error.UnsupportedFeature, render(&backend, target, &list, .{}, null, .{ .native = .{} }, .{}));
    try std.testing.expectEqual(@as(u32, 0), pixels[0]);
    try render(&backend, target, &list, .{}, null, .stock, .{});
    try std.testing.expect(pixels[0] != 0);
    try std.testing.expect(pixels[0] != pixels[7]);
}

test "a canvas command is reported where the profile has no canvas" {
    const mem = @import("../core/mem.zig");
    var raw: [8192]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var list = draw.DrawList.init(&carver, 2, 1, 1);
    var rows: [1]draw.CanvasDraw = undefined;
    list.canvases = &rows;
    list.custom_len = 1;
    list.cmd_len = 1;
    list.cmd.kind[0] = @backingInt(draw.DrawList.Kind.canvas);
    list.cmd.first[0] = 0;
    try std.testing.expectError(error.UnsupportedFeature, checkDraw(&list, .{}, null, .stock, .{}));
    try checkDraw(&list, .{}, null, .{ .canvas = true }, .{});
    list.cmd.first[0] = 1;
    try std.testing.expectError(error.InvalidDrawList, checkDraw(&list, .{}, null, .{ .canvas = true }, .{}));
}

test "image brush sampling requests preparation rather than a backend-default sampler" {
    const pixels = [_]u32{0xffffffff};
    const requirements = decorationRequirements(.{ .rect = .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1 } }, .{ .backgrounds = &.{.{ .brush = .{ .image = .{ .image = .{ .pixels = &pixels, .width = 1, .height = 1, .stride = 1 }, .source = .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1 }, .destination = .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1 }, .area = .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1 } } } }} }, &.{});
    try std.testing.expect(requirements.contains(.image_sampling));
    try std.testing.expectError(error.UnsupportedFeature, plan(requirements, .stock, .{}).require());
    const portable = plan(requirements, .portable_sdr, .{});
    try portable.require();
    try std.testing.expect(portable.prepared.contains(.image_sampling));
}
