//! The macOS shell: one NSWindow whose content view is drawn by the Metal back end's window
//! (`metal.setup.Window`: a kept picture, redrawn inside each frame's damage), its events as
//! `Events`. It meets the shell contract of src/shell/iface.zig and never owns the loop: `poll`
//! drains AppKit's event queue without blocking and returns, `wait` is the only call that sleeps
//! (no `[NSApp run]`).
//!
//! Outside the tiers (it calls AppKit), so it is a module of its own over `lcgf` and the Metal
//! back end (`zig build macos`, `zig build macos-build`), never imported by the core. AppKit is
//! reached the way src/render/metal/objc.zig reaches Metal: libobjc and the frameworks are opened
//! at run time and every message goes through `objc_msgSend`, so the shell cross-compiles from
//! any host and links nothing. Everything that does not call the OS, the reading of each event,
//! is translate.zig, tested on every host.
//!
//! AppKit delivers events by calling methods on a view. The shell registers one NSView subclass
//! at run time (`LCGFView`, as GPUI's `GPUIView`) whose methods find their `Macos` through an
//! instance variable and hand the event to the translator, so `init` builds the shell in place
//! and it must not move afterwards. The view is also the window's delegate.

const std = @import("std");
const builtin = @import("builtin");
const lcgf = @import("lcgf");
/// The Metal back end the window draws with, for a host that drives `Macos.gpu` itself.
pub const metal = @import("metal");
const objc = metal.objc;
const translate = lcgf.shell_macos_translate;
const iface = lcgf.shell_iface;
const context = lcgf.context;
const Quad = lcgf.draw_list.Quad;
const Mono = lcgf.protocol.Mono;
const Color = lcgf.types.Color;
const Events = iface.Events;
const Platform = context.Platform;
const Output = context.Output;
const Pace = lcgf.scheduler.Pace;
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
    class_addProtocol: *const fn (Id, Id) callconv(.c) bool,
    objc_getProtocol: *const fn ([*:0]const u8) callconv(.c) ?Id,
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
/// NSPasteboardTypeString: plain text on the pasteboard.
var pasteboard_string: Id = undefined;
/// NSPasteboardTypeFileURL, and the reading option that keeps only file URLs.
var pasteboard_file_url: Id = undefined;
var file_urls_only: Id = undefined;
/// NSAppearanceNameAqua and NSAppearanceNameDarkAqua; NSSystemColorsDidChangeNotification.
var appearance_aqua: Id = undefined;
var appearance_dark: Id = undefined;
var system_colors_changed: Id = undefined;
var launched = false;
/// The user chose Quit: every window's `poll` returns false from now on.
var quit = false;

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
    inline for (@typeInfo(Runtime).@"struct".field_names) |name| {
        @field(rt, name) = @ptrCast(@alignCast(std.c.dlsym(lib, name.ptr) orelse return error.MissingFunction));
    }
    if (builtin.cpu.arch == .x86_64) msg_stret = @ptrCast(@alignCast(std.c.dlsym(lib, "objc_msgSend_stret") orelse return error.MissingFunction));
    const mode: *const Id = @ptrCast(@alignCast(std.c.dlsym(fnd, "NSDefaultRunLoopMode") orelse return error.MissingFunction));
    default_mode = mode.*;
    const kit = std.c.dlopen(appkit, .{ .NOW = true }) orelse return error.NoLibrary;
    const pb: *const Id = @ptrCast(@alignCast(std.c.dlsym(kit, "NSPasteboardTypeString") orelse return error.MissingFunction));
    pasteboard_string = pb.*;
    inline for (.{ .{ &pasteboard_file_url, "NSPasteboardTypeFileURL" }, .{ &file_urls_only, "NSPasteboardURLReadingFileURLsOnlyKey" }, .{ &appearance_aqua, "NSAppearanceNameAqua" }, .{ &appearance_dark, "NSAppearanceNameDarkAqua" }, .{ &system_colors_changed, "NSSystemColorsDidChangeNotification" } }) |g| {
        const p: *const Id = @ptrCast(@alignCast(std.c.dlsym(kit, g[1]) orelse return error.MissingFunction));
        g[0].* = p.*;
    }
    try registerView();
    const pool = objc.Pool.push();
    defer pool.pop();
    const a = app();
    msg(void, a, "setActivationPolicy:", .{@as(isize, 0)}); // NSApplicationActivationPolicyRegular
    try registerDelegate(a);
    menuBar(a);
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

