//! MVP presenter: stateless. Each frame it reads the model, hands the passive view a projection
//! and commits the view's click to the model. It is the only code that changes the model.
const lcgf = @import("lcgf");
const model = @import("model.zig");
const view = @import("view.zig");

/// Returns true when the view reported a click, so the caller schedules another frame.
pub fn build(m: *model.Model, f: *lcgf.frame.Frame, th: *const lcgf.widgets_base.Theme) bool {
    var p: view.Projection = .{ .page = m.page };
    for (model.names, m.done) |name, done| {
        p.done += @intFromBool(done);
        if (m.page == .all or !done) {
            p.names[p.len] = name;
            p.len += 1;
        }
    }
    switch (view.draw(f, th, &p) orelse return false) {
        .advance => m.advance(),
        .show => |page| m.page = page,
    }
    return true;
}
