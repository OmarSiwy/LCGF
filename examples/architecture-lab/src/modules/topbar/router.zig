//! Cross-module effects are requests for the app coordinator, never sibling imports.

const std = @import("std");
const entity = @import("entity.zig");
const Request = @import("../../core/navigation.zig").Request;

pub fn route(action: entity.Action) ?Request {
    return switch (action) {
        .toggle_theme => null,
        .advance => .advance,
        .toggle_sidebar => .toggle_sidebar,
    };
}

test "topbar routes cross-module actions and keeps theme local" {
    try std.testing.expect(route(.toggle_theme) == null);
    try std.testing.expectEqual(std.meta.Tag(Request).advance, std.meta.activeTag(route(.advance).?));
    try std.testing.expectEqual(std.meta.Tag(Request).toggle_sidebar, std.meta.activeTag(route(.toggle_sidebar).?));
}
