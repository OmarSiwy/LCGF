//! The iOS shell: one full-screen UIKit view backed by a CAMetalLayer, its events as `Events`,
//! its frames drawn by the Metal back end (src/render/metal/). It meets the shell contract of
//! src/shell/iface.zig without owning the loop: UIKit's run loop is pumped by `poll` (without
//! blocking) and `wait` (until the next event or the timeout), SDL's way of running a host
//! loop inside UIKit.
//!
//! Outside the tiers (it calls UIKit, Core Foundation and Metal), so it is a module of its own
//! over `lcgr` and the Metal back end (`zig build ios-build -Dtarget=aarch64-ios`), never
//! imported by the core. UIKit is reached through the Objective-C runtime (the Metal back end's
//! objc.zig, plus the class-building calls below) and Core Foundation through hand-written
//! extern declarations opened at run time, so nothing is linked but libSystem. Everything that
//! does not call the OS, reading what UIKit reports, is translate.zig, tested on every host.
//!
//! UIKit owns `main`: `start` calls UIApplicationMain, whose application delegate opens the
//! window and the view and then calls the host's `entry` from the run loop. `entry` is the host
//! loop (`iface.run`'s body, or a copy of it); when it returns, the app exits.
//!
//!     export fn main(argc: c_int, argv: [*]?[*:0]u8) c_int {
//!         ios.start(argc, argv, run); // never returns
//!     }
//!     fn run() void {
//!         var shell: ios.Ios = undefined;
//!         shell.init(buffers) catch return;
//!         defer shell.deinit();
//!         lcgr.shell_iface.run(&shell, &ctx, &app);
//!     }

const std = @import("std");
const builtin = @import("builtin");
const lcgr = @import("lcgr");
const metal = @import("metal");
const translate = lcgr.shell_ios_translate;
const iface = lcgr.shell_iface;
const context = lcgr.context;
const Quad = lcgr.draw_list.Quad;
const Mono = lcgr.protocol.Mono;
const Color = lcgr.types.Color;
const Events = iface.Events;
const Platform = context.Platform;
const Output = context.Output;
const Pace = lcgr.scheduler.Pace;
const objc = metal.objc;
const text_input = @import("text_input.zig");
const present_ = metal.present;
const Id = objc.Id;
const Sel = objc.Sel;
const msg = objc.msg;
const CGFloat = objc.CGFloat;

comptime {
    if (builtin.os.tag != .ios or builtin.cpu.arch != .aarch64) @compileError("src/shell/ios is the iOS shell; build it with -Dtarget=aarch64-ios");
}

// ---- Objective-C runtime, UIKit and Core Foundation declarations --------------------------------

pub const CGPoint = extern struct { x: CGFloat, y: CGFloat };
pub const CGRect = extern struct { origin: CGPoint, size: objc.CGSize };
pub const UIEdgeInsets = extern struct { top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat };
const CFRunLoop = *opaque {};
const CFRunLoopSource = *opaque {};
const CFString = *opaque {};
const CFRunLoopSourceContext = extern struct {
    version: isize = 0,
    info: ?*anyopaque = null,
    retain: ?*const anyopaque = null,
    release: ?*const anyopaque = null,
    copy_description: ?*const anyopaque = null,
    equal: ?*const anyopaque = null,
    hash: ?*const anyopaque = null,
    schedule: ?*const anyopaque = null,
    cancel: ?*const anyopaque = null,
    perform: ?*const fn (?*anyopaque) callconv(.c) void = null,
};
/// `objc_super`: the receiver and the class whose superclass's method runs.
const Super = extern struct { receiver: Id, class: Id };
/// CFRunLoopRunInMode's result when a source was handled.
const run_handled_source = 4;

