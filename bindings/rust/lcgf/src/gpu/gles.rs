//! The GL ES 3 back end of `lcgf::gpu` (feature `gles`): src/render/gles/gpu.zig, inline.
//!
//! WebGPU's object model projected onto GL ES. A type is the GL names it stands for, with public
//! fields (`buffer.handle` is the buffer name); a call is the `gl*` calls it stands for, through
//! the function table you load (`GlFns::load`). GL ES has neither bind groups nor command
//! buffers, so a render pass is the current context, a pipeline is a program plus the
//! fixed-function state it sets, and `set_bind_group` replays the binding table `include_shader!`
//! wrote from the shader's reflection (`GlesBinding`).
//!
//! Binding points are flat per kind, in (group, binding) order (src/render/gpu/naga.zig numbers
//! them). naga flips clip-space y for GL, so rows count from the top as in WebGPU.

use super::*;
use core::ffi::{c_char, c_void};
use core::marker::PhantomData;
use core::ops::Range;

/// GL's types and the enums the projection uses (Khronos's values).
pub mod gl {
    pub type Enum = u32;
    pub type Uint = u32;
    pub type Int = i32;
    pub type Sizei = i32;
    pub type Boolean = u8;
    pub type Bitfield = u32;
    pub type Intptr = isize;
    pub type Sizeiptr = isize;

    pub const TEXTURE_2D: Enum = 0x0DE1;
    pub const TEXTURE_MIN_FILTER: Enum = 0x2801;
    pub const TEXTURE_MAG_FILTER: Enum = 0x2800;
    pub const TEXTURE_WRAP_S: Enum = 0x2802;
    pub const TEXTURE_WRAP_T: Enum = 0x2803;
    pub const TEXTURE_WRAP_R: Enum = 0x8072;
    pub const NEAREST: Int = 0x2600;
    pub const LINEAR: Int = 0x2601;
    pub const NEAREST_MIPMAP_NEAREST: Int = 0x2700;
    pub const LINEAR_MIPMAP_NEAREST: Int = 0x2701;
    pub const NEAREST_MIPMAP_LINEAR: Int = 0x2702;
    pub const LINEAR_MIPMAP_LINEAR: Int = 0x2703;
    pub const CLAMP_TO_EDGE: Int = 0x812F;
    pub const REPEAT: Int = 0x2901;
    pub const MIRRORED_REPEAT: Int = 0x8370;
    pub const TEXTURE_MIN_LOD: Enum = 0x813A;
    pub const TEXTURE_MAX_LOD: Enum = 0x813B;
    pub const FRAMEBUFFER: Enum = 0x8D40;
    pub const READ_FRAMEBUFFER: Enum = 0x8CA8;
    pub const DRAW_FRAMEBUFFER: Enum = 0x8CA9;
    pub const RENDERBUFFER: Enum = 0x8D41;
    pub const COLOR_ATTACHMENT0: Enum = 0x8CE0;
    pub const FRAMEBUFFER_COMPLETE: Enum = 0x8CD5;
    pub const ARRAY_BUFFER: Enum = 0x8892;
    pub const ELEMENT_ARRAY_BUFFER: Enum = 0x8893;
    pub const UNIFORM_BUFFER: Enum = 0x8A11;
    pub const SHADER_STORAGE_BUFFER: Enum = 0x90D2;
    pub const COPY_READ_BUFFER: Enum = 0x8F36;
    pub const COPY_WRITE_BUFFER: Enum = 0x8F37;
    pub const DYNAMIC_DRAW: Enum = 0x88E8;
    pub const MAP_READ_BIT: Bitfield = 0x0001;
    pub const UNPACK_ALIGNMENT: Enum = 0x0CF5;
    pub const UNPACK_ROW_LENGTH: Enum = 0x0CF2;
    pub const PACK_ALIGNMENT: Enum = 0x0D05;
    pub const VERTEX_SHADER: Enum = 0x8B31;
    pub const FRAGMENT_SHADER: Enum = 0x8B30;
    pub const COMPUTE_SHADER: Enum = 0x91B9;
    pub const COMPILE_STATUS: Enum = 0x8B81;
    pub const LINK_STATUS: Enum = 0x8B82;
    pub const TEXTURE0: Enum = 0x84C0;
    pub const SCISSOR_TEST: Enum = 0x0C11;
    pub const BLEND: Enum = 0x0BE2;
    pub const CULL_FACE: Enum = 0x0B44;
    pub const DEPTH_TEST: Enum = 0x0B71;
    pub const STENCIL_TEST: Enum = 0x0B90;
    pub const DITHER: Enum = 0x0BD0;
    pub const FRONT: Enum = 0x0404;
    pub const BACK: Enum = 0x0405;
    pub const CW: Enum = 0x0900;
    pub const CCW: Enum = 0x0901;
    pub const PRIMITIVE_RESTART_FIXED_INDEX: Enum = 0x8D69;
    pub const SAMPLE_ALPHA_TO_COVERAGE: Enum = 0x809E;
    pub const COLOR_BUFFER_BIT: Bitfield = 0x4000;
    pub const POINTS: Enum = 0x0000;
    pub const LINES: Enum = 0x0001;
    pub const LINE_STRIP: Enum = 0x0003;
    pub const TRIANGLES: Enum = 0x0004;
    pub const TRIANGLE_STRIP: Enum = 0x0005;
    pub const FLOAT: Enum = 0x1406;
    pub const UNSIGNED_BYTE: Enum = 0x1401;
    pub const UNSIGNED_SHORT: Enum = 0x1403;
    pub const UNSIGNED_INT: Enum = 0x1405;
    pub const INT: Enum = 0x1404;
    pub const HALF_FLOAT: Enum = 0x140B;
    pub const RGBA: Enum = 0x1908;
    pub const RED: Enum = 0x1903;
    pub const RG: Enum = 0x8227;
    pub const RED_INTEGER: Enum = 0x8D94;
    pub const DEPTH_COMPONENT: Enum = 0x1902;
    pub const FUNC_ADD: Enum = 0x8006;
    pub const INVALID_INDEX: Uint = 0xFFFF_FFFF;
    pub const NO_ERROR: Enum = 0;
    pub const ALL_BARRIER_BITS: Bitfield = 0xFFFF_FFFF;
}

