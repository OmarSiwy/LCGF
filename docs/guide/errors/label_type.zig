//! expect: label 'volume' needs a []const u8 field, not f32
const lcgr = @import("lcgr");
const w = lcgr.widgets_base;

const State = struct { volume: f32 = 0 };

comptime {
    _ = w.ComptimeUi(State, lcgr.spec.row(.{}, .{w.ct.label(.default, .volume)}), .default);
}
