//! The wgpu-native back end of `lcgf::gpu` (feature `wgpu`): src/render/wgpu/gpu.zig, inline.
//!
//! The projection is the identity: a type is the `webgpu.h` handle it names (`pass.as_raw()` is
//! the `WGPURenderPassEncoder`), a call is one `wgpu*` call. The WGSL goes to wgpu as written;
//! bind group layouts are the pipeline's own (WebGPU's "auto"), which is why
//! `create_bind_group` takes the pipeline. The phases are WebGPU's: `Upload` writes through the
//! queue, ordered before the commands submitted after it. It links wgpu-native
//! (`zig build abi -Dwgpu-native=v29` installs it beside liblcgf).
//!
//! `ffi` is the part of webgpu.h this uses, for wgpu-native v29; bindings/check/run.sh compares
//! every struct's size and field offsets with the C header's.

use super::*;
use core::ffi::c_void;
use core::marker::PhantomData;
use core::ops::Range;

/// The part of webgpu.h (wgpu-native v29) the projection calls, with its own names.
#[allow(
    non_camel_case_types,
    non_snake_case,
    non_upper_case_globals,
    missing_docs
)]
pub mod ffi {
    use core::ffi::{c_char, c_void};

    macro_rules! handles {
        ($($name:ident),*) => { $(pub type $name = *mut c_void;)* };
    }
    handles!(
        WGPUInstance,
        WGPUAdapter,
        WGPUDevice,
        WGPUQueue,
        WGPUBuffer,
        WGPUTexture,
        WGPUTextureView,
        WGPUSampler,
        WGPUShaderModule,
        WGPURenderPipeline,
        WGPUComputePipeline,
        WGPUBindGroup,
        WGPUBindGroupLayout,
        WGPUCommandEncoder,
        WGPUCommandBuffer,
        WGPURenderPassEncoder,
        WGPUComputePassEncoder,
        WGPUPipelineLayout
    );
    pub type WGPUFlags = u64;
    pub type WGPUBool = u32;
    pub const WGPU_STRLEN: usize = usize::MAX;
    pub const WGPU_WHOLE_SIZE: u64 = u64::MAX;
    pub const WGPU_DEPTH_SLICE_UNDEFINED: u32 = u32::MAX;

    pub const WGPUSType_ShaderSourceWGSL: u32 = 0x2;
    pub const WGPUSType_InstanceExtras: u32 = 0x30004;
    pub const WGPUTextureDimension_2D: u32 = 0x2;
    pub const WGPUTextureAspect_All: u32 = 0x1;
    pub const WGPULoadOp_Load: u32 = 0x1;
    pub const WGPULoadOp_Clear: u32 = 0x2;
    pub const WGPUStoreOp_Store: u32 = 0x1;
    pub const WGPUStoreOp_Discard: u32 = 0x2;
    pub const WGPUCallbackMode_AllowProcessEvents: u32 = 0x2;
    pub const WGPUMapMode_Read: u64 = 0x1;
    pub const WGPUMapAsyncStatus_Success: u32 = 0x1;
    pub const WGPUBufferUsage_MapRead: u64 = 0x1;
    pub const WGPUBufferUsage_CopyDst: u64 = 0x8;
    pub const WGPUVertexStepMode_Vertex: u32 = 0x1;
    pub const WGPUVertexStepMode_Instance: u32 = 0x2;
    pub const WGPUIndexFormat_Uint16: u32 = 0x1;
    pub const WGPUIndexFormat_Uint32: u32 = 0x2;
    pub const WGPUFrontFace_CCW: u32 = 0x1;
    pub const WGPUFrontFace_CW: u32 = 0x2;
    pub const WGPUFilterMode_Nearest: u32 = 0x1;
    pub const WGPUFilterMode_Linear: u32 = 0x2;
    pub const WGPUMipmapFilterMode_Nearest: u32 = 0x1;
    pub const WGPUMipmapFilterMode_Linear: u32 = 0x2;
    pub const WGPURequestAdapterStatus_Success: u32 = 0x1;
    pub const WGPURequestDeviceStatus_Success: u32 = 0x1;
    pub const WGPUInstanceBackend_Vulkan: u64 = 0x1;

    #[repr(C)]
    #[derive(Clone, Copy)]
    pub struct WGPUStringView {
        pub data: *const c_char,
        pub length: usize,
    }
    impl WGPUStringView {
        pub const NULL: Self = Self {
            data: core::ptr::null(),
            length: WGPU_STRLEN,
        };
    }
    #[repr(C)]
    #[derive(Clone, Copy)]
    pub struct WGPUChainedStruct {
        pub next: *mut WGPUChainedStruct,
        pub sType: u32,
    }

    macro_rules! zeroed {
        ($($name:ident),*) => {
            $(impl Default for $name {
                fn default() -> Self {
                    // Every field of these is a pointer, an integer, a float or a struct of those:
                    // all-zero is webgpu.h's "undefined/default" for each.
                    unsafe { core::mem::zeroed() }
                }
            })*
        };
    }

