//! MVVP is this project's explicitly defined Model-View-ViewModel-Presenter hybrid.
//! The ViewModel owns chrome state and cached projections. It cannot mutate the model;
//! domain and navigation requests go to the Presenter that coordinates the two owners.
const common = @import("../common.zig");
const Model = @import("model.zig").Model;

pub const Change = struct {
    changed: bool = false,
    request: ?common.Request = null,
};

pub const ViewModel = struct {
    page: common.Page = .all,
    sidebar: common.sidebar.State = .{},
    topbar: common.topbar.State = .{},
    cache: common.workspace.presenter.Cache = .{},
    command_overflow: bool = false,

    pub fn project(self: *ViewModel, model: *const Model) common.Projection {
        _ = self.cache.refresh(&model.workspace.store, self.page);
        return common.project(model, &self.sidebar, &self.topbar, &self.cache, self.page, self.command_overflow);
    }

    pub fn sidebarCommand(self: *ViewModel, action: common.sidebar.Action) Change {
        return switch (action) {
            .toggle => .{ .changed = common.sidebar.interactor.reduce(&self.sidebar, .toggle) },
            .navigate => |page| .{ .request = .{ .navigate = page } },
        };
    }

    pub fn topbarCommand(self: *ViewModel, action: common.topbar.Action) Change {
        return switch (action) {
            .toggle_theme => .{ .changed = common.topbar.interactor.reduce(&self.topbar, .toggle_theme) },
            .advance => .{ .request = .advance },
            .toggle_sidebar => .{ .request = .toggle_sidebar },
        };
    }
};
