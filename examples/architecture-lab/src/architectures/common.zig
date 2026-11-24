//! Shared workload, not a shared controller. Every architecture draws these same feature
//! views and uses the same entities and business rules, so comparisons isolate orchestration.
const lcgf = @import("lcgf");
const theme_zig = @import("../ui/theme.zig");
pub const config = @import("../config.zig");
pub const navigation = @import("../core/navigation.zig");
pub const sidebar = @import("../modules/sidebar/root.zig");
pub const topbar = @import("../modules/topbar/root.zig");
pub const workspace = @import("../modules/workspace/root.zig");
pub const Frame = lcgf.frame.Frame;
pub const Events = lcgf.shell_iface.Events;
pub const Page = navigation.Page;
pub const Request = navigation.Request;

/// Ownership types live in a framework-free import path; these aliases preserve one identity.
pub const Model = @import("domain.zig").Model;
pub const State = @import("domain.zig").State;

/// Ephemeral frame projection. Its workspace pointers/slices borrow model and cache until
/// the command phase; never retain this value across a mutation or an owner move.
pub const Projection = struct {
    theme: lcgf.widgets_base.Theme,
    sidebar: sidebar.Model,
    topbar: topbar.Model,
    workspace: workspace.Model,
    command_overflow: bool,
};

pub fn project(model: *const Model, side: *const sidebar.State, top: *const topbar.State, cache: *const workspace.presenter.Cache, page: Page, overflow: bool) Projection {
    return .{
        .theme = theme_zig.make(top.dark),
        .sidebar = sidebar.presenter.make(side, page),
        .topbar = topbar.presenter.make(top, page, model.workspace.store.len, cache.completed),
        .workspace = workspace.presenter.make(&model.workspace, cache),
        .command_overflow = overflow,
    };
}

/// Each view writes only its bounded typed queue. A failed queue rejects the whole frame's
/// actions; each architecture owns that decision and its scheduling, outside this renderer.
pub const Commands = struct {
    sidebar: sidebar.Commands = .{},
    topbar: topbar.Commands = .{},
    workspace: workspace.Commands = .{},
    failed: bool = false,
};

/// Exactly the original VIPER layout and shared feature view functions; no action dispatch.
pub fn draw(f: *Frame, projection: Projection) Commands {
    var commands: Commands = .{};
    const theme = &projection.theme;
    _ = f.open(.from("application"), .{ .size = .{ .fill, .fill }, .gap = 1, .fill = theme.control_held });
    defer f.close();
    topbar.draw(f, theme, projection.topbar, &commands.topbar) catch {
        commands.failed = true;
    };
    {
        _ = f.open(.from("application.body"), .{ .dir = .x, .size = .{ .fill, .fill }, .gap = 1 });
        defer f.close();
        sidebar.draw(f, theme, projection.sidebar, &commands.sidebar) catch {
            commands.failed = true;
        };
        workspace.draw(f, theme, projection.workspace, &commands.workspace) catch {
            commands.failed = true;
        };
    }
    if (projection.command_overflow) _ = lcgf.widgets_base.label(f, theme, "Command capacity exceeded. The whole input batch was rejected; raise its budget.");
    return commands;
}

/// Normalized read-only observation for tests and benchmarks. Column slices borrow the app;
/// summary/cache fields describe its most recent projection, which can lag a committed action.
pub const Snapshot = struct {
    page: Page,
    collapsed: bool,
    dark: bool,
    selected: ?workspace.entity.ItemId,
    scroll: f32,
    total: u32,
    revision: u64,
    completed: u32,
    visible_count: u32,
    projection_builds: u64,
    command_overflow: bool,
    progress: []const u16,
    active: []const bool,
};

pub fn snapshot(model: *const Model, side: *const sidebar.State, top: *const topbar.State, cache: *const workspace.presenter.Cache, page: Page, overflow: bool) Snapshot {
    const store = &model.workspace.store;
    return .{
        .page = page,
        .collapsed = side.collapsed,
        .dark = top.dark,
        .selected = model.workspace.selected,
        .scroll = model.workspace.scroll,
        .total = store.len,
        .revision = store.revision,
        .completed = cache.completed,
        .visible_count = cache.len,
        .projection_builds = cache.rebuilds,
        .command_overflow = overflow,
        .progress = store.progress[0..store.len],
        .active = store.active[0..store.len],
    };
}
