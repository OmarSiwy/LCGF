//! Real input and draw parity for the additional shared recipe adapters.

const std = @import("std");
const types = @import("../core/types.zig");
const Input = @import("../core/input.zig").Input;
const Frame = @import("../runtime/frame.zig").Frame;
const base = @import("../widgets/base.zig");
const spec = @import("../comptime/spec.zig");
const keys = @import("../widgets/keys.zig");
const radio_native = @import("../widgets/radio.zig");
const range_native = @import("../widgets/range.zig");
const model = @import("recipe.zig");
const extra = @import("recipe_extra_controls.zig");
const recipes_ct = @import("recipe_comptime.zig");
const style = @import("../style/style.zig");

const hidden_row_rule: style.Rule = .{ .part = style.Parts.row, .require = .{ .busy = true }, .when = .{ .coarse_pointer = true }, .declarations = &.{style.set(.participation, .hidden)} };
const radio_rules = model.checkbox_rules ++ [_]style.Rule{ .{ .part = style.Parts.indicator, .require = .{ .checked = true }, .declarations = &.{ style.set(.fill, .rgb(240, 140, 20)), style.set(.radius, 1) } }, hidden_row_rule };
const range_rules = model.slider_rules ++ [_]style.Rule{ .{ .part = style.Parts.thumb, .declarations = &.{ style.set(.fill, .rgb(35, 135, 230)), style.set(.width, .px(16)), style.set(.height, .px(16)), style.set(.radius, 3) } }, hidden_row_rule };
const radio_recipe: model.Recipe = .{ .parts = extra.radio_recipe.parts, .rules = &radio_rules };
const range_recipe: model.Recipe = .{ .parts = extra.range_recipe.parts, .rules = &range_rules };
const panel: types.Style = .{ .dir = .y, .gap = 16, .size = .{ .fill, .fit }, .pad = @splat(12) };

const App = struct {
    first: []const u8 = "First",
    second: []const u8 = "Second",
    selected: u32 = 0,
    values: [2]f32 = .{ 0.25, 0.75 },
    busy: bool = true,
    states: style.States = .{},
    environment: model.Environment = .{},

    pub fn build(app: *@This(), frame: *Frame) void {
        _ = frame.open(.none, panel);
        _ = extra.radio(frame, .from("quality"), &app.selected, &.{ app.first, app.second }, .{ .recipe = radio_recipe, .states = app.states, .environment = app.environment }) catch unreachable;
        _ = extra.range(frame, .from("band"), &app.values, 0, 1, .{ .recipe = range_recipe, .states = app.states, .environment = app.environment }) catch unreachable;
        _ = extra.spinner(frame, .from("loading"), app.busy, .{ .environment = app.environment }) catch unreachable;
        frame.close();
    }
};

const page = spec.col(panel, .{
    extra.ct.radio(.quality, .selected, .{ .first, .second }, .{ .recipe = radio_recipe, .states_field = "states", .environment_field = "environment" }),
    extra.ct.range(.band, .values, .{}, .{ .recipe = range_recipe, .states_field = "states", .environment_field = "environment" }),
    extra.ct.spinner(.busy, .{ .environment_field = "environment" }),
});
const Ui = base.ComptimeUi(App, page, .default);
const Run = base.Harness(App, Ui, .{ .nodes = 64, .texts = 4, .strings = 256, .customs = 1, .depth = 8, .anims = 1, .tweens = 1, .flips = 1, .signals = 1, .timers = 1 });
var run: Run = .{};

fn aim(output: Run.Pair, id: types.Id, fraction: f32) [2]f32 {
    const rect = output.runtime.tree.rect(output.runtime.tree.find(id));
    return .{ rect.x0 + fraction * rect.w(), (rect.y0 + rect.y1) / 2 };
}

