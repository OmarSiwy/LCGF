const page = @import("forbidden");
export fn check() void {
    var app: page.Page = .{};
    _ = app.frame(&.{});
}
