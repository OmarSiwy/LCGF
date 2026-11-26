//! The model: tasks and the one domain operation. It imports nothing.
pub const Page = enum { all, open };
pub const names = [_][]const u8{ "Write", "Test", "Review", "Ship" };

pub const Model = struct {
    done: [names.len]bool = @splat(false),

    /// Marks the first open task done; does nothing once every task is done.
    pub fn advance(m: *Model) void {
        for (&m.done) |*done| {
            if (!done.*) {
                done.* = true;
                return;
            }
        }
    }
};
