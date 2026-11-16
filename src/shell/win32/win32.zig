//! The Win32 shell: one top-level window, its messages as `Events`, its frames drawn with the
//! software back end and copied to the window with GDI. It meets the shell contract of
//! src/shell/iface.zig and never owns the loop: `poll` drains the thread's message queue
//! without blocking and returns, `wait` is the only call that sleeps.
//!
//! Outside the tiers (it calls user32, gdi32 and kernel32), so it is a module of its own over
//! `lcgr` (`zig build win32`, `zig build win32-build`), never imported by the core. The OS
//! declarations are written by hand (docs/DEPENDENCIES.md: small APIs need no header
//! translation), with the types of the Win32 API documentation. Everything that does not call
//! the OS, the reading of each message, is translate.zig, tested on every host.
//!
//! The window procedure is the one callback Win32 imposes: it finds its `Win32` through
//! GWLP_USERDATA and hands the message to the translator, so `init` builds the shell in place
//! and it must not move afterwards.

const std = @import("std");
const builtin = @import("builtin");
const lcgr = @import("lcgr");
const translate = lcgr.shell_win32_translate;
const iface = lcgr.shell_iface;
const sw = lcgr.render_sw;
const render = lcgr.render_iface;
const context = lcgr.context;
const Quad = lcgr.draw_list.Quad;
const Mono = lcgr.protocol.Mono;
const Color = lcgr.types.Color;
const Events = iface.Events;
const Platform = context.Platform;
const Output = context.Output;
const Pace = lcgr.scheduler.Pace;

comptime {
    if (builtin.os.tag != .windows) @compileError("src/shell/win32 is the Windows shell; build it with -Dtarget=x86_64-windows");
}

// ---- Win32 declarations (winuser.h, wingdi.h, libloaderapi.h) -------------------------------

const HWND = *opaque {};
const HINSTANCE = *opaque {};
const HDC = *opaque {};
const HANDLE = *anyopaque;
const BOOL = c_int;
const WndProc = *const fn (HWND, u32, usize, isize) callconv(.winapi) isize;

const POINT = extern struct { x: i32, y: i32 };
const RECT = extern struct { left: i32 = 0, top: i32 = 0, right: i32 = 0, bottom: i32 = 0 };
const MSG = extern struct { hwnd: ?HWND, message: u32, wparam: usize, lparam: isize, time: u32, pt: POINT, private: u32 };
const WNDCLASSEXW = extern struct {
    size: u32 = @sizeOf(WNDCLASSEXW),
    style: u32 = 0,
    wndproc: WndProc,
    cls_extra: c_int = 0,
    wnd_extra: c_int = 0,
    instance: ?HINSTANCE,
    icon: ?HANDLE = null,
    cursor: ?HANDLE = null,
    background: ?HANDLE = null,
    menu_name: ?[*:0]const u16 = null,
    class_name: [*:0]const u16,
    icon_small: ?HANDLE = null,
};
const BITMAPINFOHEADER = extern struct {
    size: u32 = @sizeOf(BITMAPINFOHEADER),
    width: i32,
    /// Negative: rows run top to bottom, as the framebuffer's do.
    height: i32,
    planes: u16 = 1,
    bit_count: u16 = 32,
    compression: u32 = 0, // BI_RGB
    size_image: u32 = 0,
    x_ppm: i32 = 0,
    y_ppm: i32 = 0,
    clr_used: u32 = 0,
    clr_important: u32 = 0,
};
const TRACKMOUSEEVENT = extern struct { size: u32 = @sizeOf(TRACKMOUSEEVENT), flags: u32, hwnd: HWND, hover_time: u32 = 0 };
const COMPOSITIONFORM = extern struct { style: u32, pos: POINT, area: RECT = .{} };
const CANDIDATEFORM = extern struct { index: u32 = 0, style: u32, pos: POINT, area: RECT };
const HIMC = *opaque {};
const PAINTSTRUCT = extern struct { hdc: ?HDC, erase: BOOL, paint: RECT, restore: BOOL, inc_update: BOOL, reserved: [32]u8 };

