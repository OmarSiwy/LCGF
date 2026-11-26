//! The app module of the components fixture: `components` holds what `<sfy-*>` elements
//! name. Spec components take the page's theme and return a `Spec`; the one inside the
//! lcgf-each region is the runtime form, built into the region's `Frame` once per item.

const lcgf = @import("lcgf");
const s = lcgf.spec;

const Theme = lcgf.widgets_base.Theme;

pub const components = struct {
    /// A caption beside a meter of an f32 field.
    pub fn @"sfy-meter"(comptime theme: Theme, comptime props: struct { level: @EnumLiteral(), caption: []const u8 }) s.Spec {
        return s.row(.{ .gap = 4 }, .{ lcgf.widgets_label.ct.label(theme, props.caption), lcgf.widgets_progress.ct.progress(theme, props.level) });
    }

    /// A titled column around the page's content.
    pub fn @"sfy-panel"(comptime theme: Theme, comptime props: struct { heading: []const u8, children: []const s.Spec }) s.Spec {
        return s.col(.{ .gap = 2, .pad = @splat(4) }, .{ lcgf.widgets_label.ct.label(theme, props.heading), s.row(.{ .gap = 4 }, props.children) });
    }

    /// A tool button; the page's on:click names its widget through `id`.
    pub fn @"sfy-tool"(comptime theme: Theme, comptime props: struct { id: @EnumLiteral(), icon: []const u8 }) s.Spec {
        return lcgf.widgets_button.ct.button(theme, props.id, props.icon);
    }

    /// One row of the run-time list: a button with the item's name.
    pub fn @"sfy-net"(f: *lcgf.frame.Frame, theme: *const Theme, props: struct { id: lcgf.types.Id, name: []const u8 }) lcgf.types.Response {
        return lcgf.widgets_button.button(f, theme, props.id, props.name);
    }
};
