//! Splitter (tier 2): two panes side by side (or one above the other) with a handle between
//! them that moves the split. The split is application state: an `f32`, the first pane's
//! share of the container, 0 to 1. Written against the public API of tiers 0 and 1
//! (src/widgets/base.zig has the recipe).
//!
//! Runtime: `splitter.open(f, th, id, .x, &split)`, the first pane's children,
//! `splitter.handle(f, th, id, .x, split)`, the second pane's children, `splitter.close(f)`.
//! Comptime: `splitter.ct.splitter(th, .id, .x, .split, .{...first}, .{...second})`.

const std = @import("std");
const base = @import("base.zig");
const types = @import("../core/types.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const Input = @import("../core/input.zig").Input;
const spec_zig = @import("../comptime/spec.zig");
const Spec = spec_zig.Spec;
const Style = types.Style;
const Axis = types.Axis;
const Id = types.Id;
const Theme = base.Theme;

/// How thick the handle is across the split, logical pixels.
pub const handle_px: f32 = 6;

// ---- spec ---------------------------------------------------------------------------------

/// Starts a splitter along `axis` (`.x`: panes side by side) whose first pane takes `split.*`
/// of it, and opens the first pane. `id` names the container; the handle is `id.with(1)`.
pub fn open(f: *Frame, th: *const Theme, id: Id, axis: Axis, split: *f32) void {
    _ = f.open(id, containerStyle(th, axis));
    _ = f.open(.none, firstStyle(th, axis, split.*));
}

/// Closes the first pane and opens the second: the handle, then the body that holds the
/// second pane's children.
pub fn handle(f: *Frame, th: *const Theme, id: Id, axis: Axis, split: f32) void {
    f.close();
    _ = f.open(.none, secondStyle(th, axis, split));
    _ = f.leaf(id.with(1), handleStyle(th, axis));
    _ = f.open(.none, bodyStyle(th));
}

/// Closes the second pane and the splitter.
pub fn close(f: *Frame) void {
    f.close();
    f.close();
    f.close();
}

/// The container: fills its parent, its panes laid along `axis`.
pub fn containerStyle(th: *const Theme, axis: Axis) Style {
    _ = th;
    return .{ .dir = axis, .size = .{ .fill, .fill } };
}

/// The first pane: `split` of the container along `axis`, the full container across.
pub fn firstStyle(th: *const Theme, axis: Axis, split: f32) Style {
    _ = th;
    const sizes = [2][2]types.Size{ .{ .pct(base.unit(split)), .fill }, .{ .fill, .pct(base.unit(split)) } };
    return .{ .dir = .y, .size = sizes[@backingInt(axis)], .clip = true };
}

/// The handle: `handle_px` along `axis`, the full container across.
pub fn handleStyle(th: *const Theme, axis: Axis) Style {
    _ = th;
    const sizes = [2][2]types.Size{ .{ .px(handle_px), .fill }, .{ .fill, .px(handle_px) } };
    return .{ .size = sizes[@backingInt(axis)] };
}

/// The second pane: the rest of the container, `1 - split`, holding the handle at its start
/// and then the body. Both panes are percentages of the container, so they always add up to
/// it exactly whatever their contents (a grower would start from its content's size).
pub fn secondStyle(th: *const Theme, axis: Axis, split: f32) Style {
    _ = th;
    const rest = 1 - base.unit(split);
    const sizes = [2][2]types.Size{ .{ .pct(rest), .fill }, .{ .fill, .pct(rest) } };
    return .{ .dir = axis, .size = sizes[@backingInt(axis)] };
}

/// The body of the second pane: what the handle leaves of it.
pub fn bodyStyle(th: *const Theme) Style {
    _ = th;
    return .{ .dir = .y, .size = .{ .fill, .fill }, .clip = true };
}

/// The splitter as a spec node.
pub const ct = struct {
    /// A splitter along `axis` over the f32 field `split`, its handle the widget `id`, its
    /// panes holding `first` and `second` (tuples of specs). Mistakes are compile errors: an
    /// empty pane, or a `split` that is not an f32 field of the state struct.
    pub fn splitter(comptime th: Theme, comptime id: @EnumLiteral(), comptime axis: Axis, comptime split: @EnumLiteral(), comptime first: anytype, comptime second: anytype) Spec {
        if (first.len == 0 or second.len == 0) @compileError("splitter '" ++ @tagName(id) ++ "' has an empty pane");
        var hd: Spec = .{ .kind = .col, .style = handleStyle(&th, axis) };
        hd.id = @tagName(id);
        const rest: Spec = .{ .kind = .col, .style = secondStyle(&th, axis, 0), .children = &.{ hd, spec_zig.col(bodyStyle(&th), second) } };
        var s: Spec = .{ .kind = .col, .style = containerStyle(&th, axis), .children = &.{ spec_zig.col(firstStyle(&th, axis, 0), first), rest } };
        s.widget = Splitter(@tagName(id), axis, @tagName(split));
        return s;
    }

    /// How the comptime front end builds and drives one splitter.
    fn Splitter(comptime id: [:0]const u8, comptime axis: Axis, comptime split: []const u8) type {
        return struct {
            pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
                const th = @TypeOf(ui.*).theme;
                const t = &ui.tables.t;
                const value: f32 = @field(ui.signals.state, split);
                const box = t.push(parent, .none, &n.style);
                const a = t.push(box, .none, &firstStyle(&th, axis, value));
                next.* += 2;
                inline for (n.children[0].children) |c| ui.push(c, a, next, in);
                t.seal(a);
                const rest = t.push(box, .none, &secondStyle(&th, axis, value));
                _ = t.push(rest, .hash(id), &n.children[1].children[0].style);
                const b = t.push(rest, .none, &n.children[1].children[1].style);
                next.* += 3;
                inline for (n.children[1].children[1].children) |c| ui.push(c, b, next, in);
                t.seal(b);
                t.seal(rest);
                t.seal(box);
            }
        };
    }
};