const ws_overlappedwindow: u32 = 0x00cf_0000;
const cw_usedefault: i32 = @bitCast(@as(u32, 0x8000_0000));
const sw_show = 5;
const pm_remove = 1;
const gwlp_userdata = -21;
const wm_paint = 0x000f;
const wm_erasebkgnd = 0x0014;
const wm_nccreate = 0x0081;
/// Posted by `wake`: it only ends a `wait`.
const wm_wake = 0x8000; // WM_APP
const qs_allinput = 0x04ff;
const mwmo_inputavailable = 0x0004;
const infinite: u32 = 0xffff_ffff;
const dib_rgb_colors = 0;
const tme_leave = 0x0002;
const cf_unicodetext = 13;
const wm_ime_setcontext = 0x0281;
const wm_ime_startcomposition = 0x010d;
const wm_ime_endcomposition = 0x010e;
const wm_ime_composition = 0x010f;
const gcs_compstr = 0x0008;
const gcs_compattr = 0x0010;
const gcs_cursorpos = 0x0080;
const gcs_resultstr = 0x0800;
/// WM_IME_SETCONTEXT's flag for the IME's own composition window, which the UI replaces.
const isc_showuicompositionwindow: usize = 0x8000_0000;
const iace_default = 0x0010;
const cfs_point = 0x0002;
const cfs_exclude = 0x0080;
const gmem_moveable = 0x0002;
const wm_setcursor = 0x0020;
/// WM_SETCURSOR's hit-test code for the client area; the frame's codes keep the system's
/// resize arrows.
const ht_client = 1;
/// DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 (Windows 10 1703): the system scales nothing,
/// sends WM_DPICHANGED, and the client area is in physical pixels.
const dpi_per_monitor_v2: isize = -4;
const swp_nozorder = 0x0004;
const swp_noactivate = 0x0010;
const swp_nomove = 0x0002;

extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) ?HINSTANCE;
extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) u16;
extern "user32" fn UnregisterClassW(name: [*:0]const u16, instance: ?HINSTANCE) callconv(.winapi) BOOL;
extern "user32" fn CreateWindowExW(ex_style: u32, class: [*:0]const u16, title: [*:0]const u16, style: u32, x: i32, y: i32, w: i32, h: i32, parent: ?HWND, menu: ?HANDLE, instance: ?HINSTANCE, param: ?*anyopaque) callconv(.winapi) ?HWND;
extern "user32" fn DestroyWindow(HWND) callconv(.winapi) BOOL;
extern "user32" fn ShowWindow(HWND, cmd: c_int) callconv(.winapi) BOOL;
extern "user32" fn DefWindowProcW(HWND, u32, usize, isize) callconv(.winapi) isize;
extern "user32" fn PeekMessageW(*MSG, ?HWND, min: u32, max: u32, remove: u32) callconv(.winapi) BOOL;
extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) BOOL;
extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) isize;
extern "user32" fn PostMessageW(?HWND, u32, usize, isize) callconv(.winapi) BOOL;
extern "user32" fn MsgWaitForMultipleObjectsEx(count: u32, handles: ?[*]const HANDLE, ms: u32, wake_mask: u32, flags: u32) callconv(.winapi) u32;
extern "user32" fn SetWindowLongPtrW(HWND, index: c_int, value: isize) callconv(.winapi) isize;
extern "user32" fn GetWindowLongPtrW(HWND, index: c_int) callconv(.winapi) isize;
extern "user32" fn GetClientRect(HWND, *RECT) callconv(.winapi) BOOL;
extern "user32" fn GetDC(?HWND) callconv(.winapi) ?HDC;
extern "user32" fn ReleaseDC(?HWND, HDC) callconv(.winapi) c_int;
extern "user32" fn BeginPaint(HWND, *PAINTSTRUCT) callconv(.winapi) ?HDC;
extern "user32" fn EndPaint(HWND, *const PAINTSTRUCT) callconv(.winapi) BOOL;
extern "user32" fn SetProcessDpiAwarenessContext(context: isize) callconv(.winapi) BOOL;
extern "user32" fn GetDpiForWindow(HWND) callconv(.winapi) u32;
extern "user32" fn AdjustWindowRectExForDpi(*RECT, style: u32, menu: BOOL, ex_style: u32, dpi: u32) callconv(.winapi) BOOL;
extern "user32" fn SetWindowPos(HWND, after: ?HWND, x: i32, y: i32, w: i32, h: i32, flags: u32) callconv(.winapi) BOOL;
extern "user32" fn LoadCursorW(instance: ?HINSTANCE, name: usize) callconv(.winapi) ?HANDLE;
extern "user32" fn SetCursor(?HANDLE) callconv(.winapi) ?HANDLE;
extern "user32" fn OpenClipboard(?HWND) callconv(.winapi) BOOL;
extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
extern "user32" fn GetClipboardData(format: u32) callconv(.winapi) ?HANDLE;
extern "user32" fn SetClipboardData(format: u32, data: ?HANDLE) callconv(.winapi) ?HANDLE;
extern "kernel32" fn GlobalAlloc(flags: u32, bytes: usize) callconv(.winapi) ?HANDLE;
extern "kernel32" fn GlobalFree(HANDLE) callconv(.winapi) ?HANDLE;
extern "kernel32" fn GlobalLock(HANDLE) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn GlobalSize(HANDLE) callconv(.winapi) usize;
extern "imm32" fn ImmGetContext(HWND) callconv(.winapi) ?HIMC;
extern "imm32" fn ImmReleaseContext(HWND, HIMC) callconv(.winapi) BOOL;
extern "imm32" fn ImmGetCompositionStringW(HIMC, index: u32, buf: ?*anyopaque, bytes: u32) callconv(.winapi) i32;
extern "imm32" fn ImmSetCompositionWindow(HIMC, *const COMPOSITIONFORM) callconv(.winapi) BOOL;
extern "imm32" fn ImmSetCandidateWindow(HIMC, *const CANDIDATEFORM) callconv(.winapi) BOOL;
extern "imm32" fn ImmAssociateContextEx(HWND, ?HIMC, flags: u32) callconv(.winapi) BOOL;
extern "user32" fn TrackMouseEvent(*TRACKMOUSEEVENT) callconv(.winapi) BOOL;
extern "user32" fn SetCapture(HWND) callconv(.winapi) ?HWND;
extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
extern "gdi32" fn SetDIBitsToDevice(HDC, x: i32, y: i32, w: u32, h: u32, sx: i32, sy: i32, start: u32, lines: u32, bits: *const anyopaque, info: *const BITMAPINFOHEADER, usage: u32) callconv(.winapi) c_int;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("lcgr.win32");

