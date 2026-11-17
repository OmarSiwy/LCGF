//! expect: col > slider[0]: slider 'volume' needs an f32 field, not bool
const s = @import("lcgf").spec;

comptime {
    @import("lcgf").validate.check(struct { volume: bool }, s.col(.{}, .{s.slider(.volume, .volume)}), .{ .require_names = false });
}
