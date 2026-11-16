//! macOS: AccessKit's subclassing adapter on the shell's window, serving NSAccessibility
//! (VoiceOver). AccessKit subclasses the window's content view at run time, so the shell's view
//! class needs no accessibility methods of its own.
//!
//! Host loop, on the main thread:
//!
//!     var ak = macos.Adapter.init(ns_window, &host.b); // once the window has a content view
//!     ... each built frame: host.frame(&ctx, &out); ak.update(&host.b);
//!     ... on windowDidBecomeKey / windowDidResignKey: ak.setFocused(true / false);
//!     ak.deinit();

const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig");
const Bridge = @import("bridge.zig").Bridge;

const Raw = opaque {};
const QueuedEvents = opaque {};
extern fn accesskit_macos_subclassing_adapter_for_window(window: *anyopaque, activation: c.ActivationHandler, activation_userdata: ?*anyopaque, action: c.ActionHandler, action_userdata: ?*anyopaque) *Raw;
extern fn accesskit_macos_subclassing_adapter_free(adapter: *Raw) void;
extern fn accesskit_macos_subclassing_adapter_update_if_active(adapter: *Raw, factory: c.TreeUpdateFactory, userdata: ?*anyopaque) ?*QueuedEvents;
extern fn accesskit_macos_subclassing_adapter_update_view_focus_state(adapter: *Raw, focused: bool) ?*QueuedEvents;
extern fn accesskit_macos_queued_events_raise(events: *QueuedEvents) void;

pub const Adapter = struct {
    raw: *Raw,

    /// Subclasses the content view of `window` (an `NSWindow *`; AccessKit panics if it has no
    /// content view). `b` must outlive the adapter: AccessKit calls back into it.
    // ponytail: a shell that makes the window, not its view, first responder also needs
    // `accesskit_macos_add_focus_forwarder_to_window_class`; add it with that shell.
    pub fn init(window: *anyopaque, b: *Bridge) Adapter {
        return .{ .raw = accesskit_macos_subclassing_adapter_for_window(window, Bridge.activate, b, Bridge.act, b) };
    }

    pub fn deinit(a: Adapter) void {
        accesskit_macos_subclassing_adapter_free(a.raw);
    }

    /// After `Bridge.frame`: sends the frame's update if VoiceOver is connected, then posts the
    /// NSAccessibility notifications it queued.
    pub fn update(a: Adapter, b: *Bridge) void {
        if (accesskit_macos_subclassing_adapter_update_if_active(a.raw, Bridge.factory, b)) |ev|
            accesskit_macos_queued_events_raise(ev);
    }

    /// The window became or stopped being key.
    pub fn setFocused(a: Adapter, focused: bool) void {
        if (accesskit_macos_subclassing_adapter_update_view_focus_state(a.raw, focused)) |ev|
            accesskit_macos_queued_events_raise(ev);
    }
};

test "macos: the adapter's calls resolve against AccessKit's library" {
    // Linking is the check (`zig build accesskit-build -Dtarget=aarch64-macos` on a Mac); an
    // NSWindow needs the AppKit run loop, which a test does not have.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    _ = &Adapter.init;
    _ = &Adapter.deinit;
    _ = &Adapter.update;
    _ = &Adapter.setFocused;
}
