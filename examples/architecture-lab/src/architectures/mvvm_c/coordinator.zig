//! Sole owner of navigation/application flow. Feature ViewModels emit requests and this
//! Coordinator interprets them; it has no Frame, renderer, callback list, or allocation.
const common = @import("../common.zig");
const Model = @import("model.zig").Model;
const vm = @import("view_model.zig");

pub const Coordinator = struct {
    page: common.Page = .all,

    pub fn commit(self: *Coordinator, model: *Model, presentation: *vm.ViewModel, sides: []const common.sidebar.Action, tops: []const common.topbar.Action, work: []const common.workspace.Action) bool {
        const old_page = self.page;
        var changed = false;
        for (sides) |action| changed = self.resolve(model, presentation, presentation.sidebarCommand(action)) or changed;
        for (tops) |action| changed = self.resolve(model, presentation, presentation.topbarCommand(action)) or changed;
        for (work) |action| {
            if (action == .scroll and self.page != old_page) continue;
            changed = presentation.workspaceCommand(model, action) or changed;
        }
        return changed;
    }

    fn resolve(self: *Coordinator, model: *Model, presentation: *vm.ViewModel, effect: vm.Effect) bool {
        var changed = effect.changed;
        if (effect.request) |request| changed = self.route(model, presentation, request) or changed;
        return changed;
    }

    pub fn route(self: *Coordinator, model: *Model, presentation: *vm.ViewModel, request: common.Request) bool {
        return switch (request) {
            .navigate => |page| blk: {
                if (self.page == page) break :blk false;
                self.page = page;
                _ = presentation.workspaceCommand(model, .reset_scroll);
                break :blk true;
            },
            .advance => presentation.workspaceCommand(model, .advance),
            .toggle_sidebar => presentation.toggleSidebar(),
        };
    }
};
