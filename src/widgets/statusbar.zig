//! Status bar (tier 2): a strip along the foot of a window showing short pieces of status
//! text side by side ("Ready", "Ln 4, Col 12"). The texts are application state (strings).
//! Written against the public API of tiers 0 and 1 (src/widgets/base.zig has the recipe).
//!
//! Runtime: `statusbar.bar(f, th, &.{ "Ready", "Ln 4" })`.
//! Comptime: `statusbar.ct.statusbar(th, .{ .status, .position })`.

const std = @import("std");
const base = @import("base.zig");
const types = @import("../core/types.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const spec_zig = @import("../comptime/spec.zig");
const Spec = spec_zig.Spec;
const Style = types.Style;
const Node = types.Node;
const Theme = base.Theme;

// ---- spec ---------------------------------------------------------------------------------

/// A status bar showing `texts` side by side, the first at the start. Returns its node.
pub fn bar(f: *Frame, th: *const Theme, texts: []const []const u8) Node {
    const n = f.open(.none, barStyle(th));
    for (texts) |s| _ = base.label(f, th, s);
    f.close();
    return n;
}

/// The strip: as wide as its parent, on the panel colour, its texts in a row spaced by two
/// pads, inset by a pad at the ends and by the gap above and below (a status bar is
/// thinner than a toolbar).
pub fn barStyle(th: *const Theme) Style {
    return .{ .dir = .x, .size = .{ .fill, .fit }, .pad = .{ th.pad, th.gap, th.pad, th.gap }, .gap = 2 * th.pad, .cross = .center, .fill = th.panel };
}

/// The status bar as a spec node.
pub const ct = struct {
    /// A status bar showing the string fields `texts` (a tuple of field names) side by side.
    /// It takes no input, so it has no id. Mistakes are compile errors: no texts, or a name
    /// that is not a string field of the state struct (`ComptimeUi`).
    pub fn statusbar(comptime th: Theme, comptime texts: anytype) Spec {
        if (texts.len == 0) @compileError("a status bar shows at least one text");
        var kids: [texts.len]Spec = undefined;
        for (&kids, texts) |*k, t| k.* = base.ct.label(th, t);
        return spec_zig.row(barStyle(&th), kids);
    }
};

// ---- tests --------------------------------------------------------------------------------

const testing = std.testing;
const Input = @import("../core/input.zig").Input;

/// A window: a body that fills it, with a button, and a status bar of two texts at its foot.
fn Page(comptime th: Theme) type {
    const window: Style = .{ .dir = .y, .size = .{ .fill, .fill } };
    const body: Style = .{ .dir = .y, .size = .{ .fill, .fill }, .pad = @splat(8) };
    return struct {
        pub const App = struct {
            saves: u32 = 0,
            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.none, window);
                _ = f.open(.none, body);
                app.saves += @intFromBool(base.button(f, &th, .from("save"), "Save").clicked);
                f.close();
                const saved: []const u8 = if (app.saves > 0) "Saved" else "Ready";
                _ = bar(f, &th, &.{ saved, "Ln 4, Col 12" });
                f.close();
            }
        };
        pub const State = struct {
            save_text: []const u8 = "Save",
            status: []const u8 = "Ready",
            position: []const u8 = "Ln 4, Col 12",
        };
        pub const spec = spec_zig.col(window, .{
            spec_zig.col(body, .{base.ct.button(th, .save, .save_text)}),
            ct.statusbar(th, .{ .status, .position }),
        });
        pub const Ui = base.ComptimeUi(State, spec, th);
        pub const Run = base.Harness(App, Ui, .{ .nodes = 32, .texts = 8, .customs = 1, .strings = 256, .depth = 8 });
    };
}

const Default = Page(.default);
var harness: Default.Run = .{};

/// Tree rows: root 0, window 1, body 2, button 3 (label 4), bar 5, texts 6 and 7.
const rows = struct {
    const bar = 5;
    const text = [2]u32{ 6, 7 };
};

test "statusbar: both front ends build a strip of texts at the window's foot" {
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 200 } };
    const out = try h.frame(&in);
    const t = out.runtime.tree;
    try testing.expectEqual(@as(u32, 8), t.len);
    const r = t.rect(rows.bar);
    try testing.expectEqual(@as(f32, 320), r.w());
    try testing.expectEqual(@as(f32, 200), r.y1);
    try testing.expect(t.rect(rows.text[1]).x0 >= t.rect(rows.text[0]).x1);
}

test "statusbar: on the panel colour, texts inset and spaced; any theme alike" {
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 200 } };
    const out = try h.frame(&in);
    const th = Theme.default;
    const t = out.runtime.tree;
    const r = t.rect(rows.bar);
    try testing.expectEqual(th.panel.bitsOf(), t.c.look[rows.bar].fill);
    try testing.expectEqual(r.x0 + th.pad, t.rect(rows.text[0]).x0);
    try testing.expectEqual(r.y0 + th.gap, t.rect(rows.text[0]).y0);
    try testing.expectEqual(t.rect(rows.text[0]).x1 + 2 * th.pad, t.rect(rows.text[1]).x0);
    try testing.expectEqual(th.text.bitsOf(), out.runtime.texts.c.color[t.c.text[rows.text[0]]]);

    const Light = Page(.{ .panel = .rgb(240, 240, 240), .text = .rgb(20, 20, 20), .pad = 12, .gap = 10 });
    const S = struct {
        var light: Light.Run = .{};
    };
    S.light.init();
    const lo = try S.light.frame(&in);
    const lt = lo.runtime.tree;
    try testing.expectEqual(lt.rect(rows.bar).x0 + 12, lt.rect(rows.text[0]).x0);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
