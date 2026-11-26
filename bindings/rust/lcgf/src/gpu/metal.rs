//! `lcgf::gpu` on Metal (feature `metal`): src/render/metal/gpu.zig, inline. WebGPU's object
//! model projected onto Metal, message for message: a type is a plain struct of Metal objects
//! with public fields (`pass.as_raw()` is the `MTLRenderCommandEncoder`, `buffer.handle` the
//! `MTLBuffer`, as on the other back ends). An [`objc::Id`] is Objective-C's `id`, so it converts to the `objc2` crates'
//! types by pointer at no cost, and nothing here depends on them. The Objective-C runtime and
//! Metal are opened at run time ([`objc::load`]), as the Zig back end does, so the crate builds
//! on any host and a program without Metal fails to load it instead of failing to start.
//!
//! Bind groups are the Metal objects bound at the slots lcgf-gen gave naga's MSL (the shader's
//! `METAL` table): buffers, textures and samplers flat per kind in (group, binding) order,
//! vertex buffers counted down from slot 30. `set_bind_group` binds a group's objects to both
//! stages. Runtime-sized storage arrays get their lengths through naga's `_buffer_sizes` slot
//! before each draw or dispatch that needs them.
//!
//! Metal tracks hazards between encoders for the resources it creates, so the phases need no
//! barriers: `Upload` is a blit encoder copying from the staging ring (queue-ordered, like
//! WebGPU's `writeBuffer`), and each pass is its own encoder on the host's command buffer.
//!
//! bindings/check/run.sh records this module's messages and the Zig projection's through a
//! stand-in Objective-C runtime (bindings/check/objc_record.c) and requires the same log.

use super::*;
use core::ffi::{CStr, c_void};
use core::marker::PhantomData;
use core::ops::Range;

pub mod objc {
    //! The Objective-C runtime, reached without headers or link-time libraries: libobjc and
    //! Metal are opened at run time, and every message goes through `objc_msgSend` cast to the
    //! call's C signature ([`send!`](crate::objc_send)).
    use core::ffi::{CStr, c_char, c_int, c_void};

    pub type Id = *mut c_void;
    pub type Sel = *mut c_void;
    pub type NSUInteger = usize;
    pub type NSInteger = isize;

    /// libobjc's and Metal's entry points, once [`load`] has opened them.
    #[derive(Clone, Copy)]
    pub struct Runtime {
        pub msg_send: unsafe extern "C" fn(),
        pub get_class: unsafe extern "C" fn(*const c_char) -> Id,
        pub register_name: unsafe extern "C" fn(*const c_char) -> Sel,
        pub pool_push: unsafe extern "C" fn() -> *mut c_void,
        pub pool_pop: unsafe extern "C" fn(*mut c_void),
        pub create_system_default_device: unsafe extern "C" fn() -> Id,
    }

    static mut RUNTIME: Option<Runtime> = None;

    /// The runtime [`load`] opened.
    ///
    /// # Panics
    /// Before [`load`] succeeded.
    #[inline(always)]
    pub fn runtime() -> Runtime {
        // SAFETY: written once by `load`, before any message; only read after.
        unsafe { (*core::ptr::addr_of!(RUNTIME)).expect("lcgf::gpu::objc::load first") }
    }

    unsafe extern "C" {
        fn dlopen(path: *const c_char, mode: c_int) -> *mut c_void;
        fn dlsym(handle: *mut c_void, name: *const c_char) -> *mut c_void;
    }
    const RTLD_NOW: c_int = 2;

    /// Where [`load_from`] opens the runtime. The defaults are the system's; `None` QuartzCore
    /// is skipped (the projection itself needs no `CAMetalLayer`).
    pub struct Paths<'a> {
        pub objc: &'a CStr,
        pub metal: &'a CStr,
        pub quartz_core: Option<&'a CStr>,
    }

    impl Default for Paths<'_> {
        fn default() -> Self {
            Self {
                objc: c"/usr/lib/libobjc.A.dylib",
                metal: c"/System/Library/Frameworks/Metal.framework/Metal",
                quartz_core: Some(c"/System/Library/Frameworks/QuartzCore.framework/QuartzCore"),
            }
        }
    }

    /// Opens libobjc and Metal. Call once, before any other call here; later calls return at
    /// once. False off Apple platforms, or where a library or a function is missing.
    pub fn load() -> bool {
        load_from(&Paths::default())
    }

    /// [`load`] from other paths.
    pub fn load_from(p: &Paths<'_>) -> bool {
        // SAFETY: dlopen and dlsym with NUL-terminated names; the casts are the functions' C
        // signatures.
        unsafe {
            if (*core::ptr::addr_of!(RUNTIME)).is_some() {
                return true;
            }
            let o = dlopen(p.objc.as_ptr(), RTLD_NOW);
            let m = dlopen(p.metal.as_ptr(), RTLD_NOW);
            if o.is_null() || m.is_null() {
                return false;
            }
            if let Some(q) = p.quartz_core {
                if dlopen(q.as_ptr(), RTLD_NOW).is_null() {
                    return false;
                }
            }
            let f = |h: *mut c_void, name: &CStr| {
                let p = dlsym(h, name.as_ptr());
                (!p.is_null()).then_some(p)
            };
            let (Some(send), Some(class), Some(sel), Some(push), Some(pop), Some(device)) = (
                f(o, c"objc_msgSend"),
                f(o, c"objc_getClass"),
                f(o, c"sel_registerName"),
                f(o, c"objc_autoreleasePoolPush"),
                f(o, c"objc_autoreleasePoolPop"),
                f(m, c"MTLCreateSystemDefaultDevice"),
            ) else {
                return false;
            };
            RUNTIME = Some(Runtime {
                msg_send: core::mem::transmute::<*mut c_void, unsafe extern "C" fn()>(send),
                get_class: core::mem::transmute::<
                    *mut c_void,
                    unsafe extern "C" fn(*const c_char) -> Id,
                >(class),
                register_name: core::mem::transmute::<
                    *mut c_void,
                    unsafe extern "C" fn(*const c_char) -> Sel,
                >(sel),
                pool_push: core::mem::transmute::<*mut c_void, unsafe extern "C" fn() -> *mut c_void>(
                    push,
                ),
                pool_pop: core::mem::transmute::<*mut c_void, unsafe extern "C" fn(*mut c_void)>(
                    pop,
                ),
                create_system_default_device: core::mem::transmute::<
                    *mut c_void,
                    unsafe extern "C" fn() -> Id,
                >(device),
            });
            true
        }
    }

    /// A class by name.
    pub fn class(name: &CStr) -> Id {
        unsafe { (runtime().get_class)(name.as_ptr()) }
    }

    /// The system's default Metal device (`MTLCreateSystemDefaultDevice`).
    pub fn create_system_default_device() -> Id {
        unsafe { (runtime().create_system_default_device)() }
    }

    pub fn release(o: Id) {
        unsafe { crate::objc_send!((); o, "release") }
    }

    /// An autoreleased `NSString` with `s`'s bytes (UTF-8).
    pub fn string(s: &CStr) -> Id {
        unsafe {
            crate::objc_send!(Id; class(c"NSString"), "stringWithUTF8String:", s.as_ptr() => *const c_char)
        }
    }

    /// An autorelease pool until it is dropped: objects that methods return without `new`,
    /// `alloc` or `copy` in their names live until it pops.
    pub struct Pool(*mut c_void);

    impl Pool {
        pub fn push() -> Self {
            Self(unsafe { (runtime().pool_push)() })
        }
    }

    impl Drop for Pool {
        fn drop(&mut self) {
            unsafe { (runtime().pool_pop)(self.0) }
        }
    }
}

