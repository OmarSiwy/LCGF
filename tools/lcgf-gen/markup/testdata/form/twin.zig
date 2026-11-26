//! form, written by hand: text controls with literal placeholders. Waits for engine spec T1
//! (the text builders take a literal hint, docs/plans/markup-engine-api.md).

const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const textfield = lcgf.widgets_textfield;
const search = lcgf.widgets_search;
const textarea = lcgf.widgets_textarea;

pub const theme: w.Theme = .{};

pub const State = struct { name: textfield.Text(256) = .{}, find: textfield.Text(256) = .{}, bio: textfield.Text(256) = .{} };

pub const spec = s.col(.{ .size = .{ .fill, .fill }, .fill = theme.panel }, .{
    s.named(s.landmark(.form, .{}, .{
        textfield.ct.textfield(theme, .name, .name, "Your name"),
        search.ct.search(theme, .find, .find, "Find"),
        textarea.ct.textarea(theme, .bio, .bio, 4, "About you"),
    }), "Sign up"),
});
