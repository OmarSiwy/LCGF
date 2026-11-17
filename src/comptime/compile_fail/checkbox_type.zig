//! expect: row > checkbox[0]: checkbox 'muted' needs a bool field, not f32
const s = @import("lcgf").spec;

comptime {
    @import("lcgf").validate.check(struct { muted: f32 }, s.row(.{}, .{s.checkbox(.mute, .muted)}), .{ .require_names = false });
}
