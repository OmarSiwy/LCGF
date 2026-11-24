//! MVVM-C separates command-bearing feature ViewModels from the app-flow Coordinator.
//! The composition root owns their values and borrows them explicitly per operation.
const common = @import("../common.zig");
pub const model = @import("model.zig");
pub const view_model = @import("view_model.zig");
pub const coordinator = @import("coordinator.zig");
pub const view = @import("view.zig");

pub const App = struct {
    model: model.Model = .{},
    view_model: view_model.ViewModel = .{},
    coordinator: coordinator.Coordinator = .{},

    pub fn init(self: *App) void {
        self.initCount(common.config.initial_items);
    }
    pub fn initCount(self: *App, count: u32) void {
        self.model.initCount(count);
        self.view_model.cache = .{};
    }
    pub fn build(self: *App, f: *common.Frame, _: *const common.Events) void {
        if (!self.model.ready) self.init();
        const commands = view.draw(f, self.view_model.project(&self.model, self.coordinator.page));
        if (commands.failed) {
            if (!self.view_model.command_overflow) f.ctx.waker.post();
            self.view_model.command_overflow = true;
            return;
        }
        if (self.commit(commands.sidebar.items(), commands.topbar.items(), commands.workspace.items())) f.ctx.waker.post();
    }
    pub fn commit(self: *App, sides: []const common.sidebar.Action, tops: []const common.topbar.Action, work: []const common.workspace.Action) bool {
        return self.coordinator.commit(&self.model, &self.view_model, sides, tops, work);
    }
    pub fn snapshot(self: *const App) common.Snapshot {
        const presentation = &self.view_model;
        return common.snapshot(&self.model, &presentation.sidebar, &presentation.topbar, &presentation.cache, self.coordinator.page, presentation.command_overflow);
    }
};
