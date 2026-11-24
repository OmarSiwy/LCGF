//! Theme changes are local; domain work and sibling changes go through the app router.

const std = @import("std");
const entity = @import("entity.zig");

pub fn reduce(state: *entity.State, action: entity.Action) bool {
    return switch (action) {
        .toggle_theme => changed: {
            state.dark = !state.dark;
            break :changed true;
        },
        .advance, .toggle_sidebar => false,
    };
}

test "topbar changes only its own preference" {
    var state: entity.State = .{};
    try std.testing.expect(!reduce(&state, .advance));
    try std.testing.expect(!reduce(&state, .toggle_sidebar));
    try std.testing.expect(state.dark);
    try std.testing.expect(reduce(&state, .toggle_theme));
    try std.testing.expect(!state.dark);
}
