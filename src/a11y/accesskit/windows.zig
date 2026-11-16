//! Windows: AccessKit's subclassing adapter on the shell's window, serving UI Automation
//! (Narrator, NVDA, JAWS). Subclassing lets AccessKit answer `WM_GETOBJECT` and track the
//! window's focus itself, so the shell's window procedure needs no change.
//!
//! Host loop, on the thread that owns the window:
//!
//!     var ak = windows.Adapter.init(hwnd, &host.b); // before the window is first shown
//!     ... each built frame: host.frame(&ctx, &out); ak.update(&host.b);
//!     ak.deinit();                                  // before the window is destroyed

const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig");
const Bridge = @import("bridge.zig").Bridge;

const Raw = opaque {};
const QueuedEvents = opaque {};
extern fn accesskit_windows_subclassing_adapter_new(hwnd: *anyopaque, activation: c.ActivationHandler, activation_userdata: ?*anyopaque, action: c.ActionHandler, action_userdata: ?*anyopaque) *Raw;
extern fn accesskit_windows_subclassing_adapter_free(adapter: *Raw) void;
extern fn accesskit_windows_subclassing_adapter_update_if_active(adapter: *Raw, factory: c.TreeUpdateFactory, userdata: ?*anyopaque) ?*QueuedEvents;
extern fn accesskit_windows_queued_events_raise(events: *QueuedEvents) void;

pub const Adapter = struct {
    raw: *Raw,

    /// Subclasses `hwnd` (an `HWND`). AccessKit panics if the window is already visible.
    /// `b` must outlive the adapter: AccessKit calls back into it.
    pub fn init(hwnd: *anyopaque, b: *Bridge) Adapter {
        return .{ .raw = accesskit_windows_subclassing_adapter_new(hwnd, Bridge.activate, b, Bridge.act, b) };
    }

    pub fn deinit(a: Adapter) void {
        accesskit_windows_subclassing_adapter_free(a.raw);
    }

    /// After `Bridge.frame`: sends the frame's update if a client is connected, then raises the
    /// UI Automation events it queued (focus moved, name or toggle changed).
    pub fn update(a: Adapter, b: *Bridge) void {
        if (accesskit_windows_subclassing_adapter_update_if_active(a.raw, Bridge.factory, b)) |ev|
            accesskit_windows_queued_events_raise(ev);
    }
};

const testing = std.testing;

extern "user32" fn CreateWindowExW(ex_style: u32, class: [*:0]const u16, name: [*:0]const u16, style: u32, x: i32, y: i32, w: i32, h: i32, parent: ?*anyopaque, menu: ?*anyopaque, instance: ?*anyopaque, param: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "user32" fn DestroyWindow(hwnd: *anyopaque) callconv(.winapi) i32;

test "windows: the adapter subclasses a hidden window and stays quiet with no client" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f: @import("bridge.zig").Fixture(32) = .{};
    f.init();
    f.reset();
    @import("bridge.zig").buildToolbar(&f, true, 1);
    f.end(0);
    const hwnd = CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), std.unicode.utf8ToUtf16LeStringLiteral("Example"), 0, 0, 0, 200, 100, null, null, null, null) orelse return error.NoWindow;
    defer _ = DestroyWindow(hwnd);
    const ak = Adapter.init(hwnd, &f.b);
    defer ak.deinit();
    // No UI Automation client asked yet: nothing is built or sent.
    ak.update(&f.b);
    try testing.expect(!f.b.full.load(.acquire));
}
