//! The macOS shell: one NSWindow whose content view is drawn by the Metal back end, its events as
//! `Events`. It meets the shell contract of src/shell/iface.zig and never owns the loop: `poll`
//! drains AppKit's event queue without blocking and returns, `wait` is the only call that sleeps
//! (no `[NSApp run]`).
//!
//! Outside the tiers (it calls AppKit), so it is a module of its own over `lcgr` and the Metal
//! back end (`zig build macos`, `zig build macos-build`), never imported by the core. AppKit is
//! reached the way src/render/metal/objc.zig reaches Metal: libobjc and the frameworks are opened
//! at run time and every message goes through `objc_msgSend`, so the shell cross-compiles from
//! any host and links nothing. Everything that does not call the OS, the reading of each event,
//! is translate.zig, tested on every host.
//!
//! AppKit delivers events by calling methods on a view. The shell registers one NSView subclass
//! at run time (`LCGRView`, as GPUI's `GPUIView`) whose methods find their `Macos` through an
//! instance variable and hand the event to the translator, so `init` builds the shell in place
//! and it must not move afterwards. The view is also the window's delegate.

const std = @import("std");
const builtin = @import("builtin");
const lcgr = @import("lcgr");
const metal = @import("metal");
const objc = metal.objc;
const translate = lcgr.shell_macos_translate;
const iface = lcgr.shell_iface;
const context = lcgr.context;
const Quad = lcgr.draw_list.Quad;
const Mono = lcgr.protocol.Mono;
const Color = lcgr.types.Color;
const Events = iface.Events;
const Platform = context.Platform;
const Output = context.Output;
const Pace = lcgr.scheduler.Pace;
const Id = objc.Id;
const Sel = objc.Sel;
const U = objc.NSUInteger;

comptime {
    if (builtin.os.tag != .macos) @compileError("src/shell/macos is the macOS shell; build it with -Dtarget=aarch64-macos or x86_64-macos");
}

// ---- The Objective-C runtime beyond messaging (objc/runtime.h) ------------------------------

pub const NSPoint = extern struct { x: f64 = 0, y: f64 = 0 };
pub const NSSize = extern struct { width: f64 = 0, height: f64 = 0 };
pub const NSRect = extern struct { origin: NSPoint = .{}, size: NSSize = .{} };

const Runtime = struct {
    objc_msgSend: *const fn () callconv(.c) void,
    objc_allocateClassPair: *const fn (Id, [*:0]const u8, usize) callconv(.c) ?Id,
    objc_registerClassPair: *const fn (Id) callconv(.c) void,
    class_addMethod: *const fn (Id, Sel, *const anyopaque, [*:0]const u8) callconv(.c) bool,
    class_addIvar: *const fn (Id, [*:0]const u8, usize, u8, [*:0]const u8) callconv(.c) bool,
    class_getInstanceVariable: *const fn (Id, [*:0]const u8) callconv(.c) ?*anyopaque,
    object_getIvar: *const fn (Id, *anyopaque) callconv(.c) ?*anyopaque,
    object_setIvar: *const fn (Id, *anyopaque, ?*anyopaque) callconv(.c) void,
};

// ponytail: process-global, as the Objective-C runtime and NSApp they point into are.
var rt: Runtime = undefined;
/// `objc_msgSend_stret`: x86_64 returns structs over 16 bytes (NSRect) through it; arm64 has none.
var msg_stret: ?*const fn () callconv(.c) void = null;
var view_class: Id = undefined;
var shell_ivar: *anyopaque = undefined;
var default_mode: Id = undefined;
var launched = false;

const libobjc = "/usr/lib/libobjc.A.dylib";
const foundation = "/System/Library/Frameworks/Foundation.framework/Foundation";
const appkit = "/System/Library/Frameworks/AppKit.framework/AppKit";

pub const Error = objc.Error || metal.device.Error || metal.renderer.Error || error{ ClassFailed, CreateWindow };

