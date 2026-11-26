//! Sparse style authoring values. This catalog describes properties with an existing consumer:
//! `Computed.box` goes to Tree/Frame and `Computed.text` to Texts/Frame.textStyled.
//! It adds no fields to tree rows and requires neither registration nor allocation.

const std = @import("std");
const types = @import("../core/types.zig");

pub const Property = enum(u8) {
    fill,
    border_color,
    border_width,
    radius,
    radii,
    opacity,
    transform,
    transform_origin,
    texture,
    material,
    params,
    uv,
    direction,
    width,
    height,
    min_width,
    min_height,
    max_width,
    max_height,
    padding_left,
    padding_top,
    padding_right,
    padding_bottom,
    gap,
    main_align,
    cross_align,
    shrink,
    floating,
    offset,
    clip,
    scroll,
    text_color,
    text_size,
    text_font,
    text_wrap,
    participation,
    cursor,
    /// How far the node paints past its rect, left, top, right, bottom (a shadow's offset and
    /// spread).
    paint_outset,
    margin_left,
    margin_top,
    margin_right,
    margin_bottom,
};

pub const count = @typeInfo(Property).@"enum".field_names.len;

pub const Kind = enum { color, number, vector4, matrix, texture, material, axis, size, alignment, boolean, vector2, font, participation, cursor };

pub const Value = union(Kind) {
    color: types.Color,
    number: f32,
    vector4: [4]f32,
    matrix: [6]f32,
    texture: types.Texture,
    material: types.Material,
    axis: types.Axis,
    size: types.Size,
    alignment: types.Align,
    boolean: bool,
    vector2: [2]f32,
    font: types.Font,
    participation: types.Participation,
    cursor: ?types.Cursor,
};

/// A transient pair of existing authoring values, not a per-node retained record. Callers can
/// pass either member directly to existing APIs and can keep only the member they need.
pub const Computed = struct {
    box: types.Style = .{},
    text: types.TextStyle = .{},
    /// Left, top, right, bottom: space kept outside the node, which the flex table carries
    /// (`flex.Flex.Style.margin`); a recipe box with margin rules writes it each frame.
    margin: [4]f32 = @splat(0),
};

pub const Invalidation = bitpack struct(u8) {
    paint: bool = false,
    measure: bool = false,
    layout: bool = false,
    hit: bool = false,
    semantics: bool = false,
    descendants: bool = false,
    platform: bool = false,
    _: u1 = 0,

    pub fn merge(a: Invalidation, b: Invalidation) Invalidation {
        return @bitCast(@as(u8, @bitCast(a)) | @as(u8, @bitCast(b)));
    }
};

const paint: Invalidation = .{ .paint = true };
const geometry: Invalidation = .{ .paint = true, .layout = true, .hit = true, .semantics = true };
const text_domains: Invalidation = .{ .paint = true, .measure = true, .layout = true, .hit = true, .semantics = true };

pub const Interpolation = enum { discrete, number, color, components, compatible_size };
pub const Metadata = struct {
    kind: Kind,
    inherits: bool,
    interpolation: Interpolation,
    invalidates: Invalidation,
};

pub fn kind(property: Property) Kind {
    return switch (property) {
        .fill, .border_color, .text_color => .color,
        .border_width, .radius, .opacity, .min_width, .min_height, .max_width, .max_height, .padding_left, .padding_top, .padding_right, .padding_bottom, .gap, .text_size, .margin_left, .margin_top, .margin_right, .margin_bottom => .number,
        .radii, .params, .uv, .paint_outset => .vector4,
        .transform => .matrix,
        .texture => .texture,
        .material => .material,
        .direction => .axis,
        .width, .height => .size,
        .main_align, .cross_align => .alignment,
        .shrink, .floating, .clip, .text_wrap => .boolean,
        .offset, .scroll, .transform_origin => .vector2,
        .text_font => .font,
        .participation => .participation,
        .cursor => .cursor,
    };
}

pub fn Type(comptime property: Property) type {
    return switch (kind(property)) {
        .color => types.Color,
        .number => f32,
        .vector4 => [4]f32,
        .matrix => [6]f32,
        .texture => types.Texture,
        .material => types.Material,
        .axis => types.Axis,
        .size => types.Size,
        .alignment => types.Align,
        .boolean => bool,
        .vector2 => [2]f32,
        .font => types.Font,
        .participation => types.Participation,
        .cursor => ?types.Cursor,
    };
}