macro_rules! gl_fns {
    ($( $name:ident = $sym:literal : fn($($arg:ty),*) $(-> $ret:ty)? ;)* | $( $oname:ident = $osym:literal : fn($($oarg:ty),*) $(-> $oret:ty)? ;)*) => {
        /// The GL ES entry points the projection calls, loaded once from the host's context. The
        /// 3.1 ones (compute, images) are `None` on a 3.0 context.
        #[derive(Clone, Copy)]
        pub struct GlFns {
            $(pub $name: unsafe extern "C" fn($($arg),*) $(-> $ret)?,)*
            $(pub $oname: Option<unsafe extern "C" fn($($oarg),*) $(-> $oret)?>,)*
        }
        impl GlFns {
            /// Loads every entry point through `get` (eglGetProcAddress, SDL_GL_GetProcAddress,
            /// ...). `None` when a GL ES 3.0 one is missing; the 3.1 ones may be.
            ///
            /// # Safety
            /// `get` returns the entry point of the given name for the context, or null.
            pub unsafe fn load(mut get: impl FnMut(&core::ffi::CStr) -> *const c_void) -> Option<Self> {
                unsafe {
                    Some(Self {
                        $($name: { let p = get($sym); if p.is_null() { return None; } core::mem::transmute::<*const c_void, unsafe extern "C" fn($($arg),*) $(-> $ret)?>(p) },)*
                        $($oname: { let p = get($osym); if p.is_null() { None } else { Some(core::mem::transmute::<*const c_void, unsafe extern "C" fn($($oarg),*) $(-> $oret)?>(p)) } },)*
                    })
                }
            }
            pub fn has_compute(&self) -> bool {
                self.dispatch_compute.is_some() && self.memory_barrier.is_some() && self.bind_image_texture.is_some()
            }
        }
    };
}

use gl::{Bitfield, Boolean, Enum, Int, Intptr, Sizei, Sizeiptr, Uint};
gl_fns! {
    gen_buffers = c"glGenBuffers": fn(Sizei, *mut Uint);
    delete_buffers = c"glDeleteBuffers": fn(Sizei, *const Uint);
    bind_buffer = c"glBindBuffer": fn(Enum, Uint);
    buffer_data = c"glBufferData": fn(Enum, Sizeiptr, *const c_void, Enum);
    buffer_sub_data = c"glBufferSubData": fn(Enum, Intptr, Sizeiptr, *const c_void);
    map_buffer_range = c"glMapBufferRange": fn(Enum, Intptr, Sizeiptr, Bitfield) -> *mut c_void;
    unmap_buffer = c"glUnmapBuffer": fn(Enum) -> Boolean;
    bind_buffer_range = c"glBindBufferRange": fn(Enum, Uint, Uint, Intptr, Sizeiptr);
    gen_textures = c"glGenTextures": fn(Sizei, *mut Uint);
    delete_textures = c"glDeleteTextures": fn(Sizei, *const Uint);
    bind_texture = c"glBindTexture": fn(Enum, Uint);
    active_texture = c"glActiveTexture": fn(Enum);
    tex_storage_2d = c"glTexStorage2D": fn(Enum, Sizei, Enum, Sizei, Sizei);
    tex_sub_image_2d = c"glTexSubImage2D": fn(Enum, Int, Int, Int, Sizei, Sizei, Enum, Enum, *const c_void);
    tex_parameteri = c"glTexParameteri": fn(Enum, Enum, Int);
    pixel_storei = c"glPixelStorei": fn(Enum, Int);
    read_pixels = c"glReadPixels": fn(Int, Int, Sizei, Sizei, Enum, Enum, *mut c_void);
    gen_samplers = c"glGenSamplers": fn(Sizei, *mut Uint);
    delete_samplers = c"glDeleteSamplers": fn(Sizei, *const Uint);
    bind_sampler = c"glBindSampler": fn(Uint, Uint);
    sampler_parameteri = c"glSamplerParameteri": fn(Uint, Enum, Int);
    sampler_parameterf = c"glSamplerParameterf": fn(Uint, Enum, f32);
    gen_renderbuffers = c"glGenRenderbuffers": fn(Sizei, *mut Uint);
    delete_renderbuffers = c"glDeleteRenderbuffers": fn(Sizei, *const Uint);
    bind_renderbuffer = c"glBindRenderbuffer": fn(Enum, Uint);
    renderbuffer_storage_multisample = c"glRenderbufferStorageMultisample": fn(Enum, Sizei, Enum, Sizei, Sizei);
    gen_framebuffers = c"glGenFramebuffers": fn(Sizei, *mut Uint);
    delete_framebuffers = c"glDeleteFramebuffers": fn(Sizei, *const Uint);
    bind_framebuffer = c"glBindFramebuffer": fn(Enum, Uint);
    framebuffer_texture_2d = c"glFramebufferTexture2D": fn(Enum, Enum, Enum, Uint, Int);
    framebuffer_renderbuffer = c"glFramebufferRenderbuffer": fn(Enum, Enum, Enum, Uint);
    check_framebuffer_status = c"glCheckFramebufferStatus": fn(Enum) -> Enum;
    blit_framebuffer = c"glBlitFramebuffer": fn(Int, Int, Int, Int, Int, Int, Int, Int, Bitfield, Enum);
    create_shader = c"glCreateShader": fn(Enum) -> Uint;
    shader_source = c"glShaderSource": fn(Uint, Sizei, *const *const c_char, *const Int);
    compile_shader = c"glCompileShader": fn(Uint);
    get_shaderiv = c"glGetShaderiv": fn(Uint, Enum, *mut Int);
    get_shader_info_log = c"glGetShaderInfoLog": fn(Uint, Sizei, *mut Sizei, *mut c_char);
    delete_shader = c"glDeleteShader": fn(Uint);
    create_program = c"glCreateProgram": fn() -> Uint;
    attach_shader = c"glAttachShader": fn(Uint, Uint);
    link_program = c"glLinkProgram": fn(Uint);
    get_programiv = c"glGetProgramiv": fn(Uint, Enum, *mut Int);
    get_program_info_log = c"glGetProgramInfoLog": fn(Uint, Sizei, *mut Sizei, *mut c_char);
    delete_program = c"glDeleteProgram": fn(Uint);
    use_program = c"glUseProgram": fn(Uint);
    get_uniform_block_index = c"glGetUniformBlockIndex": fn(Uint, *const c_char) -> Uint;
    uniform_block_binding = c"glUniformBlockBinding": fn(Uint, Uint, Uint);
    get_uniform_location = c"glGetUniformLocation": fn(Uint, *const c_char) -> Int;
    uniform1i = c"glUniform1i": fn(Int, Int);
    gen_vertex_arrays = c"glGenVertexArrays": fn(Sizei, *mut Uint);
    delete_vertex_arrays = c"glDeleteVertexArrays": fn(Sizei, *const Uint);
    bind_vertex_array = c"glBindVertexArray": fn(Uint);
    enable_vertex_attrib_array = c"glEnableVertexAttribArray": fn(Uint);
    vertex_attrib_pointer = c"glVertexAttribPointer": fn(Uint, Int, Enum, Boolean, Sizei, *const c_void);
    vertex_attrib_i_pointer = c"glVertexAttribIPointer": fn(Uint, Int, Enum, Sizei, *const c_void);
    vertex_attrib_divisor = c"glVertexAttribDivisor": fn(Uint, Uint);
    enable = c"glEnable": fn(Enum);
    disable = c"glDisable": fn(Enum);
    blend_func_separate = c"glBlendFuncSeparate": fn(Enum, Enum, Enum, Enum);
    blend_equation_separate = c"glBlendEquationSeparate": fn(Enum, Enum);
    blend_color = c"glBlendColor": fn(f32, f32, f32, f32);
    color_mask = c"glColorMask": fn(Boolean, Boolean, Boolean, Boolean);
    cull_face = c"glCullFace": fn(Enum);
    front_face = c"glFrontFace": fn(Enum);
    viewport = c"glViewport": fn(Int, Int, Sizei, Sizei);
    scissor = c"glScissor": fn(Int, Int, Sizei, Sizei);
    clear_color = c"glClearColor": fn(f32, f32, f32, f32);
    clear = c"glClear": fn(Bitfield);
    draw_arrays_instanced = c"glDrawArraysInstanced": fn(Enum, Int, Sizei, Sizei);
    draw_elements_instanced = c"glDrawElementsInstanced": fn(Enum, Sizei, Enum, *const c_void, Sizei);
    get_error = c"glGetError": fn() -> Enum;
    finish = c"glFinish": fn();
    |
    dispatch_compute = c"glDispatchCompute": fn(Uint, Uint, Uint);
    memory_barrier = c"glMemoryBarrier": fn(Bitfield);
    bind_image_texture = c"glBindImageTexture": fn(Uint, Uint, Int, Boolean, Int, Enum, Enum);
}

