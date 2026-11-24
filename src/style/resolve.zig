//! Ordered, per-property style resolution. A rule is borrowed data. Matching rules apply in
//! caller order; a later declaration replaces that property only. There is no selector tree,
//! registration step, implicit specificity, or table of every possible state combination.

const std = @import("std");
const types = @import("../core/types.zig");
const a11y = @import("../a11y/tree.zig");
pub const properties = @import("properties.zig");
pub const tokens = @import("tokens.zig");
pub const environment = @import("environment.zig");
pub const Property = properties.Property;
pub const Computed = properties.Computed;
pub const Id = types.Id;

pub const Parts = struct {
    pub const root = Id.from("root");
    pub const background = Id.from("background");
    pub const content = Id.from("content");
    pub const label = Id.from("label");
    pub const icon = Id.from("icon");
    pub const indicator = Id.from("indicator");
    pub const focus = Id.from("focus");
    pub const track = Id.from("track");
    pub const fill = Id.from("fill");
    pub const thumb = Id.from("thumb");
    pub const tick = Id.from("tick");
    pub const selection = Id.from("selection");
    pub const caret = Id.from("caret");
    pub const placeholder = Id.from("placeholder");
    pub const support = Id.from("support");
    pub const separator = Id.from("separator");
    pub const header = Id.from("header");
    pub const row = Id.from("row");
    pub const cell = Id.from("cell");
    pub const disclosure = Id.from("disclosure");
    pub const close = Id.from("close");
};

pub const States = bitpack struct(u64) {
    hovered: bool = false,
    held: bool = false,
    focused: bool = false,
    focus_visible: bool = false,
    focus_within: bool = false,
    disabled: bool = false,
    selected: bool = false,
    checked: bool = false,
    indeterminate: bool = false,
    expanded: bool = false,
    read_only: bool = false,
    invalid: bool = false,
    busy: bool = false,
    dragging: bool = false,
    drop_target: bool = false,
    scrolling: bool = false,
    current: bool = false,
    toggled: bool = false,
    required: bool = false,
    custom: u45 = 0,

    pub fn bits(states: States) u64 {
        return @bitCast(states);
    }

    /// The same semantic state drives behavior, accessibility and visual rules. Style
    /// resolution never changes it. Extra application states are supplied independently.
    pub fn fromResponse(response: types.Response, semantic: a11y.State, visible_focus: bool) States {
        return .{
            .hovered = response.hovered,
            .held = response.held,
            .focused = response.focused,
            .focus_visible = response.focused and visible_focus,
            .disabled = semantic.disabled,
            .selected = semantic.selected,
            .checked = semantic.checked,
            .indeterminate = semantic.mixed,
            .expanded = semantic.expanded,
            .read_only = semantic.read_only,
            .current = semantic.current,
            .toggled = semantic.pressed,
            .invalid = semantic.invalid,
            .required = semantic.required,
            .busy = semantic.busy,
        };
    }

    pub fn merge(a: States, b: States) States {
        return @bitCast(a.bits() | b.bits());
    }
};

/// Absence is represented by no declaration, so explicit zero and transparent are exact.
pub const Source = union(enum) {
    literal: properties.Value,
    inherit,
    initial,
    token: Id,
};
pub const Declaration = struct { property: Property, source: Source };

pub fn set(comptime property: Property, value: properties.Type(property)) Declaration {
    return .{ .property = property, .source = .{ .literal = properties.valueOf(property, value) } };
}
pub fn inherit(property: Property) Declaration {
    return .{ .property = property, .source = .inherit };
}
pub fn initial(property: Property) Declaration {
    return .{ .property = property, .source = .initial };
}
pub fn token(property: Property, id: Id) Declaration {
    return .{ .property = property, .source = .{ .token = id } };
}

/// A typed convenience over `set`. Values can be runtime values; field names are checked
/// while compiling. `patch(.{ .fill = color, .text_size = size })` is ordinary array data.
pub fn patch(fields: anytype) [@typeInfo(@TypeOf(fields)).@"struct".field_names.len]Declaration {
    const names = @typeInfo(@TypeOf(fields)).@"struct".field_names;
    var declarations: [names.len]Declaration = undefined;
    inline for (names, 0..) |name, i| declarations[i] = set(@field(Property, name), @field(fields, name));
    return declarations;
}

