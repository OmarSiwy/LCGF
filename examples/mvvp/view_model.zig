//! The ViewModel stores the page and turns the model into the view's projection. It changes
//! nothing: the presenter is the only writer of the page and the model.
const model = @import("model.zig");
const view = @import("view.zig");

pub const ViewModel = struct {
    page: model.Page = .all,

    pub fn projection(vm: *const ViewModel, m: *const model.Model) view.Projection {
        var p: view.Projection = .{ .page = vm.page };
        for (model.names, m.done) |name, done| {
            p.done += @intFromBool(done);
            if (vm.page == .all or !done) {
                p.names[p.len] = name;
                p.len += 1;
            }
        }
        return p;
    }
};
