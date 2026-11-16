//! expect: has no field 'volum'
const s = @import("lcgr").spec;

comptime {
    @import("lcgr").validate.check(struct { volume: f32 }, s.col(.{}, .{s.slider(.volume, .volum)}));
}