// ---- tests --------------------------------------------------------------------------------

const testing = std.testing;

/// A side-by-side splitter at 30%: a label on the left, a checkbox on the right.
fn Page(comptime th: Theme) type {
    const area: Style = .{ .dir = .y, .size = .{ .px(300), .px(120) }, .pad = @splat(8) };
    return struct {
        pub const App = struct {
            split: f32 = 0.3,
            wire: bool = false,
            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.none, area);
                open(f, &th, .from("split"), .x, &app.split);
                _ = base.label(f, &th, "Files");
                handle(f, &th, .from("split"), .x, app.split);
                _ = base.checkbox(f, &th, .from("wire"), &app.wire, "Wireframe");
                close(f);
                f.close();
            }
        };
        pub const State = struct {
            split: f32 = 0.3,
            files: []const u8 = "Files",
            wire: bool = false,
            wire_text: []const u8 = "Wireframe",
        };
        pub const spec = spec_zig.col(area, .{ct.splitter(th, .split_handle, .x, .split, .{base.ct.label(th, .files)}, .{base.ct.checkbox(th, .wire, .wire, .wire_text)})});
        pub const Ui = base.ComptimeUi(State, spec, th);
        pub const Run = base.Harness(App, Ui, .{ .nodes = 32, .texts = 8, .customs = 1, .strings = 256, .depth = 8 });
    };
}

const Default = Page(.default);
var harness: Default.Run = .{};

/// Tree rows: root 0, area 1, container 2, first pane 3 (label 4), second pane 5, handle 6,
/// body 7 (checkbox 8..10).
const rows = struct {
    const box = 2;
    const first = 3;
    const second = 5;
    const handle = 6;
    const body = 7;
};

test "splitter: both front ends split the container at the bound fraction around the handle" {
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 200 } };
    const out = try h.frame(&in);
    const t = out.runtime.tree;
    try testing.expectEqual(@as(u32, 11), t.len);
    const box = t.rect(rows.box);
    try testing.expectApproxEqAbs(0.3 * box.w(), t.rect(rows.first).w(), 0.5);
    try testing.expectEqual(handle_px, t.rect(rows.handle).w());
    try testing.expectEqual(t.rect(rows.first).x1, t.rect(rows.handle).x0);
    try testing.expectEqual(t.rect(rows.first).x1, t.rect(rows.second).x0);
    try testing.expectEqual(t.rect(rows.handle).x1, t.rect(rows.body).x0);
    try testing.expectEqual(box.x1, t.rect(rows.second).x1);
    try testing.expectEqual(box.h(), t.rect(rows.handle).h());
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
