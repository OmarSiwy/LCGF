// Helpers shared by the test pages; not part of the glue a real page loads.

/// RGBA8 rows of `texture` (w x h), without WebGPU's 256-byte row padding.
export async function readback(device, texture, w, h) {
    const stride = Math.ceil((w * 4) / 256) * 256;
    const buf = device.createBuffer({ size: stride * h, usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ });
    const encoder = device.createCommandEncoder();
    encoder.copyTextureToBuffer({ texture }, { buffer: buf, bytesPerRow: stride }, [w, h]);
    device.queue.submit([encoder.finish()]);
    await buf.mapAsync(GPUMapMode.READ);
    const padded = new Uint8Array(buf.getMappedRange());
    const out = new Uint8Array(w * h * 4);
    for (let y = 0; y < h; y++) out.set(padded.subarray(y * stride, y * stride + w * 4), y * w * 4);
    buf.destroy();
    return out;
}

export function base64(bytes) {
    let s = "";
    for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    return btoa(s);
}

/// render.py's stand-in glyph atlas: 16x16 cells of 4x4 texels, every printable byte a 2x3
/// block of opaque white.
export function standInAtlas() {
    const px = new Uint8Array(64 * 64 * 4);
    for (let byte = 33; byte < 127; byte++)
        for (let y = 1; y < 4; y++)
            for (let x = 1; x < 3; x++) px.fill(255, (((byte >> 4) * 4 + y) * 64 + (byte & 15) * 4 + x) * 4, (((byte >> 4) * 4 + y) * 64 + (byte & 15) * 4 + x) * 4 + 4);
    return px;
}
