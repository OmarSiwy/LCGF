//! paragraphs, written by hand: line-height (a number inherited from body, and px), letter-
//! and word-spacing, and text-overflow: ellipsis, as paragraph styles (`spec.paragraph`)
//! measured by `MonoParagraphs` in both front ends.

const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const label = lcgf.widgets_label;
const types = lcgf.types;
const Frame = lcgf.frame.Frame;
const Paragraph = lcgf.text_stack.Paragraph;

pub const theme: w.Theme = .{};

const body: types.Style = .{ .size = .{ .fill, .fill }, .fill = theme.panel };
const text: types.TextStyle = .{ .px = theme.text_px, .color = theme.text };
const wrap: types.TextStyle = .{ .px = theme.text_px, .color = theme.text, .wrap = true };
const h2: types.TextStyle = .{ .px = 21, .color = theme.text };
const cut_box: types.Style = .{ .size = .{ .px(120), .fit }, .clip = true, .role = .label };

const table = [_]Paragraph{
    .{ .line_height = .{ .multiple = 1.5 } },
    .{ .line_height = .{ .multiple = 1.5 }, .letter_spacing = 2, .word_spacing = 7 },
    .{ .line_height = .{ .multiple = 1.5 }, .ellipsis = true },
    .{ .line_height = .{ .px = 30 } },
};

pub const spec = s.col(body, .{
    s.paragraph(s.textStyled(label.ct.label(theme, "A paragraph with an inherited line height of one and a half."), wrap), table[0]),
    s.paragraph(label.ct.label(theme, "Spaced out words"), table[1]),
    s.paragraph(s.styled(label.ct.label(theme, "A line that is far too long to fit"), cut_box), table[2]),
    s.paragraph(s.textStyled(s.heading(2, "Thirty pixels"), h2), table[3]),
});

pub const limits: lcgf.context.Limits = .{ .nodes = 16, .texts = 8, .strings = 1024, .depth = 8 };

pub const App = struct {
    rows: [4]u32 = undefined,

    pub fn build(app: *App, f: *Frame) void {
        _ = f.open(.none, body);
        _ = f.textStyled("A paragraph with an inherited line height of one and a half.", wrap, label.labelStyle(&theme));
        app.rows[0] = f.texts().len - 1;
        _ = f.textStyled("Spaced out words", text, label.labelStyle(&theme));
        app.rows[1] = f.texts().len - 1;
        _ = f.textStyled("A line that is far too long to fit", text, cut_box);
        app.rows[2] = f.texts().len - 1;
        _ = f.textStyled("Thirty pixels", h2, .{ .role = .heading, .value = 2 });
        app.rows[3] = f.texts().len - 1;
        f.close();
    }

    pub fn end(app: *App, f: *Frame, font: lcgf.protocol.Mono) lcgf.context.Output {
        return f.endParagraphs(lcgf.protocol.MonoParagraphs{ .mono = font, .rows = &app.rows, .styles = &.{ 0, 1, 2, 3 }, .table = &table });
    }
};
