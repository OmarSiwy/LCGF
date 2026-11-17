//! expect: switch must handle all possibilities
const s = @import("lcgf").spec;

const E = @import("lcgf").events.Events(s.row(.{}, .{ s.checkbox(.mute, .muted), s.slider(.volume, .volume) }));

export fn handle(k: u8) u32 {
    const hit: E.Widget = @fromBackingInt(@intCast(k));
    return switch (hit) {
        .mute => 1,
    };
}
