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
        shell_cursor(c) {
            page.canvas.style.cursor = cursors[c] ?? "default";
        },
        shell_ime(on, x0, y0, x1, y1) {
            page.ime(on, x0, y0, x1, y1);
        },
        shell_clipboard(ptr, len) {
            // Decoded now: the bytes are only valid during the call. writeText is asynchronous
            // and may be refused (no focus, no permission); the copy is then lost, as in a
            // native app whose clipboard is busy.
            const text = ui.str(ptr, len);
            navigator.clipboard?.writeText(text).catch((e) => console.warn("lcgr: copy refused:", e.message));
        },
    });
}

/// CSS cursors of context.Cursor, in its order: arrow, pointer, text, grab, resize_h, resize_v.
export const cursors = ["default", "pointer", "text", "grab", "ew-resize", "ns-resize"];

/// Starts forwarding `canvas`'s events to `ui` and running its frames. Returns `page`, with
/// `frames` (animation frames run) and `stop()`.
export function attach(ui, canvas, page = {}) {
    const x = ui.exports;
    page.canvas = canvas;
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
    forward(ui, canvas, on, frame, page);
    on(window, "pagehide", () => {
        x.lcgr_close();
        page.stop();
    });
    page.stop = () => {
        observer.disconnect();
        page.input.remove();
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
function forward(ui, canvas, on, frame, page) {
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
    // Text input and the IME go through a hidden <textarea>: while a widget wants text
    // (`shell_ime`), it has focus at the caret's rect, so the IME's candidate window and the
    // on-screen keyboard come up there, and its input and composition events carry the text.
    // Keys reach the shell from whichever of the two has focus.
    const input = document.createElement("textarea");
    for (const [k, v] of [["autocomplete", "off"], ["autocorrect", "off"], ["autocapitalize", "off"], ["spellcheck", "false"], ["tabindex", "-1"]]) input.setAttribute(k, v);
    Object.assign(input.style, { position: "fixed", opacity: "0", border: "0", padding: "0", margin: "0", resize: "none", overflow: "hidden", pointerEvents: "none", width: "1px", height: "1px", left: "0", top: "0" });
    canvas.after(input);
    page.input = input;
    const bytes = (s) => new TextEncoder().encode(s).length;
    page.ime = (on, x0, y0, x1, y1) => {
        if (!on) {
            if (document.activeElement === input) canvas.focus({ preventScroll: true });
            return;
        }
        const r = canvas.getBoundingClientRect();
        const h = Math.max(y1 - y0, 1);
        Object.assign(input.style, { left: `${r.left + x0}px`, top: `${r.top + y0}px`, width: `${Math.max(x1 - x0, 1)}px`, height: `${h}px`, fontSize: `${h}px` });
        input.focus({ preventScroll: true });
    };
    const keydown = (e) => {
        if (e.isComposing || e.keyCode === 229) return; // the IME's own keys
        x.lcgr_key(e.repeat ? 2 : 0, hid[e.code] ?? 0, mods(e));
        const printable = [...e.key].length === 1 && !e.ctrlKey && !e.metaKey;
        // On the canvas, a printable key without Ctrl or Cmd is typed text; in the text input
        // the input event brings it (and the IME may change it), so it is let through.
        if (printable && e.target === canvas) typed(e.key, mods(e));
        // Keep Tab, arrows, Space and Backspace from moving focus or scrolling the page;
        // shortcuts with Ctrl or Cmd (copy, paste, reload) stay the browser's.
        if (!e.ctrlKey && !e.metaKey && !(printable && e.target === input)) e.preventDefault();
        frame();
    };
    const keyup = (e) => {
        x.lcgr_key(1, hid[e.code] ?? 0, mods(e));
        frame();
    };
    // Paste: the browser hands the text over in the paste event (Ctrl+V or Cmd+V, which are
    // left to the browser above, or the context menu); it arrives as typed text.
    const paste = (e) => {
        const text = e.clipboardData?.getData("text/plain");
        if (text) typed(text, 0);
        e.preventDefault();
        frame();
    };
    // Keys held when focus leaves both never see their keyup: release them.
    const focusout = (e) => {
        if (e.relatedTarget === canvas || e.relatedTarget === input) return;
        x.lcgr_blur();
        frame();
    };
    for (const t of [canvas, input]) {
        on(t, "keydown", keydown);
        on(t, "keyup", keyup);
        on(t, "paste", paste);
        on(t, "focusout", focusout);
    }
    // While composing, the textarea holds the composition and its selection marks the
    // converted clause (or the caret): both go to the shell, the range in UTF-8 bytes. On commit
    // the composition ends and its text is typed; plain input (no IME) is typed as it comes.
    const compose = () => {
        const v = input.value;
        const n = ui.put(v, x.lcgr_text_buffer(), x.lcgr_text_capacity());
        x.lcgr_compose(n, Math.min(bytes(v.slice(0, input.selectionStart)), n), Math.min(bytes(v.slice(0, input.selectionEnd)), n));
        frame();
    };
    on(input, "compositionstart", () => (input.value = ""));
    on(input, "input", (e) => {
        if (e.isComposing || e.inputType === "insertCompositionText") return compose();
        if (e.data) typed(e.data, 0);
        input.value = "";
        frame();
    });
    on(input, "compositionend", (e) => {
        x.lcgr_compose(0, 0, 0);
        if (e.data) typed(e.data, 0);
        input.value = "";
        frame();
    });
}
