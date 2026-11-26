//! `lcgf_render.gpu` for Rust, shaped like the `wgpu` crate, on the back end a feature picks:
//! Vulkan (`ash`'s types, the default), GL ES 3 (`gles`), wgpu-native (`wgpu`), Metal (`metal`,
//! through the Objective-C runtime opened at run time) or Direct3D 12 (`d3d12`, on bindings that
//! windows-bindgen generated from Microsoft's metadata). As in Zig
//! (`-Drender`), one back end per build: the types are that back end's handles with public
//! fields, and a call is the native call it stands for.
//!
//! - `Upload::finish(self)` consumes the upload, so no write can follow it in the frame.
//! - A pass ends when it is dropped, as in wgpu.
//!
//! Pipelines and bind groups come from a shader that `include_shader!` reflected from WGSL: a
//! `GroupN` struct with one field per binding, and a pipeline tied to its shader, so a bind
//! group of another shader does not compile.
//!
//! ```ignore
//! let mut up = gpu::Upload::new(&device, cmd);
//! up.write_buffer(&tint, 0, &opacity.to_le_bytes());
//! let encoder = up.finish(); // `up` moved: no writes after this
//! let mut pass = encoder.begin_render_pass(&desc);
//! pass.set_pipeline(&pipeline);
//! pass.set_bind_group(0, &group, &[]);
//! pass.draw(0..3, 0..1);
//! ```
//!
//! bindings/check/run.sh runs check.zig's checks with each back end on a real device, and
//! records a Vulkan frame through this module and through the Zig projection, requiring the
//! same native calls.

use core::ffi::CStr;

#[cfg(any(
    all(feature = "gles", feature = "wgpu"),
    all(feature = "gles", feature = "metal"),
    all(feature = "wgpu", feature = "metal"),
    all(
        feature = "d3d12",
        any(feature = "gles", feature = "wgpu", feature = "metal")
    )
))]
compile_error!(
    "lcgf: pick one GPU back end: the `gles`, `wgpu`, `metal` and `d3d12` features exclude each other"
);

