//! docs/research/usage-report.md, edge cases: runs the shell example 30 frames under several
//! Limits against src/ with prototype.diff applied, and prints peak / given, frames hit, first.
//! Build as docs/perf/build/bytes.zig, with -Mlcgf pointing at the patched copy.
const std = @import("std");
const l = @import("lcgf");
const Context = l.context.Context;
const names = [_][]const u8{ "nodes", "texts", "customs", "strings", "anims", "tweens", "flips", "signals", "depth", "timers", "memos" };
fn one(comptime lim: l.context.Limits, label: []const u8) !void {
    const S = struct {
        var buf: [Context.requiredBytes(lim)]u8 align(l.mem.column_align) = @splat(0);
    };
    var ctx = try Context.initZeroed(&S.buf, lim);
    var app: l.shell_example.App = .{};
    var ev: l.shell_iface.Events = .{};
    ev.in.viewport = .{ 640, 480 };
    for (0..30) |k| {
        ev.in.pointer = .{ @floatFromInt(10 + k * 7), @floatFromInt(40 + k * 3) };
        ev.in.buttons = .{ .left = k % 5 == 0 };
        var f = ctx.begin(&ev.in);
        app.build(&f, &ev);
        _ = f.end(.{});
    }
    std.debug.print("{s}: requiredBytes {d}\n", .{ label, Context.requiredBytes(lim) });
    const caps = [_]u32{ lim.nodes, lim.texts, lim.customs, lim.strings, lim.anims, lim.tweens, lim.flips, lim.signals, lim.depth, lim.timers, lim.memos };
    const pk: [16]u32 = ctx.peak;
    const hits: [16]u32 = ctx.hits;
    const first: [16]u32 = ctx.first;
    for (names, 0..) |n, i| std.debug.print("  {s:<8} {d:>6} / {d:<6} {d:>3}%  hits {d} first {d}\n", .{ n, pk[i], caps[i], pk[i] * 100 / caps[i], hits[i], first[i] });
}
pub fn main() !void {
    try one(.{ .nodes = 1024, .texts = 256 }, "example limits");
    try one(.{ .depth = 3 }, "depth 3");
    try one(.{ .strings = 16 }, "strings 16");
    try one(.{ .texts = 4 }, "texts 4");
    try one(.{ .nodes = 16 }, "nodes 16");
}
