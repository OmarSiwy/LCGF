//! The components fixture's app without `sfy-tool`: the compile-fail case builds the page
//! over it and expects the error at the element that names it.

const lcgf = @import("lcgf");
const s = lcgf.spec;

pub const components = struct {
    pub fn @"sfy-meter"(comptime theme: lcgf.widgets_base.Theme, comptime props: struct { level: @EnumLiteral(), caption: []const u8 }) s.Spec {
        _ = theme;
        _ = props;
        return s.col(.{}, .{});
    }
    pub fn @"sfy-panel"(comptime theme: lcgf.widgets_base.Theme, comptime props: struct { heading: []const u8, children: []const s.Spec }) s.Spec {
        _ = theme;
        return s.col(.{}, props.children);
    }
};
