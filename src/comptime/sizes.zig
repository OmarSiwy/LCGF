//! Prints, for each example UI (src/comptime/examples.zig), the bytes the comptime front end keeps
//! in read-only data and in RAM (`zig build ct-sizes`, ci/jobs/ct-sizes.sh). Its own module root,
//! importing the package as `lcgr`; not exported from src/lcgr.zig.

const std = @import("std");
const lcgr = @import("lcgr");
const examples = lcgr.ct_examples;

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const w = &out.interface;
    try w.print("{s:<10} {s:>5} {s:>6} {s:>6} {s:>5} {s:>8} {s:>8}\n", .{ "example", "nodes", "const", "dyn", "coord", "rodata", "ram" });
    inline for (examples.all) |e| {
        const C = lcgr.columns.Columns(e.spec, e.options);
        var k: [2]usize = .{ 0, 0 };
        for (C.class) |c| k[@backingInt(c)] += 1;
        try w.print("{s:<10} {d:>5} {d:>6} {d:>6} {s:>5} {d:>8} {d:>8}\n", .{ e.name, C.node_count, k[0], k[1], @typeName(C.Coordinate), C.rodata_bytes, C.ram_bytes });
    }
    try w.flush();
}
