//! MVP model: one state aggregate, the tasks and the page shown. It imports no view or presenter.
pub const Page = enum { all, open };
pub const names = [_][]const u8{ "Write", "Test", "Review", "Ship" };

pub const Model = struct {
    done: [names.len]bool = @splat(false),
    page: Page = .all,

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