    #[repr(C)]
    #[derive(Clone, Copy)]
    pub struct WGPUBufferDescriptor {
        pub nextInChain: *mut WGPUChainedStruct,
        pub label: WGPUStringView,
        pub usage: WGPUFlags,
        pub size: u64,
        pub mappedAtCreation: WGPUBool,
    }
    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    pub struct WGPUExtent3D {
        pub width: u32,
        pub height: u32,
        pub depthOrArrayLayers: u32,
    }
    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    pub struct WGPUOrigin3D {
        pub x: u32,
        pub y: u32,
        pub z: u32,
    }
    #[repr(C)]
    #[derive(Clone, Copy)]
    pub struct WGPUTextureDescriptor {
        pub nextInChain: *mut WGPUChainedStruct,
        pub label: WGPUStringView,
        pub usage: WGPUFlags,
        pub dimension: u32,
        pub size: WGPUExtent3D,
        pub format: u32,
        pub mipLevelCount: u32,
        pub sampleCount: u32,
        pub viewFormatCount: usize,
        pub viewFormats: *const u32,
    }
    #[repr(C)]
    #[derive(Clone, Copy)]
    pub struct WGPUSamplerDescriptor {
        pub nextInChain: *mut WGPUChainedStruct,
        pub label: WGPUStringView,
        pub addressModeU: u32,
        pub addressModeV: u32,
        pub addressModeW: u32,
        pub magFilter: u32,
        pub minFilter: u32,
        pub mipmapFilter: u32,
        pub lodMinClamp: f32,
        pub lodMaxClamp: f32,
        pub compare: u32,
        pub maxAnisotropy: u16,
    }
    #[repr(C)]
    #[derive(Clone, Copy)]
    pub struct WGPUShaderSourceWGSL {
        pub chain: WGPUChainedStruct,
        pub code: WGPUStringView,
    }
    #[repr(C)]
    #[derive(Clone, Copy)]
    pub struct WGPUShaderModuleDescriptor {
        pub nextInChain: *mut WGPUChainedStruct,
        pub label: WGPUStringView,
    }
    #[repr(C)]
    #[derive(Clone, Copy)]
    pub struct WGPUVertexAttribute {
        pub nextInChain: *mut WGPUChainedStruct,
        pub format: u32,
        pub offset: u64,
        pub shaderLocation: u32,
    }
    #[repr(C)]
    #[derive(Clone, Copy)]
    pub struct WGPUVertexBufferLayout {
        pub nextInChain: *mut WGPUChainedStruct,
        pub stepMode: u32,
        pub arrayStride: u64,
        pub attributeCount: usize,
        pub attributes: *const WGPUVertexAttribute,
    }
    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    pub struct WGPUBlendComponent {
        pub operation: u32,
        pub srcFactor: u32,
        pub dstFactor: u32,
    }
    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    pub struct WGPUBlendState {
        pub color: WGPUBlendComponent,
        pub alpha: WGPUBlendComponent,
    }
    #[repr(C)]
    #[derive(Clone, Copy)]
    pub struct WGPUColorTargetState {
        pub nextInChain: *mut WGPUChainedStruct,
        pub format: u32,
        pub blend: *const WGPUBlendState,
        pub writeMask: WGPUFlags,
    }
    #[repr(C)]
    #[derive(Clone, Copy)]
    pub struct WGPUFragmentState {
        pub nextInChain: *mut WGPUChainedStruct,
        pub module: WGPUShaderModule,
        pub entryPoint: WGPUStringView,
        pub constantCount: usize,
        pub constants: *const c_void,
        pub targetCount: usize,
        pub targets: *const WGPUColorTargetState,
    }
    #[repr(C)]
    #[derive(Clone, Copy)]
    pub struct WGPUVertexState {
        pub nextInChain: *mut WGPUChainedStruct,
        pub module: WGPUShaderModule,
        pub entryPoint: WGPUStringView,
        pub constantCount: usize,
        pub constants: *const c_void,
        pub bufferCount: usize,
        pub buffers: *const WGPUVertexBufferLayout,
    }
    #[repr(C)]
    #[derive(Clone, Copy)]
    pub struct WGPUPrimitiveState {
        pub nextInChain: *mut WGPUChainedStruct,
        pub topology: u32,
        pub stripIndexFormat: u32,
        pub frontFace: u32,
        pub cullMode: u32,
        pub unclippedDepth: WGPUBool,
    }
    #[repr(C)]
    #[derive(Clone, Copy)]
    pub struct WGPUMultisampleState {
        pub nextInChain: *mut WGPUChainedStruct,
        pub count: u32,
        pub mask: u32,
        pub alphaToCoverageEnabled: WGPUBool,
    }
    #[repr(C)]
    #[derive(Clone, Copy)]
    pub struct WGPURenderPipelineDescriptor {
        pub nextInChain: *mut WGPUChainedStruct,
        pub label: WGPUStringView,
        pub layout: WGPUPipelineLayout,
        pub vertex: WGPUVertexState,
        pub primitive: WGPUPrimitiveState,
        pub depthStencil: *const c_void,
        pub multisample: WGPUMultisampleState,
        pub fragment: *const WGPUFragmentState,
    }
    #[repr(C)]
    #[derive(Clone, Copy)]
    pub struct WGPUComputeState {
        pub nextInChain: *mut WGPUChainedStruct,
        pub module: WGPUShaderModule,
        pub entryPoint: WGPUStringView,
        pub constantCount: usize,
        pub constants: *const c_void,
    }
    #[repr(C)]
    #[derive(Clone, Copy)]
    pub struct WGPUComputePipelineDescriptor {
        pub nextInChain: *mut WGPUChainedStruct,
        pub label: WGPUStringView,
        pub layout: WGPUPipelineLayout,
        pub compute: WGPUComputeState,
    }
    #[repr(C)]
    #[derive(Clone, Copy)]
    pub struct WGPUBindGroupEntry {
        pub nextInChain: *mut WGPUChainedStruct,
        pub binding: u32,
        pub buffer: WGPUBuffer,
        pub offset: u64,
        pub size: u64,
        pub sampler: WGPUSampler,
        pub textureView: WGPUTextureView,
    }
    #[repr(C)]
    #[derive(Clone, Copy)]
    pub struct WGPUBindGroupDescriptor {
        pub nextInChain: *mut WGPUChainedStruct,
        pub label: WGPUStringView,
        pub layout: WGPUBindGroupLayout,
        pub entryCount: usize,
        pub entries: *const WGPUBindGroupEntry,
    }
    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    pub struct WGPUColor {
        pub r: f64,
        pub g: f64,
        pub b: f64,
        pub a: f64,
    }
    #[repr(C)]
    #[derive(Clone, Copy)]
    pub struct WGPURenderPassColorAttachment {
        pub nextInChain: *mut WGPUChainedStruct,
        pub view: WGPUTextureView,
        pub depthSlice: u32,
        pub resolveTarget: WGPUTextureView,
        pub loadOp: u32,
        pub storeOp: u32,
        pub clearValue: WGPUColor,
    }
    #[repr(C)]
    #[derive(Clone, Copy)]
    pub struct WGPURenderPassDescriptor {
        pub nextInChain: *mut WGPUChainedStruct,
        pub label: WGPUStringView,
        pub colorAttachmentCount: usize,
        pub colorAttachments: *const WGPURenderPassColorAttachment,
        pub depthStencilAttachment: *const c_void,
        pub occlusionQuerySet: *mut c_void,
        pub timestampWrites: *const c_void,
    }
    #[repr(C)]
    #[derive(Clone, Copy)]
    pub struct WGPUTexelCopyTextureInfo {
        pub texture: WGPUTexture,
        pub mipLevel: u32,
        pub origin: WGPUOrigin3D,
        pub aspect: u32,
    }
    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    pub struct WGPUTexelCopyBufferLayout {
        pub offset: u64,
        pub bytesPerRow: u32,
        pub rowsPerImage: u32,
    }
    #[repr(C)]
    #[derive(Clone, Copy)]
    pub struct WGPUTexelCopyBufferInfo {
        pub layout: WGPUTexelCopyBufferLayout,
        pub buffer: WGPUBuffer,
    }
    pub type WGPUBufferMapCallback = unsafe extern "C" fn(
        status: u32,
        message: WGPUStringView,
        userdata1: *mut c_void,
        userdata2: *mut c_void,
    );
    #[repr(C)]
    #[derive(Clone, Copy)]
    pub struct WGPUBufferMapCallbackInfo {
        pub nextInChain: *mut WGPUChainedStruct,
        pub mode: u32,
        pub callback: Option<WGPUBufferMapCallback>,
        pub userdata1: *mut c_void,
        pub userdata2: *mut c_void,
    }
    #[repr(C)]
    #[derive(Clone, Copy)]
    pub struct WGPUFuture {
        pub id: u64,
    }
    zeroed!(
        WGPUBufferDescriptor,
        WGPUTextureDescriptor,
        WGPUSamplerDescriptor,
        WGPUShaderModuleDescriptor,
        WGPUVertexAttribute,
        WGPUVertexBufferLayout,
        WGPUColorTargetState,
        WGPUFragmentState,
        WGPURenderPipelineDescriptor,
        WGPUComputePipelineDescriptor,
        WGPUBindGroupEntry,
        WGPUBindGroupDescriptor,
        WGPURenderPassColorAttachment,
        WGPURenderPassDescriptor,
        WGPUTexelCopyTextureInfo,
        WGPUTexelCopyBufferInfo,
        WGPUBufferMapCallbackInfo
    );