/// What creation reports.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
    CompileFailed,
    LinkFailed,
    UnsupportedFormat,
    IncompleteFramebuffer,
    NoCompute,
    /// The shader was not built with GLSL for this entry point.
    NoCode,
}

/// The host's current GL ES context: its function table.
#[derive(Clone, Copy)]
pub struct Device<'a> {
    pub fns: &'a GlFns,
}

#[derive(Clone, Copy, Debug)]
pub struct Buffer {
    pub handle: Uint,
    pub size: u64,
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
    pub texture: Uint,
    /// The framebuffer that draws into it, if it is a render attachment.
    pub fbo: Uint,
    pub width: u32,
    pub height: u32,
    pub samples: u32,
    pub format: TextureFormat,
}

#[derive(Clone, Copy, Debug)]
pub struct Texture {
    pub handle: Uint,
    pub renderbuffer: Uint,
    pub fbo: Uint,
    pub format: TextureFormat,
    pub width: u32,
    pub height: u32,
    pub samples: u32,
}

impl Texture {
    pub fn create_view(&self) -> TextureView {
        TextureView {
            texture: self.handle,
            fbo: self.fbo,
            width: self.width,
            height: self.height,
            samples: self.samples,
            format: self.format,
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub struct Sampler {
    pub handle: Uint,
}

const MAX_VERTEX_BUFFERS: usize = 8;
const MAX_VERTEX_ATTRIBUTES: usize = 16;

#[derive(Clone, Copy, Debug, Default)]
struct VertexBuffer {
    stride: u32,
    instance: bool,
    first: u8,
    count: u8,
}

#[derive(Clone, Copy, Debug)]
struct Attribute {
    location: u32,
    format: VertexFormat,
    offset: u32,
}

const NO_ATTRIBUTE: Attribute = Attribute {
    location: 0,
    format: VertexFormat::Float32,
    offset: 0,
};

/// A program, its vertex array, and the fixed-function state `set_pipeline` sets.
#[derive(Clone, Copy, Debug)]
pub struct RenderPipeline {
    pub program: Uint,
    pub vao: Uint,
    pub mode: Enum,
    buffers: [VertexBuffer; MAX_VERTEX_BUFFERS],
    attributes: [Attribute; MAX_VERTEX_ATTRIBUTES],
    pub cull: CullMode,
    pub front_ccw: bool,
    pub restart: bool,
    pub blend: Option<BlendState>,
    pub write_mask: u32,
}

#[derive(Clone, Copy, Debug)]
pub struct ComputePipeline {
    pub program: Uint,
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
    type Shader;
}
impl<S> PipelineOf for RenderPipelineOf<S> {
    type Shader = S;
}
impl<S> PipelineOf for ComputePipelineOf<S> {
    type Shader = S;
}

/// The GL names of a group's resources in binding order, the sizes of its buffers, and the
/// shader's binding table for `@group(G)`.
#[derive(Clone, Copy, Debug)]
pub struct BindGroup<const G: u32> {
    pub names: [Uint; 16],
    pub sizes: [u64; 16],
    pub table: &'static [GlesBinding],
}

/// What `create_bind_group` fills a `BindGroup` from.
pub struct GlesGroup {
    pub names: [Uint; 16],
    pub sizes: [u64; 16],
    pub table: &'static [GlesBinding],
}

impl<const G: u32> From<GlesGroup> for BindGroup<G> {
    fn from(g: GlesGroup) -> Self {
        Self {
            names: g.names,
            sizes: g.sizes,
            table: g.table,
        }
    }
}

/// One resource of a bind group, as a generated `GroupN` lists them.
#[derive(Clone, Copy, Debug)]
pub struct Resource {
    pub binding: u32,
    pub kind: BindingKind,
    pub name: Uint,
    pub size: u64,
}

impl Resource {
    pub const EMPTY: Self = Self {
        binding: 0,
        kind: BindingKind::Uniform,
        name: 0,
        size: 0,
    };
    pub fn buffer(binding: u32, kind: BindingKind, b: &Buffer) -> Self {
        Self {
            binding,
            kind,
            name: b.handle,
            size: b.size,
        }
    }
    pub fn view(binding: u32, kind: BindingKind, v: &TextureView) -> Self {
        Self {
            binding,
            kind,
            name: v.texture,
            size: 0,
        }
    }
    pub fn sampler(binding: u32, kind: BindingKind, s: &Sampler) -> Self {
        Self {
            binding,
            kind,
            name: s.handle,
            size: 0,
        }
    }
}

/// A generated `GroupN`: the shader it belongs to, its index, and its resources.
pub trait Group {
    type Shader: ShaderSource;
    type BindGroup: From<GlesGroup>;
    const INDEX: u32;
    /// Writes the resources into `out`; returns how many.
    fn resources(&self, out: &mut [Resource; 16]) -> usize;
}

/// GL allocates its own memory: an arena is only the projection's uniform interface.
pub struct Arena;
/// GL uploads through the driver; staging exists for the uniform interface.
pub struct Staging;
impl Staging {
    pub fn rewind(&mut self) {}
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

struct GlFormat {
    internal: Enum,
    format: Enum,
    ty: Enum,
}

impl TextureFormat {
    fn gl(self) -> Result<GlFormat, Error> {
        use TextureFormat::*;
        let (internal, format, ty) = match self {
            R8Unorm => (0x8229, gl::RED, gl::UNSIGNED_BYTE),
            Rg8Unorm => (0x822B, gl::RG, gl::UNSIGNED_BYTE),
            Rgba8Unorm => (0x8058, gl::RGBA, gl::UNSIGNED_BYTE),
            Rgba8UnormSrgb => (0x8C43, gl::RGBA, gl::UNSIGNED_BYTE),
            Bgra8Unorm | Bgra8UnormSrgb => return Err(Error::UnsupportedFormat), // GL ES has no BGRA storage
            R16Float => (0x822D, gl::RED, gl::HALF_FLOAT),
            Rgba16Float => (0x881A, gl::RGBA, gl::HALF_FLOAT),
            R32Float => (0x822E, gl::RED, gl::FLOAT),
            Rg32Float => (0x8230, gl::RG, gl::FLOAT),
            Rgba32Float => (0x8814, gl::RGBA, gl::FLOAT),
            R32Uint => (0x8236, gl::RED_INTEGER, gl::UNSIGNED_INT),
            Depth32Float => (0x8CAC, gl::DEPTH_COMPONENT, gl::FLOAT),
        };
        Ok(GlFormat {
            internal,
            format,
            ty,
        })
    }
}

fn blend_factor(f: BlendFactor) -> Enum {
    [
        0, 1, 0x0300, 0x0301, 0x0302, 0x0303, 0x0306, 0x0307, 0x0304, 0x0305, 0x8001, 0x8002,
    ][f as usize]
}
fn blend_op(o: BlendOperation) -> Enum {
    [gl::FUNC_ADD, 0x800A, 0x800B, 0x8007, 0x8008][o as usize]
}
fn wrap_mode(a: AddressMode) -> Int {
    [gl::CLAMP_TO_EDGE, gl::REPEAT, gl::MIRRORED_REPEAT][a as usize]
}

/// The bind calls of a group, from the shader's binding table.
fn replay<const G: u32>(f: &GlFns, g: &BindGroup<G>) {
    for (i, b) in g.table.iter().enumerate() {
        unsafe {
            match b.kind {
                BindingKind::Uniform => (f.bind_buffer_range)(
                    gl::UNIFORM_BUFFER,
                    b.unit,
                    g.names[i],
                    0,
                    g.sizes[i] as Sizeiptr,
                ),
                BindingKind::StorageRead | BindingKind::StorageReadWrite => (f.bind_buffer_range)(
                    gl::SHADER_STORAGE_BUFFER,
                    b.unit,
                    g.names[i],
                    0,
                    g.sizes[i] as Sizeiptr,
                ),
                BindingKind::Texture => {
                    (f.active_texture)(gl::TEXTURE0 + b.unit);
                    (f.bind_texture)(gl::TEXTURE_2D, g.names[i]);
                    // The group's sampler on this texture's unit (`include_shader!` chose which).
                    if b.sampler != u32::MAX {
                        (f.bind_sampler)(b.unit, g.names[b.sampler as usize]);
                    }
                }
                BindingKind::StorageTexture => (f
                    .bind_image_texture
                    .expect("storage textures need GL ES 3.1"))(
                    b.unit, g.names[i], 0, 0, 0, b.access, b.format,
                ),
                BindingKind::Sampler | BindingKind::ComparisonSampler => {} // bound with their textures
            }
        }
    }
}

// ---- the frame ------------------------------------------------------------------------------

/// The write phase of a frame: GL orders writes itself, so these are direct calls in the
/// projection's shape. `finish` consumes it.
pub struct Upload<'a> {
    f: &'a GlFns,
}

impl<'a> Upload<'a> {
    pub fn new(device: &Device<'a>) -> Self {
        Self { f: device.fns }
    }
    pub fn with_staging(device: &Device<'a>, _staging: &'a mut Staging) -> Self {
        Self { f: device.fns }
    }
    pub fn write_buffer(&mut self, buffer: &Buffer, offset: u64, data: &[u8]) {
        debug_assert!(
            offset % 4 == 0 && data.len() % 4 == 0 && offset + data.len() as u64 <= buffer.size
        );
        unsafe {
            (self.f.bind_buffer)(gl::COPY_WRITE_BUFFER, buffer.handle);
            (self.f.buffer_sub_data)(
                gl::COPY_WRITE_BUFFER,
                offset as Intptr,
                data.len() as Sizeiptr,
                data.as_ptr().cast(),
            );
            (self.f.bind_buffer)(gl::COPY_WRITE_BUFFER, 0);
        }
    }
    /// Replaces the whole first mip level of `t` with `data` (rows of `bytes_per_row`).
    pub fn write_texture(&mut self, t: &Texture, data: &[u8], bytes_per_row: u32) -> bool {
        let Ok(fmt) = t.format.gl() else { return false };
        let f = self.f;
        unsafe {
            (f.bind_texture)(gl::TEXTURE_2D, t.handle);
            (f.pixel_storei)(gl::UNPACK_ALIGNMENT, 1);
            (f.pixel_storei)(
                gl::UNPACK_ROW_LENGTH,
                (bytes_per_row / t.format.bytes_per_pixel()) as Int,
            );
            (f.tex_sub_image_2d)(
                gl::TEXTURE_2D,
                0,
                0,
                0,
                t.width as Sizei,
                t.height as Sizei,
                fmt.format,
                fmt.ty,
                data.as_ptr().cast(),
            );
            (f.pixel_storei)(gl::UNPACK_ROW_LENGTH, 0);
        }
        true
    }
    pub fn prepare(&mut self, _t: &Texture) {}
    pub fn finish(self) -> CommandEncoder<'a> {
        CommandEncoder { f: self.f }
    }
}

/// The draw phase of a frame. Made by `Upload::finish`.
pub struct CommandEncoder<'a> {
    f: &'a GlFns,
}

impl<'a> CommandEncoder<'a> {
    /// Draws into the first attachment's framebuffer (GL ES draws one colour target per
    /// framebuffer here); clears it when asked; viewport and scissor cover it.
    pub fn begin_render_pass(&self, d: &RenderPassDescriptor<'_>) -> RenderPass<'a> {
        let a = d.color_attachments[0].expect("a colour attachment");
        let f = self.f;
        let mut p = RenderPass::new(f, a.view.width, a.view.height);
        p.owned = true;
        unsafe {
            (f.bind_framebuffer)(gl::FRAMEBUFFER, a.view.fbo);
            if let Some(r) = a.resolve_target {
                p.resolve = Some((a.view.fbo, r.fbo));
            }
            (f.enable)(gl::SCISSOR_TEST);
        }
        p.set_viewport(0.0, 0.0, p.width as f32, p.height as f32, 0.0, 1.0);
        p.set_scissor_rect(0, 0, p.width, p.height);
        if let LoadOp::Clear(c) = a.ops.load {
            unsafe {
                (f.color_mask)(1, 1, 1, 1);
                (f.clear_color)(c.r as f32, c.g as f32, c.b as f32, c.a as f32);
                (f.clear)(gl::COLOR_BUFFER_BIT);
            }
        }
        p
    }
    pub fn begin_compute_pass(&self) -> ComputePass<'a> {
        assert!(self.f.has_compute(), "compute needs GL ES 3.1");
        ComputePass { f: self.f }
    }
}

/// A render pass: the current GL context, and the vertex layout of the bound pipeline (GL ES
/// 3.0 binds attribute formats together with buffers). It ends when dropped.
pub struct RenderPass<'a> {
    f: &'a GlFns,
    width: u32,
    height: u32,
    owned: bool,
    resolve: Option<(Uint, Uint)>,
    mode: Enum,
    buffers: [VertexBuffer; MAX_VERTEX_BUFFERS],
    attributes: [Attribute; MAX_VERTEX_ATTRIBUTES],
    index_type: Enum,
    index_offset: u64,
    has_pipeline: bool,
}

