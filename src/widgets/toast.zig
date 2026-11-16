//! Toast (tier 2): a short message that appears at the bottom of the window for a few seconds,
//! the WAI-ARIA APG alert pattern (a live region that does not take focus). Written against the
//! public API of tiers 0 and 1, after the recipe in base.zig. The toast sits in a layer that
//! floats over the whole viewport (`Style.float`) and puts it at the bottom centre, so its
//! place needs no size known in advance.
//!
//! Its state is a `ToastState`, owned by the application: shown or not, and the seconds left.
//! Time is the frames' `dt`, so the state steps the same in both front ends; the fading out is
//! the toast's opacity, a function of the seconds left (no spring: prototype/ui.zig's
//! `Frame.animate` belongs to the animation lane).
//!
//! Runtime: build the page, then `show(...)` under the root after it.
//!
//! Comptime: `const T = Toast(th, .saved, .toast, .save);` gives the spec builder `T.layer` and
//! the hooks `popover.ComptimePage(State, spec, th, T)` runs.

const std = @import("std");
const base = @import("base.zig");
const popover = @import("popover.zig");
const types = @import("../core/types.zig");
const simd = @import("../core/simd.zig");
const Input = @import("../core/input.zig").Input;
const Tree = @import("../core/tree.zig").Tree;
const Frame = @import("../runtime/frame.zig").Frame;
const context = @import("../runtime/context.zig");
const spec_zig = @import("../comptime/spec.zig");
const a11y = @import("../a11y/tree.zig");
const Spec = spec_zig.Spec;
const Theme = base.Theme;
const Id = types.Id;
const Rect = types.Rect;
const Style = types.Style;
const Response = types.Response;
const Part = popover.Part;

// ---- spec: what the toast takes and keeps ----------------------------------------------------

/// A toast's state, owned by the application.
pub const ToastState = struct {
    shown: bool = false,
    /// Seconds before it goes.
    left: f32 = 0,
};

/// Seconds a toast stays, not counting the time the pointer rests on it.
pub const duration: f32 = 3;

/// `null` if `State` can hold a toast bound to `field`, else the compile error.
pub fn checkToast(comptime State: type, comptime field: []const u8) ?[]const u8 {
    if (!@hasField(State, field)) return "toast: state " ++ @typeName(State) ++ " has no field '" ++ field ++ "'";
    if (@FieldType(State, field) != ToastState) return "toast: field '" ++ field ++ "' must be a toast.ToastState";
    return null;
}

/// Toast `name`, bound to the `ToastState` field `field` and shown when the widget `trigger`
/// is clicked, in theme `th`: its spec builder and the hooks `popover.ComptimePage` calls.
pub fn Toast(comptime th: Theme, comptime name: @EnumLiteral(), comptime field: @EnumLiteral(), comptime trigger: @EnumLiteral()) type {
    const id = @tagName(name);
    const field_name = @tagName(field);
    _ = trigger;
    return struct {
        /// The layer and the toast showing the string field `text`. Put it last in the page's
        /// root so it is drawn above the rest. The layer has no id (it takes no pointer
        /// input); it is told apart by its binding to `field`.
        pub fn layer(comptime text: @EnumLiteral()) Spec {
            var t = spec_zig.row(.{}, .{base.ct.label(th, text)});
            t.id = id;
            return .{ .kind = .col, .bind = field_name, .children = &.{t} };
        }

        pub fn check(comptime State: type) ?[]const u8 {
            return checkToast(State, field_name);
        }

        pub fn step(sig: anytype, v: anytype) void {
            _ = sig;
            _ = v;
        }

        pub fn part(comptime n: Spec, st: anytype, v: anytype) ?Part {
            const ts: ToastState = @field(st, field_name);
            if (comptime n.kind == .col and n.id == null and n.bind != null and std.mem.eql(u8, n.bind.?, field_name))
                return .{ .style = layerStyle(&th, v.in.viewport) };
            if (comptime n.id != null and std.mem.eql(u8, n.id.?, id)) {
                if (!ts.shown) return null;
                return .{ .style = toastStyle(&th, ts) };
            }
            return popover.plainPart(th, n, v.response);
        }
    };
}

// ---- look -------------------------------------------------------------------------------------