// ---- The shell ------------------------------------------------------------------------------

pub const Win32 = struct {
    hwnd: HWND,
    instance: ?HINSTANCE,
    t: translate.Translator = .{},
    fb: sw.Framebuffer,
    /// Capacity of the caller's pixel buffer: the largest client area drawn, in pixels.
    pixels: []u32,
    gfx: sw.Software = .{},
    font: Mono = .{},
    glyphs: GlyphBuffers,
    /// What `present` clears to before drawing.
    background: Color = .rgb(0, 0, 0),
    /// The effects of the last frame, as `apply` received them.
    applied: Platform = .{},
    /// The system cursors, by `Platform.cursor` (`translate.cursor_ids`), and the one shown
    /// over the client area.
    cursors: [translate.cursor_ids.len]?HANDLE = @splat(null),
    cursor: ?HANDLE = null,
    /// What the IME gives, before the translator reads it: one composition's UTF-16 units and
    /// their attributes. ponytail: 256 units; a longer composition is cut.
    ime_units: [256]u16 = undefined,
    ime_attrs: [256]u8 = undefined,
    /// A WM_MOUSELEAVE is asked for (TrackMouseEvent); asked again on the next move after it.
    tracking: bool = false,

    pub const Options = struct {
        /// UTF-16, as the window title is shown.
        title: [*:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("LCGR"),
        /// Client size in logical pixels; the window is this times the monitor's scale.
        size: [2]u32 = .{ 800, 600 },
        /// False for a window that stays hidden (tests).
        show: bool = true,
    };

    /// Caller-owned storage, as for the headless shell: `pixels` holds the largest client area
    /// to draw (`sw.Framebuffer.len(w, h)`; a larger window is drawn cut off), `glyphs` one quad
    /// per byte of text in a frame, `first` and `count` one row per text run. `text` and
    /// `events` hold one frame's typed text and key events, `preedit` the IME's composition
    /// (`translate.Translator.Buffers`).
    pub const Buffers = struct {
        text: []u8,
        events: []lcgr.input.Input.Event,
        preedit: []u8,
        pixels: []u32,
        glyphs: []Quad,
        first: []u32,
        count: []u32,
    };
    const GlyphBuffers = struct { quads: []Quad, first: []u32, count: []u32 };

    pub const Error = error{CreateWindow};

    /// Opens the window. `w` is where the shell lives from now on: the window procedure finds it there.
    pub fn init(w: *Win32, opt: Options, buf: Buffers) Error!void {
        // Fails when the process already has an awareness (a manifest, an earlier window).
        _ = SetProcessDpiAwarenessContext(dpi_per_monitor_v2);
        const instance = GetModuleHandleW(null);
        // Fails when the class is already registered, which is fine; CreateWindowExW says if not.
        _ = RegisterClassExW(&.{ .wndproc = wndProc, .instance = instance, .class_name = class_name });
        w.* = .{
            .hwnd = undefined,
            .instance = instance,
            .t = .init(.{ .text = buf.text, .events = buf.events, .preedit = buf.preedit }),
            .fb = .init(buf.pixels, 0, 0, .bgra8),
            .pixels = buf.pixels,
            .glyphs = .{ .quads = buf.glyphs, .first = buf.first, .count = buf.count },
        };
        for (&w.cursors, translate.cursor_ids) |*c, id| c.* = LoadCursorW(null, id);
        w.cursor = w.cursors[@backingInt(context.Cursor.arrow)];
        w.hwnd = CreateWindowExW(0, class_name, opt.title, ws_overlappedwindow, cw_usedefault, cw_usedefault, cw_usedefault, cw_usedefault, null, null, instance, w) orelse return error.CreateWindow;
        // Now that the window has a monitor, size it: the logical size at that monitor's
        // scale, plus the frame at that DPI. Its WM_SIZE sets the viewport.
        const dpi = GetDpiForWindow(w.hwnd);
        w.t.setDpi(dpi);
        var r: RECT = .{ .right = @intFromFloat(@round(@as(f32, @floatFromInt(opt.size[0])) * w.t.in.scale)), .bottom = @intFromFloat(@round(@as(f32, @floatFromInt(opt.size[1])) * w.t.in.scale)) };
        _ = AdjustWindowRectExForDpi(&r, ws_overlappedwindow, 0, 0, dpi);
        _ = SetWindowPos(w.hwnd, null, 0, 0, r.right - r.left, r.bottom - r.top, swp_nomove | swp_nozorder | swp_noactivate);
        // No IME until a frame asks for text (`apply`).
        _ = ImmAssociateContextEx(w.hwnd, null, 0);
        if (opt.show) _ = ShowWindow(w.hwnd, sw_show);
    }

    pub fn deinit(w: *Win32) void {
        _ = DestroyWindow(w.hwnd);
        _ = UnregisterClassW(class_name, w.instance);
    }

    /// Drains the thread's message queue without blocking; the window procedure translates each
    /// message. False once the user closed the window.
    pub fn poll(w: *Win32, ev: *Events) bool {
        w.t.begin();
        var m: MSG = undefined;
        while (PeekMessageW(&m, null, 0, 0, pm_remove) != 0) {
            _ = TranslateMessage(&m);
            _ = DispatchMessageW(&m);
        }
        const open = w.t.frame(ev);
        // Cleared after, not before: what arrives between polls (a `paste`, the messages
        // `apply` causes) belongs to the next frame.
        w.t.begin();
        return open;
    }

    pub fn apply(w: *Win32, p: *const Platform) void {
        const cursor = w.cursors[@backingInt(p.cursor)];
        // Shown now if the pointer is over the client area; WM_SETCURSOR keeps it there.
        if (cursor != w.cursor and w.t.in.pointer[0] >= 0) _ = SetCursor(cursor);
        w.cursor = cursor;
        if (p.clipboard.len > 0) w.copy(p.clipboard);
        w.ime(p);
        w.applied = p.*;
    }

    /// Turns the IME on while a widget wants text, and puts its windows at `ime_rect`: the
    /// composition at its top left, the candidates below it without covering it.
    fn ime(w: *Win32, p: *const Platform) void {
        if (p.wants_text != w.applied.wants_text) _ = ImmAssociateContextEx(w.hwnd, null, if (p.wants_text) iace_default else 0);
        if (!p.wants_text) return;
        const himc = ImmGetContext(w.hwnd) orelse return;
        defer _ = ImmReleaseContext(w.hwnd, himc);
        const r = translate.physicalRect(p.ime_rect, w.t.in.scale);
        const area: RECT = .{ .left = r[0], .top = r[1], .right = r[2], .bottom = r[3] };
        _ = ImmSetCompositionWindow(himc, &.{ .style = cfs_point, .pos = .{ .x = r[0], .y = r[1] } });
        _ = ImmSetCandidateWindow(himc, &.{ .style = cfs_exclude, .pos = .{ .x = r[0], .y = r[3] }, .area = area });
    }

    /// Reads the IME's composition or result (WM_IME_COMPOSITION) into the translator.
    fn imeComposition(w: *Win32, flags: usize) void {
        const himc = ImmGetContext(w.hwnd) orelse return;
        defer _ = ImmReleaseContext(w.hwnd, himc);
        if (flags & gcs_resultstr != 0) w.t.commit(w.imeString(himc, gcs_resultstr));
        if (flags & gcs_compstr != 0) {
            const units = w.imeString(himc, gcs_compstr);
            const attr_bytes = ImmGetCompositionStringW(himc, gcs_compattr, &w.ime_attrs, w.ime_attrs.len);
            const attrs = w.ime_attrs[0..@intCast(std.math.clamp(attr_bytes, 0, w.ime_attrs.len))];
            const cursor = ImmGetCompositionStringW(himc, gcs_cursorpos, null, 0);
            w.t.compose(units, attrs, @intCast(@max(cursor, 0)));
        }
    }

    fn imeString(w: *Win32, himc: HIMC, index: u32) []const u16 {
        const bytes = ImmGetCompositionStringW(himc, index, &w.ime_units, @sizeOf(@TypeOf(w.ime_units)));
        return w.ime_units[0..@intCast(std.math.clamp(@divTrunc(bytes, 2), 0, w.ime_units.len))];
    }

    /// Puts UTF-8 text on the clipboard. Called by `apply` for `Platform.clipboard`. Invalid
    /// UTF-8, or a clipboard another program holds open, leaves the clipboard as it was.
    pub fn copy(w: *Win32, utf8: []const u8) void {
        const units = translate.clipboardUnits(utf8.len);
        const mem_h = GlobalAlloc(gmem_moveable, units * 2) orelse return;
        const dst: [*]u16 = @ptrCast(@alignCast(GlobalLock(mem_h) orelse {
            _ = GlobalFree(mem_h);
            return;
        }));
        const ok = translate.clipboardText(utf8, dst[0..units]) != null;
        _ = GlobalUnlock(mem_h);
        if (ok and OpenClipboard(w.hwnd) != 0) {
            _ = EmptyClipboard();
            // On success the clipboard owns the memory.
            const owned = SetClipboardData(cf_unicodetext, mem_h) != null;
            _ = CloseClipboard();
            if (owned) return;
        }
        _ = GlobalFree(mem_h);
    }

    /// Types the clipboard's text into the next frame, as `keyboard.Clipboard.paste` asks the
    /// host to: call it after a frame whose widgets requested a paste.
    pub fn paste(w: *Win32) void {
        if (OpenClipboard(w.hwnd) == 0) return;
        defer _ = CloseClipboard();
        const h = GetClipboardData(cf_unicodetext) orelse return;
        const src: [*]const u16 = @ptrCast(@alignCast(GlobalLock(h) orelse return));
        defer _ = GlobalUnlock(h);
        const cap = GlobalSize(h) / 2;
        w.t.paste(src[0 .. std.mem.indexOfScalar(u16, src[0..cap], 0) orelse cap]);
    }

    /// Draws the frame in software and copies it to the client area.
    pub fn present(w: *Win32, out: *const Output) void {
        var r: RECT = .{};
        _ = GetClientRect(w.hwnd, &r);
        const width: u32 = @intCast(@max(r.right - r.left, 0));
        const height: u32 = @intCast(@max(r.bottom - r.top, 0));
        const rows: u32 = @intCast(@min(height, w.pixels.len / @max(lcgr.simd.padded(width), 1)));
        w.fb = .init(w.pixels, width, rows, .bgra8);
        const g = w.glyphs;
        const n = w.font.quads(out.draw, g.quads, .{ .first = g.first, .count = g.count });
        w.gfx.prepare({}, out.draw, .{ .quads = g.quads[0..n], .first = g.first, .count = g.count }, .{ 0, 0 }, w.t.in.scale);
        w.fb.clear(w.background);
        render.render(&w.gfx, .{ .fb = &w.fb, .scissor = w.fb.all() }, out.draw);
        const dc = GetDC(w.hwnd) orelse return;
        w.blit(dc);
        _ = ReleaseDC(w.hwnd, dc);
    }

    /// Copies the framebuffer to the client area, as last drawn.
    fn blit(w: *const Win32, dc: HDC) void {
        if (w.fb.width == 0 or w.fb.height == 0) return;
        const info: BITMAPINFOHEADER = .{ .width = @intCast(w.fb.stride), .height = -@as(i32, @intCast(w.fb.height)) };
        _ = SetDIBitsToDevice(dc, 0, 0, w.fb.width, w.fb.height, 0, 0, 0, w.fb.height, w.fb.pixels.ptr, &info, dib_rgb_colors);
    }

    /// Blocks until the next message or `seconds` pass (`inf`: until the next message).
    pub fn wait(_: *Win32, seconds: f32, _: Pace) void {
        if (!(seconds > 0)) return;
        const ms: u32 = if (seconds >= 4e6) infinite else @intFromFloat(@ceil(seconds * 1000));
        _ = MsgWaitForMultipleObjectsEx(0, null, ms, qs_allinput, mwmo_inputavailable);
    }

    /// Thread-safe: posts a message to the window, which ends a `wait`.
    pub fn wake(w: *Win32) void {
        _ = PostMessageW(w.hwnd, wm_wake, 0, 0);
    }

    fn wndProc(hwnd: HWND, msg: u32, wp: usize, lp: isize) callconv(.winapi) isize {
        if (msg == wm_nccreate) {
            // CREATESTRUCTW starts with lpCreateParams, the `w` CreateWindowExW was given.
            const create: *const ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(lp)));
            _ = SetWindowLongPtrW(hwnd, gwlp_userdata, @bitCast(@intFromPtr(create.*)));
        }
        const found: ?*Win32 = @ptrFromInt(@as(usize, @bitCast(GetWindowLongPtrW(hwnd, gwlp_userdata))));
        const w = found orelse return DefWindowProcW(hwnd, msg, wp, lp);
        switch (msg) {
            wm_paint => {
                // Uncovered or resized: show the last frame again until the next one is drawn.
                var ps: PAINTSTRUCT = undefined;
                const dc = BeginPaint(hwnd, &ps) orelse return 0;
                w.blit(dc);
                _ = EndPaint(hwnd, &ps);
                return 0;
            },
            // The UI draws the composition itself (Events.composition); the IME draws the rest.
            wm_ime_setcontext => return DefWindowProcW(hwnd, msg, wp, lp & ~@as(isize, @bitCast(isc_showuicompositionwindow))),
            wm_ime_startcomposition => return 0,
            wm_ime_composition => {
                w.imeComposition(@bitCast(lp));
                return 0;
            },
            wm_ime_endcomposition => {
                w.t.compose(&.{}, &.{}, 0);
                return 0;
            },
            // Windows resets the cursor on every move; over the client it is the frame's.
            wm_setcursor => if (@as(u16, @truncate(@as(usize, @bitCast(lp)))) == ht_client) {
                _ = SetCursor(w.cursor);
                return 1;
            },
            // The frame covers the whole client area: no erase, no flicker.
            wm_erasebkgnd => return 1,
            wm(.mousemove) => if (!w.tracking) {
                var tme: TRACKMOUSEEVENT = .{ .flags = tme_leave, .hwnd = hwnd };
                w.tracking = TrackMouseEvent(&tme) != 0;
            },
            wm(.mouseleave) => w.tracking = false,
            wm(.dpichanged) => {
                // Scale first, then take the size Windows suggests for the new DPI.
                w.t.feed(.{ .msg = msg, .wparam = wp, .lparam = lp });
                const r: *const RECT = @ptrFromInt(@as(usize, @bitCast(lp)));
                _ = SetWindowPos(hwnd, null, r.left, r.top, r.right - r.left, r.bottom - r.top, swp_nozorder | swp_noactivate);
                return 0;
            },
            // A drag that leaves the window keeps sending it moves until every button is up.
            wm(.lbuttondown), wm(.rbuttondown), wm(.mbuttondown) => _ = SetCapture(hwnd),
            wm(.lbuttonup), wm(.rbuttonup), wm(.mbuttonup) => if (wp & mk_any == 0) {
                _ = ReleaseCapture();
            },
            else => {},
        }
        w.t.feed(.{ .msg = msg, .wparam = wp, .lparam = lp });
        // WM_CLOSE is the user's request; the host decides, so the window stays until deinit.
        if (msg == wm(.close)) return 0;
        return DefWindowProcW(hwnd, msg, wp, lp);
    }
};

