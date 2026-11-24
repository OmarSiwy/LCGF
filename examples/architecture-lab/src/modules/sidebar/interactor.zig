//! Mutate only sidebar state. Return whether its visible state changed.

const std = @import("std");
const entity = @import("entity.zig");

pub fn reduce(state: *entity.State, action: entity.Action) bool {
    return switch (action) {
        .toggle => changed: {
            state.collapsed = !state.collapsed;
            break :changed true;
        },
        .navigate => false,
    };
}

test "sidebar owns collapse state, not navigation" {
    var state: entity.State = .{};
    try std.testing.expect(!reduce(&state, .{ .navigate = .running }));
    try std.testing.expect(!state.collapsed);
    try std.testing.expect(reduce(&state, .toggle));
    try std.testing.expect(state.collapsed);
    try std.testing.expect(reduce(&state, .toggle));
    try std.testing.expect(!state.collapsed);
}