    #[link(name = "wgpu_native")]
    unsafe extern "C" {
        pub fn wgpuDeviceCreateBuffer(
            device: WGPUDevice,
            d: *const WGPUBufferDescriptor,
        ) -> WGPUBuffer;
        pub fn wgpuBufferRelease(b: WGPUBuffer);
        pub fn wgpuBufferMapAsync(
            b: WGPUBuffer,
            mode: u64,
            offset: usize,
            size: usize,
            cb: WGPUBufferMapCallbackInfo,
        ) -> WGPUFuture;
        pub fn wgpuBufferGetConstMappedRange(
            b: WGPUBuffer,
            offset: usize,
            size: usize,
        ) -> *const c_void;
        pub fn wgpuBufferUnmap(b: WGPUBuffer);
        pub fn wgpuDeviceCreateTexture(
            device: WGPUDevice,
            d: *const WGPUTextureDescriptor,
        ) -> WGPUTexture;
        pub fn wgpuTextureCreateView(t: WGPUTexture, d: *const c_void) -> WGPUTextureView;
        pub fn wgpuTextureRelease(t: WGPUTexture);
        pub fn wgpuTextureViewRelease(v: WGPUTextureView);
        pub fn wgpuDeviceCreateSampler(
            device: WGPUDevice,
            d: *const WGPUSamplerDescriptor,
        ) -> WGPUSampler;
        pub fn wgpuSamplerRelease(s: WGPUSampler);
        pub fn wgpuDeviceCreateShaderModule(
            device: WGPUDevice,
            d: *const WGPUShaderModuleDescriptor,
        ) -> WGPUShaderModule;
        pub fn wgpuShaderModuleRelease(m: WGPUShaderModule);
        pub fn wgpuDeviceCreateRenderPipeline(
            device: WGPUDevice,
            d: *const WGPURenderPipelineDescriptor,
        ) -> WGPURenderPipeline;
        pub fn wgpuDeviceCreateComputePipeline(
            device: WGPUDevice,
            d: *const WGPUComputePipelineDescriptor,
        ) -> WGPUComputePipeline;
        pub fn wgpuRenderPipelineRelease(p: WGPURenderPipeline);
        pub fn wgpuComputePipelineRelease(p: WGPUComputePipeline);
        pub fn wgpuRenderPipelineGetBindGroupLayout(
            p: WGPURenderPipeline,
            group: u32,
        ) -> WGPUBindGroupLayout;
        pub fn wgpuComputePipelineGetBindGroupLayout(
            p: WGPUComputePipeline,
            group: u32,
        ) -> WGPUBindGroupLayout;
        pub fn wgpuBindGroupLayoutRelease(l: WGPUBindGroupLayout);
        pub fn wgpuDeviceCreateBindGroup(
            device: WGPUDevice,
            d: *const WGPUBindGroupDescriptor,
        ) -> WGPUBindGroup;
        pub fn wgpuBindGroupRelease(g: WGPUBindGroup);
        pub fn wgpuDeviceCreateCommandEncoder(
            device: WGPUDevice,
            d: *const c_void,
        ) -> WGPUCommandEncoder;
        pub fn wgpuCommandEncoderFinish(
            e: WGPUCommandEncoder,
            d: *const c_void,
        ) -> WGPUCommandBuffer;
        pub fn wgpuCommandEncoderRelease(e: WGPUCommandEncoder);
        pub fn wgpuCommandBufferRelease(c: WGPUCommandBuffer);
        pub fn wgpuCommandEncoderBeginRenderPass(
            e: WGPUCommandEncoder,
            d: *const WGPURenderPassDescriptor,
        ) -> WGPURenderPassEncoder;
        pub fn wgpuCommandEncoderBeginComputePass(
            e: WGPUCommandEncoder,
            d: *const c_void,
        ) -> WGPUComputePassEncoder;
        pub fn wgpuCommandEncoderCopyBufferToBuffer(
            e: WGPUCommandEncoder,
            src: WGPUBuffer,
            src_offset: u64,
            dst: WGPUBuffer,
            dst_offset: u64,
            size: u64,
        );
        pub fn wgpuCommandEncoderCopyTextureToBuffer(
            e: WGPUCommandEncoder,
            src: *const WGPUTexelCopyTextureInfo,
            dst: *const WGPUTexelCopyBufferInfo,
            size: *const WGPUExtent3D,
        );
        pub fn wgpuQueueSubmit(q: WGPUQueue, n: usize, commands: *const WGPUCommandBuffer);
        pub fn wgpuQueueWriteBuffer(
            q: WGPUQueue,
            b: WGPUBuffer,
            offset: u64,
            data: *const c_void,
            size: usize,
        );
        pub fn wgpuQueueWriteTexture(
            q: WGPUQueue,
            dst: *const WGPUTexelCopyTextureInfo,
            data: *const c_void,
            size: usize,
            layout: *const WGPUTexelCopyBufferLayout,
            extent: *const WGPUExtent3D,
        );
        pub fn wgpuRenderPassEncoderSetPipeline(
            p: WGPURenderPassEncoder,
            pipeline: WGPURenderPipeline,
        );
        pub fn wgpuRenderPassEncoderSetBindGroup(
            p: WGPURenderPassEncoder,
            index: u32,
            g: WGPUBindGroup,
            n: usize,
            offsets: *const u32,
        );
        pub fn wgpuRenderPassEncoderSetVertexBuffer(
            p: WGPURenderPassEncoder,
            slot: u32,
            b: WGPUBuffer,
            offset: u64,
            size: u64,
        );
        pub fn wgpuRenderPassEncoderSetIndexBuffer(
            p: WGPURenderPassEncoder,
            b: WGPUBuffer,
            format: u32,
            offset: u64,
            size: u64,
        );
        pub fn wgpuRenderPassEncoderSetViewport(
            p: WGPURenderPassEncoder,
            x: f32,
            y: f32,
            w: f32,
            h: f32,
            min: f32,
            max: f32,
        );
        pub fn wgpuRenderPassEncoderSetScissorRect(
            p: WGPURenderPassEncoder,
            x: u32,
            y: u32,
            w: u32,
            h: u32,
        );
        pub fn wgpuRenderPassEncoderSetBlendConstant(p: WGPURenderPassEncoder, c: *const WGPUColor);
        pub fn wgpuRenderPassEncoderDraw(
            p: WGPURenderPassEncoder,
            vertices: u32,
            instances: u32,
            first_vertex: u32,
            first_instance: u32,
        );
        pub fn wgpuRenderPassEncoderDrawIndexed(
            p: WGPURenderPassEncoder,
            indices: u32,
            instances: u32,
            first_index: u32,
            base_vertex: i32,
            first_instance: u32,
        );
        pub fn wgpuRenderPassEncoderEnd(p: WGPURenderPassEncoder);
        pub fn wgpuRenderPassEncoderRelease(p: WGPURenderPassEncoder);
        pub fn wgpuComputePassEncoderSetPipeline(
            p: WGPUComputePassEncoder,
            pipeline: WGPUComputePipeline,
        );
        pub fn wgpuComputePassEncoderSetBindGroup(
            p: WGPUComputePassEncoder,
            index: u32,
            g: WGPUBindGroup,
            n: usize,
            offsets: *const u32,
        );
        pub fn wgpuComputePassEncoderDispatchWorkgroups(
            p: WGPUComputePassEncoder,
            x: u32,
            y: u32,
            z: u32,
        );
        pub fn wgpuComputePassEncoderEnd(p: WGPUComputePassEncoder);
        pub fn wgpuComputePassEncoderRelease(p: WGPUComputePassEncoder);
        pub fn wgpuInstanceProcessEvents(i: WGPUInstance);
        pub fn wgpuDevicePoll(d: WGPUDevice, wait: WGPUBool, index: *const u64) -> WGPUBool;
    }
}