test "radio and range recipes preserve keyboard and pointer behavior with shared marks and two visible thumbs" {
    run.init();
    var input: Input = .{ .viewport = .{ 360, 240 }, .pointer = .{ -10, -10 } };
    var output = try run.frame(&input);
    var t = output.runtime.tree;
    const group = t.find(.from("quality"));
    const track = t.find(.from("band"));
    try std.testing.expectEqual(types.Color.rgb(240, 140, 20).bitsOf(), t.c.look[group + 3].fill);
    for (0..2) |i| {
        const knob = track + 4 + extra.range_half_rows * @as(u32, @intCast(i));
        try std.testing.expectEqual(types.Color.rgb(35, 135, 230).bitsOf(), t.c.look[knob].fill);
        const knob_rect = t.rect(knob);
        try std.testing.expectEqual(@as(f32, 16), knob_rect.w());
        try std.testing.expectApproxEqAbs(t.rect(track).x0 + t.rect(track).w() * run.app.values[i], (knob_rect.x0 + knob_rect.x1) / 2, 0.51);
    }
    input.events = &.{.{ .kind = .press, .code = keys.map.tab }};
    _ = try run.frame(&input);
    input.events = &.{.{ .kind = .press, .code = keys.right }};
    _ = try run.frame(&input);
    try std.testing.expectEqual(@as(u32, 1), run.app.selected);
    try std.testing.expectEqual(run.app.selected, run.ui.signals.state.selected);
    input.events = &.{.{ .kind = .press, .code = keys.map.tab }};
    _ = try run.frame(&input);
    input.events = &.{.{ .kind = .press, .code = keys.right }};
    output = try run.frame(&input);
    try std.testing.expectApproxEqAbs(@as(f32, 0.26), run.app.values[0], 1e-6);
    input.events = &.{};
    input.pointer = aim(output, .from("band"), 0.85);
    input.buttons.left = true;
    output = try run.frame(&input);
    try std.testing.expectApproxEqAbs(@as(f32, 0.85), run.app.values[1], 1e-5);
    input.buttons.left = false;
    output = try run.frame(&input);
    t = output.runtime.tree;
    try std.testing.expectEqual(@as(f32, 0.85), t.c.value[t.find(range_native.thumbId(.from("band"), 1))]);
    try std.testing.expectEqual(@as(f32, 1), t.c.value[t.find(radio_native.optionId(.from("quality"), 1))]);
    run.app.environment.dark = false;
    run.ui.signals.state.environment = run.app.environment;
    output = try run.frame(&input);
    try std.testing.expect(output.runtime.status.ok());
    try std.testing.expect(output.comptime_.failure == null);
}

test "extra recipe controls cancel disabled capture and keep read-only groups focusable without changes" {
    run.init();
    var input: Input = .{ .viewport = .{ 360, 240 }, .pointer = .{ -10, -10 } };
    var output = try run.frame(&input);
    input.pointer = aim(output, radio_native.optionId(.from("quality"), 1), 0.5);
    input.buttons.left = true;
    _ = try run.frame(&input);
    run.app.states.disabled = true;
    run.ui.signals.state.states = run.app.states;
    _ = try run.frame(&input);
    run.app.states.disabled = false;
    run.ui.signals.state.states = run.app.states;
    input.buttons.left = false;
    output = try run.frame(&input);
    try std.testing.expectEqual(@as(u32, 0), run.app.selected);
    run.app.states.read_only = true;
    run.ui.signals.state.states = run.app.states;
    input.pointer = .{ -10, -10 };
    input.events = &.{.{ .kind = .press, .code = keys.map.tab }};
    _ = try run.frame(&input);
    try std.testing.expect(run.ctx.inter.focus != 0 and run.ui.focus != null);
    input.events = &.{.{ .kind = .press, .code = keys.right }};
    output = try run.frame(&input);
    try std.testing.expectEqual(@as(u32, 0), run.app.selected);
    try std.testing.expectEqual([2]f32{ 0.25, 0.75 }, run.app.values);
    try std.testing.expect(output.comptime_.event == null);
}

