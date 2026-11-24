//! Passive MVP view: display the presenter-supplied projection and report typed intentions.
//! It cannot inspect or mutate the model and retains no bindings or callbacks.
const common = @import("../common.zig");

pub fn draw(f: *common.Frame, projection: common.Projection) common.Commands {
    return common.draw(f, projection);
}
