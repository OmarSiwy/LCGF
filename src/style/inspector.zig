//! Computed-style inspection as caller-owned data. Matching, overridden declarations and
//! winning token provenance are exposed without a retained inspector, UI overlay or registry.
//! The same snapshot may be shown in an application panel, serialized by a host, or tested.

const std = @import("std");
const types = @import("../core/types.zig");
const resolution = @import("resolve.zig");
const properties = @import("properties.zig");

pub const Match = struct {
    part: bool,
    variants: bool,
    required_states: bool,
    forbidden_states: bool,
    environment: bool,

    pub fn matches(value: Match) bool {
        return value.part and value.variants and value.required_states and value.forbidden_states and value.environment;
    }
};
pub const Rule = struct { index: u32, source: types.Id, match: Match };
pub const Disposition = enum { inactive, overridden, winning };
pub const Declaration = struct {
    /// `none` identifies the request's local declarations.
    rule: u32,
    index: u32,
    declaration: resolution.Declaration,
    disposition: Disposition,
};
pub const Buffers = struct {
    properties: []resolution.Inspection,
    rules: []Rule,
    declarations: []Declaration,
};
pub const Snapshot = struct {
    computed: properties.Computed,
    part: types.Id,
    states: resolution.States,
    properties: []const resolution.Inspection,
    rules: []const Rule,
    declarations: []const Declaration,
};

pub fn match(rule: resolution.Rule, request: *const resolution.Request) Match {
    var variants = true;
    for (rule.variants) |needed| {
        var found = false;
        for (request.variants) |selected| found = found or needed == selected;
        variants = variants and found;
    }
    return .{
        .part = rule.part == .none or rule.part == request.part,
        .variants = variants,
        .required_states = request.states.bits() & rule.require.bits() == rule.require.bits(),
        .forbidden_states = request.states.bits() & rule.forbid.bits() == 0,
        .environment = rule.when.matches(request.environment),
    };
}

/// Includes all declared rules, including unmatched ones. Their declarations are not resolved:
/// a missing token in an inactive rule remains inactive, as in normal style resolution.
pub fn snapshot(request: resolution.Request, buffers: Buffers) resolution.Error!Snapshot {
    var declaration_count = request.local.len;
    for (request.rules) |rule| declaration_count = std.math.add(usize, declaration_count, rule.declarations.len) catch return error.NoSpace;
    if (buffers.properties.len < properties.count or buffers.rules.len < request.rules.len or buffers.declarations.len < declaration_count) return error.NoSpace;
    var origins: [properties.count]resolution.Origin = undefined;
    const computed = try resolution.resolve(request, &origins);
    for (0..properties.count) |i| buffers.properties[i] = try resolution.inspect(&computed, &origins, @fromBackingInt(@as(u8, @intCast(i))));
    var at: usize = 0;
    for (request.rules, 0..) |rule, i| {
        const matched = match(rule, &request);
        buffers.rules[i] = .{ .index = @intCast(i), .source = rule.source, .match = matched };
        for (rule.declarations, 0..) |declaration, j| {
            const origin = origins[@backingInt(declaration.property)];
            buffers.declarations[at] = .{
                .rule = @intCast(i),
                .index = @intCast(j),
                .declaration = declaration,
                .disposition = if (!matched.matches()) .inactive else if (origin.rule == i and origin.declaration == j) .winning else .overridden,
            };
            at += 1;
        }
    }
    for (request.local, 0..) |declaration, j| {
        const origin = origins[@backingInt(declaration.property)];
        buffers.declarations[at] = .{
            .rule = types.none,
            .index = @intCast(j),
            .declaration = declaration,
            .disposition = if (origin.rule == types.none and origin.source == types.Id.from("local") and origin.declaration == j) .winning else .overridden,
        };
        at += 1;
    }
    return .{ .computed = computed, .part = request.part, .states = request.states, .properties = buffers.properties[0..properties.count], .rules = buffers.rules[0..request.rules.len], .declarations = buffers.declarations[0..at] };
}

pub const Difference = struct { property: properties.Property, before: properties.Value, after: properties.Value, invalidates: properties.Invalidation };

/// Data for a hot-reload preview: which concrete values changed and which existing passes
/// they invalidate. The caller chooses when to replace its data and rerun those passes.
pub fn differences(before: *const properties.Computed, after: *const properties.Computed, out: []Difference) error{NoSpace}![]const Difference {
    var count: usize = 0;
    inline for (@typeInfo(properties.Property).@"enum".field_names) |name| {
        const property = @field(properties.Property, name);
        count += @intFromBool(!std.meta.eql(properties.get(property, before), properties.get(property, after)));
    }
    if (out.len < count) return error.NoSpace;
    var at: usize = 0;
    inline for (@typeInfo(properties.Property).@"enum".field_names) |name| {
        const property = @field(properties.Property, name);
        const a = properties.get(property, before);
        const b = properties.get(property, after);
        if (!std.meta.eql(a, b)) {
            out[at] = .{ .property = property, .before = a, .after = b, .invalidates = properties.metadata(property).invalidates };
            at += 1;
        }
    }
    return out[0..at];
}

test "inspector explains a real compiled rule winner, inactive state and local override" {
    const compiler = @import("compiler.zig");
    var rules: [3]resolution.Rule = undefined;
    var declarations: [6]resolution.Declaration = undefined;
    var variants: [1]types.Id = undefined;
    const sheet = try compiler.compile("root { color: #fff; } root:hover { color: token(absent); } root:selected { border-width: 2px; }", .{ .rules = &rules, .declarations = &declarations, .variants = &variants }, null);
    var property_rows: [properties.count]resolution.Inspection = undefined;
    var rule_rows: [3]Rule = undefined;
    var declaration_rows: [4]Declaration = undefined;
    const inspected = try snapshot(.{ .rules = sheet.rules, .states = .{ .selected = true }, .local = &.{resolution.set(.text_color, .black)} }, .{ .properties = &property_rows, .rules = &rule_rows, .declarations = &declaration_rows });
    try std.testing.expectEqual(Disposition.overridden, inspected.declarations[0].disposition);
    try std.testing.expectEqual(Disposition.inactive, inspected.declarations[1].disposition);
    try std.testing.expect(!inspected.rules[1].match.required_states);
    try std.testing.expectEqual(Disposition.winning, inspected.declarations[2].disposition);
    try std.testing.expectEqual(types.Color.black, inspected.computed.text.color);
    try std.testing.expectEqual(types.Id.from("local"), inspected.properties[@backingInt(properties.Property.text_color)].origin.source);
    var changes: [properties.count]Difference = undefined;
    const changed = try differences(&.{}, &inspected.computed, &changes);
    var geometry = false;
    for (changed) |entry| if (entry.property == .border_width) {
        geometry = entry.invalidates.layout and entry.invalidates.descendants;
    };
    try std.testing.expect(geometry);
    try std.testing.expectError(error.NoSpace, differences(&.{}, &inspected.computed, changes[0..0]));
}

test {
    std.testing.refAllDecls(@This());
}
