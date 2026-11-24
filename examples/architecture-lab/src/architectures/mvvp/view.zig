//! The hybrid's view reads the ViewModel projection and returns intentions to its Presenter.
const common = @import("../common.zig");

pub fn draw(f: *common.Frame, projection: common.Projection) common.Commands {
    return common.draw(f, projection);
}