pub const Rule = struct {
    /// Anonymous matches every part. Application-defined named parts need no registration.
    part: Id = .none,
    /// Every listed variant must be selected. Orthogonal variants can compose independently.
    variants: []const Id = &.{},
    require: States = .{},
    forbid: States = .{},
    when: environment.Conditions = .{},
    declarations: []const Declaration,
    /// Optional stable identity for an inspector; matching never depends on this name.
    source: Id = .none,

    pub fn matches(rule: Rule, request: *const Request) bool {
        if (rule.part != .none and rule.part != request.part) return false;
        if (request.states.bits() & rule.require.bits() != rule.require.bits() or request.states.bits() & rule.forbid.bits() != 0) return false;
        for (rule.variants) |needed| {
            var found = false;
            for (request.variants) |selected| found = found or needed == selected;
            if (!found) return false;
        }
        return rule.when.matches(request.environment);
    }
};

pub const Request = struct {
    /// Component defaults. Properties marked inherited take the parent's value before rules.
    base: Computed = .{},
    parent: ?*const Computed = null,
    tokens: tokens.Table = .{},
    scope: u32 = types.none,
    part: Id = Parts.root,
    variants: []const Id = &.{},
    states: States = .{},
    environment: environment.Environment = .{},
    rules: []const Rule = &.{},
    /// Last layer, for one caller's local overrides. Empty means no local declarations.
    local: []const Declaration = &.{},
};

pub const Origin = struct {
    mode: enum { base, inherited, initial, literal, token } = .base,
    source: Id = .none,
    rule: u32 = types.none,
    declaration: u32 = types.none,
    /// The originally requested token, not its final color or alias target.
    token: Id = .none,
    token_scope: u32 = types.none,
    token_entry: u32 = types.none,
};
pub const Error = properties.Error || tokens.Error || error{NoSpace};

/// Returns existing public authoring values. `trace`, when supplied, needs `properties.count`
/// rows. A failed resolution returns no result; trace contents are unspecified on failure.
/// No registration, heap allocation, retained output, or hidden frame sequencing occurs.
pub fn resolve(request: Request, trace: ?[]Origin) Error!Computed {
    if (trace) |rows| {
        if (rows.len < properties.count) return error.NoSpace;
        @memset(rows[0..properties.count], .{});
    }
    var computed = request.base;
    if (request.parent) |parent| {
        inline for (@typeInfo(Property).@"enum".field_names) |name| {
            const property = @field(Property, name);
            if (comptime properties.metadata(property).inherits) {
                properties.write(property, &computed, properties.read(property, parent));
                if (trace) |rows| rows[@backingInt(property)] = .{ .mode = .inherited };
            }
        }
    }
    for (request.rules, 0..) |rule, i| {
        if (rule.matches(&request)) try apply(&computed, &request, rule.declarations, rule.source, @intCast(i), trace);
    }
    try apply(&computed, &request, request.local, .from("local"), types.none, trace);
    return computed;
}

fn apply(computed: *Computed, request: *const Request, declarations: []const Declaration, source: Id, rule: u32, trace: ?[]Origin) Error!void {
    for (declarations, 0..) |declaration, i| {
        var origin: Origin = .{ .source = source, .rule = rule, .declaration = @intCast(i) };
        const value: properties.Value = switch (declaration.source) {
            .literal => |literal_value| blk: {
                origin.mode = .literal;
                break :blk literal_value;
            },
            .inherit => blk: {
                origin.mode = .inherited;
                break :blk properties.get(declaration.property, request.parent orelse &.{});
            },
            .initial => blk: {
                origin.mode = .initial;
                break :blk properties.initial(declaration.property);
            },
            .token => |id| blk: {
                const found = try request.tokens.find(request.scope, id);
                origin.mode = .token;
                origin.token = id;
                origin.token_scope = found.scope;
                origin.token_entry = found.entry;
                break :blk found.value;
            },
        };
        try properties.put(declaration.property, computed, value);
        if (trace) |rows| rows[@backingInt(declaration.property)] = origin;
    }
}

pub const Inspection = struct {
    property: Property,
    value: properties.Value,
    metadata: properties.Metadata,
    origin: Origin,
};

/// Inspector data is independently readable; applications choose how to display it.
pub fn inspect(computed: *const Computed, trace: []const Origin, property: Property) Error!Inspection {
    if (trace.len < properties.count) return error.NoSpace;
    return .{ .property = property, .value = properties.get(property, computed), .metadata = properties.metadata(property), .origin = trace[@backingInt(property)] };
}