test "recipe spinner requests frames while busy and has a stable reduced-motion alternative in both front ends" {
    run.init();
    var input: Input = .{ .viewport = .{ 360, 240 }, .pointer = .{ -10, -10 }, .time = 0 };
    var output = try run.frame(&input);
    try std.testing.expect(output.comptime_.wake > 0 and output.comptime_.wake < 0.1);
    const before = std.hash.Wyhash.hash(0, output.runtime.draw.quadBytes());
    input.time = 0.25;
    output = try run.frame(&input);
    try std.testing.expect(before != std.hash.Wyhash.hash(0, output.runtime.draw.quadBytes()));
    run.app.environment.reduced_motion = true;
    run.ui.signals.state.environment = run.app.environment;
    output = try run.frame(&input);
    const reduced = std.hash.Wyhash.hash(0, output.runtime.draw.quadBytes());
    input.time = 5.75;
    output = try run.frame(&input);
    try std.testing.expectEqual(reduced, std.hash.Wyhash.hash(0, output.runtime.draw.quadBytes()));
    try std.testing.expectEqual(types.inf, output.comptime_.wake);
    const count = output.runtime.draw.quad_len;
    run.app.busy = false;
    run.ui.signals.state.busy = false;
    output = try run.frame(&input);
    try std.testing.expect(output.runtime.draw.quad_len < count);
    try std.testing.expectEqual(types.inf, output.comptime_.wake);
}

fn SpinnerWakeFixture(comptime participation: types.Participation) type {
    return struct {
        const App_ = struct {
            busy: bool = true,
            recipe: model.Recipe = extra.spinner_recipe,

            pub fn build(app: *@This(), frame: *Frame) void {
                _ = frame.open(.none, .{ .participation = participation });
                _ = extra.spinner(frame, .from("wake.spinner"), app.busy, .{ .recipe = app.recipe }) catch unreachable;
                frame.close();
            }
        };
        const Ui_ = base.ComptimeUi(App_, spec.col(.{ .participation = participation }, .{extra.ct.spinner(.busy, .{ .recipe_field = "recipe" })}), .default);
        const Harness_ = base.Harness(App_, Ui_, .{ .nodes = 16, .texts = 1, .strings = 32, .customs = 1, .depth = 4, .anims = 1, .tweens = 1, .flips = 1, .signals = 1, .timers = 1 });
        var harness: Harness_ = .{};
    };
}

test "recipe spinner wake follows effective ancestor participation and the bound busy state in both front ends" {
    const input: Input = .{ .viewport = .{ 160, 120 }, .pointer = .{ -10, -10 } };
    inline for (.{ types.Participation.hidden, types.Participation.collapsed }) |participation| {
        const Fixture = SpinnerWakeFixture(participation);
        Fixture.harness.init();
        _ = try Fixture.harness.frame(&input);
        const output = try Fixture.harness.frame(&input);
        try std.testing.expectEqual(types.inf, output.runtime.wake);
        try std.testing.expectEqual(types.inf, output.comptime_.wake);
        try std.testing.expectEqual(@as(u32, 0), Fixture.harness.ctx.timers.len);
    }
    const Fixture = SpinnerWakeFixture(.all);
    const hidden_when_busy: model.Recipe = .{ .parts = extra.spinner_recipe.parts, .rules = &.{.{ .part = style.Parts.root, .require = .{ .busy = true }, .declarations = &.{style.set(.participation, .hidden)} }} };
    const shown_when_busy: model.Recipe = .{ .parts = extra.spinner_recipe.parts, .rules = &.{
        .{ .part = style.Parts.root, .declarations = &.{style.set(.participation, .hidden)} },
        .{ .part = style.Parts.root, .require = .{ .busy = true }, .declarations = &.{style.set(.participation, .all)} },
    } };
    Fixture.harness.init();
    Fixture.harness.app.recipe = hidden_when_busy;
    Fixture.harness.ui.signals.state.recipe = hidden_when_busy;
    _ = try Fixture.harness.frame(&input);
    var output = try Fixture.harness.frame(&input);
    try std.testing.expectEqual(types.inf, output.runtime.wake);
    try std.testing.expectEqual(types.inf, output.comptime_.wake);
    Fixture.harness.app.recipe = shown_when_busy;
    Fixture.harness.ui.signals.state.recipe = shown_when_busy;
    output = try Fixture.harness.frame(&input);
    try std.testing.expect(output.runtime.wake > 0 and output.runtime.wake < 0.1);
    try std.testing.expect(output.comptime_.wake > 0 and output.comptime_.wake < 0.1);
    Fixture.harness.app.recipe = hidden_when_busy;
    Fixture.harness.ui.signals.state.recipe = hidden_when_busy;
    output = try Fixture.harness.frame(&input);
    try std.testing.expectEqual(types.inf, output.runtime.wake);
    try std.testing.expectEqual(types.inf, output.comptime_.wake);
    try std.testing.expectEqual(@as(u32, 0), Fixture.harness.ctx.timers.len);
}

