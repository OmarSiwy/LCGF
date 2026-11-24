//! Feature ViewModel: commands edit feature state or return application requests as data.
//! It owns no selected page and cannot navigate. The Coordinator decides all app flow.
const common = @import("../common.zig");
const Model = @import("model.zig").Model;

pub const Effect = struct {
    changed: bool = false,
    request: ?common.Request = null,
};

pub const ViewModel = struct {
    sidebar: common.sidebar.State = .{},
    topbar: common.topbar.State = .{},
    cache: common.workspace.presenter.Cache = .{},
    command_overflow: bool = false,

    pub fn project(self: *ViewModel, model: *const Model, page: common.Page) common.Projection {
        _ = self.cache.refresh(&model.workspace.store, page);
        return common.project(model, &self.sidebar, &self.topbar, &self.cache, page, self.command_overflow);
    }

    pub fn sidebarCommand(self: *ViewModel, action: common.sidebar.Action) Effect {
        return switch (action) {
            .toggle => .{ .changed = self.toggleSidebar() },
            .navigate => |page| .{ .request = .{ .navigate = page } },
        };
    }

    pub fn topbarCommand(self: *ViewModel, action: common.topbar.Action) Effect {
        return switch (action) {
            .toggle_theme => .{ .changed = common.topbar.interactor.reduce(&self.topbar, .toggle_theme) },
            .advance => .{ .request = .advance },
            .toggle_sidebar => .{ .request = .toggle_sidebar },
        };
    }

    /// Feature commands run here, including commands requested by the Coordinator.
    pub fn workspaceCommand(_: *ViewModel, model: *Model, action: common.workspace.Action) bool {
        return model.apply(action);
    }

    pub fn toggleSidebar(self: *ViewModel) bool {
        return common.sidebar.interactor.reduce(&self.sidebar, .toggle);
    }
};
