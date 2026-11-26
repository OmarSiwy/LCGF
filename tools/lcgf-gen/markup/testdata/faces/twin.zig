//! faces, written by hand: CSS on widgets. The comptime page restyles each widget's root with
//! `spec.styled`; the runtime page passes the same style to the widget's `…Face` function
//! (engine spec R1), so the two draw the same frames (`App`, and parity.zig), also under a
//! box-shadow and an outline, which wrap the widget in a column with their floating nodes,
//! and under a margin, a flex rule on the widget's root.

const std = @import("std");
const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const button = lcgf.widgets_button;
const toggle = lcgf.widgets_toggle;
const checkbox = lcgf.widgets_checkbox;
const switch_ = lcgf.widgets_switch;
const slider = lcgf.widgets_slider;
const progress = lcgf.widgets_progress;
const separator = lcgf.widgets_separator;
const radio = lcgf.widgets_radio;
const link = lcgf.widgets_link;
const label = lcgf.widgets_label;
const Frame = lcgf.frame.Frame;
const Style = lcgf.types.Style;

pub const theme: w.Theme = .{};

pub const State = struct { bold: bool = false, done: bool = false, wifi: bool = false, level: f32 = 0, size: u32 = 0 };

const red: lcgf.types.Color = .rgb(192, 48, 48);
const body: Style = .{ .size = .{ .fill, .fill }, .fill = theme.panel };
/// `button { width: 120px; border: 2px solid #c03030 }` over the button's own style.
const face: Style = .{ .dir = .x, .size = .{ .px(120), .fit }, .pad = @splat(theme.pad), .main = .center, .cross = .center, .border_color = red, .border = 2, .radius = theme.radius, .role = .button };
/// `#go { color: #ffcc00; font-size: 16px }`: the caption's text style.
const go_text: lcgf.types.TextStyle = .{ .px = 16, .color = .rgb(255, 204, 0) };
const done_row: Style = .{ .dir = .x, .size = .{ .px(200), .fit }, .gap = 6, .cross = .center, .role = .checkbox };
const wifi_row: Style = .{ .dir = .x, .size = .{ .px(200), .fit }, .gap = 6, .cross = .center };
/// `#lit`: box-shadow and outline wrap the button in a column with a floating shadow and ring.
const lit_box: Style = .{ .size = .{ .px(120), .fit } };
const lit_shadow: Style = .{ .size = @splat(.pct(1)), .float = true, .fill = .rgb(0, 0, 0), .radius = theme.radius, .params = lcgf.features.shadow(2), .paint_outset = .{ -2, -3, 2, 3 } };
const lit_ring: Style = .{ .size = @splat(.pct(1)), .float = true, .border_color = .rgb(240, 240, 240), .border = 2, .radius = theme.radius + 3, .paint_outset = @splat(3) };
const lit_face: Style = blk: {
    var st = face;
    st.size = @splat(.fill);
    break :blk st;
};
/// `progress { width: 160px; height: 4px }`, `hr { width: 100px; background-color: #c03030 }`,
/// `#size { width: 200px }`, `a { padding: 6px }`.
const bar: Style = blk: {
    var st = progress.trackStyle(&theme);
    st.size = .{ .px(160), .px(4) };
    break :blk st;
};
const rule: Style = .{ .size = .{ .px(100), .px(1) }, .fill = red };
const group: Style = .{ .size = .{ .px(200), .fit }, .gap = theme.gap };
const target: Style = blk: {
    var st = link.linkStyle(&theme);
    st.pad = @splat(6);
    break :blk st;
};
const track: Style = .{ .dir = .x, .size = .{ .px(160), .px(12) }, .min = .{ 40, 0 }, .fill = theme.control, .radius = theme.radius, .role = .slider };

pub const spec = s.col(body, .{
    s.styled(button.ct.buttonStyled(theme, .go, "Go", go_text), face),
    s.flexed(s.styled(toggle.ct.toggle(theme, .bold, .bold, "Bold"), face), .{ .margin = .{ 8, 4, 8, 4 } }),
    s.styled(checkbox.ct.checkbox(theme, .done, .done, "Done"), done_row),
    s.styled(switch_.ct.@"switch"(theme, .wifi, .wifi, ""), wifi_row),
    s.styled(slider.ct.slider(theme, .level, .level, .{}), track),
    s.col(lit_box, .{ s.col(lit_shadow, .{}), s.col(lit_ring, .{}), s.styled(button.ct.button(theme, .lit, "Lit"), lit_face) }),
    s.styled(progress.ct.progress(theme, .level), bar),
    s.styled(separator.ct.separator(theme, .horizontal), rule),
    s.styled(radio.ct.radio(theme, .size, .size, .{ "Small", "Large" }), group),
    s.styled(link.ct.link(theme, .docs, "Docs"), target),
});

