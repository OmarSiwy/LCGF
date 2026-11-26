//! VIPER presenter: formats the entity for the view and sends the view's clicks on, use cases to
//! the interactor and navigation to the router. It changes neither the entity nor the page itself.
const entity = @import("entity.zig");
const interactor = @import("interactor.zig");
const view = @import("view.zig");
const Router = @import("router.zig").Router;

pub fn projection(t: *const entity.Tasks, page: entity.Page) view.Projection {
    var p: view.Projection = .{ .page = page };
    for (entity.names, t.done) |name, done| {
        p.done += @intFromBool(done);
        if (page == .all or !done) {
            p.names[p.len] = name;
            p.len += 1;
        }
    }
    return p;
}

pub fn handle(action: view.Action, t: *entity.Tasks, router: *Router) void {
    switch (action) {
        .advance => interactor.advance(t),
        .show => |page| router.show(page),
    }
}
