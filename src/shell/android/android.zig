//! The Android shell: a NativeActivity's window, its input queue as `Events`, its frames drawn
//! by the Vulkan back end (src/render/vk/) into a swapchain over the window. It meets the shell
//! contract of src/shell/iface.zig without owning the loop: the activity's callbacks run on
//! Android's main thread and only post what changed; the host loop runs on a thread of its own
//! (as android_native_app_glue arranges, without the glue), where `poll` drains that thread's
//! ALooper without blocking and `wait` blocks in it.
//!
//! Outside the tiers (it calls libandroid and Vulkan), so it is a module of its own over `lcgr`
//! and the Vulkan back end (`zig build android-build -Dtarget=aarch64-linux-android`), never
//! imported by the core. The NDK is not used: the NativeActivity and input declarations below
//! are written by hand from the NDK's headers' documentation (native_activity.h, looper.h,
//! input.h), and libandroid, liblog and libc are linked by name through stub libraries
//! (build.zig) that only give the library its DT_NEEDED entries. Everything that does not call
//! the OS, reading what Android reports, is translate.zig, tested on every host.
//!
//! The application is a shared library whose `ANativeActivity_onCreate` is this file's; the
//! host provides `entry`, the host loop, as `pub fn androidMain() void` in its root file (the
//! example's main.zig). It runs once per process, on the shell's thread:
//!
//!     pub fn androidMain() void {
//!         var shell: android.Android = undefined;
//!         shell.init(buffers) catch return;
//!         defer shell.deinit();
//!         lcgr.shell_iface.run(&shell, &ctx, &app);
//!     }

const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");
const lcgr = @import("lcgr");
const vk = @import("vk");
const translate = lcgr.shell_android_translate;
const iface = lcgr.shell_iface;
const context = lcgr.context;
const Quad = lcgr.draw_list.Quad;
const Mono = lcgr.protocol.Mono;
const Color = lcgr.types.Color;
const Events = iface.Events;
const Platform = context.Platform;
const Output = context.Output;
const Pace = lcgr.scheduler.Pace;
const c = vk.c;

comptime {
    if (!builtin.abi.isAndroid()) @compileError("src/shell/android is the Android shell; build it with -Dtarget=aarch64-linux-android");
}

// ---- NDK declarations (native_activity.h, looper.h, input.h, native_window.h, log.h) ----------

pub const ANativeWindow = opaque {};
pub const AInputQueue = opaque {};
pub const AInputEvent = opaque {};
pub const ALooper = opaque {};
pub const ARect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
pub const JavaVM = opaque {};
pub const JNIEnv = opaque {};

pub const ANativeActivity = extern struct {
    callbacks: *Callbacks,
    vm: *JavaVM,
    /// The main thread's JNI environment; another thread attaches its own (jni.zig).
    env: *JNIEnv,
    /// The NativeActivity Java object.
    clazz: *anyopaque,
    internal_data_path: ?[*:0]const u8,
    external_data_path: ?[*:0]const u8,
    sdk_version: i32,
    instance: ?*anyopaque,
    asset_manager: ?*anyopaque,
    obb_path: ?[*:0]const u8,
};

const Act = *ANativeActivity;
pub const Callbacks = extern struct {
    onStart: ?*const fn (Act) callconv(.c) void,
    onResume: ?*const fn (Act) callconv(.c) void,
    onSaveInstanceState: ?*const fn (Act, *usize) callconv(.c) ?*anyopaque,
    onPause: ?*const fn (Act) callconv(.c) void,
    onStop: ?*const fn (Act) callconv(.c) void,
    onDestroy: ?*const fn (Act) callconv(.c) void,
    onWindowFocusChanged: ?*const fn (Act, c_int) callconv(.c) void,
    onNativeWindowCreated: ?*const fn (Act, *ANativeWindow) callconv(.c) void,
    onNativeWindowResized: ?*const fn (Act, *ANativeWindow) callconv(.c) void,
    onNativeWindowRedrawNeeded: ?*const fn (Act, *ANativeWindow) callconv(.c) void,
    onNativeWindowDestroyed: ?*const fn (Act, *ANativeWindow) callconv(.c) void,
    onInputQueueCreated: ?*const fn (Act, *AInputQueue) callconv(.c) void,
    onInputQueueDestroyed: ?*const fn (Act, *AInputQueue) callconv(.c) void,
    onContentRectChanged: ?*const fn (Act, *const ARect) callconv(.c) void,
    onConfigurationChanged: ?*const fn (Act) callconv(.c) void,
    onLowMemory: ?*const fn (Act) callconv(.c) void,
};

