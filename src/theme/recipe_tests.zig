//! Consumer regressions: both front ends use the same recipes while actual input changes
//! state. These compare existing production DrawLists and semantic role/value columns.

const std = @import("std");
const types = @import("../core/types.zig");
const Input = @import("../core/input.zig").Input;
const Frame = @import("../runtime/frame.zig").Frame;
const style = @import("../style/style.zig");
const model = @import("recipe.zig");
const controls = @import("recipe_controls.zig");
const ct = @import("recipe_comptime.zig");
const base = @import("../widgets/base.zig");
const spec = @import("../comptime/spec.zig");
const textfield_zig = @import("../widgets/textfield.zig");
const checkbox_zig = @import("../widgets/checkbox.zig");
const keys = @import("../widgets/keys.zig");

const panel: types.Style = .{ .dir = .y, .gap = 8, .size = .{ .fill, .fit }, .pad = @splat(12) };
const button_rules = model.button_rules ++ [_]style.Rule{
    .{ .part = style.Parts.root, .require = .{ .busy = true }, .declarations = &.{style.set(.participation, .hidden)} },
    .{ .part = style.Parts.root, .require = .{ .selected = true }, .declarations = &.{style.set(.cursor, .crosshair)} },
};
const button_recipe: model.Recipe = .{ .parts = model.button.parts, .rules = &button_rules };
const State = struct {
    save: []const u8 = "Save",
    check_text: []const u8 = "Enabled",
    switch_text: []const u8 = "Preview",
    hint: []const u8 = "Name",
    checked: checkbox_zig.Check = .mixed,
    switched: bool = false,
    volume: f32 = 0.25,
    field: textfield_zig.Text(64) = .{},
    button_state: style.States = .{},
    control_state: style.States = .{},
    environment: model.Environment = .{},
    activated: bool = false,

    pub fn build(app: *@This(), f: *Frame) void {
        _ = f.open(.none, panel);
        app.activated = (controls.button(f, .from("save"), app.save, .{ .recipe = button_recipe, .states = app.button_state, .environment = app.environment }) catch unreachable).clicked;
        const options: controls.Options = .{ .states = app.control_state, .environment = app.environment };
        _ = controls.checkbox(f, .from("check"), &app.checked, app.check_text, options) catch unreachable;
        _ = controls.switchControl(f, .from("switch"), &app.switched, app.switch_text, options) catch unreachable;
        _ = controls.slider(f, .from("slider"), &app.volume, 0, 1, options) catch unreachable;
        _ = controls.textfield(f, .from("field"), &app.field, app.hint, options) catch unreachable;
        f.close();
    }
};

const button_config: ct.Config = .{ .recipe = button_recipe, .states_field = "button_state", .environment_field = "environment" };
const control_config: ct.Config = .{ .states_field = "control_state", .environment_field = "environment" };
const page = spec.col(panel, .{
    ct.button(.save, .save, button_config),
    ct.checkbox(.check, .checked, .check_text, control_config),
    ct.switchControl(.@"switch", .switched, .switch_text, control_config),
    ct.slider(.slider, .volume, .{}, control_config),
    ct.textfield(.field, .field, .hint, control_config),
});
const Ui = base.ComptimeUi(State, page, .default);
const Run = base.Harness(State, Ui, .{ .nodes = 64, .texts = 16, .customs = 1, .strings = 2048, .depth = 12, .anims = 1, .tweens = 1, .flips = 1, .signals = 1, .timers = 1 });

fn aim(output: Run.Pair, id: types.Id) [2]f32 {
    const rect = output.runtime.tree.rect(output.runtime.tree.find(id));
    return .{ (rect.x0 + rect.x1) / 2, (rect.y0 + rect.y1) / 2 };
}