/// `objc_send!(R; target, "selector:with:", a => A, b => B)`: sends the message, `objc_msgSend`
/// cast to `extern "C" fn(Id, Sel, A, B) -> R`. Each selector is registered once, at its first
/// send. Unsafe: the types must be the method's.
#[macro_export]
#[doc(hidden)]
macro_rules! objc_send {
    ($r:ty; $target:expr, $sel:literal $(, $a:expr => $t:ty)* $(,)?) => {{
        static SEL: ::core::sync::atomic::AtomicPtr<::core::ffi::c_void> =
            ::core::sync::atomic::AtomicPtr::new(::core::ptr::null_mut());
        let rt = $crate::gpu::objc::runtime();
        let mut s = SEL.load(::core::sync::atomic::Ordering::Relaxed);
        if s.is_null() {
            s = (rt.register_name)(concat!($sel, "\0").as_ptr().cast());
            SEL.store(s, ::core::sync::atomic::Ordering::Relaxed);
        }
        let f: unsafe extern "C" fn($crate::gpu::objc::Id, $crate::gpu::objc::Sel $(, $t)*) -> $r =
            ::core::mem::transmute(rt.msg_send);
        f($target, s $(, $a)*)
    }};
}

use crate::objc_send as send;
use objc::{Id, NSInteger, NSUInteger as U};

/// What creation reports.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
    ShaderCompile,
    MissingEntryPoint,
    PipelineFailed,
    ResourceFailed,
    /// The shader was not built for Metal (no MSL).
    NoCode,
    IncompatibleMemory,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct MTLViewport {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    znear: f64,
    zfar: f64,
}
#[repr(C)]
#[derive(Clone, Copy)]
struct MTLScissorRect {
    x: U,
    y: U,
    width: U,
    height: U,
}
#[repr(C)]
#[derive(Clone, Copy)]
struct MTLSize {
    width: U,
    height: U,
    depth: U,
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
struct MTLOrigin {
    x: U,
    y: U,
    z: U,
}
#[repr(C)]
#[derive(Clone, Copy)]
struct MTLClearColor {
    r: f64,
    g: f64,
    b: f64,
    a: f64,
}

const STORAGE_SHARED: U = 0;
const STORAGE_PRIVATE: U = 2 << 4;
const MAX_SIZED: usize = 8;
const MAX_BINDINGS: usize = 16;

fn vertex_buffer_slot(slot: u32) -> U {
    30 - slot as U
}

/// The host's `MTLDevice`. Upload from the staging ring given to [`Upload::with_staging`], or
/// set `staging` for [`Upload::new`].
#[derive(Clone, Copy)]
pub struct Device<'a> {
    pub device: Id,
    pub staging: *mut Staging,
    pub _host: PhantomData<&'a ()>,
}

impl Device<'_> {
    pub fn wrap(device: Id) -> Self {
        Self {
            device,
            staging: core::ptr::null_mut(),
            _host: PhantomData,
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub struct Buffer {
    pub handle: Id,
    pub size: u64,
    /// Set in a host arena (shared storage).
    pub mapped: *mut u8,
}

impl Buffer {
    /// The buffer from `range.start`, as `wgpu::Buffer::slice`.
    pub fn slice(&self, range: core::ops::RangeFrom<u64>) -> BufferSlice<'_> {
        BufferSlice {
            buffer: self,
            offset: range.start,
        }
    }
}

#[derive(Clone, Copy)]
pub struct BufferSlice<'a> {
    pub buffer: &'a Buffer,
    pub offset: u64,
}

#[derive(Clone, Copy, Debug)]
pub struct TextureView {
    pub texture: Id,
    pub width: u32,
    pub height: u32,
    pub samples: u32,
    pub format: TextureFormat,
}

#[derive(Clone, Copy, Debug)]
pub struct Texture {
    pub texture: Id,
    pub format: TextureFormat,
    pub width: u32,
    pub height: u32,
    pub samples: u32,
}

