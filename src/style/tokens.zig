//! Semantic token identity survives resolution. Tables and scope links belong to the caller;
//! literals are never searched for in a palette. Aliases resolve in their definition scope.

const std = @import("std");
const types = @import("../core/types.zig");
const properties = @import("properties.zig");

pub const Id = types.Id;
pub const none = types.none;
pub const Binding = union(enum) { value: properties.Value, alias: Id };
pub const Entry = struct { id: Id, binding: Binding };
pub const Scope = struct {
    parent: u32 = none,
    entries: []const Entry = &.{},
    /// Optional cache users increment this when borrowed entries change.
    generation: u64 = 0,
};

pub fn literal(comptime property: properties.Property, id: Id, value: properties.Type(property)) Entry {
    return .{ .id = id, .binding = .{ .value = properties.valueOf(property, value) } };
}

pub fn alias(id: Id, target: Id) Entry {
    return .{ .id = id, .binding = .{ .alias = target } };
}

pub const Error = error{ MissingToken, InvalidScope, TokenCycle, NoSpace, InvalidScale };
pub const Found = struct {
    value: properties.Value,
    scope: u32,
    entry: u32,
    token: Id,
};

pub const Table = struct {
    scopes: []const Scope = &.{},

    /// Last matching entry wins within a scope; the nearest scope wins over its ancestors.
    /// The bounded walk rejects cycles even for imported, untrusted scope/alias tables.
    pub fn find(table: Table, active_scope: u32, id: Id) Error!Found {
        var scope = active_scope;
        var target = id;
        var limit: usize = 1;
        for (table.scopes) |s| limit +|= s.entries.len;
        for (0..limit) |_| {
            var found: ?struct { scope: u32, entry: u32 } = null;
            var walked: usize = 0;
            while (scope != none) : (walked += 1) {
                if (scope >= table.scopes.len or walked >= table.scopes.len) return error.InvalidScope;
                const s = table.scopes[scope];
                var i = s.entries.len;
                while (i > 0) {
                    i -= 1;
                    if (s.entries[i].id == target) {
                        found = .{ .scope = scope, .entry = @intCast(i) };
                        break;
                    }
                }
                if (found != null) break;
                scope = s.parent;
            }
            const row = found orelse return error.MissingToken;
            switch (table.scopes[row.scope].entries[row.entry].binding) {
                .value => |value| return .{ .value = value, .scope = row.scope, .entry = row.entry, .token = target },
                .alias => |next| {
                    target = next;
                    scope = row.scope;
                },
            }
        }
        return error.TokenCycle;
    }

    /// Ancestor generations only. Use with the request's scope in an optional cache key;
    /// increments are the caller's responsibility when mutable token data changes.
    pub fn generation(table: Table, active_scope: u32) Error!u64 {
        var scope = active_scope;
        var hash: u64 = 0xcbf29ce484222325;
        var walked: usize = 0;
        while (scope != none) : (walked += 1) {
            if (scope >= table.scopes.len or walked >= table.scopes.len) return error.InvalidScope;
            const s = table.scopes[scope];
            hash = (hash ^ scope) *% 0x100000001b3;
            hash = (hash ^ s.generation) *% 0x100000001b3;
            scope = s.parent;
        }
        return hash;
    }
};

/// Names an arbitrary nondecreasing design scale in caller storage. The result can supply
/// padding, gaps, radii, text sizes or another existing numeric consumer through token refs.
/// Validation happens before writing, so failure leaves the destination untouched.
pub fn scale(destination: []Entry, ids: []const Id, values: []const f32) Error![]Entry {
    if (ids.len != values.len) return error.InvalidScale;
    if (destination.len < values.len) return error.NoSpace;
    var previous: f32 = 0;
    for (values) |value| {
        if (!std.math.isFinite(value) or value < previous) return error.InvalidScale;
        previous = value;
    }
    for (destination[0..values.len], ids, values) |*entry, id, value| entry.* = literal(.gap, id, value);
    return destination[0..values.len];
}

test "same-valued roles keep their identities; a child scope and lexical alias differ" {
    const accent = Id.from("accent");
    const danger = Id.from("danger");
    const root = [_]Entry{
        literal(.fill, accent, .white),
        literal(.fill, danger, .white),
        alias(.from("button"), accent),
    };
    const child = [_]Entry{literal(.fill, accent, .black)};
    const scopes = [_]Scope{ .{ .entries = &root }, .{ .parent = 0, .entries = &child } };
    const table: Table = .{ .scopes = &scopes };
    try std.testing.expectEqual(types.Color.black, (try table.find(1, accent)).value.color);
    try std.testing.expectEqual(types.Color.white, (try table.find(1, danger)).value.color);
    try std.testing.expectEqual(types.Color.white, (try table.find(1, .from("button"))).value.color);
    try std.testing.expectError(error.MissingToken, table.find(1, .from("unknown")));
}

test "cycles and scale capacity errors are explicit" {
    const entries = [_]Entry{ alias(.from("a"), .from("b")), alias(.from("b"), .from("a")) };
    const table: Table = .{ .scopes = &.{.{ .entries = &entries }} };
    try std.testing.expectError(error.TokenCycle, table.find(0, .from("a")));
    const cycle: Table = .{ .scopes = &.{.{ .parent = 0 }} };
    try std.testing.expectError(error.InvalidScope, cycle.find(0, .from("a")));
    var output: [2]Entry = undefined;
    try std.testing.expectError(error.NoSpace, scale(output[0..1], &.{ .from("sm"), .from("lg") }, &.{ 4, 8 }));
    _ = try scale(&output, &.{ .from("sm"), .from("lg") }, &.{ 0, 8 });
    try std.testing.expectEqual(@as(f32, 0), output[0].binding.value.number);
    try std.testing.expectError(error.InvalidScale, scale(&output, &.{ .from("sm"), .from("lg") }, &.{ 8, 4 }));
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Table);
}
