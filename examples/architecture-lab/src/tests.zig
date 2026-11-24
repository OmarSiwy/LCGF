//! Tests exercise real LCGF input, hit testing, layout, drawing, and the scheduler.
//! The static fixture belongs to this serial test process; do not run it concurrently.
const std = @import("std");
const testing = std.testing;
const lcgf = @import("lcgf");
const host = @import("host");
const App = @import("app.zig").App;
const config = @import("config.zig");
const sidebar = @import("modules/sidebar/root.zig");
const topbar = @import("modules/topbar/root.zig");
const workspace = @import("modules/workspace/root.zig");
const Context = lcgf.context.Context;
const Input = lcgf.input.Input;
const Output = lcgf.context.Output;

var memory: [Context.requiredBytes(config.limits)]u8 align(lcgf.mem.column_align) = undefined;

fn step(ctx: *Context, app: *App, input: Input) !Output {
    const events: lcgf.shell_iface.Events = .{ .in = input };
    var frame = ctx.begin(&events.in);
    app.build(&frame, &events);
    const output = frame.end(.{});
    try testing.expect(output.status.ok());
    try testing.expect(!app.command_overflow);
    return output;
}

fn center(output: Output, id: lcgf.types.Id) ![2]f32 {
    const node = output.tree.find(id);
    try testing.expect(node != lcgf.types.none);
    return host.center(output.tree.rect(node));
}

fn click(ctx: *Context, app: *App, point: [2]f32) !Output {
    _ = try step(ctx, app, .{ .pointer = point });
    _ = try step(ctx, app, .{ .pointer = point, .buttons = .{ .left = true } });
    return step(ctx, app, .{ .pointer = point });
}

test "100000 records build a bounded UI and pixels through the real host" {
    var app: App = .{};
    app.init();
    const smoke = try host.Smoke.run(&app, "frame\nviewport 800 600\nframe\n");
    try testing.expectEqual(@as(u32, 100_000), app.workspace.store.len);
    try testing.expect(smoke.out.?.tree.len < 200);
    try testing.expect(smoke.out.?.draw.cmd_len > 0);
    try testing.expect(smoke.at(10, 10).a == 255);
    try testing.expectEqual(@as(u64, 1), app.cache.rebuilds);
}

test "node count stays independent of record count at a fixed viewport" {
    var app: App = .{};
    app.initCount(100);
    var ctx = try Context.init(&memory, config.limits);
    const small_count = (try step(&ctx, &app, .{})).tree.len;
    app.initCount(100_000);
    ctx = try Context.init(&memory, config.limits);
    const large_count = (try step(&ctx, &app, .{})).tree.len;
    try testing.expectEqual(small_count, large_count);
    _ = try step(&ctx, &app, .{ .viewport = .{ 1600, 1600 } });
}

test "sidebar click routes then explicitly schedules the committed view" {
    var app: App = .{};
    app.initCount(100);
    var ctx = try Context.init(&memory, config.limits);
    const output = try step(&ctx, &app, .{});
    const point = try center(output, sidebar.view.pageId(.running));
    const clicked = try click(&ctx, &app, point);
    try testing.expectEqual(.running, app.page);
    try testing.expectEqual(@as(f32, 0), clicked.wake);
    try testing.expect(ctx.waker.flag.load(.acquire));
    _ = try step(&ctx, &app, .{});
    try testing.expectEqual(.running, app.cache.page);
    for (app.cache.indices[0..app.cache.len]) |slot| try testing.expect(app.workspace.store.active[slot]);
}

test "topbar commands cross module boundary without mutating unrelated chrome" {
    var app: App = .{};
    app.initCount(30);
    var ctx = try Context.init(&memory, config.limits);
    var output = try step(&ctx, &app, .{});
    const before = app.workspace.store.progress[1];
    const revision = app.workspace.store.revision;
    _ = try click(&ctx, &app, try center(output, topbar.view.advance_id));
    try testing.expect(app.workspace.store.progress[1] > before);
    try testing.expect(app.workspace.store.revision > revision);
    output = try step(&ctx, &app, .{});
    _ = try click(&ctx, &app, try center(output, topbar.view.theme_id));
    try testing.expect(!app.topbar.dark);
    output = try step(&ctx, &app, .{});
    _ = try click(&ctx, &app, try center(output, topbar.view.sidebar_id));
    try testing.expect(app.sidebar.collapsed);
}

