//! This project-defined hybrid adds a Presenter between view intentions and model use cases.
//! The ViewModel projects and edits local UI state; this Presenter changes domain/navigation.
const common = @import("../common.zig");
const Model = @import("model.zig").Model;
const vm = @import("view_model.zig");
const view = @import("view.zig");

pub fn initCount(model: *Model, presentation: *vm.ViewModel, count: u32) void {
    model.initCount(count);
    presentation.cache = .{};
}

pub fn build(model: *Model, presentation: *vm.ViewModel, f: *common.Frame) void {
    if (!model.ready) initCount(model, presentation, common.config.initial_items);
    const commands = view.draw(f, presentation.project(model));
    if (commands.failed) {
        if (!presentation.command_overflow) f.ctx.waker.post();
        presentation.command_overflow = true;
        return;
    }
    if (commit(model, presentation, commands.sidebar.items(), commands.topbar.items(), commands.workspace.items())) f.ctx.waker.post();
}

pub fn commit(model: *Model, presentation: *vm.ViewModel, sides: []const common.sidebar.Action, tops: []const common.topbar.Action, work: []const common.workspace.Action) bool {
    const old_page = presentation.page;
    var changed = false;
    for (sides) |action| changed = apply(model, presentation, presentation.sidebarCommand(action)) or changed;
    for (tops) |action| changed = apply(model, presentation, presentation.topbarCommand(action)) or changed;
    for (work) |action| {
        if (action == .scroll and presentation.page != old_page) continue;
        changed = model.apply(action) or changed;
    }
    return changed;
}

fn apply(model: *Model, presentation: *vm.ViewModel, change: vm.Change) bool {
    var changed = change.changed;
    if (change.request) |request| changed = route(model, presentation, request) or changed;
    return changed;
}

fn route(model: *Model, presentation: *vm.ViewModel, request: common.Request) bool {
    return switch (request) {
        .navigate => |page| blk: {
            if (presentation.page == page) break :blk false;
            presentation.page = page;
            _ = model.apply(.reset_scroll);
            break :blk true;
        },
        .advance => model.apply(.advance),
        .toggle_sidebar => presentation.sidebarCommand(.toggle).changed,
    };
}
