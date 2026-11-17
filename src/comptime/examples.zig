//! Example UIs for the comptime front end's size reports (`zig build ct-sizes`) and tests. Each
//! is a spec and the state struct it binds; they stand in for examples/ until that exists.

const s = @import("spec.zig");
const Spec = s.Spec;

pub const Example = struct { name: []const u8, State: type, spec: Spec, options: Options = .{} };
const Options = @import("validate.zig").Options;

/// The probe's mixer (prototype/comptime_ui_probe.zig), with accessible names.
pub const Mixer = struct { title: []const u8 = "Mixer", volume: f32 = 0.5, muted: bool = false, pan: f32 = 0 };
pub const mixer = s.col(.{ .pad = @splat(8), .gap = 4 }, .{
    s.label(.title),
    s.row(.{ .gap = 8 }, .{ s.named(s.checkbox(.mute, .muted), "Mute"), s.named(s.slider(.volume, .volume), "Volume") }),
    s.row(.{ .gap = 8 }, .{ s.label(.title), s.named(s.slider(.pan, .pan), "Pan") }),
});

/// A card that only shows text: nothing in it is written from state but the label runs.
pub const Card = struct { heading: []const u8 = "Battery", body: []const u8 = "82%" };
pub const static_card = s.col(.{ .pad = @splat(12), .gap = 6, .fill = .rgb(30, 30, 40), .radius = 8, .border = 1, .border_color = .rgb(80, 80, 90) }, .{
    s.label(.heading),
    s.row(.{ .gap = 4 }, .{ s.label(.body), s.col(.{ .size = .{ .fill, .px(1) } }, .{}) }),
});

/// A settings page: a title and ten rows of a label and a control, on a fixed 320x240 display.
pub const Settings = struct {
    title: []const u8 = "Settings",
    wifi: bool = true,
    bluetooth: bool = false,
    brightness: f32 = 0.7,
    volume: f32 = 0.4,
    dark: bool = true,
    sleep: f32 = 0.2,
    sounds: bool = true,
    haptics: bool = false,
    contrast: f32 = 0.5,
    location: bool = false,
};
pub const settings = blk: {
    const fields = @typeInfo(Settings).@"struct";
    var rows: [fields.field_names.len]Spec = undefined;
    rows[0] = s.label(.title);
    for (fields.field_names[1..], fields.field_types[1..], rows[1..]) |name, T, *r| {
        const id: [:0]const u8 = name;
        const control: Spec = .{ .kind = if (T == bool) .checkbox else .slider, .id = id, .bind = name, .name = name };
        r.* = s.row(.{ .gap = 8, .size = .{ .fill, .px(20) } }, .{ Spec{ .kind = .label, .bind = "title" }, control });
    }
    break :blk s.col(.{ .size = .{ .px(320), .px(240) }, .pad = @splat(4), .gap = 2, .fill = .rgb(0, 0, 0) }, rows);
};

/// A status badge for a 96x64 display: a title and a level, on a microcontroller.
pub const Badge = struct { name: []const u8 = "Ada", level: f32 = 0.3 };
pub const badge = s.col(.{ .size = .{ .px(96), .px(64) }, .pad = @splat(2), .gap = 2, .fill = .rgb(255, 255, 255), .clip = true }, .{
    s.label(.name),
    s.named(s.slider(.level, .level), "Level"),
});

/// A dashboard: a title over a row of fixed-size tiles, each a label showing its own field and
/// a bar, and a slider. Each tile is a relayout boundary (ct_layout.Plain.relayout).
pub const Dash = struct { title: []const u8 = "", a: []const u8 = "", b: []const u8 = "", c: []const u8 = "", level: f32 = 0 };
fn tile(comptime field: @EnumLiteral()) Spec {
    return s.col(.{ .size = .{ .px(90), .px(40) }, .pad = @splat(4), .clip = true }, .{ s.label(field), s.col(.{ .size = .{ .fill, .px(4) } }, .{}) });
}
pub const dash = s.col(.{ .pad = @splat(8), .gap = 4 }, .{
    s.label(.title),
    s.row(.{ .gap = 6 }, .{ tile(.a), tile(.b), tile(.c) }),
    s.named(s.slider(.level, .level), "Level"),
});

/// A row whose middle node is a custom widget that builds its own rows.
pub const Custom = struct { level: f32 = 0 };
pub const custom = s.row(.{}, .{ s.label(.level), Spec{ .kind = .col, .widget = struct {} }, s.label(.level) });

/// A to-do page: a heading, a list of up to 8 rows of which `len` are shown, and a footer shown
/// while `footer` is set, then a status line in one of two forms (`mode`). Dynamic examples
/// use `runLive` with the frame's selection.
pub const Todo = struct { title: []const u8 = "Today", len: u32 = 3, footer: bool = true, mode: Mode = .brief };
pub const Mode = enum(u8) { brief, detailed };
pub const todo = s.col(.{ .pad = @splat(4), .gap = 4 }, .{
    s.row(.{ .gap = 8 }, .{ s.label(.title), s.col(.{ .size = .{ .px(30), .px(10) } }, .{}) }),
    s.list(.len, 8, .{ .gap = 2 }, s.row(.{ .gap = 4, .size = .{ .fill, .px(20) } }, .{ s.label(.title), s.col(.{ .size = .{ .fill, .px(8) } }, .{}) })),
    s.when(.footer, s.row(.{ .gap = 8, .pad = @splat(2) }, .{ s.label(.title), s.col(.{ .size = .{ .px(40), .px(12) } }, .{}) })),
    s.choice(.mode, .{}, .{
        s.col(.{ .size = .{ .px(16), .px(16) } }, .{}),
        s.row(.{ .gap = 4, .size = .{ .fill, .fit } }, .{ s.label(.title), s.col(.{ .size = .{ .fill, .px(6) } }, .{}), s.col(.{ .size = .{ .px(24), .px(24) } }, .{}) }),
    }),
});

/// A hundred thousand logical rows use five physical copies of the template.
pub const Feed = struct { count: u32 = 100_000, scroll: f32 = 0 };
pub const feed = s.col(.{}, .{s.virtualList(.count, .scroll, 4, 12, s.col(.{ .size = .{ .fill, .fit } }, .{}))});

/// The examples with dynamic regions.
pub const dynamic = [_]Example{
    .{ .name = "todo", .State = Todo, .spec = todo },
    .{ .name = "feed", .State = Feed, .spec = feed },
};

pub const all = [_]Example{
    .{ .name = "mixer", .State = Mixer, .spec = mixer },
    .{ .name = "card", .State = Card, .spec = static_card },
    .{ .name = "settings", .State = Settings, .spec = settings, .options = .{ .viewport = .{ 320, 240 } } },
    .{ .name = "badge", .State = Badge, .spec = badge, .options = .{ .viewport = .{ 96, 64 } } },
    .{ .name = "dash", .State = Dash, .spec = dash },
    .{ .name = "custom", .State = Custom, .spec = custom },
};

test "examples: every dynamic example passes validation" {
    inline for (dynamic) |e| comptime @import("validate.zig").check(e.State, e.spec, e.options);
}

test "examples: every example passes validation" {
    // One evaluation for all the checks: each raises the quota for its own spec, but the
    // branches add up across them, so the sum is raised here.
    comptime {
        @setEvalBranchQuota(1_000_000);
        for (all) |e| @import("validate.zig").check(e.State, e.spec, e.options);
    }
}
