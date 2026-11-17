//! expect: col > slider[0]: state missing_field.State has no field 'volum'
const s = @import("lcgf").spec;

const State = struct { volume: f32 };

comptime {
    @import("lcgf").validate.check(State, s.col(.{}, .{s.slider(.volume, .volum)}), .{ .require_names = false });
}
