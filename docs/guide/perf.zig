//! The examples of docs/guide/perf.md, compiled and run by `zig build docs`. Every ```zig
//! block of the guide is a verbatim piece of this file (docs/guide/snippets.py checks that).
//! The sizes here are exact and checked; the timings in the guide are measurements.

const std = @import("std");
const testing = std.testing;
const lcgf = @import("lcgf");
const Context = lcgf.context.Context;
const s = lcgf.spec;

test "memory: bytes per node of capacity" {
    // -- bytes
    const small = Context.requiredBytes(.{ .nodes = 4096 });
    const large = Context.requiredBytes(.{ .nodes = 8192 });
    try testing.expectEqual(925 * 4096, large - small); // 925 bytes per node
    // -- end
}

const Mixer = struct { title: []const u8 = "Mixer", volume: f32 = 0.5, muted: bool = false, pan: f32 = 0 };
const mixer = s.col(.{ .pad = @splat(8), .gap = 4 }, .{
    s.label(.title),
    s.row(.{ .gap = 8 }, .{ s.checkbox(.mute, .muted), s.slider(.volume, .volume) }),
    s.row(.{ .gap = 8 }, .{ s.label(.title), s.slider(.pan, .pan) }),
});

test "memory: the comptime front end keeps state and two masks" {
    // -- comptime
    const S = lcgf.signals.Signals(Mixer, mixer);
    try testing.expectEqual(32, @sizeOf(Mixer));
    try testing.expectEqual(u8, S.Mask); // 8 nodes, one bit each
    try testing.expectEqual(40, @sizeOf(S.Runtime)); // the state, two masks, padding
    // -- end
}
