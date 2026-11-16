//! expect: col > slider[0]: slider 'volume' needs an f32 field, not bool
const s = @import("lcgr").spec;

comptime {
    @import("lcgr").validate.check(struct { volume: bool }, s.col(.{}, .{s.slider(.volume, .volume)}));
}