const FailureFixture = struct {
    const State_ = struct {
        first: []const u8 = "First",
        second: []const u8 = "Second",
        selected: u32 = 0,
        values: [2]f32 = .{ -0.25, 0.75 },
        busy: bool = true,
        loading_recipe: model.Recipe = extra.spinner_recipe,
        caption: []const u8 = "Still works",
    };
    const spec_ = spec.col(panel, .{
        extra.ct.radio(.quality, .selected, .{ .first, .second }, .{}),
        extra.ct.range(.band, .values, .{}, .{}),
        extra.ct.spinner(.busy, .{ .recipe_field = "loading_recipe" }),
        recipes_ct.button(.after, .caption, .{}),
    });
    const Ui_ = base.ComptimeUi(State_, spec_, .default);
    var ui: Ui_ = .{};
    const huge_caption: [2048]u8 = @splat('X');

    fn clickAfter(output: Ui_.Output, input: *Input) !void {
        const row = output.tree.find(.from("after"));
        const expected = @as(u32, @backingInt(Ui_.Events.Widget.after)) + 1;
        try std.testing.expectEqual(expected, row);
        try std.testing.expect(output.tree.participation(row).hit);
        const rect = output.tree.rect(row);
        input.pointer = .{ (rect.x0 + rect.x1) / 2, (rect.y0 + rect.y1) / 2 };
        input.buttons.left = true;
        _ = ui.frame(input);
        input.buttons.left = false;
        const released = ui.frame(input);
        try std.testing.expect(released.event != null);
        try std.testing.expectEqual(Ui_.Events.Widget.after, std.meta.activeTag(released.event.?));
    }
};

test "failed composite recipes preserve CT rows and later button activation then recover on the next frame" {
    const Fixture = FailureFixture;
    const ui = &Fixture.ui;
    ui.* = .{};
    var input: Input = .{ .viewport = .{ 360, 320 }, .pointer = .{ -10, -10 } };
    var output = ui.frame(&input);
    try std.testing.expectEqual(@as(?anyerror, error.InvalidValue), output.failure);
    try std.testing.expectEqual(output.tree.cap, output.tree.len);
    try std.testing.expectEqual(@as(u32, @backingInt(Fixture.Ui_.Events.Widget.@"band.0")), output.tree.find(.from("band")));
    inline for (.{ "band.0", "band.1" }, 0..) |name, i| {
        const row = @as(u32, @backingInt(@field(Fixture.Ui_.Events.Widget, name))) + 1;
        try std.testing.expectEqual(row, output.tree.find(range_native.thumbId(.from("band"), i)));
        try std.testing.expect(!output.tree.participation(row).layout);
        try std.testing.expectEqual(@as(u8, 0), output.tree.c.sense[row]);
    }
    try Fixture.clickAfter(output, &input);
    ui.signals.state.values = .{ 0.25, 0.75 };
    input.pointer = .{ -10, -10 };
    output = ui.frame(&input);
    try std.testing.expectEqual(@as(?anyerror, null), output.failure);
    try std.testing.expect(output.tree.participation(output.tree.find(range_native.thumbId(.from("band"), 0))).hit);

    ui.signals.state.first = &Fixture.huge_caption;
    ui.signals.state.loading_recipe = .{ .parts = extra.spinner_recipe.parts, .rules = &.{.{ .part = style.Parts.root, .declarations = &.{style.set(.width, .fill)} }} };
    output = ui.frame(&input);
    try std.testing.expectEqual(@as(?anyerror, error.NoSpace), output.failure);
    try std.testing.expectEqual(output.tree.cap, output.tree.len);
    try std.testing.expectEqual(types.inf, output.wake);
    const first = output.tree.find(radio_native.optionId(.from("quality"), 0));
    try std.testing.expectEqual(@as(u32, @backingInt(Fixture.Ui_.Events.Widget.@"quality.0")) + 1, first);
    try std.testing.expectEqual(first - 1, output.tree.find(.from("quality")));
    try std.testing.expect(!output.tree.participation(first).layout);
    try Fixture.clickAfter(output, &input);

    ui.signals.state.first = "Restored";
    ui.signals.state.loading_recipe = extra.spinner_recipe;
    input.pointer = .{ -10, -10 };
    output = ui.frame(&input);
    try std.testing.expectEqual(@as(?anyerror, null), output.failure);
    try std.testing.expectEqual(output.tree.cap, output.tree.len);
    try std.testing.expect(output.wake > 0 and output.wake < 0.1);
    const restored = output.tree.rect(output.tree.find(radio_native.optionId(.from("quality"), 1)));
    input.pointer = .{ (restored.x0 + restored.x1) / 2, (restored.y0 + restored.y1) / 2 };
    input.buttons.left = true;
    _ = ui.frame(&input);
    input.buttons.left = false;
    _ = ui.frame(&input);
    try std.testing.expectEqual(@as(u32, 1), ui.signals.state.selected);
}