impl Texture {
    pub fn create_view(&self) -> TextureView {
        TextureView {
            texture: self.texture,
            width: self.width,
            height: self.height,
            samples: self.samples,
            format: self.format,
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub struct Sampler {
    pub handle: Id,
}

/// A pipeline and what its passes need from its shader: the primitive, cull mode and winding
/// the encoder is set to, and its runtime-sized arrays.
#[derive(Clone, Copy, Debug)]
pub struct RenderPipeline {
    pub state: Id,
    pub primitive: U,
    pub cull: U,
    pub winding: U,
    pub sized: u32,
    pub sizes_slot: u32,
}

#[derive(Clone, Copy, Debug)]
pub struct ComputePipeline {
    pub state: Id,
    pub threads: [u32; 3],
    pub sized: u32,
    pub sizes_slot: u32,
}

/// A pipeline made for shader `S`: bind groups of `S`'s groups go with it, others do not compile.
pub struct RenderPipelineOf<S> {
    pub raw: RenderPipeline,
    _s: PhantomData<S>,
}
pub struct ComputePipelineOf<S> {
    pub raw: ComputePipeline,
    _s: PhantomData<S>,
}
impl<S> core::ops::Deref for RenderPipelineOf<S> {
    type Target = RenderPipeline;
    fn deref(&self) -> &RenderPipeline {
        &self.raw
    }
}
impl<S> core::ops::Deref for ComputePipelineOf<S> {
    type Target = ComputePipeline;
    fn deref(&self) -> &ComputePipeline {
        &self.raw
    }
}

/// The pipelines a bind group can be made for: either kind, tied to its shader.
pub trait PipelineOf {
    type Shader: ShaderSource;
}
impl<S: ShaderSource> PipelineOf for RenderPipelineOf<S> {
    type Shader = S;
}
impl<S: ShaderSource> PipelineOf for ComputePipelineOf<S> {
    type Shader = S;
}

/// One binding of a group: its object, slot and buffer size.
#[derive(Clone, Copy, Debug)]
pub struct BindEntry {
    pub object: Id,
    pub kind: BindingKind,
    pub slot: u32,
    pub sized: u32,
    pub size: u64,
}

impl BindEntry {
    const EMPTY: Self = Self {
        object: core::ptr::null_mut(),
        kind: BindingKind::Uniform,
        slot: 0,
        sized: u32::MAX,
        size: 0,
    };
}

/// A group's Metal objects in binding order, with their slots and buffers' sizes.
#[derive(Clone, Copy, Debug)]
pub struct BindGroup<const G: u32> {
    pub entries: [BindEntry; MAX_BINDINGS],
    pub count: u32,
}

impl<const G: u32> Default for BindGroup<G> {
    fn default() -> Self {
        Self {
            entries: [BindEntry::EMPTY; MAX_BINDINGS],
            count: 0,
        }
    }
}

/// The bind group type a generated `GroupN` makes.
pub trait GroupOf {
    fn entries_mut(&mut self) -> (&mut [BindEntry; MAX_BINDINGS], &mut u32);
}
impl<const G: u32> GroupOf for BindGroup<G> {
    fn entries_mut(&mut self) -> (&mut [BindEntry; MAX_BINDINGS], &mut u32) {
        (&mut self.entries, &mut self.count)
    }
}

/// One resource of a bind group, as a generated `GroupN` lists them.
#[derive(Clone, Copy, Debug)]
pub struct Resource {
    pub binding: u32,
    pub kind: BindingKind,
    pub object: Id,
    pub size: u64,
}

impl Resource {
    pub const EMPTY: Self = Self {
        binding: 0,
        kind: BindingKind::Uniform,
        object: core::ptr::null_mut(),
        size: 0,
    };
    pub fn buffer(binding: u32, kind: BindingKind, b: &Buffer) -> Self {
        Self {
            binding,
            kind,
            object: b.handle,
            size: b.size,
        }
    }
    pub fn view(binding: u32, kind: BindingKind, v: &TextureView) -> Self {
        Self {
            binding,
            kind,
            object: v.texture,
            size: 0,
        }
    }
    pub fn sampler(binding: u32, kind: BindingKind, s: &Sampler) -> Self {
        Self {
            binding,
            kind,
            object: s.handle,
            size: 0,
        }
    }
}

/// A generated `GroupN`: the shader it belongs to, its index, and its resources.
pub trait Group {
    type Shader: ShaderSource;
    type BindGroup: GroupOf + Default;
    const INDEX: u32;
    /// Writes the resources into `out`; returns how many.
    fn resources(&self, out: &mut [Resource; 16]) -> usize;
}

/// What memory resources are made in: a device arena makes private storage, a host arena
/// shared and mapped. Each resource is its own allocation.
pub struct Arena {
    pub kind: MemoryKind,
}

/// A shared buffer the frame's writes copy from, on the queue. One per frame in flight;
/// `rewind` it when that frame's previous use has completed.
pub struct Staging {
    pub buffer: Buffer,
    pub used: u64,
}

impl Staging {
    pub fn rewind(&mut self) {
        self.used = 0;
    }
    fn push(&mut self, data: &[u8], alignment: u64) -> Option<u64> {
        let at = self.used.next_multiple_of(alignment);
        if at + data.len() as u64 > self.buffer.size {
            return None;
        }
        // SAFETY: the staging buffer is shared and mapped, `buffer.size` bytes long.
        unsafe {
            core::ptr::copy_nonoverlapping(
                data.as_ptr(),
                self.buffer.mapped.add(at as usize),
                data.len(),
            )
        };
        self.used = at + data.len() as u64;
        Some(at)
    }
}

#[derive(Clone, Copy)]
pub struct RenderPassColorAttachment<'a> {
    pub view: &'a TextureView,
    pub resolve_target: Option<&'a TextureView>,
    pub ops: Operations,
}

#[derive(Clone, Copy, Default)]
pub struct RenderPassDescriptor<'a> {
    pub color_attachments: &'a [Option<RenderPassColorAttachment<'a>>],
}

