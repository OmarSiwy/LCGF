//! expect: duplicate widget id 'volume'
const s = @import("lcgr").spec;

comptime {
    @import("lcgr").validate.check(struct { volume: f32, muted: bool }, s.col(.{}, .{ s.slider(.volume, .volume), s.row(.{}, .{s.checkbox(.volume, .muted)}) }));
}
