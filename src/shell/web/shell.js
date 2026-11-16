// The web shell's page side (src/shell/web/web.zig): attaches a loaded LCGR module to a
// <canvas>, forwards what happens to the canvas through the module's exports, and runs its
// frames from requestAnimationFrame. Load the module with src/render/web/lcgr.js first:
//
//     import { load, webgpu, canvas2d } from "./lcgr.js";
//     import { attach, shell } from "./shell.js";
//     const canvas = document.querySelector("canvas");
//     const page = {};
//     const ui = await load("shell.wasm", webgpu, canvas2d(canvas), shell(page));
//     attach(ui, canvas, page);
//
// DOM events become calls on the shell (`forward`): mouse pointer events move `Input.pointer`
// and its buttons, touch and pen pointer events are `Input.contacts`, wheel events `wheel` or
// `scroll`, key events `Input.keys` and `events` with USB HID codes, typed characters `text`.
//
// The module runs one frame per animation frame it asked for (`lcgr_frame`), and asks for the
// next one itself (`shell_schedule`): the next animation frame while anything is pending, and
// none while idle, so an idle page costs nothing. A resize asks for a frame.

/// The imports web.zig's host needs. `page` is filled by `attach`.
export function shell(page) {
    return (ui) => ({
        shell_schedule(seconds, pace) {
            page.schedule?.(seconds, pace);
        },
    });
}

/// Starts forwarding `canvas`'s events to `ui` and running its frames. Returns `page`, with
/// `frames` (animation frames run) and `stop()`.
export function attach(ui, canvas, page = {}) {
    const x = ui.exports;
    let pending = 0; // requestAnimationFrame id, 0 when none is pending
    page.frames = 0;
    const run = (ms) => {
        pending = 0;
        page.frames++;
        x.lcgr_frame(ms);
    };
    const frame = () => {
        if (!pending) pending = requestAnimationFrame(run);
    };
    page.frame = frame;
    page.schedule = (seconds) => {
        if (seconds !== Infinity) frame(); // idle (Infinity): the next event asks
    };

    // The canvas fills its CSS box; its backing store is that box in device pixels, so the
    // frame maps one to one onto the screen at any devicePixelRatio. ResizeObserver reports
    // the device-pixel size exactly where the browser knows it (Chromium, Firefox), and fires
    // again when the ratio changes (zoom, a move to another monitor); elsewhere css * dpr is
    // rounded, and a resolution media query catches ratio changes.
    let device = null; // [w, h] from devicePixelContentBoxSize, when the browser gives it
    const resize = () => {
        const r = canvas.getBoundingClientRect();
        const dpr = window.devicePixelRatio || 1;
        const [w, h] = device ?? [Math.round(r.width * dpr), Math.round(r.height * dpr)];
        if (canvas.width !== w || canvas.height !== h) [canvas.width, canvas.height] = [w, h];
        x.lcgr_resize(r.width, r.height, dpr, w, h);
        frame();
    };
    const observer = new ResizeObserver(([entry]) => {
        const d = entry.devicePixelContentBoxSize?.[0];
        device = d ? [d.inlineSize, d.blockSize] : null;
        resize();
    });
    try {
        observer.observe(canvas, { box: "device-pixel-content-box" });
    } catch {
        observer.observe(canvas); // no device-pixel box: css * dpr
    }
    let ratio = null;
    const watchRatio = () => {
        ratio?.removeEventListener("change", onRatio);
        ratio = matchMedia(`(resolution: ${window.devicePixelRatio || 1}dppx)`);
        ratio.addEventListener("change", onRatio);
    };
    const onRatio = () => {
        watchRatio();
        resize();
    };
    watchRatio();
    resize();

    const listeners = [];
    const on = (target, type, fn, opts) => {
        target.addEventListener(type, fn, opts);
        listeners.push([target, type, fn, opts]);
    };
    page.on = on;
    forward(ui, canvas, on, frame);
    on(window, "pagehide", () => {
        x.lcgr_close();
        page.stop();
    });
    page.stop = () => {
        observer.disconnect();
        ratio.removeEventListener("change", onRatio);
        for (const [t, type, fn, opts] of listeners) t.removeEventListener(type, fn, opts);
        cancelAnimationFrame(pending);
    };
    frame();
    return page;
}

