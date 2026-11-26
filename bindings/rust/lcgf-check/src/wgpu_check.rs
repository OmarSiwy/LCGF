//! `lcgf::gpu` on wgpu-native (feature `wgpu`): check.zig's checks (gpu_checks.rs) on a real
//! adapter (Mesa lavapipe through wgpu's Vulkan back end in CI), over the repository's WGSL as
//! wgpu takes it. `--layout` prints the webgpu.h struct layouts the crate declares instead, for
//! run.sh to compare with the C header's (wgpu_layout.c).
//!
//!   lcgf-wgpu-check [--layout]   (prints "skip" and exits 0 when there is no adapter)

mod gpu_checks;
mod wgpu_layout;

use core::ffi::c_void;
use lcgf::gpu::{self, ffi::*};

// What only the host calls: an instance, an adapter and a device (webgpu.h, wgpu.h).
type RequestCallback = unsafe extern "C" fn(
    status: u32,
    handle: *mut c_void,
    message: WGPUStringView,
    ud1: *mut c_void,
    ud2: *mut c_void,
);
#[repr(C)]
struct RequestCallbackInfo {
    next_in_chain: *mut WGPUChainedStruct,
    mode: u32,
    callback: RequestCallback,
    userdata1: *mut c_void,
    userdata2: *mut c_void,
}
#[repr(C)]
struct InstanceDescriptor {
    next_in_chain: *const WGPUChainedStruct,
    required_feature_count: usize,
    required_features: *const c_void,
    required_limits: *const c_void,
}
/// WGPUInstanceExtras (wgpu.h): 112 bytes, the chain first and `backends` at 16; the rest zero.
#[repr(C)]
struct InstanceExtras {
    chain: WGPUChainedStruct,
    backends: u64,
    rest: [u64; 11],
}
const _: () = assert!(size_of::<InstanceExtras>() == 112);
#[link(name = "wgpu_native")]
unsafe extern "C" {
    fn wgpuCreateInstance(d: *const InstanceDescriptor) -> WGPUInstance;
    fn wgpuInstanceRequestAdapter(
        i: WGPUInstance,
        options: *const c_void,
        cb: RequestCallbackInfo,
    ) -> WGPUFuture;
    fn wgpuAdapterRequestDevice(
        a: WGPUAdapter,
        d: *const c_void,
        cb: RequestCallbackInfo,
    ) -> WGPUFuture;
    fn wgpuDeviceGetQueue(d: WGPUDevice) -> WGPUQueue;
}

unsafe extern "C" fn on_request(
    _status: u32,
    handle: *mut c_void,
    _m: WGPUStringView,
    ud: *mut c_void,
    _: *mut c_void,
) {
    unsafe { *ud.cast::<Option<*mut c_void>>() = Some(handle) };
}

/// An instance on wgpu's Vulkan back end, its first adapter and a device on it.
fn setup() -> Option<gpu::Device<'static>> {
    unsafe {
        let extras = InstanceExtras {
            chain: WGPUChainedStruct {
                next: core::ptr::null_mut(),
                sType: WGPUSType_InstanceExtras,
            },
            backends: WGPUInstanceBackend_Vulkan,
            rest: [0; 11],
        };
        let instance = wgpuCreateInstance(&InstanceDescriptor {
            next_in_chain: &extras.chain,
            required_feature_count: 0,
            required_features: core::ptr::null(),
            required_limits: core::ptr::null(),
        });
        if instance.is_null() {
            return None;
        }
        let info = |got: &mut Option<*mut c_void>| RequestCallbackInfo {
            next_in_chain: core::ptr::null_mut(),
            mode: WGPUCallbackMode_AllowProcessEvents,
            callback: on_request,
            userdata1: (got as *mut Option<*mut c_void>).cast(),
            userdata2: core::ptr::null_mut(),
        };
        let mut adapter = None;
        wgpuInstanceRequestAdapter(instance, core::ptr::null(), info(&mut adapter));
        for _ in 0..10_000 {
            if adapter.is_some() {
                break;
            }
            wgpuInstanceProcessEvents(instance);
        }
        let adapter = adapter.filter(|a| !a.is_null())?;
        let mut device = None;
        wgpuAdapterRequestDevice(adapter, core::ptr::null(), info(&mut device));
        for _ in 0..10_000 {
            if device.is_some() {
                break;
            }
            wgpuInstanceProcessEvents(instance);
        }
        let device = device.filter(|d| !d.is_null())?;
        Some(gpu::Device::wrap(
            device,
            wgpuDeviceGetQueue(device),
            instance,
        ))
    }
}

/// check.zig's host on wgpu-native: one command encoder per upload, submitted whole.
struct WgpuHost<'a> {
    d: gpu::Device<'a>,
    encoder: WGPUCommandEncoder,
}

impl gpu_checks::Host for WgpuHost<'_> {
    fn upload<'s>(&'s mut self, staging: Option<&'s mut gpu::Staging>) -> gpu::Upload<'s> {
        self.encoder = unsafe { wgpuDeviceCreateCommandEncoder(self.d.device, core::ptr::null()) };
        match staging {
            Some(s) => gpu::Upload::with_staging(&self.d, self.encoder, s),
            None => gpu::Upload::new(&self.d, self.encoder),
        }
    }
    fn submit(&mut self) -> bool {
        self.d.submit_encoder(self.encoder);
        true
    }
    fn read_texture(&mut self, t: &gpu::Texture, out: &mut [u8]) -> bool {
        self.d.read_texture(t, out).is_ok()
    }
    fn read_buffer(&mut self, b: &gpu::Buffer, out: &mut [u8]) -> bool {
        self.d.read_buffer(b, 0, out).is_ok()
    }
}

fn main() {
    if std::env::args().nth(1).as_deref() == Some("--layout") {
        wgpu_layout::print();
        return;
    }
    let Some(d) = setup() else {
        println!("skip: no wgpu adapter");
        return;
    };
    let mut h = WgpuHost {
        d,
        encoder: core::ptr::null_mut(),
    };
    let rtt = gpu_checks::render_to_texture(&d, &mut h).unwrap();
    let cs = gpu_checks::compute(&d, &mut h).unwrap();
    println!(
        "{} render-to-texture, {} compute (Rust lcgf::gpu on wgpu-native)",
        if rtt { "ok  " } else { "FAIL" },
        if cs { "ok  " } else { "FAIL" }
    );
    std::process::exit(if rtt && cs { 0 } else { 1 });
}
