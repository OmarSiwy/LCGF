//! Native window material descriptors, separate from portable surface filters. These are
//! consumed by Win32.setBackdrop and Macos.setMaterial; unsupported hosts retain their
//! caller-chosen solid fallback. No attempt is made to reproduce an OS material with blur.
const std = @import("std");
const Color = @import("../core/types.zig").Color;

/// DWM_SYSTEMBACKDROP_TYPE. DWM may change the material's appearance across OS versions.
/// Setting a nondefault value requires Windows 11 build 22621 or newer; HRESULT is checked.
pub const WindowsBackdrop = enum(u32) { auto = 0, none = 1, window = 2, transient = 3, tabbed = 4 };
pub const WindowsCorners = enum(u32) { system = 0, square = 1, round = 2, small_round = 3 };
pub const WindowsColor = union(enum) {
    system,
    suppress,
    color: Color,
    pub fn colorref(value: WindowsColor) u32 {
        return switch (value) {
            .system => 0xffffffff,
            .suppress => 0xfffffffe,
            .color => |c| @as(u32, c.r) | (@as(u32, c.g) << 8) | (@as(u32, c.b) << 16),
        };
    }
};

/// NSVisualEffectMaterial semantic roles (AppKit), independent of the effective appearance.
pub const AppKitMaterial = enum(isize) {
    titlebar = 3,
    selection = 4,
    menu = 5,
    popover = 6,
    sidebar = 7,
    header = 10,
    sheet = 11,
    window = 12,
    hud = 13,
    fullscreen = 15,
    tooltip = 17,
    content = 18,
    under_window = 21,
    under_page = 22,
};
pub const AppKitBlend = enum(isize) { behind_window = 0, within_window = 1 };
pub const AppKitState = enum(isize) { follows_window = 0, active = 1, inactive = 2 };
pub const AppKit = struct {
    material: AppKitMaterial = .window,
    blending: AppKitBlend = .behind_window,
    state: AppKitState = .follows_window,
    emphasized: bool = false,
};

/// Preference policy is separate from native submission. Unknown does not disable effects;
/// callers with no known preference can use the OS's own policy. Their solid fallback still
/// belongs to their theme rather than becoming a hardcoded color in the shell.
pub fn windowsEffective(requested: WindowsBackdrop, reduce_transparency: ?bool) WindowsBackdrop {
    return if (reduce_transparency orelse false) .none else requested;
}
pub fn appKitEffective(requested: ?AppKit, reduce_transparency: ?bool) ?AppKit {
    return if (reduce_transparency orelse false) null else requested;
}

test "native material policy preserves unknown preferences and selects the solid fallback" {
    try std.testing.expectEqual(WindowsBackdrop.window, windowsEffective(.window, null));
    try std.testing.expectEqual(WindowsBackdrop.none, windowsEffective(.window, true));
    try std.testing.expectEqual(AppKitMaterial.sidebar, appKitEffective(.{ .material = .sidebar }, false).?.material);
    try std.testing.expectEqual(null, appKitEffective(.{ .material = .sidebar }, true));
    try std.testing.expectEqual(@as(u32, 0x332211), WindowsColor.colorref(.{ .color = .rgb(0x11, 0x22, 0x33) }));
    try std.testing.expectEqual(@as(u32, 0xffffffff), WindowsColor.colorref(.system));
}
