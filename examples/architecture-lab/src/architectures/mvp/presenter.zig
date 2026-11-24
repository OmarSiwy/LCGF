//! MVP's presenter owns orchestration: query model, instruct passive view, then apply actions.
//! Navigation is handled directly here; there is no ViewModel or separate router/coordinator.
const common = @import("../common.zig");
const State = @import("model.zig").State;
const view = @import("view.zig");

pub fn initCount(state: *State, count: u32) void {
    state.model.initCount(count);
    state.cache = .{};
}

pub fn build(state: *State, f: *common.Frame) void {
    if (!state.model.ready) initCount(state, common.config.initial_items);
    _ = state.cache.refresh(&state.model.workspace.store, state.page);
    const projection = common.project(&state.model, &state.sidebar, &state.topbar, &state.cache, state.page, state.command_overflow);
    const commands = view.draw(f, projection);
    if (commands.failed) {
        if (!state.command_overflow) f.ctx.waker.post();
        state.command_overflow = true;
        return;
    }
    if (commit(state, commands.sidebar.items(), commands.topbar.items(), commands.workspace.items())) f.ctx.waker.post();
}

/// Every view read the same state. Navigation beats scrolling from that previous page;
/// stable-ID selections remain meaningful. Evaluate every reducer, even after a change.
pub fn commit(state: *State, sides: []const common.sidebar.Action, tops: []const common.topbar.Action, work: []const common.workspace.Action) bool {
    const old_page = state.page;
    var changed = false;
    for (sides) |action| switch (action) {
        .toggle => changed = common.sidebar.interactor.reduce(&state.sidebar, .toggle) or changed,
        .navigate => |page| {
            if (state.page != page) {
                state.page = page;
                _ = state.model.apply(.reset_scroll);
                changed = true;
            }
        },
    };
    for (tops) |action| switch (action) {
        .toggle_theme => changed = common.topbar.interactor.reduce(&state.topbar, .toggle_theme) or changed,
        .toggle_sidebar => changed = common.sidebar.interactor.reduce(&state.sidebar, .toggle) or changed,
        .advance => changed = state.model.apply(.advance) or changed,
    };
    for (work) |action| {
        if (action == .scroll and state.page != old_page) continue;
        changed = state.model.apply(action) or changed;
    }
    return changed;
}