pub fn metadata(property: Property) Metadata {
    const value_kind = kind(property);
    var domains: Invalidation = switch (property) {
        .fill, .border_color, .opacity, .texture, .material, .params, .uv, .text_color, .paint_outset => paint,
        .border_width, .radius, .radii, .transform, .transform_origin, .direction, .width, .height, .min_width, .min_height, .max_width, .max_height, .padding_left, .padding_top, .padding_right, .padding_bottom, .gap, .main_align, .cross_align, .shrink, .floating, .offset, .clip, .scroll, .participation => geometry,
        .text_size, .text_font, .text_wrap => text_domains,
        .margin_left, .margin_top, .margin_right, .margin_bottom => geometry,
        .cursor => .{ .platform = true },
    };
    domains.descendants = switch (property) {
        .border_width, .radius, .radii, .opacity, .transform, .transform_origin, .direction, .width, .height, .min_width, .min_height, .max_width, .max_height, .padding_left, .padding_top, .padding_right, .padding_bottom, .gap, .main_align, .cross_align, .shrink, .floating, .offset, .clip, .scroll, .text_color, .text_size, .text_font, .participation, .cursor => true,
        else => false,
    };
    return .{
        .kind = value_kind,
        .inherits = switch (property) {
            .text_color, .text_size, .text_font, .cursor => true,
            else => false,
        },
        .interpolation = switch (value_kind) {
            .number => .number,
            .color => .color,
            .vector2, .vector4, .matrix => .components,
            .size => .compatible_size,
            else => .discrete,
        },
        .invalidates = domains,
    };
}

pub fn read(comptime property: Property, computed: *const Computed) Type(property) {
    return switch (property) {
        .fill => computed.box.fill,
        .border_color => computed.box.border_color,
        .border_width => computed.box.border,
        .radius => computed.box.radius,
        .radii => computed.box.radii,
        .opacity => computed.box.opacity,
        .transform => computed.box.transform,
        .transform_origin => computed.box.transform_origin,
        .texture => computed.box.texture,
        .material => computed.box.material,
        .params => computed.box.params,
        .uv => computed.box.uv,
        .direction => computed.box.dir,
        .width => computed.box.size[0],
        .height => computed.box.size[1],
        .min_width => computed.box.min[0],
        .min_height => computed.box.min[1],
        .max_width => computed.box.max[0],
        .max_height => computed.box.max[1],
        .padding_left => computed.box.pad[0],
        .padding_top => computed.box.pad[1],
        .padding_right => computed.box.pad[2],
        .padding_bottom => computed.box.pad[3],
        .gap => computed.box.gap,
        .main_align => computed.box.main,
        .cross_align => computed.box.cross,
        .shrink => computed.box.shrink,
        .floating => computed.box.float,
        .offset => computed.box.offset,
        .clip => computed.box.clip,
        .scroll => computed.box.scroll,
        .text_color => computed.text.color,
        .text_size => computed.text.px,
        .text_font => computed.text.font,
        .text_wrap => computed.text.wrap,
        .participation => computed.box.participation,
        .cursor => computed.box.cursor,
        .paint_outset => computed.box.paint_outset,
        .margin_left => computed.margin[0],
        .margin_top => computed.margin[1],
        .margin_right => computed.margin[2],
        .margin_bottom => computed.margin[3],
    };
}

pub fn write(comptime property: Property, computed: *Computed, value: Type(property)) void {
    switch (property) {
        .fill => computed.box.fill = value,
        .border_color => computed.box.border_color = value,
        .border_width => computed.box.border = value,
        .radius => computed.box.radius = value,
        .radii => computed.box.radii = value,
        .opacity => computed.box.opacity = value,
        .transform => computed.box.transform = value,
        .transform_origin => computed.box.transform_origin = value,
        .texture => computed.box.texture = value,
        .material => computed.box.material = value,
        .params => computed.box.params = value,
        .uv => computed.box.uv = value,
        .direction => computed.box.dir = value,
        .width => computed.box.size[0] = value,
        .height => computed.box.size[1] = value,
        .min_width => computed.box.min[0] = value,
        .min_height => computed.box.min[1] = value,
        .max_width => computed.box.max[0] = value,
        .max_height => computed.box.max[1] = value,
        .padding_left => computed.box.pad[0] = value,
        .padding_top => computed.box.pad[1] = value,
        .padding_right => computed.box.pad[2] = value,
        .padding_bottom => computed.box.pad[3] = value,
        .gap => computed.box.gap = value,
        .main_align => computed.box.main = value,
        .cross_align => computed.box.cross = value,
        .shrink => computed.box.shrink = value,
        .floating => computed.box.float = value,
        .offset => computed.box.offset = value,
        .clip => computed.box.clip = value,
        .scroll => computed.box.scroll = value,
        .text_color => computed.text.color = value,
        .text_size => computed.text.px = value,
        .text_font => computed.text.font = value,
        .text_wrap => computed.text.wrap = value,
        .participation => computed.box.participation = value,
        .cursor => computed.box.cursor = value,
        .paint_outset => computed.box.paint_outset = value,
        .margin_left => computed.margin[0] = value,
        .margin_top => computed.margin[1] = value,
        .margin_right => computed.margin[2] = value,
        .margin_bottom => computed.margin[3] = value,
    }
}

pub fn valueOf(comptime property: Property, value: Type(property)) Value {
    return @unionInit(Value, @tagName(kind(property)), value);
}

pub fn get(property: Property, computed: *const Computed) Value {
    return switch (property) {
        inline else => |tag| valueOf(tag, read(tag, computed)),
    };
}

pub const Error = error{ WrongType, InvalidValue };

