//! The shells' example (src/shell/example.zig) exposed to the desktop's screen reader through
//! the Unix adapter, with no window: AT-SPI needs none, so the accessibility tree is the whole
//! program. Used by the screen-reader smoke test (ci/jobs/accesskit-linux.sh).
//!
//!     accesskit-smoke SECONDS
//!
//! Below the example it adds a text field, Title, holding "Untitled", a search field, Find,
//! holding "zig", and a text area, Notes, so the screen reader has a field's text to read, a
//! search box and a multiline field.
//!
//! Runs for SECONDS. A second after a screen reader connects, it starts moving keyboard focus
//! round Reset, Wireframe, Exposure, Title, Find and Notes (as Tab would), one a second, so the screen
//! reader announces each. Prints `ready` when the adapter exists, `connected` when the first update
//! went out, then a line whenever the application's state changes (`resets=1`,
//! `wireframe=true`, `focus=exposure`), so a test can drive it from the screen reader's side and
//! read the result.

const std = @import("std");
const lcgf = @import("lcgf");
const bridge = @import("bridge.zig");
const a11y = lcgf.a11y_tree;
const example = lcgf.shell_example;
const Context = lcgf.context.Context;
const tf = lcgf.widgets_textfield;

const search = lcgf.widgets_search;

const id_title = lcgf.types.Id.from("title");
const id_find = lcgf.types.Id.from("find");
const id_notes = lcgf.types.Id.from("notes");
const textarea = lcgf.widgets_textarea;

const limits: lcgf.context.Limits = .{ .nodes = 1024, .texts = 256 };
var ctx_buffer: [Context.requiredBytes(limits)]u8 align(lcgf.mem.column_align) = undefined;
var host: bridge.Host(1024) = .{};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.next();
    const seconds = try std.fmt.parseInt(u32, args.next() orelse return error.Usage, 10);
    var out_buf: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const w = &stdout.interface;

    var ctx = try Context.init(&ctx_buffer, limits);
    host.init("LCGF example", &ctx, null);
    var app: example.App = .{};
    var title: tf.Text(32) = .init("Untitled");
    var find: tf.Text(32) = .init("zig");
    var notes: tf.Text(64) = .init("Buy milk");
    var ev: lcgf.shell_iface.Events = .{};
    ev.in.viewport = .{ 800, 600 };

    const ak = bridge.unix.Adapter.init(&host.b);
    defer ak.deinit();
    ak.setFocused(true);
    try w.writeAll("ready\n");
    try w.flush();

    const tour = [_]lcgf.types.Id{ example.id_reset, example.id_wire, example.id_exposure, id_title, id_find, id_notes };
    const names = [_][]const u8{ "reset", "wireframe", "exposure", "title", "find", "notes" };
    var acts_buf: [bridge.Bridge.queue_len + 1]a11y.Action = undefined;
    var seen: example.App = app;
    var seen_focus: u32 = 0;
    var connected_at: ?u32 = null;
    const tick_ms = 10;
    var tick: u32 = 0;
    while (tick < seconds * 1000 / tick_ms) : (tick += 1) {
        var n = host.b.drain(acts_buf[0..bridge.Bridge.queue_len]).len;
        // The tour: one focus move a second once a screen reader is listening.
        if (connected_at == null and host.b.sent > 0) {
            connected_at = tick;
            try w.writeAll("connected\n");
        }
        if (connected_at) |t0| {
            // A second to settle (the screen reader reads the window first), then round and round.
            const ms = (tick - t0) * tick_ms;
            if (ms >= 1000 and ms % 1000 == 0) {
                acts_buf[n] = .{ .kind = .focus, .target = @backingInt(tour[(ms / 1000 - 1) % tour.len]) };
                n += 1;
            }
        }
        if (n > 0 or ctx.needsFrame(&ev.in)) {
            var f = ctx.begin(&ev.in);
            a11y.apply(&ctx.inter, acts_buf[0..n]);
            app.build(&f, &ev);
            const caption = lcgf.widgets_base.label(&f, &app.theme, "Title");
            _ = tf.textfield(&f, &app.theme, id_title, &title, "Document title");
            const find_caption = lcgf.widgets_base.label(&f, &app.theme, "Find");
            _ = search.search(&f, &app.theme, id_find, &find, "Search");
            const notes_caption = lcgf.widgets_base.label(&f, &app.theme, "Notes");
            _ = textarea.textarea(&f, &app.theme, id_notes, &notes, 3, "");
            const out = f.end(.{});
            app.semantics(out.tree, &host.s, &ctx.strings[ctx.cur]);
            tf.semantics(out.tree, &host.s, id_title, caption.ix());
            tf.textValue(out.tree, &host.s, &ctx.strings[ctx.cur], id_title, &title, "Document title");
            search.semantics(out.tree, &host.s, id_find, find_caption.ix());
            search.textValue(out.tree, &host.s, &ctx.strings[ctx.cur], id_find, &find, "Search");
            textarea.semantics(out.tree, &host.s, id_notes, notes_caption.ix());
            textarea.textValue(out.tree, &host.s, &ctx.strings[ctx.cur], id_notes, &notes, "");
            host.frame(&ctx, &out);
            ak.update(&host.b);
        }
        if (app.resets != seen.resets) try w.print("resets={d}\n", .{app.resets});
        if (app.wireframe != seen.wireframe) try w.print("wireframe={}\n", .{app.wireframe});
        if (ctx.inter.focus != seen_focus) for (tour, names) |id, name| {
            if (@backingInt(id) == ctx.inter.focus) try w.print("focus={s}\n", .{name});
        };
        seen = app;
        seen_focus = ctx.inter.focus;
        try w.flush();
        try io.sleep(.fromMilliseconds(tick_ms), .awake);
    }
}