fn wm(comptime m: translate.Wm) u32 {
    return @backingInt(m);
}
/// MK_LBUTTON, MK_RBUTTON, MK_MBUTTON: some mouse button is still held.
const mk_any = 0x0013;

comptime {
    iface.check(Win32);
}

// ---- Tests: on Windows only (`zig build win32`) ---------------------------------------------

const testing = std.testing;
const mem = lcgr.mem;
const example = lcgr.shell_example;

const example_limits: context.Limits = .{ .nodes = 1024, .texts = 256 };
const Fixture = struct {
    var ctx_buffer: [context.Context.requiredBytes(example_limits)]u8 align(mem.column_align) = undefined;
    var pixels: [sw.Framebuffer.len(1024, 768)]u32 = undefined;
    var text: [64]u8 = undefined;
    var events: [16]lcgr.input.Input.Event = undefined;
    var preedit: [64]u8 = undefined;
    var glyphs: [512]Quad = undefined;
    var first: [example_limits.texts]u32 = undefined;
    var count: [example_limits.texts]u32 = undefined;

    fn open(w: *Win32) !void {
        try w.init(.{ .show = false }, .{ .text = &text, .events = &events, .preedit = &preedit, .pixels = &pixels, .glyphs = &glyphs, .first = &first, .count = &count });
    }
};

