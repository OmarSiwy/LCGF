// The JavaScript side of LCGF on the web: loads a wasm32-freestanding module and gives it the
// functions it imports (module "lcgf"). Nothing else: no framework, no build step, no bundler.
//
//     import { load } from "./lcgf.js";
//     const ui = await load("hello.wasm");
//     ui.exports.lcgf_hello(800, 600);
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
            throw new Error("lcgf panic: " + msg);
        },
    };
    for (const part of parts) Object.assign(env, part(ui));
    const bytes = typeof url === "string" ? await (await fetch(url)).arrayBuffer() : url;
    const { instance } = await WebAssembly.instantiate(bytes, { lcgf: env });
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

/// lcgf_render.gpu in the browser (src/render/web/gpu.zig): one WebGPU call per import, over
/// the handle table of `webgpu` (link it first: `load(url, webgpu, gpuProjection)`). Descriptors
/// arrive as u32 words; these tables name their values in the order of src/render/gpu/desc.zig's
/// enums.
export function gpuProjection(ui) {
    const formats = ["r8unorm", "rg8unorm", "rgba8unorm", "rgba8unorm-srgb", "bgra8unorm", "bgra8unorm-srgb", "r16float", "rgba16float", "r32float", "rg32float", "rgba32float", "r32uint", "depth32float"];
    const vertexFormats = ["float32", "float32x2", "float32x3", "float32x4", "uint32", "uint32x2", "uint32x4", "sint32", "unorm8x4"];
    const topologies = ["point-list", "line-list", "line-strip", "triangle-list", "triangle-strip"];
    const indexFormats = ["uint16", "uint32"];
    const frontFaces = ["ccw", "cw"];
    const cullModes = ["none", "front", "back"];
    const factors = ["zero", "one", "src", "one-minus-src", "src-alpha", "one-minus-src-alpha", "dst", "one-minus-dst", "dst-alpha", "one-minus-dst-alpha", "constant", "one-minus-constant"];
    const operations = ["add", "subtract", "reverse-subtract", "min", "max"];
    const addressModes = ["clamp-to-edge", "repeat", "mirror-repeat"];
    const filters = ["nearest", "linear"];
    const compares = ["never", "less", "equal", "less-equal", "greater", "not-equal", "greater-equal", "always"];
    const get = (h) => ui.gpu.get(h);
    const put = (o) => ui.gpu.put(o);
    const f32 = (bits) => new Float32Array(new Uint32Array([bits]).buffer)[0];
    return {
        gpup_create_buffer: (d, size, usage) => put(get(d).createBuffer({ size, usage })),
        gpup_create_texture: (d, w, h, layers, format, usage, mips, samples) =>
            put(get(d).createTexture({ size: [w, h, layers], format: formats[format], usage, mipLevelCount: mips, sampleCount: samples })),
        gpup_create_view: (t) => put(get(t).createView()),
        gpup_create_sampler(d, ptr) {
            const w = ui.u32(ptr, 9);
            const desc = {
                addressModeU: addressModes[w[0]], addressModeV: addressModes[w[1]], addressModeW: addressModes[w[2]],
                magFilter: filters[w[3]], minFilter: filters[w[4]], mipmapFilter: filters[w[5]],
                lodMinClamp: f32(w[6]), lodMaxClamp: f32(w[7]),
            };
            if (w[8]) desc.compare = compares[w[8] - 1];
            return put(get(d).createSampler(desc));
        },
        gpup_create_render_pipeline(d, wgsl, wgsl_len, ptr, len) {
            const device = get(d);
            const w = ui.u32(ptr, len);
            let i = 0;
            const next = () => w[i++];
            const module = device.createShaderModule({ code: ui.str(wgsl, wgsl_len) });
            const vs = ui.str(next(), next());
            const fsPtr = next(), fsLen = next();
            const primitive = { topology: topologies[next()] };
            const strip = next();
            if (strip) primitive.stripIndexFormat = indexFormats[strip - 1];
            primitive.frontFace = frontFaces[next()];
            primitive.cullMode = cullModes[next()];
            const multisample = { count: next(), mask: next(), alphaToCoverageEnabled: next() !== 0 };
            const buffers = [];
            for (let b = 0, nb = next(); b < nb; b++) {
                const arrayStride = next(), stepMode = next() ? "instance" : "vertex", attributes = [];
                for (let a = 0, na = next(); a < na; a++) attributes.push({ format: vertexFormats[next()], offset: next(), shaderLocation: next() });
                buffers.push({ arrayStride, stepMode, attributes });
            }
            const targets = [];
            for (let t = 0, nt = next(); t < nt; t++) {
                const format = formats[next()], blended = next();
                const color = { operation: operations[next()], srcFactor: factors[next()], dstFactor: factors[next()] };
                const alpha = { operation: operations[next()], srcFactor: factors[next()], dstFactor: factors[next()] };
                const mask = next();
                // Zig's ColorWriteMask is red, green, blue, alpha from bit 0; WebGPU's is the same.
                targets.push(blended ? { format, blend: { color, alpha }, writeMask: mask } : { format, writeMask: mask });
            }
            const desc = { layout: "auto", vertex: { module, entryPoint: vs, buffers }, primitive, multisample };
            if (fsLen) desc.fragment = { module, entryPoint: ui.str(fsPtr, fsLen), targets };
            return put(device.createRenderPipeline(desc));
        },
        gpup_create_compute_pipeline(d, wgsl, wgsl_len, entry, entry_len) {
            const device = get(d);
            const module = device.createShaderModule({ code: ui.str(wgsl, wgsl_len) });
            return put(device.createComputePipeline({ layout: "auto", compute: { module, entryPoint: ui.str(entry, entry_len) } }));
        },
        gpup_create_bind_group(d, p, group, ptr, count) {
            const w = ui.u32(ptr, count * 3);
            const entries = [];
            for (let i = 0; i < count; i++) {
                const [binding, kind, h] = [w[i * 3], w[i * 3 + 1], w[i * 3 + 2]];
                entries.push({ binding, resource: kind === 0 ? { buffer: get(h) } : get(h) });
            }
            return put(get(d).createBindGroup({ layout: get(p).getBindGroupLayout(group), entries }));
        },
        gpup_write_texture(q, t, ptr, len, bytesPerRow, w, h) {
            get(q).writeTexture({ texture: get(t) }, ui.u8(ptr, len), { bytesPerRow, rowsPerImage: h }, [w, h]);
        },
        gpup_begin_render_pass(e, ptr, count) {
            const w = ui.u32(ptr, count * 8);
            const colorAttachments = [];
            for (let i = 0; i < count; i++) {
                const o = i * 8;
                const a = { view: get(w[o]), loadOp: w[o + 2] ? "clear" : "load", storeOp: w[o + 3] ? "discard" : "store", clearValue: [f32(w[o + 4]), f32(w[o + 5]), f32(w[o + 6]), f32(w[o + 7])] };
                if (w[o + 1]) a.resolveTarget = get(w[o + 1]);
                colorAttachments.push(a);
            }
            return put(get(e).beginRenderPass({ colorAttachments }));
        },
        gpup_end_pass(p) {
            get(p).end();
            ui.gpu.release(p);
        },
        gpup_set_index_buffer: (p, b, format, offset) => get(p).setIndexBuffer(get(b), indexFormats[format], offset),
        gpup_set_viewport: (p, x, y, w, h, min, max) => get(p).setViewport(x, y, w, h, min, max),
        gpup_set_scissor: (p, x, y, w, h) => get(p).setScissorRect(x, y, w, h),
        gpup_set_blend_constant: (p, r, g, b, a) => get(p).setBlendConstant([r, g, b, a]),
        gpup_draw_indexed: (p, n, instances, first, base, firstInstance) => get(p).drawIndexed(n, instances, first, base, firstInstance),
        gpup_begin_compute_pass: (e) => put(get(e).beginComputePass()),
        gpup_dispatch: (p, x, y, z) => get(p).dispatchWorkgroups(x, y, z),
    };
}

/// The 2D-canvas fallback for canvas.zig: `load(url, canvas2d(canvasElement))`. `present`
/// copies the module's framebuffer onto the canvas, resizing the canvas to it. The 2D context
/// is taken on the first present, so a page that draws with WebGPU instead can link this too.
export function canvas2d(canvas) {
    let ctx = null; // taken at the first present: a canvas has one kind of context for life
    return (ui) => ({
        canvas_put(ptr, stride, w, h) {
            ctx ??= canvas.getContext("2d");
            if (canvas.width !== w || canvas.height !== h) [canvas.width, canvas.height] = [w, h];
            const px = new Uint8ClampedArray(ui.exports.memory.buffer, ptr, stride * h * 4);
            ctx.putImageData(new ImageData(px, stride, h), 0, 0, 0, 0, w, h);
        },
    });
}
