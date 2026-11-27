//! Mixed front ends: one program, both front ends, one draw list (src/comptime/interop.zig).
//! `zig build ct-mixed` runs its tests, then the program.
//!
//! Page A is a comptime toolbar (fixed structure, state in tables) above a region that a runtime
//! `Frame` fills with a data-driven list; page B is a runtime page with a comptime mixer panel in
//! one of its nodes. Each frame the host runs the outer front end, reads the region's rect from
//! its tree, runs the inner one over `regionInput`, and `compose`s the two draw lists into the
//! one it hands to a renderer. The comptime side is widgets' `ComptimeUi`, which paints with the
//! tier-0 passes until the comptime paint (lane ct-paint) lands.

const std = @import("std");
const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const interop = lcgf.ct_interop;
const mem = lcgf.mem;
const Context = lcgf.context.Context;
const Limits = lcgf.context.Limits;
const Frame = lcgf.frame.Frame;
const Input = lcgf.input.Input;
const DrawList = lcgf.draw_list.DrawList;
const Id = lcgf.types.Id;
const Rect = lcgf.types.Rect;
const Mono = lcgf.protocol.Mono;
const Color = lcgf.types.Color;
const CanvasDraw = lcgf.draw_list.CanvasDraw;
const Damage = lcgf.damage.Damage;
const sw = lcgf.render_sw;

const th: w.Theme = .default;
const font: Mono = .{};

fn rect4(r: Rect) [4]f32 {
    return .{ r.x0, r.y0, r.x1, r.y1 };
}

/// The draw list the renderer gets: room for both front ends' rows.
const Out = struct {
    buf: [bytes]u8 align(mem.column_align) = undefined,
    draw: DrawList = undefined,
    strings: [4096]u8 = undefined,

    const nodes = 256;
    const texts = 64;
    const customs = 4;
    const bytes = blk: {
        var counter: mem.Carver = .{ .buf = null };
        _ = DrawList.init(&counter, nodes, texts, customs);
        break :blk counter.off;
    };

    fn init(o: *Out) void {
        var carver: mem.Carver = .{ .buf = &o.buf };
        o.draw = DrawList.init(&carver, nodes, texts, customs);
    }
};

const list_limits: Limits = .{ .nodes = 64, .texts = 16, .customs = 1, .strings = 1024, .depth = 8 };

// ---- page A: runtime list in a comptime region ---------------------------------------------

const list_id: Id = .from("list");

const Toolbar = struct {
    add_text: []const u8 = "Add",
    show: bool = true,
    show_text: []const u8 = "Show list",
};
const page_a = s.col(.{ .size = .{ .fill, .fill } }, .{
    s.row(.{ .size = .{ .fill, .fit }, .pad = @splat(8), .gap = 8, .cross = .center, .fill = th.panel }, .{
        w.ct.button(th, .add, .add_text),
        w.ct.checkbox(th, .show_box, .show, .show_text),
    }),
    interop.region(.list, .{ .size = .{ .fill, .fill } }),
});

const item_names = [_][]const u8{ "Item 0", "Item 1", "Item 2", "Item 3", "Item 4", "Item 5", "Item 6", "Item 7" };

const PageA = struct {
    ui: w.ComptimeUi(Toolbar, page_a, th) = .{},
    buffer: [Context.requiredBytes(list_limits)]u8 align(mem.column_align) = undefined,
    ctx: Context = undefined,
    out: Out = .{},
    items: u32 = 3,
    picked: ?u32 = null,

    fn init(p: *PageA) void {
        p.ctx = Context.init(&p.buffer, list_limits) catch unreachable;
        p.out.init();
    }

    fn frame(p: *PageA, in: *const Input) !*const DrawList {
        const top = p.ui.frame(in);
        if (top.event) |e| switch (e) {
            .add => p.items = @min(p.items + 1, item_names.len),
            .show_box => {}, // the checkbox has written `show`
            .list => {}, // the embedded list handles its own pointer events
        };
        const region = rect4(top.tree.rect(top.tree.find(list_id)));
        const sub = interop.regionInput(in, region);
        var f = p.ctx.begin(&sub);
        if (p.ui.signals.state.show) {
            _ = f.open(.none, .{ .dir = .y, .size = .{ .fill, .fit }, .pad = @splat(8), .gap = 4 });
            for (item_names[0..p.items], 0..) |name, k| {
                if (w.button(&f, &th, .hash(name), name).clicked) p.picked = @intCast(k);
            }
            f.close();
        }
        const inner = f.end(font);
        try interop.compose(&p.out.draw, top.draw, inner.draw, @backingInt(list_id), &p.out.strings);
        return &p.out.draw;
    }
};

