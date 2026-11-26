//! The view binds to the ViewModel: it reads `projection()` and calls the ViewModel's commands.
//! It never reads the model.
const std = @import("std");
const lcgf = @import("lcgf");
const w = lcgf.widgets_base;
const Frame = lcgf.frame.Frame;
const Id = lcgf.types.Id;
const ViewModel = @import("view_model.zig").ViewModel;

pub const id_all = Id.from("all");
pub const id_open = Id.from("open");
pub const id_advance = Id.from("advance");

/// Returns true when a command ran, so the caller schedules another frame.
pub fn draw(f: *Frame, th: *const w.Theme, vm: *ViewModel) bool {
    const p = vm.projection();
    var acted = false;
    _ = f.open(.from("tasks"), .{ .size = .{ .fill, .fill }, .pad = @splat(16), .gap = 8, .fill = th.panel });
    _ = f.open(.from("bar"), .{ .dir = .x, .size = .{ .fill, .fit }, .gap = 8, .cross = .center });
    if (w.button(f, th, id_all, "All").clicked) {
        vm.show(.all);
        acted = true;
    }
    if (w.button(f, th, id_open, "Open").clicked) {
        vm.show(.open);
        acted = true;
    }
    if (w.button(f, th, id_advance, "Advance").clicked) {
        vm.advance();
        acted = true;
    }
    var buf: [32]u8 = undefined;
    _ = w.label(f, th, std.fmt.bufPrint(&buf, "{s}: {d}/4 done", .{ @tagName(p.page), p.done }) catch "?");
    f.close();
    for (p.names[0..p.len]) |name| _ = w.label(f, th, name);
    f.close();
    return acted;
}
