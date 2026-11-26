//! `lcgf::gpu` on Metal (`metal`): check.zig's checks (gpu_checks.rs) on the system's Metal
//! device, over the repository's WGSL as naga's MSL. Exits 0 when both pass. Without Metal
//! (Linux, or a VM with no GPU) it prints "skip" and exits 0.
//!
//!   lcgf-metal-device-check

mod gpu_checks;

use lcgf::gpu;
use lcgf::gpu::objc::{self, Id};
use lcgf::objc_send as send;

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct MTLSize {
    width: usize,
    height: usize,
    depth: usize,
}

/// check.zig's host on Metal: one command buffer per submission, readback through a blit into
/// shared memory (the projection's device textures and buffers are private).
struct MetalHost<'a> {
    d: gpu::Device<'a>,
    queue: Id,
    own: gpu::Staging,
    cmd: Id,
}

impl MetalHost<'_> {
    fn readback(&mut self, out: &mut [u8], copy: impl FnOnce(Id, Id)) -> bool {
        unsafe {
            let shared: Id = send!(Id; self.d.device, "newBufferWithLength:options:", out.len() => usize, 0 => usize);
            let c: Id = send!(Id; self.queue, "commandBuffer");
            let blit: Id = send!(Id; c, "blitCommandEncoder");
            copy(blit, shared);
            send!((); blit, "endEncoding");
            send!((); c, "commit");
            send!((); c, "waitUntilCompleted");
            let p: *const u8 = send!(*const u8; shared, "contents");
            out.copy_from_slice(std::slice::from_raw_parts(p, out.len()));
            objc::release(shared);
        }
        true
    }
}

impl gpu_checks::Host for MetalHost<'_> {
    fn upload<'s>(&'s mut self, staging: Option<&'s mut gpu::Staging>) -> gpu::Upload<'s> {
        self.cmd = unsafe { send!(Id; self.queue, "commandBuffer") };
        gpu::Upload::with_staging(&self.d, self.cmd, staging.unwrap_or(&mut self.own))
    }
    fn submit(&mut self) -> bool {
        unsafe {
            send!((); self.cmd, "commit");
            send!((); self.cmd, "waitUntilCompleted");
        }
        self.own.rewind();
        true
    }
    fn read_texture(&mut self, t: &gpu::Texture, out: &mut [u8]) -> bool {
        let (texture, w, h) = (t.texture, t.width as usize, t.height as usize);
        self.readback(out, |blit, to| unsafe {
            send!((); blit, "copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toBuffer:destinationOffset:destinationBytesPerRow:destinationBytesPerImage:",
                texture => Id, 0 => usize, 0 => usize, MTLSize::default() => MTLSize, MTLSize { width: w, height: h, depth: 1 } => MTLSize,
                to => Id, 0 => usize, w * 4 => usize, w * h * 4 => usize)
        })
    }
    fn read_buffer(&mut self, b: &gpu::Buffer, out: &mut [u8]) -> bool {
        let (src, n) = (b.handle, out.len());
        self.readback(out, |blit, to| unsafe {
            send!((); blit, "copyFromBuffer:sourceOffset:toBuffer:destinationOffset:size:",
                src => Id, 0 => usize, to => Id, 0 => usize, n => usize)
        })
    }
}

fn main() {
    if !objc::load() {
        println!("skip: no Objective-C runtime and Metal (not macOS)");
        return;
    }
    let _pool = objc::Pool::push();
    let device = objc::create_system_default_device();
    if device.is_null() {
        println!("skip: no Metal device");
        return;
    }
    let d = gpu::Device::wrap(device);
    let mut host = d.create_arena(1 << 16, gpu::MemoryKind::Host, 8).unwrap();
    let own = d.create_staging(&mut host, 1 << 16).unwrap();
    let queue: Id = unsafe { send!(Id; device, "newCommandQueue") };
    let mut h = MetalHost {
        d,
        queue,
        own,
        cmd: core::ptr::null_mut(),
    };
    let rtt = gpu_checks::render_to_texture(&d, &mut h).unwrap();
    let cs = gpu_checks::compute(&d, &mut h).unwrap();
    println!(
        "{} render-to-texture, {} compute (Rust lcgf::gpu on Metal)",
        if rtt { "ok  " } else { "FAIL" },
        if cs { "ok  " } else { "FAIL" }
    );
    std::process::exit(if rtt && cs { 0 } else { 1 });
}