test "virtual table wheel, stable selection and keyboard navigation work" {
    var app: App = .{};
    app.init();
    var ctx = try Context.init(&memory, config.limits);
    var output = try step(&ctx, &app, .{});
    const rect = output.tree.rect(output.tree.find(workspace.view.table_id));
    const point: [2]f32 = .{ rect.x0 + 40, rect.y0 + 12 };
    _ = try step(&ctx, &app, .{ .pointer = point, .wheel = .{ 0, 50_000 } });
    output = try step(&ctx, &app, .{ .pointer = point });
    _ = try click(&ctx, &app, point);
    try testing.expectEqual(@as(u32, 50_001), @backingInt(app.workspace.selected.?));
    const after_click_rebuilds = app.cache.rebuilds;

    const end: Input.Event = .{ .kind = .press, .code = 0x4d };
    _ = try step(&ctx, &app, .{ .events = &.{end} });
    try testing.expectEqual(@as(u32, 100_000), @backingInt(app.workspace.selected.?));
    output = try step(&ctx, &app, .{});
    try testing.expect(output.tree.find(workspace.view.rowId(app.workspace.selected.?)) != lcgf.types.none);
    try testing.expectEqual(after_click_rebuilds, app.cache.rebuilds);

    const home: Input.Event = .{ .kind = .press, .code = 0x4a };
    _ = try step(&ctx, &app, .{ .events = &.{home} });
    try testing.expectEqual(@as(u32, 1), @backingInt(app.workspace.selected.?));
    try testing.expectEqual(@as(f32, 0), app.workspace.scroll);
}

test "navigation wins over old-page scrolling but preserves stable selection" {
    var app: App = .{};
    app.initCount(30);
    const selected = app.workspace.store.idAt(8);
    try testing.expect(app.commit(&.{.{ .navigate = .completed }}, &.{}, &.{ .{ .scroll = 2000 }, .{ .select = selected } }));
    try testing.expectEqual(.completed, app.page);
    try testing.expectEqual(@as(f32, 0), app.workspace.scroll);
    try testing.expectEqual(selected, app.workspace.selected.?);
}

test "focused button activates with Enter and ignores held-key repeats" {
    var app: App = .{};
    app.initCount(20);
    var ctx = try Context.init(&memory, config.limits);
    const output = try step(&ctx, &app, .{});
    _ = try click(&ctx, &app, try center(output, topbar.view.theme_id));
    try testing.expect(!app.topbar.dark);
    const enter: Input.Event = .{ .kind = .press, .code = 40 };
    _ = try step(&ctx, &app, .{ .events = &.{enter} });
    try testing.expect(app.topbar.dark);
    const repeat: Input.Event = .{ .kind = .repeat, .code = 40 };
    _ = try step(&ctx, &app, .{ .events = &.{repeat} });
    try testing.expect(app.topbar.dark);
}

test "empty filtered data is safe and idle settles without a polling frame" {
    var app: App = .{};
    app.initCount(0);
    var ctx = try Context.init(&memory, config.limits);
    _ = try step(&ctx, &app, .{});
    _ = try step(&ctx, &app, .{});
    const output = try step(&ctx, &app, .{});
    const input: Input = .{};
    try testing.expect(!ctx.needsFrame(&input));
    try testing.expectEqual(lcgf.types.inf, output.wake);
    try testing.expectEqual(lcgf.scheduler.Pace.idle, output.pace);
    try testing.expectEqual(@as(u32, 0), app.cache.len);
    try testing.expect(app.workspace.selected == null);
}

test {
    // Bring the pure module suites into the application test entry point too.
    _ = @import("core/commands.zig");
    _ = @import("modules/sidebar/interactor.zig");
    _ = @import("modules/sidebar/router.zig");
    _ = @import("modules/topbar/interactor.zig");
    _ = @import("modules/topbar/router.zig");
    _ = @import("modules/workspace/entity.zig");
    _ = @import("modules/workspace/interactor.zig");
    _ = @import("modules/workspace/presenter.zig");
}
