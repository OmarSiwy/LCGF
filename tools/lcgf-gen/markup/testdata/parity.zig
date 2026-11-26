//! One fixture through both Zig frontends (plan §1.4, M7.2): the runtime page `page_rt`
//! (`Ui.build` over a `Frame`) against the comptime page `page` (`ComptimeUi`), both generated
//! from the same HTML. base.Harness checks their draw lists, row counts and accessibility
//! columns frame by frame, over the twin's replay or a pointer sweep. A page with run-time
//! regions (`twin.Sample`) runs through both `Page.frame`s over the same items instead: the
//! comptime page composes each region's draw list into its own, so the two draw the same
//! commands, quads and text, though not in the same arrays.

const std = @import("std");
const lcgf = @import("lcgf");
const page = @import("page");
const rt = @import("page_rt");
const twin = @import("twin");

const Replay = lcgf.input.Replay;

var harness: lcgf.widgets_base.Harness(rt.Ui, page.Ui, rt.limits) = undefined;

/// Hover, press and release at points across the top of the page, where the fixtures' widgets are.
const sweep =
    \\frame
    \\viewport 800 600
    \\pointer 400 300
    \\frame
    \\pointer 12 12
    \\frame
    \\buttons left
    \\frame
    \\buttons
    \\frame
    \\pointer 40 40
    \\frame
    \\buttons left
    \\frame
    \\buttons
    \\frame
    \\pointer 20 70
    \\frame
    \\buttons left
    \\frame
    \\buttons
;

const regions = @hasDecl(twin, "Sample");

test "the runtime and the spec frontend draw the same frames" {
    if (regions) return;
    const h = &harness;
    h.init();
    var text: [16]u8 = undefined;
    var evs: [8]lcgf.input.Input.Event = undefined;
    var contacts: [1]lcgf.input.Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &evs, .contacts = &contacts };
    inline for (.{ if (@hasDecl(twin, "replay")) twin.replay else sweep, sweep }) |src| {
        h.init();
        var replay: Replay = .{ .src = src };
        while (try replay.next(buf)) |in| {
            _ = try h.frame(in);
            // The two state stores move together.
            inline for (comptime @typeInfo(rt.State).@"struct".field_names) |f| {
                const a = @field(h.app.signals.state, f);
                const b = @field(h.ui.signals.state, f);
                if (@typeInfo(@TypeOf(a)) == .@"enum")
                    try std.testing.expectEqualStrings(@tagName(b), @tagName(a))
                else if (@typeInfo(@TypeOf(a)) != .@"struct")
                    try std.testing.expectEqual(b, a);
            }
        }
    }
}

var semantic: lcgf.widgets_base.Semantic(rt.limits.nodes) = .{};

test "both front ends give assistive technology the same tree and names" {
    if (regions) return;
    const h = &harness;
    h.init();
    var text: [16]u8 = undefined;
    var evs: [8]lcgf.input.Input.Event = undefined;
    var contacts: [1]lcgf.input.Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &evs, .contacts = &contacts };
    var replay: Replay = .{ .src = sweep };
    while (try replay.next(buf)) |in| {
        _ = try h.frame(in);
        try semantic.run(h);
    }
    // The names the twin lists (aria-label, a <label>'s text) are in the export.
    if (@hasDecl(twin, "names")) inline for (twin.names) |want| {
        for (0..semantic.out[0].len) |r| {
            if (std.mem.eql(u8, semantic.name(0, @intCast(r)), want)) break;
        } else {
            std.debug.print("no exported node is named '{s}'\n", .{want});
            return error.NameMissing;
        }
    };
}

test "the runtime page takes the twin's handlers" {
    if (!@hasDecl(twin, "Handlers")) return;
    const H = twin.Handlers(rt.Ui);
    _ = rt.Page(H);
    var ui: rt.Ui = .{};
    var h: H = .{};
    ui.dispatch(&h);
}

/// `a` and `b` equal, but for their rect and clip edges, which may differ by the one pixel of
/// rounding a region at a fractional origin gives: the comptime page snaps the region's rect
/// and then its content in it, the runtime page snaps the content where it is (engine E3).
fn expectSnapped(a: anytype, b: @TypeOf(a)) !void {
    var y = b;
    inline for (.{ "rect", "clip" }) |name| {
        for (@field(a, name), @field(b, name)) |p, q| if (!(p == q or @abs(p - q) <= 1)) {
            std.debug.print("{s} {any} against {any}\n", .{ name, @field(a, name), @field(b, name) });
            return error.TestExpectedEqual;
        };
        @field(y, name) = @field(a, name);
    }
    try std.testing.expectEqualDeep(a, y);
}

