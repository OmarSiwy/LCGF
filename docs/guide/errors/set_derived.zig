//! expect: 'gain' is derived; set its inputs instead
const s = @import("lcgr").spec;

const State = struct {
    volume: f32 = 0,
    gain: f32 = 0,
    pub const derived = .{ .gain = .{ .from = .{.volume}, .compute = f } };
    fn f(x: *const State) f32 {
        return x.volume;
    }
};

export fn setGain(rt: *@import("lcgr").signals.Signals(State, s.label(.gain)).Runtime) void {
    rt.set(.gain, 1);
}