/// The method of `LCGFView` for each selector, with its type encoding (`v@:@`: returns void,
/// takes self, _cmd and one object).
const methods = .{
    .{ "acceptsFirstResponder", &acceptsFirstResponder, "c@:" },
    .{ "windowDidResize:", &windowDidResize, "v@:@" },
    .{ "windowShouldClose:", &windowShouldClose, "c@:@" },
    .{ "windowDidResignKey:", &windowDidResignKey, "v@:@" },
    .{ "cursorUpdate:", &cursorUpdate, "v@:@" },
    // NSDraggingDestination: files dragged from Finder.
    .{ "draggingEntered:", &draggingUpdated, "Q@:@" },
    .{ "draggingUpdated:", &draggingUpdated, "Q@:@" },
    .{ "draggingExited:", &draggingExited, "v@:@" },
    .{ "performDragOperation:", &performDragOperation, "c@:@" },
    .{ "viewDidChangeEffectiveAppearance", &appearanceDidChange, "v@:" },
    .{ "systemColorsDidChange:", &systemColorsDidChange, "v@:@" },
    .{ "viewDidChangeBackingProperties", &viewDidChangeBackingProperties, "v@:" },
    .{ "insertText:", &insertText, "v@:@" },
    // NSTextInputClient: the input method's view of the text.
    .{ "insertText:replacementRange:", &insertTextReplacing, "v@:@{_NSRange=QQ}" },
    .{ "setMarkedText:selectedRange:replacementRange:", &setMarkedText, "v@:@{_NSRange=QQ}{_NSRange=QQ}" },
    .{ "unmarkText", &unmarkText, "v@:" },
    .{ "hasMarkedText", &hasMarkedText, "c@:" },
    .{ "markedRange", &markedRange, "{_NSRange=QQ}@:" },
    .{ "selectedRange", &selectedRange, "{_NSRange=QQ}@:" },
    .{ "validAttributesForMarkedText", &validAttributesForMarkedText, "@@:" },
    .{ "attributedSubstringForProposedRange:actualRange:", &attributedSubstring, "@@:{_NSRange=QQ}^{_NSRange=QQ}" },
    .{ "characterIndexForPoint:", &characterIndexForPoint, "Q@:{CGPoint=dd}" },
    .{ "firstRectForCharacterRange:actualRange:", &firstRectForCharacterRange, "{CGRect={CGPoint=dd}{CGSize=dd}}@:{_NSRange=QQ}^{_NSRange=QQ}" },
    .{ "doCommandBySelector:", &doCommandBySelector, "v@::" },
} ++ events: {
    // Every mouse, key and scroll event goes to `onEvent`.
    const names = .{ "mouseDown:", "mouseUp:", "rightMouseDown:", "rightMouseUp:", "otherMouseDown:", "otherMouseUp:", "mouseMoved:", "mouseDragged:", "rightMouseDragged:", "otherMouseDragged:", "mouseEntered:", "mouseExited:", "scrollWheel:", "keyDown:", "keyUp:", "flagsChanged:" };
    var t: [names.len]struct { [:0]const u8, *const anyopaque, [:0]const u8 } = undefined;
    for (names, 0..) |n, i| t[i] = .{ n, &onEvent, "v@:@" };
    break :events t;
};

fn registerView() Error!void {
    const cls = rt.objc_allocateClassPair(objc.class("NSView"), "LCGFView", 0) orelse return error.ClassFailed;
    if (!rt.class_addIvar(cls, "lcgf", @sizeOf(usize), std.math.log2(@alignOf(usize)), "^v")) return error.ClassFailed;
    inline for (methods) |m| {
        if (!rt.class_addMethod(cls, objc.sel(m[0]), @ptrCast(m[1]), m[2])) return error.ClassFailed;
    }
    // Declared so `interpretKeyEvents:` treats the view as a text input client.
    if (rt.objc_getProtocol("NSTextInputClient")) |p| _ = rt.class_addProtocol(cls, p);
    rt.objc_registerClassPair(cls);
    view_class = cls;
    shell_ivar = rt.class_getInstanceVariable(cls, "lcgf") orelse return error.ClassFailed;
}

/// NSApp's delegate: Quit asks it first, and it says no (NSTerminateCancel), so the host's loop
/// ends instead of `exit` being called under it.
fn registerDelegate(a: Id) Error!void {
    const cls = rt.objc_allocateClassPair(objc.class("NSObject"), "LCGFAppDelegate", 0) orelse return error.ClassFailed;
    if (!rt.class_addMethod(cls, objc.sel("applicationShouldTerminate:"), @ptrCast(&applicationShouldTerminate), "Q@:@")) return error.ClassFailed;
    rt.objc_registerClassPair(cls);
    // Kept for the life of the process: NSApp holds its delegate weakly.
    msg(void, a, "setDelegate:", .{msg(Id, cls, "new", .{})});
}

fn applicationShouldTerminate(_: Id, _: Sel, _: Id) callconv(.c) U {
    quit = true;
    return 0;
}

/// The menu bar: the application menu and the Window menu (`translate.app_menu`,
/// `translate.window_menu`).
fn menuBar(a: Id) void {
    const bar = msg(Id, objc.class("NSMenu"), "new", .{});
    const name = msg(Id, msg(Id, objc.class("NSProcessInfo"), "processInfo", .{}), "processName", .{});
    _ = submenu(bar, objc.string(""), &translate.app_menu, name);
    const window = submenu(bar, objc.string("Window"), &translate.window_menu, name);
    msg(void, a, "setMainMenu:", .{bar});
    msg(void, a, "setWindowsMenu:", .{window});
    objc.release(bar);
}

fn submenu(bar: Id, title: Id, comptime items: []const translate.MenuItem, name: Id) Id {
    const menu = msg(Id, msg(Id, objc.class("NSMenu"), "alloc", .{}), "initWithTitle:", .{title});
    inline for (items) |x| {
        if (x.title.len == 0) {
            msg(void, menu, "addItem:", .{msg(Id, objc.class("NSMenuItem"), "separatorItem", .{})});
        } else {
            var t = objc.string(x.title);
            if (x.named) t = msg(Id, msg(Id, t, "stringByAppendingString:", .{objc.string(" ")}), "stringByAppendingString:", .{name});
            const item = msg(Id, menu, "addItemWithTitle:action:keyEquivalent:", .{ t, objc.sel(x.action), objc.string(x.key) });
            if (x.option) msg(void, item, "setKeyEquivalentModifierMask:", .{@as(U, translate.flag_command | translate.flag_option)});
        }
    }
    const holder = msg(Id, objc.class("NSMenuItem"), "new", .{});
    msg(void, holder, "setSubmenu:", .{menu});
    msg(void, bar, "addItem:", .{holder});
    objc.release(holder);
    objc.release(menu);
    return menu;
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
    m.applyCursor(m.applied.cursor, m.t.in.pointer[0] >= 0);
    if (kind != .key_down) return;
    // While a widget wants text the input method sees the key (and may compose); otherwise
    // the key's own characters are typed, and no input method runs.
    if (m.applied.wants_text) {
        msg(void, view, "interpretKeyEvents:", .{msg(Id, objc.class("NSArray"), "arrayWithObject:", .{e})});
    } else if (msg(?Id, e, "characters", .{})) |s| m.t.feed(.{ .insert = utf8(s) });
}

