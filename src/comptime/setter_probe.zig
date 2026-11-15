//! Object file for the setter-shape check (`zig build ct-setter`, ci/jobs/ct-setter.sh). Not
//! exported from src/lcgr.zig: it is its own module root and imports the package as `lcgr`.
//!
//! `set_volume` is the probe's: the check requires it to compile to one store of the value, one
//! OR of a constant into the dirty mask, and the return.

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