/// Opens AppKit, registers the view class and starts NSApp as a regular app (a Dock icon, a
/// menu bar, key focus). Once per process; later calls return at once.
fn launch() Error!void {
    if (launched) return;
    try objc.load();
    const lib = std.c.dlopen(libobjc, .{ .NOW = true }) orelse return error.NoLibrary;
    const fnd = std.c.dlopen(foundation, .{ .NOW = true }) orelse return error.NoLibrary;
    _ = std.c.dlopen(appkit, .{ .NOW = true }) orelse return error.NoLibrary;
    inline for (@typeInfo(Runtime).@"struct".field_names) |name| {
        @field(rt, name) = @ptrCast(@alignCast(std.c.dlsym(lib, name.ptr) orelse return error.MissingFunction));
    }
    if (builtin.cpu.arch == .x86_64) msg_stret = @ptrCast(@alignCast(std.c.dlsym(lib, "objc_msgSend_stret") orelse return error.MissingFunction));
    const mode: *const Id = @ptrCast(@alignCast(std.c.dlsym(fnd, "NSDefaultRunLoopMode") orelse return error.MissingFunction));
    default_mode = mode.*;
    try registerView();
    const pool = objc.Pool.push();
    defer pool.pop();
    const a = app();
    msg(void, a, "setActivationPolicy:", .{@as(isize, 0)}); // NSApplicationActivationPolicyRegular
    msg(void, a, "finishLaunching", .{});
    launched = true;
}

fn app() Id {
    return msg(Id, objc.class("NSApplication"), "sharedApplication", .{});
}

/// The C signature of `objc_msgSend` for `Args`, up to nine arguments (NSEvent's constructors
/// take nine; src/render/metal/objc.zig stops at five).
fn Send(comptime R: type, comptime Args: type) type {
    const a = @typeInfo(Args).@"struct".field_types;
    return switch (a.len) {
        0...5 => objc.Send(R, Args),
        6 => fn (Id, Sel, a[0], a[1], a[2], a[3], a[4], a[5]) callconv(.c) R,
        7 => fn (Id, Sel, a[0], a[1], a[2], a[3], a[4], a[5], a[6]) callconv(.c) R,
        8 => fn (Id, Sel, a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7]) callconv(.c) R,
        9 => fn (Id, Sel, a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8]) callconv(.c) R,
        else => @compileError("macos.msg: more than 9 arguments"),
    };
}

/// Sends `selector` to `target` with `args` (a tuple of C-ABI values), as `objc.msg`.
fn msg(comptime R: type, target: Id, comptime selector: [:0]const u8, args: anytype) R {
    const f: *const Send(R, @TypeOf(args)) = @ptrCast(rt.objc_msgSend);
    return @call(.auto, f, .{ target, objc.sel(selector) } ++ args);
}

/// A message returning NSRect: through `objc_msgSend_stret` on x86_64, where a 32-byte struct is
/// returned in memory; Zig's C calling convention passes that memory the way it expects.
fn msgRect(target: Id, comptime selector: [:0]const u8, args: anytype) NSRect {
    const f: *const Send(NSRect, @TypeOf(args)) = @ptrCast(msg_stret orelse rt.objc_msgSend);
    return @call(.auto, f, .{ target, objc.sel(selector) } ++ args);
}

/// The method of `LCGRView` for each selector, with its type encoding (`v@:@`: returns void,
/// takes self, _cmd and one object).
const methods = .{
    .{ "acceptsFirstResponder", &acceptsFirstResponder, "c@:" },
    .{ "windowDidResize:", &windowDidResize, "v@:@" },
    .{ "windowShouldClose:", &windowShouldClose, "c@:@" },
    .{ "windowDidResignKey:", &windowDidResignKey, "v@:@" },
    .{ "insertText:", &insertText, "v@:@" },
    .{ "doCommandBySelector:", &doCommandBySelector, "v@::" },
} ++ events: {
    // Every mouse, key and scroll event goes to `onEvent`.
    const names = .{ "mouseDown:", "mouseUp:", "rightMouseDown:", "rightMouseUp:", "otherMouseDown:", "otherMouseUp:", "mouseMoved:", "mouseDragged:", "rightMouseDragged:", "otherMouseDragged:", "mouseEntered:", "mouseExited:", "scrollWheel:", "keyDown:", "keyUp:", "flagsChanged:" };
    var t: [names.len]struct { [:0]const u8, *const anyopaque, [:0]const u8 } = undefined;
    for (names, 0..) |n, i| t[i] = .{ n, &onEvent, "v@:@" };
    break :events t;
};

