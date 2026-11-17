//! expect: derived fields of derived_cycle.State form a cycle
const s = @import("lcgf").spec;

const State = struct {
    a: f32 = 0,
    b: f32 = 0,
    pub const derived = .{ .a = .{ .from = .{.b}, .compute = fa }, .b = .{ .from = .{.a}, .compute = fb } };
    fn fa(x: *const State) f32 {
        return x.b;
    }
    fn fb(x: *const State) f32 {
        return x.a;
    }
};

comptime {
    _ = @import("lcgf").signals.Signals(State, s.label(.a)).topo_order;
}
