//! Semantic platform colour input. Hosts populate these roles from their platform's actual
//! palette; portable light/dark high-contrast defaults are explicit fallback values.
//! These are ordinary values, not a system-colour registry or a platform query.

const std = @import("std");
const Color = @import("../core/types.zig").Color;
pub const Role = enum {
    canvas,
    canvas_text,
    field,
    field_text,
    button_face,
    button_text,
    button_border,
    link,
    visited_link,
    active_text,
    highlight,
    highlight_text,
    selected_item,
    selected_item_text,
    mark,
    mark_text,
    gray_text,
    accent,
    accent_text,
};
pub const count = @typeInfo(Role).@"enum".field_names.len;
pub const Colors = struct {
    rows: [count]Color,
    pub fn get(colors: Colors, role: Role) Color {
        return colors.rows[@backingInt(role)];
    }
    pub fn set(colors: *Colors, role: Role, value: Color) void {
        colors.rows[@backingInt(role)] = value;
    }
    pub fn isOpaque(colors: Colors) bool {
        for (colors.rows) |c| if (c.a != 255) return false;
        return true;
    }
};
pub const Policy = enum {
    /// Recipes use semantic roles when high-contrast/forced-colors input is active.
    automatic,
    /// Explicit component exception, for authored charts, images or essential colour keys.
    /// The application retains responsibility for the component's readable alternatives.
    preserve,
};

pub fn highContrast(dark: bool) Colors {
    const foreground: Color = if (dark) .white else .black;
    const background: Color = if (dark) .black else .white;
    const accent: Color = if (dark) .rgb(255, 230, 0) else .rgb(0, 32, 128);
    const on_accent: Color = if (dark) .black else .white;
    var colors: Colors = .{ .rows = @splat(foreground) };
    inline for (.{ .canvas, .field, .button_face }) |role| colors.set(role, background);
    inline for (.{ .canvas_text, .field_text, .button_text, .button_border, .gray_text }) |role| colors.set(role, foreground);
    inline for (.{ .link, .visited_link, .active_text, .highlight, .selected_item, .mark, .accent }) |role| colors.set(role, accent);
    inline for (.{ .highlight_text, .selected_item_text, .mark_text, .accent_text }) |role| colors.set(role, on_accent);
    return colors;
}

test "both high contrast profiles preserve text controls selection and visible boundaries" {
    const contrast = @import("../a11y/settings.zig").contrast;
    for ([_]bool{ false, true }) |dark| {
        const colors = highContrast(dark);
        try std.testing.expect(colors.isOpaque());
        inline for (.{ .{ .canvas_text, .canvas }, .{ .field_text, .field }, .{ .button_text, .button_face }, .{ .highlight_text, .highlight }, .{ .selected_item_text, .selected_item } }) |pair| try std.testing.expect(contrast(colors.get(pair[0]), colors.get(pair[1])) >= 7);
        try std.testing.expect(contrast(colors.get(.button_border), colors.get(.canvas)) >= 3);
        try std.testing.expect(contrast(colors.get(.accent), colors.get(.canvas)) >= 3);
    }
}
