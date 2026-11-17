//! expect: state signal_missing_field.State has no field 'volum'
const s = @import("lcgf").spec;

const State = struct { volume: f32 = 0 };

comptime {
    _ = @import("lcgf").signals.Signals(State, s.label(.volum)).dirty_masks;
}
