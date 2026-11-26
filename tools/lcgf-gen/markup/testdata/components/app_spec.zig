//! The components fixture's app as an app written before the runtime frontend lowered
//! components: the page's components are plain spec functions, with no namespace and no
//! runtime form. Its comptime page must give the twin's spec and pass the fixture's events.
//! The region's components are runtime forms, as they always were.

const lcgf = @import("lcgf");
const s = lcgf.spec;
const Theme = lcgf.widgets_base.Theme;
const app = @import("app.zig");

pub const components = struct {
    pub fn @"sfy-meter"(comptime theme: Theme, comptime props: struct { level: @EnumLiteral(), caption: []const u8 }) s.Spec {
        return s.row(.{ .gap = 4 }, .{ lcgf.widgets_label.ct.label(theme, props.caption), lcgf.widgets_progress.ct.progress(theme, props.level) });
    }
    pub fn @"sfy-panel"(comptime theme: Theme, comptime props: struct { heading: []const u8, children: []const s.Spec }) s.Spec {
        return s.col(.{ .gap = 2, .pad = @splat(4) }, .{ lcgf.widgets_label.ct.label(theme, props.heading), s.row(.{ .gap = 4 }, props.children) });
    }
    pub const @"sfy-tool" = app.components.@"sfy-tool";
    pub const @"sfy-net" = app.components.@"sfy-net";
    pub const @"sfy-chip" = app.components.@"sfy-chip";
};
