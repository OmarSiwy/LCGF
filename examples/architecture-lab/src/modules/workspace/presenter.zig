//! The presenter projects domain columns into display order. Filtering is an
//! O(n) revision-triggered pass; drawing borrows only the resulting index slice.

const std = @import("std");
const entity = @import("entity.zig");
const navigation = @import("../../core/navigation.zig");

pub const Cache = struct {
    indices: [entity.capacity]u32 = undefined,
    len: u32 = 0,
    revision: u64 = 0,
    page: navigation.Page = .all,
    valid: bool = false,
    rebuilds: u64 = 0,
    /// Summary counts are over the whole store, independent of the current filter.
    running: u32 = 0,
    completed: u32 = 0,

    /// The cache belongs to one Store. A different Store requires invalidate(),
    /// even when it happens to carry the same revision. No pointer into our own
    /// inline storage is retained, so a Cache may move before being borrowed.
    pub fn invalidate(self: *Cache) void {
        self.valid = false;
    }

    pub fn refresh(self: *Cache, store: *const entity.Store, page: navigation.Page) bool {
        if (self.valid and self.revision == store.revision and self.page == page) return false;

        // Choose the filtering operation once. Each loop visits dense columns;
        // the predicate is not a per-row virtual call or router dispatch.
        switch (page) {
            .all => self.rebuild(store, .all),
            .running => self.rebuild(store, .running),
            .completed => self.rebuild(store, .completed),
        }
        self.revision = store.revision;
        self.page = page;
        self.valid = true;
        self.rebuilds +%= 1;
        return true;
    }

    fn rebuild(self: *Cache, store: *const entity.Store, comptime page: navigation.Page) void {
        self.len = 0;
        self.running = 0;
        self.completed = 0;
        for (store.progress[0..store.len], store.active[0..store.len], 0..) |progress, active, i| {
            const complete = progress == 1000;
            self.running += @intFromBool(active);
            self.completed += @intFromBool(complete);
            const include = switch (page) {
                .all => true,
                .running => active,
                .completed => complete,
            };
            // Write then advance conditionally: dense stable compaction, with no
            // per-row allocation or branch around a selected-row insertion.
            self.indices[self.len] = @intCast(i);
            self.len += @intFromBool(include);
        }
    }

    /// Every filter preserves slot order. Binary search therefore maps a stable
    /// selection to its visible position without rescanning the data every frame.
    /// Null means no selection, an invalid ID, or an entity hidden by the filter.
    pub fn indexForId(self: *const Cache, store: *const entity.Store, selection: ?entity.ItemId) ?u32 {
        const id = selection orelse return null;
        const slot = store.indexOf(id) orelse return null;
        var left: u32 = 0;
        var right = self.len;
        while (left < right) {
            const middle = left + (right - left) / 2;
            if (self.indices[middle] < slot) {
                left = middle + 1;
            } else {
                right = middle;
            }
        }
        if (left < self.len and self.indices[left] == slot) return left;
        return null;
    }
};

/// A frame-only borrow. Consume before mutating State, refreshing Cache, or moving
/// either owner. Text buffers for row formatting remain local to the view; LCGF
/// copies text bytes into its frame storage when text nodes are emitted.
pub const Model = struct {
    store: *const entity.Store,
    indices: []const u32,
    selected: ?entity.ItemId,
    selected_index: ?u32,
    scroll: f32,
};

pub fn make(state: *const entity.State, cache: *const Cache) Model {
    std.debug.assert(cache.valid and cache.revision == state.store.revision);
    return .{
        .store = &state.store,
        .indices = cache.indices[0..cache.len],
        .selected = state.selected,
        .selected_index = cache.indexForId(&state.store, state.selected),
        .scroll = state.scroll,
    };
}

test "filters preserve stable storage order and cache no-ops avoid a rebuild" {
    var state: entity.State = .{};
    state.store.init(6);
    state.store.progress[0..6].* = .{ 1000, 200, 300, 1000, 500, 1000 };
    state.store.active[0..6].* = .{ false, true, false, false, true, false };
    var cache: Cache = .{};

    try std.testing.expect(cache.refresh(&state.store, .all));
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4, 5 }, cache.indices[0..cache.len]);
    try std.testing.expectEqual(@as(u32, 2), cache.running);
    try std.testing.expectEqual(@as(u32, 3), cache.completed);
    const rebuilds = cache.rebuilds;
    try std.testing.expect(!cache.refresh(&state.store, .all));
    try std.testing.expectEqual(rebuilds, cache.rebuilds);

    state.selected = state.store.idAt(4);
    state.scroll = 64;
    try std.testing.expect(!cache.refresh(&state.store, .all));
    try std.testing.expect(cache.refresh(&state.store, .running));
    try std.testing.expectEqualSlices(u32, &.{ 1, 4 }, cache.indices[0..cache.len]);
    try std.testing.expectEqual(@as(u32, 2), cache.running);
    try std.testing.expectEqual(@as(u32, 3), cache.completed);
    try std.testing.expectEqual(@as(u32, 1), cache.indexForId(&state.store, state.selected).?);
    try std.testing.expect(cache.indexForId(&state.store, state.store.idAt(0)) == null);

    try std.testing.expect(cache.refresh(&state.store, .completed));
    try std.testing.expectEqualSlices(u32, &.{ 0, 3, 5 }, cache.indices[0..cache.len]);
    const model = make(&state, &cache);
    try std.testing.expectEqual(state.selected, model.selected);
    try std.testing.expectEqual(@as(f32, 64), model.scroll);
    try std.testing.expect(model.store == &state.store);
}

test "revision changes, empty data, and full capacity compaction stay valid" {
    var store: entity.Store = .{};
    var cache: Cache = .{};
    store.init(0);
    try std.testing.expect(cache.refresh(&store, .running));
    try std.testing.expectEqual(@as(u32, 0), cache.len);
    try std.testing.expect(cache.indexForId(&store, @as(entity.ItemId, @fromBackingInt(1))) == null);

    store.init(entity.capacity);
    @memset(store.progress[0..store.len], 0);
    @memset(store.active[0..store.len], true);
    try std.testing.expect(cache.refresh(&store, .running));
    try std.testing.expectEqual(entity.capacity, cache.len);
    try std.testing.expectEqual(entity.capacity - 1, cache.indices[cache.len - 1]);
    const last = store.idAt(store.len - 1);
    try std.testing.expectEqual(entity.capacity - 1, cache.indexForId(&store, last).?);

    @memset(store.active[0..store.len], false);
    store.revision +%= 1;
    try std.testing.expect(cache.refresh(&store, .running));
    try std.testing.expectEqual(@as(u32, 0), cache.len);
    try std.testing.expect(cache.indexForId(&store, last) == null);
    cache.invalidate();
    try std.testing.expect(cache.refresh(&store, .running));
}