// ---- page B: comptime panel in a runtime node ----------------------------------------------

const panel_id: Id = .from("panel");

const Mixer = struct {
    mute_text: []const u8 = "Mute",
    muted: bool = false,
    volume: f32 = 0.5,
};
const panel = s.row(.{ .size = .{ .fill, .fit }, .pad = @splat(8), .gap = 8, .cross = .center }, .{
    w.ct.checkbox(th, .mute, .muted, .mute_text),
    w.ct.slider(th, .volume, .volume),
});

const PageB = struct {
    ui: w.ComptimeUi(Mixer, panel, th) = .{},
    buffer: [Context.requiredBytes(list_limits)]u8 align(mem.column_align) = undefined,
    ctx: Context = undefined,
    out: Out = .{},

    fn init(p: *PageB) void {
        p.ctx = Context.init(&p.buffer, list_limits) catch unreachable;
        p.out.init();
    }

    fn frame(p: *PageB, in: *const Input) !*const DrawList {
        var f = p.ctx.begin(in);
        _ = f.open(.none, .{ .dir = .y, .size = .{ .fill, .fill } });
        _ = w.label(&f, &th, "Channel 1");
        _ = f.custom(panel_id, .{ .size = .{ .fill, .px(40) } }, 0);
        _ = w.label(&f, &th, "Channel 2");
        f.close();
        const outer = f.end(font);
        const region = rect4(outer.tree.rect(outer.tree.find(panel_id)));
        const sub = interop.regionInput(in, region);
        const inner = p.ui.frame(&sub);
        try interop.compose(&p.out.draw, outer.draw, inner.draw, @backingInt(panel_id), &p.out.strings);
        return &p.out.draw;
    }
};

// ---- page C: a comptime page with two runtime regions, composed in a chain -----------------

const canvas_id: Id = .from("canvas");
const side_id: Id = .from("side");

const Header = struct {
    grid: bool = true,
    grid_text: []const u8 = "Grid",
};
const page_c = s.col(.{ .size = .{ .fill, .fill } }, .{
    s.row(.{ .size = .{ .fill, .fit }, .pad = @splat(8), .fill = th.panel }, .{
        w.ct.checkbox(th, .grid_box, .grid, .grid_text),
    }),
    s.row(.{ .size = .{ .fill, .fill } }, .{
        interop.region(.canvas, .{ .size = .{ .fill, .fill } }),
        interop.fitRegion(.side, .{ .size = .{ .fit, .fill } }),
    }),
});

const region_limits: Limits = .{
    .nodes = 8,
    .texts = 2,
    .customs = 2,
    .strings = 64,
    .depth = 4,
    .damage = true,
};
const canvas_ground: Color = .rgb(10, 20, 30);
const canvas_red: Color = .rgb(220, 0, 0);

