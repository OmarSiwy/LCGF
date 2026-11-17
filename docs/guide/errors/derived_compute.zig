//! expect: derived field 'gain' needs compute: fn (*const derived_compute.State) f32
const s = @import("lcgf").spec;

const State = struct {
    volume: f32 = 0,
    gain: f32 = 0,
    pub const derived = .{ .gain = .{ .from = .{.volume}, .compute = f } };
    fn f(x: State) f32 { // takes the state by value
        return x.volume;
    }
};

comptime {
    _ = @import("lcgf").signals.Signals(State, s.label(.gain)).topo_order;
}
