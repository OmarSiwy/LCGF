// The JavaScript side of LCGR on the web: loads a wasm32-freestanding module and gives it the
// functions it imports (module "lcgr"). Nothing else: no framework, no build step, no bundler.
//
//     import { load } from "./lcgr.js";
//     const ui = await load("hello.wasm");
//     ui.exports.lcgr_hello(800, 600);
//
// The wasm side owns its memory and its loop (docs/DESIGN.md); JS only reads what it is told
// to read (a pointer and a length) and calls the platform for it. Each feature adds its
// imports through `parts`: a function from the loaded module to an object of import functions,
// so a page links only what it uses.
//
// Ported in spirit from DVUI's web back end (web.js) and Clay's wasm example: one import
// object, strings passed as (pointer, length) into the module's memory, decoded with
// TextDecoder.

const decoder = new TextDecoder();
const encoder = new TextEncoder();

/// Loads `url` (or an ArrayBuffer of wasm bytes) and instantiates it. `parts` are functions
/// `(ui) => ({ name: fn, ... })` adding imports; `ui` is the returned object, filled once the
/// instance exists (imports are only called after that).
export async function load(url, ...parts) {
    const ui = {
        instance: null,
        exports: null,
        /// Lines the module logged, newest last (also echoed to the console).
        logs: [],
        /// The module's memory as bytes. A new view each call: memory.grow detaches old ones.
        u8(ptr, len) {
            return new Uint8Array(ui.exports.memory.buffer, ptr, len);
        },
        u32(ptr, len) {
            return new Uint32Array(ui.exports.memory.buffer, ptr, len);
        },
        f32(ptr, len) {
            return new Float32Array(ui.exports.memory.buffer, ptr, len);
        },
        str(ptr, len) {
            return decoder.decode(ui.u8(ptr, len));
        },
        /// Encodes `s` as UTF-8 into the module's buffer [ptr, ptr + cap); returns bytes written.
        put(s, ptr, cap) {
            return encoder.encodeInto(s, ui.u8(ptr, cap)).written;
        },
    };
    const env = {
        log(ptr, len) {
            const line = ui.str(ptr, len);
            ui.logs.push(line);
            console.log(line);
        },
        panic(ptr, len) {
            const msg = ui.str(ptr, len);
            ui.logs.push("panic: " + msg);
            throw new Error("lcgr panic: " + msg);
        },
    };
    for (const part of parts) Object.assign(env, part(ui));
    const bytes = typeof url === "string" ? await (await fetch(url)).arrayBuffer() : url;
    const { instance } = await WebAssembly.instantiate(bytes, { lcgr: env });
    ui.instance = instance;
    ui.exports = instance.exports;
    return ui;
}
