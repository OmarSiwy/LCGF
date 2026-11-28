//! Counter with signals: the count is a `Cell` (src/runtime/signals.zig), a value paired with a
//! version number; "doubled" is a `Derived` recomputed only when the count's version moved; and
//! the summary panel is skipped with `Frame.reuse` while the derived value did not change, as
//! prototype/example.zig `buildUi` skips its sidebar on `layers`. Nothing subscribes and nothing
//! is called back: each reader compares versions when it runs.

const std = @import("std");
const lcgf = @import("lcgf");
const lcgf_app = @import("lcgf_app");
const w = lcgf.widgets_base;
const signals = lcgf.runtime_signals;
const Frame = lcgf.frame.Frame;
const Id = lcgf.types.Id;
const Events = lcgf.shell_iface.Events;

pub const id_dec = Id.from("dec");
pub const id_inc = Id.from("inc");
pub const id_summary = Id.from("summary");

pub const App = struct {
    theme: w.Theme = .default,
    /// Their signals are created by their first change: nothing to set up.
    count: signals.Cell(i32) = .of(0),
    doubled: signals.Derived(i32) = .of(0),
    /// How often "doubled" was computed and the summary built: the work signals saved.
    computes: u32 = 0,
    summary_builds: u32 = 0,

    pub fn build(app: *App, f: *Frame, _: *const Events) void {
        const th = &app.theme;
        const sig = &f.ctx.signals;

        _ = f.open(.from("row"), .{ .dir = .x, .size = .{ .fill, .fit }, .pad = @splat(16), .gap = 8, .cross = .center, .fill = th.panel });
        if (w.button(f, th, id_dec, "-").clicked) app.count.set(sig, app.count.get() - 1);
        if (w.button(f, th, id_inc, "+").clicked) app.count.set(sig, app.count.get() + 1);
        var buf: [32]u8 = undefined;
        _ = w.label(f, th, std.fmt.bufPrint(&buf, "Count: {d}", .{app.count.get()}) catch "?");
        f.close();

        // A memo: `double` runs on the first frame and once per change of its input, not
        // once per frame.
        _ = app.doubled.update(sig, &.{app.count.signal}, double, .{ app, app.count.get() });
        // Copied from last frame while "doubled" did not change.
        if (!f.reuse(id_summary, &.{app.doubled.signal()})) {
            app.summary_builds += 1;
            _ = f.open(id_summary, .{ .size = .{ .fill, .fit }, .pad = @splat(16), .fill = th.panel });
            var buf2: [32]u8 = undefined;
            _ = w.label(f, th, std.fmt.bufPrint(&buf2, "Doubled: {d}", .{app.doubled.get()}) catch "?");
            f.close();
        }
    }

    fn double(app: *App, n: i32) i32 {
        app.computes += 1;
        return n * 2;
    }
};

pub fn main(init: std.process.Init) !void {
    var app: App = .{};
    try lcgf_app.run(App, &app, init, .{ .title = "Counter" });
}

const testing = std.testing;
const replay = @import("lcgf_replay");

test "counter: clicks move the count; the memo and the summary follow only its changes" {
    var app: App = .{};
    var s = try replay.run(&app, "frame\nviewport 800 600\n");
    const inc = replay.center(s.rect(id_inc));
    const dec = replay.center(s.rect(id_dec));

    app = .{};
    var rec: [512]u8 = undefined;
    s = try replay.run(&app, try replay.clicks(&rec, &.{ inc, inc, inc, dec }));
    try testing.expectEqual(@as(i32, 2), app.count.get());
    try testing.expectEqual(@as(i32, 4), app.doubled.get());
    // The first frame's compute and one per change: none on the other frames.
    try testing.expectEqual(@as(u32, 1 + 4), app.computes);
    // The summary was rebuilt for its first frame, each change of "doubled", and each move of
    // keyboard focus (to "+", then to "-"), which `reuse` treats as an input to every memo.
    try testing.expectEqual(@as(u32, 1 + 4 + 2), app.summary_builds);
    try testing.expectEqual(@as(u32, 14), s.builds);
    // Its panel was drawn, reused or not.
    const r = s.rect(id_summary);
    try testing.expectEqual(app.theme.panel, s.at(@intFromFloat(r.x0 + 2), @intFromFloat(r.y0 + 2)));
}