fn pixel_format(f: TextureFormat) -> U {
    use TextureFormat::*;
    match f {
        R8Unorm => 10,
        Rg8Unorm => 30,
        Rgba8Unorm => 70,
        Rgba8UnormSrgb => 71,
        Bgra8Unorm => 80,
        Bgra8UnormSrgb => 81,
        R16Float => 25,
        Rgba16Float => 115,
        R32Float => 55,
        Rg32Float => 105,
        Rgba32Float => 125,
        R32Uint => 53,
        Depth32Float => 252,
    }
}

fn vertex_format(f: VertexFormat) -> U {
    use VertexFormat::*;
    match f {
        Float32 => 28,
        Float32x2 => 29,
        Float32x3 => 30,
        Float32x4 => 31,
        Uint32 => 36,
        Uint32x2 => 37,
        Uint32x4 => 39,
        Sint32 => 32,
        Unorm8x4 => 9,
    }
}

fn blend_factor(f: BlendFactor) -> U {
    match f as U {
        n @ 0..=9 => n,
        n => n + 1, // Metal's 10 is SourceAlphaSaturated
    }
}

fn address_mode(a: AddressMode) -> U {
    match a {
        AddressMode::ClampToEdge => 0,
        AddressMode::Repeat => 2,
        AddressMode::MirrorRepeat => 3,
    }
}

fn compile(device: Id, msl: &str) -> Result<Id, Error> {
    if msl.is_empty() {
        return Err(Error::NoCode); // include_shader! gives every shader its MSL
    }
    let mut err: Id = core::ptr::null_mut();
    let src = objc::string(CStr::from_bytes_with_nul(msl.as_bytes()).map_err(|_| Error::NoCode)?);
    let lib: Id = unsafe {
        send!(Id; device, "newLibraryWithSource:options:error:", src => Id, core::ptr::null_mut() => Id, &mut err => *mut Id)
    };
    if lib.is_null() {
        return Err(Error::ShaderCompile);
    }
    Ok(lib)
}

/// An entry point by its WGSL name, or by naga's rename of it (`main` is `main_` in MSL).
fn function(library: Id, name: &CStr) -> Result<Id, Error> {
    let f: Id = unsafe { send!(Id; library, "newFunctionWithName:", objc::string(name) => Id) };
    if !f.is_null() {
        return Ok(f);
    }
    let mut buf = [0u8; 128];
    let n = name.to_bytes().len();
    if n + 2 > buf.len() {
        return Err(Error::MissingEntryPoint);
    }
    buf[..n].copy_from_slice(name.to_bytes());
    buf[n] = b'_';
    let renamed = CStr::from_bytes_until_nul(&buf).map_err(|_| Error::MissingEntryPoint)?;
    let f: Id = unsafe { send!(Id; library, "newFunctionWithName:", objc::string(renamed) => Id) };
    if f.is_null() {
        Err(Error::MissingEntryPoint)
    } else {
        Ok(f)
    }
}

// ---- the frame ------------------------------------------------------------------------------

/// The lengths of the bound runtime-sized arrays, for naga's `_buffer_sizes`.
#[derive(Clone, Copy, Default)]
struct Sizes {
    lengths: [u32; MAX_SIZED],
    count: u32,
    slot: u32,
}

impl Sizes {
    fn take(&mut self, entries: &[BindEntry]) {
        for e in entries {
            if (e.sized as usize) < MAX_SIZED {
                self.lengths[e.sized as usize] = e.size as u32;
            }
        }
    }
}

/// The write phase: a blit encoder on the host's command buffer, copying from the staging
/// ring. Made on the first write; `finish` consumes it.
pub struct Upload<'a> {
    cmd: Id,
    staging: *mut Staging,
    blit: Id,
    _d: PhantomData<&'a ()>,
}

impl<'a> Upload<'a> {
    /// An upload from the device's staging ring (`Device::staging`).
    pub fn new(device: &Device<'a>, cmd: Id) -> Self {
        assert!(
            !device.staging.is_null(),
            "lcgf::gpu (Metal): set Device::staging, or use Upload::with_staging"
        );
        Self {
            cmd,
            staging: device.staging,
            blit: core::ptr::null_mut(),
            _d: PhantomData,
        }
    }
    pub fn with_staging(_device: &Device<'a>, cmd: Id, staging: &'a mut Staging) -> Self {
        Self {
            cmd,
            staging,
            blit: core::ptr::null_mut(),
            _d: PhantomData,
        }
    }
    fn encoder(&mut self) -> Id {
        if self.blit.is_null() {
            self.blit = unsafe { send!(Id; self.cmd, "blitCommandEncoder") };
        }
        self.blit
    }
    pub fn write_buffer(&mut self, buffer: &Buffer, offset: u64, data: &[u8]) {
        debug_assert!(
            offset % 4 == 0 && data.len() % 4 == 0 && offset + data.len() as u64 <= buffer.size
        );
        // SAFETY: the staging ring outlives the upload (`'a`).
        let staging = unsafe { &mut *self.staging };
        let at = staging
            .push(data, 4)
            .expect("lcgf::gpu: the staging ring is full");
        let (src, enc) = (staging.buffer.handle, self.encoder());
        unsafe {
            send!((); enc, "copyFromBuffer:sourceOffset:toBuffer:destinationOffset:size:",
                src => Id, at as U => U, buffer.handle => Id, offset as U => U, data.len() as U => U)
        };
    }
    pub fn write_texture(&mut self, t: &Texture, data: &[u8], bytes_per_row: u32) -> bool {
        let staging = unsafe { &mut *self.staging };
        let Some(at) = staging.push(data, 256) else {
            return false;
        };
        let (src, enc) = (staging.buffer.handle, self.encoder());
        let size = MTLSize {
            width: t.width as U,
            height: t.height as U,
            depth: 1,
        };
        unsafe {
            send!((); enc, "copyFromBuffer:sourceOffset:sourceBytesPerRow:sourceBytesPerImage:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:",
                src => Id, at as U => U, bytes_per_row as U => U, data.len() as U => U, size => MTLSize,
                t.texture => Id, 0 => U, 0 => U, MTLOrigin::default() => MTLOrigin)
        };
        true
    }
    pub fn prepare(&mut self, _t: &Texture) {}
    pub fn finish(self) -> CommandEncoder<'a> {
        if !self.blit.is_null() {
            unsafe { send!((); self.blit, "endEncoding") };
        }
        CommandEncoder {
            cmd: self.cmd,
            _d: PhantomData,
        }
    }
    pub fn as_raw(&self) -> Id {
        self.cmd
    }
}

