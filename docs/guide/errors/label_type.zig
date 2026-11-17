//! expect: label 'volume' needs a []const u8 field, not f32
const lcgf = @import("lcgf");
const w = lcgf.widgets_base;

const State = struct { volume: f32 = 0 };

comptime {
    _ = w.ComptimeUi(State, lcgf.spec.row(.{}, .{w.ct.label(.default, .volume)}), .default);
}