/// KeyboardEvent.code to USB HID usage ids (HID Usage Tables, keyboard page 0x07): the codes the
/// core's key maps default to (src/interact/focus.zig `Keymap`, keyboard.zig `ClipboardKeys`).
export const hid = (() => {
    const m = {};
    for (let i = 0; i < 26; i++) m["Key" + String.fromCharCode(65 + i)] = 0x04 + i;
    for (let i = 1; i <= 9; i++) m["Digit" + i] = 0x1d + i;
    m.Digit0 = 0x27;
    for (let i = 1; i <= 12; i++) m["F" + i] = 0x39 + i;
    for (let i = 1; i <= 9; i++) m["Numpad" + i] = 0x58 + i;
    Object.assign(m, {
        Enter: 0x28, Escape: 0x29, Backspace: 0x2a, Tab: 0x2b, Space: 0x2c, Minus: 0x2d, Equal: 0x2e,
        BracketLeft: 0x2f, BracketRight: 0x30, Backslash: 0x31, Semicolon: 0x33, Quote: 0x34,
        Backquote: 0x35, Comma: 0x36, Period: 0x37, Slash: 0x38, CapsLock: 0x39,
        PrintScreen: 0x46, ScrollLock: 0x47, Pause: 0x48, Insert: 0x49, Home: 0x4a, PageUp: 0x4b,
        Delete: 0x4c, End: 0x4d, PageDown: 0x4e, ArrowRight: 0x4f, ArrowLeft: 0x50, ArrowDown: 0x51,
        ArrowUp: 0x52, NumLock: 0x53, NumpadDivide: 0x54, NumpadMultiply: 0x55, NumpadSubtract: 0x56,
        NumpadAdd: 0x57, NumpadEnter: 0x58, Numpad0: 0x62, NumpadDecimal: 0x63, IntlBackslash: 0x64,
        ContextMenu: 0x65, NumpadEqual: 0x67, IntlRo: 0x87, IntlYen: 0x89,
        ControlLeft: 0xe0, ShiftLeft: 0xe1, AltLeft: 0xe2, MetaLeft: 0xe3,
        ControlRight: 0xe4, ShiftRight: 0xe5, AltRight: 0xe6, MetaRight: 0xe7,
    });
    return m;
})();

/// Input.Mods bits of a DOM event: shift, ctrl, alt, cmd (Meta).
export const mods = (e) => (e.shiftKey ? 1 : 0) | (e.ctrlKey ? 2 : 0) | (e.altKey ? 4 : 0) | (e.metaKey ? 8 : 0);

/// Forwards `canvas`'s DOM events to the module, each followed by a request for a frame.
/// `on(target, type, fn, options)` adds a listener that `stop` removes; `frame` asks for one.
function forward(ui, canvas, on, frame) {
    const x = ui.exports;
    const at = (e) => {
        const r = canvas.getBoundingClientRect();
        return [e.clientX - r.left, e.clientY - r.top];
    };
    // Fingers and pens are contacts; the mouse is the pointer.
    const contact = (e, down) => {
        const [px, py] = at(e);
        const kind = e.pointerType === "touch" ? 0 : e.buttons & 32 ? 2 : 1; // 32: eraser button
        const deg = Math.PI / 180;
        x.lcgr_contact(e.pointerId, kind, down, px, py, e.pressure > 0 ? e.pressure : e.pointerType === "touch" ? 1 : 0, (e.tiltX || 0) * deg, (e.tiltY || 0) * deg);
    };
    canvas.style.touchAction = "none"; // the page does not pan or zoom under a finger
    canvas.tabIndex = 0; // focusable, so keys reach it
    canvas.style.outline = "none";
    on(canvas, "pointermove", (e) => {
        x.lcgr_mods(mods(e));
        if (e.pointerType === "mouse") x.lcgr_pointer(...at(e));
        else contact(e, e.buttons !== 0);
        frame();
    });
    on(canvas, "pointerdown", (e) => {
        canvas.focus({ preventScroll: true });
        canvas.setPointerCapture(e.pointerId); // a drag keeps reporting outside the canvas
        x.lcgr_mods(mods(e));
        if (e.pointerType === "mouse") {
            x.lcgr_pointer(...at(e));
            x.lcgr_button(e.button, true);
        } else contact(e, true);
        e.preventDefault();
        frame();
    });
    const up = (e) => {
        if (e.pointerType === "mouse") x.lcgr_button(e.button, false);
        else x.lcgr_lift(e.pointerId);
        frame();
    };
    on(canvas, "pointerup", up);
    on(canvas, "pointercancel", up);
    on(canvas, "pointerleave", (e) => {
        if (e.pointerType === "mouse") x.lcgr_leave();
        else x.lcgr_lift(e.pointerId);
        frame();
    });
    on(canvas, "contextmenu", (e) => e.preventDefault());
    on(canvas, "wheel", (e) => {
        x.lcgr_mods(mods(e));
        x.lcgr_wheel(e.deltaX, e.deltaY, e.deltaMode);
        e.preventDefault(); // the page does not scroll
        frame();
    }, { passive: false });

    const typed = (s, m) => {
        const n = ui.put(s, x.lcgr_text_buffer(), x.lcgr_text_capacity());
        x.lcgr_typed(n, m);
    };
    on(canvas, "keydown", (e) => {
        const code = hid[e.code] ?? 0;
        x.lcgr_key(e.repeat ? 2 : 0, code, mods(e));
        // A printable character without Ctrl or Cmd is typed text.
        if ([...e.key].length === 1 && !e.ctrlKey && !e.metaKey) typed(e.key, mods(e));
        // Keep Tab, arrows, Space and Backspace from moving focus or scrolling the page;
        // shortcuts with Ctrl or Cmd (copy, paste, reload) stay the browser's.
        if (!e.ctrlKey && !e.metaKey) e.preventDefault();
        frame();
    });
    on(canvas, "keyup", (e) => {
        x.lcgr_key(1, hid[e.code] ?? 0, mods(e));
        frame();
    });
    // Keys held when the canvas loses focus never see their keyup: release them.
    on(canvas, "blur", () => {
        x.lcgr_blur();
        frame();
    });
}