impl<'a> RenderPass<'a> {
    fn new(f: &'a GlFns, width: u32, height: u32) -> Self {
        Self {
            f,
            width,
            height,
            owned: false,
            resolve: None,
            mode: gl::TRIANGLES,
            buffers: [VertexBuffer::default(); MAX_VERTEX_BUFFERS],
            attributes: [NO_ATTRIBUTE; MAX_VERTEX_ATTRIBUTES],
            index_type: gl::UNSIGNED_SHORT,
            index_offset: 0,
            has_pipeline: false,
        }
    }
    /// The pass the host is drawing in (the UI's, for an inline custom draw); dropping it
    /// leaves it to the host.
    pub fn wrap(device: &Device<'a>, width: u32, height: u32) -> Self {
        Self::new(device.fns, width, height)
    }
    /// Program, vertex array, and the fixed-function state the pipeline describes.
    pub fn set_pipeline(&mut self, p: &RenderPipeline) {
        let f = self.f;
        self.has_pipeline = true;
        self.mode = p.mode;
        self.buffers = p.buffers;
        self.attributes = p.attributes;
        unsafe {
            (f.use_program)(p.program);
            (f.bind_vertex_array)(p.vao);
            match p.blend {
                Some(b) => {
                    (f.enable)(gl::BLEND);
                    (f.blend_func_separate)(
                        blend_factor(b.color.src_factor),
                        blend_factor(b.color.dst_factor),
                        blend_factor(b.alpha.src_factor),
                        blend_factor(b.alpha.dst_factor),
                    );
                    (f.blend_equation_separate)(
                        blend_op(b.color.operation),
                        blend_op(b.alpha.operation),
                    );
                }
                None => (f.disable)(gl::BLEND),
            }
            let m = p.write_mask;
            (f.color_mask)(
                (m & 1) as u8,
                (m >> 1 & 1) as u8,
                (m >> 2 & 1) as u8,
                (m >> 3 & 1) as u8,
            );
            match p.cull {
                CullMode::None => (f.disable)(gl::CULL_FACE),
                c => {
                    (f.enable)(gl::CULL_FACE);
                    (f.cull_face)(if c == CullMode::Front {
                        gl::FRONT
                    } else {
                        gl::BACK
                    });
                }
            }
            // naga's y flip mirrors the image in GL's clip space, which reverses the winding.
            (f.front_face)(if p.front_ccw { gl::CW } else { gl::CCW });
            if p.restart {
                (f.enable)(gl::PRIMITIVE_RESTART_FIXED_INDEX)
            } else {
                (f.disable)(gl::PRIMITIVE_RESTART_FIXED_INDEX)
            }
            (f.disable)(gl::SAMPLE_ALPHA_TO_COVERAGE);
            (f.disable)(gl::DEPTH_TEST);
            (f.disable)(gl::STENCIL_TEST);
            (f.disable)(gl::DITHER);
            (f.enable)(gl::SCISSOR_TEST);
        }
    }
    pub fn set_bind_group<const G: u32>(
        &mut self,
        index: u32,
        group: &BindGroup<G>,
        _offsets: &[u32],
    ) {
        debug_assert!(index == G, "bind group made for another @group");
        replay(self.f, group);
    }
    pub fn set_vertex_buffer(&mut self, slot: u32, slice: BufferSlice<'_>) {
        let f = self.f;
        let vb = self.buffers[slot as usize];
        unsafe {
            (f.bind_buffer)(gl::ARRAY_BUFFER, slice.buffer.handle);
            for a in &self.attributes[vb.first as usize..][..vb.count as usize] {
                use VertexFormat::*;
                let (n, ty, integer, norm) = match a.format {
                    Float32 => (1, gl::FLOAT, false, false),
                    Float32x2 => (2, gl::FLOAT, false, false),
                    Float32x3 => (3, gl::FLOAT, false, false),
                    Float32x4 => (4, gl::FLOAT, false, false),
                    Uint32 => (1, gl::UNSIGNED_INT, true, false),
                    Uint32x2 => (2, gl::UNSIGNED_INT, true, false),
                    Uint32x4 => (4, gl::UNSIGNED_INT, true, false),
                    Sint32 => (1, gl::INT, true, false),
                    Unorm8x4 => (4, gl::UNSIGNED_BYTE, false, true),
                };
                let at = (slice.offset + a.offset as u64) as usize as *const c_void;
                (f.enable_vertex_attrib_array)(a.location);
                if integer {
                    (f.vertex_attrib_i_pointer)(a.location, n, ty, vb.stride as Sizei, at);
                } else {
                    (f.vertex_attrib_pointer)(
                        a.location,
                        n,
                        ty,
                        norm as u8,
                        vb.stride as Sizei,
                        at,
                    );
                }
                (f.vertex_attrib_divisor)(a.location, vb.instance as u32);
            }
        }
    }
    pub fn set_index_buffer(&mut self, slice: BufferSlice<'_>, format: IndexFormat) {
        unsafe { (self.f.bind_buffer)(gl::ELEMENT_ARRAY_BUFFER, slice.buffer.handle) };
        self.index_type = if format == IndexFormat::Uint16 {
            gl::UNSIGNED_SHORT
        } else {
            gl::UNSIGNED_INT
        };
        self.index_offset = slice.offset;
    }
    pub fn set_viewport(
        &mut self,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        _min_depth: f32,
        _max_depth: f32,
    ) {
        unsafe { (self.f.viewport)(x as Int, y as Int, w as Sizei, h as Sizei) };
    }
    pub fn set_scissor_rect(&mut self, x: u32, y: u32, w: u32, h: u32) {
        debug_assert!(
            x + w <= self.width && y + h <= self.height,
            "scissor outside the target"
        );
        unsafe {
            (self.f.enable)(gl::SCISSOR_TEST);
            (self.f.scissor)(x as Int, y as Int, w as Sizei, h as Sizei);
        }
    }
    pub fn set_blend_constant(&mut self, c: Color) {
        unsafe { (self.f.blend_color)(c.r as f32, c.g as f32, c.b as f32, c.a as f32) };
    }
    pub fn draw(&mut self, vertices: Range<u32>, instances: Range<u32>) {
        debug_assert!(
            self.has_pipeline && instances.start == 0,
            "draw with no pipeline, or a first instance GL ES cannot draw"
        );
        unsafe {
            (self.f.draw_arrays_instanced)(
                self.mode,
                vertices.start as Int,
                vertices.len() as Sizei,
                instances.len() as Sizei,
            )
        };
    }
    pub fn draw_indexed(&mut self, indices: Range<u32>, base_vertex: i32, instances: Range<u32>) {
        debug_assert!(
            self.has_pipeline && base_vertex == 0 && instances.start == 0,
            "GL ES 3.0 draws no base vertex or first instance"
        );
        let size = if self.index_type == gl::UNSIGNED_SHORT {
            2
        } else {
            4
        };
        let at = (self.index_offset + indices.start as u64 * size) as usize as *const c_void;
        unsafe {
            (self.f.draw_elements_instanced)(
                self.mode,
                indices.len() as Sizei,
                self.index_type,
                at,
                instances.len() as Sizei,
            )
        };
    }
    pub fn fns(&self) -> &'a GlFns {
        self.f
    }
}