fn registerView() Error!void {
    const cls = rt.objc_allocateClassPair(objc.class("NSView"), "LCGRView", 0) orelse return error.ClassFailed;
    if (!rt.class_addIvar(cls, "lcgr", @sizeOf(usize), std.math.log2(@alignOf(usize)), "^v")) return error.ClassFailed;
    inline for (methods) |m| {
        if (!rt.class_addMethod(cls, objc.sel(m[0]), @ptrCast(m[1]), m[2])) return error.ClassFailed;
    }
    rt.objc_registerClassPair(cls);
    view_class = cls;
    shell_ivar = rt.class_getInstanceVariable(cls, "lcgr") orelse return error.ClassFailed;
}

/// The shell a view method was called on.
fn shellOf(view: Id) *Macos {
    return @ptrCast(@alignCast(rt.object_getIvar(view, shell_ivar).?));
}

fn acceptsFirstResponder(_: Id, _: Sel) callconv(.c) bool {
    return true;
}

fn windowDidResize(view: Id, _: Sel, _: Id) callconv(.c) void {
    const b = msgRect(view, "bounds", .{});
    shellOf(view).t.resize(.{ b.size.width, b.size.height });
}

/// Reads an NSEvent into `translate.Event`, asking only for the fields its type has (AppKit
/// raises for `keyCode` on a mouse event), and hands it to the translator. A key press also
/// goes through `interpretKeyEvents:`, which calls `insertText:` with the text it types.
fn onEvent(view: Id, _: Sel, e: Id) callconv(.c) void {
    const kind: translate.Kind = @fromBackingInt(@intCast(@as(u32, @truncate(msg(U, e, "type", .{})))));
    var ev: translate.Event = .{ .kind = kind, .flags = msg(U, e, "modifierFlags", .{}) };
    switch (kind) {
        .key_down, .key_up, .flags_changed => ev.code = msg(u16, e, "keyCode", .{}),
        .scroll => {
            ev.delta = .{ msg(f64, e, "scrollingDeltaX", .{}), msg(f64, e, "scrollingDeltaY", .{}) };
            ev.precise = msg(bool, e, "hasPreciseScrollingDeltas", .{});
        },
        else => {
            const p = msg(NSPoint, e, "locationInWindow", .{});
            ev.at = .{ p.x, p.y };
            if (kind == .other_down or kind == .other_up or kind == .other_dragged) ev.code = @truncate(@as(U, @bitCast(msg(isize, e, "buttonNumber", .{}))));
        },
    }
    if (kind == .key_down) ev.repeat = msg(bool, e, "isARepeat", .{});
    const m = shellOf(view);
    m.t.feed(.{ .event = ev });
    if (kind == .key_down) msg(void, view, "interpretKeyEvents:", .{msg(Id, objc.class("NSArray"), "arrayWithObject:", .{e})});
}

/// Text a key typed. `text` is an NSString, or an NSAttributedString from an input method.
fn insertText(view: Id, _: Sel, text: Id) callconv(.c) void {
    shellOf(view).t.feed(.{ .insert = utf8(text) });
}

/// Keys that edit rather than type (arrows, Return, Delete) arrive here from
/// `interpretKeyEvents:`; their key events already reached the UI, so nothing is done (and
/// NSResponder's beep is not sounded).
fn doCommandBySelector(_: Id, _: Sel, _: Sel) callconv(.c) void {}

fn windowDidResignKey(view: Id, _: Sel, _: Id) callconv(.c) void {
    shellOf(view).t.feed(.resign);
}

/// The UTF-8 of an NSString or NSAttributedString, valid while the autorelease pool lasts.
fn utf8(s: Id) []const u8 {
    const str = if (msg(bool, s, "isKindOfClass:", .{objc.class("NSAttributedString")})) msg(Id, s, "string", .{}) else s;
    const p = msg(?[*:0]const u8, str, "UTF8String", .{}) orelse return "";
    return std.mem.span(p);
}

/// The close button or Cmd+W: the user's request. The host decides, so the window stays open
/// until `deinit`; `poll` returns false from now on.
fn windowShouldClose(view: Id, _: Sel, _: Id) callconv(.c) bool {
    shellOf(view).t.feed(.close);
    return false;
}

