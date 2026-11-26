//! copies, written by hand: state CSS and a transition inside an lcgf-each region. Each copy's
//! widgets are recipe widgets of their own, `id.with(index)`: a row's :hover, a button's
//! eased :hover fill and a checkbox's :checked box follow that copy's pointer and value. The
//! button's fade is per copy, in the page's `go_fade: [4]Fade` (lcgf-max="4"), the same in
//! both frontends.

const std = @import("std");
const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;

pub const theme: w.Theme = .{};

pub const spec = s.col(.{ .size = @splat(.fill), .fill = theme.panel }, .{
    lcgf.ct_interop.region(.each_tasks, .{ .size = .{ .px(400), .px(200) }, .gap = 4 }),
});

pub fn Handlers(comptime Ui: type) type {
    return struct {
        goes: u32 = 0,
        last: u32 = 99,

        pub fn toggled(_: *@This(), _: *Ui, _: u32, _: bool) void {}
        pub fn go(h: *@This(), _: *Ui, index: u32) void {
            h.goes += 1;
            h.last = index;
        }
    };
}

const Task = struct { title: []const u8, done: bool };

/// The items parity.zig gives both frontends' regions; each side gets its own copy.
pub const Sample = struct {
    tasks: [2]Task = .{ .{ .title = "write", .done = false }, .{ .title = "test", .done = true } },

    pub fn data(x: *Sample) struct { tasks: []const Task } {
        return .{ .tasks = &x.tasks };
    }
};

/// Over task 1's row and button while its fade runs, then a click on it.
pub const replay =
    \\frame
    \\viewport 800 600
    \\dt 0.025
    \\pointer 40 40
    \\frame
    \\frame
    \\frame
    \\buttons left
    \\frame
    \\buttons
    \\frame
    \\pointer 300 300
    \\frame
    \\frame
;

/// The rect of the `k`th run showing `text`.
fn runOf(d: *const lcgf.draw_list.DrawList, text: []const u8, k: u32) ?[4]f32 {
    var seen: u32 = 0;
    for (d.runs[0..d.run_len]) |r| if (std.mem.eql(u8, d.strings[r.start..][0..r.bytes], text)) {
        if (seen == k) return r.rect;
        seen += 1;
    };
    return null;
}

const hot: [3]f32 = .{ 200, 80, 80 };

/// The pointer over task 1's button: its fade alone eases toward the hover fill, asking for
/// frames until it lands; a click reports index 1.
pub fn events(comptime page: type, p: anytype, h: anytype) !void {
    _ = page;
    var sample: Sample = .{};
    var in: lcgf.input.Input = .{ .dt = 0.025 };
    var out = p.frame(h, &in, sample.data());
    const go1 = runOf(out.draw, "Go", 1).?;
    in.pointer = .{ (go1[0] + go1[2]) / 2, (go1[1] + go1[3]) / 2 };
    out = p.frame(h, &in, sample.data());
    _ = p.frame(h, &in, sample.data());
    out = p.frame(h, &in, sample.data());
    const fades = &p.ui.signals.state.go_fade;
    try std.testing.expectEqualSlices(f32, &hot, fades[1].to[0..3]);
    try std.testing.expect(!std.mem.eql(f32, &hot, fades[0].to[0..3]));
    try std.testing.expect(fades[1].elapsed < 0.1);
    try std.testing.expectEqual(@as(f32, 0), out.wake);
    for (0..4) |_| out = p.frame(h, &in, sample.data());
    try std.testing.expectEqual(@as(f32, 0.1), fades[1].elapsed);
    in.buttons.left = true;
    _ = p.frame(h, &in, sample.data());
    in.buttons.left = false;
    _ = p.frame(h, &in, sample.data());
    try std.testing.expectEqual(1, h.goes);
    try std.testing.expectEqual(@as(u32, 1), h.last);
}
