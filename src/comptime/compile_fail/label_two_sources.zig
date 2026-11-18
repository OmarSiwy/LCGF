//! expect: label: a label cannot have both literal text and a bound field
const lcgf = @import("lcgf");
comptime {
    lcgf.validate.check(struct { title: []const u8 = "" }, .{ .kind = .label, .text = "Title", .bind = "title" }, .{});
}