pub const NSRange = extern struct { location: U, length: U };
/// NSNotFound.
const not_found: U = @as(U, std.math.maxInt(isize));

fn insertTextReplacing(view: Id, _: Sel, text: Id, _: NSRange) callconv(.c) void {
    shellOf(view).t.feed(.{ .insert = utf8(text) });
}

fn setMarkedText(view: Id, _: Sel, text: Id, selected: NSRange, _: NSRange) callconv(.c) void {
    const sel: [2]u32 = .{ @intCast(@min(selected.location, std.math.maxInt(u32))), @intCast(@min(selected.length, std.math.maxInt(u32))) };
    shellOf(view).t.feed(.{ .mark = .{ .text = utf8(text), .selected = sel } });
}

/// The input method gives up its composition: what was shown is committed.
fn unmarkText(view: Id, _: Sel) callconv(.c) void {
    const t = &shellOf(view).t;
    t.commit(t.preedit[0..t.composition.len]);
}

fn hasMarkedText(view: Id, _: Sel) callconv(.c) bool {
    return shellOf(view).t.marked();
}

fn markedRange(view: Id, _: Sel) callconv(.c) NSRange {
    const t = &shellOf(view).t;
    return if (t.marked()) .{ .location = 0, .length = t.composition.units } else .{ .location = not_found, .length = 0 };
}

/// The UI keeps its text to itself, so the input method sees an empty document with the caret
/// at the end of the composition.
fn selectedRange(view: Id, _: Sel) callconv(.c) NSRange {
    return .{ .location = shellOf(view).t.composition.units, .length = 0 };
}

fn validAttributesForMarkedText(_: Id, _: Sel) callconv(.c) Id {
    return msg(Id, objc.class("NSArray"), "array", .{});
}

fn attributedSubstring(_: Id, _: Sel, _: NSRange, _: ?*NSRange) callconv(.c) ?Id {
    return null;
}

fn characterIndexForPoint(_: Id, _: Sel, _: NSPoint) callconv(.c) U {
    return not_found;
}

/// Where the candidate window goes: the frame's `ime_rect`, on the screen.
fn firstRectForCharacterRange(view: Id, _: Sel, range: NSRange, actual: ?*NSRange) callconv(.c) NSRect {
    const m = shellOf(view);
    if (actual) |a| a.* = range;
    const r = translate.windowRect(m.applied.ime_rect, m.t.in.viewport[1]);
    const in_window: NSRect = .{ .origin = .{ .x = r[0], .y = r[1] }, .size = .{ .width = r[2], .height = r[3] } };
    return msgRect(m.window, "convertRectToScreen:", .{in_window});
}

/// Text a key typed. `text` is an NSString, or an NSAttributedString from an input method.
fn insertText(view: Id, _: Sel, text: Id) callconv(.c) void {
    shellOf(view).t.feed(.{ .insert = utf8(text) });
}

/// Keys that edit rather than type (arrows, Return, Delete) arrive here from
/// `interpretKeyEvents:`; their key events already reached the UI, so nothing is done (and
/// NSResponder's beep is not sounded).
fn doCommandBySelector(_: Id, _: Sel, _: Sel) callconv(.c) void {}

/// The pointer entered the view (its tracking area asks for this): AppKit would show the arrow;
/// the frame's cursor is shown instead.
fn cursorUpdate(view: Id, _: Sel, _: Id) callconv(.c) void {
    const m = shellOf(view);
    m.applyCursor(m.applied.cursor, true);
}

/// Light or dark changed: the view's effective appearance follows the system's.
fn appearanceDidChange(view: Id, _: Sel) callconv(.c) void {
    shellOf(view).settingsChanged();
}

/// NSSystemColorsDidChangeNotification: the accent colour changed.
fn systemColorsDidChange(view: Id, _: Sel, _: Id) callconv(.c) void {
    shellOf(view).settingsChanged();
}

/// The appearance AppKit shows now.
fn readAppearance() translate.Appearance {
    const pool = objc.Pool.push();
    defer pool.pop();
    const look = msg(Id, app(), "effectiveAppearance", .{});
    const names = msg(Id, msg(Id, objc.class("NSArray"), "arrayWithObject:", .{appearance_aqua}), "arrayByAddingObject:", .{appearance_dark});
    const best = msg(?Id, look, "bestMatchFromAppearancesWithNames:", .{names});
    const dark = if (best) |b| msg(bool, b, "isEqualToString:", .{appearance_dark}) else false;
    const color_class = objc.class("NSColor");
    if (!msg(bool, color_class, "respondsToSelector:", .{objc.sel("controlAccentColor")})) return .fromSystem(dark, null);
    const srgb = msg(Id, objc.class("NSColorSpace"), "sRGBColorSpace", .{});
    const c = msg(?Id, msg(Id, color_class, "controlAccentColor", .{}), "colorUsingColorSpace:", .{srgb}) orelse return .fromSystem(dark, null);
    return .fromSystem(dark, .{ msg(f64, c, "redComponent", .{}), msg(f64, c, "greenComponent", .{}), msg(f64, c, "blueComponent", .{}) });
}

