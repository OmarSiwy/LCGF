//! Generic comptime consumers for named recipe parts. Container shape is still a Spec;
//! values, states, environment and tokens may be caller-owned runtime data. No registry or
//! compiler-only styling language is required. Inheritance is an explicit parent part.

const std = @import("std");
const types = @import("../core/types.zig");
const Input = @import("../core/input.zig").Input;
const style = @import("../style/style.zig");
const model = @import("recipe.zig");
const controls = @import("recipe_comptime.zig");
const base = @import("../widgets/base.zig");
const specs = @import("../comptime/spec.zig");
const a11y = @import("../a11y/tree.zig");

pub const Options = struct {
    controls: controls.Config = .{},
    /// The parent part's typography/cursor is resolved explicitly. Default root; a label
    /// inside a styled data cell can name .cell. Set null for an independent part.
    parent_part: ?types.Id = style.Parts.root,
    role: ?a11y.Role = null,
};

pub fn container(comptime part: types.Id, comptime recipe: model.Recipe, comptime children: anytype, comptime options: Options) specs.Spec {
    var node = specs.col(.{}, children);
    node.widget = Part(part, recipe, options, null);
    return node;
}

pub fn label(comptime part: types.Id, comptime recipe: model.Recipe, comptime text: @EnumLiteral(), comptime options: Options) specs.Spec {
    return .{ .kind = .label, .bind = @tagName(text), .widget = Part(part, recipe, options, @tagName(text)) };
}

fn Part(comptime part: types.Id, comptime default_recipe: model.Recipe, comptime options: Options, comptime text: ?[]const u8) type {
    return struct {
        pub fn bindError(comptime State: type, comptime field: []const u8) ?[]const u8 {
            _ = field;
            const config = options.controls;
            if (config.states_field) |name| if (base.fieldError(State, "part states", name, style.States)) |err| return err;
            if (config.environment_field) |name| if (base.fieldError(State, "part environment", name, model.Environment)) |err| return err;
            if (config.tokens_field) |name| if (base.fieldError(State, "part tokens", name, style.tokens.Table)) |err| return err;
            if (config.recipe_field) |name| if (base.fieldError(State, "part recipe", name, model.Recipe)) |err| return err;
            if (text) |name| return base.fieldError(State, "part label", name, []const u8);
            return null;
        }

        fn computed(ui: anytype, in: *const Input) style.Error!style.Computed {
            const State = @TypeOf(ui.signals.state);
            comptime if (bindError(State, "")) |err| {
                @compileError(err);
            };
            const config = options.controls;
            const recipe = if (config.recipe_field) |field| @field(ui.signals.state, field) else config.recipe orelse default_recipe;
            var use: model.Use = .{
                .states = if (config.states_field) |field| @field(ui.signals.state, field) else config.states,
                .environment = if (config.environment_field) |field| @field(ui.signals.state, field) else config.environment orelse model.Environment.fromInput(in).withSettings(&ui.frame_settings),
                .tokens = if (config.tokens_field) |field| @field(ui.signals.state, field) else config.tokens,
                .scope = config.scope,
                .variants = config.variants,
                .color_policy = config.color_policy,
            };
            var parent: style.Computed = undefined;
            if (options.parent_part) |parent_part| {
                if (part != style.Parts.root) {
                    const root = try recipe.resolve(style.Parts.root, use, null);
                    use.parent = &root;
                    parent = if (parent_part == style.Parts.root) root else try recipe.resolve(parent_part, use, null);
                    use.parent = &parent;
                }
            }
            use.local = config.local;
            return recipe.resolve(part, use, null);
        }

        pub fn push(ui: anytype, comptime node: specs.Spec, parent: u32, next: *u32, in: *const Input) void {
            const resolved = computed(ui, in) catch |err| blk: {
                ui.fail(err);
                break :blk default_recipe.baseFor(part);
            };
            const tb = &ui.tables;
            const row = tb.t.push(parent, .none, &resolved.box);
            if (options.role) |role| tb.t.c.role[row] = @backingInt(role);
            next.* += 1;
            if (text) |field| {
                tb.t.c.text[row] = tb.tx.push(row, tb.strings.add(@field(ui.signals.state, field)), &resolved.text);
            } else inline for (node.children) |child| ui.push(child, row, next, in);
            tb.t.seal(row);
        }
    };
}

test "data part composition has runtime/comptime parity with dynamic state and environment" {
    @setEvalBranchQuota(200_000);
    const runtime = @import("recipe_parts.zig");
    const App = struct {
        title: []const u8 = "Shared part",
        states: style.States = .{ .selected = true },
        environment: model.Environment = .{},

        pub fn build(app: *@This(), frame: *@import("../runtime/frame.zig").Frame) void {
            const data = runtime.open(frame, .none, style.Parts.root, .{ .role = .table, .use = .{ .states = app.states, .environment = app.environment } }) catch unreachable;
            const row = runtime.dataRow(frame, &data, app.states) catch unreachable;
            _ = runtime.dataCell(frame, &row, app.title, app.states, false) catch unreachable;
            frame.close();
            frame.close();
        }
    };
    const shared: controls.Config = .{ .states_field = "states", .environment_field = "environment" };
    const page = container(style.Parts.root, model.data, .{
        container(style.Parts.row, model.data, .{
            container(style.Parts.cell, model.data, .{label(style.Parts.label, model.data, .title, .{ .controls = shared, .parent_part = style.Parts.cell })}, .{ .controls = shared, .role = .cell }),
        }, .{ .controls = shared, .role = .row }),
    }, .{ .controls = shared, .role = .table });
    const Ui = base.ComptimeUi(App, page, .default);
    const Run = base.Harness(App, Ui, .{ .nodes = 16, .texts = 2, .customs = 1, .strings = 128, .depth = 8, .anims = 1, .tweens = 1, .flips = 1, .signals = 1, .timers = 1 });
    const Saved = struct {
        var run: Run = .{};
    };
    const run = &Saved.run;
    run.init();
    const input: Input = .{ .viewport = .{ 200, 100 } };
    _ = try run.frame(&input);
    run.app.states.invalid = true;
    run.app.environment.text_scale = 2;
    run.ui.signals.set(.states, run.app.states);
    run.ui.signals.set(.environment, run.app.environment);
    const output = try run.frame(&input);
    try std.testing.expectEqual(@as(f32, 28), output.runtime.texts.c.px[0]);
    try std.testing.expectEqual(@as(?anyerror, null), output.comptime_.failure);
}

test {
    std.testing.refAllDecls(@This());
}
