//! Business rules operate on data in batches. This module imports neither a UI
//! framework nor the shell, and performs no allocation or I/O.

const std = @import("std");
const entity = @import("entity.zig");

/// Apply one validated intent. True means observable state actually changed,
/// allowing the shell to request a follow-up frame only when one is necessary.
pub fn reduce(state: *entity.State, action: entity.Action) bool {
    switch (action) {
        .select => |selection| {
            if (selection) |id| {
                if (state.store.indexOf(id) == null) return false;
            }
            if (state.selected == selection) return false;
            state.selected = selection;
            return true;
        },
        .scroll => |requested| {
            if (!std.math.isFinite(requested)) return false;
            const position = @max(requested, 0);
            if (state.scroll == position) return false;
            state.scroll = position;
            return true;
        },
        .reset_scroll => {
            if (state.scroll == 0) return false;
            state.scroll = 0;
            return true;
        },
        .advance => return advance(&state.store),
    }
}

/// One contiguous pass over the hot columns, with no per-entity callback or
/// pointer chase. A button press advances all active items by 2.5 percentage points.
/// This is deliberately event-driven; nothing scans 100,000 rows while idle.
fn advance(store: *entity.Store) bool {
    var changed_bits: u16 = 0;
    for (store.progress[0..store.len], store.active[0..store.len]) |*progress, *active| {
        const previous = progress.*;
        const was_active = active.*;
        const increment: u16 = 25 * @as(u16, @intFromBool(was_active));
        progress.* = @min(previous + increment, 1000);
        active.* = (@intFromBool(was_active) & @intFromBool(progress.* < 1000)) != 0;
        changed_bits |= previous ^ progress.*;
        changed_bits |= @intFromBool(was_active != active.*);
    }
    const changed = changed_bits != 0;
    store.revision +%= @intFromBool(changed);
    return changed;
}

test "selection rejects invalid identity and repeated actions are no-ops" {
    var state: entity.State = .{};
    state.store.init(3);
    const first = state.store.idAt(0);
    const revision = state.store.revision;
    try std.testing.expect(reduce(&state, .{ .select = first }));
    try std.testing.expect(!reduce(&state, .{ .select = first }));
    try std.testing.expect(!reduce(&state, .{ .select = @as(entity.ItemId, @fromBackingInt(0)) }));
    try std.testing.expect(!reduce(&state, .{ .select = @as(entity.ItemId, @fromBackingInt(4)) }));
    try std.testing.expectEqual(first, state.selected.?);
    try std.testing.expectEqual(revision, state.store.revision);
    try std.testing.expect(reduce(&state, .{ .select = null }));
    try std.testing.expect(!reduce(&state, .{ .select = null }));
}

test "scroll rejects NaN and infinities, clamps negative input, and keeps domain revision" {
    var state: entity.State = .{};
    const revision = state.store.revision;
    try std.testing.expect(!reduce(&state, .{ .scroll = std.math.nan(f32) }));
    try std.testing.expect(!reduce(&state, .{ .scroll = std.math.inf(f32) }));
    try std.testing.expect(!reduce(&state, .{ .scroll = -std.math.inf(f32) }));
    try std.testing.expect(reduce(&state, .{ .scroll = 120 }));
    try std.testing.expect(!reduce(&state, .{ .scroll = 120 }));
    try std.testing.expect(reduce(&state, .{ .scroll = -10 }));
    try std.testing.expectEqual(@as(f32, 0), state.scroll);
    try std.testing.expect(!reduce(&state, .reset_scroll));
    try std.testing.expectEqual(revision, state.store.revision);
}

test "batch advance saturates and invalidates only when domain values change" {
    var state: entity.State = .{};
    state.store.init(3);
    state.store.progress[0..3].* = .{ 990, 1000, 80 };
    state.store.active[0..3].* = .{ true, false, false };
    const revision = state.store.revision;
    try std.testing.expect(reduce(&state, .advance));
    try std.testing.expectEqualSlices(u16, &.{ 1000, 1000, 80 }, state.store.progress[0..3]);
    try std.testing.expectEqualSlices(bool, &.{ false, false, false }, state.store.active[0..3]);
    try std.testing.expectEqual(revision +% 1, state.store.revision);
    try std.testing.expect(!reduce(&state, .advance));
    try std.testing.expectEqual(revision +% 1, state.store.revision);
}