test "caller usage: same-value semantic tokens separate on a theme change, literals stay literal" {
    const accent = Id.from("accent");
    const danger = Id.from("danger");
    var entries = [_]tokens.Entry{ tokens.literal(.fill, accent, .white), tokens.literal(.fill, danger, .white) };
    const scope = [_]tokens.Scope{.{ .entries = &entries }};
    const table: tokens.Table = .{ .scopes = &scope };
    const rules = [_]Rule{
        .{ .part = Parts.root, .declarations = &.{token(.fill, accent)} },
        .{ .part = Parts.indicator, .declarations = &.{token(.fill, danger)} },
        .{ .part = Parts.icon, .declarations = &.{set(.fill, .white)} },
    };
    var request: Request = .{ .rules = &rules, .tokens = table, .scope = 0 };
    try std.testing.expectEqual(types.Color.white, (try resolve(request, null)).box.fill);
    entries[0] = tokens.literal(.fill, accent, .black);
    entries[1] = tokens.literal(.fill, danger, .rgb(220, 10, 10));
    try std.testing.expectEqual(types.Color.black, (try resolve(request, null)).box.fill);
    request.part = Parts.indicator;
    try std.testing.expectEqual(types.Color.rgb(220, 10, 10), (try resolve(request, null)).box.fill);
    request.part = Parts.icon;
    try std.testing.expectEqual(types.Color.white, (try resolve(request, null)).box.fill);
}

test "caller usage: simultaneous states, orthogonal variants and local transparent overrides" {
    const rules = [_]Rule{
        .{ .declarations = &patch(.{ .fill = types.Color.black, .radius = @as(f32, 4) }) },
        .{ .require = .{ .selected = true }, .declarations = &.{set(.border_width, 2)} },
        .{ .require = .{ .hovered = true }, .forbid = .{ .disabled = true }, .declarations = &.{set(.fill, .white)} },
        .{ .require = .{ .focus_visible = true }, .declarations = &.{set(.border_color, .rgb(10, 20, 230))}, .source = .from("keyboard-focus") },
        .{ .variants = &.{.from("small")}, .declarations = &.{set(.text_size, 12)} },
        .{ .variants = &.{.from("destructive")}, .declarations = &.{set(.text_color, .rgb(220, 0, 0))} },
    };
    var trace: [properties.count]Origin = undefined;
    const computed = try resolve(.{
        .rules = &rules,
        .states = .{ .selected = true, .hovered = true, .focus_visible = true },
        .variants = &.{ .from("small"), .from("destructive") },
        .local = &.{set(.fill, .transparent)},
    }, &trace);
    try std.testing.expectEqual(types.Color.transparent, computed.box.fill);
    try std.testing.expectEqual(@as(f32, 2), computed.box.border);
    try std.testing.expectEqual(types.Color.rgb(10, 20, 230), computed.box.border_color);
    try std.testing.expectEqual(@as(f32, 12), computed.text.px);
    try std.testing.expectEqual(types.Color.rgb(220, 0, 0), computed.text.color);
    try std.testing.expectEqual(Id.from("keyboard-focus"), (try inspect(&computed, &trace, .border_color)).origin.source);
    try std.testing.expectEqual(Id.from("local"), trace[@backingInt(Property.fill)].source);
}

test "explicit inheritance, initial, zero and transparent remain distinct, also at comptime" {
    const parent: Computed = comptime .{ .box = .{ .fill = .black, .gap = 7 }, .text = .{ .color = .black, .px = 30 } };
    const request: Request = comptime .{
        .parent = &parent,
        .local = &.{ inherit(.fill), initial(.text_size), set(.text_color, .transparent), set(.gap, 0) },
    };
    const folded = comptime resolve(request, null) catch unreachable;
    const runtime = try resolve(request, null);
    try std.testing.expectEqualDeep(folded, runtime);
    try std.testing.expectEqual(types.Color.black, runtime.box.fill);
    try std.testing.expectEqual(types.Color.transparent, runtime.text.color);
    try std.testing.expectEqual(@as(f32, 14), runtime.text.px);
    try std.testing.expectEqual(@as(f32, 0), runtime.box.gap);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(States);
    std.testing.refAllDecls(Rule);
}