use ffi::*;

/// What creation reports.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
    PipelineFailed,
    MapFailed,
}

/// The host's device and queue; the instance runs map callbacks for `read_buffer`.
#[derive(Clone, Copy)]
pub struct Device<'a> {
    pub device: WGPUDevice,
    pub queue: WGPUQueue,
    pub instance: WGPUInstance,
    pub _host: PhantomData<&'a ()>,
}

impl Device<'_> {
    pub fn wrap(device: WGPUDevice, queue: WGPUQueue, instance: WGPUInstance) -> Self {
        Self {
            device,
            queue,
            instance,
            _host: PhantomData,
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub struct Buffer {
    pub handle: WGPUBuffer,
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
    pub view: WGPUTextureView,
    pub texture: WGPUTexture,
    pub width: u32,
    pub height: u32,
    pub samples: u32,
    pub format: TextureFormat,
}

#[derive(Clone, Copy, Debug)]
pub struct Texture {
    pub texture: WGPUTexture,
    /// The default view, made with the texture.
    pub view: WGPUTextureView,
    pub format: TextureFormat,
    pub width: u32,
    pub height: u32,
    pub samples: u32,
}

impl Texture {
    pub fn create_view(&self) -> TextureView {
        TextureView {
            view: self.view,
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
    pub handle: WGPUSampler,
}

#[derive(Clone, Copy, Debug)]
pub struct RenderPipeline {
    pub pipeline: WGPURenderPipeline,
}
#[derive(Clone, Copy, Debug)]
pub struct ComputePipeline {
    pub pipeline: WGPUComputePipeline,
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

/// The pipelines a bind group can be made for: either kind, tied to its shader, and the layout
/// it made for a group.
pub trait PipelineOf {
    type Shader;
    fn group_layout(&self, g: u32) -> WGPUBindGroupLayout;
}
impl<S> PipelineOf for RenderPipelineOf<S> {
    type Shader = S;
    fn group_layout(&self, g: u32) -> WGPUBindGroupLayout {
        unsafe { wgpuRenderPipelineGetBindGroupLayout(self.raw.pipeline, g) }
    }
}
impl<S> PipelineOf for ComputePipelineOf<S> {
    type Shader = S;
    fn group_layout(&self, g: u32) -> WGPUBindGroupLayout {
        unsafe { wgpuComputePipelineGetBindGroupLayout(self.raw.pipeline, g) }
    }
}

#[derive(Clone, Copy, Debug)]
pub struct BindGroup<const G: u32> {
    pub group: WGPUBindGroup,
}

impl<const G: u32> From<WGPUBindGroup> for BindGroup<G> {
    fn from(group: WGPUBindGroup) -> Self {
        Self { group }
    }
}

/// One resource of a bind group, as a generated `GroupN` lists them.
#[derive(Clone, Copy, Debug)]
pub struct Resource {
    pub binding: u32,
    pub kind: BindingKind,
    pub buffer: WGPUBuffer,
    pub view: WGPUTextureView,
    pub sampler: WGPUSampler,
}

impl Resource {
    pub const EMPTY: Self = Self {
        binding: 0,
        kind: BindingKind::Uniform,
        buffer: core::ptr::null_mut(),
        view: core::ptr::null_mut(),
        sampler: core::ptr::null_mut(),
    };
    pub fn buffer(binding: u32, kind: BindingKind, b: &Buffer) -> Self {
        Self {
            binding,
            kind,
            buffer: b.handle,
            ..Self::EMPTY
        }
    }
    pub fn view(binding: u32, kind: BindingKind, v: &TextureView) -> Self {
        Self {
            binding,
            kind,
            view: v.view,
            ..Self::EMPTY
        }
    }
    pub fn sampler(binding: u32, kind: BindingKind, s: &Sampler) -> Self {
        Self {
            binding,
            kind,
            sampler: s.handle,
            ..Self::EMPTY
        }
    }
}

/// A generated `GroupN`: the shader it belongs to, its index, and its resources.
pub trait Group {
    type Shader: ShaderSource;
    type BindGroup: From<WGPUBindGroup>;
    const INDEX: u32;
    /// Writes the resources into `out`; returns how many.
    fn resources(&self, out: &mut [Resource; 16]) -> usize;
}

/// WebGPU allocates its own memory: an arena is only the projection's uniform interface.
pub struct Arena;
/// WebGPU stages writes itself; staging exists for the uniform interface.
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

fn sv(s: &CStr) -> WGPUStringView {
    WGPUStringView {
        data: s.as_ptr(),
        length: WGPU_STRLEN,
    }
}

impl TextureFormat {
    fn wgpu(self) -> u32 {
        use TextureFormat::*;
        match self {
            R8Unorm => 0x01,
            Rg8Unorm => 0x0a,
            Rgba8Unorm => 0x16,
            Rgba8UnormSrgb => 0x17,
            Bgra8Unorm => 0x1b,
            Bgra8UnormSrgb => 0x1c,
            R16Float => 0x09,
            Rgba16Float => 0x28,
            R32Float => 0x0e,
            Rg32Float => 0x21,
            Rgba32Float => 0x29,
            R32Uint => 0x0f,
            Depth32Float => 0x30,
        }
    }
}

fn vertex_format(f: VertexFormat) -> u32 {
    use VertexFormat::*;
    match f {
        Float32 => 0x1c,
        Float32x2 => 0x1d,
        Float32x3 => 0x1e,
        Float32x4 => 0x1f,
        Uint32 => 0x20,
        Uint32x2 => 0x21,
        Uint32x4 => 0x23,
        Sint32 => 0x24,
        Unorm8x4 => 0x09,
    }
}

fn blend(b: &BlendComponent) -> WGPUBlendComponent {
    // webgpu.h numbers factors from Zero = 1 in our order, skipping 0xb (SrcAlphaSaturated).
    let factor = |f: BlendFactor| match f as u32 {
        n @ 0..=9 => n + 1,
        n => n + 2,
    };
    WGPUBlendComponent {
        operation: b.operation as u32 + 1,
        srcFactor: factor(b.src_factor),
        dstFactor: factor(b.dst_factor),
    }
}

fn shader_module(device: WGPUDevice, wgsl: &str) -> WGPUShaderModule {
    let source = WGPUShaderSourceWGSL {
        chain: WGPUChainedStruct {
            next: core::ptr::null_mut(),
            sType: WGPUSType_ShaderSourceWGSL,
        },
        code: WGPUStringView {
            data: wgsl.as_ptr().cast(),
            length: wgsl.len(),
        },
    };
    let d = WGPUShaderModuleDescriptor {
        nextInChain: &source.chain as *const _ as *mut _,
        label: WGPUStringView::NULL,
    };
    unsafe { wgpuDeviceCreateShaderModule(device, &d) }
}

// ---- the frame ------------------------------------------------------------------------------

/// The write phase: WebGPU's queue writes, ordered before the commands submitted after them.
/// `finish` consumes it.
pub struct Upload<'a> {
    queue: WGPUQueue,
    encoder: WGPUCommandEncoder,
    _d: PhantomData<&'a ()>,
}

impl<'a> Upload<'a> {
    pub fn new(device: &Device<'a>, encoder: WGPUCommandEncoder) -> Self {
        Self {
            queue: device.queue,
            encoder,
            _d: PhantomData,
        }
    }
    pub fn with_staging(
        device: &Device<'a>,
        encoder: WGPUCommandEncoder,
        _staging: &'a mut Staging,
    ) -> Self {
        Self::new(device, encoder)
    }
    pub fn write_buffer(&mut self, buffer: &Buffer, offset: u64, data: &[u8]) {
        unsafe {
            wgpuQueueWriteBuffer(
                self.queue,
                buffer.handle,
                offset,
                data.as_ptr().cast(),
                data.len(),
            )
        };
    }
    pub fn write_texture(&mut self, t: &Texture, data: &[u8], bytes_per_row: u32) -> bool {
        let dst = WGPUTexelCopyTextureInfo {
            texture: t.texture,
            aspect: WGPUTextureAspect_All,
            ..Default::default()
        };
        let layout = WGPUTexelCopyBufferLayout {
            offset: 0,
            bytesPerRow: bytes_per_row,
            rowsPerImage: t.height,
        };
        let extent = WGPUExtent3D {
            width: t.width,
            height: t.height,
            depthOrArrayLayers: 1,
        };
        unsafe {
            wgpuQueueWriteTexture(
                self.queue,
                &dst,
                data.as_ptr().cast(),
                data.len(),
                &layout,
                &extent,
            )
        };
        true
    }
    pub fn prepare(&mut self, _t: &Texture) {}
    pub fn finish(self) -> CommandEncoder<'a> {
        CommandEncoder {
            encoder: self.encoder,
            _d: PhantomData,
        }
    }
    pub fn as_raw(&self) -> WGPUCommandEncoder {
        self.encoder
    }
}

/// The draw phase of a frame: the host's command encoder. Made by `Upload::finish`.
pub struct CommandEncoder<'a> {
    encoder: WGPUCommandEncoder,
    _d: PhantomData<&'a ()>,
}

impl<'a> CommandEncoder<'a> {
    pub fn begin_render_pass(&self, d: &RenderPassDescriptor<'_>) -> RenderPass<'a> {
        let mut atts = [WGPURenderPassColorAttachment::default(); MAX_COLOR_TARGETS];
        let mut n = 0;
        for a in d.color_attachments.iter().flatten() {
            let (load, clear) = match a.ops.load {
                LoadOp::Clear(c) => (
                    WGPULoadOp_Clear,
                    WGPUColor {
                        r: c.r,
                        g: c.g,
                        b: c.b,
                        a: c.a,
                    },
                ),
                LoadOp::Load => (WGPULoadOp_Load, WGPUColor::default()),
            };
            atts[n] = WGPURenderPassColorAttachment {
                view: a.view.view,
                depthSlice: WGPU_DEPTH_SLICE_UNDEFINED,
                resolveTarget: a.resolve_target.map_or(core::ptr::null_mut(), |r| r.view),
                loadOp: load,
                storeOp: if matches!(a.ops.store, StoreOp::Store) {
                    WGPUStoreOp_Store
                } else {
                    WGPUStoreOp_Discard
                },
                clearValue: clear,
                ..Default::default()
            };
            n += 1;
        }
        let rp = WGPURenderPassDescriptor {
            colorAttachmentCount: n,
            colorAttachments: atts.as_ptr(),
            ..Default::default()
        };
        RenderPass {
            pass: unsafe { wgpuCommandEncoderBeginRenderPass(self.encoder, &rp) },
            owned: true,
            _d: PhantomData,
        }
    }
    pub fn begin_compute_pass(&self) -> ComputePass<'a> {
        ComputePass {
            pass: unsafe { wgpuCommandEncoderBeginComputePass(self.encoder, core::ptr::null()) },
            _d: PhantomData,
        }
    }
    pub fn as_raw(&self) -> WGPUCommandEncoder {
        self.encoder
    }
}

/// A render pass; it ends (and is released) when dropped, as in wgpu.
pub struct RenderPass<'a> {
    pass: WGPURenderPassEncoder,
    owned: bool,
    _d: PhantomData<&'a ()>,
}

impl<'a> RenderPass<'a> {
    /// The pass the host is recording (the UI's, for an inline custom draw); dropping it leaves
    /// it to the host.
    pub fn wrap(_device: &Device<'a>, pass: WGPURenderPassEncoder) -> Self {
        Self {
            pass,
            owned: false,
            _d: PhantomData,
        }
    }
    pub fn set_pipeline(&mut self, p: &RenderPipeline) {
        unsafe { wgpuRenderPassEncoderSetPipeline(self.pass, p.pipeline) };
    }
    pub fn set_bind_group<const G: u32>(
        &mut self,
        index: u32,
        group: &BindGroup<G>,
        offsets: &[u32],
    ) {
        debug_assert!(index == G, "bind group made for another @group");
        unsafe {
            wgpuRenderPassEncoderSetBindGroup(
                self.pass,
                index,
                group.group,
                offsets.len(),
                offsets.as_ptr(),
            )
        };
    }
    pub fn set_vertex_buffer(&mut self, slot: u32, slice: BufferSlice<'_>) {
        unsafe {
            wgpuRenderPassEncoderSetVertexBuffer(
                self.pass,
                slot,
                slice.buffer.handle,
                slice.offset,
                WGPU_WHOLE_SIZE,
            )
        };
    }
    pub fn set_index_buffer(&mut self, slice: BufferSlice<'_>, format: IndexFormat) {
        let f = if format == IndexFormat::Uint16 {
            WGPUIndexFormat_Uint16
        } else {
            WGPUIndexFormat_Uint32
        };
        unsafe {
            wgpuRenderPassEncoderSetIndexBuffer(
                self.pass,
                slice.buffer.handle,
                f,
                slice.offset,
                WGPU_WHOLE_SIZE,
            )
        };
    }
    pub fn set_viewport(&mut self, x: f32, y: f32, w: f32, h: f32, min_depth: f32, max_depth: f32) {
        unsafe { wgpuRenderPassEncoderSetViewport(self.pass, x, y, w, h, min_depth, max_depth) };
    }
    pub fn set_scissor_rect(&mut self, x: u32, y: u32, w: u32, h: u32) {
        unsafe { wgpuRenderPassEncoderSetScissorRect(self.pass, x, y, w, h) };
    }
    pub fn set_blend_constant(&mut self, c: Color) {
        unsafe {
            wgpuRenderPassEncoderSetBlendConstant(
                self.pass,
                &WGPUColor {
                    r: c.r,
                    g: c.g,
                    b: c.b,
                    a: c.a,
                },
            )
        };
    }
    pub fn draw(&mut self, vertices: Range<u32>, instances: Range<u32>) {
        unsafe {
            wgpuRenderPassEncoderDraw(
                self.pass,
                vertices.len() as u32,
                instances.len() as u32,
                vertices.start,
                instances.start,
            )
        };
    }
    pub fn draw_indexed(&mut self, indices: Range<u32>, base_vertex: i32, instances: Range<u32>) {
        unsafe {
            wgpuRenderPassEncoderDrawIndexed(
                self.pass,
                indices.len() as u32,
                instances.len() as u32,
                indices.start,
                base_vertex,
                instances.start,
            )
        };
    }
    pub fn as_raw(&self) -> WGPURenderPassEncoder {
        self.pass
    }
}

impl Drop for RenderPass<'_> {
    fn drop(&mut self) {
        if self.owned {
            unsafe {
                wgpuRenderPassEncoderEnd(self.pass);
                wgpuRenderPassEncoderRelease(self.pass);
            }
        }
    }
}

