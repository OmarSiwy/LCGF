//! Explicit MVVM binding: read the ViewModel projection, draw, invoke its typed commands.
//! A render borrow ends before accept mutates the model; no pointers are retained by the view.
const common = @import("../common.zig");
const Model = @import("model.zig").Model;
const ViewModel = @import("view_model.zig").ViewModel;

pub fn draw(f: *common.Frame, model: *Model, presentation: *ViewModel) void {
    const commands = common.draw(f, presentation.project(model));
    if (presentation.accept(model, &commands)) f.ctx.waker.post();
}
