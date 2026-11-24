//! Top bar's public surface; state, projection, and effect routing stay explicit.

const entity = @import("entity.zig");
pub const State = entity.State;
pub const Action = entity.Action;
pub const Commands = @import("../../core/commands.zig").Buffer(Action, 8);
pub const interactor = @import("interactor.zig");
pub const presenter = @import("presenter.zig");
pub const router = @import("router.zig");
pub const view = @import("view.zig");
pub const Model = presenter.Model;
pub const draw = view.draw;