const ns_window_style = 1 | 2 | 4 | 8; // titled, closable, miniaturizable, resizable
const ns_backing_store_buffered = 2;
const ns_event_mask_any: u64 = std.math.maxInt(u64);
const ns_event_type_application_defined = 15;
/// The subtype of the NSEvent `wake` posts.
const wake_subtype = 0x6c63; // "lc"
const ns_event_type_key_up = 11;
/// NSTrackingArea options: entered and exited, moves, always (not only in the key window), and
/// the rectangle follows the view's visible rectangle.
const ns_tracking = 0x01 | 0x02 | 0x80 | 0x200;

// ---- The shell ------------------------------------------------------------------------------

pub const Macos = struct {
    window: Id,
    view: Id,
    t: translate.Translator = .{},
    dev: metal.device.Device,
    layer: metal.device.Layer,
    gfx: metal.Renderer,
    frames: metal.present.Frames,
    font: Mono = .{},
    glyphs: GlyphBuffers,
    /// What `present` clears to before drawing.
    background: Color = .rgb(0, 0, 0),
    /// The effects of the last frame, as `apply` received them.
    applied: Platform = .{},

    pub const Options = struct {
        title: [:0]const u8 = "LCGR",
        /// Content size in points (logical pixels).
        size: [2]u32 = .{ 800, 600 },
        /// False for a window that stays hidden (tests).
        show: bool = true,
    };

    /// Caller-owned storage: `text` and `events` one frame's typed text and key events, `glyphs` one quad per byte of text in a frame (at most the
    /// renderer's 32768), `first` and `count` one row per text run.
    pub const Buffers = struct {
        text: []u8,
        events: []lcgr.input.Input.Event,
        glyphs: []Quad,
        first: []u32,
        count: []u32,
    };
    const GlyphBuffers = struct { quads: []Quad, first: []u32, count: []u32 };

    /// Opens the window. `m` is where the shell lives from now on: the view finds it there.
    pub fn init(m: *Macos, opt: Options, buf: Buffers) Error!void {
        try launch();
        const pool = objc.Pool.push();
        defer pool.pop();
        var dev = try metal.device.Device.init();
        errdefer dev.deinit();
        var gfx = try metal.Renderer.init(dev.device, .{ .format = .bgra8_unorm });
        errdefer gfx.deinit();
        const size: [2]f32 = .{ @floatFromInt(opt.size[0]), @floatFromInt(opt.size[1]) };
        const rect: NSRect = .{ .size = .{ .width = size[0], .height = size[1] } };
        const window = msg(?Id, msg(Id, objc.class("NSWindow"), "alloc", .{}), "initWithContentRect:styleMask:backing:defer:", .{ rect, @as(U, ns_window_style), @as(U, ns_backing_store_buffered), false }) orelse return error.CreateWindow;
        const view = msg(Id, msg(Id, view_class, "alloc", .{}), "initWithFrame:", .{rect});
        m.* = .{
            .window = window,
            .view = view,
            .dev = dev,
            .layer = .init(&dev, .{ .size = size, .scale = 1 }),
            .gfx = gfx,
            .frames = .init(dev.queue, gfx.desc.frames_in_flight),
            .t = .init(.{ .text = buf.text, .events = buf.events }),
            .glyphs = .{ .quads = buf.glyphs, .first = buf.first, .count = buf.count },
        };
        rt.object_setIvar(view, shell_ivar, m);
        m.t.resize(.{ size[0], size[1] });
        msg(void, window, "setReleasedWhenClosed:", .{false});
        msg(void, window, "setTitle:", .{objc.string(opt.title)});
        msg(void, window, "setContentView:", .{view});
        msg(void, window, "setDelegate:", .{view});
        _ = msg(bool, window, "makeFirstResponder:", .{view});
        msg(void, window, "setAcceptsMouseMovedEvents:", .{true});
        const area = msg(Id, msg(Id, objc.class("NSTrackingArea"), "alloc", .{}), "initWithRect:options:owner:userInfo:", .{ NSRect{}, @as(U, ns_tracking), view, @as(?Id, null) });
        msg(void, view, "addTrackingArea:", .{area});
        objc.release(area);
        m.layer.attach(view);
        if (opt.show) {
            msg(void, window, "center", .{});
            msg(void, window, "makeKeyAndOrderFront:", .{@as(?Id, null)});
            msg(void, app(), "activateIgnoringOtherApps:", .{true});
        }
    }

    pub fn deinit(m: *Macos) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        m.frames.deinit();
        msg(void, m.window, "setDelegate:", .{@as(?Id, null)});
        msg(void, m.window, "close", .{});
        objc.release(m.window);
        objc.release(m.view);
        m.layer.deinit();
        m.gfx.deinit();
        m.dev.deinit();
    }

    /// Drains AppKit's event queue without blocking; the view's methods translate each event.
    /// False once the user closed the window.
    pub fn poll(m: *Macos, ev: *Events) bool {
        const pool = objc.Pool.push();
        defer pool.pop();
        const a = app();
        const past = msg(Id, objc.class("NSDate"), "distantPast", .{});
        while (msg(?Id, a, "nextEventMatchingMask:untilDate:inMode:dequeue:", .{ ns_event_mask_any, past, default_mode, true })) |e| {
            // `wake`'s event only ends a wait.
            if (msg(U, e, "type", .{}) == ns_event_type_application_defined and msg(i16, e, "subtype", .{}) == wake_subtype) continue;
            // NSApp does not pass on a key release while Command is held; the window does.
            if (msg(U, e, "type", .{}) == ns_event_type_key_up) {
                if (msg(?Id, e, "window", .{})) |w| msg(void, w, "sendEvent:", .{e});
                continue;
            }
            msg(void, a, "sendEvent:", .{e});
        }
        return m.t.frame(ev);
    }

    pub fn apply(m: *Macos, p: *const Platform) void {
        m.applied = p.*;
    }

    /// Draws the frame with Metal into the view's layer and presents it.
    pub fn present(m: *Macos, out: *const Output) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const vp = m.t.in.viewport;
        _ = m.layer.resize(vp, m.t.in.scale);
        // After `begin` the slot's instances are free to rewrite.
        const cmd = m.frames.begin();
        const g = m.glyphs;
        const n = m.font.quads(out.draw, g.quads, .{ .first = g.first, .count = g.count });
        m.gfx.prepare({}, out.draw, .{ .quads = g.quads[0..n], .first = g.first, .count = g.count }, vp, m.t.in.scale);
        const drawable = metal.present.nextDrawable(m.layer.layer) orelse return;
        const c = m.background;
        const clear: [4]f64 = .{ @as(f64, @floatFromInt(c.r)) / 255, @as(f64, @floatFromInt(c.g)) / 255, @as(f64, @floatFromInt(c.b)) / 255, @as(f64, @floatFromInt(c.a)) / 255 };
        const pass = metal.present.beginPass(cmd, metal.present.drawableTexture(drawable), clear);
        m.gfx.render(pass, out.draw);
        metal.present.endPass(pass);
        m.frames.present(cmd, drawable, null);
    }

    /// Blocks until the next event or `seconds` pass (`inf`: until the next event). The event
    /// stays queued for the next `poll`.
    pub fn wait(_: *Macos, seconds: f32, _: Pace) void {
        if (!(seconds > 0)) return;
        const pool = objc.Pool.push();
        defer pool.pop();
        const date = if (std.math.isInf(seconds))
            msg(Id, objc.class("NSDate"), "distantFuture", .{})
        else
            msg(Id, objc.class("NSDate"), "dateWithTimeIntervalSinceNow:", .{@as(f64, seconds)});
        _ = msg(?Id, app(), "nextEventMatchingMask:untilDate:inMode:dequeue:", .{ ns_event_mask_any, date, default_mode, false });
    }

    /// Thread-safe: posts an application-defined event, which ends a `wait` (AppKit documents
    /// `postEvent:atStart:` as callable from any thread).
    pub fn wake(_: *Macos) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const e = msg(?Id, objc.class("NSEvent"), "otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:", .{
            @as(U, ns_event_type_application_defined), NSPoint{}, @as(U, 0), @as(f64, 0), @as(isize, 0), @as(?Id, null), @as(i16, wake_subtype), @as(isize, 0), @as(isize, 0),
        }) orelse return;
        msg(void, app(), "postEvent:atStart:", .{ e, false });
    }
};