/// A compute pass; it ends (and is released) when dropped.
pub struct ComputePass<'a> {
    pass: WGPUComputePassEncoder,
    _d: PhantomData<&'a ()>,
}

impl ComputePass<'_> {
    pub fn set_pipeline(&mut self, p: &ComputePipeline) {
        unsafe { wgpuComputePassEncoderSetPipeline(self.pass, p.pipeline) };
    }
    pub fn set_bind_group<const G: u32>(
        &mut self,
        index: u32,
        group: &BindGroup<G>,
        offsets: &[u32],
    ) {
        debug_assert!(index == G, "bind group made for another @group");
        unsafe {
            wgpuComputePassEncoderSetBindGroup(
                self.pass,
                index,
                group.group,
                offsets.len(),
                offsets.as_ptr(),
            )
        };
    }
    pub fn dispatch_workgroups(&mut self, x: u32, y: u32, z: u32) {
        unsafe { wgpuComputePassEncoderDispatchWorkgroups(self.pass, x, y, z) };
    }
    pub fn as_raw(&self) -> WGPUComputePassEncoder {
        self.pass
    }
}

impl Drop for ComputePass<'_> {
    fn drop(&mut self) {
        unsafe {
            wgpuComputePassEncoderEnd(self.pass);
            wgpuComputePassEncoderRelease(self.pass);
        }
    }
}

