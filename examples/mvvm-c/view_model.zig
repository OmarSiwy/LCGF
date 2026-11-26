//! The feature ViewModel: builds the projection and runs feature commands on the model. It has
//! no page and cannot navigate; a navigation click comes back as a request for the coordinator.
const model = @import("model.zig");
const view = @import("view.zig");

pub fn projection(m: *const model.Model, page: model.Page) view.Projection {
    var p: view.Projection = .{ .page = page };
    for (model.names, m.done) |name, done| {
        p.done += @intFromBool(done);
        if (page == .all or !done) {
            p.names[p.len] = name;
            p.len += 1;
        }
    }
    return p;
}

/// Runs `action` on the model, or returns the page it asks for.
pub fn command(m: *model.Model, action: view.Action) ?model.Page {
    switch (action) {
        .advance => m.advance(),
        .show => |page| return page,
    }
    return null;
}
