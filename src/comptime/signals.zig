//! Signals: the comptime front end's signal graph, resolved by the compiler. Each state field is
//! a signal; what it affects is a constant, so a setter needs no subscriber list. Tier 1. Ported
//! from prototype/comptime_ui_probe.zig (`Ui().Field`, `Ui().dirty_masks`, `Runtime.set`).

const std = @import("std");
const Spec = @import("spec.zig").Spec;

/// The signals of a UI over `State` declared by `spec`.
pub fn Signals(comptime State: type, comptime spec: Spec) type {
    if (@typeInfo(State) != .@"struct") @compileError("state must be a struct, not " ++ @typeName(State));
    _ = spec;
    return struct {
        /// One tag per state field, in declaration order: tag k is field k, so a field's
        /// tables are indexed by `@backingInt(field)`.
        pub const Field = std.meta.FieldEnum(State);

        /// The type a setter of `field` takes.
        pub fn FieldType(comptime field: Field) type {
            return @FieldType(State, @tagName(field));
        }
    };
}

// ---- tests -------------------------------------------------------------------------------------

const testing = std.testing;
const s = @import("spec.zig");

/// The probe's state and usage spec.
const Mixer = struct { title: []const u8 = "Mixer", volume: f32 = 0.5, muted: bool = false, pan: f32 = 0 };
const mixer = s.col(.{ .pad = @splat(8), .gap = 4 }, .{
    s.label(.title),
    s.row(.{ .gap = 8 }, .{ s.checkbox(.mute, .muted), s.slider(.volume, .volume) }),
    s.row(.{ .gap = 8 }, .{ s.label(.title), s.slider(.pan, .pan) }),
});
const App = Signals(Mixer, mixer);

test "Field: one tag per state field, in declaration order" {
    const info = @typeInfo(App.Field).@"enum";
    try testing.expectEqual(4, info.field_names.len);
    inline for (@typeInfo(Mixer).@"struct".field_names, 0..) |name, k| {
        try testing.expectEqualStrings(name, info.field_names[k]);
        try testing.expectEqual(k, @backingInt(@field(App.Field, name)));
    }
    try testing.expectEqual(App.Field.volume, std.meta.stringToEnum(App.Field, "volume").?);
    try testing.expectEqual(f32, App.FieldType(.volume));
    try testing.expectEqual(bool, App.FieldType(.muted));
    try testing.expectEqual([]const u8, App.FieldType(.title));
}
