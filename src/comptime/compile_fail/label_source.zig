//! expect: label: a label needs a literal, a bound field or a format
const lcgf = @import("lcgf");
comptime {
    lcgf.validate.check(struct {}, .{ .kind = .label }, .{});
}