/// Schemify's frame in small: the page records its damage, each region's context records its
/// own and keeps its list whole, and two composes join them; the result is culled once.
const PageC = struct {
    const Ui = w.ComptimeUi(Header, page_c, th);
    const dm_bytes = blk: {
        var counter: mem.Carver = .{ .buf = null };
        _ = Damage.init(&counter, Ui.nodes);
        break :blk counter.off;
    };
    const shapes_bytes = lcgf.canvas.Instances.requiredBytes(4, 0, 1, .{});

    ui: Ui = .{},
    dm_buf: [dm_bytes]u8 align(mem.column_align) = undefined,
    dm: Damage = undefined,
    canvas_buf: [Context.requiredBytes(region_limits)]u8 align(mem.column_align) = undefined,
    side_buf: [Context.requiredBytes(region_limits)]u8 align(mem.column_align) = undefined,
    canvas_ctx: Context = undefined,
    side_ctx: Context = undefined,
    rows: [2 * region_limits.customs]CanvasDraw = undefined,
    shapes_buf: [shapes_bytes]u8 align(mem.column_align) = undefined,
    shapes: lcgf.canvas.Instances = undefined,
    layers: [1]lcgf.canvas.Layer = .{.of(.{ .stroke = canvas_red, .fill = canvas_red })},
    palette: lcgf.canvas.Palette = undefined,
    ranges: [1]lcgf.canvas.Range = undefined,
    camera: lcgf.canvas.Camera = .{ .offset = .{ 20, 20 } },
    side_w: f32 = 60,
    side_fill: Color = .rgb(0, 0, 200),
    /// The page with the canvas region, then with the side region too.
    mid: Out = .{},
    out: Out = .{},
    mid_canvases: [Out.customs]CanvasDraw = undefined,
    out_canvases: [Out.customs]CanvasDraw = undefined,

    fn init(p: *PageC) !void {
        var dm_carver: mem.Carver = .{ .buf = &p.dm_buf };
        p.dm = Damage.init(&dm_carver, Ui.nodes);
        std.debug.assert(dm_carver.off == dm_bytes);
        p.canvas_ctx = try Context.init(&p.canvas_buf, region_limits);
        p.canvas_ctx.trackDamageWhole();
        p.canvas_ctx.enableCanvas(&p.rows);
        p.side_ctx = try Context.init(&p.side_buf, region_limits);
        p.side_ctx.trackDamageWhole();
        var carver: mem.Carver = .{ .buf = &p.shapes_buf };
        p.shapes = .init(&carver, 4, 0, 1, .{});
        _ = p.shapes.rect(.{ 0, 0 }, .{ 10, 10 }, .{});
        p.ranges = .{p.shapes.since(0)};
        p.palette = .{ .layers = &p.layers };
        p.mid.init();
        p.out.init();
        p.mid.draw.canvases = &p.mid_canvases;
        p.out.draw.canvases = &p.out_canvases;
    }

    /// The composed list of one frame, culled to what changed.
    fn frame(p: *PageC, in: *const Input) !*const DrawList {
        var top = p.ui.frame(in);
        if (interop.setFit(&p.ui, .side, .{ p.side_w, 0 })) top = p.ui.rebuild(in);
        p.ui.recordDamage(&p.dm);

        var sub = interop.regionInput(in, rect4(top.tree.rect(top.tree.find(canvas_id))));
        var f = p.canvas_ctx.begin(&sub);
        const view: lcgf.types.Style = .{ .size = .{ .fill, .fill }, .fill = canvas_ground };
        _ = f.canvas(.from("view"), view, &p.shapes, .{
            .camera = p.camera,
            .palette = &p.palette,
            .ranges = &p.ranges,
        });
        const a = f.end(font).draw;
        try interop.compose(&p.mid.draw, top.draw, a, @backingInt(canvas_id), &p.mid.strings);

        sub = interop.regionInput(in, rect4(top.tree.rect(top.tree.find(side_id))));
        var g = p.side_ctx.begin(&sub);
        _ = g.leaf(.from("swatch"), .{ .size = .{ .px(40), .px(40) }, .fill = p.side_fill });
        const b = g.end(font).draw;
        try interop.compose(&p.out.draw, &p.mid.draw, b, @backingInt(side_id), &p.out.strings);
        lcgf.damage.cull(&p.out.draw, &p.out.draw.damage);
        std.debug.assert(p.out.draw.cmd_len <= top.draw.cmd_len + a.cmd_len + b.cmd_len);
        return &p.out.draw;
    }

    /// Region `id`'s rect in the page, as the last frame laid it out.
    fn regionRect(p: *const PageC, id: Id) [4]f32 {
        const t = &p.ui.tables.t;
        return rect4(t.rect(t.find(id)));
    }
};

