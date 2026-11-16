//! Accordion (tier 2): sections stacked in a column, each a header that shows or hides the
//! panel below it. Each section's expanded flag is application state (a `bool`). Written
//! against the public API of tiers 0 and 1 (src/widgets/base.zig has the recipe).
//!
//! Runtime: `accordion.open(f, th, id, &expanded, "Title")`, the panel's children, then
//! `accordion.close(f)`. Comptime: `accordion.ct.section(th, .id, .expanded, .title, .{...})`.
//!
//! A collapsed panel is still built, 0 px high and clipping: its rows are there, but nothing
//! in them is painted or hit. That keeps the rows of a section the same in every state, as
//! the comptime front end's fixed tables need (and as a height animation would).

const std = @import("std");
const base = @import("base.zig");
const types = @import("../core/types.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const Input = @import("../core/input.zig").Input;
const spec_zig = @import("../comptime/spec.zig");
const Spec = spec_zig.Spec;
const Style = types.Style;
const Id = types.Id;
const Response = types.Response;
const Theme = base.Theme;

// ---- spec ---------------------------------------------------------------------------------

/// Starts a section with header `title` and the identity `id`, showing its panel while
/// `expanded.*` is set. Everything built until `close` goes in the panel. Returns the
/// header's response.
pub fn open(f: *Frame, th: *const Theme, id: Id, expanded: *bool, title: []const u8) Response {
    _ = f.open(.none, sectionStyle(th));
    const head = f.open(id, headerStyle(th));
    const r = f.interact(head, .button);
    _ = f.leaf(.none, indicatorStyle(th, expanded.*));
    _ = base.label(f, th, title);
    f.close();
    _ = f.open(.none, panelStyle(th, expanded.*));
    return r;
}

/// Ends the section `open` started.
pub fn close(f: *Frame) void {
    f.close();
    f.close();
}

/// A section spans its parent's width: the header above, the panel below.
pub fn sectionStyle(th: *const Theme) Style {
    _ = th;
    return .{ .dir = .y, .size = .{ .fill, .fit } };
}

/// The header: a row across the section holding the indicator and the title.
pub fn headerStyle(th: *const Theme) Style {
    return .{ .dir = .x, .size = .{ .fill, .fit }, .gap = th.gap, .cross = .center, .role = .button };
}

/// The mark before the title that shows whether the section is open.
pub fn indicatorStyle(th: *const Theme, expanded: bool) Style {
    _ = th;
    _ = expanded;
    return .{ .size = .{ .px(8), .px(8) } };
}

/// The panel: as tall as its children when expanded, 0 px and clipping when collapsed,
/// picked by table index.
pub fn panelStyle(th: *const Theme, expanded: bool) Style {
    _ = th;
    const heights = [2]types.Size{ .px(0), .fit };
    return .{ .dir = .y, .size = .{ .fill, heights[@intFromBool(expanded)] }, .clip = true };
}

/// The accordion's sections as spec nodes.
pub const ct = struct {
    /// A section whose header is the widget `id`, titled by the string field `title`, showing
    /// `children` (a tuple of specs) while the bool field `expanded` is set. Mistakes are
    /// compile errors: an empty `children`, an `expanded` that is not a bool field or a
    /// `title` that is not a string field of the state struct.
    pub fn section(comptime th: Theme, comptime id: @EnumLiteral(), comptime expanded: @EnumLiteral(), comptime title: @EnumLiteral(), comptime children: anytype) Spec {
        if (children.len == 0) @compileError("accordion section '" ++ @tagName(id) ++ "' has an empty panel");
        var head = spec_zig.row(headerStyle(&th), .{ Spec{ .kind = .col }, base.ct.label(th, title) });
        head.id = @tagName(id);
        var s = spec_zig.col(sectionStyle(&th), .{ head, spec_zig.col(.{}, children) });
        s.widget = Section(@tagName(id), @tagName(expanded));
        return s;
    }

    /// How the comptime front end builds and drives one section.
    fn Section(comptime id: [:0]const u8, comptime expanded: []const u8) type {
        return struct {
            pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
                const th = @TypeOf(ui.*).theme;
                const t = &ui.tables.t;
                const open_: bool = @field(ui.signals.state, expanded);
                const sec = t.push(parent, .none, &n.style);
                const head = t.push(sec, .hash(id), &n.children[0].style);
                _ = t.push(head, .none, &indicatorStyle(&th, open_));
                next.* += 3;
                ui.push(n.children[0].children[1], head, next, in);
                t.seal(head);
                const panel = t.push(sec, .none, &panelStyle(&th, open_));
                next.* += 1;
                inline for (n.children[1].children) |c| ui.push(c, panel, next, in);
                t.seal(panel);
                t.seal(sec);
            }
        };
    }
};

// ---- tests --------------------------------------------------------------------------------

const testing = std.testing;

/// Two sections: "General" (open) holding a checkbox, "Advanced" (closed) holding a slider.
fn Page(comptime th: Theme) type {
    const column: Style = .{ .dir = .y, .size = .{ .px(240), .fit }, .pad = @splat(8), .gap = 4 };
    return struct {
        pub const App = struct {
            general: bool = true,
            advanced: bool = false,
            wire: bool = false,
            level: f32 = 0.5,
            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.none, column);
                _ = open(f, &th, .from("general"), &app.general, "General");
                _ = base.checkbox(f, &th, .from("wire"), &app.wire, "Wireframe");
                close(f);
                _ = open(f, &th, .from("advanced"), &app.advanced, "Advanced");
                _ = base.slider(f, &th, .from("level"), &app.level, 0, 1);
                close(f);
                f.close();
            }
        };
        pub const State = struct {
            general: bool = true,
            general_text: []const u8 = "General",
            advanced: bool = false,
            advanced_text: []const u8 = "Advanced",
            wire: bool = false,
            wire_text: []const u8 = "Wireframe",
            level: f32 = 0.5,
        };
        pub const spec = spec_zig.col(column, .{
            ct.section(th, .general, .general, .general_text, .{base.ct.checkbox(th, .wire, .wire, .wire_text)}),
            ct.section(th, .advanced, .advanced, .advanced_text, .{base.ct.slider(th, .level, .level)}),
        });
        pub const Ui = base.ComptimeUi(State, spec, th);
        pub const Run = base.Harness(App, Ui, .{ .nodes = 32, .texts = 8, .customs = 1, .strings = 256, .depth = 8 });
    };
}

const Default = Page(.default);
var harness: Default.Run = .{};

test "accordion: both front ends build every section's rows; a collapsed panel is 0 px and clips" {
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 200 } };
    const out = try h.frame(&in);
    const t = out.runtime.tree;
    // root, column, then per section: section, header, indicator, title, panel, content (the
    // checkbox has 2 children, the slider 1)
    try testing.expectEqual(@as(u32, 2 + 8 + 7), t.len);
    const general_panel = t.find(.from("general")) + 3;
    const advanced_panel = t.find(.from("advanced")) + 3;
    try testing.expect(t.rect(general_panel).h() > 0);
    try testing.expectEqual(@as(f32, 0), t.rect(advanced_panel).h());
    // The closed panel's slider is there but invisible.
    try testing.expectEqual(@as(u32, 0), t.c.visible[t.find(.from("level"))]);
    try testing.expectEqual(4, Default.Ui.Events.widget_count);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
