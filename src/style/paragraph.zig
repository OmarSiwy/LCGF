//! Optional paragraph authoring lowers directly to text.layout.Stack.Paragraph. It stays
//! separate from ordinary node records and TextStyle, so callers using simple labels do not
//! acquire paragraph storage, normalization buffers or a text-shaping dependency at runtime.

const std = @import("std");
const types = @import("../core/types.zig");
const tokens = @import("tokens.zig");
const properties = @import("properties.zig");
const resolution = @import("resolve.zig");
const stack = @import("../text/layout/stack.zig");
pub const Paragraph = stack.Paragraph;
pub const Property = std.meta.FieldEnum(Paragraph);
pub const count = @typeInfo(Paragraph).@"struct".field_names.len;
const fields = @typeInfo(Paragraph).@"struct";
pub const Value = @Union(.auto, Property, fields.field_names, fields.field_types, &@splat(.{}));

pub fn Type(comptime property: Property) type {
    return @FieldType(Paragraph, @tagName(property));
}

pub const Metadata = struct { inherits: bool, invalidates: properties.Invalidation };
pub fn metadata(property: Property) Metadata {
    return .{
        .inherits = property != .max_lines and property != .ellipsis,
        .invalidates = .{
            .paint = true,
            .measure = property != .alignment and property != .last_align,
            .layout = true,
            .hit = true,
            .semantics = true,
            .descendants = property != .max_lines and property != .ellipsis,
        },
    };
}

pub const Source = union(enum) { literal: Value, inherit, initial, number_token: types.Id };
pub const Declaration = struct { property: Property, source: Source };
pub const Inputs = struct { parent: ?*const Paragraph = null, tokens: tokens.Table = .{}, scope: u32 = types.none };
pub const Error = tokens.Error || error{ WrongType, InvalidValue, NoSpace };

pub fn set(comptime property: Property, value: Type(property)) Declaration {
    return .{ .property = property, .source = .{ .literal = @unionInit(Value, @tagName(property), value) } };
}
pub fn inherit(property: Property) Declaration {
    return .{ .property = property, .source = .inherit };
}
pub fn initial(property: Property) Declaration {
    return .{ .property = property, .source = .initial };
}

/// Numeric design tokens drive spacing, tab stops, leading and line height. A line-height
/// token is interpreted in logical pixels; the typed literal supports font or multipliers.
pub fn token(comptime property: Property, id: types.Id) Declaration {
    switch (property) {
        .tab_size, .tab_width, .letter_spacing, .word_spacing, .leading, .line_height => {},
        else => @compileError("this paragraph property requires a typed literal, not a numeric token"),
    }
    return .{ .property = property, .source = .{ .number_token = id } };
}

pub fn patch(values: anytype) [@typeInfo(@TypeOf(values)).@"struct".field_names.len]Declaration {
    const names = @typeInfo(@TypeOf(values)).@"struct".field_names;
    var declarations: [names.len]Declaration = undefined;
    inline for (names, 0..) |name, i| declarations[i] = set(@field(Property, name), @field(values, name));
    return declarations;
}

pub fn get(property: Property, paragraph: *const Paragraph) Value {
    return switch (property) {
        inline else => |tag| @unionInit(Value, @tagName(tag), @field(paragraph, @tagName(tag))),
    };
}

pub fn validate(property: Property, value: Value) Error!void {
    if (std.meta.activeTag(value) != property) return error.WrongType;
    switch (value) {
        .tab_size => |n| if (!std.math.isFinite(n) or n <= 0) {
            return error.InvalidValue;
        },
        .tab_width => |optional| if (optional) |n| {
            if (!std.math.isFinite(n) or n <= 0) return error.InvalidValue;
        },
        .letter_spacing, .word_spacing => |n| if (!std.math.isFinite(n)) {
            return error.InvalidValue;
        },
        .leading => |n| if (!std.math.isFinite(n) or n < 0 or n > 1) {
            return error.InvalidValue;
        },
        .max_lines => |n| if (n == 0) {
            return error.InvalidValue;
        },
        .line_height => |height| switch (height) {
            .font => {},
            .px, .multiple => |n| if (!std.math.isFinite(n) or n < 0) {
                return error.InvalidValue;
            },
        },
        else => {},
    }
}

fn numeric(property: Property, value: properties.Value) Error!Value {
    const number = if (value == .number) value.number else return error.WrongType;
    return switch (property) {
        .tab_size => .{ .tab_size = number },
        .tab_width => .{ .tab_width = number },
        .letter_spacing => .{ .letter_spacing = number },
        .word_spacing => .{ .word_spacing = number },
        .leading => .{ .leading = number },
        .line_height => .{ .line_height = .{ .px = number } },
        else => error.WrongType,
    };
}

