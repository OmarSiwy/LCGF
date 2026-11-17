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

/// The comptime node a runtime `Frame` fills: a custom draw (`Spec.widget`), so the draw list
/// keeps its place for `compose`.
const Region = struct {
    pub fn push(ui: anytype, comptime n: s.Spec, parent: u32, next: *u32, in: *const Input) void {
        _ = in;
        next.* += 1;
        const tb = &ui.tables;
        const i = tb.t.push(parent, list_id, &n.style);
        tb.t.c.custom[i] = tb.cu.push(i, list_id, 0);
        tb.t.seal(i);
    }
};

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
    s.Spec{ .kind = .col, .style = .{ .size = .{ .fill, .fill } }, .widget = Region },
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
