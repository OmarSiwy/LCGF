//! scrolling, written by hand: overflow-y: auto as a scroll area around the box's content
//! (`widgets_scroll.ct.scroll`), with sticky section headers held at the top of its viewport.

const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const label = lcgf.widgets_label;
const scroll = lcgf.widgets_scroll;

pub const theme: w.Theme = .{};

pub const State = struct { nets_scroll: f32 = 0 };

/// Scroll the list half a notch, then a notch and a half: the second header pushes the first.
pub const replay =
    \\frame
    \\viewport 800 600
    \\pointer 50 40
    \\frame
    \\wheel 0 -0.5
    \\frame
    \\wheel 0 0
    \\frame
    \\wheel 0 -1.5
    \\frame
    \\wheel 0 0
    \\frame
;

fn head(comptime text: []const u8) s.Spec {
    return s.layer(s.sticky(s.styled(label.ct.label(theme, text), .{ .fill = .rgb(0x30, 0x34, 0x40), .role = .label }), 0), 1);
}

pub const spec = s.col(.{ .size = .{ .fill, .fill }, .fill = theme.panel }, .{
    s.col(.{ .size = .{ .px(160), .px(80) }, .clip = true }, .{
        scroll.ct.scroll(theme, .nets, .nets_scroll, .{
            s.col(.{}, .{ head("Inputs"), label.ct.label(theme, "in1"), label.ct.label(theme, "in2"), label.ct.label(theme, "in3") }),
            s.col(.{}, .{ head("Outputs"), label.ct.label(theme, "out1"), label.ct.label(theme, "out2"), label.ct.label(theme, "out3") }),
        }),
    }),
});
