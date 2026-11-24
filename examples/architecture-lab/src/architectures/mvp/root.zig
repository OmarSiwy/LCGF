//! MVP entry point: one owned model, one stateless presenter, one passive view.
const common = @import("../common.zig");
pub const model = @import("model.zig");
pub const presenter = @import("presenter.zig");
pub const view = @import("view.zig");

pub const App = struct {
    model: model.State = .{},

    pub fn init(self: *App) void {
        self.initCount(common.config.initial_items);
    }
    pub fn initCount(self: *App, count: u32) void {
        presenter.initCount(&self.model, count);
    }
    pub fn build(self: *App, f: *common.Frame, _: *const common.Events) void {
        presenter.build(&self.model, f);
    }
    pub fn commit(self: *App, sides: []const common.sidebar.Action, tops: []const common.topbar.Action, work: []const common.workspace.Action) bool {
        return presenter.commit(&self.model, sides, tops, work);
    }
    pub fn snapshot(self: *const App) common.Snapshot {
        const state = &self.model;
        return common.snapshot(&state.model, &state.sidebar, &state.topbar, &state.cache, state.page, state.command_overflow);
    }
};