/// The runtime and framework functions this file calls, fetched once by `load`.
pub const Fns = struct {
    objc_allocateClassPair: *const fn (Id, [*:0]const u8, usize) callconv(.c) ?Id,
    objc_registerClassPair: *const fn (Id) callconv(.c) void,
    class_addMethod: *const fn (Id, Sel, *const anyopaque, [*:0]const u8) callconv(.c) bool,
    object_getClass: *const fn (Id) callconv(.c) Id,
    objc_msgSendSuper: *const fn () callconv(.c) void,
    class_addIvar: *const fn (Id, [*:0]const u8, usize, u8, [*:0]const u8) callconv(.c) bool,
    class_getInstanceVariable: *const fn (Id, [*:0]const u8) callconv(.c) ?*anyopaque,
    ivar_getOffset: *const fn (*anyopaque) callconv(.c) isize,
    objc_getProtocol: *const fn ([*:0]const u8) callconv(.c) ?*anyopaque,
    class_addProtocol: *const fn (Id, *anyopaque) callconv(.c) bool,
    UIApplicationMain: *const fn (c_int, ?[*]?[*:0]u8, ?Id, ?Id) callconv(.c) c_int,
    CFRunLoopGetMain: *const fn () callconv(.c) CFRunLoop,
    CFRunLoopRunInMode: *const fn (CFString, f64, bool) callconv(.c) i32,
    CFRunLoopWakeUp: *const fn (CFRunLoop) callconv(.c) void,
    CFRunLoopSourceCreate: *const fn (?*anyopaque, isize, *CFRunLoopSourceContext) callconv(.c) ?CFRunLoopSource,
    CFRunLoopAddSource: *const fn (CFRunLoop, CFRunLoopSource, CFString) callconv(.c) void,
    CFRunLoopSourceSignal: *const fn (CFRunLoopSource) callconv(.c) void,
};
// ponytail: process-global, as UIKit's one application is.
pub var fns: Fns = undefined;
var default_mode: CFString = undefined;
var common_modes: CFString = undefined;

const libs = [_][:0]const u8{
    "/usr/lib/libobjc.A.dylib",
    "/System/Library/Frameworks/UIKit.framework/UIKit",
    "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",
};

pub const Error = objc.Error || metal.device.Error || metal.renderer.Error || error{ NoView, RunLoop };

fn load() Error!void {
    try objc.load();
    var handles: [libs.len]*anyopaque = undefined;
    for (libs, &handles) |path, *h| h.* = std.c.dlopen(path, .{ .NOW = true }) orelse return error.NoLibrary;
    inline for (@typeInfo(Fns).@"struct".field_names) |name| {
        @field(fns, name) = for (handles) |h| {
            if (std.c.dlsym(h, name)) |p| break @ptrCast(@alignCast(p));
        } else return error.MissingFunction;
    }
    const cf = handles[2];
    default_mode = @as(*const CFString, @ptrCast(@alignCast(std.c.dlsym(cf, "kCFRunLoopDefaultMode") orelse return error.MissingFunction))).*;
    common_modes = @as(*const CFString, @ptrCast(@alignCast(std.c.dlsym(cf, "kCFRunLoopCommonModes") orelse return error.MissingFunction))).*;
}

/// Sends `selector` to `self` as `class`'s superclass implements it.
pub fn super(comptime R: type, self: Id, class: Id, comptime selector: [:0]const u8, args: anytype) R {
    const sup: Super = .{ .receiver = self, .class = msg(Id, class, "superclass", .{}) };
    const A = @typeInfo(@TypeOf(args)).@"struct".field_types;
    const F = switch (A.len) {
        0 => fn (*const Super, Sel) callconv(.c) R,
        1 => fn (*const Super, Sel, A[0]) callconv(.c) R,
        2 => fn (*const Super, Sel, A[0], A[1]) callconv(.c) R,
        else => @compileError("super: more than 2 arguments"),
    };
    const f: *const F = @ptrCast(fns.objc_msgSendSuper);
    return @call(.auto, f, .{ &sup, objc.sel(selector) } ++ args);
}

/// A new class `name` under `parent` with `methods` (selector, implementation, type encoding).
/// Class methods go on the metaclass: pass `meta = true`.
pub const Method = struct { sel: [:0]const u8, imp: *const anyopaque, types: [:0]const u8, meta: bool = false };
fn defineClass(comptime parent: [:0]const u8, name: [:0]const u8, comptime methods: []const Method) Id {
    return defineClassWith(parent, name, methods, &.{});
}