test "recipe controls: runtime/comptime draw and behavior parity through click, drag, text and theme changes" {
    @setEvalBranchQuota(200_000);
    const Saved = struct {
        var run: Run = .{};
    };
    const run = &Saved.run;
    run.init();
    var input: Input = .{ .viewport = .{ 320, 400 } };
    var output = try run.frame(&input);
    inline for (.{ "save", "check", "switch", "slider", "field" }) |name| {
        input.pointer = aim(output, .from(name));
        input.buttons.left = true;
        output = try run.frame(&input);
        input.buttons.left = false;
        output = try run.frame(&input);
        try std.testing.expectEqual(run.app.checked, run.ui.signals.state.checked);
        try std.testing.expectEqual(run.app.switched, run.ui.signals.state.switched);
        try std.testing.expectEqual(run.app.volume, run.ui.signals.state.volume);
        try std.testing.expectEqual(@as(?anyerror, null), output.comptime_.failure);
    }
    try std.testing.expectEqual(Ui.Events.Widget.field, run.ui.focus.?);
    try std.testing.expectEqual(@backingInt(types.Id.from("field")), run.ctx.inter.focus);
    input.text = "Hello";
    input.events = &.{.{ .kind = .text, .at = 0, .len = 5 }};
    output = try run.frame(&input);
    try std.testing.expectEqualStrings(run.app.field.text(), run.ui.signals.state.field.text());
    try std.testing.expectEqualStrings("Hello", run.app.field.text());
    input.text = "";
    input.events = &.{};
    run.app.environment = .{ .text_scale = 2, .high_contrast = true, .reduced_transparency = true };
    run.ui.signals.set(.environment, run.app.environment);
    output = try run.frame(&input);
    try std.testing.expectEqual(@as(f32, 28), output.runtime.texts.c.px[0]);
    try std.testing.expectEqual(@as(?anyerror, null), output.comptime_.failure);
}

test "forced color selection uses HighlightText in both front ends without duplicate semantics" {
    @setEvalBranchQuota(200_000);
    const Saved = struct {
        var run: Run = .{};
    };
    const run = &Saved.run;
    run.init();
    run.app.field = textfield_zig.Text(64).init("office");
    run.app.field.editor().anchor = 1;
    run.app.field.editor().caret = 4;
    run.app.environment = .{ .dark = false, .forced_colors = true };
    run.ui.signals.set(.field, run.app.field);
    run.ui.signals.set(.environment, run.app.environment);
    const input: Input = .{ .viewport = .{ 320, 400 } };
    const output = try run.frame(&input);
    const colors = style.system_colors.highContrast(false);
    var found = false;
    for (output.runtime.draw.runs[0..output.runtime.draw.run_len]) |text_run| {
        if (text_run.color == colors.get(.highlight_text).bitsOf()) found = true;
    }
    try std.testing.expect(found);
    const field_row = output.runtime.tree.find(.from("field"));
    var text_nodes: usize = 0;
    var semantic_nodes: usize = 0;
    for (field_row + 1..output.runtime.tree.c.end[field_row]) |row| {
        if (output.runtime.tree.c.text[row] != types.none) {
            text_nodes += 1;
            semantic_nodes += @intFromBool(output.runtime.tree.participation(@intCast(row)).semantics);
        }
    }
    try std.testing.expect(text_nodes >= 3);
    try std.testing.expectEqual(@as(usize, 1), semantic_nodes);
    try std.testing.expect(output.runtime.status.ok());
}

test "recipe disabled state cancels capture, skips Tab and cannot be defeated by a visual override" {
    @setEvalBranchQuota(200_000);
    const Saved = struct {
        var run: Run = .{};
    };
    const run = &Saved.run;
    run.init();
    var input: Input = .{ .viewport = .{ 320, 400 } };
    var output = try run.frame(&input);
    input.pointer = aim(output, .from("save"));
    input.buttons.left = true;
    output = try run.frame(&input);
    run.app.button_state.disabled = true;
    run.ui.signals.set(.button_state, run.app.button_state);
    output = try run.frame(&input);
    try std.testing.expectEqual(@as(?Ui.Events.Event, null), output.comptime_.event);
    run.app.button_state.disabled = false;
    run.ui.signals.set(.button_state, run.app.button_state);
    _ = try run.frame(&input);
    input.buttons.left = false;
    output = try run.frame(&input);
    try std.testing.expect(!run.app.activated);
    try std.testing.expectEqual(@as(?Ui.Events.Event, null), output.comptime_.event);
    run.app.button_state.disabled = true;
    run.ui.signals.set(.button_state, run.app.button_state);
    _ = try run.frame(&input);
    input.events = &.{.{ .kind = .press, .code = (@import("../interact/focus.zig").Keymap{}).tab }};
    output = try run.frame(&input);
    try std.testing.expectEqual(Ui.Events.Widget.check, run.ui.focus.?);
    try std.testing.expectEqual(@backingInt(types.Id.from("check")), run.ctx.inter.focus);
}

