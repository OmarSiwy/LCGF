//! One behavioral/rendering contract across distinct controllers. These serial tests use two
//! independently owned LCGF buffers so the VIPER oracle stays live while a variant is rendered.
const std = @import("std");
const testing = std.testing;
const lcgf = @import("lcgf");
const common = @import("architectures/common.zig");
const Viper = @import("app.zig").App;
const Context = lcgf.context.Context;
const Input = lcgf.input.Input;
const Output = lcgf.context.Output;

var reference_memory: [Context.requiredBytes(common.config.limits)]u8 align(lcgf.mem.column_align) = undefined;
var candidate_memory: [Context.requiredBytes(common.config.limits)]u8 align(lcgf.mem.column_align) = undefined;

/// Normalize observations so all architecture owners expose the same read-only contract.
fn observe(app: anytype) common.Snapshot {
    if (@hasDecl(@TypeOf(app.*), "snapshot")) return app.snapshot();
    const store = &app.workspace.store;
    return .{
        .page = app.page,
        .collapsed = app.sidebar.collapsed,
        .dark = app.topbar.dark,
        .selected = app.workspace.selected,
        .scroll = app.workspace.scroll,
        .total = store.len,
        .revision = store.revision,
        .completed = app.cache.completed,
        .visible_count = app.cache.len,
        .projection_builds = app.cache.rebuilds,
        .command_overflow = app.command_overflow,
        .progress = store.progress[0..store.len],
        .active = store.active[0..store.len],
    };
}

fn step(ctx: *Context, app: anytype, input: Input) !Output {
    const events: common.Events = .{ .in = input };
    var frame = ctx.begin(&events.in);
    app.build(&frame, &events);
    const output = frame.end(.{});
    try testing.expect(output.status.ok());
    try testing.expect(!observe(app).command_overflow);
    return output;
}

fn center(output: Output, id: lcgf.types.Id) ![2]f32 {
    const node = output.tree.find(id);
    try testing.expect(node != lcgf.types.none);
    const rect = output.tree.rect(node);
    return .{ (rect.x0 + rect.x1) / 2, (rect.y0 + rect.y1) / 2 };
}

fn click(ctx: *Context, app: anytype, point: [2]f32) !Output {
    _ = try step(ctx, app, .{ .pointer = point });
    _ = try step(ctx, app, .{ .pointer = point, .buttons = .{ .left = true } });
    return step(ctx, app, .{ .pointer = point });
}

/// This example has no composite focus groups: every named focusable node is a Tab stop.
/// Derive the next stop from live tree order, independently of LCGF's SIMD focus search.
fn nextFocusId(output: Output, current_id: u32) !u32 {
    const tree = output.tree;
    const current = tree.find(@fromBackingInt(current_id));
    try testing.expect(current != lcgf.types.none);
    const focus_mask: u8 = @bitCast(lcgf.types.Sense{ .focus = true });
    for (1..tree.len + 1) |distance| {
        const row = (@as(usize, current) + distance) % tree.len;
        if (tree.c.id[row] != 0 and tree.c.sense[row] & focus_mask != 0) return tree.c.id[row];
    }
    return error.NoFocusableNode;
}

fn expectSameOutput(reference: Output, candidate: Output) !void {
    try testing.expectEqual(reference.tree.len, candidate.tree.len);
    const live = reference.tree.len;
    // Equal pixels alone cannot prove equal hit targets, focus stops, or accessibility roles.
    try testing.expectEqualSlices(u32, reference.tree.c.id[0..live], candidate.tree.c.id[0..live]);
    try testing.expectEqualSlices(u8, reference.tree.c.sense[0..live], candidate.tree.c.sense[0..live]);
    try testing.expectEqualSlices(u8, reference.tree.c.role[0..live], candidate.tree.c.role[0..live]);
    try testing.expectEqual(reference.platform.cursor, candidate.platform.cursor);
    try testing.expect(lcgf.widgets_base.sameDraw(reference.draw, candidate.draw));
    // LCGF's sameDraw compares runs, geometry and command order; also verify actual strings.
    try testing.expectEqualStrings(reference.draw.strings, candidate.draw.strings);
    try testing.expectEqual(reference.wake, candidate.wake);
    try testing.expectEqual(reference.pace, candidate.pace);
}