/// The layer: over the whole viewport, the toast at its bottom centre.
pub fn layerStyle(th: *const Theme, viewport: [2]f32) Style {
    _ = th;
    return .{ .float = true, .size = .{ .px(viewport[0]), .px(viewport[1]) }, .main = .end, .cross = .center };
}

/// The toast.
pub fn toastStyle(th: *const Theme, t: ToastState) Style {
    _ = th;
    _ = t;
    return .{ .dir = .x };
}

// ---- runtime front end ------------------------------------------------------------------------

/// Builds the layer of toast `name` and, while it is shown, the toast showing `text`. Call it
/// at the root's depth, after the rest of the page, so it is drawn on top. `trigger` (the
/// click that should show the toast) is used from the behaviour commit on.
pub fn show(f: *Frame, th: *const Theme, comptime name: []const u8, t: *ToastState, trigger: bool, text: []const u8) void {
    _ = trigger;
    _ = f.open(.none, layerStyle(th, f.in.viewport));
    if (t.shown) {
        _ = f.open(.from(name), toastStyle(th, t.*));
        _ = base.label(f, th, text);
        f.close();
    }
    f.close();
}

// ---- tests ------------------------------------------------------------------------------------

const testing = std.testing;

/// The test page: a toolbar with a Save button and a label, and the toast Save shows.
fn Page(comptime th: Theme) type {
    return struct {
        const toolbar_style: Style = .{ .dir = .x, .size = .{ .fill, .fit }, .pad = @splat(8), .gap = 8, .cross = .center, .fill = th.panel };
        const page_style: Style = .{ .size = .{ .fill, .fill } };

        pub const App = struct {
            toast: ToastState = .{},

            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.none, page_style);
                _ = f.open(.none, toolbar_style);
                const save = base.button(f, &th, .from("save"), "Save");
                _ = base.label(f, &th, "Scene 1");
                f.close();
                show(f, &th, "saved", &app.toast, save.clicked, "Scene saved");
                f.close();
            }
        };

        pub const State = struct {
            toast: ToastState = .{},
            save_text: []const u8 = "Save",
            scene: []const u8 = "Scene 1",
            saved_text: []const u8 = "Scene saved",
        };
        pub const T = Toast(th, .saved, .toast, .save);
        pub const spec = spec_zig.col(page_style, .{
            spec_zig.row(toolbar_style, .{ base.ct.button(th, .save, .save_text), base.ct.label(th, .scene) }),
            T.layer(.saved_text),
        });
        pub const Ui = popover.ComptimePage(State, spec, th, T);
        pub const limits: context.Limits = .{ .nodes = 64, .texts = 16, .customs = 1, .strings = 1024, .depth = 8 };
        pub const Run = base.Harness(App, Ui, limits);
    };
}

const Default = Page(.default);
var harness: Default.Run = .{};

/// Sets the toast's state in both front ends of `h` and builds a frame; returns its tree.
fn setState(h: anytype, st: ToastState) !*const Tree {
    const in: Input = .{ .viewport = .{ 400, 300 }, .dt = 0 };
    h.app.toast = st;
    h.ui.signals.set(.toast, st);
    return (try h.frame(&in)).runtime.tree;
}

test "Toast: the page agrees in both front ends, hidden and shown" {
    const h = &harness;
    h.init();
    var t = try setState(h, .{});
    try testing.expectEqual(@as(u32, 7), t.len);
    t = try setState(h, .{ .shown = true, .left = duration });
    try testing.expectEqual(@as(u32, 9), t.len);
    // At the bottom centre of the viewport.
    const r = t.rect(t.find(.from("saved")));
    try testing.expectEqual(@as(f32, 300), r.y1);
    try testing.expectApproxEqAbs(@as(f32, 200), (r.x0 + r.x1) * 0.5, 1);
}

test "checkToast: the state field" {
    try testing.expectEqual(null, comptime checkToast(Default.State, "toast"));
    try testing.expectEqualStrings("toast: field 'toast' must be a toast.ToastState", comptime checkToast(struct { toast: f32 }, "toast").?);
    try testing.expect(comptime checkToast(struct {}, "toast") != null);
}

test {
    std.testing.refAllDecls(@This());
}
