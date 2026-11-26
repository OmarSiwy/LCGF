//! The presenter takes the view's click and applies it: domain work to the model, navigation to
//! the page the ViewModel stores. Neither owner changes the other.
const model = @import("model.zig");
const view = @import("view.zig");
const ViewModel = @import("view_model.zig").ViewModel;

pub fn apply(m: *model.Model, vm: *ViewModel, action: view.Action) void {
    switch (action) {
        .advance => m.advance(),
        .show => |page| vm.page = page,
    }
}
