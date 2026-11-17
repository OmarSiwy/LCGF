//! expect: expected type '[]align(64) u8', found '*[4096]u8'
const lcgf = @import("lcgf");
const Context = lcgf.context.Context;

var buffer: [4096]u8 = undefined; // no align(lcgf.mem.column_align)

export fn start() bool {
    _ = Context.init(&buffer, .{ .nodes = 4 }) catch return false;
    return true;
}
