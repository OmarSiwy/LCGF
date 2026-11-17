//! expect: state must be a struct, not u32
const s = @import("lcgf").spec;

comptime {
    @import("lcgf").validate.check(u32, s.label(.x), .{});
}