/// The draw phase of a frame: the host's command buffer. Made by `Upload::finish`.
pub struct CommandEncoder<'a> {
    cmd: Id,
    _d: PhantomData<&'a ()>,
}

impl<'a> CommandEncoder<'a> {
    pub fn begin_render_pass(&self, d: &RenderPassDescriptor<'_>) -> RenderPass<'a> {
        unsafe {
            let rp: Id = send!(Id; objc::class(c"MTLRenderPassDescriptor"), "renderPassDescriptor");
            let colors: Id = send!(Id; rp, "colorAttachments");
            let (mut w, mut h) = (0, 0);
            for (i, a) in d.color_attachments.iter().flatten().enumerate() {
                let color: Id = send!(Id; colors, "objectAtIndexedSubscript:", i as U => U);
                send!((); color, "setTexture:", a.view.texture => Id);
                let (load, clear) = match a.ops.load {
                    LoadOp::Clear(c) => (2, c),
                    LoadOp::Load => (1, Color::default()),
                };
                send!((); color, "setLoadAction:", load => U);
                let store = matches!(a.ops.store, StoreOp::Store);
                let action: U = match (a.resolve_target, store) {
                    (Some(_), true) => 3,
                    (Some(_), false) => 2,
                    (None, s) => s as U,
                };
                send!((); color, "setStoreAction:", action => U);
                if let Some(r) = a.resolve_target {
                    send!((); color, "setResolveTexture:", r.texture => Id);
                }
                let cc = MTLClearColor {
                    r: clear.r,
                    g: clear.g,
                    b: clear.b,
                    a: clear.a,
                };
                send!((); color, "setClearColor:", cc => MTLClearColor);
                (w, h) = (a.view.width, a.view.height);
            }
            RenderPass {
                encoder: send!(Id; self.cmd, "renderCommandEncoderWithDescriptor:", rp => Id),
                width: w,
                height: h,
                owned: true,
                primitive: 3,
                index: (core::ptr::null_mut(), 0, 0, 2),
                sizes: Sizes::default(),
                _d: PhantomData,
            }
        }
    }
    pub fn begin_compute_pass(&self) -> ComputePass<'a> {
        ComputePass {
            encoder: unsafe { send!(Id; self.cmd, "computeCommandEncoder") },
            threads: [1, 1, 1],
            sizes: Sizes::default(),
            _d: PhantomData,
        }
    }
    pub fn as_raw(&self) -> Id {
        self.cmd
    }
}

/// A render pass; it ends when dropped, as in wgpu.
pub struct RenderPass<'a> {
    encoder: Id,
    width: u32,
    height: u32,
    owned: bool,
    primitive: U,
    /// The index buffer, its type (0 uint16, 1 uint32), offset and index size.
    index: (Id, U, u64, u64),
    sizes: Sizes,
    _d: PhantomData<&'a ()>,
}

