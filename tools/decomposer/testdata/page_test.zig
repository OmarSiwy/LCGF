const std = @import("std");
const page = @import("counter");
const lcgf = @import("lcgf");

test "generated page renders, dispatches one Zig writer, and repaints the binding" {
    var app: page.Page = .{};
    var in: lcgf.input.Input = .{};
    const first = app.frame(&in);
    try std.testing.expectEqualStrings("Native counter", page.title);
    try std.testing.expect(first.draw.cmd_len > 0);
    try std.testing.expectEqualStrings("Ready", app.ui.signals.state.message);
    const rect = first.tree.rect(first.tree.find(.from("change")));
    in.pointer = .{ (rect.x0 + rect.x1) / 2, (rect.y0 + rect.y1) / 2 };
    in.buttons.left = true;
    _ = app.frame(&in);
    in.buttons.left = false;
    const clicked = app.frame(&in);
    try std.testing.expectEqual(@as(f32, 0), clicked.wake);
    try std.testing.expectEqualStrings("Changed", app.ui.signals.state.message);
    const next = app.frame(&in);
    try std.testing.expect(next.event == null);
    const run = next.draw.runs[0];
    const words = next.draw.strings[run.start..][0..run.bytes];
    try std.testing.expectEqualStrings("Changed", words);
    try std.testing.expectEqualStrings("Details", next.draw.strings[next.draw.runs[2].start..][0..next.draw.runs[2].bytes]);
}

test "read-only binding is a literal at comptime even in a document with writers" {
    const readonly = @import("readonly");
    try std.testing.expectEqual(0, @sizeOf(readonly.State));
    try std.testing.expect(!@hasField(page.State, "subtitle"));
    var app: readonly.Page = .{};
    const first = app.frame(&.{});
    try std.testing.expectEqual(2, first.draw.run_len);
    const heading = std.mem.indexOfScalar(u8, first.tree.c.role[0..first.tree.len], @backingInt(lcgf.types.Role.heading)).?;
    try std.testing.expectEqual(@as(f32, 2), first.tree.c.value[heading]);
    const run = first.draw.runs[0];
    try std.testing.expectEqualStrings("Compiled once", first.draw.strings[run.start..][0..run.bytes]);
}

test "an observer callback can read a default through a zero-size document state" {
    const readonly = @import("readonly");
    var app: readonly.Page = .{};
    var in: lcgf.input.Input = .{};
    const ui = app.frame(&in);
    const r = ui.tree.rect(ui.tree.find(.from("inspect")));
    in.pointer = .{ (r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2 };
    in.buttons.left = true;
    _ = app.frame(&in);
    in.buttons.left = false;
    try std.testing.expect(app.frame(&in).event.? == .inspect);
}
