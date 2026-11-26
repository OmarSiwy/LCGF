//! settings, written by hand: a switch captioned by `<label for>`, a toggle button, two buttons
//! (an `<input type=button>` and a bound caption) in a row, inside a named form landmark.

const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const button = lcgf.widgets_button;
const switch_ = lcgf.widgets_switch;
const toggle = lcgf.widgets_toggle;
const Frame = lcgf.frame.Frame;

pub const theme: w.Theme = .{};

/// Accessible names the a11y export must carry (parity.zig).
pub const names = .{"Settings"};

pub const State = struct { wifi: bool = true, bold: bool = false, reset_text: []const u8 = "" };

const body: lcgf.types.Style = .{ .size = .{ .fill, .fill }, .fill = theme.panel };

pub const spec = s.col(body, .{
    s.named(s.landmark(.form, .{ .pad = @splat(12), .gap = 8 }, .{
        switch_.ct.@"switch"(theme, .wifi, .wifi, "Wi-Fi"),
        toggle.ct.toggle(theme, .bold, .bold, "Bold"),
        s.row(.{ .gap = 4 }, .{
            button.ct.button(theme, .apply, "Apply"),
            button.ct.button(theme, .reset, .reset_text),
        }),
    }), "Settings"),
});

pub const limits: lcgf.context.Limits = .{ .nodes = 32, .texts = 8, .strings = 1024, .depth = 8 };

/// The same page in the runtime front end, for the draw lists.
pub const App = struct {
    wifi: bool = true,
    bold: bool = false,

    pub fn build(app: *App, f: *Frame) void {
        _ = f.open(.none, body);
        _ = f.open(.none, .{ .pad = @splat(12), .gap = 8, .role = .form });
        _ = switch_.@"switch"(f, &theme, .from("wifi"), &app.wifi, "Wi-Fi");
        _ = toggle.toggle(f, &theme, .from("bold"), &app.bold, "Bold");
        _ = f.open(.none, .{ .dir = .x, .gap = 4 });
        _ = button.button(f, &theme, .from("apply"), "Apply");
        _ = button.button(f, &theme, .from("reset"), "");
        f.close();
        f.close();
        f.close();
    }
};

/// Hover, press and release Apply, then toggle Bold.
pub const replay =
    \\frame
    \\viewport 800 600
    \\pointer 400 300
    \\frame
    \\pointer 30 90
    \\frame
    \\buttons left
    \\frame
    \\buttons
;