/// NSDragOperationCopy: the pointer shows a plus.
const drag_copy: U = 1;

fn draggingUpdated(view: Id, _: Sel, info: Id) callconv(.c) U {
    const p = msg(NSPoint, info, "draggingLocation", .{});
    shellOf(view).t.feed(.{ .drag = .{ p.x, p.y } });
    return drag_copy;
}

fn draggingExited(view: Id, _: Sel, _: Id) callconv(.c) void {
    shellOf(view).t.feed(.drag_exit);
}

/// The drop: each file URL on the dragging pasteboard as a path, then the drop point.
fn performDragOperation(view: Id, _: Sel, info: Id) callconv(.c) bool {
    const m = shellOf(view);
    const pb = msg(Id, info, "draggingPasteboard", .{});
    const classes = msg(Id, objc.class("NSArray"), "arrayWithObject:", .{objc.class("NSURL")});
    const yes = msg(Id, objc.class("NSNumber"), "numberWithBool:", .{true});
    const options = msg(Id, objc.class("NSDictionary"), "dictionaryWithObject:forKey:", .{ yes, file_urls_only });
    if (msg(?Id, pb, "readObjectsForClasses:options:", .{ classes, options })) |urls| {
        for (0..msg(U, urls, "count", .{})) |i| {
            const url = msg(Id, urls, "objectAtIndex:", .{@as(U, i)});
            const path = msg(?[*:0]const u8, url, "fileSystemRepresentation", .{}) orelse continue;
            m.t.feed(.{ .file = std.mem.span(path) });
        }
    }
    const p = msg(NSPoint, info, "draggingLocation", .{});
    m.t.feed(.{ .drop = .{ p.x, p.y } });
    return true;
}

/// The window moved to a display of another scale, or that display's scale changed. The next
/// `present` resizes the layer's drawables (device.zig `Layer.resize`).
fn viewDidChangeBackingProperties(view: Id, _: Sel) callconv(.c) void {
    const m = shellOf(view);
    m.t.feed(.{ .scale = msg(f64, m.window, "backingScaleFactor", .{}) });
}

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
const ns_utf8_string_encoding = 4;
/// NSTrackingArea options: entered and exited, moves, cursor updates, always (not only in the key window), and
/// the rectangle follows the view's visible rectangle.
const ns_tracking = 0x01 | 0x02 | 0x04 | 0x80 | 0x200;

// ---- The shell ------------------------------------------------------------------------------

