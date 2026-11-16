//! expect: two shortcuts on key 22 with the same modifiers
const s = @import("lcgr").spec;

const E = @import("lcgr").events.Events(s.row(.{}, .{ s.checkbox(.mute, .muted), s.slider(.volume, .volume) }));

comptime {
    _ = E.Shortcuts(&.{
        .{ .code = 22, .mods = .{ .ctrl = true }, .widget = .mute },
        .{ .code = 22, .mods = .{ .ctrl = true }, .widget = .volume },
    }).slots;
}
