//! C0804: bytes per node of capacity of the runtime front end (src/runtime/context.zig), its tree
//! and its draw list, as the difference between 8,192 and 4,096 nodes. Build as docs/perf/build/push.zig.
const std = @import("std");
const lcgf = @import("lcgf");
pub fn main() void {
    const L = lcgf.context.Limits;
    const a: L = .{ .nodes = 4096 };
    const b: L = .{ .nodes = 8192 };
    const ra = lcgf.context.Context.requiredBytes(a);
    const rb = lcgf.context.Context.requiredBytes(b);
    std.debug.print("ctx 4096={d} 8192={d} per node={d}\n", .{ ra, rb, (rb - ra) / 4096 });
    inline for (.{lcgf.tree.Tree}) |T| {
        var c1: lcgf.mem.Carver = .{ .buf = null };
        _ = T.init(&c1, 4096);
        var c2: lcgf.mem.Carver = .{ .buf = null };
        _ = T.init(&c2, 8192);
        std.debug.print("tree per node={d}\n", .{(c2.off - c1.off) / 4096});
    }
    var d1: lcgf.mem.Carver = .{ .buf = null };
    _ = lcgf.draw_list.DrawList.init(&d1, 4096, 0, 0);
    var d2: lcgf.mem.Carver = .{ .buf = null };
    _ = lcgf.draw_list.DrawList.init(&d2, 8192, 0, 0);
    std.debug.print("drawlist per node={d}\n", .{(d2.off - d1.off) / 4096});
}
