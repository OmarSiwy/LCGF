//! example.zig: the usage code the API was designed from.
//!
//! Headless on purpose: it drives the UI with scripted input and checks what
//! comes out, so `zig test example.zig` is both the demo and the test suite.
//! In a real host, `Input` is filled from your window layer and the `render`
//! switch below issues GPU calls (see ui_wgpu.zig).

const std = @import("std");
const ui = @import("ui.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

// The caller owns all memory. Here it is one static buffer, sized at comptime.
const limits: ui.Limits = .{ .nodes = 1024, .texts = 256 };
var buffer: [ui.Context.requiredBytes(limits)]u8 align(ui.mem.column_align) = undefined;

const id_reset = ui.Id.from("reset");
const id_wire = ui.Id.from("wireframe");
const id_exposure = ui.Id.from("exposure");
const id_glow = ui.Id.from("glow");
const id_sidebar = ui.Id.from("sidebar");
const id_add = ui.Id.from("add-layer");
const id_viewport = ui.Id.from("viewport");

const App = struct {
    theme: ui.Theme = .{},
    resets: u32 = 0,
    exposure: f32 = 1,
    wireframe: bool = false,
    glow: f32 = 0,
    /// A signal, so the sidebar can be skipped while it does not change.
    layers: ui.Cell(u32),
    sidebar_builds: u32 = 0,
};

/// The whole UI. Runs top to bottom every frame; nothing calls back into it.
fn buildUi(f: *ui.Frame, app: *App) void {
    const th = &app.theme;

    _ = f.open(ui.Id.from("toolbar"), .{ .dir = .x, .size = .{ .fill, .fit }, .pad = @splat(8), .gap = 8, .cross = .center, .fill = th.panel });
    if (ui.widgets.button(f, th, id_reset, "Reset").clicked) {
        app.resets += 1;
        app.exposure = 1;
    }
    _ = ui.widgets.checkbox(f, th, id_wire, &app.wireframe, "Wireframe");
    _ = ui.widgets.slider(f, th, id_exposure, &app.exposure, 0, 4);
    // A spring: eases toward its target and keeps the host awake until it lands.
    app.glow = f.animate(id_glow, @floatFromInt(@intFromBool(app.wireframe)), .{});
    f.close();

    _ = f.open(ui.Id.from("body"), .{ .dir = .x, .size = .{ .fill, .fill } });
    // Rebuilt only when `layers` changes or the pointer is on one of its widgets.
    if (!f.reuse(id_sidebar, &.{app.layers.signal})) {
        app.sidebar_builds += 1;
        _ = f.open(id_sidebar, .{ .size = .{ .px(160), .fill }, .pad = @splat(8), .gap = 4, .fill = th.panel });
        if (ui.widgets.button(f, th, id_add, "Add layer").clicked) app.layers.set(&f.ctx.signals, app.layers.get() + 1);
        var name: [24]u8 = undefined;
        for (0..app.layers.get()) |i| {
            _ = ui.widgets.label(f, th, std.fmt.bufPrint(&name, "Layer {d}", .{i}) catch "?");
        }
        f.close();
    }
    // The 3D view. The UI only reserves the rect; the host draws into it.
    _ = f.custom(id_viewport, .{ .size = .{ .fill, .fill } }, 0);
    f.close();
}

fn frame(ctx: *ui.Context, app: *App, in: *const ui.Input) ui.Output {
    var f = ctx.begin(in);
    buildUi(&f, app);
    return f.end(.{});
}

const Drawn = struct { batches: u32 = 0, quads: u32 = 0, texts: u32 = 0, customs: u32 = 0, viewport: [4]f32 = @splat(0) };

/// What a renderer does with the output: one switch per command, in paint order.
fn render(draw: *const ui.DrawList) Drawn {
    var d: Drawn = .{};
    for (0..draw.cmd_len) |i| switch (draw.command(@intCast(i))) {
        .quads => |batch| { // gfx.drawBatch(pass, batch)
            d.batches += 1;
            d.quads += batch.count;
        },
        .text => d.texts += 1, // gfx.drawText(pass, run)
        .custom => |k| { // scene.draw(pass, rect, clip): your pipeline, in z-order
            d.customs += 1;
            d.viewport = draw.customs[k].rect;
        },
    };
    return d;
}

fn center(r: ui.Rect) [2]f32 {
    return .{ (r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5 };
}

test "host loop: layout, draw list, click, drag, idle" {
    var ctx = try ui.Context.init(&buffer, limits);
    var app: App = .{ .layers = .init(&ctx.signals, 3) };
    var in: ui.Input = .{ .viewport = .{ 800, 600 } };

    try expect(ctx.needsFrame(&in));
    var out = frame(&ctx, &app, &in);
    try expect(out.status.ok());

    // Layout: toolbar on top, sidebar left, viewport takes the rest.
    const t = out.tree;
    try expectEqual(ui.Rect{ .x0 = 0, .y0 = 50, .x1 = 160, .y1 = 600 }, t.rect(t.find(id_sidebar)));
    try expectEqual(ui.Rect{ .x0 = 160, .y0 = 50, .x1 = 800, .y1 = 600 }, t.rect(t.find(id_viewport)));

    // Draw list: quads between text runs are merged into batches; the custom
    // draw arrives last, in paint order, carrying its rect.
    const d = render(out.draw);
    try expectEqual(@as(u32, 1), d.customs);
    try expectEqual([4]f32{ 160, 50, 800, 600 }, d.viewport);
    try expectEqual(@as(u32, 6), d.texts); // Reset, Wireframe, Add layer, Layer 0..2
    try expectEqual(@as(u32, 7), d.quads); // toolbar, 2 buttons, box, track, thumb, sidebar
    try expect(d.batches < d.quads);
    try expectEqual(@as(usize, 7 * @sizeOf(ui.Quad)), out.draw.quadBytes().len);

    // Idle: one settle frame after input, then nothing to do.
    try expectEqual(@as(f32, 0), out.wake);
    out = frame(&ctx, &app, &in);
    try expectEqual(ui.inf, out.wake);
    try expect(!ctx.needsFrame(&in));

    // Click: press and release over the button, found by last frame's geometry.
    in.pointer = center(out.tree.rect(out.tree.find(id_reset)));
    out = frame(&ctx, &app, &in);
    try expectEqual(ui.Cursor.pointer, out.platform.cursor);
    in.buttons.left = true;
    _ = frame(&ctx, &app, &in);
    try expectEqual(@as(u32, 0), app.resets);
    in.buttons.left = false;
    out = frame(&ctx, &app, &in);
    try expectEqual(@as(u32, 1), app.resets);

    // Drag: holding the slider at 75% of its track sets the value to 3 of 0..4.
    const track = out.tree.rect(out.tree.find(id_exposure));
    in.pointer = .{ track.x0 + 0.75 * track.w(), (track.y0 + track.y1) * 0.5 };
    _ = frame(&ctx, &app, &in);
    in.buttons.left = true;
    out = frame(&ctx, &app, &in);
    try std.testing.expectApproxEqAbs(@as(f32, 3), app.exposure, 0.01);
    try expectEqual(@as(f32, 3), out.tree.c.value[out.tree.find(id_exposure)]);
    in.buttons.left = false;
    _ = frame(&ctx, &app, &in);
}

test "signals: the sidebar is rebuilt only when it has to be" {
    var ctx = try ui.Context.init(&buffer, limits);
    var app: App = .{ .layers = .init(&ctx.signals, 3) };
    var in: ui.Input = .{ .viewport = .{ 800, 600 } };

    var out = frame(&ctx, &app, &in);
    try expectEqual(@as(u32, 1), app.sidebar_builds);
    const before = out.tree.rect(out.tree.find(id_add));

    // Unchanged dependencies: copied from last frame, same geometry, same text.
    out = frame(&ctx, &app, &in);
    out = frame(&ctx, &app, &in);
    try expectEqual(@as(u32, 1), app.sidebar_builds);
    try expectEqual(before, out.tree.rect(out.tree.find(id_add)));
    try expectEqual(@as(u32, 6), render(out.draw).texts);

    // A changed signal wakes the host and rebuilds exactly once.
    app.layers.set(&ctx.signals, 5);
    try expect(ctx.needsFrame(&in));
    out = frame(&ctx, &app, &in);
    try expectEqual(@as(u32, 2), app.sidebar_builds);
    try expectEqual(@as(u32, 8), render(out.draw).texts);
    out = frame(&ctx, &app, &in);
    try expectEqual(@as(u32, 2), app.sidebar_builds);

    // The pointer on a widget inside the subtree forces rebuilds, so the
    // click is seen; "Add layer" then changes the signal itself.
    in.pointer = center(before);
    _ = frame(&ctx, &app, &in);
    in.buttons.left = true;
    _ = frame(&ctx, &app, &in);
    in.buttons.left = false;
    out = frame(&ctx, &app, &in);
    try expectEqual(@as(u32, 6), app.layers.get());
    const builds_while_hovering = app.sidebar_builds;
    try expect(builds_while_hovering > 2);

    // Pointer leaves: one more rebuild clears the hover colour, then reuse resumes.
    in.pointer = .{ 700, 500 };
    _ = frame(&ctx, &app, &in);
    _ = frame(&ctx, &app, &in);
    const settled = app.sidebar_builds;
    out = frame(&ctx, &app, &in);
    try expectEqual(settled, app.sidebar_builds);
    try expectEqual(@as(u32, 9), render(out.draw).texts);
}

test "springs keep the host awake until they land" {
    var ctx = try ui.Context.init(&buffer, limits);
    var app: App = .{ .layers = .init(&ctx.signals, 1) };
    const in: ui.Input = .{ .viewport = .{ 800, 600 } };

    _ = frame(&ctx, &app, &in);
    _ = frame(&ctx, &app, &in);
    try expect(!ctx.needsFrame(&in));

    app.wireframe = true; // the glow spring now has a new target
    var frames: u32 = 0;
    var out = frame(&ctx, &app, &in);
    try expectEqual(@as(f32, 0), out.wake);
    while (out.wake == 0 and frames < 600) : (frames += 1) out = frame(&ctx, &app, &in);
    try expect(frames > 5 and frames < 600);
    try expectEqual(@as(f32, 1), app.glow);
    try expectEqual(ui.inf, out.wake);
}

test "tier 0 alone: no Context, caller sequences the passes" {
    var raw: [256 * 1024]u8 align(ui.mem.column_align) = undefined;
    var carver: ui.mem.Carver = .{ .buf = &raw };
    var t = ui.Tree.init(&carver, 64);
    var tx = ui.Texts.init(&carver, 8);
    var strings: ui.Strings = .{ .buf = carver.slice(u8, 256) };

    const root = t.push(0, ui.root_id, &.{ .size = .{ .px(400), .px(300) }, .pad = @splat(10), .gap = 5, .clip = true });
    const bar = t.push(root, .none, &.{ .dir = .x, .size = .{ .fill, .px(40) }, .gap = 4 });
    const a = t.push(bar, ui.Id.from("a"), &.{ .size = .{ .px(100), .fill } });
    const b = t.push(bar, ui.Id.from("b"), &.{ .size = .{ .fill, .fill } });
    t.seal(bar);
    // A wrapping paragraph in a 100 px column.
    const col = t.push(root, .none, &.{ .size = .{ .px(100), .fit } });
    const para = t.push(col, .none, &.{ .shrink = true });
    const words = "twenty-four characters!!";
    t.c.text[para] = tx.push(para, strings.add(words), &.{ .px = 10, .wrap = true });
    t.seal(col);
    const body = t.push(root, ui.Id.from("body"), &.{ .size = .{ .fill, .fill } });
    t.seal(root);
    t.c.sense[a] = @bitCast(ui.Sense.button);
    t.c.sense[body] = @bitCast(ui.Sense.button);

    // The same sequence Frame.end runs, spelled out.
    const font: ui.fonts.Mono = .{ .advance = 0.5, .line = 1.2 };
    font.measure(&tx);
    ui.layout.prepare(&t);
    ui.layout.applyText(&t, &tx, .x);
    ui.layout.fit(&t, .x);
    ui.layout.resolve(&t, .x, 400);
    ui.layout.textAvail(&t, &tx);
    font.wrap(&tx); // 24 bytes * 5 px = 120 px into 100 px: two lines
    ui.layout.applyText(&t, &tx, .y);
    ui.layout.fit(&t, .y);
    ui.layout.resolve(&t, .y, 300);
    ui.layout.place(&t);
    ui.layout.finalize(&t);

    try expectEqual(ui.Rect{ .x0 = 10, .y0 = 10, .x1 = 390, .y1 = 50 }, t.rect(bar));
    try expectEqual(ui.Rect{ .x0 = 10, .y0 = 10, .x1 = 110, .y1 = 50 }, t.rect(a));
    try expectEqual(ui.Rect{ .x0 = 114, .y0 = 10, .x1 = 390, .y1 = 50 }, t.rect(b));
    try expectEqual(ui.Rect{ .x0 = 10, .y0 = 55, .x1 = 110, .y1 = 79 }, t.rect(para));
    try expectEqual(ui.Rect{ .x0 = 10, .y0 = 84, .x1 = 390, .y1 = 290 }, t.rect(body));

    // Hit testing reads the same columns.
    try expectEqual(a, ui.hit.at(&t, 50, 20, .any));
    try expectEqual(body, ui.hit.at(&t, 50, 100, .any));
    try expectEqual(ui.none, ui.hit.at(&t, 200, 20, .any));
}

test "running out of rows is reported, not fatal" {
    const tiny: ui.Limits = .{ .nodes = 8, .texts = 2, .customs = 1, .strings = 16, .anims = 2, .signals = 2, .memos = 1, .depth = 3 };
    var small: [ui.Context.requiredBytes(tiny)]u8 align(ui.mem.column_align) = undefined;
    var ctx = try ui.Context.init(&small, tiny);
    try std.testing.expectError(error.BufferTooSmall, ui.Context.init(small[0..64], tiny));

    const in: ui.Input = .{};
    var f = ctx.begin(&in);
    for (0..40) |i| {
        _ = f.open(ui.Id.from("n").with(@intCast(i)), .{ .pad = @splat(1) });
        _ = f.text("a long label that will not fit", .{});
    }
    for (0..40) |_| f.close();
    const out = f.end(.{});
    try expect(out.status.nodes and out.status.texts and out.status.strings and out.status.depth);
    try expect(out.tree.len <= tiny.nodes);
}
