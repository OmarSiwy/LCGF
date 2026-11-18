//! expect: label: a label needs a literal or a bound field
const lcgf = @import("lcgf");
comptime {
    lcgf.validate.check(struct {}, .{ .kind = .label }, .{});
}