fn expectSameState(reference: *const Viper, candidate: anytype) !void {
    const a = observe(reference);
    const b = observe(candidate);
    try testing.expectEqual(a.page, b.page);
    try testing.expectEqual(a.collapsed, b.collapsed);
    try testing.expectEqual(a.dark, b.dark);
    try testing.expectEqual(a.selected, b.selected);
    try testing.expectEqual(a.scroll, b.scroll);
    try testing.expectEqual(a.total, b.total);
    try testing.expectEqual(a.revision, b.revision);
    try testing.expectEqual(a.completed, b.completed);
    try testing.expectEqual(a.visible_count, b.visible_count);
    try testing.expectEqual(a.projection_builds, b.projection_builds);
    try testing.expectEqual(a.command_overflow, b.command_overflow);
    try testing.expectEqualSlices(u16, a.progress, b.progress);
    try testing.expectEqualSlices(bool, a.active, b.active);
}

/// Run identical real input and direct command-boundary edge cases against VIPER.
fn checkContract(comptime Application: type) !void {
    var reference: Viper = .{};
    var candidate: Application = .{};
    reference.initCount(1000);
    candidate.initCount(1000);
    var ref_ctx = try Context.init(&reference_memory, common.config.limits);
    var ctx = try Context.init(&candidate_memory, common.config.limits);
    var ref_out = try step(&ref_ctx, &reference, .{});
    var out = try step(&ctx, &candidate, .{});
    try expectSameOutput(ref_out, out);
    try expectSameState(&reference, &candidate);
    const small_count = out.tree.len;
    const roots = [_]lcgf.types.Id{ .from("application"), .from("application.body"), .from("topbar"), .from("sidebar"), .from("workspace"), common.workspace.view.table_id };
    for (roots) |id| try testing.expect(out.tree.find(id) != lcgf.types.none);
    try testing.expect(out.draw.cmd_len > 0);

    // Reach Menu using only Tab, without assuming which stop receives the initial focus.
    // Once focus exists, verify each subsequent stop and wrap against the live tree order.
    const tab: Input.Event = .{ .kind = .press, .code = 43 };
    const tab_up: Input.Event = .{ .kind = .release, .code = 43 };
    ref_out = try step(&ref_ctx, &reference, .{ .events = &.{tab} });
    out = try step(&ctx, &candidate, .{ .events = &.{tab} });
    try expectSameOutput(ref_out, out);
    try testing.expectEqual(ref_ctx.inter.focus, ctx.inter.focus);
    const first_focus = out.tree.find(@fromBackingInt(ctx.inter.focus));
    try testing.expect(ctx.inter.focus != 0 and first_focus != lcgf.types.none);
    const focus_mask: u8 = @bitCast(lcgf.types.Sense{ .focus = true });
    try testing.expect(out.tree.c.sense[first_focus] & focus_mask != 0);
    var stop_count: u32 = 0;
    for (out.tree.c.id[0..out.tree.len], out.tree.c.sense[0..out.tree.len]) |id, sense|
        stop_count += @intFromBool(id != 0 and sense & focus_mask != 0);
    var visited: u32 = 0;
    while (ctx.inter.focus != @backingInt(common.topbar.view.sidebar_id) and visited < stop_count) : (visited += 1) {
        const previous_focus = ctx.inter.focus;
        const expected_focus = try nextFocusId(out, previous_focus);
        ref_out = try step(&ref_ctx, &reference, .{ .events = &.{tab_up} });
        out = try step(&ctx, &candidate, .{ .events = &.{tab_up} });
        try expectSameOutput(ref_out, out);
        try testing.expectEqual(previous_focus, ctx.inter.focus);
        ref_out = try step(&ref_ctx, &reference, .{ .events = &.{tab} });
        out = try step(&ctx, &candidate, .{ .events = &.{tab} });
        try expectSameOutput(ref_out, out);
        try testing.expectEqual(expected_focus, ctx.inter.focus);
        try testing.expectEqual(ref_ctx.inter.focus, ctx.inter.focus);
    }
    try testing.expectEqual(@backingInt(common.topbar.view.sidebar_id), ctx.inter.focus);
    try testing.expect(ctx.focus.visible);
    const focused_node = out.tree.find(common.topbar.view.sidebar_id);
    try testing.expect(focused_node != lcgf.types.none);
    // Check a visible effect, not merely the internal focus-visible flag.
    try testing.expect(out.tree.border(focused_node) > 0);
    const space: Input.Event = .{ .kind = .press, .code = 44 };
    ref_out = try step(&ref_ctx, &reference, .{ .events = &.{space} });
    out = try step(&ctx, &candidate, .{ .events = &.{space} });
    try expectSameOutput(ref_out, out);
    try expectSameState(&reference, &candidate);
    try testing.expect(candidate.snapshot().collapsed);
    const space_up: Input.Event = .{ .kind = .release, .code = 44 };
    ref_out = try step(&ref_ctx, &reference, .{ .events = &.{space_up} });
    out = try step(&ctx, &candidate, .{ .events = &.{space_up} });
    try expectSameOutput(ref_out, out);
    try testing.expect(candidate.snapshot().collapsed);
    // A second distinct press restores the initial chrome before later pointer scenarios.
    ref_out = try step(&ref_ctx, &reference, .{ .events = &.{space} });
    out = try step(&ctx, &candidate, .{ .events = &.{space} });
    try expectSameState(&reference, &candidate);
    try testing.expect(!candidate.snapshot().collapsed);
    ref_out = try step(&ref_ctx, &reference, .{});
    out = try step(&ctx, &candidate, .{});
    try expectSameOutput(ref_out, out);
    try testing.expectEqual(.all, candidate.snapshot().page);
    try testing.expect(candidate.snapshot().selected == null);
    try testing.expect(candidate.snapshot().dark);

    // Drive the virtualized table through actual wheel/click/key input, not direct commits.
    // These view changes must not rescan the domain's filtered index cache.
    const initial_rebuilds = candidate.snapshot().projection_builds;
    const table_node = out.tree.find(common.workspace.view.table_id);
    try testing.expect(table_node != lcgf.types.none);
    const table_rect = out.tree.rect(table_node);
    const table_point: [2]f32 = .{ table_rect.x0 + 40, table_rect.y0 + 12 };
    ref_out = try step(&ref_ctx, &reference, .{ .pointer = table_point, .wheel = .{ 0, 50 } });
    out = try step(&ctx, &candidate, .{ .pointer = table_point, .wheel = .{ 0, 50 } });
    try expectSameOutput(ref_out, out);
    try expectSameState(&reference, &candidate);
    try testing.expect(candidate.snapshot().scroll > 0);
    ref_out = try step(&ref_ctx, &reference, .{ .pointer = table_point });
    out = try step(&ctx, &candidate, .{ .pointer = table_point });
    try expectSameOutput(ref_out, out);
    ref_out = try click(&ref_ctx, &reference, table_point);
    out = try click(&ctx, &candidate, table_point);
    try expectSameOutput(ref_out, out);
    try expectSameState(&reference, &candidate);
    try testing.expectEqual(@as(u32, 51), @backingInt(candidate.snapshot().selected.?));
    const end: Input.Event = .{ .kind = .press, .code = 0x4d };
    ref_out = try step(&ref_ctx, &reference, .{ .events = &.{end} });
    out = try step(&ctx, &candidate, .{ .events = &.{end} });
    try expectSameOutput(ref_out, out);
    try expectSameState(&reference, &candidate);
    try testing.expectEqual(candidate.snapshot().total, @backingInt(candidate.snapshot().selected.?));
    ref_out = try step(&ref_ctx, &reference, .{});
    out = try step(&ctx, &candidate, .{});
    try expectSameOutput(ref_out, out);
    try testing.expect(out.tree.find(common.workspace.view.rowId(candidate.snapshot().selected.?)) != lcgf.types.none);
    const home: Input.Event = .{ .kind = .press, .code = 0x4a };
    ref_out = try step(&ref_ctx, &reference, .{ .events = &.{home} });
    out = try step(&ctx, &candidate, .{ .events = &.{home} });
    try expectSameOutput(ref_out, out);
    try expectSameState(&reference, &candidate);
    try testing.expectEqual(@as(u32, 1), @backingInt(candidate.snapshot().selected.?));
    try testing.expectEqual(@as(f32, 0), candidate.snapshot().scroll);
    try testing.expectEqual(initial_rebuilds, candidate.snapshot().projection_builds);
    ref_out = try step(&ref_ctx, &reference, .{});
    out = try step(&ctx, &candidate, .{});
    try expectSameOutput(ref_out, out);

    // A real topbar click exercises the architecture's view-to-domain command path.
    const before_progress = candidate.snapshot().progress[1];
    const before_revision = candidate.snapshot().revision;
    var point = try center(out, common.topbar.view.advance_id);
    ref_out = try click(&ref_ctx, &reference, point);
    out = try click(&ctx, &candidate, point);
    try expectSameOutput(ref_out, out);
    try expectSameState(&reference, &candidate);
    try testing.expect(candidate.snapshot().progress[1] > before_progress);
    try testing.expect(candidate.snapshot().revision > before_revision);
    ref_out = try step(&ref_ctx, &reference, .{});
    out = try step(&ctx, &candidate, .{});
    try expectSameOutput(ref_out, out);

    // Navigation is visible on the explicitly scheduled follow-up frame.
    point = try center(out, common.sidebar.view.pageId(.running));
    ref_out = try click(&ref_ctx, &reference, point);
    out = try click(&ctx, &candidate, point);
    try expectSameOutput(ref_out, out);
    try expectSameState(&reference, &candidate);
    try testing.expectEqual(.running, candidate.snapshot().page);
    try testing.expect(ctx.waker.flag.load(.acquire));
    try testing.expectEqual(@as(f32, 0), out.wake);
    ref_out = try step(&ref_ctx, &reference, .{});
    out = try step(&ctx, &candidate, .{});
    try expectSameOutput(ref_out, out);
    try expectSameState(&reference, &candidate);

    // UI-local state changes and focused keyboard activation follow the same routes.
    point = try center(out, common.topbar.view.theme_id);
    ref_out = try click(&ref_ctx, &reference, point);
    out = try click(&ctx, &candidate, point);
    try expectSameState(&reference, &candidate);
    try testing.expect(!candidate.snapshot().dark);
    const enter: Input.Event = .{ .kind = .press, .code = 40 };
    ref_out = try step(&ref_ctx, &reference, .{ .events = &.{enter} });
    out = try step(&ctx, &candidate, .{ .events = &.{enter} });
    try expectSameOutput(ref_out, out);
    try testing.expect(candidate.snapshot().dark);
    const repeat: Input.Event = .{ .kind = .repeat, .code = 40 };
    ref_out = try step(&ref_ctx, &reference, .{ .events = &.{repeat} });
    out = try step(&ctx, &candidate, .{ .events = &.{repeat} });
    try expectSameOutput(ref_out, out);
    try expectSameState(&reference, &candidate);
    try testing.expect(candidate.snapshot().dark);

    const selected: common.workspace.entity.ItemId = @fromBackingInt(9);
    const scroll_then_select = [_]common.workspace.Action{ .{ .scroll = 64 }, .{ .select = selected } };
    try testing.expect(reference.commit(&.{}, &.{}, &scroll_then_select));
    try testing.expect(candidate.commit(&.{}, &.{}, &scroll_then_select));
    try expectSameState(&reference, &candidate);
    const invalid_id: common.workspace.entity.ItemId = @fromBackingInt(1001);
    const invalid = [_]common.workspace.Action{ .{ .select = invalid_id }, .{ .scroll = std.math.nan(f32) }, .{ .scroll = std.math.inf(f32) } };
    try testing.expect(!reference.commit(&.{}, &.{}, &invalid));
    try testing.expect(!candidate.commit(&.{}, &.{}, &invalid));
    try expectSameState(&reference, &candidate);
    try testing.expectEqual(selected, candidate.snapshot().selected.?);
    try testing.expectEqual(@as(f32, 64), candidate.snapshot().scroll);

    // Intent ordering is part of the contract: new navigation rejects an old view's scroll.
    const navigation = [_]common.sidebar.Action{.{ .navigate = .completed }};
    const old_page_actions = [_]common.workspace.Action{ .{ .scroll = 2000 }, .{ .select = selected } };
    try testing.expect(reference.commit(&navigation, &.{}, &old_page_actions));
    try testing.expect(candidate.commit(&navigation, &.{}, &old_page_actions));
    try expectSameState(&reference, &candidate);
    try testing.expectEqual(.completed, candidate.snapshot().page);
    try testing.expectEqual(@as(f32, 0), candidate.snapshot().scroll);
    try testing.expectEqual(selected, candidate.snapshot().selected.?);
    ref_out = try step(&ref_ctx, &reference, .{});
    out = try step(&ctx, &candidate, .{});
    try expectSameOutput(ref_out, out);

    // Store size changes do not add off-screen UI nodes or per-record widget objects.
    reference.initCount(common.workspace.entity.capacity);
    candidate.initCount(common.workspace.entity.capacity);
    ref_ctx = try Context.init(&reference_memory, common.config.limits);
    ctx = try Context.init(&candidate_memory, common.config.limits);
    ref_out = try step(&ref_ctx, &reference, .{});
    out = try step(&ctx, &candidate, .{});
    try expectSameOutput(ref_out, out);
    try expectSameState(&reference, &candidate);
    try testing.expectEqual(small_count, out.tree.len);
    try testing.expect(out.tree.len < 200);

    // Empty filtered data is safe. With no new input, the common scheduler can sleep.
    reference.initCount(0);
    candidate.initCount(0);
    ref_ctx = try Context.init(&reference_memory, common.config.limits);
    ctx = try Context.init(&candidate_memory, common.config.limits);
    for (0..3) |_| {
        ref_out = try step(&ref_ctx, &reference, .{});
        out = try step(&ctx, &candidate, .{});
        try expectSameOutput(ref_out, out);
    }
    try expectSameState(&reference, &candidate);
    const input: Input = .{};
    try testing.expect(!ctx.needsFrame(&input));
    try testing.expectEqual(lcgf.types.inf, out.wake);
    try testing.expectEqual(lcgf.scheduler.Pace.idle, out.pace);
    try testing.expectEqual(@as(u32, 0), candidate.snapshot().visible_count);
    try testing.expect(candidate.snapshot().selected == null);
}

test "MVP matches VIPER drawing, commands, guards, virtualization and idle" {
    try checkContract(@import("architectures/mvp/root.zig").App);
}

test "MVVP hybrid matches VIPER drawing, commands, guards, virtualization and idle" {
    try checkContract(@import("architectures/mvvp/root.zig").App);
}

test "MVVM matches VIPER drawing, commands, guards, virtualization and idle" {
    try checkContract(@import("architectures/mvvm/root.zig").App);
}

test "MVVM-C matches VIPER drawing, commands, guards, virtualization and idle" {
    try checkContract(@import("architectures/mvvm_c/root.zig").App);
}
