//! VIPER interactor: the use cases. The only code that changes the entity.
const Tasks = @import("entity.zig").Tasks;

/// Marks the first open task done; does nothing once every task is done.
pub fn advance(t: *Tasks) void {
    for (&t.done) |*done| {
        if (!done.*) {
            done.* = true;
            return;
        }
    }
}
