const std = @import("std");
const lcgf = @import("lcgf");

pub fn build(b: *std.Build) void {
    lcgf.buildDesktopExample(b, "dashboard");
}
