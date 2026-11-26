//! `lcgf::gpu` on GL ES (feature `gles`): check.zig's checks (gpu_checks.rs) on a real driver
//! (Mesa llvmpipe in CI), through a headless EGL context, over shaders `include_shader!` made
//! from the repository's WGSL with naga's GLSL ES. The compute check needs GL ES 3.1 and is
//! reported as skipped without it.
//!
//!   lcgf-gles-check      (prints "skip" and exits 0 when there is no EGL / GL ES 3 driver)

mod gpu_checks;

use core::ffi::{CStr, c_char, c_int, c_void};
use lcgf::gpu::{self, gl};

unsafe extern "C" {
    fn dlopen(name: *const c_char, flags: c_int) -> *mut c_void;
    fn dlsym(lib: *mut c_void, name: *const c_char) -> *mut c_void;
}

type Display = *mut c_void;
const NONE: i32 = 0x3038;
const EXTENSIONS: i32 = 0x3055;

/// EGL, as much as a headless context takes (Khronos's values; no EGL crate needed).
struct Egl {
    get_proc_address: unsafe extern "C" fn(*const c_char) -> *const c_void,
}

fn has(list: *const c_char, name: &str) -> bool {
    !list.is_null()
        && unsafe { CStr::from_ptr(list) }
            .to_str()
            .unwrap_or("")
            .split(' ')
            .any(|w| w == name)
}

/// A GL ES 3.1 context if the driver has one, else 3.0, current on this thread.
fn setup() -> Option<(Egl, i32)> {
    unsafe {
        let lib = dlopen(c"libEGL.so.1".as_ptr(), 2);
        if lib.is_null() {
            return None;
        }
        macro_rules! sym {
            ($name:literal: $ty:ty) => {{
                let p = dlsym(lib, $name.as_ptr());
                if p.is_null() {
                    None
                } else {
                    Some(core::mem::transmute::<*mut c_void, $ty>(p))
                }
            }};
        }
        let get_proc_address =
            sym!(c"eglGetProcAddress": unsafe extern "C" fn(*const c_char) -> *const c_void)?;
        let get_display = sym!(c"eglGetDisplay": unsafe extern "C" fn(*mut c_void) -> Display)?;
        let get_platform_display = sym!(c"eglGetPlatformDisplay": unsafe extern "C" fn(u32, *mut c_void, *const isize) -> Display);
        let initialize =
            sym!(c"eglInitialize": unsafe extern "C" fn(Display, *mut i32, *mut i32) -> u32)?;
        let query_string =
            sym!(c"eglQueryString": unsafe extern "C" fn(Display, i32) -> *const c_char)?;
        let bind_api = sym!(c"eglBindAPI": unsafe extern "C" fn(u32) -> u32)?;
        let choose_config = sym!(c"eglChooseConfig": unsafe extern "C" fn(Display, *const i32, *mut *mut c_void, i32, *mut i32) -> u32)?;
        let create_context = sym!(c"eglCreateContext": unsafe extern "C" fn(Display, *mut c_void, *mut c_void, *const i32) -> *mut c_void)?;
        let create_pbuffer = sym!(c"eglCreatePbufferSurface": unsafe extern "C" fn(Display, *mut c_void, *const i32) -> *mut c_void)?;
        let make_current = sym!(c"eglMakeCurrent": unsafe extern "C" fn(Display, *mut c_void, *mut c_void, *mut c_void) -> u32)?;
        let mut dpy = core::ptr::null_mut();
        if let Some(gpd) = get_platform_display {
            if has(
                query_string(core::ptr::null_mut(), EXTENSIONS),
                "EGL_MESA_platform_surfaceless",
            ) {
                dpy = gpd(0x31DD, core::ptr::null_mut(), core::ptr::null());
            }
        }
        if dpy.is_null() {
            dpy = get_display(core::ptr::null_mut());
        }
        if dpy.is_null()
            || initialize(dpy, core::ptr::null_mut(), core::ptr::null_mut()) == 0
            || bind_api(0x30A0) == 0
        {
            return None;
        }
        let attrs = [
            0x3040, 0x0040, 0x3033, 0x0001, 0x3024, 8, 0x3023, 8, 0x3022, 8, 0x3021, 8, NONE,
        ];
        let (mut config, mut n) = (core::ptr::null_mut(), 0);
        if choose_config(dpy, attrs.as_ptr(), &mut config, 1, &mut n) == 0 || n == 0 {
            return None;
        }
        let (mut ctx, mut minor): (*mut c_void, i32) = (core::ptr::null_mut(), 1);
        while ctx.is_null() && minor >= 0 {
            let ca = [0x3098, 3, 0x30FB, minor, NONE];
            ctx = create_context(dpy, config, core::ptr::null_mut(), ca.as_ptr());
            if ctx.is_null() {
                minor -= 1;
            }
        }
        if ctx.is_null() {
            return None;
        }
        let mut surface = core::ptr::null_mut();
        if !has(query_string(dpy, EXTENSIONS), "EGL_KHR_surfaceless_context") {
            let pa = [0x3057, 1, 0x3056, 1, NONE];
            surface = create_pbuffer(dpy, config, pa.as_ptr());
        }
        (make_current(dpy, surface, surface, ctx) != 0).then_some((Egl { get_proc_address }, minor))
    }
}