pub const Macos = struct {
    window: Id,
    view: Id,
    t: translate.Translator = .{},
    /// The view's Metal: device, layer, renderer, frames and the picture the window keeps. A
    /// host with its own GPU work drives it with `begin` and `present`; `present` below is
    /// the one call for a host without.
    gpu: metal.setup.Window,
    font: Mono = .{},
    glyphs: GlyphBuffers,
    /// What `present` clears to before drawing.
    background: Color = .rgb(0, 0, 0),
    /// The effects of the last frame, as `apply` received them.
    applied: Platform = .{},
    /// The system cursors, by `Platform.cursor` (`translate.cursor_names`); shared objects
    /// AppKit owns.
    cursors: [translate.cursor_names.len]Id = undefined,
    cursor_hidden: bool = false,
    effect_view: ?Id = null,
    /// The system's light or dark mode and accent, read at `init` and again when AppKit says
    /// they changed. `appearanceChanged` hands a change to the host once.
    appearance: translate.Appearance = .{},
    appearance_changed: bool = false,
    /// CACurrentMediaTime at `init`: `Input.time` is counted from there.
    start: f64 = 0,

    pub const Options = struct {
        title: [:0]const u8 = "LCGF",
        /// Content size in points (logical pixels).
        size: [2]u32 = .{ 800, 600 },
        /// False for a window that stays hidden (tests).
        show: bool = true,
        /// Canvas rows the window's renderer keeps on the GPU (`metal.setup.Window.Canvas`);
        /// none: canvases draw nothing.
        canvas: metal.setup.Window.Canvas = .{},
    };

    /// Caller-owned storage: `text` and `events` hold two frames' typed text and key events,
    /// `preedit` twice the longest input-method composition, `names` and `ends` twice the
    /// paths of one drop (`translate.Translator.Buffers`: what arrives, and the frame handed
    /// out), `glyphs` one quad per byte of text in a frame (at most the
    /// renderer's 32768), `first` and `count` one row per text run.
    pub const Buffers = struct {
        text: []u8,
        events: []lcgf.input.Input.Event,
        preedit: []u8,
        names: []u8,
        ends: []u32,
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
        const size: [2]f32 = .{ @floatFromInt(opt.size[0]), @floatFromInt(opt.size[1]) };
        var gpu: metal.setup.Window = try .init(size, 1, opt.canvas);
        errdefer gpu.deinit();
        const rect: NSRect = .{ .size = .{ .width = size[0], .height = size[1] } };
        const window = msg(?Id, msg(Id, objc.class("NSWindow"), "alloc", .{}), "initWithContentRect:styleMask:backing:defer:", .{ rect, @as(U, ns_window_style), @as(U, ns_backing_store_buffered), false }) orelse return error.CreateWindow;
        const view = msg(Id, msg(Id, view_class, "alloc", .{}), "initWithFrame:", .{rect});
        m.* = .{
            .window = window,
            .view = view,
            .gpu = gpu,
            .t = .init(.{ .text = buf.text, .events = buf.events, .preedit = buf.preedit, .names = buf.names, .ends = buf.ends }),
            .glyphs = .{ .quads = buf.glyphs, .first = buf.first, .count = buf.count },
            // Attaching the view can synchronously deliver viewDidChangeEffectiveAppearance.
            .appearance = readAppearance(),
        };
        rt.object_setIvar(view, shell_ivar, m);
        inline for (translate.cursor_names, &m.cursors) |name, *c| {
            const cls = objc.class("NSCursor");
            c.* = if (msg(bool, cls, "respondsToSelector:", .{objc.sel(name)})) msg(Id, cls, name, .{}) else msg(Id, cls, "arrowCursor", .{});
        }
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
        msg(void, view, "registerForDraggedTypes:", .{msg(Id, objc.class("NSArray"), "arrayWithObject:", .{pasteboard_file_url})});
        m.gpu.layer.attach(view);
        // The window has a display now; its scale may not be 1.
        m.t.setScale(msg(f64, window, "backingScaleFactor", .{}));
        m.start = metal.present.mediaTime();
        const center = msg(Id, objc.class("NSNotificationCenter"), "defaultCenter", .{});
        msg(void, center, "addObserver:selector:name:object:", .{ view, objc.sel("systemColorsDidChange:"), system_colors_changed, @as(?Id, null) });
        if (opt.show) {
            msg(void, window, "center", .{});
            msg(void, window, "makeKeyAndOrderFront:", .{@as(?Id, null)});
            msg(void, app(), "activateIgnoringOtherApps:", .{true});
        }
    }

    pub fn deinit(m: *Macos) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        m.applyCursor(.arrow, false);
        msg(void, msg(Id, objc.class("NSNotificationCenter"), "defaultCenter", .{}), "removeObserver:", .{m.view});
        msg(void, m.window, "setDelegate:", .{@as(?Id, null)});
        msg(void, m.window, "close", .{});
        objc.release(m.window);
        if (m.effect_view) |effect| objc.release(effect);
        objc.release(m.view);
        m.gpu.deinit();
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
        m.t.clock(metal.present.mediaTime() - m.start);
        // What arrived between polls (a `paste`, another window's poll dispatching ours) is
        // in this frame.
        return m.t.frame(ev) and !quit;
    }

    /// The refresh rate of the window's display (`maximumFramesPerSecond`, macOS 12); 60 when
    /// AppKit does not say.
    fn hz(m: *const Macos) f64 {
        const screen = msg(?Id, m.window, "screen", .{}) orelse return 60;
        if (!msg(bool, screen, "respondsToSelector:", .{objc.sel("maximumFramesPerSecond")})) return 60;
        const f = msg(isize, screen, "maximumFramesPerSecond", .{});
        return if (f > 0) @floatFromInt(f) else 60;
    }

    pub fn apply(m: *Macos, p: *const Platform) void {
        // The text field lost focus mid-composition: the input method drops it.
        if (m.applied.wants_text and !p.wants_text and m.t.marked()) {
            if (msg(?Id, m.view, "inputContext", .{})) |ic| msg(void, ic, "discardMarkedText", .{});
            m.t.mark("", .{ 0, 0 });
        }
        // The candidate window follows the caret.
        if (p.wants_text and !std.meta.eql(p.ime_rect, m.applied.ime_rect)) {
            if (msg(?Id, m.view, "inputContext", .{})) |ic| msg(void, ic, "invalidateCharacterCoordinates", .{});
        }
        // Shown now if the pointer is over the view; `cursorUpdate:` shows it on the way in.
        m.applyCursor(p.cursor, m.t.in.pointer[0] >= 0);
        if (p.clipboard.len > 0) copy(p.clipboard);
        m.applied = p.*;
    }

    /// Places a real NSVisualEffectView behind the Metal content view. Clear `background`
    /// transparently (and leave the relevant UI background unpainted) to reveal it. The
    /// material changes no text colors and does not automatically enable AppKit vibrancy
    /// for shader-drawn text. Passing null removes it; the caller retains its clear color.
    pub fn setMaterial(m: *Macos, options: ?lcgf.shell_materials.AppKit) error{ InvalidMaterial, UnsupportedMaterial }!void {
        const pool = objc.Pool.push();
        defer pool.pop();
        if (options) |config| {
            if (config.material == .titlebar and config.blending != .within_window) return error.InvalidMaterial;
            if (m.effect_view == null) {
                const rect = msgRect(m.view, "frame", .{});
                const effect = msg(?Id, msg(Id, objc.class("NSVisualEffectView"), "alloc", .{}), "initWithFrame:", .{rect}) orelse return error.UnsupportedMaterial;
                m.effect_view = effect;
                msg(void, m.view, "setAutoresizingMask:", .{@as(U, 2 | 16)});
                msg(void, m.window, "setContentView:", .{effect});
                msg(void, effect, "addSubview:", .{m.view});
            }
            const effect = m.effect_view.?;
            msg(void, effect, "setMaterial:", .{@backingInt(config.material)});
            msg(void, effect, "setBlendingMode:", .{@backingInt(config.blending)});
            msg(void, effect, "setState:", .{@backingInt(config.state)});
            msg(void, effect, "setEmphasized:", .{config.emphasized});
            msg(void, m.window, "setOpaque:", .{false});
            msg(void, m.window, "setBackgroundColor:", .{msg(Id, objc.class("NSColor"), "clearColor", .{})});
            msg(void, m.gpu.layer.layer, "setOpaque:", .{false});
        } else if (m.effect_view) |effect| {
            msg(void, m.view, "removeFromSuperview", .{});
            msg(void, m.window, "setContentView:", .{m.view});
            m.effect_view = null;
            objc.release(effect);
            msg(void, m.window, "setOpaque:", .{true});
            msg(void, m.window, "setBackgroundColor:", .{msg(Id, objc.class("NSColor"), "windowBackgroundColor", .{})});
            msg(void, m.gpu.layer.layer, "setOpaque:", .{true});
        }
        _ = msg(bool, m.window, "makeFirstResponder:", .{m.view});
    }

    fn applyCursor(m: *Macos, cursor: context.Cursor, inside: bool) void {
        const hide = inside and cursor == .hidden;
        if (hide != m.cursor_hidden) {
            if (hide) msg(void, objc.class("NSCursor"), "hide", .{}) else msg(void, objc.class("NSCursor"), "unhide", .{});
            m.cursor_hidden = hide;
        }
        if (inside and !hide) msg(void, m.cursors[@backingInt(cursor)], "set", .{});
    }

    /// Puts UTF-8 text on the general pasteboard. Called by `apply` for `Platform.clipboard`.
    /// Invalid UTF-8 leaves the pasteboard as it was.
    pub fn copy(utf8_text: []const u8) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const s = msg(?Id, msg(Id, objc.class("NSString"), "alloc", .{}), "initWithBytes:length:encoding:", .{ utf8_text.ptr, @as(U, utf8_text.len), @as(U, ns_utf8_string_encoding) }) orelse return;
        defer objc.release(s);
        const pb = msg(Id, objc.class("NSPasteboard"), "generalPasteboard", .{});
        _ = msg(isize, pb, "clearContents", .{});
        _ = msg(bool, pb, "setString:forType:", .{ s, pasteboard_string });
    }

    /// Types the pasteboard's text into the next frame, as `keyboard.Clipboard.paste` asks the
    /// host to: call it after a frame whose widgets requested a paste.
    pub fn paste(m: *Macos) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const pb = msg(Id, objc.class("NSPasteboard"), "generalPasteboard", .{});
        const s = msg(?Id, pb, "stringForType:", .{pasteboard_string}) orelse return;
        m.t.paste(utf8(s));
    }

    /// The new appearance once after the system's changed, else null. The host restyles and
    /// asks for a frame, since nothing in `Input` changed:
    ///
    ///     if (shell.appearanceChanged()) |a| {
    ///         app.theme = lcgf.theme.widgets(&a.tokens());
    ///         ctx.waker.post();
    ///     }
    pub fn appearanceChanged(m: *Macos) ?translate.Appearance {
        if (!m.appearance_changed) return null;
        m.appearance_changed = false;
        return m.appearance;
    }

    /// Rereads the appearance; a change is kept for `appearanceChanged`.
    fn settingsChanged(m: *Macos) void {
        const a = readAppearance();
        if (std.meta.eql(a, m.appearance)) return;
        m.appearance = a;
        m.appearance_changed = true;
        // Wake a `wait` in progress so the host sees the change now.
        m.wake();
    }

    /// Draws the frame with Metal into the window's picture, inside `out.draw.damage`, and
    /// presents it. A window that is not shown (`shown`, or no drawable came) gives the frame
    /// up, and the next frame presented draws all of the picture.
    pub fn present(m: *Macos, out: *const Output) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        if (!m.shown()) {
            m.gpu.lost = true;
            return;
        }
        const g = m.glyphs;
        const n = m.font.quads(out.draw, g.quads, .{ .first = g.first, .count = g.count });
        const glyphs: metal.renderer.Glyphs = .{ .quads = g.quads[0..n], .first = g.first, .count = g.count };
        const c = m.background;
        const clear: [4]f32 = .{ unit(c.r), unit(c.g), unit(c.b), unit(c.a) };
        m.gpu.draw(out.draw, glyphs, m.t.in.viewport, m.t.in.scale, clear) catch {
            m.gpu.lost = true;
        };
    }

    /// Whether AppKit shows any of the window (`occlusionState`): not when it is hidden,
    /// minimised, on another Space or covered whole. A frame for a window not shown is given
    /// up before the layer is asked for a drawable, which would wait a second for none.
    pub fn shown(m: *const Macos) bool {
        const visible: U = 1 << 1; // NSWindowOcclusionStateVisible
        return msg(U, m.window, "occlusionState", .{}) & visible != 0;
    }

    /// Blocks until the next event or `seconds` pass (`inf`: until the next event); while
    /// animating (`.display`), one refresh (`translate.waitSeconds`). The event stays queued
    /// for the next `poll`.
    ///
    /// ponytail: while the user drags or resizes the window, AppKit runs its own tracking loop
    /// inside `sendEvent:`, so `poll` returns when they let go and the window shows the last
    /// frame meanwhile. Live resizing needs frames built from inside that loop (GPUI draws
    /// from the display link there), which breaks "the host owns the loop"; add it if asked.
    pub fn wait(m: *Macos, seconds: f32, pace: Pace) void {
        const s = translate.waitSeconds(seconds, pace, m.hz());
        if (s != null and !(s.? > 0)) return;
        const pool = objc.Pool.push();
        defer pool.pop();
        const date = if (s) |secs|
            msg(Id, objc.class("NSDate"), "dateWithTimeIntervalSinceNow:", .{secs})
        else
            msg(Id, objc.class("NSDate"), "distantFuture", .{});
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

fn unit(v: u8) f32 {
    return @as(f32, @floatFromInt(v)) / 255;
}

// ---- Tests: on macOS only (`zig build macos`) -----------------------------------------------

const testing = std.testing;
const example_limits: context.Limits = .{ .nodes = 1024, .texts = 256 };

const Fixture = struct {
    // A second window's own text, events and composition; glyphs are shared.
    var text2: [64]u8 = undefined;
    var events2: [16]lcgf.input.Input.Event = undefined;
    var preedit2: [64]u8 = undefined;
    var ctx_buffer: [context.Context.requiredBytes(example_limits)]u8 align(lcgf.mem.column_align) = undefined;
    var text: [64]u8 = undefined;
    var events: [16]lcgf.input.Input.Event = undefined;
    var preedit: [64]u8 = undefined;
    var names: [512]u8 = undefined;
    var ends: [16]u32 = undefined;
    var names2: [512]u8 = undefined;
    var ends2: [16]u32 = undefined;
    var glyphs: [512]Quad = undefined;
    var first: [256]u32 = undefined;
    var count: [256]u32 = undefined;

    fn open(m: *Macos) !void {
        try openWith(m, .{ .show = false });
    }

    fn openWith(m: *Macos, options: Macos.Options) !void {
        try m.init(options, .{ .text = &text, .events = &events, .preedit = &preedit, .names = &names, .ends = &ends, .glyphs = &glyphs, .first = &first, .count = &count });
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

test "macos: the backing scale is the window's, and follows a change" {
    var m: Macos = undefined;
    try Fixture.open(&m);
    defer m.deinit();
    var ev: Events = .{};
    _ = m.poll(&ev);
    try testing.expectEqual(@as(f32, @floatCast(msg(f64, m.window, "backingScaleFactor", .{}))), ev.in.scale);
    // AppKit sends this when the window changes display; the view rereads the scale.
    msg(void, m.view, "viewDidChangeBackingProperties", .{});
    _ = m.poll(&ev);
    try testing.expectEqual(@as(f32, @floatCast(msg(f64, m.window, "backingScaleFactor", .{}))), ev.in.scale);
}

test "macos: copy then paste round-trips through the general pasteboard" {
    var m: Macos = undefined;
    try Fixture.open(&m);
    defer m.deinit();
    var ev: Events = .{};
    _ = m.poll(&ev);
    m.apply(&.{ .clipboard = "two\nlines \u{e9}" });
    m.paste();
    try testing.expect(m.poll(&ev));
    try testing.expectEqualStrings("two\nlines \u{e9}", ev.in.text);
}

test "macos: the appearance is AppKit's and follows a change" {
    var m: Macos = undefined;
    try Fixture.open(&m);
    defer m.deinit();
    // Whatever this machine is set to, it is what AppKit says, and no change is pending.
    try testing.expectEqual(readAppearance(), m.appearance);
    try testing.expectEqual(null, m.appearanceChanged());
    // A notification that changed nothing hands nothing to the host.
    msg(void, m.view, "viewDidChangeEffectiveAppearance", .{});
    try testing.expectEqual(null, m.appearanceChanged());
    // A changed one is handed over once.
    m.appearance.dark = !m.appearance.dark;
    msg(void, msg(Id, objc.class("NSNotificationCenter"), "defaultCenter", .{}), "postNotificationName:object:", .{ system_colors_changed, @as(?Id, null) });
    try testing.expectEqual(readAppearance(), m.appearanceChanged().?);
    try testing.expectEqual(null, m.appearanceChanged());
}

test "macos: the view accepts file drags from Finder" {
    var m: Macos = undefined;
    try Fixture.open(&m);
    defer m.deinit();
    const types = msg(Id, m.view, "registeredDraggedTypes", .{});
    try testing.expect(msg(bool, types, "containsObject:", .{pasteboard_file_url}));
}

test "macos: the view is a text input client that composes and commits" {
    var m: Macos = undefined;
    try Fixture.open(&m);
    defer m.deinit();
    var ev: Events = .{};
    _ = m.poll(&ev);
    try testing.expect(msg(bool, m.view, "conformsToProtocol:", .{rt.objc_getProtocol("NSTextInputClient").?}));
    m.apply(&.{ .wants_text = true, .ime_rect = .{ .x0 = 10, .y0 = 20, .x1 = 40, .y1 = 60 } });
    // What an input method calls, in order: compose, then commit.
    msg(void, m.view, "setMarkedText:selectedRange:replacementRange:", .{ objc.string("\u{306b}"), NSRange{ .location = 1, .length = 0 }, NSRange{ .location = not_found, .length = 0 } });
    try testing.expect(msg(bool, m.view, "hasMarkedText", .{}));
    try testing.expectEqual(NSRange{ .location = 0, .length = 1 }, msg(NSRange, m.view, "markedRange", .{}));
    _ = m.poll(&ev);
    try testing.expectEqualStrings("\u{306b}", ev.composition.text);
    msg(void, m.view, "insertText:replacementRange:", .{ objc.string("\u{65e5}"), NSRange{ .location = not_found, .length = 0 } });
    _ = m.poll(&ev);
    try testing.expectEqualStrings("\u{65e5}", ev.in.text);
    try testing.expectEqualStrings("", ev.composition.text);
    // The candidate window's rectangle is the ime_rect on the screen: same size.
    var actual: NSRange = undefined;
    const r = msgRect(m.view, "firstRectForCharacterRange:actualRange:", .{ NSRange{ .location = 0, .length = 0 }, &actual });
    try testing.expectEqual(NSSize{ .width = 30, .height = 40 }, r.size);
}

test "macos: two windows on one thread get their own events" {
    var a: Macos = undefined;
    try Fixture.open(&a);
    defer a.deinit();
    var b: Macos = undefined;
    try b.init(.{ .show = false }, .{ .text = &Fixture.text2, .events = &Fixture.events2, .preedit = &Fixture.preedit2, .names = &Fixture.names2, .ends = &Fixture.ends2, .glyphs = &Fixture.glyphs, .first = &Fixture.first, .count = &Fixture.count });
    defer b.deinit();
    const pool = objc.Pool.push();
    defer pool.pop();
    msg(void, a.view, "insertText:", .{objc.string("a")});
    msg(void, b.view, "insertText:", .{objc.string("b")});
    var ev_a: Events = .{};
    var ev_b: Events = .{};
    try testing.expect(a.poll(&ev_a));
    msg(void, a.view, "insertText:", .{objc.string("x")});
    msg(void, b.window, "performClose:", .{@as(?Id, null)});
    try testing.expect(!b.poll(&ev_b)); // B closed; A is still open
    try testing.expectEqualStrings("a", ev_a.in.text);
    try testing.expectEqualStrings("b", ev_b.in.text);
    try testing.expect(a.poll(&ev_a));
    try testing.expectEqualStrings("x", ev_a.in.text);
}

test "macos: the menu bar is built, and Quit ends every poll without exiting" {
    var a: Macos = undefined;
    try Fixture.open(&a);
    defer a.deinit();
    const bar = msg(Id, app(), "mainMenu", .{});
    try testing.expectEqual(@as(isize, 2), msg(isize, bar, "numberOfItems", .{}));
    var ev: Events = .{};
    try testing.expect(a.poll(&ev));
    msg(void, app(), "terminate:", .{@as(?Id, null)});
    defer quit = false; // the other tests go on
    try testing.expect(!a.poll(&ev));
}

fn job(m: *Macos) void {
    // Long enough that the test thread is asleep in `wait` first.
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
    _ = std.c.nanosleep(&ts, null);
    m.wake();
}

test "macos: a worker thread ends a wait, and the clock runs" {
    var m: Macos = undefined;
    try Fixture.open(&m);
    defer m.deinit();
    var ev: Events = .{};
    _ = m.poll(&ev);
    const t0 = ev.in.time;
    const worker = try std.Thread.spawn(.{}, job, .{&m});
    const c0 = metal.present.mediaTime();
    m.wait(std.math.inf(f32), .idle);
    const c1 = metal.present.mediaTime();
    worker.join();
    // Woken, not timed out (there is no timeout): well under 5 s.
    try testing.expect(c1 - c0 < 5);
    try testing.expect(m.poll(&ev));
    try testing.expect(ev.in.time > t0);
    try testing.expect(ev.in.dt > 0);
    // A queued AppKit event may legitimately end a timer wait early. Verify it
    // was left for poll, drain it, then require one uninterrupted timed wait.
    const pool = objc.Pool.push();
    defer pool.pop();
    const past = msg(Id, objc.class("NSDate"), "distantPast", .{});
    for (0..64) |_| {
        const start = metal.present.mediaTime();
        m.wait(0.02, .timer);
        if (metal.present.mediaTime() - start >= 0.015) break;
        const pending = msg(?Id, app(), "nextEventMatchingMask:untilDate:inMode:dequeue:", .{ ns_event_mask_any, past, default_mode, false });
        try testing.expect(pending != null);
        try testing.expect(m.poll(&ev));
    } else return error.TimerDidNotExpire;
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
    const open = m.poll(ev);
    for (records) |rec| switch (rec) {
        .event => |e| if (e.kind == .moved) {
            try testing.expectEqual([2]f32{ @floatCast(e.at[0]), ev.in.viewport[1] - @as(f32, @floatCast(e.at[1])) }, ev.in.pointer);
        },
        else => {},
    };
    return open;
}

test "macos: a real window runs the example from posted events" {
    var m: Macos = undefined;
    // AppKit routes mouseMoved: to the key window's responder. Hidden windows
    // accept synthetic button events but miss the hover frames in the recording.
    try Fixture.openWith(&m, .{});
    defer m.deinit();
    var ctx = try context.Context.init(&Fixture.ctx_buffer, example_limits);
    var app_: lcgf.shell_example.App = .{};
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
    // The arrow is back after leaving the slider, and it is AppKit's.
    try testing.expectEqual(context.Cursor.arrow, m.applied.cursor);
    try testing.expectEqual(msg(Id, objc.class("NSCursor"), "arrowCursor", .{}), m.cursors[0]);
}

test "macos: a window that is not shown gives its frame up and owes all of it" {
    var m: Macos = undefined;
    try Fixture.open(&m); // never ordered in
    defer m.deinit();
    var ev: Events = .{};
    _ = m.poll(&ev);
    try testing.expect(!m.shown());
    var ctx = try context.Context.init(&Fixture.ctx_buffer, example_limits);
    var f = ctx.begin(&ev.in);
    _ = f.leaf(.none, .{ .size = .{ .fill, .fill }, .fill = .rgb(0, 0, 255) });
    const out = f.end(.{});
    m.present(&out);
    try testing.expect(m.gpu.lost);
    try testing.expectEqual(null, m.gpu.gfx.list);
}

test "macos: a real material wraps the Metal view and can be removed" {
    var m: Macos = undefined;
    try Fixture.open(&m);
    defer m.deinit();
    m.background = .transparent;
    try m.setMaterial(.{ .material = .sidebar, .state = .active });
    const effect = m.effect_view.?;
    try testing.expectEqual(@as(isize, 7), msg(isize, effect, "material", .{}));
    try testing.expectEqual(@as(isize, 1), msg(isize, effect, "state", .{}));
    try testing.expectEqual(effect, msg(Id, m.view, "superview", .{}));
    try testing.expect(!msg(bool, m.gpu.layer.layer, "isOpaque", .{}));
    try testing.expectError(error.InvalidMaterial, m.setMaterial(.{ .material = .titlebar }));
    try m.setMaterial(null);
    try testing.expectEqual(@as(?Id, null), m.effect_view);
    try testing.expectEqual(m.view, msg(Id, m.window, "contentView", .{}));
}