/// Dynamic importers get the same validation as typed callers. Invalid input is rejected,
/// never silently clamped; infinity is accepted only for unbounded max width/height.
pub fn validate(property: Property, value: Value) Error!void {
    if (std.meta.activeTag(value) != kind(property)) return error.WrongType;
    switch (value) {
        .number => |n| {
            const unbounded = property == .max_width or property == .max_height;
            if (std.math.isNan(n) or (!unbounded and !std.math.isFinite(n)) or n < 0) return error.InvalidValue;
            if (property == .opacity and n > 1) return error.InvalidValue;
        },
        .size => |v| {
            if (!std.math.isFinite(v.v) or v.v < 0) return error.InvalidValue;
        },
        .vector2 => |v| for (v) |n| {
            if (!std.math.isFinite(n)) return error.InvalidValue;
        },
        .vector4 => |v| for (v) |n| {
            if (!std.math.isFinite(n)) return error.InvalidValue;
        },
        .matrix => |v| for (v) |n| {
            if (!std.math.isFinite(n)) return error.InvalidValue;
        },
        else => {},
    }
}

pub fn put(property: Property, computed: *Computed, value: Value) Error!void {
    try validate(property, value);
    switch (property) {
        inline else => |tag| write(tag, computed, @field(value, @tagName(kind(tag)))),
    }
}

pub fn initial(property: Property) Value {
    return get(property, &.{});
}

/// The caller decides which work to run. This compares catalog properties; behavior-owned
/// role/value and internal decoration references are intentionally not style declarations.
pub fn changed(before: *const Computed, after: *const Computed) Invalidation {
    var domains: Invalidation = .{};
    inline for (@typeInfo(Property).@"enum".field_names) |name| {
        const property = @field(Property, name);
        if (!std.meta.eql(read(property, before), read(property, after))) domains = domains.merge(metadata(property).invalidates);
    }
    return domains;
}

/// Interpolation of existing value types. Different sizing modes and resource handles switch
/// at the midpoint. Colors use premultiplied sRGB, avoiding transparent-color fringes.
/// Matrix interpolation is component-wise, not rotation decomposition.
pub fn interpolate(property: Property, a: Value, b: Value, fraction: f32) Error!Value {
    try validate(property, a);
    try validate(property, b);
    if (!std.math.isFinite(fraction)) return error.InvalidValue;
    const t = std.math.clamp(fraction, 0, 1);
    if (t == 0) return a;
    if (t == 1) return b;
    return switch (a) {
        .number => |v| .{ .number = if (std.math.isFinite(v) and std.math.isFinite(b.number)) v + (b.number - v) * t else if (t < 0.5) v else b.number },
        .color => |v| blk: {
            const color_math = @import("../draw/color_math.zig");
            const mixed = color_math.mix(color_math.fromColor(v), color_math.fromColor(b.color), t, .{});
            break :blk .{ .color = @bitCast(color_math.pack(mixed)) };
        },
        .vector2 => |v| .{ .vector2 = mixArray(2, v, b.vector2, t) },
        .vector4 => |v| .{ .vector4 = mixArray(4, v, b.vector4, t) },
        .matrix => |v| .{ .matrix = mixArray(6, v, b.matrix, t) },
        .size => |v| .{ .size = if (v.kind == b.size.kind) .{ .kind = v.kind, .v = v.v + (b.size.v - v.v) * t } else if (t < 0.5) v else b.size },
        else => if (t < 0.5) a else b,
    };
}

fn mixArray(comptime n: usize, a: [n]f32, b: [n]f32, t: f32) [n]f32 {
    return @as(@Vector(n, f32), a) + (@as(@Vector(n, f32), b) - @as(@Vector(n, f32), a)) * @as(@Vector(n, f32), @splat(t));
}

test "direct typed values reach existing box and text consumers; transparent and zero are values" {
    var computed: Computed = .{};
    try put(.fill, &computed, valueOf(.fill, .transparent));
    try put(.padding_left, &computed, valueOf(.padding_left, 0));
    try put(.text_size, &computed, valueOf(.text_size, 21));
    try put(.width, &computed, valueOf(.width, .px(90)));
    try std.testing.expectEqual(types.Color.transparent, computed.box.fill);
    try std.testing.expectEqual(@as(f32, 0), computed.box.pad[0]);
    try std.testing.expectEqual(@as(f32, 21), computed.text.px);
    try std.testing.expectEqual(types.Size.px(90), computed.box.size[0]);
    try std.testing.expectError(error.WrongType, put(.fill, &computed, .{ .number = 2 }));
    try std.testing.expectError(error.InvalidValue, put(.opacity, &computed, .{ .number = 2 }));
}

test "paint-only changes do not request shaping or layout; text metrics do" {
    const before: Computed = .{};
    var after = before;
    after.text.color = .black;
    try std.testing.expectEqual(Invalidation{ .paint = true, .descendants = true }, changed(&before, &after));
    after.text.px = 20;
    try std.testing.expect(changed(&before, &after).measure);
    try std.testing.expect(changed(&before, &after).layout);
    try std.testing.expectEqual(Value{ .number = 5 }, try interpolate(.border_width, .{ .number = 2 }, .{ .number = 8 }, 0.5));
}

test {
    std.testing.refAllDecls(@This());
}
