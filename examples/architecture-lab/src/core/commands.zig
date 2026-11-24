//! A single-threaded, caller-owned command buffer. Views append intents, then the
//! shell drains them after every view has read the same state snapshot.

const std = @import("std");

/// Capacity is a deliberate application budget, not an invitation to silently lose
/// actions. A caller must propagate Full or record an explicit frame failure.
/// Payloads should be values or stable IDs; this buffer does not own pointee memory.
pub fn Buffer(comptime T: type, comptime capacity: usize) type {
    return struct {
        storage: [capacity]T = undefined,
        len: usize = 0,

        const Self = @This();

        pub fn items(self: *const Self) []const T {
            return self.storage[0..self.len];
        }

        pub fn append(self: *Self, item: T) error{Full}!void {
            if (self.len == capacity) return error.Full;
            self.storage[self.len] = item;
            self.len += 1;
        }

        /// Values become reusable slots. No allocation or element destructor is hidden here.
        pub fn clear(self: *Self) void {
            self.len = 0;
        }
    };
}

test "a full command buffer preserves every queued action in order" {
    var queue: Buffer(u32, 3) = .{};
    try queue.append(9);
    try queue.append(4);
    try queue.append(2);
    try std.testing.expectError(error.Full, queue.append(7));
    try std.testing.expectEqualSlices(u32, &.{ 9, 4, 2 }, queue.items());
    queue.clear();
    try std.testing.expectEqual(@as(usize, 0), queue.items().len);
    try queue.append(5);
    try std.testing.expectEqualSlices(u32, &.{5}, queue.items());
}