comptime {
    iface.check(Macos);
}

// ---- Tests: on macOS only (`zig build macos`) -----------------------------------------------

const testing = std.testing;
const example_limits: context.Limits = .{ .nodes = 1024, .texts = 256 };

const Fixture = struct {
    var ctx_buffer: [context.Context.requiredBytes(example_limits)]u8 align(lcgr.mem.column_align) = undefined;
    var text: [64]u8 = undefined;
    var events: [16]lcgr.input.Input.Event = undefined;
    var glyphs: [512]Quad = undefined;
    var first: [256]u32 = undefined;
    var count: [256]u32 = undefined;

    fn open(m: *Macos) !void {
        try m.init(.{ .show = false }, .{ .text = &text, .events = &events, .glyphs = &glyphs, .first = &first, .count = &count });
    }
};

test "macos: a real window reports its size, a resize and the close button" {
    var m: Macos = undefined;
    try Fixture.open(&m);
    defer m.deinit();
    var ev: Events = .{};
    try testing.expect(m.poll(&ev));
    try testing.expectEqual([2]f32{ 800, 600 }, ev.in.viewport);
    msg(void, m.window, "setContentSize:", .{NSSize{ .width = 640, .height = 480 }});
    try testing.expect(m.poll(&ev));
    try testing.expectEqual([2]f32{ 640, 480 }, ev.in.viewport);
    msg(void, m.window, "performClose:", .{@as(?Id, null)});
    try testing.expect(!m.poll(&ev));
}

