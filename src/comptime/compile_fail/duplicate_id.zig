//! expect: col > row[1] > checkbox[0]: duplicate widget id 'volume', first used at col > slider[0]
const s = @import("lcgf").spec;

comptime {
    @import("lcgf").validate.check(struct { volume: f32, muted: bool }, s.col(.{}, .{ s.slider(.volume, .volume), s.row(.{}, .{s.checkbox(.volume, .muted)}) }), .{ .require_names = false });
}