/// A 400 x 300 software target that keeps its pixels from frame to frame.
const Screen = struct {
    const size = [2]u32{ 400, 300 };
    pixels: [sw.Framebuffer.len(size[0], size[1])]u32 = undefined,
    glyphs: [256]lcgf.draw_list.Quad = undefined,
    first: [Out.texts]u32 = undefined,
    count: [Out.texts]u32 = undefined,
    setup: sw.Setup = .{},

    fn fb(sc: *Screen) sw.Framebuffer {
        return .init(&sc.pixels, size[0], size[1], .rgba8);
    }

    /// Draws `d` over what the screen holds: only inside `d.damage`.
    fn draw(sc: *Screen, d: *const DrawList) void {
        var target = sc.fb();
        const glyphs = lcgf.render_sw_font.glyphs(d, &sc.glyphs, &sc.first, &sc.count);
        sc.setup.gfx.images = &lcgf.render_sw_font.images;
        sc.setup.draw(&target, d, glyphs, .black, 1);
    }

    fn at(sc: *Screen, x: u32, y: u32) Color {
        return sc.fb().at(x, y);
    }

    /// The pixel `dx`, `dy` from `box`'s corner.
    fn in(sc: *Screen, box: [4]f32, dx: f32, dy: f32) Color {
        return sc.at(@intFromFloat(box[0] + dx), @intFromFloat(box[1] + dy));
    }

    /// Paints one pixel behind the renderer's back: it shows through unless (x, y) is redrawn.
    fn mark(sc: *Screen, x: u32, y: u32) void {
        var target = sc.fb();
        target.fill(.{ x, y, x + 1, y + 1 }, .white);
    }
};

// ---- the program ---------------------------------------------------------------------------

var page_a_: PageA = .{};
var page_b_: PageB = .{};

fn textOf(d: *const DrawList, k: u32) []const u8 {
    const r = d.runs[k];
    return d.strings[r.start..][0..r.bytes];
}

/// A press and a release at window point `at`; returns the draw list after the release.
fn click(page: anytype, in: *Input, at: [2]f32) !*const DrawList {
    in.pointer = at;
    in.buttons.left = true;
    _ = try page.frame(in);
    in.buttons.left = false;
    return page.frame(in);
}

/// The window point at the middle of the text run that shows `text`: what a user would click.
fn spot(d: *const DrawList, text: []const u8) [2]f32 {
    for (0..d.run_len) |k| {
        const r = d.runs[k].rect;
        if (std.mem.eql(u8, textOf(d, @intCast(k)), text)) return .{ (r[0] + r[2]) / 2, (r[1] + r[3]) / 2 };
    }
    std.debug.panic("no text run '{s}'", .{text});
}

fn hasText(d: *const DrawList, text: []const u8) bool {
    for (0..d.run_len) |k| if (std.mem.eql(u8, textOf(d, @intCast(k)), text)) return true;
    return false;
}

pub fn main(init: std.process.Init) !void {
    var buf: [512]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout.interface;
    var in: Input = .{ .viewport = .{ 400, 300 } };

    const a = &page_a_;
    a.init();
    var d = try a.frame(&in);
    try out.print("page A (comptime toolbar, runtime list): {d} commands, {d} quads, {d} text runs\n", .{ d.cmd_len, d.quad_len, d.run_len });
    d = try click(a, &in, spot(d, "Add"));
    try out.print("  clicked Add (comptime): {d} items, {d} text runs\n", .{ a.items, d.run_len });
    d = try click(a, &in, spot(d, "Item 2"));
    try out.print("  clicked Item 2 (runtime): picked {?d}\n", .{a.picked});

    const b = &page_b_;
    b.init();
    in = .{ .viewport = .{ 400, 300 } };
    d = try b.frame(&in);
    try out.print("page B (runtime page, comptime panel): {d} commands, {d} quads, {d} text runs\n", .{ d.cmd_len, d.quad_len, d.run_len });
    d = try click(b, &in, spot(d, "Mute"));
    try out.print("  clicked Mute (comptime): muted {}\n", .{b.ui.signals.state.muted});
    try out.flush();
}

