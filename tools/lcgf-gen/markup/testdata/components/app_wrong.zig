//! The components fixture's app without `sfy-tool`: the compile-fail case builds the page
//! over it and expects the error at the element that names it.

const lcgf = @import("lcgf");
const s = lcgf.spec;

pub const components = struct {
    pub fn @"sfy-meter"(comptime props: struct { level: @EnumLiteral(), caption: []const u8 }) s.Spec {
        _ = props;
        return s.col(.{}, .{});
    }
    pub fn @"sfy-panel"(comptime props: struct { heading: []const u8, children: []const s.Spec }) s.Spec {
        return s.col(.{}, props.children);
    }
};
