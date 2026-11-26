//! decorations, written by hand: <u> and <s> from the UA sheet, underline with overline in a
//! colour, decorations propagated to the text inside a box (adding up with <del>'s), and an
//! underline on wrapping text, one bar per line (`MonoParagraphs.decorate`).

const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const label = lcgf.widgets_label;
const types = lcgf.types;
const Frame = lcgf.frame.Frame;
const Decoration = lcgf.text_decorations.Style;

pub const theme: w.Theme = .{};

const body: types.Style = .{ .size = .{ .fill, .fill }, .fill = theme.panel };
const wrap: types.TextStyle = .{ .px = theme.text_px, .color = theme.text, .wrap = true };
const narrow: types.Style = .{ .size = .{ .px(80), .fit } };

const decorations = [_]Decoration{
    .{ .underline = true },
    .{ .strike = true },
    .{ .underline = true, .overline = true, .color = types.Color.rgb(255, 0, 0).bitsOf() },
    .{ .underline = true, .strike = true },
};
const paragraphs: [decorations.len]lcgf.text_stack.Paragraph = @splat(.{});

pub const spec = s.col(body, .{
    s.decorated(label.ct.label(theme, "Underlined"), decorations[0]),
    s.decorated(label.ct.label(theme, "Struck"), decorations[1]),
    s.decorated(label.ct.label(theme, "Over and under"), decorations[2]),
    s.col(.{}, .{
        s.decorated(label.ct.label(theme, "Inherited"), decorations[0]),
        s.decorated(label.ct.label(theme, "and struck"), decorations[3]),
    }),
    s.col(narrow, .{
        s.decorated(s.textStyled(label.ct.label(theme, "A long underlined line that wraps"), wrap), decorations[0]),
    }),
});

pub const limits: lcgf.context.Limits = .{ .nodes = 16, .texts = 8, .strings = 1024, .depth = 8 };

pub const App = struct {
    rows: [6]u32 = undefined,
    const styles = [_]u16{ 0, 1, 2, 0, 3, 0 };

    pub fn build(app: *App, f: *Frame) void {
        _ = f.open(.none, body);
        for ([_][]const u8{ "Underlined", "Struck", "Over and under" }, 0..) |str, k| {
            _ = label.label(f, &theme, str);
            app.rows[k] = f.texts().len - 1;
        }
        _ = f.open(.none, .{});
        _ = label.label(f, &theme, "Inherited");
        app.rows[3] = f.texts().len - 1;
        _ = label.label(f, &theme, "and struck");
        app.rows[4] = f.texts().len - 1;
        f.close();
        _ = f.open(.none, narrow);
        _ = f.textStyled("A long underlined line that wraps", wrap, label.labelStyle(&theme));
        app.rows[5] = f.texts().len - 1;
        f.close();
        f.close();
    }

    pub fn end(app: *App, f: *Frame, font: lcgf.protocol.Mono) lcgf.context.Output {
        const out = f.endParagraphs(.{ .mono = font, .rows = &app.rows, .styles = &styles, .table = &paragraphs, .decorations = &decorations });
        return out;
    }
};

/// The bars are in the draw list: three lines of the wrapped run, two on "Over and under".
pub fn events(comptime page: type, p: anytype, h: anytype) !void {
    _ = page;
    var in: lcgf.input.Input = .{ .viewport = .{ 800, 600 } };
    const d = p.frame(h, &in).draw;
    var red: u32 = 0;
    for (d.quads[0..d.quad_len]) |q| red += @intFromBool(q.fill == types.Color.rgb(255, 0, 0).bitsOf());
    try @import("std").testing.expectEqual(2, red);
}

pub fn Handlers(comptime Ui: type) type {
    _ = Ui;
    return struct {};
}