/// `defineClass` with NSInteger instance variables, read and written with `ivar`.
fn defineClassWith(comptime parent: [:0]const u8, name: [:0]const u8, comptime methods: []const Method, comptime ivars: []const [:0]const u8) Id {
    const cls = fns.objc_allocateClassPair(objc.class(parent), name, 0) orelse std.debug.panic("ios: class {s} exists", .{name});
    inline for (ivars) |v| _ = fns.class_addIvar(cls, v, @sizeOf(isize), 3, "q");
    inline for (methods) |m| {
        const target = if (m.meta) fns.object_getClass(cls) else cls;
        _ = fns.class_addMethod(target, objc.sel(m.sel), m.imp, m.types);
    }
    fns.objc_registerClassPair(cls);
    return cls;
}

// ---- The application: delegate, window, view ---------------------------------------------------

/// What UIKit's callbacks reach: the host's entry, the view, and the shell once `init` ran.
pub const App = struct {
    entry: *const fn () void = undefined,
    window: ?Id = null,
    view: ?Id = null,
    view_class: Id = undefined,
    shell: ?*Ios = null,
};
// ponytail: one application, one window, one view per process, as UIKit gives a scene-less app.
pub var app: App = .{};

/// Hands the process to UIKit, which calls `entry` once the window is up. Never returns: the
/// app exits when `entry` does.
pub fn start(argc: c_int, argv: ?[*]?[*:0]u8, entry: *const fn () void) noreturn {
    load() catch |e| std.debug.panic("ios: {t}", .{e});
    app.entry = entry;
    app.view_class = defineClass("UIView", "LcgrView", &[_]Method{
        .{ .sel = "layerClass", .imp = &viewLayerClass, .types = "#@:", .meta = true },
        .{ .sel = "layoutSubviews", .imp = &viewLayout, .types = "v@:" },
        .{ .sel = "safeAreaInsetsDidChange", .imp = &viewInsets, .types = "v@:" },
        .{ .sel = "touchesBegan:withEvent:", .imp = &viewTouches, .types = "v@:@@" },
        .{ .sel = "touchesMoved:withEvent:", .imp = &viewTouches, .types = "v@:@@" },
        .{ .sel = "touchesEnded:withEvent:", .imp = &viewTouches, .types = "v@:@@" },
        .{ .sel = "touchesCancelled:withEvent:", .imp = &viewTouches, .types = "v@:@@" },
        .{ .sel = "pressesBegan:withEvent:", .imp = &viewPressesBegan, .types = "v@:@@" },
        .{ .sel = "pressesEnded:withEvent:", .imp = &viewPressesEnded, .types = "v@:@@" },
        .{ .sel = "pressesCancelled:withEvent:", .imp = &viewPressesCancelled, .types = "v@:@@" },
    } ++ text_input.methods);
    for ([_][*:0]const u8{ "UIKeyInput", "UITextInput" }) |name| {
        if (fns.objc_getProtocol(name)) |proto| _ = fns.class_addProtocol(app.view_class, proto);
    }
    text_input.position_class = defineClassWith("UITextPosition", "LcgrTextPosition", &.{}, &.{"o"});
    text_input.range_class = defineClassWith("UITextRange", "LcgrTextRange", &.{
        .{ .sel = "start", .imp = &text_input.rangeStart, .types = "@@:" },
        .{ .sel = "end", .imp = &text_input.rangeEnd, .types = "@@:" },
        .{ .sel = "isEmpty", .imp = &text_input.rangeEmpty, .types = "B@:" },
    }, &.{ "a", "b" });
    _ = defineClass("UIResponder", "LcgrAppDelegate", &.{
        .{ .sel = "application:didFinishLaunchingWithOptions:", .imp = &appLaunched, .types = "B@:@@" },
        .{ .sel = "lcgrRun", .imp = &appRun, .types = "v@:" },
        .{ .sel = "applicationWillResignActive:", .imp = &appInactive, .types = "v@:@" },
        .{ .sel = "applicationDidEnterBackground:", .imp = &appBackground, .types = "v@:@" },
        .{ .sel = "applicationWillEnterForeground:", .imp = &appInactive, .types = "v@:@" },
        .{ .sel = "applicationDidBecomeActive:", .imp = &appActive, .types = "v@:@" },
        .{ .sel = "applicationWillTerminate:", .imp = &appTerminate, .types = "v@:@" },
    });
    const pool = objc.Pool.push();
    const delegate = objc.string("LcgrAppDelegate");
    _ = fns.UIApplicationMain(argc, argv, null, delegate);
    pool.pop();
    std.process.exit(0);
}

