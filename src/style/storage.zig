//! Optional bounded storage. The direct resolver borrows ordinary slices and does not need
//! either of these conveniences. Reset invalidates spans; caches retain only reached states.

const std = @import("std");
const types = @import("../core/types.zig");
const resolve_zig = @import("resolve.zig");
const environment = @import("environment.zig");
const properties = @import("properties.zig");

pub const Span = struct { start: u32, len: u32, generation: u64 };
pub const Store = struct {
    rows: []resolve_zig.Declaration,
    len: u32 = 0,
    generation: u64 = 1,

    pub fn append(store: *Store, declarations: []const resolve_zig.Declaration) error{NoSpace}!Span {
        if (declarations.len > store.rows.len - store.len or declarations.len > std.math.maxInt(u32) - store.len) return error.NoSpace;
        const start = store.len;
        @memcpy(store.rows[start..][0..declarations.len], declarations);
        store.len += @intCast(declarations.len);
        return .{ .start = start, .len = @intCast(declarations.len), .generation = store.generation };
    }

    pub fn view(store: *const Store, span: Span) error{StaleSpan}![]const resolve_zig.Declaration {
        if (span.generation != store.generation or span.start > store.len or span.len > store.len - span.start) return error.StaleSpan;
        return store.rows[span.start..][0..span.len];
    }

    pub fn reset(store: *Store) void {
        store.len = 0;
        store.generation +%= 1;
        if (store.generation == 0) store.generation = 1;
    }
};

/// The application owns these revisions. Increment the appropriate one when borrowed inputs
/// change. In particular `recipe` covers base values, declarations and variant selections;
/// `parent` covers inherited values. A new identity can be used instead of incrementing.
pub const Revisions = struct { recipe: u64 = 0, tokens: u64 = 0, parent: u64 = 0 };
pub const Key = struct {
    identity: types.Id,
    revisions: Revisions,
    part: types.Id,
    scope: u32,
    states: resolve_zig.States,
    environment: environment.Environment,

    pub fn from(identity: types.Id, revisions: Revisions, request: resolve_zig.Request) Key {
        return .{ .identity = identity, .revisions = revisions, .part = request.part, .scope = request.scope, .states = request.states, .environment = request.environment };
    }
};

pub const Row = struct {
    live: bool = false,
    key: Key = undefined,
    computed: properties.Computed = undefined,
};
pub const Result = struct { computed: properties.Computed, cached: bool };
pub const Cache = struct {
    rows: []Row,
    next: usize = 0,

    pub fn init(rows: []Row) Cache {
        for (rows) |*row| row.live = false;
        return .{ .rows = rows };
    }

    pub fn clear(cache: *Cache) void {
        for (cache.rows) |*row| row.live = false;
        cache.next = 0;
    }

    pub fn get(cache: *const Cache, key: Key) ?properties.Computed {
        for (cache.rows) |row| {
            if (row.live and std.meta.eql(row.key, key)) return row.computed;
        }
        return null;
    }

    /// A bounded round-robin cache, with no admission or allocation side effects. Zero
    /// capacity is an error; a caller wanting no cache calls the direct resolver instead.
    pub fn put(cache: *Cache, key: Key, computed: properties.Computed) error{NoSpace}!void {
        if (cache.rows.len == 0) return error.NoSpace;
        for (cache.rows) |*row| {
            if (row.live and std.meta.eql(row.key, key)) {
                row.computed = computed;
                return;
            }
        }
        cache.rows[cache.next] = .{ .live = true, .key = key, .computed = computed };
        cache.next = (cache.next + 1) % cache.rows.len;
    }

    pub fn resolve(cache: *Cache, identity: types.Id, revisions: Revisions, request: resolve_zig.Request) resolve_zig.Error!Result {
        const key = Key.from(identity, revisions, request);
        if (cache.get(key)) |computed| return .{ .computed = computed, .cached = true };
        const computed = try resolve_zig.resolve(request, null);
        try cache.put(key, computed);
        return .{ .computed = computed, .cached = false };
    }
};

test "bounded authoring storage rejects overflow and stale spans without losing current declarations" {
    var rows: [2]resolve_zig.Declaration = undefined;
    var store: Store = .{ .rows = &rows };
    const span = try store.append(&.{ resolve_zig.set(.fill, .white), resolve_zig.set(.gap, 8) });
    try std.testing.expectEqual(@as(usize, 2), (try store.view(span)).len);
    try std.testing.expectError(error.NoSpace, store.append(&.{resolve_zig.set(.gap, 4)}));
    const computed = try resolve_zig.resolve(.{ .local = try store.view(span) }, null);
    try std.testing.expectEqual(@as(f32, 8), computed.box.gap);
    store.reset();
    try std.testing.expectError(error.StaleSpan, store.view(span));
}

test "optional cache agrees with direct resolution and generation changes invalidate a reached state" {
    var rows: [2]Row = undefined;
    var cache = Cache.init(&rows);
    var declarations = [_]resolve_zig.Declaration{resolve_zig.set(.fill, .white)};
    const request: resolve_zig.Request = .{ .local = &declarations, .states = .{ .hovered = true } };
    const first = try cache.resolve(.from("button"), .{}, request);
    try std.testing.expect(!first.cached);
    const second = try cache.resolve(.from("button"), .{}, request);
    try std.testing.expect(second.cached);
    try std.testing.expectEqualDeep(try resolve_zig.resolve(request, null), second.computed);
    declarations[0] = resolve_zig.set(.fill, .black);
    const revised = try cache.resolve(.from("button"), .{ .recipe = 1 }, request);
    try std.testing.expect(!revised.cached);
    try std.testing.expectEqual(types.Color.black, revised.computed.box.fill);
    cache.clear();
    try std.testing.expectEqual(@as(?properties.Computed, null), cache.get(Key.from(.from("button"), .{ .recipe = 1 }, request)));
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Store);
    std.testing.refAllDecls(Cache);
}
