//! expect: col > row[0] > slider[1]: slider 'volume' has no accessible name; give it one with spec.named(..., "Name")
const s = @import("lcgr").spec;

comptime {
    @import("lcgr").validate.check(struct { volume: f32, muted: bool }, s.col(.{}, .{
        s.row(.{}, .{ s.named(s.checkbox(.mute, .muted), "Mute"), s.slider(.volume, .volume) }),
    }), .{});
}