fn viewLayerClass(_: Id, _: Sel) callconv(.c) Id {
    return objc.class("CAMetalLayer");
}

/// The bounds changed (launch, rotation, split view): the next frame lays out at the new size.
fn viewLayout(self: Id, _: Sel) callconv(.c) void {
    super(void, self, app.view_class, "layoutSubviews", .{});
    if (app.shell) |s| s.layout();
}

/// Every touch callback: each UITouch of the set says its own phase.
fn viewTouches(self: Id, _: Sel, touches: Id, _: ?Id) callconv(.c) void {
    const s = app.shell orelse return;
    const all = msg(Id, touches, "allObjects", .{});
    const n = msg(objc.NSUInteger, all, "count", .{});
    for (0..n) |i| s.touch(self, msg(Id, all, "objectAtIndex:", .{@as(objc.NSUInteger, i)}));
}

fn viewInsets(self: Id, _: Sel) callconv(.c) void {
    super(void, self, app.view_class, "safeAreaInsetsDidChange", .{});
    if (app.shell) |s| s.layout();
}

/// Hardware keys: each UIPress's UIKey (iOS 13.4+) is a key event; then UIKit's own handling,
/// which inserts the text a key types through `insertText:`.
fn presses(self: Id, set: Id, event: ?Id, down: bool, comptime selector: [:0]const u8) void {
    if (app.shell) |s| {
        const all = msg(Id, set, "allObjects", .{});
        for (0..msg(objc.NSUInteger, all, "count", .{})) |i| {
            const k = msg(?Id, msg(Id, all, "objectAtIndex:", .{@as(objc.NSUInteger, i)}), "key", .{}) orelse continue;
            const code: u32 = @intCast(@max(msg(objc.NSInteger, k, "keyCode", .{}), 0));
            s.t.key(code, down, @bitCast(msg(objc.NSInteger, k, "modifierFlags", .{})));
        }
    }
    super(void, self, app.view_class, selector, .{ set, event });
}

fn viewPressesBegan(self: Id, _: Sel, set: Id, event: ?Id) callconv(.c) void {
    presses(self, set, event, true, "pressesBegan:withEvent:");
}
fn viewPressesEnded(self: Id, _: Sel, set: Id, event: ?Id) callconv(.c) void {
    presses(self, set, event, false, "pressesEnded:withEvent:");
}
fn viewPressesCancelled(self: Id, _: Sel, set: Id, event: ?Id) callconv(.c) void {
    presses(self, set, event, false, "pressesCancelled:withEvent:");
}

fn appLaunched(self: Id, _: Sel, _: Id, _: ?Id) callconv(.c) bool {
    const screen = msg(Id, objc.class("UIScreen"), "mainScreen", .{});
    const bounds = msg(CGRect, screen, "bounds", .{});
    const window = msg(Id, msg(Id, objc.class("UIWindow"), "alloc", .{}), "initWithFrame:", .{bounds});
    const view = msg(Id, msg(Id, app.view_class, "alloc", .{}), "initWithFrame:", .{bounds});
    msg(void, view, "setMultipleTouchEnabled:", .{@as(objc.BOOL, true)});
    // A view with its own layer class draws at 1x unless told the screen's scale.
    msg(void, view, "setContentScaleFactor:", .{msg(CGFloat, screen, "nativeScale", .{})});
    const vc = msg(Id, objc.class("UIViewController"), "new", .{});
    msg(void, vc, "setView:", .{view});
    msg(void, window, "setRootViewController:", .{vc});
    msg(void, window, "makeKeyAndVisible", .{});
    app.window = window;
    app.view = view;
    // The host loop runs from the run loop, after launching has finished.
    msg(void, self, "performSelector:withObject:afterDelay:", .{ objc.sel("lcgrRun"), @as(?Id, null), @as(f64, 0) });
    return true;
}

