//! Translate navigation intentions into the app's shared request vocabulary.

const std = @import("std");
const entity = @import("entity.zig");
const Request = @import("../../core/navigation.zig").Request;

pub fn route(action: entity.Action) ?Request {
    return switch (action) {
        .navigate => |page| .{ .navigate = page },
        .toggle => null,
    };
}

test "sidebar routes navigation and keeps collapse local" {
    try std.testing.expect(route(.toggle) == null);
    const request = route(.{ .navigate = .completed }).?;
    try std.testing.expectEqual(.completed, request.navigate);
}
