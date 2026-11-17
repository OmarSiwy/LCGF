//! Prints, for each example UI (src/comptime/examples.zig), the bytes the comptime front end keeps
//! in read-only data and in RAM, the RAM the runtime tree takes for the same nodes, the layout scratch size,
//! and the runtime tree's bytes per node (`zig build ct-sizes`, ci/jobs/ct-sizes.sh). Its own module root,
//! importing the package as `lcgf`; not exported from src/lcgf.zig.

const std = @import("std");
const lcgf = @import("lcgf");
const examples = lcgf.ct_examples;

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const w = &out.interface;
    try w.print("{s:<10} {s:>5} {s:>6} {s:>6} {s:>5} {s:>5} {s:>8} {s:>8} {s:>8} {s:>8} {s:>8} {s:>9}\n", .{ "example", "nodes", "const", "dyn", "drop", "coord", "rodata", "ram", "scratch", "runtime", "saved", "rt/node" });
    inline for (examples.all) |e| {
        const C = lcgf.columns.Columns(e.spec, e.options);
        // Kept constant, kept dynamic, dropped.
        var k: [3]usize = .{ 0, 0, 0 };
        for (C.class, C.dropped) |c, d| k[if (d) 2 else @backingInt(c)] += 1;
        const scratch = comptime for (C.class) |class| {
            if (class == .constant) break std.fmt.comptimePrint("{d}", .{@sizeOf(lcgf.ct_layout.Layout(e.spec, e.options).Scratch)});
        } else "runtime";
        try w.print("{s:<10} {d:>5} {d:>6} {d:>6} {d:>5} {s:>5} {d:>8} {d:>8} {s:>8} {d:>8} {d:>8} {d:>9}\n", .{ e.name, C.node_count, k[0], k[1], k[2], @typeName(C.Coordinate), C.rodata_bytes, C.ram_bytes, scratch, C.runtime_bytes, C.ram_saved, C.runtime_bytes / C.node_count });
    }
    try w.flush();
}
