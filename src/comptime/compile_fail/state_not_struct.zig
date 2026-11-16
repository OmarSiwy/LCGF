//! expect: state must be a struct, not u32
const s = @import("lcgr").spec;

comptime {
    @import("lcgr").validate.check(u32, s.label(.x), .{});
}