// ---- tests ---------------------------------------------------------------------------------

const testing = std.testing;

test "page A: a comptime toolbar's events and a runtime list's clicks, one draw list" {
    const a = &page_a_;
    a.* = .{};
    a.init();
    var in: Input = .{ .viewport = .{ 400, 300 } };
    var d = try a.frame(&in);
    // The toolbar's texts (comptime) and the list's (runtime) in one draw list, in paint order.
    try testing.expectEqual(5, d.run_len); // Add, Show list, Item 0..2
    try testing.expectEqualStrings("Add", textOf(d, 0));
    try testing.expectEqualStrings("Item 0", textOf(d, 2));
    // The list is laid out below the toolbar, in window coordinates.
    try testing.expect(spot(d, "Item 0")[1] > spot(d, "Add")[1] + 10);

    d = try click(a, &in, spot(d, "Add"));
    try testing.expectEqual(4, a.items);
    d = try a.frame(&in);
    try testing.expect(hasText(d, "Item 3"));

    d = try click(a, &in, spot(d, "Item 2"));
    try testing.expectEqual(@as(?u32, 2), a.picked);

    // Unchecking the comptime checkbox empties the runtime region: its command goes too.
    const before = d.cmd_len;
    d = try click(a, &in, spot(d, "Show list"));
    try testing.expect(!a.ui.signals.state.show);
    d = try a.frame(&in);
    try testing.expect(!hasText(d, "Item 0"));
    try testing.expect(d.cmd_len < before);
}

test "page B: a comptime panel's widgets inside a runtime page, one draw list" {
    const b = &page_b_;
    b.* = .{};
    b.init();
    var in: Input = .{ .viewport = .{ 400, 300 } };
    var d = try b.frame(&in);
    // Channel 1 (runtime), Mute (comptime), Channel 2 (runtime): the panel paints where its node is.
    try testing.expectEqual(3, d.run_len);
    var order: [3][]const u8 = undefined;
    var n: usize = 0;
    for (0..d.cmd_len) |i| switch (d.command(@intCast(i))) {
        .text => |run| {
            order[n] = textOf(d, run);
            n += 1;
        },
        else => {},
    };
    try testing.expectEqual(3, n);
    for ([_][]const u8{ "Channel 1", "Mute", "Channel 2" }, order) |want, got| try testing.expectEqualStrings(want, got);
    const mute = spot(d, "Mute");
    try testing.expect(mute[1] > spot(d, "Channel 1")[1] and mute[1] < spot(d, "Channel 2")[1]);

    d = try click(b, &in, mute);
    try testing.expect(b.ui.signals.state.muted);

    // The slider, judged in the panel's coordinates: its rect there plus the node's origin.
    const r = b.ui.rects.c;
    const k = comptime @TypeOf(b.ui).Events.slot(.volume);
    const node = b.ctx.trees[b.ctx.cur].rect(b.ctx.trees[b.ctx.cur].find(panel_id));
    in.pointer = .{ node.x0 + r[0][k] + 0.75 * (r[2][k] - r[0][k]), node.y0 + (r[1][k] + r[3][k]) / 2 };
    in.buttons.left = true;
    _ = try b.frame(&in);
    try testing.expectApproxEqAbs(@as(f32, 0.75), b.ui.signals.state.volume, 0.02);
}

/// True when some slot of `g` holds all of `box`.
fn covered(g: *const lcgf.damage.Region, box: [4]f32) bool {
    for (0..lcgf.damage.max_rects) |k| {
        const r = g.rect(@intCast(k));
        if (r[0] <= box[0] and r[1] <= box[1] and r[2] >= box[2] and r[3] >= box[3]) return true;
    }
    return false;
}

