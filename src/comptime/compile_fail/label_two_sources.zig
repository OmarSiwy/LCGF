//! expect: label: a label takes one of literal text, a bound field or a format
const lcgf = @import("lcgf");
comptime {
    lcgf.validate.check(struct { title: []const u8 = "" }, .{ .kind = .label, .text = "Title", .bind = "title" }, .{});
}
