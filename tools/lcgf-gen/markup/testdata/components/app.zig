//! The app module of the components fixture: `components` holds what `<sfy-*>` elements
//! name. Spec components take the page's theme and return a `Spec`; the one inside the
//! lcgf-each region is the runtime form, built into the region's `Frame` once per item.

const lcgf = @import("lcgf");
const s = lcgf.spec;

const Theme = lcgf.widgets_base.Theme;

pub const components = struct {
    /// A caption beside a meter of an f32 field: `spec` on a comptime page, which binds the
    /// field by name, and `frame` on a runtime page, which gets its value.
    pub const @"sfy-meter" = struct {
        pub fn spec(comptime theme: Theme, comptime props: struct { level: @EnumLiteral(), caption: []const u8 }) s.Spec {
            return s.row(.{ .gap = 4 }, .{ lcgf.widgets_label.ct.label(theme, props.caption), lcgf.widgets_progress.ct.progress(theme, props.level) });
        }
        pub fn frame(f: *lcgf.frame.Frame, theme: *const Theme, props: struct { level: f32, caption: []const u8 }) void {
            _ = f.open(.none, .{ .dir = .x, .gap = 4 });
            _ = lcgf.widgets_label.label(f, theme, props.caption);
            _ = lcgf.widgets_progress.progress(f, theme, props.level);
            f.close();
        }
    };

    /// A titled column around the page's content: its `children` in the spec, and on a
    /// runtime page what is built between `open` and `close`.
    pub const @"sfy-panel" = struct {
        pub fn spec(comptime theme: Theme, comptime props: struct { heading: []const u8, children: []const s.Spec }) s.Spec {
            return s.col(.{ .gap = 2, .pad = @splat(4) }, .{ lcgf.widgets_label.ct.label(theme, props.heading), s.row(.{ .gap = 4 }, props.children) });
        }
        pub fn open(f: *lcgf.frame.Frame, theme: *const Theme, props: struct { heading: []const u8 }) void {
            _ = f.open(.none, .{ .gap = 2, .pad = @splat(4) });
            _ = lcgf.widgets_label.label(f, theme, props.heading);
            _ = f.open(.none, .{ .dir = .x, .gap = 4 });
        }
        pub fn close(f: *lcgf.frame.Frame, theme: *const Theme) void {
            _ = theme;
            f.close();
            f.close();
        }
    };

    /// A tool button in both forms under one name: `spec` on the page, `frame` per item of a
    /// run-time region. The page's on:click names its widget through `id`.
    pub const @"sfy-tool" = struct {
        pub fn spec(comptime theme: Theme, comptime props: struct { id: @EnumLiteral(), icon: []const u8 }) s.Spec {
            return lcgf.widgets_button.ct.button(theme, props.id, props.icon);
        }
        pub fn frame(f: *lcgf.frame.Frame, theme: *const Theme, props: struct { id: lcgf.types.Id, icon: []const u8 }) lcgf.types.Response {
            return lcgf.widgets_button.button(f, theme, props.id, props.icon);
        }
    };

    /// One row of the run-time list: a button with the item's name.
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
