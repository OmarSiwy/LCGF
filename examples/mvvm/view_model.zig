//! The ViewModel owns the model and the page. It exposes the projection the view reads and the
//! commands the view calls, and those commands change the model directly.
const model = @import("model.zig");

pub const ViewModel = struct {
    model: model.Model = .{},
    page: model.Page = .all,

    /// What the view shows: the page, the done count and the names of the visible tasks.
    pub const Projection = struct {
        page: model.Page,
        done: u32 = 0,
        names: [4][]const u8 = undefined,
        len: u32 = 0,
    };

    pub fn projection(vm: *const ViewModel) Projection {
        var p: Projection = .{ .page = vm.page };
        for (model.names, vm.model.done) |name, done| {
            p.done += @intFromBool(done);
            if (vm.page == .all or !done) {
                p.names[p.len] = name;
                p.len += 1;
            }
        }
        return p;
    }

    pub fn advance(vm: *ViewModel) void {
        vm.model.advance();
    }

    pub fn show(vm: *ViewModel, page: model.Page) void {
        vm.page = page;
    }
};
