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

    // The canvas fills its CSS box, one canvas pixel per CSS pixel.
    const resize = () => {
        const r = canvas.getBoundingClientRect();
        canvas.width = Math.round(r.width);
        canvas.height = Math.round(r.height);
        x.lcgr_resize(r.width, r.height, 1);
        frame();
    };
    const observer = new ResizeObserver(resize);
    observer.observe(canvas);
    resize();

    const listeners = [];
    const on = (target, type, fn, opts) => {
        target.addEventListener(type, fn, opts);
        listeners.push([target, type, fn, opts]);
    };
    page.on = on;
    on(window, "pagehide", () => {
        x.lcgr_close();
        page.stop();
    });
    page.stop = () => {
        observer.disconnect();
        for (const [t, type, fn, opts] of listeners) t.removeEventListener(type, fn, opts);
        cancelAnimationFrame(pending);
    };
    frame();
    return page;
}
