//! The view reads feature projections and emits commands. It cannot access the Coordinator.
const common = @import("../common.zig");

pub fn draw(f: *common.Frame, projection: common.Projection) common.Commands {
    return common.draw(f, projection);
}