test "combined state and environment row participation cancels captured range and radio actions in both front ends" {
    run.init();
    var input: Input = .{ .viewport = .{ 360, 240 }, .pointer = .{ -10, -10 } };
    var output = try run.frame(&input);
    input.pointer = aim(output, .from("band"), 0.25);
    input.buttons.left = true;
    _ = try run.frame(&input);
    run.app.states.busy = true;
    run.ui.signals.state.states = run.app.states;
    input.pointer = aim(output, .from("band"), 0.3);
    output = try run.frame(&input);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), run.app.values[0], 1e-5);
    const kept = run.app.values;
    run.app.environment.coarse_pointer = true;
    run.ui.signals.state.environment = run.app.environment;
    input.pointer = aim(output, .from("band"), 0.4);
    output = try run.frame(&input);
    try std.testing.expectEqual(kept, run.app.values);
    try std.testing.expectEqual(@as(u32, 0), run.ctx.inter.active);
    try std.testing.expect(run.ui.pointer.pressed == null);
    run.app.environment.coarse_pointer = false;
    run.ui.signals.state.environment = run.app.environment;
    input.pointer = aim(output, .from("band"), 0.45);
    _ = try run.frame(&input);
    input.buttons.left = false;
    output = try run.frame(&input);
    try std.testing.expectEqual(kept, run.app.values);
    try std.testing.expect(output.comptime_.event == null);

    input.pointer = aim(output, radio_native.optionId(.from("quality"), 1), 0.5);
    input.buttons.left = true;
    _ = try run.frame(&input);
    run.app.environment.coarse_pointer = true;
    run.ui.signals.state.environment = run.app.environment;
    input.buttons.left = false;
    output = try run.frame(&input);
    try std.testing.expectEqual(@as(u32, 0), run.app.selected);
    try std.testing.expect(output.comptime_.event == null);
    run.app.environment.coarse_pointer = false;
    run.ui.signals.state.environment = run.app.environment;
    input.pointer = .{ -10, -10 };
    _ = try run.frame(&input);
    _ = try run.frame(&input);
    input.events = &.{.{ .kind = .press, .code = keys.map.tab }};
    _ = try run.frame(&input);
    run.app.environment.coarse_pointer = true;
    run.ui.signals.state.environment = run.app.environment;
    input.events = &.{.{ .kind = .press, .code = keys.right }};
    output = try run.frame(&input);
    try std.testing.expectEqual(@as(u32, 0), run.app.selected);
    try std.testing.expect(output.comptime_.event == null);
}