test "recipe read-only checkbox remains focusable and its pointer event is explicitly suppressed" {
    @setEvalBranchQuota(200_000);
    const Saved = struct {
        var run: Run = .{};
    };
    const run = &Saved.run;
    run.init();
    run.app.control_state.read_only = true;
    run.ui.signals.set(.control_state, run.app.control_state);
    var input: Input = .{ .viewport = .{ 320, 400 } };
    var output = try run.frame(&input);
    input.pointer = aim(output, .from("check"));
    input.buttons.left = true;
    output = try run.frame(&input);
    input.buttons.left = false;
    output = try run.frame(&input);
    try std.testing.expectEqual(checkbox_zig.Check.mixed, run.app.checked);
    try std.testing.expectEqual(run.app.checked, run.ui.signals.state.checked);
    try std.testing.expectEqual(Ui.Events.Widget.check, run.ui.focus.?);
    try std.testing.expectEqual(@as(?Ui.Events.Event, null), output.comptime_.event);
    input.events = &.{.{ .kind = .release, .code = keys.space }};
    output = try run.frame(&input);
    try std.testing.expectEqual(@as(?Ui.Events.Event, null), output.comptime_.event);
    try std.testing.expectEqual(checkbox_zig.Check.mixed, run.app.checked);
}

test "recipe participation cancels release actions and explicit cursor wins in both front ends" {
    @setEvalBranchQuota(200_000);
    const Saved = struct {
        var run: Run = .{};
    };
    const run = &Saved.run;
    run.init();
    run.app.button_state.selected = true;
    run.ui.signals.set(.button_state, run.app.button_state);
    var input: Input = .{ .viewport = .{ 320, 400 } };
    var output = try run.frame(&input);
    input.pointer = aim(output, .from("save"));
    output = try run.frame(&input);
    try std.testing.expectEqual(types.Cursor.crosshair, output.runtime.platform.cursor);
    try std.testing.expectEqual(types.Cursor.crosshair, output.comptime_.cursor);
    input.buttons.left = true;
    _ = try run.frame(&input);
    run.app.button_state.busy = true;
    run.ui.signals.set(.button_state, run.app.button_state);
    input.buttons.left = false;
    output = try run.frame(&input);
    try std.testing.expect(!run.app.activated);
    try std.testing.expectEqual(@as(?Ui.Events.Event, null), output.comptime_.event);
    try std.testing.expectEqual(types.Cursor.arrow, output.comptime_.cursor);
}

test "a runtime token error in a comptime recipe is returned as frame data" {
    const ErrorCase = struct {
        const declarations = [_]style.Declaration{style.token(.fill, .from("not-defined"))};
        const rules = [_]style.Rule{.{ .declarations = &declarations }};
        const State_ = struct {
            text: []const u8 = "Try",
            recipe: model.Recipe = .{ .parts = model.button.parts, .rules = &rules },
        };
    };
    const ErrorUi = base.ComptimeUi(ErrorCase.State_, ct.button(.try_it, .text, .{ .recipe_field = "recipe" }), .default);
    var ui: ErrorUi = .{};
    const output = ui.frame(&.{ .viewport = .{ 320, 100 } });
    try std.testing.expectEqual(@as(?anyerror, error.MissingToken), output.failure);
    ui.signals.set(.recipe, model.button);
    try std.testing.expectEqual(@as(?anyerror, null), ui.frame(&.{}).failure);
}
