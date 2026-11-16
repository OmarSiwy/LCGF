//! expect: duplicate widget id 'volume'
const s = @import("lcgr").spec;

comptime {
    @import("lcgr").validate.check(s.col(.{}, .{ s.slider(.volume, .volume), s.row(.{}, .{s.checkbox(.volume, .muted)}) }));
}