/// Produce a paragraph row for Stack.paragraphs or default_paragraph. Like node resolution,
/// omitted inherited fields follow the supplied parent; explicit null/zero remain literals.
/// Trace requires count rows and is unspecified on failure.
pub fn resolve(base: Paragraph, declarations: []const Declaration, inputs: Inputs, trace: ?[]resolution.Origin) Error!Paragraph {
    if (trace) |rows| {
        if (rows.len < count) return error.NoSpace;
        @memset(rows[0..count], .{});
    }
    var out = base;
    if (inputs.parent) |parent| {
        inline for (fields.field_names) |name| {
            const property = @field(Property, name);
            if (comptime metadata(property).inherits) {
                @field(out, name) = @field(parent, name);
                if (trace) |rows| rows[@backingInt(property)] = .{ .mode = .inherited };
            }
        }
    }
    for (declarations, 0..) |declaration, i| {
        var origin: resolution.Origin = .{ .source = .from("paragraph"), .declaration = @intCast(i) };
        const value: Value = switch (declaration.source) {
            .literal => |literal| blk: {
                origin.mode = .literal;
                break :blk literal;
            },
            .inherit => blk: {
                origin.mode = .inherited;
                break :blk get(declaration.property, inputs.parent orelse &.{});
            },
            .initial => blk: {
                origin.mode = .initial;
                break :blk get(declaration.property, &.{});
            },
            .number_token => |id| blk: {
                const found = try inputs.tokens.find(inputs.scope, id);
                origin.mode = .token;
                origin.token = id;
                origin.token_scope = found.scope;
                origin.token_entry = found.entry;
                break :blk try numeric(declaration.property, found.value);
            },
        };
        try validate(declaration.property, value);
        switch (declaration.property) {
            inline else => |property| @field(out, @tagName(property)) = @field(value, @tagName(property)),
        }
        if (trace) |rows| rows[@backingInt(declaration.property)] = origin;
    }
    return out;
}

pub fn changed(before: *const Paragraph, after: *const Paragraph) properties.Invalidation {
    var invalidation: properties.Invalidation = .{};
    inline for (fields.field_names) |name| {
        if (!std.meta.eql(@field(before, name), @field(after, name))) invalidation = invalidation.merge(metadata(@field(Property, name)).invalidates);
    }
    return invalidation;
}

test "caller usage: resolved paragraph tokens drive the real shaping and multiline layout path" {
    const mem = @import("../core/mem.zig");
    const Texts = @import("../core/texts.zig").Texts;
    const Strings = @import("../core/strings.zig").Strings;
    const shape = @import("../text/shape/shape.zig");
    const golden = @import("../text/layout/golden.zig");
    const shapers = [_]shape.Shaper{.init(try @import("../text/font/opentype.zig").Face.parse(golden.font, 0))};
    const entries = [_]tokens.Entry{tokens.literal(.gap, .from("line.height"), 30)};
    const scopes = [_]tokens.Scope{.{ .entries = &entries }};
    const options = try resolve(.{}, &.{
        token(.line_height, .from("line.height")), set(.max_lines, 2), set(.ellipsis, true), set(.alignment, .center), set(.wrap, .word),
    }, .{ .tokens = .{ .scopes = &scopes }, .scope = 0 }, null);
    var buffer: [4096]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &buffer };
    var texts = Texts.init(&carver, 1);
    var bytes: [64]u8 = undefined;
    var strings: Strings = .{ .buf = &bytes };
    _ = texts.push(0, strings.add("one two three four five"), &.{ .px = 20, .wrap = true });
    var paragraph: golden.Para = .{};
    paragraph.bind();
    var run: golden.RunCols = .{};
    var text_stack: stack.Stack = .{ .shapers = &shapers, .run = run.run(), .g = paragraph.g, .l = paragraph.l, .default_paragraph = options };
    var ascent: [1]f32 = undefined;
    text_stack.measure(&texts, &strings, &ascent);
    texts.c.avail[0] = 70;
    text_stack.wrap(&texts, &strings, &ascent);
    try std.testing.expectEqual(@as(f32, 60), texts.c.h[0]);
    try std.testing.expect(text_stack.l.ellipsis > 0);
    try std.testing.expect(!text_stack.overflow);
}

test "paragraph presence and invalidation distinguish inherited, initial, null and zero" {
    const parent: Paragraph = .{ .letter_spacing = 2, .tab_width = 40, .line_height = .{ .multiple = 2 } };
    const out = try resolve(.{}, &.{ set(.letter_spacing, 0), set(.tab_width, null), initial(.line_height) }, .{ .parent = &parent }, null);
    try std.testing.expectEqual(@as(f32, 0), out.letter_spacing);
    try std.testing.expectEqual(@as(?f32, null), out.tab_width);
    try std.testing.expectEqual(Paragraph.LineHeight.font, out.line_height);
    const positioned = try resolve(out, &.{set(.alignment, .right)}, .{}, null);
    try std.testing.expect(!changed(&out, &positioned).measure);
    try std.testing.expect(changed(&out, &positioned).layout);
    try std.testing.expectError(error.InvalidValue, resolve(.{}, &.{set(.max_lines, 0)}, .{}, null));
}

test {
    std.testing.refAllDecls(@This());
}