extern "android" fn ALooper_prepare(opts: c_int) *ALooper;
extern "android" fn ALooper_pollOnce(timeout_ms: c_int, fd: ?*c_int, events: ?*c_int, data: ?*?*anyopaque) c_int;
extern "android" fn ALooper_wake(looper: *ALooper) void;
extern "android" fn AInputQueue_attachLooper(q: *AInputQueue, looper: *ALooper, ident: c_int, callback: ?*const anyopaque, data: ?*anyopaque) void;
extern "android" fn AInputQueue_detachLooper(q: *AInputQueue) void;
extern "android" fn AInputQueue_getEvent(q: *AInputQueue, out: *?*AInputEvent) i32;
extern "android" fn AInputQueue_preDispatchEvent(q: *AInputQueue, e: *AInputEvent) i32;
extern "android" fn AInputQueue_finishEvent(q: *AInputQueue, e: *AInputEvent, handled: c_int) void;
extern "android" fn ANativeWindow_getWidth(w: *ANativeWindow) i32;
extern "android" fn ANativeWindow_getHeight(w: *ANativeWindow) i32;
extern "android" fn ANativeWindow_acquire(w: *ANativeWindow) void;
extern "android" fn ANativeWindow_release(w: *ANativeWindow) void;
extern "android" fn ANativeActivity_finish(a: Act) void;
extern "android" fn AInputEvent_getType(e: *const AInputEvent) i32;
extern "android" fn AMotionEvent_getAction(e: *const AInputEvent) i32;
extern "android" fn AMotionEvent_getButtonState(e: *const AInputEvent) i32;
extern "android" fn AMotionEvent_getPointerCount(e: *const AInputEvent) usize;
extern "android" fn AMotionEvent_getPointerId(e: *const AInputEvent, i: usize) i32;
extern "android" fn AMotionEvent_getToolType(e: *const AInputEvent, i: usize) i32;
extern "android" fn AMotionEvent_getX(e: *const AInputEvent, i: usize) f32;
extern "android" fn AMotionEvent_getY(e: *const AInputEvent, i: usize) f32;
extern "android" fn AMotionEvent_getPressure(e: *const AInputEvent, i: usize) f32;
extern "android" fn AMotionEvent_getAxisValue(e: *const AInputEvent, axis: i32, i: usize) f32;
extern "android" fn AKeyEvent_getAction(e: *const AInputEvent) i32;
extern "android" fn AKeyEvent_getKeyCode(e: *const AInputEvent) i32;
extern "android" fn AKeyEvent_getMetaState(e: *const AInputEvent) i32;
extern "android" fn AKeyEvent_getRepeatCount(e: *const AInputEvent) i32;
extern "android" fn AConfiguration_new() ?*anyopaque;
extern "android" fn AConfiguration_delete(config: *anyopaque) void;
extern "android" fn AConfiguration_fromAssetManager(config: *anyopaque, assets: *anyopaque) void;
extern "android" fn AConfiguration_getDensity(config: *anyopaque) i32;
extern "log" fn __android_log_write(prio: c_int, tag: [*:0]const u8, text: [*:0]const u8) c_int;

const looper_poll_timeout = -3;
const input_event_type_key = 1;
const input_event_type_motion = 2;
const axis_orientation = 8;
const axis_vscroll = 9;
const axis_hscroll = 10;
const axis_tilt = 25;
/// The looper ident the input queue reports with.
const ident_input = 1;
const log_error = 6;

fn logError(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrintSentinel(&buf, fmt, args, 0) catch return;
    _ = __android_log_write(log_error, "lcgr", s);
}

// ---- The activity: callbacks on the main thread, the host loop on its own -----------------------

