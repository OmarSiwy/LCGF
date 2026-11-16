//! The bench springs scene (bench/scenes/springs.zig) on the ported lcgr Context: median and p99
//! build time of 1,000 Frame.animate calls per frame. See README.md.
const std = @import("std");
const lcgr = @import("lcgr");
const Context = lcgr.context.Context;
const limits: lcgr.context.Limits = .{ .nodes = 2048, .anims = 1024 };
var buffer: [Context.requiredBytes(limits)]u8 align(lcgr.mem.column_align) = undefined;

pub fn main() !void {
    var ctx = try Context.init(&buffer, limits);
    var samples: [3000]u64 = undefined;
    const base = lcgr.types.Id.from("springs");
    const targets = [2]f32{ 4, 40 };
    var sink: f32 = 0;
    for (0..3000) |tick| {
        const in: lcgr.input.Input = .{ .viewport = .{ 1280, 800 }, .dt = 1.0 / 60.0 };
        var f = ctx.begin(&in);
        var t0: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &t0);
        _ = f.open(base, .{ .size = .{ .fill, .fill }, .gap = 2, .pad = @splat(8) });
        for (0..40) |r| {
            _ = f.open(.none, .{ .dir = .x, .gap = 2 });
            for (0..25) |c| {
                const i: u32 = @intCast(r * 25 + c);
                const w = f.animate(base.with(i), targets[(tick / 30 + i) % 2], .{});
                sink += w;
                _ = f.leaf(.none, .{ .size = .{ .px(w), .px(16) } });
            }
            f.close();
        }
        f.close();
        var t1: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &t1);
        samples[tick] = @intCast((t1.sec - t0.sec) * 1_000_000_000 + (t1.nsec - t0.nsec));
        _ = f.end(.{});
    }
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    std.debug.print("lcgr springs: build median {d:.1} us, p99 {d:.1} us (sink {d})\n", .{ @as(f64, @floatFromInt(samples[1500])) / 1000, @as(f64, @floatFromInt(samples[2970])) / 1000, sink });
}
