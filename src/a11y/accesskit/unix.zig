//! Linux and the BSDs: AccessKit's Unix adapter, serving AT-SPI over D-Bus (Orca). It needs no
//! window handle: it registers the application on the accessibility bus when one is enabled,
//! and calls the bridge's handlers from its own thread.
//!
//! Host loop:
//!
//!     var ak = unix.Adapter.init(&host.b);
//!     ... each built frame: host.frame(&ctx, &out); ak.update(&host.b);
//!     ... when the window gains or loses keyboard focus: ak.setFocused(true / false);
//!     ak.deinit();

const std = @import("std");
const c = @import("c.zig");
const Bridge = @import("bridge.zig").Bridge;

const Raw = opaque {};
extern fn accesskit_unix_adapter_new(activation: c.ActivationHandler, activation_userdata: ?*anyopaque, action: c.ActionHandler, action_userdata: ?*anyopaque, deactivation: c.DeactivationHandler, deactivation_userdata: ?*anyopaque) *Raw;
extern fn accesskit_unix_adapter_free(adapter: *Raw) void;
extern fn accesskit_unix_adapter_update_if_active(adapter: *Raw, factory: c.TreeUpdateFactory, userdata: ?*anyopaque) void;
extern fn accesskit_unix_adapter_update_window_focus_state(adapter: *Raw, focused: bool) void;
extern fn accesskit_unix_adapter_set_root_window_bounds(adapter: *Raw, outer: c.Rect, inner: c.Rect) void;

pub const Adapter = struct {
    raw: *Raw,

    /// `b` must outlive the adapter: AccessKit calls back into it from its own thread.
    pub fn init(b: *Bridge) Adapter {
        return .{ .raw = accesskit_unix_adapter_new(Bridge.activate, b, Bridge.act, b, deactivate, b) };
    }

    pub fn deinit(a: Adapter) void {
        accesskit_unix_adapter_free(a.raw);
    }

    /// After `Bridge.frame`: sends the frame's update if a screen reader is connected.
    pub fn update(a: Adapter, b: *Bridge) void {
        accesskit_unix_adapter_update_if_active(a.raw, Bridge.factory, b);
    }

    /// The window gained or lost keyboard focus; Orca follows the focused window.
    pub fn setFocused(a: Adapter, focused: bool) void {
        accesskit_unix_adapter_update_window_focus_state(a.raw, focused);
    }

    /// The window's position on screen, `outer` with its decorations, in physical pixels. X11
    /// only: a Wayland client cannot know its position.
    pub fn setBounds(a: Adapter, outer: c.Rect, inner: c.Rect) void {
        accesskit_unix_adapter_set_root_window_bounds(a.raw, outer, inner);
    }

    /// The screen reader went away. The next activation asks for the whole tree again, so
    /// nothing is kept.
    fn deactivate(_: ?*anyopaque) callconv(.c) void {}
};