test "macos: wake ends a wait with no timeout" {
    var m: Macos = undefined;
    try Fixture.open(&m);
    defer m.deinit();
    m.wake();
    m.wait(std.math.inf(f32), .idle);
    var ev: Events = .{};
    try testing.expect(m.poll(&ev));
}

/// Posts a recorded frame's NSEvents to the application and polls: what the view receives is
/// what a user's input would give it. Window-level records (resize, close, typed text) are fed
/// to the translator directly, as the delegate methods would.
fn mouse(k: translate.Kind) bool {
    return switch (k) {
        .key_down, .key_up, .flags_changed, .scroll => false,
        else => true,
    };
}

fn replayFrame(m: *Macos, r: *translate.Replay, ev: *Events) !?bool {
    var buf: [32]translate.Record = undefined;
    const records = (try r.next(&buf)) orelse return null;
    const pool = objc.Pool.push();
    defer pool.pop();
    const number = msg(isize, m.window, "windowNumber", .{});
    for (records) |rec| switch (rec) {
        // ponytail: mouse events only, which is what the example's recording holds; key and
        // scroll events need constructors with more arguments and are fed directly.
        .event => |e| if (mouse(e.kind)) {
            const ns = msg(?Id, objc.class("NSEvent"), "mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:", .{
                @as(U, @backingInt(e.kind)), NSPoint{ .x = e.at[0], .y = e.at[1] }, @as(U, e.flags), @as(f64, 0), number, @as(?Id, null), @as(isize, 0), @as(isize, 1), @as(f32, 1),
            }) orelse return error.NoEvent;
            msg(void, app(), "postEvent:atStart:", .{ ns, false });
        } else m.t.feed(rec),
        else => m.t.feed(rec),
    };
    return m.poll(ev);
}

test "macos: a real window runs the example from posted events" {
    var m: Macos = undefined;
    try Fixture.open(&m);
    defer m.deinit();
    var ctx = try context.Context.init(&Fixture.ctx_buffer, example_limits);
    var app_: lcgr.shell_example.App = .{};
    var r: translate.Replay = .{ .src = @embedFile("testdata/example.events") };
    var ev: Events = .{};
    var frames: u32 = 0;
    while (try replayFrame(&m, &r, &ev)) |open| : (frames += 1) {
        try testing.expect(open);
        if (!ctx.needsFrame(&ev.in)) continue;
        var f = ctx.begin(&ev.in);
        app_.build(&f, &ev);
        const out = f.end(.{});
        m.apply(&out.platform);
        m.present(&out);
    }
    // The headless shell's results (src/shell/headless.zig).
    try testing.expectEqual(@as(u32, 15), frames);
    try testing.expectEqual(@as(u32, 13), app_.builds);
    try testing.expectEqual(@as(u32, 1), app_.resets);
    try testing.expectEqual(@as(u32, 4), app_.layers);
    try testing.expectApproxEqAbs(@as(f32, 3), app_.exposure, 0.01);
}