impl<'a> RenderPass<'a> {
    /// The pass the host is encoding (the UI's, for an inline custom draw); dropping it leaves
    /// it to the host.
    pub fn wrap(_device: &Device<'a>, encoder: Id, width: u32, height: u32) -> Self {
        Self {
            encoder,
            width,
            height,
            owned: false,
            primitive: 3,
            index: (core::ptr::null_mut(), 0, 0, 2),
            sizes: Sizes::default(),
            _d: PhantomData,
        }
    }
    pub fn set_pipeline(&mut self, p: &RenderPipeline) {
        let e = self.encoder;
        unsafe {
            send!((); e, "setRenderPipelineState:", p.state => Id);
            send!((); e, "setCullMode:", p.cull => U);
            send!((); e, "setFrontFacingWinding:", p.winding => U);
            send!((); e, "setTriangleFillMode:", 0 => U);
        }
        self.primitive = p.primitive;
        self.sizes.count = p.sized;
        self.sizes.slot = p.sizes_slot;
    }
    pub fn set_bind_group<const G: u32>(
        &mut self,
        index: u32,
        group: &BindGroup<G>,
        _offsets: &[u32],
    ) {
        debug_assert!(index == G, "bind group made for another @group");
        let e = self.encoder;
        for b in &group.entries[..group.count as usize] {
            let slot = b.slot as U;
            unsafe {
                match b.kind {
                    BindingKind::Uniform
                    | BindingKind::StorageRead
                    | BindingKind::StorageReadWrite => {
                        send!((); e, "setVertexBuffer:offset:atIndex:", b.object => Id, 0 => U, slot => U);
                        send!((); e, "setFragmentBuffer:offset:atIndex:", b.object => Id, 0 => U, slot => U);
                    }
                    BindingKind::Texture | BindingKind::StorageTexture => {
                        send!((); e, "setVertexTexture:atIndex:", b.object => Id, slot => U);
                        send!((); e, "setFragmentTexture:atIndex:", b.object => Id, slot => U);
                    }
                    BindingKind::Sampler | BindingKind::ComparisonSampler => {
                        send!((); e, "setVertexSamplerState:atIndex:", b.object => Id, slot => U);
                        send!((); e, "setFragmentSamplerState:atIndex:", b.object => Id, slot => U);
                    }
                }
            }
        }
        self.sizes.take(&group.entries[..group.count as usize]);
    }
    pub fn set_vertex_buffer(&mut self, slot: u32, slice: BufferSlice<'_>) {
        unsafe {
            send!((); self.encoder, "setVertexBuffer:offset:atIndex:",
                slice.buffer.handle => Id, slice.offset as U => U, vertex_buffer_slot(slot) => U)
        };
    }
    pub fn set_index_buffer(&mut self, slice: BufferSlice<'_>, format: IndexFormat) {
        let wide = format == IndexFormat::Uint32;
        self.index = (
            slice.buffer.handle,
            wide as U,
            slice.offset,
            if wide { 4 } else { 2 },
        );
    }
    pub fn set_viewport(&mut self, x: f32, y: f32, w: f32, h: f32, min_depth: f32, max_depth: f32) {
        let v = MTLViewport {
            x: x as f64,
            y: y as f64,
            width: w as f64,
            height: h as f64,
            znear: min_depth as f64,
            zfar: max_depth as f64,
        };
        unsafe { send!((); self.encoder, "setViewport:", v => MTLViewport) };
    }
    pub fn set_scissor_rect(&mut self, x: u32, y: u32, w: u32, h: u32) {
        debug_assert!(x + w <= self.width && y + h <= self.height);
        let r = MTLScissorRect {
            x: x as U,
            y: y as U,
            width: w as U,
            height: h as U,
        };
        unsafe { send!((); self.encoder, "setScissorRect:", r => MTLScissorRect) };
    }
    pub fn set_blend_constant(&mut self, c: Color) {
        unsafe {
            send!((); self.encoder, "setBlendColorRed:green:blue:alpha:",
                c.r as f32 => f32, c.g as f32 => f32, c.b as f32 => f32, c.a as f32 => f32)
        };
    }
    fn push_sizes(&mut self) {
        if self.sizes.count == 0 {
            return;
        }
        let (p, n, slot) = (
            self.sizes.lengths.as_ptr().cast::<c_void>(),
            self.sizes.count as U * 4,
            self.sizes.slot as U,
        );
        unsafe {
            send!((); self.encoder, "setVertexBytes:length:atIndex:", p => *const c_void, n => U, slot => U);
            send!((); self.encoder, "setFragmentBytes:length:atIndex:", p => *const c_void, n => U, slot => U);
        }
    }
    pub fn draw(&mut self, vertices: Range<u32>, instances: Range<u32>) {
        self.push_sizes();
        unsafe {
            send!((); self.encoder, "drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:",
                self.primitive => U, vertices.start as U => U, vertices.len() as U => U,
                instances.len() as U => U, instances.start as U => U)
        };
    }
    pub fn draw_indexed(&mut self, indices: Range<u32>, base_vertex: i32, instances: Range<u32>) {
        self.push_sizes();
        let (buffer, ty, offset, size) = self.index;
        unsafe {
            send!((); self.encoder, "drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:baseVertex:baseInstance:",
                self.primitive => U, indices.len() as U => U, ty => U, buffer => Id,
                (offset + indices.start as u64 * size) as U => U, instances.len() as U => U,
                base_vertex as NSInteger => NSInteger, instances.start as U => U)
        };
    }
    pub fn as_raw(&self) -> Id {
        self.encoder
    }
}

impl Drop for RenderPass<'_> {
    fn drop(&mut self) {
        if self.owned {
            unsafe { send!((); self.encoder, "endEncoding") };
        }
    }
}

/// A compute pass; it ends when dropped.
pub struct ComputePass<'a> {
    encoder: Id,
    threads: [u32; 3],
    sizes: Sizes,
    _d: PhantomData<&'a ()>,
}

impl ComputePass<'_> {
    pub fn set_pipeline(&mut self, p: &ComputePipeline) {
        unsafe { send!((); self.encoder, "setComputePipelineState:", p.state => Id) };
        self.threads = p.threads;
        self.sizes.count = p.sized;
        self.sizes.slot = p.sizes_slot;
    }
    pub fn set_bind_group<const G: u32>(
        &mut self,
        index: u32,
        group: &BindGroup<G>,
        _offsets: &[u32],
    ) {
        debug_assert!(index == G, "bind group made for another @group");
        let e = self.encoder;
        for b in &group.entries[..group.count as usize] {
            let slot = b.slot as U;
            unsafe {
                match b.kind {
                    BindingKind::Uniform
                    | BindingKind::StorageRead
                    | BindingKind::StorageReadWrite => {
                        send!((); e, "setBuffer:offset:atIndex:", b.object => Id, 0 => U, slot => U)
                    }
                    BindingKind::Texture | BindingKind::StorageTexture => {
                        send!((); e, "setTexture:atIndex:", b.object => Id, slot => U)
                    }
                    BindingKind::Sampler | BindingKind::ComparisonSampler => {
                        send!((); e, "setSamplerState:atIndex:", b.object => Id, slot => U)
                    }
                }
            }
        }
        self.sizes.take(&group.entries[..group.count as usize]);
    }
    pub fn dispatch_workgroups(&mut self, x: u32, y: u32, z: u32) {
        let e = self.encoder;
        unsafe {
            if self.sizes.count > 0 {
                send!((); e, "setBytes:length:atIndex:", self.sizes.lengths.as_ptr().cast::<c_void>() => *const c_void,
                    self.sizes.count as U * 4 => U, self.sizes.slot as U => U);
            }
            let groups = MTLSize {
                width: x as U,
                height: y as U,
                depth: z as U,
            };
            let threads = MTLSize {
                width: self.threads[0] as U,
                height: self.threads[1] as U,
                depth: self.threads[2] as U,
            };
            send!((); e, "dispatchThreadgroups:threadsPerThreadgroup:", groups => MTLSize, threads => MTLSize);
        }
    }
    pub fn as_raw(&self) -> Id {
        self.encoder
    }
}

impl Drop for ComputePass<'_> {
    fn drop(&mut self) {
        unsafe { send!((); self.encoder, "endEncoding") };
    }
}

// ---- creation ---------------------------------------------------------------------------------