/// Pixel (x, y) of the screen at the middle of `box`.
fn middle(box: [4]f32) [2]u32 {
    return .{ @intFromFloat((box[0] + box[2]) / 2), @intFromFloat((box[1] + box[3]) / 2) };
}

test "page C: a composed page redraws only what changed in the page or a region" {
    const S = struct {
        var p: PageC = .{};
        var screen: Screen = .{};
    };
    const p = &S.p;
    const sc = &S.screen;
    try p.init();
    const in: Input = .{ .viewport = .{ 400, 300 } };

    // The first frame draws everything: the page and both regions.
    sc.draw(try p.frame(&in));
    const canvas = p.regionRect(canvas_id);
    const side = p.regionRect(side_id);
    try testing.expectEqual(canvas[2], side[0]);
    try testing.expectEqual(60, side[2] - side[0]);
    try testing.expectEqual(canvas_red, sc.in(canvas, 25, 25));
    try testing.expectEqual(Color.rgb(0, 0, 200), sc.in(side, 20, 20));

    // Idle: nothing changed, nothing is drawn.
    sc.mark(5, 5);
    var d = try p.frame(&in);
    try testing.expectEqual(0, d.damage.count());
    try testing.expectEqual(0, d.quad_len);
    sc.draw(d);
    try testing.expectEqual(Color.white, sc.at(5, 5));

    // A pan of the canvas: its node's rect in the page, nothing else; a pixel outside it stays.
    const side_mid = middle(side);
    sc.mark(side_mid[0], side_mid[1]);
    p.camera.offset = .{ 60, 60 };
    d = try p.frame(&in);
    try testing.expectEqual(1, d.damage.count());
    try testing.expectEqual(canvas, d.damage.bounds());
    sc.draw(d);
    try testing.expectEqual(canvas_red, sc.in(canvas, 65, 65));
    try testing.expectEqual(canvas_ground, sc.in(canvas, 25, 25));
    try testing.expectEqual(Color.white, sc.at(side_mid[0], side_mid[1]));
    try testing.expectEqual(Color.white, sc.at(5, 5));

    // A comptime widget's state: within that widget's rect; the regions keep their pixels.
    const k = comptime PageC.Ui.Events.slot(.grid_box);
    const r = p.ui.rects.c;
    const widget = [4]f32{ r[0][k], r[1][k], r[2][k], r[3][k] };
    const canvas_mid = middle(canvas);
    sc.mark(canvas_mid[0], canvas_mid[1]);
    p.ui.signals.state.grid = false;
    d = try p.frame(&in);
    try testing.expect(d.damage.count() > 0);
    var within: lcgf.damage.Region = .empty;
    within.add(widget);
    try testing.expect(covered(&within, d.damage.bounds()));
    sc.draw(d);
    try testing.expectEqual(Color.white, sc.at(canvas_mid[0], canvas_mid[1]));
    try testing.expectEqual(Color.white, sc.at(side_mid[0], side_mid[1]));

    // The second region's content: its swatch's rect in the page, nothing else.
    p.side_fill = .rgb(0, 200, 0);
    d = try p.frame(&in);
    try testing.expectEqual(1, d.damage.count());
    const swatch = [4]f32{ side[0], side[1], side[0] + 40, side[1] + 40 };
    try testing.expectEqual(swatch, d.damage.bounds());
    sc.draw(d);
    try testing.expectEqual(Color.rgb(0, 200, 0), sc.in(side, 20, 20));
    try testing.expectEqual(Color.white, sc.at(canvas_mid[0], canvas_mid[1]));

    // The side region grows: both regions' old and new rects are redrawn.
    p.side_w = 100;
    d = try p.frame(&in);
    const side2 = p.regionRect(side_id);
    const canvas2 = p.regionRect(canvas_id);
    try testing.expectEqual(100, side2[2] - side2[0]);
    for ([_][4]f32{ side, side2, canvas, canvas2 }) |box|
        try testing.expect(covered(&d.damage, box));
    sc.draw(d);
    try testing.expectEqual(Color.rgb(0, 200, 0), sc.in(side2, 20, 20));
}