/// What the main thread's callbacks post for the shell's thread, under `mutex`. A callback
/// that takes something away (the window, the input queue) waits until the shell's thread has
/// let go of it (`acked`), as Android requires before the callback returns.
const Shared = struct {
    // pthreads, which bionic's zeroed initialisers make ready: the shell has no std.Io (a
    // shared library gets no `main`), and these are libc's anyway.
    mutex: std.c.pthread_mutex_t = .{},
    cond: std.c.pthread_cond_t = .{},
    activity: ?Act = null,
    window: ?*ANativeWindow = null,
    queue: ?*AInputQueue = null,
    /// Bumped by every change; `acked` reaches it once the shell's thread has applied them.
    posted: u32 = 0,
    acked: u32 = 0,
    resized: bool = false,
    destroyed: bool = false,
    /// The content rect (`onContentRectChanged`), window pixels; null before the first.
    content: ?ARect = null,
    /// The shell's thread's looper, for `ALooper_wake`; null until its thread runs.
    looper: ?*ALooper = null,
    /// The host loop is running (a shell exists to apply changes).
    running: bool = false,
};
// ponytail: one activity per process, as a NativeActivity app has (Android may destroy and
// recreate the activity; the process and its host loop live on).
var shared: Shared = .{};
var thread_started = false;

fn lock() void {
    _ = std.c.pthread_mutex_lock(&shared.mutex);
}
fn unlock() void {
    _ = std.c.pthread_mutex_unlock(&shared.mutex);
}
fn broadcast() void {
    _ = std.c.pthread_cond_broadcast(&shared.cond);
}

/// Posts a change and wakes the shell's thread; with `wait`, blocks until it was applied.
fn post(comptime change: fn (*Shared) void, wait: bool) void {
    lock();
    defer unlock();
    change(&shared);
    shared.posted +%= 1;
    const target = shared.posted;
    if (shared.looper) |l| ALooper_wake(l);
    while (wait and shared.running and shared.acked != target) _ = std.c.pthread_cond_wait(&shared.cond, &shared.mutex);
}

var pending_window: ?*ANativeWindow = null;
var pending_queue: ?*AInputQueue = null;

fn setWindow(s: *Shared) void {
    s.window = pending_window;
}
fn setQueue(s: *Shared) void {
    s.queue = pending_queue;
}
fn setResized(s: *Shared) void {
    s.resized = true;
}
fn setDestroyed(s: *Shared) void {
    s.destroyed = true;
}
var pending_content: ARect = undefined;
fn setContent(s: *Shared) void {
    s.content = pending_content;
}
fn setConfiguration(_: *Shared) void {}

fn onNativeWindowCreated(_: Act, w: *ANativeWindow) callconv(.c) void {
    pending_window = w;
    post(setWindow, false);
}
fn onNativeWindowDestroyed(_: Act, _: *ANativeWindow) callconv(.c) void {
    pending_window = null;
    post(setWindow, true);
}
fn onNativeWindowResized(_: Act, _: *ANativeWindow) callconv(.c) void {
    post(setResized, false);
}
fn onInputQueueCreated(_: Act, q: *AInputQueue) callconv(.c) void {
    pending_queue = q;
    post(setQueue, false);
}
fn onInputQueueDestroyed(_: Act, _: *AInputQueue) callconv(.c) void {
    pending_queue = null;
    post(setQueue, true);
}
fn onDestroy(_: Act) callconv(.c) void {
    post(setDestroyed, true);
}
fn onContentRectChanged(_: Act, r: *const ARect) callconv(.c) void {
    pending_content = r.*;
    post(setContent, false);
}
/// The density may have changed (moved to another display, display size changed in Settings):
/// every posted change re-reads it.
fn onConfigurationChanged(_: Act) callconv(.c) void {
    post(setConfiguration, false);
}