impl Device<'_> {
    pub fn create_arena(
        &self,
        _bytes: u64,
        kind: MemoryKind,
        _bind_groups: u32,
    ) -> Result<Arena, Error> {
        Ok(Arena { kind })
    }
    pub fn destroy_arena(&self, _a: Arena) {}
    pub fn create_staging(&self, host: &mut Arena, bytes: u64) -> Result<Staging, Error> {
        if host.kind != MemoryKind::Host {
            return Err(Error::IncompatibleMemory);
        }
        let buffer = self.create_buffer(
            host,
            &BufferDescriptor {
                size: bytes,
                usage: BufferUsages::COPY_SRC,
            },
        )?;
        Ok(Staging { buffer, used: 0 })
    }
    pub fn destroy_staging(&self, s: Staging) {
        self.destroy_buffer(&s.buffer);
    }

    pub fn create_buffer(&self, arena: &mut Arena, d: &BufferDescriptor) -> Result<Buffer, Error> {
        let shared = arena.kind == MemoryKind::Host;
        let options = if shared {
            STORAGE_SHARED
        } else {
            STORAGE_PRIVATE
        };
        let b: Id = unsafe {
            send!(Id; self.device, "newBufferWithLength:options:", d.size.max(4) as U => U, options => U)
        };
        if b.is_null() {
            return Err(Error::ResourceFailed);
        }
        let mapped = if shared {
            unsafe { send!(*mut u8; b, "contents") }
        } else {
            core::ptr::null_mut()
        };
        Ok(Buffer {
            handle: b,
            size: d.size,
            mapped,
        })
    }
    pub fn destroy_buffer(&self, b: &Buffer) {
        objc::release(b.handle);
    }

    pub fn create_texture(
        &self,
        _arena: &mut Arena,
        d: &TextureDescriptor,
    ) -> Result<Texture, Error> {
        unsafe {
            let mipmapped = d.mip_level_count > 1;
            let td: Id = send!(Id; objc::class(c"MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:",
                pixel_format(d.format) => U, d.width as U => U, d.height as U => U, mipmapped => bool);
            let mut usage: U = 0;
            if d.usage.has(TextureUsages::TEXTURE_BINDING) {
                usage |= 1;
            }
            if d.usage.has(TextureUsages::STORAGE_BINDING) {
                usage |= 1 | 2;
            }
            if d.usage.has(TextureUsages::RENDER_ATTACHMENT) {
                usage |= 4;
            }
            send!((); td, "setUsage:", usage => U);
            send!((); td, "setStorageMode:", 2 => U); // private: the GPU's alone
            let samples = d.sample_count.max(1);
            if samples > 1 {
                send!((); td, "setTextureType:", 4 => U); // MTLTextureType2DMultisample
                send!((); td, "setSampleCount:", samples as U => U);
            }
            let t: Id = send!(Id; self.device, "newTextureWithDescriptor:", td => Id);
            if t.is_null() {
                return Err(Error::ResourceFailed);
            }
            Ok(Texture {
                texture: t,
                format: d.format,
                width: d.width,
                height: d.height,
                samples,
            })
        }
    }
    pub fn destroy_texture(&self, t: &Texture) {
        objc::release(t.texture);
    }

    pub fn create_sampler(&self, d: &SamplerDescriptor) -> Result<Sampler, Error> {
        unsafe {
            let sd: Id = send!(Id; objc::class(c"MTLSamplerDescriptor"), "new");
            send!((); sd, "setMinFilter:", (d.min_filter == FilterMode::Linear) as U => U);
            send!((); sd, "setMagFilter:", (d.mag_filter == FilterMode::Linear) as U => U);
            send!((); sd, "setMipFilter:", if d.mipmap_filter == FilterMode::Linear { 2 } else { 1 } => U);
            send!((); sd, "setSAddressMode:", address_mode(d.address_mode_u) => U);
            send!((); sd, "setTAddressMode:", address_mode(d.address_mode_v) => U);
            send!((); sd, "setRAddressMode:", address_mode(d.address_mode_w) => U);
            send!((); sd, "setLodMinClamp:", d.lod_min_clamp => f32);
            send!((); sd, "setLodMaxClamp:", d.lod_max_clamp => f32);
            let s: Id = send!(Id; self.device, "newSamplerStateWithDescriptor:", sd => Id);
            objc::release(sd);
            if s.is_null() {
                return Err(Error::ResourceFailed);
            }
            Ok(Sampler { handle: s })
        }
    }
    pub fn destroy_sampler(&self, s: &Sampler) {
        objc::release(s.handle);
    }

    /// A pipeline for shader `S` from the MSL lcgf-gen gave it slots in.
    pub fn create_render_pipeline<S: ShaderSource>(
        &self,
        d: &RenderPipelineDescriptor<'_>,
    ) -> Result<RenderPipelineOf<S>, Error> {
        let _pool = objc::Pool::push();
        let library = compile(self.device, S::MSL)?;
        let vs = match function(library, d.vertex.entry_point) {
            Ok(f) => f,
            Err(e) => {
                objc::release(library);
                return Err(e);
            }
        };
        let r = unsafe { self.render_state::<S>(d, library, vs) };
        objc::release(vs);
        objc::release(library);
        r
    }

    unsafe fn render_state<S: ShaderSource>(
        &self,
        d: &RenderPipelineDescriptor<'_>,
        library: Id,
        vs: Id,
    ) -> Result<RenderPipelineOf<S>, Error> {
        unsafe {
            let pd: Id = send!(Id; objc::class(c"MTLRenderPipelineDescriptor"), "new");
            let r = self.describe(d, library, vs, pd);
            objc::release(pd);
            r.map(|(state, ())| RenderPipelineOf {
                raw: RenderPipeline {
                    state,
                    primitive: d.topology as U, // MTLPrimitiveType: WebGPU's order
                    cull: d.cull_mode as U,
                    winding: d.front_face_ccw as U, // MTLWindingCounterClockwise = 1
                    sized: S::METAL.sized,
                    sizes_slot: S::METAL.sizes_slot,
                },
                _s: PhantomData,
            })
        }
    }

    unsafe fn describe(
        &self,
        d: &RenderPipelineDescriptor<'_>,
        library: Id,
        vs: Id,
        pd: Id,
    ) -> Result<(Id, ()), Error> {
        unsafe {
            send!((); pd, "setVertexFunction:", vs => Id);
            if let Some(fr) = d.fragment {
                let fs = function(library, fr.entry_point)?;
                send!((); pd, "setFragmentFunction:", fs => Id);
                objc::release(fs);
            }
            send!((); pd, "setRasterSampleCount:", d.sample_count.max(1) as U => U);
            send!((); pd, "setAlphaToCoverageEnabled:", false => bool);
            let vd: Id = send!(Id; objc::class(c"MTLVertexDescriptor"), "vertexDescriptor");
            let attributes: Id = send!(Id; vd, "attributes");
            let layouts: Id = send!(Id; vd, "layouts");
            for (slot, vb) in d.vertex.buffers.iter().enumerate() {
                let index = vertex_buffer_slot(slot as u32);
                for a in vb.attributes {
                    let at: Id = send!(Id; attributes, "objectAtIndexedSubscript:", a.shader_location as U => U);
                    send!((); at, "setFormat:", vertex_format(a.format) => U);
                    send!((); at, "setOffset:", a.offset as U => U);
                    send!((); at, "setBufferIndex:", index => U);
                }
                let layout: Id = send!(Id; layouts, "objectAtIndexedSubscript:", index => U);
                send!((); layout, "setStride:", vb.array_stride as U => U);
                send!((); layout, "setStepFunction:", if vb.step_mode_instance { 2 } else { 1 } => U);
                send!((); layout, "setStepRate:", 1 => U);
            }
            send!((); pd, "setVertexDescriptor:", vd => Id);
            let colors: Id = send!(Id; pd, "colorAttachments");
            for (i, t) in d.fragment.map_or(&[][..], |f| f.targets).iter().enumerate() {
                let color: Id = send!(Id; colors, "objectAtIndexedSubscript:", i as U => U);
                send!((); color, "setPixelFormat:", pixel_format(t.format) => U);
                // WebGPU's mask is red 1 ... alpha 8; Metal's is alpha 1 ... red 8.
                let m = t.write_mask as U;
                send!((); color, "setWriteMask:", (m >> 3 & 1) | (m >> 2 & 1) << 1 | (m >> 1 & 1) << 2 | (m & 1) << 3 => U);
                if let Some(b) = t.blend {
                    send!((); color, "setBlendingEnabled:", true => bool);
                    send!((); color, "setSourceRGBBlendFactor:", blend_factor(b.color.src_factor) => U);
                    send!((); color, "setDestinationRGBBlendFactor:", blend_factor(b.color.dst_factor) => U);
                    send!((); color, "setRgbBlendOperation:", b.color.operation as U => U); // same order as WebGPU
                    send!((); color, "setSourceAlphaBlendFactor:", blend_factor(b.alpha.src_factor) => U);
                    send!((); color, "setDestinationAlphaBlendFactor:", blend_factor(b.alpha.dst_factor) => U);
                    send!((); color, "setAlphaBlendOperation:", b.alpha.operation as U => U);
                }
            }
            let mut err: Id = core::ptr::null_mut();
            let state: Id = send!(Id; self.device, "newRenderPipelineStateWithDescriptor:error:", pd => Id, &mut err => *mut Id);
            if state.is_null() {
                return Err(Error::PipelineFailed);
            }
            Ok((state, ()))
        }
    }

    pub fn create_compute_pipeline<S: ShaderSource>(
        &self,
        entry_point: &CStr,
    ) -> Result<ComputePipelineOf<S>, Error> {
        let _pool = objc::Pool::push();
        let library = compile(self.device, S::MSL)?;
        let cs = match function(library, entry_point) {
            Ok(f) => f,
            Err(e) => {
                objc::release(library);
                return Err(e);
            }
        };
        let mut err: Id = core::ptr::null_mut();
        let state: Id = unsafe {
            send!(Id; self.device, "newComputePipelineStateWithFunction:error:", cs => Id, &mut err => *mut Id)
        };
        if state.is_null() {}
        objc::release(cs);
        objc::release(library);
        if state.is_null() {
            return Err(Error::PipelineFailed);
        }
        Ok(ComputePipelineOf {
            raw: ComputePipeline {
                state,
                threads: S::METAL.workgroup,
                sized: S::METAL.sized,
                sizes_slot: S::METAL.sizes_slot,
            },
            _s: PhantomData,
        })
    }

    pub fn destroy_render_pipeline(&self, p: &RenderPipeline) {
        objc::release(p.state);
    }
    pub fn destroy_compute_pipeline(&self, p: &ComputePipeline) {
        objc::release(p.state);
    }

    /// A bind group for `group` (a generated `GroupN` of the pipeline's shader): its objects, at
    /// the slots the shader's MSL has them.
    pub fn create_bind_group<P: PipelineOf, G: Group<Shader = P::Shader>>(
        &self,
        _arena: &mut Arena,
        _pipeline: &P,
        group: &G,
    ) -> Result<G::BindGroup, Error> {
        let mut rs = [Resource::EMPTY; 16];
        let n = group.resources(&mut rs);
        let layout = <P::Shader as ShaderSource>::METAL
            .groups
            .get(G::INDEX as usize)
            .copied()
            .unwrap_or(&[]);
        let mut out = G::BindGroup::default();
        let (entries, count) = out.entries_mut();
        for (i, (r, l)) in rs[..n].iter().zip(layout).enumerate() {
            entries[i] = BindEntry {
                object: r.object,
                kind: l.kind,
                slot: l.slot,
                sized: l.sized,
                size: r.size,
            };
        }
        *count = n.min(layout.len()) as u32;
        Ok(out)
    }
}
