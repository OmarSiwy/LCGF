const std = @import("std");

pub const App = struct {
    message: []const u8 = "Ready",
    subtitle: []const u8 = "Compiled once",
    show_details: bool = false,
    include_note: bool = false,
};

pub const actions = struct {
    pub fn undeclared(writer: anytype) void {
        writer.set(.subtitle, "Overwritten");
    }

    pub fn observe(reader: anytype) void {
        std.debug.assert(std.mem.eql(u8, reader.get(.subtitle), "Compiled once"));
    }

    pub fn change(writer: anytype) void {
        writer.set(.message, "Changed");
        writer.set(.show_details, true);
    }
};
