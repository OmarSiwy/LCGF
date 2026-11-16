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

/// WebGPU for webgpu.zig: the binding functions of the wgpu renderer, over a table of handles.
/// After `load`, `ui.gpu.put(obj)` registers a host object (device, queue, pass, texture view,
/// sampler) and returns its handle; `ui.gpu.get(h)` reads one back; `ui.gpu.release(h)` frees
/// the slot. Handle 0 is never used.
export function webgpu(ui) {
    const objs = [null];
    const free = [];
    const gpu = (ui.gpu = {
        put(o) {
            const h = free.length ? free.pop() : objs.length;
            objs[h] = o;
            return h;
        },
        get: (h) => objs[h],
        release(h) {
            objs[h]?.destroy?.();
            objs[h] = null;
            free.push(h);
        },
    });
    // Same order as webgpu.zig `TextureFormat` and wgpu.zig `AttrFormat`, `BufferUse`.
    const formats = ["rgba8unorm", "bgra8unorm"];
    const attr_formats = ["float32", "float32x2", "float32x4", "uint32x4", "unorm8x4"];
    // A function, so a page without WebGPU can still link this part (GPUBufferUsage is undefined).
    const uses = (use) => (use ? GPUBufferUsage.UNIFORM : GPUBufferUsage.VERTEX) | GPUBufferUsage.COPY_DST;
    // One pair of bind group layouts per device, shared by every pipeline (wgpu.zig `Binding`).
    const layouts = new Map();
    function layoutsOf(device) {
        let l = layouts.get(device);
        if (l) return l;
        const VF = GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT;
        const globals = device.createBindGroupLayout({ entries: [{ binding: 0, visibility: VF, buffer: { type: "uniform" } }] });
        const texture = device.createBindGroupLayout({
            entries: [
                { binding: 0, visibility: GPUShaderStage.FRAGMENT, texture: { sampleType: "float" } },
                { binding: 1, visibility: GPUShaderStage.FRAGMENT, sampler: { type: "filtering" } },
            ],
        });
        l = { globals, texture, pipeline: device.createPipelineLayout({ bindGroupLayouts: [globals, texture] }) };
        layouts.set(device, l);
        return l;
    }
    const blend = { srcFactor: "one", dstFactor: "one-minus-src-alpha", operation: "add" };
    return {
        gpu_create_buffer(d, size, use) {
            return gpu.put(objs[d].createBuffer({ size, usage: uses(use) }));
        },
        gpu_release: gpu.release,
        gpu_write_buffer(q, b, offset, ptr, len) {
            objs[q].writeBuffer(objs[b], offset, ui.exports.memory.buffer, ptr, len);
        },
        gpu_create_pipeline(d, wgsl, wgsl_len, vs, vs_len, fs, fs_len, format, samples, stride, attrs, attrs_len) {
            const device = objs[d];
            const module = device.createShaderModule({ code: ui.str(wgsl, wgsl_len) });
            const rows = ui.u32(attrs, attrs_len * 3);
            const attributes = [];
            for (let i = 0; i < attrs_len; i++)
                attributes.push({ shaderLocation: rows[i * 3], offset: rows[i * 3 + 1], format: attr_formats[rows[i * 3 + 2]] });
            return gpu.put(device.createRenderPipeline({
                layout: layoutsOf(device).pipeline,
                vertex: { module, entryPoint: ui.str(vs, vs_len), buffers: [{ arrayStride: stride, stepMode: "instance", attributes }] },
                primitive: { topology: "triangle-strip" },
                fragment: { module, entryPoint: ui.str(fs, fs_len), targets: [{ format: formats[format], blend: { color: blend, alpha: blend } }] },
                multisample: { count: samples },
            }));
        },
        gpu_globals_group(d, b) {
            const device = objs[d];
            return gpu.put(device.createBindGroup({ layout: layoutsOf(device).globals, entries: [{ binding: 0, resource: { buffer: objs[b] } }] }));
        },
        gpu_texture_group(d, v, s) {
            const device = objs[d];
            return gpu.put(device.createBindGroup({
                layout: layoutsOf(device).texture,
                entries: [{ binding: 0, resource: objs[v] }, { binding: 1, resource: objs[s] }],
            }));
        },
        gpu_set_pipeline: (p, pipe) => objs[p].setPipeline(objs[pipe]),
        gpu_set_bind_group: (p, i, g) => objs[p].setBindGroup(i, objs[g]),
        gpu_set_vertex_buffer: (p, slot, b, offset, size) => objs[p].setVertexBuffer(slot, objs[b], offset, Math.min(size, objs[b].size - offset)),
        gpu_draw: (p, v, n, fv, fi) => objs[p].draw(v, n, fv, fi),
    };
}

/// The 2D-canvas fallback for canvas.zig: `load(url, canvas2d(canvasElement))`. `present`
/// copies the module's framebuffer onto the canvas, resizing the canvas to it.
export function canvas2d(canvas) {
    const ctx = canvas.getContext("2d");
    return (ui) => ({
        canvas_put(ptr, stride, w, h) {
            if (canvas.width !== w || canvas.height !== h) [canvas.width, canvas.height] = [w, h];
            const px = new Uint8ClampedArray(ui.exports.memory.buffer, ptr, stride * h * 4);
            ctx.putImageData(new ImageData(px, stride, h), 0, 0, 0, 0, w, h);
        },
    });
}