/// Posts a recorded frame's messages to the window, then polls it: what the window procedure
/// sees is what a user's input would give it.
fn replayFrame(w: *Win32, r: *translate.Replay, ev: *Events) !?bool {
    var buf: [32]translate.Msg = undefined;
    const msgs = (try r.next(&buf)) orelse return null;
    for (msgs) |m| _ = PostMessageW(w.hwnd, m.msg, m.wparam, m.lparam);
    return w.poll(ev);
}

test "win32: a real window runs the example from posted messages" {
    var w: Win32 = undefined;
    try Fixture.open(&w);
    defer w.deinit();
    // The real cursor is not over this hidden window: asking for WM_MOUSELEAVE would report
    // the recorded pointer gone.
    w.tracking = true;
    // The recording is at 100%, whatever the test machine's monitor is.
    w.t.setDpi(96);
    var ctx = try context.Context.init(&Fixture.ctx_buffer, example_limits);
    var app: example.App = .{};
    var r: translate.Replay = .{ .src = @embedFile("testdata/example.msgs") };
    var ev: Events = .{};
    var frames: u32 = 0;
    while (try replayFrame(&w, &r, &ev)) |open| : (frames += 1) {
        try testing.expect(open);
        if (!ctx.needsFrame(&ev.in)) continue;
        var f = ctx.begin(&ev.in);
        app.build(&f, &ev);
        const out = f.end(.{});
        w.apply(&out.platform);
        w.present(&out);
    }
    // The headless shell's results (src/shell/headless.zig).
    try testing.expectEqual(@as(u32, 15), frames);
    try testing.expectEqual(@as(u32, 13), app.builds);
    try testing.expectEqual(@as(u32, 1), app.resets);
    try testing.expectEqual(@as(u32, 4), app.layers);
    try testing.expectApproxEqAbs(@as(f32, 3), app.exposure, 0.01);
    try testing.expectEqual(app.theme.panel, w.fb.at(80, 590));
    // The arrow is back after leaving the slider, and it is the system's.
    try testing.expectEqual(context.Cursor.arrow, w.applied.cursor);
    try testing.expectEqual(LoadCursorW(null, translate.cursor_ids[0]), w.cursor);
    try testing.expect(w.cursor != null);
}

test "win32: copy then paste round-trips through the system clipboard" {
    var w: Win32 = undefined;
    try Fixture.open(&w);
    defer w.deinit();
    var ev: Events = .{};
    _ = w.poll(&ev);
    w.apply(&.{ .clipboard = "two\nlines \u{e9}" });
    w.paste();
    try testing.expect(w.poll(&ev));
    try testing.expectEqualStrings("two\nlines \u{e9}", ev.in.text);
}
