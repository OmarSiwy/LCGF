//! The components fixture's app without `sfy-tool`: the compile-fail case builds the page
//! over it and expects the error at the element that names it.

const lcgf = @import("lcgf");
const s = lcgf.spec;
const Theme = lcgf.widgets_base.Theme;

pub const components = struct {
    pub fn @"sfy-meter"(comptime theme: Theme, comptime props: struct { level: @EnumLiteral(), caption: []const u8 }) s.Spec {
        _ = theme;
        _ = props;
        return s.col(.{}, .{});
    }
    pub fn @"sfy-panel"(comptime theme: Theme, comptime props: struct { heading: []const u8, children: []const s.Spec }) s.Spec {
        _ = theme;
        return s.col(.{}, props.children);
    }
    pub fn @"sfy-net"(f: *lcgf.frame.Frame, theme: *const Theme, props: struct { id: lcgf.types.Id, name: []const u8 }) lcgf.types.Response {
        return lcgf.widgets_button.button(f, theme, props.id, props.name);
    }

    /// A mark before a region row's content: `open` builds what goes before the content and
    /// `close` what goes after it.
    pub const @"sfy-chip" = struct {
        pub fn open(f: *lcgf.frame.Frame, theme: *const Theme, props: struct { mark: []const u8 }) void {
            _ = f.open(.none, .{ .dir = .x, .gap = 4 });
            _ = lcgf.widgets_label.label(f, theme, props.mark);
        }
        pub fn close(f: *lcgf.frame.Frame, theme: *const Theme) void {
            _ = theme;
            f.close();
        }
    };
};