/// The library's entry point: Android calls it on the main thread when the activity is
/// created (again after each destruction, while the process lives).
pub export fn ANativeActivity_onCreate(activity: Act, _: ?*anyopaque, _: usize) callconv(.c) void {
    const cb = activity.callbacks;
    cb.onNativeWindowCreated = &onNativeWindowCreated;
    cb.onNativeWindowDestroyed = &onNativeWindowDestroyed;
    cb.onNativeWindowResized = &onNativeWindowResized;
    cb.onInputQueueCreated = &onInputQueueCreated;
    cb.onInputQueueDestroyed = &onInputQueueDestroyed;
    cb.onDestroy = &onDestroy;
    cb.onContentRectChanged = &onContentRectChanged;
    cb.onConfigurationChanged = &onConfigurationChanged;
    lock();
    shared.activity = activity;
    shared.destroyed = false;
    unlock();
    if (thread_started) return;
    const t = std.Thread.spawn(.{}, threadMain, .{}) catch |e| return logError("cannot start the shell's thread: {t}", .{e});
    t.detach();
    thread_started = true;
}

fn threadMain() void {
    const looper = ALooper_prepare(0);
    lock();
    shared.looper = looper;
    unlock();
    root.androidMain();
    lock();
    const a = shared.activity;
    unlock();
    if (a) |activity| ANativeActivity_finish(activity);
}

// ---- Vulkan over the window ----------------------------------------------------------------------

/// VK_KHR_android_surface (vulkan_android.h, not in vulkan_core.h).
const VkAndroidSurfaceCreateInfoKHR = extern struct {
    sType: c.VkStructureType = 1000008000,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    window: *ANativeWindow,
};
const PFN_vkCreateAndroidSurfaceKHR = ?*const fn (c.VkInstance, *const VkAndroidSurfaceCreateInfoKHR, ?*const anyopaque, *c.VkSurfaceKHR) callconv(.c) c.VkResult;
const instance_extensions = [_][*:0]const u8{ "VK_KHR_surface", "VK_KHR_android_surface" };

/// The device and what is drawn with: made once, kept while windows come and go.
const Gpu = struct {
    lib: vk.loader.Library,
    instance: vk.loader.Instance,
    device: vk.device.Device,
    once: vk.host.Once,
    sampler: c.VkSampler,
    white: vk.device.Image,
    gfx: vk.Renderer,
    format: c.VkFormat,

    /// Fills `g` in place (the renderer keeps a pointer to its device). `surface` picks a
    /// device that can present to it.
    fn init(g: *Gpu, surface_window: *ANativeWindow) !c.VkSurfaceKHR {
        g.lib = try openVulkan();
        errdefer g.lib.close();
        g.instance = try vk.loader.Instance.init(&g.lib, .{ .app_name = "lcgr-android", .extensions = &instance_extensions });
        errdefer g.instance.deinit();
        const surface = try createSurface(&g.instance, surface_window);
        errdefer vk.swapchain.destroySurface(&g.instance, surface);
        g.device = try vk.device.Device.init(&g.instance, try vk.device.pick(&g.instance, surface), true);
        errdefer g.device.deinit();
        const d = &g.device;
        g.once = try vk.host.Once.init(d);
        g.sampler = try vk.host.nearestSampler(d);
        var h: vk.host.Host = .{ .lib = g.lib, .instance = g.instance, .device = g.device, .once = g.once };
        g.white = try h.sampled(1, 1, &.{ 0xff, 0xff, 0xff, 0xff });
        // The swapchain's format: Android offers RGBA8 (and often BGRA8) for windows.
        var probe = try vk.swapchain.Swapchain.init(&g.instance, d, surface, .{ .width = 1, .height = 1 }, null);
        g.format = probe.format;
        probe.deinit(d);
        g.gfx = try vk.Renderer.init(d, .{ .format = g.format, .frames = 2 }, g.white.view, g.sampler);
        return surface;
    }

    fn deinit(g: *Gpu) void {
        const d = &g.device;
        _ = d.fns.vkDeviceWaitIdle.?(d.handle);
        g.gfx.deinit(d);
        d.destroyImage(&g.white);
        d.fns.vkDestroySampler.?(d.handle, g.sampler, null);
        g.once.deinit(d);
        g.device.deinit();
        g.instance.deinit();
        g.lib.close();
    }
};