impl Drop for RenderPass<'_> {
    /// Ends a pass the projection began: resolves a multisampled target, unbinds the
    /// framebuffer. A wrapped pass is the host's.
    fn drop(&mut self) {
        if !self.owned {
            return;
        }
        let f = self.f;
        unsafe {
            if let Some((from, to)) = self.resolve {
                let (w, h) = (self.width as Int, self.height as Int);
                (f.bind_framebuffer)(gl::READ_FRAMEBUFFER, from);
                (f.bind_framebuffer)(gl::DRAW_FRAMEBUFFER, to);
                (f.blit_framebuffer)(
                    0,
                    0,
                    w,
                    h,
                    0,
                    0,
                    w,
                    h,
                    gl::COLOR_BUFFER_BIT,
                    gl::NEAREST as Enum,
                );
            }
            (f.bind_framebuffer)(gl::FRAMEBUFFER, 0);
        }
    }
}

/// A compute pass; one barrier over every kind of access when it is dropped.
pub struct ComputePass<'a> {
    f: &'a GlFns,
}

impl ComputePass<'_> {
    pub fn set_pipeline(&mut self, p: &ComputePipeline) {
        unsafe { (self.f.use_program)(p.program) };
    }
    pub fn set_bind_group<const G: u32>(
        &mut self,
        index: u32,
        group: &BindGroup<G>,
        _offsets: &[u32],
    ) {
        debug_assert!(index == G, "bind group made for another @group");
        replay(self.f, group);
    }
    pub fn dispatch_workgroups(&mut self, x: u32, y: u32, z: u32) {
        unsafe { (self.f.dispatch_compute.unwrap())(x, y, z) };
    }
}

