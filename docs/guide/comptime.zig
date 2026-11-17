//! The examples of docs/guide/comptime.md, compiled and run by `zig build docs`. Every ```zig
//! block of the guide is a verbatim piece of this file (docs/guide/snippets.py checks that).

const std = @import("std");
const testing = std.testing;
const lcgf = @import("lcgf");
const Input = lcgf.input.Input;

// -- state and spec
const s = lcgf.spec;

const Mixer = struct {
    title: []const u8 = "Mixer",
    volume: f32 = 0.5,
    muted: bool = false,
    pan: f32 = 0,
};

const mixer = s.col(.{ .pad = @splat(8), .gap = 4 }, .{
    s.label(.title),
    s.row(.{ .gap = 8 }, .{ s.named(s.checkbox(.mute, .muted), "Mute"), s.named(s.slider(.volume, .volume), "Volume") }),
    s.row(.{ .gap = 8 }, .{ s.label(.title), s.named(s.slider(.pan, .pan), "Pan") }),
});

comptime {
    lcgf.validate.check(Mixer, mixer, .{});
}
// -- end

test "tables: structure is a compile-time constant" {
    // -- flat
    const F = lcgf.flatten.Flat(mixer);
    try testing.expectEqual(8, F.node_count);
    try testing.expectEqual(u4, F.Index);
    try testing.expectEqualSlices(F.Index, &.{ 0, 0, 0, 2, 2, 0, 5, 5 }, &F.parent);
    try testing.expectEqualSlices(F.Index, &.{ 8, 2, 5, 4, 5, 8, 7, 8 }, &F.end);
    // -- end
}

test "signals: a setter is a store and an OR" {
    // -- signals
    const S = lcgf.signals.Signals(Mixer, mixer);
    var rt: S.Runtime = .{};
    _ = rt.takeDirty(); // every node starts dirty: the first frame does everything

    rt.set(.volume, 0.9); // a slider keeps its size: repaint it, lay out nothing
    var d = rt.takeDirty();
    try testing.expectEqual(0, d.layout);
    try testing.expectEqual(0b0001_0000, d.paint);

    rt.set(.title, "Desk"); // a label's text sizes it: both labels, row 5 and the root
    d = rt.takeDirty();
    try testing.expectEqual(0b0110_0011, d.layout);
    // -- end
}

// -- derived
const Channel = struct {
    volume: f32 = 0.5,
    muted: bool = false,
    gain: f32 = 0.5,

    pub const derived = .{ .gain = .{ .from = .{ .volume, .muted }, .compute = gainOf } };
    pub const effects = .{ .save = .{ .volume, .muted }, .meter = .{.gain} };

    fn gainOf(c: *const Channel) f32 {
        return if (c.muted) 0 else c.volume;
    }
};
// -- end

test "derived fields and effects" {
    const channel = comptime s.row(.{}, .{ s.slider(.v, .volume), s.checkbox(.m, .muted), s.label(.gain) });
    const S = lcgf.signals.Signals(Channel, channel);
    var saves: u32 = 0;
    var meter: f32 = -1;
    // -- effects
    var rt: S.Runtime = .{};
    rt.stage(.volume, 0.8);
    rt.stage(.muted, true);
    rt.commit(); // gain is recomputed once for the batch

    while (rt.takeEffect()) |e| switch (e) { // forgetting an effect is a compile error
        .save => saves += 1,
        .meter => meter = rt.state.gain,
    };
    // -- end
    try testing.expectEqual(1, saves);
    try testing.expectEqual(0, meter);
}

test "events: widgets are an enum" {
    // -- widget
    const E = lcgf.events.Events(mixer);
    try testing.expectEqual(4, @backingInt(E.Widget.volume)); // the tag's value is its row
    const hit: E.Widget = .mute;
    const label = switch (hit) { // a widget missing here is a compile error
        .mute => "mute",
        .volume, .pan => "slider",
    };
    // -- end
    try testing.expectEqualStrings("mute", label);
}

// -- components
fn channelRow(comptime mute: @EnumLiteral(), comptime muted: @EnumLiteral(), comptime level: @EnumLiteral()) s.Spec {
    return s.row(.{ .gap = 8 }, .{ s.checkbox(mute, muted), s.slider(level, level) });
}
// -- end

test "components: a function returning a Spec is the same nodes inline" {
    const a = comptime s.col(.{}, .{ channelRow(.mute, .muted, .volume), s.label(.title) });
    const b = comptime s.col(.{}, .{ s.row(.{ .gap = 8 }, .{ s.checkbox(.mute, .muted), s.slider(.volume, .volume) }), s.label(.title) });
    try testing.expectEqual(lcgf.flatten.Flat(b).parent, lcgf.flatten.Flat(a).parent);
    try testing.expectEqual(lcgf.flatten.Flat(b).end, lcgf.flatten.Flat(a).end);
}

// -- frame
const w = lcgf.widgets_base;
const th: w.Theme = .default;

const Toolbar = struct {
    reset_text: []const u8 = "Reset",
    wireframe: bool = false,
    wire_text: []const u8 = "Wireframe",
    exposure: f32 = 0.25,
};

const toolbar = s.row(.{ .gap = 8 }, .{
    w.ct.button(th, .reset, .reset_text),
    w.ct.checkbox(th, .wire, .wireframe, .wire_text),
    w.ct.slider(th, .exposure, .exposure),
});

const Ui = w.ComptimeUi(Toolbar, toolbar, th);
var ui: Ui = .{}; // the buffer is inside: no allocator, sized by the compiler
// -- end

test "ComptimeUi: a frame from input" {
    var in: Input = .{ .viewport = .{ 400, 100 } };
    var out = ui.frame(&in);
    var resets: u32 = 0;
    // -- run
    in.pointer = .{ 5, 5 }; // over the button, which is the first child of the row
    in.buttons.left = true;
    out = ui.frame(&in); // input is judged against the last frame's rects
    in.buttons.left = false;
    out = ui.frame(&in); // a click is a press and a release over the widget
    if (out.event) |e| switch (e) {
        .reset => resets += 1, // a button's click comes back to the caller
        .wire, .exposure => {}, // checkboxes and sliders have already written their field
    };
    const draw = out.draw; // hand it to a renderer
    // -- end
    try testing.expectEqual(1, resets);
    try testing.expect(draw.quad_len > 0);
}