#[cfg(not(any(
    feature = "gles",
    feature = "wgpu",
    feature = "metal",
    feature = "d3d12"
)))]
mod vulkan;
#[cfg(not(any(
    feature = "gles",
    feature = "wgpu",
    feature = "metal",
    feature = "d3d12"
)))]
pub use vulkan::*;
#[cfg(feature = "gles")]
mod gles;
#[cfg(feature = "gles")]
pub use gles::*;
#[cfg(all(feature = "wgpu", not(feature = "gles")))]
mod wgpu;
#[cfg(all(feature = "wgpu", not(feature = "gles")))]
pub use self::wgpu::*;
#[cfg(all(feature = "metal", not(any(feature = "gles", feature = "wgpu"))))]
mod metal;
#[cfg(all(feature = "metal", not(any(feature = "gles", feature = "wgpu"))))]
pub use metal::*;
#[cfg(all(
    feature = "d3d12",
    not(any(feature = "gles", feature = "wgpu", feature = "metal"))
))]
mod d3d12;
#[cfg(all(
    feature = "d3d12",
    not(any(feature = "gles", feature = "wgpu", feature = "metal"))
))]
pub use d3d12::*;

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Color {
    pub r: f64,
    pub g: f64,
    pub b: f64,
    pub a: f64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TextureFormat {
    R8Unorm,
    Rg8Unorm,
    Rgba8Unorm,
    Rgba8UnormSrgb,
    Bgra8Unorm,
    Bgra8UnormSrgb,
    R16Float,
    Rgba16Float,
    R32Float,
    Rg32Float,
    Rgba32Float,
    R32Uint,
    Depth32Float,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum IndexFormat {
    Uint16,
    Uint32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BindingKind {
    Uniform,
    StorageRead,
    StorageReadWrite,
    Texture,
    StorageTexture,
    Sampler,
    ComparisonSampler,
}

/// One binding of a group, as lcgf-gen reflects it from WGSL.
#[derive(Clone, Copy, Debug)]
pub struct BindingLayout {
    pub binding: u32,
    pub kind: BindingKind,
}

pub const MAX_GROUPS: usize = 4;

/// What a shader brings, as `include_shader!` writes it from WGSL: its bind group layouts and
/// the code of each back end it was built for (naga's SPIR-V for Vulkan, naga's GLSL ES with
/// LCGF's binding table for GL ES; wgpu takes the WGSL itself). A back end whose code is
/// missing refuses the pipeline.
pub trait ShaderSource {
    const WGSL: &'static str;
    const GROUPS: &'static [&'static [BindingLayout]];
    const SPIRV: &'static [u32] = &[];
    const GLSL: &'static [GlslStage] = &[];
    const GLES: GlesTable = GlesTable::EMPTY;
    /// naga's MSL with its slots, NUL-terminated; empty when the shader was not built for Metal.
    const MSL: &'static str = "";
    /// naga's HLSL with its samplers registered, NUL-terminated; empty when the shader was not
    /// built for D3D12. Its root signature comes from `GROUPS`.
    const HLSL: &'static str = "";
    const METAL: MetalTable = MetalTable::EMPTY;
}

#[derive(Clone, Copy, Debug)]
pub enum LoadOp {
    Clear(Color),
    Load,
}

#[derive(Clone, Copy, Debug)]
pub enum StoreOp {
    Store,
    Discard,
}

#[derive(Clone, Copy, Debug)]
pub struct Operations {
    pub load: LoadOp,
    pub store: StoreOp,
}

impl Default for Operations {
    fn default() -> Self {
        Self {
            load: LoadOp::Clear(Color::default()),
            store: StoreOp::Store,
        }
    }
}

/// Usage bits, as wgpu's `BufferUsages`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BufferUsages(pub u32);

impl BufferUsages {
    pub const MAP_READ: Self = Self(1);
    pub const MAP_WRITE: Self = Self(2);
    pub const COPY_SRC: Self = Self(4);
    pub const COPY_DST: Self = Self(8);
    pub const INDEX: Self = Self(16);
    pub const VERTEX: Self = Self(32);
    pub const UNIFORM: Self = Self(64);
    pub const STORAGE: Self = Self(128);
    pub const INDIRECT: Self = Self(256);
    #[allow(dead_code)] // the back ends that read usages
    pub(crate) fn has(self, o: Self) -> bool {
        self.0 & o.0 != 0
    }
}

impl core::ops::BitOr for BufferUsages {
    type Output = Self;
    fn bitor(self, o: Self) -> Self {
        Self(self.0 | o.0)
    }
}

/// Usage bits, as wgpu's `TextureUsages`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TextureUsages(pub u32);

impl TextureUsages {
    pub const COPY_SRC: Self = Self(1);
    pub const COPY_DST: Self = Self(2);
    pub const TEXTURE_BINDING: Self = Self(4);
    pub const STORAGE_BINDING: Self = Self(8);
    pub const RENDER_ATTACHMENT: Self = Self(16);
    #[allow(dead_code)] // the back ends that read usages
    pub(crate) fn has(self, o: Self) -> bool {
        self.0 & o.0 != 0
    }
}

impl core::ops::BitOr for TextureUsages {
    type Output = Self;
    fn bitor(self, o: Self) -> Self {
        Self(self.0 | o.0)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MemoryKind {
    Device,
    Host,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FilterMode {
    Nearest,
    Linear,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AddressMode {
    ClampToEdge,
    Repeat,
    MirrorRepeat,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VertexFormat {
    Float32,
    Float32x2,
    Float32x3,
    Float32x4,
    Uint32,
    Uint32x2,
    Uint32x4,
    Sint32,
    Unorm8x4,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BlendFactor {
    Zero,
    One,
    Src,
    OneMinusSrc,
    SrcAlpha,
    OneMinusSrcAlpha,
    Dst,
    OneMinusDst,
    DstAlpha,
    OneMinusDstAlpha,
    Constant,
    OneMinusConstant,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BlendOperation {
    Add,
    Subtract,
    ReverseSubtract,
    Min,
    Max,
}

#[derive(Clone, Copy, Debug)]
pub struct BlendComponent {
    pub operation: BlendOperation,
    pub src_factor: BlendFactor,
    pub dst_factor: BlendFactor,
}

#[derive(Clone, Copy, Debug)]
pub struct BlendState {
    pub color: BlendComponent,
    pub alpha: BlendComponent,
}

impl BlendState {
    /// What the UI draws with: premultiplied colour over what is there.
    pub const PREMULTIPLIED: Self = {
        let c = BlendComponent {
            operation: BlendOperation::Add,
            src_factor: BlendFactor::One,
            dst_factor: BlendFactor::OneMinusSrcAlpha,
        };
        Self { color: c, alpha: c }
    };
}

pub struct BufferDescriptor {
    pub size: u64,
    pub usage: BufferUsages,
}

pub struct TextureDescriptor {
    pub width: u32,
    pub height: u32,
    pub format: TextureFormat,
    pub usage: TextureUsages,
    pub mip_level_count: u32,
    pub sample_count: u32,
}

#[derive(Clone, Copy)]
pub struct SamplerDescriptor {
    pub address_mode_u: AddressMode,
    pub address_mode_v: AddressMode,
    pub address_mode_w: AddressMode,
    pub mag_filter: FilterMode,
    pub min_filter: FilterMode,
    pub mipmap_filter: FilterMode,
    pub lod_min_clamp: f32,
    pub lod_max_clamp: f32,
}

impl Default for SamplerDescriptor {
    fn default() -> Self {
        Self {
            address_mode_u: AddressMode::ClampToEdge,
            address_mode_v: AddressMode::ClampToEdge,
            address_mode_w: AddressMode::ClampToEdge,
            mag_filter: FilterMode::Nearest,
            min_filter: FilterMode::Nearest,
            mipmap_filter: FilterMode::Nearest,
            lod_min_clamp: 0.0,
            lod_max_clamp: 32.0,
        }
    }
}

#[derive(Clone, Copy)]
pub struct VertexAttribute {
    pub format: VertexFormat,
    pub offset: u64,
    pub shader_location: u32,
}

#[derive(Clone, Copy)]
pub struct VertexBufferLayout<'a> {
    pub array_stride: u64,
    pub step_mode_instance: bool,
    pub attributes: &'a [VertexAttribute],
}

#[derive(Clone, Copy)]
pub struct ColorTargetState {
    pub format: TextureFormat,
    /// `None` replaces what is there.
    pub blend: Option<BlendState>,
    pub write_mask: u32,
}

#[derive(Clone, Copy)]
pub struct VertexState<'a> {
    pub entry_point: &'a CStr,
    pub buffers: &'a [VertexBufferLayout<'a>],
}

#[derive(Clone, Copy)]
pub struct FragmentState<'a> {
    pub entry_point: &'a CStr,
    pub targets: &'a [ColorTargetState],
}

#[derive(Clone, Copy)]
pub struct RenderPipelineDescriptor<'a> {
    pub vertex: VertexState<'a>,
    pub fragment: Option<FragmentState<'a>>,
    pub topology: PrimitiveTopology,
    pub cull_mode: CullMode,
    pub front_face_ccw: bool,
    pub sample_count: u32,
}

impl TextureFormat {
    pub fn bytes_per_pixel(self) -> u32 {
        use TextureFormat::*;
        match self {
            R8Unorm => 1,
            Rg8Unorm | R16Float => 2,
            Rgba16Float | Rg32Float => 8,
            Rgba32Float => 16,
            _ => 4,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PrimitiveTopology {
    PointList,
    LineList,
    LineStrip,
    TriangleList,
    TriangleStrip,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CullMode {
    None,
    Front,
    Back,
}

// ---- GL ES: what a shader brings for it ---------------------------------------------------------

/// One entry point's GLSL ES, as naga wrote it with LCGF's bindings added (src/render/gpu/naga.zig).
#[derive(Clone, Copy, Debug)]
pub struct GlslStage {
    pub entry_point: &'static str,
    /// NUL-terminated.
    pub code: &'static str,
}

/// A name in the GLSL and the binding point or texture unit it gets after linking.
#[derive(Clone, Copy, Debug)]
pub struct GlslName {
    /// NUL-terminated.
    pub name: &'static str,
    pub slot: u32,
}

/// How a binding is bound on GL ES: its binding point or unit, the sampler of its group a
/// texture is sampled with, and a storage texture's format and access (GL enums).
#[derive(Clone, Copy, Debug)]
pub struct GlesBinding {
    pub kind: BindingKind,
    pub unit: u32,
    /// Index in the group of the sampler bound on this texture's unit, or `u32::MAX`.
    pub sampler: u32,
    pub format: u32,
    pub access: u32,
}

/// The binding table GL ES replays: per group its bindings, and the names bound after linking.
#[derive(Clone, Copy, Debug)]
pub struct GlesTable {
    pub groups: &'static [&'static [GlesBinding]],
    pub blocks: &'static [GlslName],
    pub textures: &'static [GlslName],
}

impl GlesTable {
    pub const EMPTY: Self = Self {
        groups: &[],
        blocks: &[],
        textures: &[],
    };
}

// ---- Metal: what a shader brings for it ---------------------------------------------------------

/// How a binding is bound on Metal: its slot (buffers, textures and samplers numbered apart, in
/// (group, binding) order: src/render/gpu/naga.zig), and for a runtime-sized storage array its
/// index in naga's `_buffer_sizes` (`u32::MAX` otherwise).
#[derive(Clone, Copy, Debug)]
pub struct MetalBinding {
    pub kind: BindingKind,
    pub slot: u32,
    pub sized: u32,
}

/// The binding table Metal replays: per group its bindings, how many runtime-sized arrays the
/// shader has and the buffer slot their lengths go to, and the compute workgroup size.
#[derive(Clone, Copy, Debug)]
pub struct MetalTable {
    pub groups: &'static [&'static [MetalBinding]],
    pub sized: u32,
    pub sizes_slot: u32,
    pub workgroup: [u32; 3],
}

impl MetalTable {
    pub const EMPTY: Self = Self {
        groups: &[],
        sized: 0,
        sizes_slot: 0,
        workgroup: [1, 1, 1],
    };
}