/// `vk.loader.Library.open` for Android's libvulkan.so. ponytail: open's own dlsym cast does
/// not compile for aarch64 (a function pointer is 4-aligned there and the cast lacks an
/// @alignCast; the Vulkan lane's code); use open again once it does.
fn openVulkan() !vk.loader.Library {
    const handle = std.c.dlopen("libvulkan.so", .{ .NOW = true }) orelse return error.NoLoader;
    errdefer _ = std.c.dlclose(handle);
    const sym = std.c.dlsym(handle, "vkGetInstanceProcAddr") orelse return error.NoLoader;
    const get: c.PFN_vkGetInstanceProcAddr = @ptrCast(@alignCast(sym));
    return .{ .handle = handle, .getInstanceProcAddr = get, .fns = try vk.loader.load(vk.loader.GlobalFns, get, @as(c.VkInstance, null)) };
}

fn createSurface(instance: *const vk.loader.Instance, window: *ANativeWindow) !c.VkSurfaceKHR {
    const create = instance.proc(PFN_vkCreateAndroidSurfaceKHR, "vkCreateAndroidSurfaceKHR") orelse return error.MissingExtension;
    var surface: c.VkSurfaceKHR = null;
    try vk.loader.check(create(instance.handle, &.{ .window = window }, null, &surface));
    return surface;
}

/// The window's surface, swapchain and frames: made when a window arrives, gone with it.
const Target = struct {
    window: *ANativeWindow,
    surface: c.VkSurfaceKHR,
    chain: vk.swapchain.Swapchain,
    frames: vk.frame.Frames,
};

/// Most pointers read from one motion event.
const translate_max = 16;

// ---- The shell -----------------------------------------------------------------------------------