/// check.zig's host on GL ES: the current context; readback through the texture's framebuffer.
struct GlesHost<'a> {
    d: gpu::Device<'a>,
}

impl GlesHost<'_> {
    fn clean(&self) -> bool {
        let mut ok = true;
        while unsafe { (self.d.fns.get_error)() } != gl::NO_ERROR {
            ok = false;
        }
        ok
    }
}

impl gpu_checks::Host for GlesHost<'_> {
    fn upload<'s>(&'s mut self, staging: Option<&'s mut gpu::Staging>) -> gpu::Upload<'s> {
        match staging {
            Some(s) => gpu::Upload::with_staging(&self.d, s),
            None => gpu::Upload::new(&self.d),
        }
    }
    fn submit(&mut self) -> bool {
        unsafe { (self.d.fns.finish)() };
        self.clean()
    }
    fn read_texture(&mut self, t: &gpu::Texture, out: &mut [u8]) -> bool {
        let f = self.d.fns;
        unsafe {
            (f.bind_framebuffer)(gl::FRAMEBUFFER, t.fbo);
            (f.pixel_storei)(gl::PACK_ALIGNMENT, 1);
            (f.read_pixels)(
                0,
                0,
                t.width as i32,
                t.height as i32,
                gl::RGBA,
                gl::UNSIGNED_BYTE,
                out.as_mut_ptr().cast(),
            );
            (f.bind_framebuffer)(gl::FRAMEBUFFER, 0);
        }
        self.clean()
    }
    fn read_buffer(&mut self, b: &gpu::Buffer, out: &mut [u8]) -> bool {
        self.d.read_buffer(b, 0, out);
        self.clean()
    }
}

fn main() {
    let Some((egl, minor)) = setup() else {
        println!("skip: no GL ES 3 driver");
        return;
    };
    let Some(fns) = (unsafe { gpu::GlFns::load(|name| (egl.get_proc_address)(name.as_ptr())) })
    else {
        println!("skip: no GL ES 3 driver");
        return;
    };
    let d = gpu::Device { fns: &fns };
    let mut h = GlesHost { d };
    let rtt = gpu_checks::render_to_texture(&d, &mut h).unwrap();
    let compute = minor >= 1 && fns.has_compute();
    let cs = compute && gpu_checks::compute(&d, &mut h).unwrap();
    println!(
        "{} render-to-texture, {} compute (Rust lcgf::gpu on GL ES 3.{minor})",
        if rtt { "ok  " } else { "FAIL" },
        if !compute {
            "skip"
        } else if cs {
            "ok  "
        } else {
            "FAIL"
        }
    );
    std::process::exit(if rtt && (cs || !compute) { 0 } else { 1 });
}