fn appInactive(_: Id, _: Sel, _: Id) callconv(.c) void {
    if (app.shell) |s| s.t.lifecycle(.inactive);
}
fn appBackground(_: Id, _: Sel, _: Id) callconv(.c) void {
    if (app.shell) |s| s.t.lifecycle(.background);
}
fn appActive(_: Id, _: Sel, _: Id) callconv(.c) void {
    if (app.shell) |s| s.t.lifecycle(.active);
}
/// The system is ending the app (rare: usually it is suspended, then killed without notice).
fn appTerminate(_: Id, _: Sel, _: Id) callconv(.c) void {
    if (app.shell) |s| s.t.terminate();
}

fn appRun(_: Id, _: Sel) callconv(.c) void {
    app.entry();
    std.process.exit(0);
}

// ---- The shell ---------------------------------------------------------------------------------

pub const Ios = struct {
    t: translate.Translator = .{},
    view: Id,
    dev: metal.device.Device,
    layer: metal.device.Layer,
    gfx: metal.Renderer,
    frames: present_.Frames,
    font: Mono = .{},
    glyphs: Buffers,
    /// What `present` clears to before drawing.
    background: Color = .rgb(0, 0, 0),
    source: CFRunLoopSource,
    run_loop: CFRunLoop,
    /// Set by `wake` from any thread; the next `poll` clears it.
    woken: std.atomic.Value(bool) = .init(false),
    /// The display's refresh rate (UIScreen.maximumFramesPerSecond), for `.display` pacing.
    hz: f32 = 60,
    polls: u32 = 0,
    presents: u32 = 0,
    /// The UITouch object behind each translator id (id = row + 1), null for a free row. UIKit
    /// keeps a touch's object from began to ended.
    touches: [translate.max_contacts]?Id = @splat(null),
    /// Text input as last applied: whether the view is first responder (keyboard up), and
    /// the rect (points) the IME's candidates and the text-selection UI anchor to.
    text: struct { wants: bool = false, rect: lcgr.types.Rect = .{} } = .{},
    /// The IME's marked text (retained, an NSString) and the UTF-16 range it selects: the
    /// whole document UITextInput sees (text_input).
    marked: ?Id = null,
    selected: [2]usize = .{ 0, 0 },
    input_delegate: ?Id = null,
    /// A recording of UIKit events (translate.Replay) fed to the translator one frame per
    /// `poll` instead of waiting for the user: the input replay test on a device.
    recording: ?translate.Replay = null,
    /// Why `poll` ended a recording early: a bad line (`recording.line`).
    err: ?translate.Replay.Error = null,
    tokenizer: ?Id = null,

    /// Caller-owned storage: one glyph quad per byte of text in a frame; `first` and `count`
    /// one row per text run.
    /// `text` and `events` hold what arrives between polls and the frame handed out (half each):
    /// pasted and, later, typed text.
    pub const Buffers = struct { glyphs: []Quad, first: []u32, count: []u32, text: []u8, events: []lcgr.input.Input.Event };

    /// The shell over the view the application delegate opened. Call from `start`'s `entry`;
    /// the shell must not move afterwards (UIKit's callbacks point at it).
    pub fn init(s: *Ios, buf: Buffers) Error!void {
        const view = app.view orelse return error.NoView;
        var dev = try metal.device.Device.init();
        errdefer dev.deinit();
        // The view's own layer is the CAMetalLayer (`layerClass`); configure it as Layer.init would.
        const layer = msg(Id, view, "layer", .{});
        msg(void, layer, "setDevice:", .{dev.device});
        msg(void, layer, "setPixelFormat:", .{metal.mtl.PixelFormat.bgra8_unorm});
        msg(void, layer, "setFramebufferOnly:", .{@as(objc.BOOL, true)});
        msg(void, layer, "setOpaque:", .{@as(objc.BOOL, true)});
        var gfx = try metal.Renderer.init(dev.device, .{});
        errdefer gfx.deinit();
        var ctx: CFRunLoopSourceContext = .{ .perform = &performWake };
        const run_loop = fns.CFRunLoopGetMain();
        const source = fns.CFRunLoopSourceCreate(null, 0, &ctx) orelse return error.RunLoop;
        fns.CFRunLoopAddSource(run_loop, source, common_modes);
        const screen = msg(Id, objc.class("UIScreen"), "mainScreen", .{});
        s.* = .{
            .t = .init(.{ .text = buf.text, .events = buf.events }),
            .view = view,
            .dev = dev,
            .layer = .{ .layer = layer, .format = .bgra8_unorm },
            .gfx = gfx,
            .frames = .init(dev.queue, gfx.desc.frames_in_flight),
            .glyphs = buf,
            .source = source,
            .run_loop = run_loop,
            .hz = @floatFromInt(@max(msg(objc.NSInteger, screen, "maximumFramesPerSecond", .{}), 1)),
        };
        app.shell = s;
        s.layout();
    }

    pub fn deinit(s: *Ios) void {
        app.shell = null;
        s.frames.deinit();
        s.gfx.deinit();
        s.dev.deinit();
    }

    /// Reads the view's bounds, scale and safe area into the translator.
    fn layout(s: *Ios) void {
        const b = msg(CGRect, s.view, "bounds", .{});
        s.t.resize(@floatCast(b.size.width), @floatCast(b.size.height));
        s.t.setScale(@floatCast(msg(CGFloat, s.view, "contentScaleFactor", .{})));
        const i = msg(UIEdgeInsets, s.view, "safeAreaInsets", .{});
        s.t.setInsets(@floatCast(i.top), @floatCast(i.left), @floatCast(i.bottom), @floatCast(i.right));
    }

    /// True once after the app returned from the background: build a frame (post the
    /// context's waker), since frames built while it was away were not presented.
    pub fn resumed(s: *Ios) bool {
        return s.t.takeResumed();
    }

    /// The safe area as root padding (`Style.pad`): what the notch, the Dynamic Island and
    /// the home indicator cover.
    pub fn safeArea(s: *const Ios) [4]f32 {
        return s.t.safe;
    }

    fn touch(s: *Ios, view: Id, ui: Id) void {
        const phase: translate.Phase = @fromBackingInt(@intCast(@as(u8, @intCast(@min(msg(objc.NSInteger, ui, "phase", .{}), 4)))));
        const kind: translate.Kind = @fromBackingInt(@intCast(@as(u8, @intCast(@min(msg(objc.NSInteger, ui, "type", .{}), 3)))));
        const row = for (s.touches, 0..) |o, i| {
            if (o == ui) break i;
        } else for (s.touches, 0..) |o, i| {
            if (o == null) break i;
        } else return; // more touches than rows: the translator would drop it too
        s.touches[row] = if (phase == .ended or phase == .cancelled) null else ui;
        const at = msg(CGPoint, ui, "locationInView:", .{view});
        const max_force = msg(CGFloat, ui, "maximumPossibleForce", .{});
        var c: translate.Touch = .{
            .id = @intCast(row + 1),
            .phase = phase,
            .pos = .{ @floatCast(at.x), @floatCast(at.y) },
            .kind = kind,
            .pressure = if (max_force > 0) @floatCast(msg(CGFloat, ui, "force", .{}) / max_force) else 1,
        };
        if (kind == .pencil) {
            // Tilt from the normal is 90 degrees less the altitude, split along the azimuth.
            const lean = std.math.pi / 2.0 - msg(CGFloat, ui, "altitudeAngle", .{});
            const az = msg(CGFloat, ui, "azimuthAngleInView:", .{view});
            c.tilt = .{ @floatCast(lean * @cos(az)), @floatCast(lean * @sin(az)) };
        }
        s.t.touch(c);
    }

    /// Runs the events UIKit has pending, without blocking, then gives the frame.
    pub fn poll(s: *Ios, ev: *Events) bool {
        while (fns.CFRunLoopRunInMode(default_mode, 0, true) == run_handled_source) {}
        _ = s.woken.swap(false, .acq_rel);
        s.polls += 1;
        if (s.recording) |*r| {
            const more = r.next(&s.t) catch |e| blk: {
                s.err = e;
                break :blk false;
            };
            if (!more) return false;
        }
        return s.t.frame(ev);
    }

    /// Applies a frame's effects: text the frame copies goes to the general pasteboard; while
    /// a widget wants text the view is first responder, which brings up the soft keyboard (or
    /// takes a hardware keyboard's text), and its IME anchors at `ime_rect`.
    pub fn apply(s: *Ios, p: *const Platform) void {
        if (p.clipboard.len > 0) s.copy(p.clipboard);
        s.text.rect = p.ime_rect;
        if (p.wants_text != s.text.wants) {
            s.text.wants = p.wants_text;
            if (p.wants_text) {
                _ = msg(bool, s.view, "becomeFirstResponder", .{});
            } else {
                _ = msg(bool, s.view, "resignFirstResponder", .{});
                text_input.clear(s);
            }
        }
    }

    /// Puts UTF-8 text on the general pasteboard (`UIPasteboard.string`). Invalid UTF-8 leaves
    /// the pasteboard as it was.
    pub fn copy(_: *Ios, utf8: []const u8) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const str = msg(?Id, msg(Id, objc.class("NSString"), "alloc", .{}), "initWithBytes:length:encoding:", .{ utf8.ptr, @as(objc.NSUInteger, utf8.len), ns_utf8_encoding }) orelse return;
        defer objc.release(str);
        msg(void, generalPasteboard(), "setString:", .{str});
    }

    /// Types the pasteboard's text into the next frame, as `keyboard.Clipboard.paste` asks the
    /// host to: call it after a frame whose widgets requested a paste. iOS may ask the user
    /// first ("Allow Paste") and returns nothing if they decline.
    pub fn paste(s: *Ios) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const str = msg(?Id, generalPasteboard(), "string", .{}) orelse return;
        const utf8 = msg(?[*:0]const u8, str, "UTF8String", .{}) orelse return;
        s.t.paste(std.mem.span(utf8));
    }

    /// Draws the frame into the layer's next drawable and presents it.
    pub fn present(s: *Ios, out: *const Output) void {
        // In the background iOS kills an app that commits GPU work; nothing is shown anyway.
        if (!s.t.visible()) return;
        const pool = objc.Pool.push();
        defer pool.pop();
        const in = &s.t.in;
        _ = s.layer.resize(in.viewport, in.scale);
        const cmd = s.frames.begin();
        const g = s.glyphs;
        const n = s.font.quads(out.draw, g.glyphs, .{ .first = g.first, .count = g.count });
        s.gfx.prepare({}, out.draw, .{ .quads = g.glyphs[0..n], .first = g.first, .count = g.count }, in.viewport, in.scale);
        const drawable = present_.nextDrawable(s.layer.layer) orelse return;
        const c = s.background;
        const pass = present_.beginPass(cmd, present_.drawableTexture(drawable), .{ unit(c.r), unit(c.g), unit(c.b), 1 });
        s.gfx.render(pass, out.draw);
        present_.endPass(pass);
        s.frames.present(cmd, drawable, null);
        s.presents += 1;
    }

    fn unit(v: u8) f64 {
        return @as(f64, @floatFromInt(v)) / 255;
    }

    /// Runs the run loop until an event is handled or `seconds` pass; `.display` waits one
    /// refresh. Returns at once after a `wake`, or when the translator owes a frame (a tap's
    /// release). In the background it waits for the next event only.
    pub fn wait(s: *Ios, seconds: f32, pace: Pace) void {
        if (s.woken.load(.acquire) or s.t.pending() or s.recording != null) return;
        // In the background no frame is shown, so animations and timers wait for the return.
        const secs: f64 = if (!s.t.visible()) std.math.inf(f64) else if (pace == .display) 1 / s.hz else seconds;
        if (!(secs > 0)) return;
        _ = fns.CFRunLoopRunInMode(default_mode, @min(secs, 1e9), true);
    }

    /// Thread-safe: signals the shell's run loop source, which ends a `wait` in progress.
    pub fn wake(s: *Ios) void {
        s.woken.store(true, .release);
        fns.CFRunLoopSourceSignal(s.source);
        fns.CFRunLoopWakeUp(s.run_loop);
    }
};

const ns_utf8_encoding: objc.NSUInteger = 4;

fn generalPasteboard() Id {
    return msg(Id, objc.class("UIPasteboard"), "generalPasteboard", .{});
}

/// The wake source's callback: handling it is what ends the run loop's turn.
fn performWake(_: ?*anyopaque) callconv(.c) void {}

comptime {
    iface.check(Ios);
}
