//! Counter with signals: the count is a `Cell` (src/runtime/signals.zig), a value paired with a
//! version number; "doubled" is a `Derived` recomputed only when the count's version moved; and
//! the summary panel is skipped with `Frame.reuse` while the derived value did not change, as
//! prototype/example.zig `buildUi` skips its sidebar on `layers`. Nothing subscribes and nothing
//! is called back: each reader compares versions when it runs.

const std = @import("std");
const lcgf = @import("lcgf");
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
    /// Created on the first frame, from the context's signals.
    count: signals.Cell(i32) = undefined,
    doubled: signals.Derived(i32) = undefined,
    ready: bool = false,
    /// How often "doubled" was computed and the summary built: the work signals saved.
    computes: u32 = 0,
    summary_builds: u32 = 0,

    pub fn build(app: *App, f: *Frame, _: *const Events) void {
        const th = &app.theme;
        const sig = &f.ctx.signals;
        if (!app.ready) {
            app.count = .init(sig, 0);
            app.doubled = .init(sig, &.{app.count.signal}, 0);
            app.ready = true;
        }

        _ = f.open(.from("row"), .{ .dir = .x, .size = .{ .fill, .fit }, .pad = @splat(16), .gap = 8, .cross = .center, .fill = th.panel });
        if (w.button(f, th, id_dec, "-").clicked) app.count.set(sig, app.count.get() - 1);
        if (w.button(f, th, id_inc, "+").clicked) app.count.set(sig, app.count.get() + 1);
        var buf: [32]u8 = undefined;
        _ = w.label(f, th, std.fmt.bufPrint(&buf, "Count: {d}", .{app.count.get()}) catch "?");
        f.close();

        // A memo: runs once per change of its input, not once per frame.
        const deps = [_]signals.Signal{app.count.signal};
        if (app.doubled.stale(sig, &deps)) {
            app.computes += 1;
            app.doubled.set(sig, &deps, app.count.get() * 2);
        }
        // Copied from last frame while "doubled" did not change.
        if (!f.reuse(id_summary, &.{app.doubled.signal()})) {
            app.summary_builds += 1;
            _ = f.open(id_summary, .{ .size = .{ .fill, .fit }, .pad = @splat(16), .fill = th.panel });
            var buf2: [32]u8 = undefined;
            _ = w.label(f, th, std.fmt.bufPrint(&buf2, "Doubled: {d}", .{app.doubled.get()}) catch "?");
            f.close();
        }
    }
};

const testing = std.testing;
const host = @import("host");

test "counter: clicks move the count; the memo and the summary follow only its changes" {
    var app: App = .{};
    var s = try host.Smoke.run(&app, "frame\nviewport 800 600\n");
    const inc = host.center(s.rect(id_inc));
    const dec = host.center(s.rect(id_dec));

    app = .{};
    var rec: [512]u8 = undefined;
    s = try host.Smoke.run(&app, try host.clicks(&rec, &.{ inc, inc, inc, dec }));
    try testing.expectEqual(@as(i32, 2), app.count.get());
    try testing.expectEqual(@as(i32, 4), app.doubled.get());
    // Four changes, four computes: none on the other frames.
    try testing.expectEqual(@as(u32, 4), app.computes);
    // The summary was rebuilt for its first frame and each change of "doubled", not per frame.
    try testing.expectEqual(@as(u32, 1 + 4), app.summary_builds);
    try testing.expectEqual(@as(u32, 14), s.builds);
    // Its panel was drawn, reused or not.
    const r = s.rect(id_summary);
    try testing.expectEqual(app.theme.panel, s.at(@intFromFloat(r.x0 + 2), @intFromFloat(r.y0 + 2)));
}