// ---- creation ---------------------------------------------------------------------------------

struct Mapped {
    done: bool,
    ok: bool,
}

unsafe extern "C" fn on_map(
    status: u32,
    _message: WGPUStringView,
    ud: *mut c_void,
    _: *mut c_void,
) {
    let m = unsafe { &mut *ud.cast::<Mapped>() };
    m.done = true;
    m.ok = status == WGPUMapAsyncStatus_Success;
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
        // Our usage bits are WebGPU's, from MAP_READ (1) to INDIRECT (256).
        let bd = WGPUBufferDescriptor {
            usage: d.usage.0 as u64,
            size: d.size,
            ..Default::default()
        };
        Ok(Buffer {
            handle: unsafe { wgpuDeviceCreateBuffer(self.device, &bd) },
            size: d.size,
        })
    }
    pub fn destroy_buffer(&self, b: &Buffer) {
        unsafe { wgpuBufferRelease(b.handle) };
    }

    pub fn create_texture(
        &self,
        _arena: &mut Arena,
        d: &TextureDescriptor,
    ) -> Result<Texture, Error> {
        let td = WGPUTextureDescriptor {
            // Our usage bits are WebGPU's, from COPY_SRC (1) to RENDER_ATTACHMENT (16).
            usage: d.usage.0 as u64,
            dimension: WGPUTextureDimension_2D,
            size: WGPUExtent3D {
                width: d.width,
                height: d.height,
                depthOrArrayLayers: 1,
            },
            format: d.format.wgpu(),
            mipLevelCount: d.mip_level_count.max(1),
            sampleCount: d.sample_count.max(1),
            ..Default::default()
        };
        let texture = unsafe { wgpuDeviceCreateTexture(self.device, &td) };
        let view = unsafe { wgpuTextureCreateView(texture, core::ptr::null()) };
        Ok(Texture {
            texture,
            view,
            format: d.format,
            width: d.width,
            height: d.height,
            samples: d.sample_count.max(1),
        })
    }
    pub fn destroy_texture(&self, t: &Texture) {
        unsafe {
            wgpuTextureViewRelease(t.view);
            wgpuTextureRelease(t.texture);
        }
    }

    pub fn create_sampler(&self, d: &SamplerDescriptor) -> Result<Sampler, Error> {
        let filter = |f: FilterMode| {
            if f == FilterMode::Linear {
                WGPUFilterMode_Linear
            } else {
                WGPUFilterMode_Nearest
            }
        };
        let sd = WGPUSamplerDescriptor {
            addressModeU: d.address_mode_u as u32 + 1,
            addressModeV: d.address_mode_v as u32 + 1,
            addressModeW: d.address_mode_w as u32 + 1,
            magFilter: filter(d.mag_filter),
            minFilter: filter(d.min_filter),
            mipmapFilter: if d.mipmap_filter == FilterMode::Linear {
                WGPUMipmapFilterMode_Linear
            } else {
                WGPUMipmapFilterMode_Nearest
            },
            lodMinClamp: d.lod_min_clamp,
            lodMaxClamp: d.lod_max_clamp,
            maxAnisotropy: 1,
            ..Default::default()
        };
        Ok(Sampler {
            handle: unsafe { wgpuDeviceCreateSampler(self.device, &sd) },
        })
    }
    pub fn destroy_sampler(&self, s: &Sampler) {
        unsafe { wgpuSamplerRelease(s.handle) };
    }

    /// A pipeline for shader `S` from its WGSL, with WebGPU's "auto" layout.
    pub fn create_render_pipeline<S: ShaderSource>(
        &self,
        d: &RenderPipelineDescriptor<'_>,
    ) -> Result<RenderPipelineOf<S>, Error> {
        let m = shader_module(self.device, S::WGSL);
        let mut attrs = [WGPUVertexAttribute::default(); 16];
        let mut buffers = [WGPUVertexBufferLayout::default(); 8];
        let mut na = 0;
        for (i, vb) in d.vertex.buffers.iter().enumerate() {
            let first = na;
            for a in vb.attributes {
                attrs[na] = WGPUVertexAttribute {
                    format: vertex_format(a.format),
                    offset: a.offset,
                    shaderLocation: a.shader_location,
                    ..Default::default()
                };
                na += 1;
            }
            buffers[i] = WGPUVertexBufferLayout {
                stepMode: if vb.step_mode_instance {
                    WGPUVertexStepMode_Instance
                } else {
                    WGPUVertexStepMode_Vertex
                },
                arrayStride: vb.array_stride,
                attributeCount: na - first,
                attributes: attrs[first..].as_ptr(),
                ..Default::default()
            };
        }
        let mut blends = [WGPUBlendState::default(); MAX_COLOR_TARGETS];
        let mut targets = [WGPUColorTargetState::default(); MAX_COLOR_TARGETS];
        let mut fragment = WGPUFragmentState::default();
        if let Some(fr) = d.fragment {
            for (i, t) in fr.targets.iter().enumerate() {
                targets[i] = WGPUColorTargetState {
                    format: t.format.wgpu(),
                    writeMask: t.write_mask as u64,
                    ..Default::default()
                };
                if let Some(b) = t.blend {
                    blends[i] = WGPUBlendState {
                        color: blend(&b.color),
                        alpha: blend(&b.alpha),
                    };
                    targets[i].blend = &blends[i];
                }
            }
            fragment = WGPUFragmentState {
                module: m,
                entryPoint: sv(fr.entry_point),
                targetCount: fr.targets.len(),
                targets: targets.as_ptr(),
                ..Default::default()
            };
        }
        let mut pd = WGPURenderPipelineDescriptor::default();
        pd.vertex = WGPUVertexState {
            module: m,
            entryPoint: sv(d.vertex.entry_point),
            bufferCount: d.vertex.buffers.len(),
            buffers: buffers.as_ptr(),
            ..pd.vertex
        };
        pd.primitive = WGPUPrimitiveState {
            topology: d.topology as u32 + 1,
            frontFace: if d.front_face_ccw {
                WGPUFrontFace_CCW
            } else {
                WGPUFrontFace_CW
            },
            cullMode: d.cull_mode as u32 + 1,
            ..pd.primitive
        };
        pd.multisample = WGPUMultisampleState {
            count: d.sample_count.max(1),
            mask: u32::MAX,
            ..pd.multisample
        };
        if d.fragment.is_some() {
            pd.fragment = &fragment;
        }
        let pipeline = unsafe { wgpuDeviceCreateRenderPipeline(self.device, &pd) };
        unsafe { wgpuShaderModuleRelease(m) };
        if pipeline.is_null() {
            return Err(Error::PipelineFailed);
        }
        Ok(RenderPipelineOf {
            raw: RenderPipeline { pipeline },
            _s: PhantomData,
        })
    }

    pub fn create_compute_pipeline<S: ShaderSource>(
        &self,
        entry_point: &CStr,
    ) -> Result<ComputePipelineOf<S>, Error> {
        let m = shader_module(self.device, S::WGSL);
        let mut pd = WGPUComputePipelineDescriptor::default();
        pd.compute = WGPUComputeState {
            module: m,
            entryPoint: sv(entry_point),
            ..pd.compute
        };
        let pipeline = unsafe { wgpuDeviceCreateComputePipeline(self.device, &pd) };
        unsafe { wgpuShaderModuleRelease(m) };
        if pipeline.is_null() {
            return Err(Error::PipelineFailed);
        }
        Ok(ComputePipelineOf {
            raw: ComputePipeline { pipeline },
            _s: PhantomData,
        })
    }

    pub fn destroy_render_pipeline(&self, p: &RenderPipeline) {
        unsafe { wgpuRenderPipelineRelease(p.pipeline) };
    }
    pub fn destroy_compute_pipeline(&self, p: &ComputePipeline) {
        unsafe { wgpuComputePipelineRelease(p.pipeline) };
    }

    /// A bind group for `group` (a generated `GroupN` of the pipeline's shader), with the layout
    /// the pipeline made for its group.
    pub fn create_bind_group<P: PipelineOf, G: Group<Shader = P::Shader>>(
        &self,
        _arena: &mut Arena,
        pipeline: &P,
        group: &G,
    ) -> Result<G::BindGroup, Error> {
        let layout = pipeline.group_layout(G::INDEX);
        let mut rs = [Resource::EMPTY; 16];
        let n = group.resources(&mut rs);
        let mut es = [WGPUBindGroupEntry::default(); 16];
        for (e, r) in es.iter_mut().zip(&rs[..n]) {
            *e = WGPUBindGroupEntry {
                binding: r.binding,
                buffer: r.buffer,
                size: if r.buffer.is_null() {
                    0
                } else {
                    WGPU_WHOLE_SIZE
                },
                textureView: r.view,
                sampler: r.sampler,
                ..Default::default()
            };
        }
        let bd = WGPUBindGroupDescriptor {
            layout,
            entryCount: n,
            entries: es.as_ptr(),
            ..Default::default()
        };
        let g = unsafe { wgpuDeviceCreateBindGroup(self.device, &bd) };
        unsafe { wgpuBindGroupLayoutRelease(layout) };
        Ok(g.into())
    }

    fn submit(&self, e: WGPUCommandEncoder) {
        unsafe {
            let c = wgpuCommandEncoderFinish(e, core::ptr::null());
            wgpuQueueSubmit(self.queue, 1, &c);
            wgpuCommandBufferRelease(c);
            wgpuCommandEncoderRelease(e);
        }
    }

    /// Submits the commands recorded into `encoder` (and releases it).
    pub fn submit_encoder(&self, encoder: WGPUCommandEncoder) {
        self.submit(encoder);
    }

    fn map_read(&self, staging: WGPUBuffer, size: usize) -> bool {
        let mut m = Mapped {
            done: false,
            ok: false,
        };
        let cb = WGPUBufferMapCallbackInfo {
            mode: WGPUCallbackMode_AllowProcessEvents,
            callback: Some(on_map),
            userdata1: (&mut m as *mut Mapped).cast(),
            ..Default::default()
        };
        unsafe { wgpuBufferMapAsync(staging, WGPUMapMode_Read, 0, size, cb) };
        let mut polls = 0;
        while !m.done && polls < 1_000_000 {
            unsafe {
                wgpuDevicePoll(self.device, 1, core::ptr::null());
                if !self.instance.is_null() {
                    wgpuInstanceProcessEvents(self.instance);
                }
            }
            polls += 1;
        }
        m.ok
    }

    /// Copies `out.len()` bytes of `b` from `offset`, through a mappable buffer, waiting for the
    /// GPU. `b` needs `COPY_SRC`.
    pub fn read_buffer(&self, b: &Buffer, offset: u64, out: &mut [u8]) -> Result<(), Error> {
        let size = out.len().div_ceil(4) * 4;
        let bd = WGPUBufferDescriptor {
            usage: WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst,
            size: size as u64,
            ..Default::default()
        };
        unsafe {
            let staging = wgpuDeviceCreateBuffer(self.device, &bd);
            let e = wgpuDeviceCreateCommandEncoder(self.device, core::ptr::null());
            wgpuCommandEncoderCopyBufferToBuffer(e, b.handle, offset, staging, 0, size as u64);
            self.submit(e);
            let ok = self.map_read(staging, size);
            if ok {
                core::ptr::copy_nonoverlapping(
                    wgpuBufferGetConstMappedRange(staging, 0, size).cast::<u8>(),
                    out.as_mut_ptr(),
                    out.len(),
                );
                wgpuBufferUnmap(staging);
            }
            wgpuBufferRelease(staging);
            if ok { Ok(()) } else { Err(Error::MapFailed) }
        }
    }

    /// Copies an RGBA8 texture's rows (from the top) into `out`, waiting for the GPU. `t` needs
    /// `COPY_SRC`.
    pub fn read_texture(&self, t: &Texture, out: &mut [u8]) -> Result<(), Error> {
        let row = t.width as usize * 4;
        let padded = row.div_ceil(256) * 256;
        let size = padded * t.height as usize;
        let bd = WGPUBufferDescriptor {
            usage: WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst,
            size: size as u64,
            ..Default::default()
        };
        unsafe {
            let staging = wgpuDeviceCreateBuffer(self.device, &bd);
            let e = wgpuDeviceCreateCommandEncoder(self.device, core::ptr::null());
            let src = WGPUTexelCopyTextureInfo {
                texture: t.texture,
                aspect: WGPUTextureAspect_All,
                ..Default::default()
            };
            let dst = WGPUTexelCopyBufferInfo {
                layout: WGPUTexelCopyBufferLayout {
                    offset: 0,
                    bytesPerRow: padded as u32,
                    rowsPerImage: t.height,
                },
                buffer: staging,
            };
            let extent = WGPUExtent3D {
                width: t.width,
                height: t.height,
                depthOrArrayLayers: 1,
            };
            wgpuCommandEncoderCopyTextureToBuffer(e, &src, &dst, &extent);
            self.submit(e);
            let ok = self.map_read(staging, size);
            if ok {
                let p = wgpuBufferGetConstMappedRange(staging, 0, size).cast::<u8>();
                for y in 0..t.height as usize {
                    core::ptr::copy_nonoverlapping(
                        p.add(y * padded),
                        out.as_mut_ptr().add(y * row),
                        row,
                    );
                }
                wgpuBufferUnmap(staging);
            }
            wgpuBufferRelease(staging);
            if ok { Ok(()) } else { Err(Error::MapFailed) }
        }
    }
}

const MAX_COLOR_TARGETS: usize = 4;
