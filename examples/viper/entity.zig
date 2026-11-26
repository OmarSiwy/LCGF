//! VIPER entity: plain task data. No behaviour and no imports.
pub const Page = enum { all, open };
pub const names = [_][]const u8{ "Write", "Test", "Review", "Ship" };

pub const Tasks = struct {
    done: [names.len]bool = @splat(false),
};
