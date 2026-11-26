//! VIPER view: draws what the presenter hands it and reports clicks back to it.
const std = @import("std");
const lcgf = @import("lcgf");
const w = lcgf.widgets_base;
const Frame = lcgf.frame.Frame;
const Id = lcgf.types.Id;
const Page = @import("entity.zig").Page;

pub const Action = union(enum) { advance, show: Page };

pub const id_all = Id.from("all");
pub const id_open = Id.from("open");
pub const id_advance = Id.from("advance");

/// Everything the view shows: the page, the done count and the names of the visible tasks.
pub const Projection = struct {
    page: Page,
    done: u32 = 0,
    names: [4][]const u8 = undefined,
    len: u32 = 0,
};

/// Draws `p` and returns this frame's click, if any.
pub fn draw(f: *Frame, th: *const w.Theme, p: *const Projection) ?Action {
    var action: ?Action = null;
    _ = f.open(.from("tasks"), .{ .size = .{ .fill, .fill }, .pad = @splat(16), .gap = 8, .fill = th.panel });
    _ = f.open(.from("bar"), .{ .dir = .x, .size = .{ .fill, .fit }, .gap = 8, .cross = .center });
    if (w.button(f, th, id_all, "All").clicked) action = .{ .show = .all };
    if (w.button(f, th, id_open, "Open").clicked) action = .{ .show = .open };
    if (w.button(f, th, id_advance, "Advance").clicked) action = .advance;
    var buf: [32]u8 = undefined;
    _ = w.label(f, th, std.fmt.bufPrint(&buf, "{s}: {d}/4 done", .{ @tagName(p.page), p.done }) catch "?");
    f.close();
    for (p.names[0..p.len]) |name| _ = w.label(f, th, name);
    f.close();
    return action;
}
