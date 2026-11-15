//! Object file for the setter-shape check (`zig build ct-setter`, ci/jobs/ct-setter.sh). Not
//! exported from src/lcgr.zig: it is its own module root and imports the package as `lcgr`.
//!
//! `set_volume` is the probe's: the check requires it to compile to one store of the value, one
//! OR of a constant into one dirty mask (paint: a slider keeps its size), and the return.

const lcgr = @import("lcgr");
const s = lcgr.spec;

const Mixer = struct { title: []const u8 = "Mixer", volume: f32 = 0.5, muted: bool = false, pan: f32 = 0 };
const App = lcgr.signals.Signals(Mixer, s.col(.{ .pad = @splat(8), .gap = 4 }, .{
    s.label(.title),
    s.row(.{ .gap = 8 }, .{ s.checkbox(.mute, .muted), s.slider(.volume, .volume) }),
    s.row(.{ .gap = 8 }, .{ s.label(.title), s.slider(.pan, .pan) }),
}));

export fn set_volume(rt: *App.Runtime, v: f32) void {
    rt.set(.volume, v);
}

/// 100 nodes, so the mask is a [4]u32 array; `x` is shown by the last leaf only, so its mask
/// touches word 0 (the root) and word 3 (row 99): two ORs.
const Far = lcgr.signals.Signals(struct { x: u8 = 0, y: u8 = 0 }, blk: {
    var leaves: [99]s.Spec = undefined;
    for (&leaves, 0..) |*l, k| l.* = if (k == 98) s.label(.x) else s.label(.y);
    break :blk s.row(.{}, leaves);
});

export fn set_far(rt: *Far.Runtime, v: u8) void {
    rt.set(.x, v);
}

/// The batched setter: for a field nothing derives from, the same store and OR as `set`.
export fn stage_volume(rt: *App.Runtime, v: f32) void {
    rt.stage(.volume, v);
}
