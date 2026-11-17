//! expect: row > checkbox[0]: checkbox 'mute' has no accessible name; give it one with spec.named(..., "Name")
const s = @import("lcgf").spec;

// An empty name is no name.
comptime {
    @import("lcgf").validate.check(struct { muted: bool }, s.row(.{}, .{s.named(s.checkbox(.mute, .muted), "")}), .{});
}