pub const Android = struct {
    t: translate.Translator,
    looper: *ALooper,
    queue: ?*AInputQueue = null,
    gpu: ?Gpu = null,
    target: ?Target = null,
    /// The last change from the main thread applied.
    seen: u32 = 0,
    font: Mono = .{},
    glyphs: Buffers,
    /// What `present` clears to before drawing.
    background: Color = .rgb(0, 0, 0),
    /// Set by `wake` from any thread; the next `poll` clears it.
    woken: std.atomic.Value(bool) = .init(false),
    /// The display's refresh rate, for `.display` pacing.
    hz: f32 = 60,
    polls: u32 = 0,
    presents: u32 = 0,

    /// Caller-owned storage: one glyph quad per byte of text in a frame (`first` and `count`
    /// one row per text run); `text` and `events` hold typed text, half arriving, half shown.
    pub const Buffers = struct { glyphs: []Quad, first: []u32, count: []u32, text: []u8, events: []lcgr.input.Input.Event };

    /// The shell, on the thread that runs `androidMain`. It must not move afterwards.
    pub fn init(s: *Android, buf: Buffers) error{NoLooper}!void {
        lock();
        const looper = shared.looper orelse {
            unlock();
            return error.NoLooper;
        };
        shared.running = true;
        unlock();
        s.* = .{ .t = .init(.{ .text = buf.text, .events = buf.events }), .looper = looper, .glyphs = buf };
    }

    pub fn deinit(s: *Android) void {
        lock();
        shared.running = false;
        broadcast();
        unlock();
        s.dropTarget();
        if (s.gpu) |*g| g.deinit();
        s.gpu = null;
        if (s.queue) |q| AInputQueue_detachLooper(q);
    }

    /// Applies what the main thread posted: a new or lost window, input queue, size.
    fn sync(s: *Android) void {
        lock();
        defer unlock();
        if (shared.posted == s.seen) return;
        if (shared.queue != s.queue) {
            if (s.queue) |q| AInputQueue_detachLooper(q);
            s.queue = shared.queue;
            if (s.queue) |q| AInputQueue_attachLooper(q, s.looper, ident_input, null, null);
        }
        const window = if (s.target) |tg| tg.window else null;
        if (shared.window != window) {
            s.dropTarget();
            if (shared.window) |w| s.makeTarget(w);
        }
        if (shared.destroyed) s.t.destroy();
        if (shared.activity) |a| s.t.setDensity(density(a));
        if (shared.content) |r| s.t.setContent(@floatFromInt(r.left), @floatFromInt(r.top), @floatFromInt(r.right), @floatFromInt(r.bottom));
        shared.resized = false;
        s.seen = shared.posted;
        shared.acked = s.seen;
        broadcast();
    }

    /// The screen's density from the activity's configuration, dpi (0 when unknown).
    fn density(a: Act) u32 {
        const assets = a.asset_manager orelse return 0;
        const config = AConfiguration_new() orelse return 0;
        defer AConfiguration_delete(config);
        AConfiguration_fromAssetManager(config, assets);
        return @intCast(@max(AConfiguration_getDensity(config), 0));
    }

    /// The safe area as root padding (`Style.pad`): what the status bar, the navigation bar
    /// and display cutouts cover, as far as the content rect says.
    pub fn safeArea(s: *const Android) [4]f32 {
        return s.t.safe();
    }

    fn makeTarget(s: *Android, window: *ANativeWindow) void {
        ANativeWindow_acquire(window);
        s.makeTargetOrLog(window) catch |e| {
            logError("no Vulkan target for the window: {t}", .{e});
            ANativeWindow_release(window);
        };
    }

    fn makeTargetOrLog(s: *Android, window: *ANativeWindow) !void {
        s.resize(window);
        const surface = if (s.gpu) |*g| try createSurface(&g.instance, window) else blk: {
            s.gpu = @as(Gpu, undefined);
            errdefer s.gpu = null;
            break :blk try s.gpu.?.init(window);
        };
        const g = &s.gpu.?;
        errdefer vk.swapchain.destroySurface(&g.instance, surface);
        var chain = try vk.swapchain.Swapchain.init(&g.instance, &g.device, surface, extent(s.t.window), null);
        errdefer chain.deinit(&g.device);
        s.target = .{ .window = window, .surface = surface, .chain = chain, .frames = try .init(&g.device, 2) };
    }

    fn dropTarget(s: *Android) void {
        const tg = &(s.target orelse return);
        const g = &s.gpu.?;
        _ = g.device.fns.vkDeviceWaitIdle.?(g.device.handle);
        tg.frames.deinit(&g.device);
        tg.chain.deinit(&g.device);
        vk.swapchain.destroySurface(&g.instance, tg.surface);
        ANativeWindow_release(tg.window);
        s.target = null;
    }

    fn resize(s: *Android, window: *ANativeWindow) void {
        s.t.resize(@floatFromInt(ANativeWindow_getWidth(window)), @floatFromInt(ANativeWindow_getHeight(window)));
    }

    fn extent(px: [2]f32) c.VkExtent2D {
        return .{ .width = @intFromFloat(@max(px[0], 1)), .height = @intFromFloat(@max(px[1], 1)) };
    }

    /// Drains the looper (input, posted changes) without blocking, then gives the frame.
    pub fn poll(s: *Android, ev: *Events) bool {
        s.sync();
        while (true) {
            const ident = ALooper_pollOnce(0, null, null, null);
            if (ident == ident_input) s.drainInput() else if (ident == looper_poll_timeout or ident < -1) break;
            s.sync();
        }
        if (s.target) |tg| s.resize(tg.window);
        _ = s.woken.swap(false, .acq_rel);
        s.polls += 1;
        return s.t.frame(ev);
    }

    fn drainInput(s: *Android) void {
        const q = s.queue orelse return;
        var e: ?*AInputEvent = null;
        while (AInputQueue_getEvent(q, &e) >= 0) {
            const event = e orelse continue;
            // The IME may take the event first; then it comes back later, or never.
            if (AInputQueue_preDispatchEvent(q, event) != 0) continue;
            AInputQueue_finishEvent(q, event, @intFromBool(s.handle(event)));
        }
    }

    /// Reads one input event into the translator; true when it was used.
    fn handle(s: *Android, e: *AInputEvent) bool {
        switch (AInputEvent_getType(e)) {
            input_event_type_motion => {
                var ptrs: [translate_max]translate.Pointer = undefined;
                const n = @min(AMotionEvent_getPointerCount(e), ptrs.len);
                for (ptrs[0..n], 0..) |*p, i| p.* = .{
                    .id = @bitCast(AMotionEvent_getPointerId(e, i)),
                    .tool = @fromBackingInt(@intCast(@as(u8, @truncate(@as(u32, @bitCast(AMotionEvent_getToolType(e, i))))))),
                    .pos = .{ AMotionEvent_getX(e, i), AMotionEvent_getY(e, i) },
                    .pressure = AMotionEvent_getPressure(e, i),
                    .tilt = AMotionEvent_getAxisValue(e, axis_tilt, i),
                    .orientation = AMotionEvent_getAxisValue(e, axis_orientation, i),
                };
                s.t.motion(.{
                    .action = @bitCast(AMotionEvent_getAction(e)),
                    .pointers = ptrs[0..n],
                    .buttons = @bitCast(AMotionEvent_getButtonState(e)),
                    .scroll = .{ AMotionEvent_getAxisValue(e, axis_hscroll, 0), AMotionEvent_getAxisValue(e, axis_vscroll, 0) },
                });
                return true;
            },
            input_event_type_key => return s.t.key(
                @fromBackingInt(@intCast(@as(u8, @truncate(@as(u32, @bitCast(AKeyEvent_getAction(e))))))),
                @bitCast(AKeyEvent_getKeyCode(e)),
                @bitCast(AKeyEvent_getMetaState(e)),
                @bitCast(AKeyEvent_getRepeatCount(e)),
            ),
            else => return false,
        }
    }

    pub fn apply(_: *Android, _: *const Platform) void {}

    /// Draws the frame into the next swapchain image and presents it. A changed or lost
    /// swapchain (rotation, resize) is rebuilt at the window's size for the next frame.
    pub fn present(s: *Android, out: *const Output) void {
        const tg = &(s.target orelse return);
        const g = &s.gpu.?;
        s.draw(tg, g, out) catch |e| switch (e) {
            error.OutOfDate => s.rebuild(tg, g),
            else => logError("present: {t}", .{e}),
        };
    }

    fn draw(s: *Android, tg: *Target, g: *Gpu, out: *const Output) !void {
        const d = &g.device;
        const want = extent(s.t.window);
        if (want.width != tg.chain.extent.width or want.height != tg.chain.extent.height) s.rebuild(tg, g);
        const f = try tg.frames.begin(d, &tg.chain);
        const in = &s.t.m.in;
        const gl = s.glyphs;
        const n = s.font.quads(out.draw, gl.glyphs, .{ .first = gl.first, .count = gl.count });
        g.gfx.prepare(f.slot, out.draw, .{ .quads = gl.glyphs[0..n], .first = gl.first, .count = gl.count }, in.viewport, in.scale);
        const bg = s.background;
        vk.pass.begin(d, f.cmd, .{ .image = f.image, .view = f.view, .extent = tg.chain.extent, .clear = .{ unit(bg.r), unit(bg.g), unit(bg.b), 1 } });
        g.gfx.render(f.cmd, out.draw);
        vk.pass.end(d, f.cmd, .{ .image = f.image, .layout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR });
        if (try tg.frames.present(d, &tg.chain, f) == .suboptimal) s.rebuild(tg, g);
        s.presents += 1;
    }

    fn rebuild(s: *Android, tg: *Target, g: *Gpu) void {
        tg.frames.resize(&g.device, &tg.chain, &g.instance, tg.surface, extent(s.t.window)) catch |e| logError("swapchain: {t}", .{e});
    }

    fn unit(v: u8) f32 {
        return @as(f32, @floatFromInt(v)) / 255;
    }

    /// Blocks in the looper until an event, a posted change or a `wake`, at most `seconds`;
    /// `.display` waits one refresh (FIFO presentation paces it too).
    pub fn wait(s: *Android, seconds: f32, pace: Pace) void {
        if (s.woken.load(.acquire) or s.t.m.pending()) return;
        const secs = if (pace == .display) 1 / s.hz else seconds;
        if (!(secs > 0)) return;
        // Past ~24 days the milliseconds would not fit: wait without a timeout.
        const ms: c_int = if (secs >= 2e6) -1 else @intFromFloat(@ceil(secs * 1000));
        _ = ALooper_pollOnce(ms, null, null, null);
    }

    /// Thread-safe: ends a `wait` in progress, and has the next `poll` give a frame.
    pub fn wake(s: *Android) void {
        s.woken.store(true, .release);
        ALooper_wake(s.looper);
    }
};

comptime {
    iface.check(Android);
}
