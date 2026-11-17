//! expect: derived field 'gain' reads itself
const s = @import("lcgf").spec;

const State = struct {
    gain: f32 = 0,
    pub const derived = .{ .gain = .{ .from = .{.gain}, .compute = f } };
    fn f(x: *const State) f32 {
        return x.gain;
    }
};

comptime {
    _ = @import("lcgf").signals.Signals(State, s.label(.gain)).topo_order;
}
