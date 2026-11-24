//! Workspace entities and local UI state, independent of LCGF and any platform.
//! The two frequently scanned properties are dense columns. Names are formatted
//! only for visible rows, so the store needs no per-item strings or heap objects.

const std = @import("std");

pub const capacity: u32 = 100_000;
pub const ItemId = enum(u32) { _ };

pub const Store = struct {
    /// Progress is in thousandths: 1000 is complete. Only [0..len] is initialized.
    progress: [capacity]u16 = undefined,
    active: [capacity]bool = undefined,
    len: u32 = 0,
    /// Changed by domain writes, never by selection or scrolling. Cache validity
    /// depends on every write respecting this contract.
    revision: u64 = 0,

    /// Seed deterministic data in a default-initialized Store (`var store: Store = .{}`).
    /// Re-seeding also invalidates an existing presenter cache. Count is a configured
    /// capacity invariant; loading untrusted counts must validate them before this call.
    pub fn init(self: *Store, count: u32) void {
        std.debug.assert(count <= capacity);
        self.len = count;
        for (self.progress[0..count], self.active[0..count], 0..) |*progress, *active, i| {
            const complete = i % 5 == 0;
            progress.* = if (complete) 1000 else @intCast((i * 37) % 1000);
            active.* = !complete and i % 3 != 0;
        }
        self.revision +%= 1;
    }

    /// IDs are slot + 1. Slots never move or get reused in this template, so
    /// filtering and scrolling cannot change an entity's identity. If deletion
    /// is added, introduce a generation or indirection table before reusing slots.
    pub fn idAt(self: *const Store, index: u32) ItemId {
        std.debug.assert(index < self.len);
        return @fromBackingInt(index + 1);
    }

    /// Reject zero and stale/out-of-range IDs at the interactor boundary.
    pub fn indexOf(self: *const Store, id: ItemId) ?u32 {
        const value = @backingInt(id);
        if (value == 0 or value > self.len) return null;
        return value - 1;
    }
};

pub const State = struct {
    store: Store = .{},
    selected: ?ItemId = null,
    /// Logical pixels. The view clamps to its current viewport; the interactor
    /// rejects non-finite input and clamps the lower bound to zero.
    scroll: f32 = 0,
};

pub const Action = union(enum) {
    select: ?ItemId,
    scroll: f32,
    advance: void,
    reset_scroll: void,
};

test "entity identity is stable and invalid IDs never become indices" {
    var store: Store = .{};
    store.init(7);
    for (0..store.len) |i| {
        const index: u32 = @intCast(i);
        try std.testing.expectEqual(index, store.indexOf(store.idAt(index)).?);
    }
    try std.testing.expect(store.indexOf(@fromBackingInt(0)) == null);
    try std.testing.expect(store.indexOf(@fromBackingInt(8)) == null);
    try std.testing.expect(store.indexOf(@fromBackingInt(std.math.maxInt(u32))) == null);
}

test "seeded columns satisfy progress and active invariants" {
    var store: Store = .{};
    store.init(capacity);
    for (store.progress[0..store.len], store.active[0..store.len]) |progress, active| {
        try std.testing.expect(progress <= 1000);
        try std.testing.expect(!active or progress < 1000);
    }
    const previous = store.revision;
    store.init(0);
    try std.testing.expectEqual(@as(u32, 0), store.len);
    try std.testing.expect(store.revision != previous);
}
