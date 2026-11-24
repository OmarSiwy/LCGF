//! Standard MVVM expressed with explicit value projections and statically dispatched commands.
//! This ViewModel owns presentation/navigation state and directly invokes model use cases.
//! There is no Presenter, Coordinator, observer graph, automatic binding, or hidden allocation.
const common = @import("../common.zig");
const Model = @import("model.zig").Model;

pub const ViewModel = struct {
    page: common.Page = .all,
    sidebar: common.sidebar.State = .{},
    topbar: common.topbar.State = .{},
    cache: common.workspace.presenter.Cache = .{},
    command_overflow: bool = false,

    pub fn initModel(self: *ViewModel, model: *Model, count: u32) void {
        model.initCount(count);
        self.cache = .{};
    }

    pub fn project(self: *ViewModel, model: *Model) common.Projection {
        if (!model.ready) self.initModel(model, common.config.initial_items);
        _ = self.cache.refresh(&model.workspace.store, self.page);
        return common.project(model, &self.sidebar, &self.topbar, &self.cache, self.page, self.command_overflow);
    }

    /// The view binds its result to this command boundary. No partial batch is committed.
    pub fn accept(self: *ViewModel, model: *Model, commands: *const common.Commands) bool {
        if (commands.failed) {
            const changed = !self.command_overflow;
            self.command_overflow = true;
            return changed;
        }
        return self.commit(model, commands.sidebar.items(), commands.topbar.items(), commands.workspace.items());
    }

    pub fn commit(self: *ViewModel, model: *Model, sides: []const common.sidebar.Action, tops: []const common.topbar.Action, work: []const common.workspace.Action) bool {
        const old_page = self.page;
        var changed = false;
        for (sides) |action| switch (action) {
            .toggle => changed = common.sidebar.interactor.reduce(&self.sidebar, .toggle) or changed,
            .navigate => |page| changed = self.navigate(model, page) or changed,
        };
        for (tops) |action| switch (action) {
            .toggle_theme => changed = common.topbar.interactor.reduce(&self.topbar, .toggle_theme) or changed,
            .toggle_sidebar => changed = common.sidebar.interactor.reduce(&self.sidebar, .toggle) or changed,
            .advance => changed = model.apply(.advance) or changed,
        };
        for (work) |action| {
            if (action == .scroll and self.page != old_page) continue;
            changed = model.apply(action) or changed;
        }
        return changed;
    }

    fn navigate(self: *ViewModel, model: *Model, page: common.Page) bool {
        if (self.page == page) return false;
        self.page = page;
        _ = model.apply(.reset_scroll);
        return true;
    }
};
