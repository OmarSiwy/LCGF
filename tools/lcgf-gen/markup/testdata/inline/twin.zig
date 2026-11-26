//! inline, written by hand: one <p> of mixed phrasing (strong, em, code, a span with a nested
//! b, a <u> underlined on its own) as one label in style runs (`spec.spans`), measured by `MonoParagraphs` in both front
//! ends. Bold selects the 700 face of the font table, code the theme's monospace at 12 px.

const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const label = lcgf.widgets_label;
const types = lcgf.types;
const Frame = lcgf.frame.Frame;
const Span = lcgf.protocol.Span;

pub const theme: w.Theme = .{};

const body: types.Style = .{ .size = .{ .fill, .fill }, .fill = theme.panel };
const text = "Plain, bold, emphasis and code underlined in one nested paragraph.";
const regular: types.TextStyle = .{ .px = theme.text_px, .color = theme.text, .font = @fromBackingInt(1), .wrap = true };

fn with(comptime color: types.Color, comptime font: u16, comptime px: f32) types.TextStyle {
    return .{ .px = px, .color = color, .font = @fromBackingInt(font), .wrap = true };
}

const note: types.Color = .rgb(128, 128, 255);
const spans = [_]Span{
    .{ .start = 7, .style = with(theme.text, 2, theme.text_px) }, // bold
    .{ .start = 11, .style = regular },
    .{ .start = 13, .style = with(.rgb(255, 204, 0), 1, theme.text_px) }, // emphasis
    .{ .start = 21, .style = regular },
    .{ .start = 26, .style = with(theme.text, 0, 12) }, // code
    .{ .start = 30, .style = regular },
    .{ .start = 31, .style = regular, .decoration = .{ .underline = true } }, // underlined
    .{ .start = 41, .style = regular },
    .{ .start = 45, .style = with(note, 1, theme.text_px) }, // one
    .{ .start = 49, .style = with(note, 2, theme.text_px) }, // nested
    .{ .start = 55, .style = with(note, 1, theme.text_px) }, // paragraph
    .{ .start = 65, .style = regular },
};

pub const spec = s.col(body, .{
    s.spans(s.textStyled(label.ct.label(theme, text), regular), &spans),
});

pub const limits: lcgf.context.Limits = .{ .nodes = 8, .texts = 4, .strings = 1024, .depth = 8 };

pub const App = struct {
    rows: [1]u32 = undefined,

    pub fn build(app: *App, f: *Frame) void {
        _ = f.open(.none, body);
        _ = f.textStyled(text, regular, label.labelStyle(&theme));
        app.rows[0] = f.texts().len - 1;
        f.close();
    }

    pub fn end(app: *App, f: *Frame, font: lcgf.protocol.Mono) lcgf.context.Output {
        return f.endParagraphs(lcgf.protocol.MonoParagraphs{ .mono = font, .rows = &app.rows, .styles = &.{0}, .table = &.{.{}}, .spans = &.{&spans} });
    }
};
