//! One fixture through both Zig frontends (plan §1.4, M7.2): the runtime page `page_rt`
//! (`Ui.build` over a `Frame`) against the comptime page `page` (`ComptimeUi`), both generated
//! from the same HTML. base.Harness checks their draw lists, row counts and accessibility
//! columns frame by frame, over the twin's replay or a pointer sweep.

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

test "the runtime and the spec frontend draw the same frames" {
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
