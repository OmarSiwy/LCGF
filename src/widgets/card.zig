//! Card and group box (tier 2): a container that frames the widgets inside it under a title.
//! A card is a filled panel; a group box is an outlined frame with a caption. Both are one
//! node with the title as its first child, then the caller's children. Written against the
//! public API of tiers 0 and 1 (src/widgets/base.zig has the recipe).
//!
//! Runtime: `card.open(f, th, .card, "Render")`, the children, then `f.close()`.
//! Comptime: `card.ct.card(th, .card, .title, .{ ...children })`, `title` a string field of
//! the state struct.

const std = @import("std");
const base = @import("base.zig");
const types = @import("../core/types.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const spec_zig = @import("../comptime/spec.zig");
const Spec = spec_zig.Spec;
const Style = types.Style;
const Node = types.Node;
const Theme = base.Theme;

/// Which frame the container draws.
pub const Variant = enum(u1) { card, group_box };

// ---- spec ---------------------------------------------------------------------------------

/// Starts a card or group box titled `title` and returns its node. Everything built until the
/// matching `f.close()` is inside it, below the title.
pub fn open(f: *Frame, th: *const Theme, variant: Variant, title: []const u8) Node {
    const n = f.open(.none, style(th, variant));
    _ = base.label(f, th, title);
    return n;
}

/// The node of a card or group box: a column, padded, its children spaced by the theme's gap.
pub fn style(th: *const Theme, variant: Variant) Style {
    _ = variant;
    return .{ .dir = .y, .pad = @splat(th.pad), .gap = th.gap };
}

/// The containers as spec nodes.
pub const ct = struct {
    /// A card or group box titled by the string field `title`, holding `children` (a tuple of
    /// specs). It takes no input, so it has no id. Mistakes are compile errors: an empty
    /// `children`, or a `title` that is not a string field of the state struct (`ComptimeUi`).
    pub fn card(comptime th: Theme, comptime variant: Variant, comptime title: @EnumLiteral(), comptime children: anytype) Spec {
        if (children.len == 0) @compileError("card '" ++ @tagName(title) ++ "' holds nothing; give it at least one child");
        return spec_zig.col(style(&th, variant), .{base.ct.label(th, title)} ++ children);
    }
};

// ---- tests --------------------------------------------------------------------------------

const testing = std.testing;
const context = @import("../runtime/context.zig");
const Input = @import("../core/input.zig").Input;

/// A card holding a button and a group box holding a checkbox, in both front ends.
fn Page(comptime th: Theme) type {
    return struct {
        pub const App = struct {
            wire: bool = false,
            pub fn build(app: *App, f: *Frame) void {
                _ = open(f, &th, .card, "Render");
                _ = base.button(f, &th, .from("go"), "Go");
                _ = open(f, &th, .group_box, "Options");
                _ = base.checkbox(f, &th, .from("wire"), &app.wire, "Wireframe");
                f.close();
                f.close();
            }
        };
        pub const State = struct {
            title: []const u8 = "Render",
            go_text: []const u8 = "Go",
            options: []const u8 = "Options",
            wire: bool = false,
            wire_text: []const u8 = "Wireframe",
        };
        pub const spec = ct.card(th, .card, .title, .{
            base.ct.button(th, .go, .go_text),
            ct.card(th, .group_box, .options, .{base.ct.checkbox(th, .wire, .wire, .wire_text)}),
        });
        pub const Run = base.Harness(App, base.ComptimeUi(State, spec, th), .{ .nodes = 32, .texts = 8, .customs = 1, .strings = 256, .depth = 8 });
    };
}

const Default = Page(.default);
var harness: Default.Run = .{};

test "card: both front ends build the same rows: the container, its title, then its children" {
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 400, 300 } };
    const out = try h.frame(&in);
    const t = out.runtime.tree;
    // root, card, title, button, its label, group box, caption, checkbox, its box and caption
    try testing.expectEqual(@as(u32, 10), t.len);
    const card_row: u32 = 1;
    const group_row: u32 = 5;
    try testing.expectEqual(card_row, t.c.parent[card_row + 1]);
    try testing.expectEqual(card_row, t.c.parent[group_row]);
    try testing.expectEqual(group_row, t.c.parent[group_row + 1]);
    // The title is the container's first child, padded in by the theme's pad.
    const r = t.rect(card_row);
    const title = t.rect(card_row + 1);
    try testing.expectEqual(r.x0 + Theme.default.pad, title.x0);
    try testing.expectEqual(r.y0 + Theme.default.pad, title.y0);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
