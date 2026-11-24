//! MVVM entry point: a model and a command-bearing ViewModel, with no coordinator/presenter.
const common = @import("../common.zig");
pub const model = @import("model.zig");
pub const view_model = @import("view_model.zig");
pub const view = @import("view.zig");

pub const App = struct {
    model: model.Model = .{},
    view_model: view_model.ViewModel = .{},

    pub fn init(self: *App) void {
        self.initCount(common.config.initial_items);
    }
    pub fn initCount(self: *App, count: u32) void {
        self.view_model.initModel(&self.model, count);
    }
    pub fn build(self: *App, f: *common.Frame, _: *const common.Events) void {
        view.draw(f, &self.model, &self.view_model);
    }
    pub fn commit(self: *App, sides: []const common.sidebar.Action, tops: []const common.topbar.Action, work: []const common.workspace.Action) bool {
        return self.view_model.commit(&self.model, sides, tops, work);
    }
    pub fn snapshot(self: *const App) common.Snapshot {
        const presentation = &self.view_model;
        return common.snapshot(&self.model, &presentation.sidebar, &presentation.topbar, &presentation.cache, presentation.page, presentation.command_overflow);
    }
};