/// The draw list `d`'s commands in paint order, one item each: a quad batch is its quads, so
/// two lists that batch differently compare the same.
fn expectSameCommands(a: *const lcgf.draw_list.DrawList, b: *const lcgf.draw_list.DrawList) !void {
    var ia: u32 = 0;
    var ib: u32 = 0;
    var qa: u32 = 0; // quads of command `ia` already compared
    var qb: u32 = 0;
    while (ia < a.cmd_len and ib < b.cmd_len) {
        const ca = a.command(ia);
        const cb = b.command(ib);
        try std.testing.expectEqual(std.meta.activeTag(ca), std.meta.activeTag(cb));
        switch (ca) {
            .quads => |x| {
                const y = cb.quads;
                try std.testing.expectEqual(x.texture, y.texture);
                try std.testing.expectEqual(x.material, y.material);
                try expectSnapped(a.quads[x.first + qa], b.quads[y.first + qb]);
                qa += 1;
                qb += 1;
                if (qa == x.count) {
                    ia += 1;
                    qa = 0;
                }
                if (qb == y.count) {
                    ib += 1;
                    qb = 0;
                }
                continue;
            },
            .text => |x| {
                var ra = a.runs[x];
                var rb = b.runs[cb.text];
                try std.testing.expectEqualStrings(a.strings[ra.start..][0..ra.bytes], b.strings[rb.start..][0..rb.bytes]);
                ra.start = 0;
                rb.start = 0;
                try expectSnapped(ra, rb);
            },
            .custom, .canvas => |x| try std.testing.expectEqualDeep(a.customs[x], b.customs[cb.custom]),
        }
        ia += 1;
        ib += 1;
    }
    try std.testing.expectEqual(a.cmd_len, ia);
    try std.testing.expectEqual(b.cmd_len, ib);
}

const Context = lcgf.context.Context;
const regions_side = if (regions) struct {
    var cp: page.Page(twin.Handlers(page.Ui)) = .{};
    var rp: rt.Page(twin.Handlers(rt.Ui)) = .{};
    var buffer: [Context.requiredBytes(rt.limits)]u8 align(lcgf.mem.column_align) = undefined;
} else void;

test "a page with regions draws the same frames in both frontends over the same items" {
    if (!regions) return;
    const S = regions_side;
    var text: [16]u8 = undefined;
    var evs: [8]lcgf.input.Input.Event = undefined;
    var contacts: [1]lcgf.input.Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &evs, .contacts = &contacts };
    inline for (.{ if (@hasDecl(twin, "replay")) twin.replay else sweep, sweep }) |src| {
        S.cp = .{};
        S.rp = .{};
        var ctx = try Context.init(&S.buffer, rt.limits);
        var items_c: twin.Sample = .{};
        var items_r: twin.Sample = .{};
        var hc: twin.Handlers(page.Ui) = .{};
        var hr: twin.Handlers(rt.Ui) = .{};
        var replay: Replay = .{ .src = src };
        while (try replay.next(buf)) |in| {
            var a = S.cp.frame(&hc, in, items_c.data());
            var b = S.rp.frame(&ctx, &hr, in, items_r.data());
            // A fit region takes last frame's size (E1) and asks for this frame again, as a
            // host then draws it: compare what the host shows.
            if (a.wake == 0) {
                a = S.cp.frame(&hc, in, items_c.data());
                b = S.rp.frame(&ctx, &hr, in, items_r.data());
            }
            try expectSameCommands(a.draw, b.draw);
            // The state, the items and what the handlers saw move together.
            inline for (comptime @typeInfo(rt.State).@"struct".field_names) |f| {
                const x = @field(S.cp.ui.signals.state, f);
                const y = @field(S.rp.ui.signals.state, f);
                if (@typeInfo(@TypeOf(x)) == .@"enum")
                    try std.testing.expectEqualStrings(@tagName(x), @tagName(y))
                else if (@typeInfo(@TypeOf(x)) != .@"struct")
                    try std.testing.expectEqual(x, y);
            }
            try std.testing.expectEqualDeep(items_c, items_r);
            inline for (comptime @typeInfo(@TypeOf(hc)).@"struct".field_names) |f|
                try std.testing.expectEqualDeep(@field(hc, f), @field(hr, f));
        }
    }
}