impl Drop for ComputePass<'_> {
    fn drop(&mut self) {
        unsafe { (self.f.memory_barrier.unwrap())(gl::ALL_BARRIER_BITS) };
    }
}

// ---- creation ---------------------------------------------------------------------------------

fn compile(f: &GlFns, stage: Enum, code: &str) -> Result<Uint, Error> {
    unsafe {
        let s = (f.create_shader)(stage);
        let ptr = code.as_ptr().cast::<c_char>();
        let len = code.trim_end_matches('\0').len() as Int;
        (f.shader_source)(s, 1, &ptr, &len);
        (f.compile_shader)(s);
        let mut ok = 0;
        (f.get_shaderiv)(s, gl::COMPILE_STATUS, &mut ok);
        if ok == 0 {
            // The crate is no_std: the driver's log stays with the driver (glGetShaderInfoLog).
            (f.delete_shader)(s);
            return Err(Error::CompileFailed);
        }
        Ok(s)
    }
}

/// Links the stages and binds the shader's uniform blocks and sampler uniforms to their slots.
fn link(f: &GlFns, t: &GlesTable, stages: &[(Enum, &str)]) -> Result<Uint, Error> {
    unsafe {
        let p = (f.create_program)();
        let mut objects = [0; 2];
        let mut result = Ok(());
        for (i, &(stage, code)) in stages.iter().enumerate() {
            match compile(f, stage, code) {
                Ok(s) => {
                    objects[i] = s;
                    (f.attach_shader)(p, s);
                }
                Err(e) => {
                    result = Err(e);
                    break;
                }
            }
        }
        if result.is_ok() {
            (f.link_program)(p);
            let mut ok = 0;
            (f.get_programiv)(p, gl::LINK_STATUS, &mut ok);
            if ok == 0 {
                result = Err(Error::LinkFailed);
            }
        }
        for s in objects.into_iter().filter(|&s| s != 0) {
            (f.delete_shader)(s);
        }
        if let Err(e) = result {
            (f.delete_program)(p);
            return Err(e);
        }
        (f.use_program)(p);
        for b in t.blocks {
            let i = (f.get_uniform_block_index)(p, b.name.as_ptr().cast());
            if i != gl::INVALID_INDEX {
                (f.uniform_block_binding)(p, i, b.slot);
            }
        }
        for u in t.textures {
            let loc = (f.get_uniform_location)(p, u.name.as_ptr().cast());
            if loc >= 0 {
                (f.uniform1i)(loc, u.slot as Int);
            }
        }
        (f.use_program)(0);
        Ok(p)
    }
}

