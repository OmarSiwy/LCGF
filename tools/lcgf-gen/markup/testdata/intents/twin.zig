//! intents, written by hand: a one-way view. The items are a const slice; the controls show
//! their fields (`checked="{task.done}"`) and on:change reports (index, value) as an intent
//! without writing the item.

const std = @import("std");
const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;

pub const theme: w.Theme = .{};

pub const spec = s.col(.{ .size = .{ .fill, .fill }, .fill = theme.panel }, .{
    lcgf.ct_interop.region(.each_tasks, .{ .size = .{ .px(400), .px(200) }, .gap = 4 }),
});

pub fn Handlers(comptime Ui: type) type {
    return struct {
        toggles: u32 = 0,
        last: ?struct { u32, bool } = null,
        levels: u32 = 0,

        pub fn toggled(h: *@This(), _: *Ui, index: u32, value: bool) void {
            h.toggles += 1;
            h.last = .{ index, value };
        }
        pub fn leveled(h: *@This(), _: *Ui, _: u32, _: f32) void {
            h.levels += 1;
        }
    };
}

const Task = struct { title: []const u8, done: bool, level: f32 };

/// The items parity.zig gives both frontends' regions; each side gets its own copy.
pub const Sample = struct {
    tasks: [2]Task = .{ .{ .title = "write", .done = false, .level = 0.5 }, .{ .title = "test", .done = true, .level = 0.25 } },

    pub fn data(x: *Sample) struct { tasks: []const Task } {
        return .{ .tasks = &x.tasks };
    }
};

fn runOf(d: *const lcgf.draw_list.DrawList, text: []const u8) ?[4]f32 {
    for (d.runs[0..d.run_len]) |r| if (std.mem.eql(u8, d.strings[r.start..][0..r.bytes], text)) return r.rect;
    return null;
}

/// A click on task 1's checkbox reports (1, true) once and leaves the const data as it was;
/// the next frame still shows the item's own value, so no change is reported again.
pub fn events(comptime page: type, p: anytype, h: anytype) !void {
    _ = page;
    const tasks: []const Task = &.{ .{ .title = "write", .done = false, .level = 0.5 }, .{ .title = "test", .done = false, .level = 0.25 } };
    var in: lcgf.input.Input = .{};
    const out = p.frame(h, &in, .{ .tasks = tasks });
    // The checkbox is the row's first control; the row starts at the region's left edge.
    const region = out.tree.rect(out.tree.find(.from("each_tasks")));
    const title = runOf(out.draw, "test").?;
    in.pointer = .{ region.x0 + 6, (title[1] + title[3]) / 2 };
    in.buttons.left = true;
    _ = p.frame(h, &in, .{ .tasks = tasks });
    in.buttons.left = false;
    _ = p.frame(h, &in, .{ .tasks = tasks });
    _ = p.frame(h, &in, .{ .tasks = tasks });
    try std.testing.expectEqual(1, h.toggles);
    try std.testing.expectEqual(@as(u32, 1), h.last.?[0]);
    try std.testing.expect(h.last.?[1]);
    try std.testing.expect(!tasks[1].done and !tasks[0].done);
    try std.testing.expectEqual(0, h.levels);
}
