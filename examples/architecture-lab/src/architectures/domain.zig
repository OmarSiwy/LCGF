//! Framework-free ownership shared by the architecture examples. Imports stop at plain data,
//! business rules, and the pure projection cache: no LCGF, renderer, shell, or allocator.
const entity = @import("../modules/workspace/entity.zig");
const interactor = @import("../modules/workspace/interactor.zig");
const cache_zig = @import("../modules/workspace/presenter.zig");
const sidebar_entity = @import("../modules/sidebar/entity.zig");
const topbar_entity = @import("../modules/topbar/entity.zig");
const navigation = @import("../core/navigation.zig");

/// Reuse the same feature invariants in every architecture. The shared feature state includes
/// selected identity and scroll position; app chrome ownership differs by architecture.
pub const Model = struct {
    ready: bool = false,
    workspace: entity.State = .{},

    pub fn initCount(self: *Model, count: u32) void {
        self.workspace.store.init(count);
        self.workspace.selected = null;
        self.workspace.scroll = 0;
        self.ready = true;
    }

    pub fn apply(self: *Model, action: entity.Action) bool {
        return interactor.reduce(&self.workspace, action);
    }
};

/// MVP gives its Presenter one owner for both model and presentation state. The other variants
/// store the same types in a separate ViewModel (and, for MVVM-C, a Coordinator).
pub const State = struct {
    model: Model = .{},
    page: navigation.Page = .all,
    sidebar: sidebar_entity.State = .{},
    topbar: topbar_entity.State = .{},
    cache: cache_zig.Cache = .{},
    command_overflow: bool = false,
};