pub fn Handlers(comptime Ui: type) type {
    return struct {
        gone: u32 = 0,
        read_count: u32 = 0,

        pub fn go(h: *@This(), _: *Ui) void {
            h.gone += 1;
        }
        pub fn read(h: *@This(), _: *Ui) void {
            h.read_count += 1;
        }
    };
}

pub const limits: lcgf.context.Limits = .{ .nodes = 64, .texts = 16, .strings = 1024, .depth = 8 };

/// The page in the runtime front end, by hand.
pub const App = struct {
    bold: bool = false,
    done: bool = false,
    wifi: bool = false,
    level: f32 = 0,
    size: u32 = 0,
    /// The toggle's margin is a flex rule on its root, the row it pushes first.
    flex_buf: [flex_bytes]u8 align(lcgf.mem.column_align) = undefined,
    flex: ?lcgf.flex.Flex = null,

    const flex_bytes = blk: {
        var carver: lcgf.mem.Carver = .{ .buf = null };
        _ = carver.columns(lcgf.flex.Flex.Columns, lcgf.simd.rows(limits.nodes));
        break :blk carver.off;
    };

    pub fn end(app: *App, f: *Frame, font: lcgf.protocol.Mono) lcgf.context.Output {
        return f.endFlex(font, &app.flex.?);
    }

    pub fn build(app: *App, f: *Frame) void {
        if (app.flex == null) {
            var carver: lcgf.mem.Carver = .{ .buf = &app.flex_buf };
            app.flex = lcgf.flex.Flex.init(&carver, limits.nodes);
        }
        _ = f.open(.none, body);
        _ = button.buttonFace(f, &theme, .from("go"), "Go", go_text, face);
        app.flex.?.set(f.tree().len, &.{ .margin = .{ 8, 4, 8, 4 } });
        _ = toggle.toggleFace(f, &theme, .from("bold"), &app.bold, "Bold", face);
        _ = checkbox.checkboxFace(f, &theme, .from("done"), &app.done, "Done", done_row);
        _ = switch_.switchFace(f, &theme, .from("wifi"), &app.wifi, "", wifi_row);
        _ = slider.sliderFace(f, &theme, .from("level"), &app.level, 0, 1, track);
        _ = f.open(.none, lit_box);
        _ = f.leaf(.none, lit_shadow);
        _ = f.leaf(.none, lit_ring);
        _ = button.buttonFace(f, &theme, .from("lit"), "Lit", label.labelText(&theme), lit_face);
        f.close();
        _ = progress.progressFace(f, &theme, app.level, bar);
        _ = separator.separatorFace(f, rule);
        _ = radio.radioFace(f, &theme, .from("size"), &app.size, &.{ "Small", "Large" }, group);
        _ = link.linkFace(f, &theme, .from("docs"), "Docs", target);
        f.close();
    }
};

/// Hover and click each widget, top to bottom, drag the slider, and click the lit button.
pub const replay =
    \\frame
    \\viewport 800 600
    \\pointer 60 16
    \\frame
    \\buttons left
    \\frame
    \\buttons
    \\frame
    \\pointer 60 50
    \\frame
    \\buttons left
    \\frame
    \\buttons
    \\frame
    \\pointer 8 76
    \\frame
    \\buttons left
    \\frame
    \\buttons
    \\frame
    \\pointer 16 94
    \\frame
    \\buttons left
    \\frame
    \\buttons
    \\frame
    \\pointer 40 117
    \\frame
    \\buttons left
    \\frame
    \\pointer 120 117
    \\frame
    \\buttons
    \\frame
    \\pointer 60 130
    \\frame
    \\buttons left
    \\frame
    \\buttons
    \\frame
    \\pointer 10 194
    \\frame
    \\buttons left
    \\frame
    \\buttons
    \\frame
    \\pointer 20 215
    \\frame
    \\buttons left
    \\frame
    \\buttons
    \\frame
;

/// A click on the restyled button reaches `go`; the CSS width holds.
pub fn events(comptime page: type, p: anytype, h: anytype) !void {
    _ = page;
    var in: lcgf.input.Input = .{ .viewport = .{ 800, 600 } };
    const out = p.frame(h, &in);
    const go = out.tree.rect(out.tree.find(.from("go")));
    try std.testing.expectEqual(120, go.x1 - go.x0);
    in.pointer = .{ 60, (go.y0 + go.y1) / 2 };
    in.buttons.left = true;
    _ = p.frame(h, &in);
    in.buttons.left = false;
    _ = p.frame(h, &in);
    try std.testing.expectEqual(1, h.gone);
}
