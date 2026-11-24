//! Composition root: owns all persistent data and is the only place that knows sibling modules.
//! Views read one snapshot, then typed commands are reduced in a documented, deterministic order.
const lcgf = @import("lcgf");
const navigation = @import("core/navigation.zig");
const sidebar = @import("modules/sidebar/root.zig");
const topbar = @import("modules/topbar/root.zig");
const workspace = @import("modules/workspace/root.zig");
const theme_zig = @import("ui/theme.zig");
const config = @import("config.zig");

pub const App = struct {
    ready: bool = false,
    page: navigation.Page = .all,
    sidebar: sidebar.State = .{},
    topbar: topbar.State = .{},
    workspace: workspace.State = .{},
    cache: workspace.presenter.Cache = .{},
    /// A failed bounded command batch is rejected in its entirety and shown in the UI.
    command_overflow: bool = false,

    /// The same read-only observation contract used by the alternative architectures.
    pub fn snapshot(self: *const App) @import("architectures/common.zig").Snapshot {
        const store = &self.workspace.store;
        return .{
            .page = self.page,
            .collapsed = self.sidebar.collapsed,
            .dark = self.topbar.dark,
            .selected = self.workspace.selected,
            .scroll = self.workspace.scroll,
            .total = store.len,
            .revision = store.revision,
            .completed = self.cache.completed,
            .visible_count = self.cache.len,
            .projection_builds = self.cache.rebuilds,
            .command_overflow = self.command_overflow,
            .progress = store.progress[0..store.len],
            .active = store.active[0..store.len],
        };
    }

    pub fn init(self: *App) void {
        self.initCount(config.initial_items);
    }

    pub fn initCount(self: *App, count: u32) void {
        self.workspace.store.init(count);
        self.workspace.selected = null;
        self.workspace.scroll = 0;
        self.cache = .{};
        self.ready = true;
    }

    pub fn build(self: *App, f: *lcgf.frame.Frame, _: *const lcgf.shell_iface.Events) void {
        if (!self.ready) self.init();
        _ = self.cache.refresh(&self.workspace.store, self.page);
        const theme = theme_zig.make(self.topbar.dark);
        var side_commands: sidebar.Commands = .{};
        var top_commands: topbar.Commands = .{};
        var work_commands: workspace.Commands = .{};

        _ = f.open(.from("application"), .{ .size = .{ .fill, .fill }, .gap = 1, .fill = theme.control_held });
        defer f.close();
        var failed = false;
        topbar.draw(f, &theme, topbar.presenter.make(&self.topbar, self.page, self.workspace.store.len, self.cache.completed), &top_commands) catch {
            failed = true;
        };
        {
            _ = f.open(.from("application.body"), .{ .dir = .x, .size = .{ .fill, .fill }, .gap = 1 });
            defer f.close();
            sidebar.draw(f, &theme, sidebar.presenter.make(&self.sidebar, self.page), &side_commands) catch {
                failed = true;
            };
            workspace.draw(f, &theme, workspace.presenter.make(&self.workspace, &self.cache), &work_commands) catch {
                failed = true;
            };
        }
        if (self.command_overflow) _ = lcgf.widgets_base.label(f, &theme, "Command capacity exceeded. The whole input batch was rejected; raise its budget.");

        if (failed) {
            if (!self.command_overflow) f.ctx.waker.post();
            self.command_overflow = true;
            return;
        }
        const changed = self.commit(side_commands.items(), top_commands.items(), work_commands.items());

        // finish() clears signals.dirty. An explicit Wake survives it and schedules the frame
        // that will render the committed state, even when the pointer has already gone idle.
        if (changed) f.ctx.waker.post();
    }

    /// Batch order is sidebar, topbar, workspace. Navigation wins over an old page's scroll
    /// intent; selections already contain stable IDs and remain valid across page changes.
    pub fn commit(self: *App, side_actions: []const sidebar.Action, top_actions: []const topbar.Action, work_actions: []const workspace.Action) bool {
        const old_page = self.page;
        var changed = false;
        // Preserve evaluation of every reducer; `changed or reduce()` would short-circuit.
        for (side_actions) |action| changed = self.dispatchSidebar(action) or changed;
        for (top_actions) |action| changed = self.dispatchTopbar(action) or changed;
        for (work_actions) |action| {
            if (action == .scroll and self.page != old_page) continue;
            changed = self.dispatchWorkspace(action) or changed;
        }
        return changed;
    }

    pub fn dispatchSidebar(self: *App, action: sidebar.Action) bool {
        var changed = sidebar.interactor.reduce(&self.sidebar, action);
        if (sidebar.router.route(action)) |request| changed = self.route(request) or changed;
        return changed;
    }

    pub fn dispatchTopbar(self: *App, action: topbar.Action) bool {
        var changed = topbar.interactor.reduce(&self.topbar, action);
        if (topbar.router.route(action)) |request| changed = self.route(request) or changed;
        return changed;
    }

    pub fn dispatchWorkspace(self: *App, action: workspace.Action) bool {
        var changed = workspace.interactor.reduce(&self.workspace, action);
        if (workspace.router.route(action)) |request| changed = self.route(request) or changed;
        return changed;
    }

    pub fn route(self: *App, request: navigation.Request) bool {
        return switch (request) {
            .navigate => |page| blk: {
                if (self.page == page) break :blk false;
                self.page = page;
                _ = workspace.interactor.reduce(&self.workspace, .reset_scroll);
                break :blk true;
            },
            .advance => workspace.interactor.reduce(&self.workspace, .advance),
            .toggle_sidebar => sidebar.interactor.reduce(&self.sidebar, .toggle),
        };
    }
};
