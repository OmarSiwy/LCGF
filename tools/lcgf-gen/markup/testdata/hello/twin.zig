//! hello, written by hand: what page.html compiles to, and the same page in the runtime front
//! end for the draw-list comparison.

const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const label = lcgf.widgets_label;
const Frame = lcgf.frame.Frame;

pub const theme: w.Theme = .{};

const body: lcgf.types.Style = .{ .size = .{ .fill, .fill }, .fill = theme.panel };
const h1: lcgf.types.TextStyle = .{ .px = 28, .color = theme.text };
const wrap: lcgf.types.TextStyle = .{ .px = theme.text_px, .color = theme.text, .wrap = true };

pub const spec = s.col(body, .{
    s.textStyled(s.heading(1, "Hello, LCGF"), h1),
    s.textStyled(label.ct.label(theme, "This page was written in HTML and compiled to a comptime Spec."), wrap),
    label.ct.label(theme, "two\nlines"),
    label.ct.label(theme, "Line one\nLine two"),
});

pub const limits: lcgf.context.Limits = .{ .nodes = 16, .texts = 8, .strings = 1024, .depth = 8 };

pub const App = struct {
    pub fn build(_: *App, f: *Frame) void {
        _ = f.open(.none, body);
        _ = f.textStyled("Hello, LCGF", h1, .{ .role = .heading, .value = 1 });
        _ = f.textStyled("This page was written in HTML and compiled to a comptime Spec.", wrap, label.labelStyle(&theme));
        _ = label.label(f, &theme, "two\nlines");
        _ = label.label(f, &theme, "Line one\nLine two");
        f.close();
    }
};
