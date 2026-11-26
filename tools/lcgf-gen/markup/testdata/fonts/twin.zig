//! fonts, written by hand: three @font-face rows of one family, selected by font-family,
//! font-weight (bold from <strong>, a relative `bolder`) and font-style (italic from <em>);
//! a generic family (monospace from <code>, system-ui) is the theme's font.

const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const label = lcgf.widgets_label;
const types = lcgf.types;
const Frame = lcgf.frame.Frame;

pub const theme: w.Theme = .{};

const body: types.Style = .{ .size = .{ .fill, .fill }, .fill = theme.panel };
const regular: types.TextStyle = .{ .px = theme.text_px, .color = theme.text, .font = @fromBackingInt(1), .wrap = true };
const bold: types.TextStyle = .{ .px = theme.text_px, .color = theme.text, .font = @fromBackingInt(2) };
const italic: types.TextStyle = .{ .px = theme.text_px, .color = theme.text, .font = @fromBackingInt(3) };

pub const spec = s.col(body, .{
    s.textStyled(label.ct.label(theme, "Regular"), regular),
    s.textStyled(label.ct.label(theme, "Bold"), bold),
    s.textStyled(label.ct.label(theme, "Italic"), italic),
    s.textStyled(label.ct.label(theme, "Bolder"), bold),
    label.ct.label(theme, "monospace"),
    label.ct.label(theme, "Theme font"),
});

pub const limits: lcgf.context.Limits = .{ .nodes = 16, .texts = 8, .strings = 1024, .depth = 8 };

pub const App = struct {
    pub fn build(_: *App, f: *Frame) void {
        _ = f.open(.none, body);
        _ = f.textStyled("Regular", regular, label.labelStyle(&theme));
        _ = f.textStyled("Bold", bold, label.labelStyle(&theme));
        _ = f.textStyled("Italic", italic, label.labelStyle(&theme));
        _ = f.textStyled("Bolder", bold, label.labelStyle(&theme));
        _ = label.label(f, &theme, "monospace");
        _ = label.label(f, &theme, "Theme font");
        f.close();
    }
};
