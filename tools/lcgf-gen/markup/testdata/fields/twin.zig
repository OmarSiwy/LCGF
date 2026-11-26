//! fields, written by hand: CSS on the text controls (width, border colour, padding). The
//! comptime page restyles each root with `spec.styled`; the runtime page passes the same style
//! to the control's `…Face` function (engine spec R1). Focus still turns the border to the
//! accent in both (`textfield.focusFace`), so the two draw the same frames over a replay that
//! focuses and types into each.

const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const textfield = lcgf.widgets_textfield;
const search = lcgf.widgets_search;
const number = lcgf.widgets_number;
const textarea = lcgf.widgets_textarea;
const Frame = lcgf.frame.Frame;
const Style = lcgf.types.Style;
const Text = textfield.Text(256);

pub const theme: w.Theme = .{};

pub const State = struct { name: Text = .{}, pin: Text = .{}, query: Text = .{}, qty: number.Number = .{}, note: Text = .{} };

const red: lcgf.types.Color = .rgb(192, 48, 48);
const body: Style = .{ .size = .{ .fill, .fill }, .fill = theme.panel };

/// `input, textarea { width: 220px; border-color: #c03030 }` over each control's own root.
fn restyled(base: Style, width: f32) Style {
    var st = base;
    st.size[0] = .px(width);
    st.border_color = red;
    return st;
}
const name_face = restyled(textfield.fieldStyle(&theme, false, 0), 220);
const pin_face = blk: {
    var st = name_face;
    st.pad = .{ 4, 2, 4, 2 }; // #pin { padding: 2px 4px }
    break :blk st;
};
const find_face = restyled(search.boxStyle(&theme, false), 220);
const qty_face = restyled(number.numberStyle(&theme, false, 0), 100);
const note_face = restyled(textarea.areaStyle(&theme, 2, false), 220);

pub const spec = s.col(body, .{
    s.styled(textfield.ct.textfield(theme, .name, .name, "Name"), name_face),
    s.styled(textfield.ct.password(theme, .pin, .pin, ""), pin_face),
    s.styled(search.ct.search(theme, .find, .query, "Find"), find_face),
    s.styled(number.ct.number(theme, .qty, .qty, .{ .hi = 9 }), qty_face),
    s.styled(textarea.ct.textarea(theme, .note, .note, 2, ""), note_face),
});

pub fn Handlers(comptime Ui: type) type {
    _ = Ui;
    return struct {};
}

pub const limits: lcgf.context.Limits = .{ .nodes = 64, .texts = 16, .strings = 2048, .depth = 8 };

/// The page in the runtime front end, by hand.
pub const App = struct {
    state: State = .{},

    pub fn build(app: *App, f: *Frame) void {
        const st = &app.state;
        _ = f.open(.none, body);
        _ = textfield.textfieldFace(f, &theme, .from("name"), &st.name, "Name", name_face);
        _ = textfield.passwordFace(f, &theme, .from("pin"), &st.pin, "", pin_face);
        _ = search.searchFace(f, &theme, .from("find"), &st.query, "Find", find_face);
        _ = number.numberFace(f, &theme, .from("qty"), &st.qty, .{ .hi = 9 }, qty_face);
        _ = textarea.textareaFace(f, &theme, .from("note"), &st.note, 2, "", note_face);
        f.close();
    }
};

/// Click into each control, top to bottom, and type into it.
pub const replay =
    \\frame
    \\viewport 800 600
    \\pointer 40 12
    \\frame
    \\buttons left
    \\frame
    \\buttons
    \\frame
    \\text ab
    \\frame
    \\pointer 40 40
    \\frame
    \\buttons left
    \\frame
    \\buttons
    \\frame
    \\text 12
    \\frame
    \\pointer 40 64
    \\frame
    \\buttons left
    \\frame
    \\buttons
    \\frame
    \\text x
    \\frame
    \\pointer 40 92
    \\frame
    \\buttons left
    \\frame
    \\buttons
    \\frame
    \\text 7
    \\frame
    \\pointer 40 124
    \\frame
    \\buttons left
    \\frame
    \\buttons
    \\frame
    \\text hi
    \\frame
;
