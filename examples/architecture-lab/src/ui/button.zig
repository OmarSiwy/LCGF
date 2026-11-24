//! Stateless button composition with explicit keyboard activation and a visible focus border.
//! LCGF supplies pointer responses and focus traversal; the app defines activation keys here.

const std = @import("std");
const lcgf = @import("lcgf");
const w = lcgf.widgets_base;
const Frame = lcgf.frame.Frame;
const Theme = w.Theme;
const Id = lcgf.types.Id;
const Response = lcgf.types.Response;
const Input = lcgf.input.Input;

/// Enter and Space use the USB HID codes produced by this template's X11 host.
/// A click and any number of key events collapse to one activation for this frame.
/// Repeats, releases, and Ctrl/Alt/Command chords do not trigger a button action.
pub fn activated(response: Response, input: *const Input) bool {
    if (response.clicked) return true;
    if (!response.focused) return false;
    for (input.events) |event| {
        if (event.kind != .press) continue;
        if (event.mods.ctrl or event.mods.alt or event.mods.cmd) continue;
        if (event.code == 40 or event.code == 44) return true;
    }
    return false;
}

pub fn draw(f: *Frame, theme: *const Theme, id: Id, caption: []const u8) Response {
    return drawSelected(f, theme, id, caption, false, false);
}

/// A selected navigation button can fill its container without a separate widget type.
pub fn drawSelected(f: *Frame, theme: *const Theme, id: Id, caption: []const u8, selected: bool, fill_width: bool) Response {
    var style = w.buttonStyle(theme);
    if (fill_width) style.size[0] = .fill;

    // Focus has already stepped in Context.begin. Read it before creating this frame's node
    // so all styling goes through the public Style value rather than editing tree columns.
    const previous = f.ctx.inter.response(id);
    if (previous.focused and f.ctx.focus.visible) {
        style.border = f.ctx.focus.ring_width;
        style.border_color = theme.text;
    }

    const node = f.open(id, style);
    var response = f.interact(node, .button);
    response.clicked = activated(response, f.in);
    f.setFill(node, if (selected) theme.accent else w.buttonFill(theme, response));
    f.setCursor(.pointer, response.hovered);
    _ = w.label(f, theme, caption);
    f.close();
    return response;
}

test "button activation requires focus and a fresh activation key without command chords" {
    const focused: Response = .{ .focused = true };
    var input: Input = .{};
    try std.testing.expect(activated(.{ .clicked = true }, &input));
    try std.testing.expect(!activated(focused, &input));

    const accepted = [_]Input.Event{
        .{ .kind = .press, .code = 40 },
        .{ .kind = .press, .code = 44 },
        .{ .kind = .press, .code = 40, .mods = .{ .shift = true } },
    };
    for (accepted) |event| {
        input.events = &.{event};
        try std.testing.expect(activated(focused, &input));
        try std.testing.expect(!activated(.{}, &input));
    }

    const ignored = [_]Input.Event{
        .{ .kind = .repeat, .code = 40 },
        .{ .kind = .repeat, .code = 44 },
        .{ .kind = .release, .code = 40 },
        .{ .kind = .press, .code = 43 },
        .{ .kind = .press, .code = 40, .mods = .{ .ctrl = true } },
        .{ .kind = .press, .code = 44, .mods = .{ .alt = true } },
        .{ .kind = .press, .code = 40, .mods = .{ .cmd = true } },
    };
    for (ignored) |event| {
        input.events = &.{event};
        try std.testing.expect(!activated(focused, &input));
    }

    input.events = &accepted;
    try std.testing.expect(activated(.{ .focused = true, .clicked = true }, &input));
}
