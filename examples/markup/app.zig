//! A counter written in HTML and CSS (ui/counter.html): the build generates `counter_ui`, a
//! comptime page, with `lcgf.addMarkup`. The app supplies only the handlers the markup names;
//! the view state (`count`, `by_ten`) is generated from the bindings.

const std = @import("std");
const lcgf = @import("lcgf");
const ui = @import("counter_ui");

pub const Handlers = struct {
    step: f32 = 1,

    pub fn inc(h: *Handlers, view: *ui.Ui) void {
        view.signals.set(.count, view.signals.state.count + h.step);
    }

    pub fn dec(h: *Handlers, view: *ui.Ui) void {
        view.signals.set(.count, view.signals.state.count - h.step);
    }

    pub fn step_changed(h: *Handlers, _: *ui.Ui, by_ten: bool) void {
        h.step = if (by_ten) 10 else 1;
    }
};

var page: ui.Page(Handlers) = .{};

pub fn main(init: std.process.Init) !void {
    var h: Handlers = .{};
    var in: lcgf.input.Input = .{};
    const first = page.frame(&h, &in);
    const t = first.tree;
    const inc = t.rect(t.find(.from("inc")));
    in.pointer = .{ (inc.x0 + inc.x1) / 2, (inc.y0 + inc.y1) / 2 };
    in.buttons.left = true;
    _ = page.frame(&h, &in);
    in.buttons.left = false;
    const out = page.frame(&h, &in);
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    try w.interface.print("{s}: count {d} after one click on +, {d} rows drawn\n", .{ ui.title, page.ui.signals.state.count, out.tree.len });
    try w.interface.flush();
}

test "a click on + counts one; with 'Count by ten' checked, ten" {
    var h: Handlers = .{};
    var in: lcgf.input.Input = .{};
    page = .{};
    const t = page.frame(&h, &in).tree;
    const inc = t.rect(t.find(.from("inc")));
    const box = t.rect(t.find(.from("step10")));
    for ([_]lcgf.types.Rect{ inc, box, inc }) |r| {
        in.pointer = .{ (r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2 };
        in.buttons.left = true;
        _ = page.frame(&h, &in);
        in.buttons.left = false;
        _ = page.frame(&h, &in);
    }
    try std.testing.expect(page.ui.signals.state.by_ten);
    try std.testing.expectEqual(11, page.ui.signals.state.count);
}