fn glsl_of<S: ShaderSource>(entry: &CStr) -> Result<&'static str, Error> {
    let entry = entry.to_str().map_err(|_| Error::NoCode)?;
    S::GLSL
        .iter()
        .find(|s| s.entry_point == entry)
        .map(|s| s.code)
        .ok_or(Error::NoCode)
}

impl Device<'_> {
    pub fn create_arena(
        &self,
        _bytes: u64,
        _kind: MemoryKind,
        _bind_groups: u32,
    ) -> Result<Arena, Error> {
        Ok(Arena)
    }
    pub fn destroy_arena(&self, _a: Arena) {}
    pub fn create_staging(&self, _host: &mut Arena, _bytes: u64) -> Result<Staging, Error> {
        Ok(Staging)
    }
    pub fn destroy_staging(&self, _s: Staging) {}

    pub fn create_buffer(&self, _arena: &mut Arena, d: &BufferDescriptor) -> Result<Buffer, Error> {
        let f = self.fns;
        let mut b = Buffer {
            handle: 0,
            size: d.size,
        };
        unsafe {
            (f.gen_buffers)(1, &mut b.handle);
            (f.bind_buffer)(gl::COPY_WRITE_BUFFER, b.handle);
            (f.buffer_data)(
                gl::COPY_WRITE_BUFFER,
                d.size as Sizeiptr,
                core::ptr::null(),
                gl::DYNAMIC_DRAW,
            );
            (f.bind_buffer)(gl::COPY_WRITE_BUFFER, 0);
        }
        Ok(b)
    }
    pub fn destroy_buffer(&self, b: &Buffer) {
        unsafe { (self.fns.delete_buffers)(1, &b.handle) };
    }
    /// Copies `out.len()` bytes of `b` from `offset`, waiting for the GPU (WebGPU's `map_async`
    /// and `get_mapped_range`, synchronous: the caller knows the writes are done).
    pub fn read_buffer(&self, b: &Buffer, offset: u64, out: &mut [u8]) {
        let f = self.fns;
        unsafe {
            (f.bind_buffer)(gl::COPY_READ_BUFFER, b.handle);
            let p = (f.map_buffer_range)(
                gl::COPY_READ_BUFFER,
                offset as Intptr,
                out.len() as Sizeiptr,
                gl::MAP_READ_BIT,
            );
            if !p.is_null() {
                core::ptr::copy_nonoverlapping(p.cast::<u8>(), out.as_mut_ptr(), out.len());
            }
            (f.unmap_buffer)(gl::COPY_READ_BUFFER);
            (f.bind_buffer)(gl::COPY_READ_BUFFER, 0);
        }
    }

    pub fn create_texture(
        &self,
        _arena: &mut Arena,
        d: &TextureDescriptor,
    ) -> Result<Texture, Error> {
        let f = self.fns;
        let fmt = d.format.gl()?;
        let mut t = Texture {
            handle: 0,
            renderbuffer: 0,
            fbo: 0,
            format: d.format,
            width: d.width,
            height: d.height,
            samples: d.sample_count,
        };
        unsafe {
            if d.sample_count > 1 {
                // GL ES 3.0 multisamples only renderbuffers: a multisampled target is drawn and resolved.
                (f.gen_renderbuffers)(1, &mut t.renderbuffer);
                (f.bind_renderbuffer)(gl::RENDERBUFFER, t.renderbuffer);
                (f.renderbuffer_storage_multisample)(
                    gl::RENDERBUFFER,
                    d.sample_count as Sizei,
                    fmt.internal,
                    d.width as Sizei,
                    d.height as Sizei,
                );
            } else {
                (f.gen_textures)(1, &mut t.handle);
                (f.bind_texture)(gl::TEXTURE_2D, t.handle);
                (f.tex_storage_2d)(
                    gl::TEXTURE_2D,
                    d.mip_level_count.max(1) as Sizei,
                    fmt.internal,
                    d.width as Sizei,
                    d.height as Sizei,
                );
                // Complete without a sampler object; a bound sampler overrides these.
                (f.tex_parameteri)(gl::TEXTURE_2D, gl::TEXTURE_MIN_FILTER, gl::NEAREST);
                (f.tex_parameteri)(gl::TEXTURE_2D, gl::TEXTURE_MAG_FILTER, gl::NEAREST);
            }
            if d.usage.has(TextureUsages::RENDER_ATTACHMENT) {
                (f.gen_framebuffers)(1, &mut t.fbo);
                (f.bind_framebuffer)(gl::FRAMEBUFFER, t.fbo);
                if t.renderbuffer != 0 {
                    (f.framebuffer_renderbuffer)(
                        gl::FRAMEBUFFER,
                        gl::COLOR_ATTACHMENT0,
                        gl::RENDERBUFFER,
                        t.renderbuffer,
                    );
                } else {
                    (f.framebuffer_texture_2d)(
                        gl::FRAMEBUFFER,
                        gl::COLOR_ATTACHMENT0,
                        gl::TEXTURE_2D,
                        t.handle,
                        0,
                    );
                }
                let status = (f.check_framebuffer_status)(gl::FRAMEBUFFER);
                (f.bind_framebuffer)(gl::FRAMEBUFFER, 0);
                if status != gl::FRAMEBUFFER_COMPLETE {
                    self.destroy_texture(&t);
                    return Err(Error::IncompleteFramebuffer);
                }
            }
        }
        Ok(t)
    }
    pub fn destroy_texture(&self, t: &Texture) {
        let f = self.fns;
        unsafe {
            if t.fbo != 0 {
                (f.delete_framebuffers)(1, &t.fbo);
            }
            if t.handle != 0 {
                (f.delete_textures)(1, &t.handle);
            }
            if t.renderbuffer != 0 {
                (f.delete_renderbuffers)(1, &t.renderbuffer);
            }
        }
    }

    pub fn create_sampler(&self, d: &SamplerDescriptor) -> Result<Sampler, Error> {
        let f = self.fns;
        let mut s = Sampler { handle: 0 };
        let linear = d.min_filter == FilterMode::Linear;
        let min = match (d.mipmap_filter == FilterMode::Linear, linear) {
            (true, true) => gl::LINEAR_MIPMAP_LINEAR,
            (true, false) => gl::NEAREST_MIPMAP_LINEAR,
            (false, true) => gl::LINEAR_MIPMAP_NEAREST,
            (false, false) => gl::NEAREST_MIPMAP_NEAREST,
        };
        unsafe {
            (f.gen_samplers)(1, &mut s.handle);
            (f.sampler_parameteri)(s.handle, gl::TEXTURE_MIN_FILTER, min);
            (f.sampler_parameteri)(
                s.handle,
                gl::TEXTURE_MAG_FILTER,
                if d.mag_filter == FilterMode::Linear {
                    gl::LINEAR
                } else {
                    gl::NEAREST
                },
            );
            (f.sampler_parameteri)(s.handle, gl::TEXTURE_WRAP_S, wrap_mode(d.address_mode_u));
            (f.sampler_parameteri)(s.handle, gl::TEXTURE_WRAP_T, wrap_mode(d.address_mode_v));
            (f.sampler_parameteri)(s.handle, gl::TEXTURE_WRAP_R, wrap_mode(d.address_mode_w));
            (f.sampler_parameterf)(s.handle, gl::TEXTURE_MIN_LOD, d.lod_min_clamp);
            (f.sampler_parameterf)(s.handle, gl::TEXTURE_MAX_LOD, d.lod_max_clamp);
        }
        Ok(s)
    }
    pub fn destroy_sampler(&self, s: &Sampler) {
        unsafe { (self.fns.delete_samplers)(1, &s.handle) };
    }

    /// A pipeline for shader `S`: its program linked from naga's GLSL ES, its vertex layout and
    /// the fixed-function state `set_pipeline` sets.
    pub fn create_render_pipeline<S: ShaderSource>(
        &self,
        d: &RenderPipelineDescriptor<'_>,
    ) -> Result<RenderPipelineOf<S>, Error> {
        let f = self.fns;
        let vs = glsl_of::<S>(d.vertex.entry_point)?;
        let fs = glsl_of::<S>(d.fragment.map(|x| x.entry_point).unwrap_or(c"fs"))?;
        let program = link(
            f,
            &S::GLES,
            &[(gl::VERTEX_SHADER, vs), (gl::FRAGMENT_SHADER, fs)],
        )?;
        let mut vao = 0;
        unsafe { (f.gen_vertex_arrays)(1, &mut vao) };
        let mut p = RenderPipeline {
            program,
            vao,
            mode: match d.topology {
                PrimitiveTopology::PointList => gl::POINTS,
                PrimitiveTopology::LineList => gl::LINES,
                PrimitiveTopology::LineStrip => gl::LINE_STRIP,
                PrimitiveTopology::TriangleList => gl::TRIANGLES,
                PrimitiveTopology::TriangleStrip => gl::TRIANGLE_STRIP,
            },
            buffers: [VertexBuffer::default(); MAX_VERTEX_BUFFERS],
            attributes: [NO_ATTRIBUTE; MAX_VERTEX_ATTRIBUTES],
            cull: d.cull_mode,
            front_ccw: d.front_face_ccw,
            restart: false,
            blend: None,
            write_mask: 0xf,
        };
        let mut n = 0;
        for (slot, vb) in d.vertex.buffers.iter().enumerate() {
            p.buffers[slot] = VertexBuffer {
                stride: vb.array_stride as u32,
                instance: vb.step_mode_instance,
                first: n as u8,
                count: vb.attributes.len() as u8,
            };
            for a in vb.attributes {
                p.attributes[n] = Attribute {
                    location: a.shader_location,
                    format: a.format,
                    offset: a.offset as u32,
                };
                n += 1;
            }
        }
        if let Some(t) = d.fragment.and_then(|fr| fr.targets.first().copied()) {
            p.blend = t.blend;
            p.write_mask = t.write_mask;
        }
        Ok(RenderPipelineOf {
            raw: p,
            _s: PhantomData,
        })
    }

    pub fn create_compute_pipeline<S: ShaderSource>(
        &self,
        entry_point: &CStr,
    ) -> Result<ComputePipelineOf<S>, Error> {
        if !self.fns.has_compute() {
            return Err(Error::NoCompute);
        }
        let cs = glsl_of::<S>(entry_point)?;
        let program = link(self.fns, &S::GLES, &[(gl::COMPUTE_SHADER, cs)])?;
        Ok(ComputePipelineOf {
            raw: ComputePipeline { program },
            _s: PhantomData,
        })
    }

    pub fn destroy_render_pipeline(&self, p: &RenderPipeline) {
        unsafe {
            (self.fns.delete_program)(p.program);
            (self.fns.delete_vertex_arrays)(1, &p.vao);
        }
    }
    pub fn destroy_compute_pipeline(&self, p: &ComputePipeline) {
        unsafe { (self.fns.delete_program)(p.program) };
    }

    /// A bind group for `group` (a generated `GroupN` of the pipeline's shader): the GL names to
    /// bind, and the shader's binding table for the group.
    pub fn create_bind_group<P: PipelineOf, G: Group<Shader = P::Shader>>(
        &self,
        _arena: &mut Arena,
        _pipeline: &P,
        group: &G,
    ) -> Result<G::BindGroup, Error>
    where
        P::Shader: ShaderSource,
    {
        let mut rs = [Resource::EMPTY; 16];
        let n = group.resources(&mut rs);
        let mut g = GlesGroup {
            names: [0; 16],
            sizes: [0; 16],
            table: <P::Shader as ShaderSource>::GLES.groups[G::INDEX as usize],
        };
        for (i, r) in rs[..n].iter().enumerate() {
            g.names[i] = r.name;
            g.sizes[i] = r.size;
        }
        Ok(g.into())
    }
}
