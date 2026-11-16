//! 250 colour transitions per frame (`Frame.transition`, four tweens each: 1,000 `Tweens.slot`
//! calls), on the ported lcgr Context: median and p99 build time. Every 30 frames each swatch's
//! target colour flips. See README.md.
const std = @import("std");
const lcgr = @import("lcgr");
const Context = lcgr.context.Context;
const Color = lcgr.types.Color;
const limits: lcgr.context.Limits = .{ .nodes = 1024, .tweens = 1024 };
var buffer: [Context.requiredBytes(limits)]u8 align(lcgr.mem.column_align) = undefined;

pub fn main() !void {
    var ctx = try Context.init(&buffer, limits);
    var samples: [3000]u64 = undefined;
    const base = lcgr.types.Id.from("swatches");
    const colors = [2]Color{ .rgb(20, 40, 200), .rgb(240, 180, 10) };
    var sink: u32 = 0;
    for (0..3000) |tick| {
        const in: lcgr.input.Input = .{ .viewport = .{ 1280, 800 }, .dt = 1.0 / 60.0 };
        var f = ctx.begin(&in);
        var t0: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &t0);
        _ = f.open(base, .{ .size = .{ .fill, .fill }, .gap = 2, .pad = @splat(8) });
        for (0..10) |r| {
            _ = f.open(.none, .{ .dir = .x, .gap = 2 });
            for (0..25) |c| {
                const i: u32 = @intCast(r * 25 + c);
                const col = f.transition(base.with(i), colors[(tick / 30 + i) % 2], .{});
                sink +%= col.bitsOf();
                _ = f.leaf(.none, .{ .size = .{ .px(40), .px(40) }, .fill = col });
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
    std.debug.print("lcgr transitions: build median {d:.1} us, p99 {d:.1} us (sink {d})\n", .{ @as(f64, @floatFromInt(samples[1500])) / 1000, @as(f64, @floatFromInt(samples[2970])) / 1000, sink });
}
