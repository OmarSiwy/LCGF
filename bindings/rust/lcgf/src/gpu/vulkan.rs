//! The Vulkan back end of `lcgf::gpu` (`ash`'s types): the frame phases, the per-draw calls and
//! resource creation of src/render/vk/gpu.zig, inline. A call is the `vkCmd*` it stands for,
//! through the function table you load (`DeviceFns::load`).

use super::*;

/// What creation reports: Vulkan's own result.
pub type Error = vk::Result;

use core::ffi::{CStr, c_char};
use core::marker::PhantomData;
use core::ops::Range;

pub use ash::vk;

/// The device commands the projection records and the ones creation uses, loaded once.
pub struct DeviceFns {
    pub cmd_update_buffer: vk::PFN_vkCmdUpdateBuffer,
    pub cmd_pipeline_barrier2: vk::PFN_vkCmdPipelineBarrier2,
    pub cmd_begin_rendering: vk::PFN_vkCmdBeginRendering,
    pub cmd_end_rendering: vk::PFN_vkCmdEndRendering,
    pub cmd_set_viewport: vk::PFN_vkCmdSetViewport,
    pub cmd_set_scissor: vk::PFN_vkCmdSetScissor,
    pub cmd_bind_pipeline: vk::PFN_vkCmdBindPipeline,
    pub cmd_bind_descriptor_sets: vk::PFN_vkCmdBindDescriptorSets,
    pub cmd_bind_vertex_buffers: vk::PFN_vkCmdBindVertexBuffers,
    pub cmd_bind_index_buffer: vk::PFN_vkCmdBindIndexBuffer,
    pub cmd_draw: vk::PFN_vkCmdDraw,
    pub cmd_draw_indexed: vk::PFN_vkCmdDrawIndexed,
    pub cmd_set_blend_constants: vk::PFN_vkCmdSetBlendConstants,
    pub cmd_dispatch: vk::PFN_vkCmdDispatch,
    pub cmd_copy_buffer_to_image: vk::PFN_vkCmdCopyBufferToImage,
    pub create_buffer: vk::PFN_vkCreateBuffer,
    pub destroy_buffer: vk::PFN_vkDestroyBuffer,
    pub get_buffer_memory_requirements: vk::PFN_vkGetBufferMemoryRequirements,
    pub bind_buffer_memory: vk::PFN_vkBindBufferMemory,
    pub create_image: vk::PFN_vkCreateImage,
    pub destroy_image: vk::PFN_vkDestroyImage,
    pub get_image_memory_requirements: vk::PFN_vkGetImageMemoryRequirements,
    pub bind_image_memory: vk::PFN_vkBindImageMemory,
    pub create_image_view: vk::PFN_vkCreateImageView,
    pub destroy_image_view: vk::PFN_vkDestroyImageView,
    pub create_sampler: vk::PFN_vkCreateSampler,
    pub destroy_sampler: vk::PFN_vkDestroySampler,
    pub allocate_memory: vk::PFN_vkAllocateMemory,
    pub free_memory: vk::PFN_vkFreeMemory,
    pub map_memory: vk::PFN_vkMapMemory,
    pub create_descriptor_pool: vk::PFN_vkCreateDescriptorPool,
    pub destroy_descriptor_pool: vk::PFN_vkDestroyDescriptorPool,
    pub allocate_descriptor_sets: vk::PFN_vkAllocateDescriptorSets,
    pub update_descriptor_sets: vk::PFN_vkUpdateDescriptorSets,
    pub create_descriptor_set_layout: vk::PFN_vkCreateDescriptorSetLayout,
    pub destroy_descriptor_set_layout: vk::PFN_vkDestroyDescriptorSetLayout,
    pub create_pipeline_layout: vk::PFN_vkCreatePipelineLayout,
    pub destroy_pipeline_layout: vk::PFN_vkDestroyPipelineLayout,
    pub create_shader_module: vk::PFN_vkCreateShaderModule,
    pub destroy_shader_module: vk::PFN_vkDestroyShaderModule,
    pub create_graphics_pipelines: vk::PFN_vkCreateGraphicsPipelines,
    pub create_compute_pipelines: vk::PFN_vkCreateComputePipelines,
    pub destroy_pipeline: vk::PFN_vkDestroyPipeline,
}

impl DeviceFns {
    /// Loads every command from `device`.
    ///
    /// # Safety
    /// `get` must be the device's `vkGetDeviceProcAddr`, and every command must exist.
    pub unsafe fn load(get: vk::PFN_vkGetDeviceProcAddr, device: vk::Device) -> Self {
        macro_rules! f {
            ($name:literal) => {{
                let name: &CStr =
                    unsafe { CStr::from_bytes_with_nul_unchecked(concat!($name, "\0").as_bytes()) };
                let p = unsafe { get(device, name.as_ptr() as *const c_char) }.expect($name);
                unsafe { core::mem::transmute::<unsafe extern "system" fn(), _>(p) }
            }};
        }
        Self {
            cmd_update_buffer: f!("vkCmdUpdateBuffer"),
            cmd_pipeline_barrier2: f!("vkCmdPipelineBarrier2"),
            cmd_begin_rendering: f!("vkCmdBeginRendering"),
            cmd_end_rendering: f!("vkCmdEndRendering"),
            cmd_set_viewport: f!("vkCmdSetViewport"),
            cmd_set_scissor: f!("vkCmdSetScissor"),
            cmd_bind_pipeline: f!("vkCmdBindPipeline"),
            cmd_bind_descriptor_sets: f!("vkCmdBindDescriptorSets"),
            cmd_bind_vertex_buffers: f!("vkCmdBindVertexBuffers"),
            cmd_bind_index_buffer: f!("vkCmdBindIndexBuffer"),
            cmd_draw: f!("vkCmdDraw"),
            cmd_draw_indexed: f!("vkCmdDrawIndexed"),
            cmd_set_blend_constants: f!("vkCmdSetBlendConstants"),
            cmd_dispatch: f!("vkCmdDispatch"),
            cmd_copy_buffer_to_image: f!("vkCmdCopyBufferToImage"),
            create_buffer: f!("vkCreateBuffer"),
            destroy_buffer: f!("vkDestroyBuffer"),
            get_buffer_memory_requirements: f!("vkGetBufferMemoryRequirements"),
            bind_buffer_memory: f!("vkBindBufferMemory"),
            create_image: f!("vkCreateImage"),
            destroy_image: f!("vkDestroyImage"),
            get_image_memory_requirements: f!("vkGetImageMemoryRequirements"),
            bind_image_memory: f!("vkBindImageMemory"),
            create_image_view: f!("vkCreateImageView"),
            destroy_image_view: f!("vkDestroyImageView"),
            create_sampler: f!("vkCreateSampler"),
            destroy_sampler: f!("vkDestroySampler"),
            allocate_memory: f!("vkAllocateMemory"),
            free_memory: f!("vkFreeMemory"),
            map_memory: f!("vkMapMemory"),
            create_descriptor_pool: f!("vkCreateDescriptorPool"),
            destroy_descriptor_pool: f!("vkDestroyDescriptorPool"),
            allocate_descriptor_sets: f!("vkAllocateDescriptorSets"),
            update_descriptor_sets: f!("vkUpdateDescriptorSets"),
            create_descriptor_set_layout: f!("vkCreateDescriptorSetLayout"),
            destroy_descriptor_set_layout: f!("vkDestroyDescriptorSetLayout"),
            create_pipeline_layout: f!("vkCreatePipelineLayout"),
            destroy_pipeline_layout: f!("vkDestroyPipelineLayout"),
            create_shader_module: f!("vkCreateShaderModule"),
            destroy_shader_module: f!("vkDestroyShaderModule"),
            create_graphics_pipelines: f!("vkCreateGraphicsPipelines"),
            create_compute_pipelines: f!("vkCreateComputePipelines"),
            destroy_pipeline: f!("vkDestroyPipeline"),
        }
    }
}

/// The device: its handle, the function table you loaded and its memory types (from
/// `vkGetPhysicalDeviceMemoryProperties`).
#[derive(Clone, Copy)]
pub struct Device<'a> {
    pub handle: vk::Device,
    pub fns: &'a DeviceFns,
    pub memory: vk::PhysicalDeviceMemoryProperties,
}

impl TextureFormat {
    pub fn vk(self) -> vk::Format {
        use TextureFormat::*;
        match self {
            R8Unorm => vk::Format::R8_UNORM,
            Rg8Unorm => vk::Format::R8G8_UNORM,
            Rgba8Unorm => vk::Format::R8G8B8A8_UNORM,
            Rgba8UnormSrgb => vk::Format::R8G8B8A8_SRGB,
            Bgra8Unorm => vk::Format::B8G8R8A8_UNORM,
            Bgra8UnormSrgb => vk::Format::B8G8R8A8_SRGB,
            R16Float => vk::Format::R16_SFLOAT,
            Rgba16Float => vk::Format::R16G16B16A16_SFLOAT,
            R32Float => vk::Format::R32_SFLOAT,
            Rg32Float => vk::Format::R32G32_SFLOAT,
            Rgba32Float => vk::Format::R32G32B32A32_SFLOAT,
            R32Uint => vk::Format::R32_UINT,
            Depth32Float => vk::Format::D32_SFLOAT,
        }
    }
    fn aspect(self) -> vk::ImageAspectFlags {
        if self == TextureFormat::Depth32Float {
            vk::ImageAspectFlags::DEPTH
        } else {
            vk::ImageAspectFlags::COLOR
        }
    }
}

impl BindingKind {
    fn descriptor_type(self) -> vk::DescriptorType {
        match self {
            BindingKind::Uniform => vk::DescriptorType::UNIFORM_BUFFER,
            BindingKind::StorageRead | BindingKind::StorageReadWrite => {
                vk::DescriptorType::STORAGE_BUFFER
            }
            BindingKind::Texture => vk::DescriptorType::SAMPLED_IMAGE,
            BindingKind::StorageTexture => vk::DescriptorType::STORAGE_IMAGE,
            BindingKind::Sampler | BindingKind::ComparisonSampler => vk::DescriptorType::SAMPLER,
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub struct Buffer {
    pub handle: vk::Buffer,
    pub size: u64,
    /// Set when the buffer is in a host arena: its bytes, written directly.
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
    buffer: &'a Buffer,
    offset: u64,
}

#[derive(Clone, Copy, Debug)]
pub struct TextureView {
    pub view: vk::ImageView,
    pub image: vk::Image,
    pub width: u32,
    pub height: u32,
    pub samples: u32,
    /// The layout shaders see it in: its texture's resting layout.
    pub layout: vk::ImageLayout,
    pub format: TextureFormat,
}

#[derive(Clone, Copy, Debug)]
pub struct Texture {
    pub image: vk::Image,
    pub view: vk::ImageView,
    pub format: TextureFormat,
    pub width: u32,
    pub height: u32,
    pub samples: u32,
    /// The layout it keeps between passes: shader-readable, or general for storage.
    pub resting: vk::ImageLayout,
}

impl Texture {
    pub fn create_view(&self) -> TextureView {
        TextureView {
            view: self.view,
            image: self.image,
            width: self.width,
            height: self.height,
            samples: self.samples,
            layout: self.resting,
            format: self.format,
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub struct Sampler {
    pub handle: vk::Sampler,
}

const MAX_COLOR_TARGETS: usize = 4;

#[derive(Clone, Copy, Debug, Default)]
pub struct RenderPipeline {
    pub pipeline: vk::Pipeline,
    pub layout: vk::PipelineLayout,
    pub set_layouts: [vk::DescriptorSetLayout; MAX_GROUPS],
}

#[derive(Clone, Copy, Debug, Default)]
pub struct ComputePipeline {
    pub pipeline: vk::Pipeline,
    pub layout: vk::PipelineLayout,
    pub set_layouts: [vk::DescriptorSetLayout; MAX_GROUPS],
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

/// A descriptor set made for `@group(G)`, and the layout it binds with.
#[derive(Clone, Copy, Debug)]
pub struct BindGroup<const G: u32> {
    pub set: vk::DescriptorSet,
    pub layout: vk::PipelineLayout,
}

/// One resource of a bind group, as a generated `GroupN` lists them.
#[derive(Clone, Copy, Debug)]
pub struct Resource {
    pub binding: u32,
    pub kind: BindingKind,
    pub buffer: vk::Buffer,
    pub view: vk::ImageView,
    pub layout: vk::ImageLayout,
    pub sampler: vk::Sampler,
}

impl Resource {
    pub const EMPTY: Self = Self {
        binding: 0,
        kind: BindingKind::Uniform,
        buffer: vk::Buffer::null(),
        view: vk::ImageView::null(),
        layout: vk::ImageLayout::UNDEFINED,
        sampler: vk::Sampler::null(),
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
            layout: v.layout,
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
    type BindGroup: From<(vk::DescriptorSet, vk::PipelineLayout)>;
    const INDEX: u32;
    /// Writes the resources into `out`; returns how many.
    fn resources(&self, out: &mut [Resource; 16]) -> usize;
}

impl<const G: u32> From<(vk::DescriptorSet, vk::PipelineLayout)> for BindGroup<G> {
    fn from((set, layout): (vk::DescriptorSet, vk::PipelineLayout)) -> Self {
        Self { set, layout }
    }
}

/// The pipelines a bind group can be made for: either kind, tied to its shader.
pub trait PipelineOf {
    type Shader;
    fn set_layouts(&self) -> &[vk::DescriptorSetLayout; MAX_GROUPS];
    fn layout(&self) -> vk::PipelineLayout;
}
impl<S> PipelineOf for RenderPipelineOf<S> {
    type Shader = S;
    fn set_layouts(&self) -> &[vk::DescriptorSetLayout; MAX_GROUPS] {
        &self.raw.set_layouts
    }
    fn layout(&self) -> vk::PipelineLayout {
        self.raw.layout
    }
}
impl<S> PipelineOf for ComputePipelineOf<S> {
    type Shader = S;
    fn set_layouts(&self) -> &[vk::DescriptorSetLayout; MAX_GROUPS] {
        &self.raw.set_layouts
    }
    fn layout(&self) -> vk::PipelineLayout {
        self.raw.layout
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

fn layout_barrier<'a>(
    image: vk::Image,
    from: vk::ImageLayout,
    to: vk::ImageLayout,
    src_stage: vk::PipelineStageFlags2,
    src_access: vk::AccessFlags2,
    dst_stage: vk::PipelineStageFlags2,
    dst_access: vk::AccessFlags2,
) -> vk::ImageMemoryBarrier2<'a> {
    vk::ImageMemoryBarrier2 {
        src_stage_mask: src_stage,
        src_access_mask: src_access,
        dst_stage_mask: dst_stage,
        dst_access_mask: dst_access,
        old_layout: from,
        new_layout: to,
        src_queue_family_index: vk::QUEUE_FAMILY_IGNORED,
        dst_queue_family_index: vk::QUEUE_FAMILY_IGNORED,
        image,
        subresource_range: vk::ImageSubresourceRange {
            aspect_mask: vk::ImageAspectFlags::COLOR,
            base_mip_level: 0,
            level_count: 1,
            base_array_layer: 0,
            layer_count: 1,
        },
        ..Default::default()
    }
}

fn dependency<'a>(
    memory: &'a [vk::MemoryBarrier2<'a>],
    images: &'a [vk::ImageMemoryBarrier2<'a>],
) -> vk::DependencyInfo<'a> {
    vk::DependencyInfo {
        memory_barrier_count: memory.len() as u32,
        p_memory_barriers: if memory.is_empty() {
            core::ptr::null()
        } else {
            memory.as_ptr()
        },
        image_memory_barrier_count: images.len() as u32,
        p_image_memory_barriers: if images.is_empty() {
            core::ptr::null()
        } else {
            images.as_ptr()
        },
        ..Default::default()
    }
}

fn memory_barrier<'a>(
    src_stage: vk::PipelineStageFlags2,
    src_access: vk::AccessFlags2,
) -> vk::MemoryBarrier2<'a> {
    vk::MemoryBarrier2 {
        src_stage_mask: src_stage,
        src_access_mask: src_access,
        dst_stage_mask: vk::PipelineStageFlags2::ALL_COMMANDS,
        dst_access_mask: vk::AccessFlags2::MEMORY_READ,
        ..Default::default()
    }
}

/// A ring of mapped memory for texture writes, in a host arena. One per frame in flight;
/// `rewind` it when that frame's previous use has completed.
pub struct Staging {
    pub buffer: Buffer,
    pub used: u64,
}

impl Staging {
    pub fn rewind(&mut self) {
        self.used = 0;
    }
    fn push(&mut self, data: &[u8]) -> Option<u64> {
        let at = (self.used + 15) & !15;
        if at + data.len() as u64 > self.buffer.size || self.buffer.mapped.is_null() {
            return None;
        }
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

/// The write phase of a frame: copies and writes only, recorded into your command buffer before
/// any pass. `finish` consumes it and returns the draw phase.
pub struct Upload<'a> {
    cmd: vk::CommandBuffer,
    fns: &'a DeviceFns,
    staging: Option<&'a mut Staging>,
    images: [vk::ImageMemoryBarrier2<'static>; 16],
    image_count: usize,
}

impl<'a> Upload<'a> {
    pub fn new(device: &Device<'a>, cmd: vk::CommandBuffer) -> Self {
        Self {
            cmd,
            fns: device.fns,
            staging: None,
            images: [vk::ImageMemoryBarrier2::default(); 16],
            image_count: 0,
        }
    }

    /// With a staging ring for texture writes.
    pub fn with_staging(
        device: &Device<'a>,
        cmd: vk::CommandBuffer,
        staging: &'a mut Staging,
    ) -> Self {
        Self {
            staging: Some(staging),
            ..Self::new(device, cmd)
        }
    }

    /// Writes `data` at `offset`, ordered on the queue like `wgpu::Queue::write_buffer`. Offset
    /// and length are multiples of 4; the buffer has copy_dst.
    pub fn write_buffer(&mut self, buffer: &Buffer, offset: u64, data: &[u8]) {
        debug_assert!(
            offset % 4 == 0 && data.len() % 4 == 0 && offset + data.len() as u64 <= buffer.size
        );
        for (k, chunk) in data.chunks(65536).enumerate() {
            unsafe {
                (self.fns.cmd_update_buffer)(
                    self.cmd,
                    buffer.handle,
                    offset + (k * 65536) as u64,
                    chunk.len() as u64,
                    chunk.as_ptr().cast(),
                )
            };
        }
    }

    /// Replaces the whole first mip level of `t` with `data` (rows of `bytes_per_row`), through
    /// the staging ring. `false` when there is no ring or it is full.
    pub fn write_texture(&mut self, t: &Texture, data: &[u8], bytes_per_row: u32) -> bool {
        let Some(staging) = self.staging.as_mut() else {
            return false;
        };
        let Some(at) = staging.push(data) else {
            return false;
        };
        let src = staging.buffer.handle;
        let to = [layout_barrier(
            t.image,
            vk::ImageLayout::UNDEFINED,
            vk::ImageLayout::TRANSFER_DST_OPTIMAL,
            vk::PipelineStageFlags2::NONE,
            vk::AccessFlags2::NONE,
            vk::PipelineStageFlags2::COPY,
            vk::AccessFlags2::TRANSFER_WRITE,
        )];
        let dep = dependency(&[], &to);
        unsafe { (self.fns.cmd_pipeline_barrier2)(self.cmd, &dep) };
        let copy = vk::BufferImageCopy {
            buffer_offset: at,
            buffer_row_length: bytes_per_row / t.format.bytes_per_pixel(),
            image_subresource: vk::ImageSubresourceLayers {
                aspect_mask: t.format.aspect(),
                mip_level: 0,
                base_array_layer: 0,
                layer_count: 1,
            },
            image_extent: vk::Extent3D {
                width: t.width,
                height: t.height,
                depth: 1,
            },
            ..Default::default()
        };
        unsafe {
            (self.fns.cmd_copy_buffer_to_image)(
                self.cmd,
                src,
                t.image,
                vk::ImageLayout::TRANSFER_DST_OPTIMAL,
                1,
                &copy,
            )
        };
        self.rest(t.image, vk::ImageLayout::TRANSFER_DST_OPTIMAL, t.resting);
        true
    }

    /// Brings a texture that was never written into its resting layout.
    pub fn prepare(&mut self, t: &Texture) {
        self.rest(t.image, vk::ImageLayout::UNDEFINED, t.resting);
    }

    fn rest(&mut self, image: vk::Image, from: vk::ImageLayout, to: vk::ImageLayout) {
        assert!(self.image_count < 16);
        self.images[self.image_count] = layout_barrier(
            image,
            from,
            to,
            vk::PipelineStageFlags2::COPY,
            vk::AccessFlags2::TRANSFER_WRITE,
            vk::PipelineStageFlags2::ALL_COMMANDS,
            vk::AccessFlags2::SHADER_READ
                | vk::AccessFlags2::SHADER_WRITE
                | vk::AccessFlags2::COLOR_ATTACHMENT_READ,
        );
        self.image_count += 1;
    }

    /// Ends the write phase with one global barrier from every transfer write to every read
    /// that follows, plus the layout moves of the textures written.
    pub fn finish(self) -> CommandEncoder<'a> {
        let m = [memory_barrier(
            vk::PipelineStageFlags2::ALL_TRANSFER,
            vk::AccessFlags2::TRANSFER_WRITE,
        )];
        let dep = vk::DependencyInfo {
            image_memory_barrier_count: self.image_count as u32,
            p_image_memory_barriers: self.images.as_ptr(),
            ..dependency(&m, &[])
        };
        unsafe { (self.fns.cmd_pipeline_barrier2)(self.cmd, &dep) };
        CommandEncoder {
            cmd: self.cmd,
            fns: self.fns,
        }
    }

    pub fn as_raw(&self) -> vk::CommandBuffer {
        self.cmd
    }
}

/// The draw phase of a frame: render and compute passes.
pub struct CommandEncoder<'a> {
    cmd: vk::CommandBuffer,
    fns: &'a DeviceFns,
}

impl<'a> CommandEncoder<'a> {
    /// Moves the attachments into place, clears or loads them, and sets the viewport and scissor
    /// to the whole target (WebGPU's defaults). Dropping the pass leaves them resting.
    pub fn begin_render_pass(&self, d: &RenderPassDescriptor<'_>) -> RenderPass<'a> {
        let mut p = RenderPass::new(self.cmd, self.fns, 0, 0);
        let mut barriers = [vk::ImageMemoryBarrier2::default(); 2 * MAX_COLOR_TARGETS];
        let mut infos = [vk::RenderingAttachmentInfo::default(); MAX_COLOR_TARGETS];
        let mut nb = 0;
        let mut ni = 0;
        for a in d.color_attachments.iter().flatten() {
            let clear = matches!(a.ops.load, LoadOp::Clear(_));
            let from = if clear {
                vk::ImageLayout::UNDEFINED
            } else {
                a.view.layout
            };
            barriers[nb] = layout_barrier(
                a.view.image,
                from,
                vk::ImageLayout::COLOR_ATTACHMENT_OPTIMAL,
                vk::PipelineStageFlags2::ALL_COMMANDS,
                vk::AccessFlags2::MEMORY_READ | vk::AccessFlags2::MEMORY_WRITE,
                vk::PipelineStageFlags2::COLOR_ATTACHMENT_OUTPUT,
                vk::AccessFlags2::COLOR_ATTACHMENT_READ | vk::AccessFlags2::COLOR_ATTACHMENT_WRITE,
            );
            nb += 1;
            p.ends[p.end_count] = (a.view.image, a.view.layout);
            p.end_count += 1;
            if let Some(r) = a.resolve_target {
                barriers[nb] = layout_barrier(
                    r.image,
                    vk::ImageLayout::UNDEFINED,
                    vk::ImageLayout::COLOR_ATTACHMENT_OPTIMAL,
                    vk::PipelineStageFlags2::ALL_COMMANDS,
                    vk::AccessFlags2::MEMORY_READ,
                    vk::PipelineStageFlags2::COLOR_ATTACHMENT_OUTPUT,
                    vk::AccessFlags2::COLOR_ATTACHMENT_WRITE,
                );
                nb += 1;
                p.ends[p.end_count] = (r.image, r.layout);
                p.end_count += 1;
            }
            let c = match a.ops.load {
                LoadOp::Clear(c) => c,
                LoadOp::Load => Color::default(),
            };
            infos[ni] = vk::RenderingAttachmentInfo {
                image_view: a.view.view,
                image_layout: vk::ImageLayout::COLOR_ATTACHMENT_OPTIMAL,
                resolve_mode: if a.resolve_target.is_some() {
                    vk::ResolveModeFlags::AVERAGE
                } else {
                    vk::ResolveModeFlags::NONE
                },
                resolve_image_view: a.resolve_target.map_or(vk::ImageView::null(), |r| r.view),
                resolve_image_layout: vk::ImageLayout::COLOR_ATTACHMENT_OPTIMAL,
                load_op: if clear {
                    vk::AttachmentLoadOp::CLEAR
                } else {
                    vk::AttachmentLoadOp::LOAD
                },
                store_op: match a.ops.store {
                    StoreOp::Store => vk::AttachmentStoreOp::STORE,
                    StoreOp::Discard => vk::AttachmentStoreOp::DONT_CARE,
                },
                clear_value: vk::ClearValue {
                    color: vk::ClearColorValue {
                        float32: [c.r as f32, c.g as f32, c.b as f32, c.a as f32],
                    },
                },
                ..Default::default()
            };
            ni += 1;
            p.width = a.view.width;
            p.height = a.view.height;
        }
        let dep = dependency(&[], &barriers[..nb]);
        unsafe { (self.fns.cmd_pipeline_barrier2)(self.cmd, &dep) };
        let ri = vk::RenderingInfo {
            render_area: vk::Rect2D {
                offset: vk::Offset2D { x: 0, y: 0 },
                extent: vk::Extent2D {
                    width: p.width,
                    height: p.height,
                },
            },
            layer_count: 1,
            color_attachment_count: ni as u32,
            p_color_attachments: infos.as_ptr(),
            ..Default::default()
        };
        unsafe { (self.fns.cmd_begin_rendering)(self.cmd, &ri) };
        p.owned = true;
        p.set_viewport(0.0, 0.0, p.width as f32, p.height as f32, 0.0, 1.0);
        p.set_scissor_rect(0, 0, p.width, p.height);
        p
    }

    pub fn begin_compute_pass(&self) -> ComputePass<'a> {
        ComputePass {
            cmd: self.cmd,
            fns: self.fns,
        }
    }

    pub fn as_raw(&self) -> vk::CommandBuffer {
        self.cmd
    }
}

/// A render pass: the command buffer inside dynamic rendering. Ends when dropped.
pub struct RenderPass<'a> {
    cmd: vk::CommandBuffer,
    fns: &'a DeviceFns,
    width: u32,
    height: u32,
    owned: bool,
    ends: [(vk::Image, vk::ImageLayout); 2 * MAX_COLOR_TARGETS],
    end_count: usize,
    has_pipeline: bool,
}

impl<'a> RenderPass<'a> {
    fn new(cmd: vk::CommandBuffer, fns: &'a DeviceFns, width: u32, height: u32) -> Self {
        Self {
            cmd,
            fns,
            width,
            height,
            owned: false,
            ends: [(vk::Image::null(), vk::ImageLayout::UNDEFINED); 2 * MAX_COLOR_TARGETS],
            end_count: 0,
            has_pipeline: false,
        }
    }
    /// The UI's own pass, begun by the host (the inline route): dropping it leaves the pass to
    /// the host.
    pub fn wrap(device: &Device<'a>, cmd: vk::CommandBuffer, width: u32, height: u32) -> Self {
        Self::new(cmd, device.fns, width, height)
    }
    pub fn set_pipeline(&mut self, p: &RenderPipeline) {
        self.has_pipeline = true;
        unsafe {
            (self.fns.cmd_bind_pipeline)(self.cmd, vk::PipelineBindPoint::GRAPHICS, p.pipeline)
        };
    }
    pub fn set_bind_group<const G: u32>(
        &mut self,
        index: u32,
        group: &BindGroup<G>,
        offsets: &[u32],
    ) {
        debug_assert!(index == G, "bind group made for another @group");
        unsafe {
            (self.fns.cmd_bind_descriptor_sets)(
                self.cmd,
                vk::PipelineBindPoint::GRAPHICS,
                group.layout,
                G,
                1,
                &group.set,
                offsets.len() as u32,
                if offsets.is_empty() {
                    core::ptr::null()
                } else {
                    offsets.as_ptr()
                },
            )
        };
    }
    pub fn set_vertex_buffer(&mut self, slot: u32, slice: BufferSlice<'_>) {
        unsafe {
            (self.fns.cmd_bind_vertex_buffers)(
                self.cmd,
                slot,
                1,
                &slice.buffer.handle,
                &slice.offset,
            )
        };
    }
    pub fn set_index_buffer(&mut self, slice: BufferSlice<'_>, format: IndexFormat) {
        let t = if format == IndexFormat::Uint16 {
            vk::IndexType::UINT16
        } else {
            vk::IndexType::UINT32
        };
        unsafe { (self.fns.cmd_bind_index_buffer)(self.cmd, slice.buffer.handle, slice.offset, t) };
    }
    pub fn set_viewport(&mut self, x: f32, y: f32, w: f32, h: f32, min_depth: f32, max_depth: f32) {
        let v = vk::Viewport {
            x,
            y,
            width: w,
            height: h,
            min_depth,
            max_depth,
        };
        unsafe { (self.fns.cmd_set_viewport)(self.cmd, 0, 1, &v) };
    }
    pub fn set_scissor_rect(&mut self, x: u32, y: u32, w: u32, h: u32) {
        debug_assert!(
            x + w <= self.width && y + h <= self.height,
            "scissor outside the target"
        );
        let r = vk::Rect2D {
            offset: vk::Offset2D {
                x: x as i32,
                y: y as i32,
            },
            extent: vk::Extent2D {
                width: w,
                height: h,
            },
        };
        unsafe { (self.fns.cmd_set_scissor)(self.cmd, 0, 1, &r) };
    }
    pub fn set_blend_constant(&mut self, c: Color) {
        let k = [c.r as f32, c.g as f32, c.b as f32, c.a as f32];
        unsafe { (self.fns.cmd_set_blend_constants)(self.cmd, &k) };
    }
    pub fn draw(&mut self, vertices: Range<u32>, instances: Range<u32>) {
        debug_assert!(self.has_pipeline, "draw with no pipeline");
        unsafe {
            (self.fns.cmd_draw)(
                self.cmd,
                vertices.end - vertices.start,
                instances.end - instances.start,
                vertices.start,
                instances.start,
            )
        };
    }
    pub fn draw_indexed(&mut self, indices: Range<u32>, base_vertex: i32, instances: Range<u32>) {
        debug_assert!(self.has_pipeline, "draw with no pipeline");
        unsafe {
            (self.fns.cmd_draw_indexed)(
                self.cmd,
                indices.end - indices.start,
                instances.end - instances.start,
                indices.start,
                base_vertex,
                instances.start,
            )
        };
    }
    pub fn as_raw(&self) -> vk::CommandBuffer {
        self.cmd
    }
    pub fn fns(&self) -> &'a DeviceFns {
        self.fns
    }
}

impl Drop for RenderPass<'_> {
    /// Ends a pass the projection began, leaving its attachments in their resting layout.
    fn drop(&mut self) {
        if !self.owned {
            return;
        }
        unsafe { (self.fns.cmd_end_rendering)(self.cmd) };
        let mut barriers = [vk::ImageMemoryBarrier2::default(); 2 * MAX_COLOR_TARGETS];
        for (b, &(image, layout)) in barriers.iter_mut().zip(&self.ends[..self.end_count]) {
            *b = layout_barrier(
                image,
                vk::ImageLayout::COLOR_ATTACHMENT_OPTIMAL,
                layout,
                vk::PipelineStageFlags2::COLOR_ATTACHMENT_OUTPUT,
                vk::AccessFlags2::COLOR_ATTACHMENT_WRITE,
                vk::PipelineStageFlags2::ALL_COMMANDS,
                vk::AccessFlags2::MEMORY_READ,
            );
        }
        let dep = dependency(&[], &barriers[..self.end_count]);
        unsafe { (self.fns.cmd_pipeline_barrier2)(self.cmd, &dep) };
    }
}

/// A compute pass. Ends when dropped, with one barrier from its writes to every later read.
pub struct ComputePass<'a> {
    cmd: vk::CommandBuffer,
    fns: &'a DeviceFns,
}

impl ComputePass<'_> {
    pub fn set_pipeline(&mut self, p: &ComputePipeline) {
        unsafe {
            (self.fns.cmd_bind_pipeline)(self.cmd, vk::PipelineBindPoint::COMPUTE, p.pipeline)
        };
    }
    pub fn set_bind_group<const G: u32>(
        &mut self,
        index: u32,
        group: &BindGroup<G>,
        offsets: &[u32],
    ) {
        debug_assert!(index == G, "bind group made for another @group");
        unsafe {
            (self.fns.cmd_bind_descriptor_sets)(
                self.cmd,
                vk::PipelineBindPoint::COMPUTE,
                group.layout,
                G,
                1,
                &group.set,
                offsets.len() as u32,
                if offsets.is_empty() {
                    core::ptr::null()
                } else {
                    offsets.as_ptr()
                },
            )
        };
    }
    pub fn dispatch_workgroups(&mut self, x: u32, y: u32, z: u32) {
        unsafe { (self.fns.cmd_dispatch)(self.cmd, x, y, z) };
    }
    pub fn as_raw(&self) -> vk::CommandBuffer {
        self.cmd
    }
}

impl Drop for ComputePass<'_> {
    fn drop(&mut self) {
        let m = [memory_barrier(
            vk::PipelineStageFlags2::COMPUTE_SHADER,
            vk::AccessFlags2::SHADER_WRITE,
        )];
        let dep = dependency(&m, &[]);
        unsafe { (self.fns.cmd_pipeline_barrier2)(self.cmd, &dep) };
    }
}

// ---- creation ---------------------------------------------------------------------------------

impl VertexFormat {
    fn vk(self) -> vk::Format {
        use VertexFormat::*;
        match self {
            Float32 => vk::Format::R32_SFLOAT,
            Float32x2 => vk::Format::R32G32_SFLOAT,
            Float32x3 => vk::Format::R32G32B32_SFLOAT,
            Float32x4 => vk::Format::R32G32B32A32_SFLOAT,
            Uint32 => vk::Format::R32_UINT,
            Uint32x2 => vk::Format::R32G32_UINT,
            Uint32x4 => vk::Format::R32G32B32A32_UINT,
            Sint32 => vk::Format::R32_SINT,
            Unorm8x4 => vk::Format::R8G8B8A8_UNORM,
        }
    }
}

impl BlendFactor {
    fn vk(self) -> vk::BlendFactor {
        use BlendFactor::*;
        match self {
            Zero => vk::BlendFactor::ZERO,
            One => vk::BlendFactor::ONE,
            Src => vk::BlendFactor::SRC_COLOR,
            OneMinusSrc => vk::BlendFactor::ONE_MINUS_SRC_COLOR,
            SrcAlpha => vk::BlendFactor::SRC_ALPHA,
            OneMinusSrcAlpha => vk::BlendFactor::ONE_MINUS_SRC_ALPHA,
            Dst => vk::BlendFactor::DST_COLOR,
            OneMinusDst => vk::BlendFactor::ONE_MINUS_DST_COLOR,
            DstAlpha => vk::BlendFactor::DST_ALPHA,
            OneMinusDstAlpha => vk::BlendFactor::ONE_MINUS_DST_ALPHA,
            Constant => vk::BlendFactor::CONSTANT_COLOR,
            OneMinusConstant => vk::BlendFactor::ONE_MINUS_CONSTANT_COLOR,
        }
    }
}

/// One block of device memory and one descriptor pool, owned by the caller. Resources are
/// placed by bumping an offset.
pub struct Arena {
    pub memory: vk::DeviceMemory,
    pub type_index: u32,
    pub size: u64,
    pub used: u64,
    pub mapped: *mut u8,
    pub pool: vk::DescriptorPool,
}

impl Arena {
    fn place(&mut self, req: &vk::MemoryRequirements) -> Result<u64, vk::Result> {
        if (req.memory_type_bits >> self.type_index) & 1 == 0 {
            return Err(vk::Result::ERROR_OUT_OF_DEVICE_MEMORY);
        }
        let at = self.used.div_ceil(req.alignment) * req.alignment;
        if at + req.size > self.size {
            return Err(vk::Result::ERROR_OUT_OF_DEVICE_MEMORY);
        }
        self.used = at + req.size;
        Ok(at)
    }
}

fn ok(r: vk::Result) -> Result<(), vk::Result> {
    if r == vk::Result::SUCCESS {
        Ok(())
    } else {
        Err(r)
    }
}

impl Device<'_> {
    fn memory_type(&self, bits: u32, flags: vk::MemoryPropertyFlags) -> Option<u32> {
        (0..self.memory.memory_type_count).find(|&i| {
            (bits >> i) & 1 != 0
                && self.memory.memory_types[i as usize]
                    .property_flags
                    .contains(flags)
        })
    }

    pub fn create_arena(
        &self,
        bytes: u64,
        kind: MemoryKind,
        bind_groups: u32,
    ) -> Result<Arena, vk::Result> {
        let flags = match kind {
            MemoryKind::Device => vk::MemoryPropertyFlags::DEVICE_LOCAL,
            MemoryKind::Host => {
                vk::MemoryPropertyFlags::HOST_VISIBLE | vk::MemoryPropertyFlags::HOST_COHERENT
            }
        };
        let index = self
            .memory_type(u32::MAX, flags)
            .ok_or(vk::Result::ERROR_OUT_OF_DEVICE_MEMORY)?;
        let mut a = Arena {
            memory: vk::DeviceMemory::null(),
            type_index: index,
            size: bytes,
            used: 0,
            mapped: core::ptr::null_mut(),
            pool: vk::DescriptorPool::null(),
        };
        let mi = vk::MemoryAllocateInfo {
            allocation_size: bytes,
            memory_type_index: index,
            ..Default::default()
        };
        ok(unsafe {
            (self.fns.allocate_memory)(self.handle, &mi, core::ptr::null(), &mut a.memory)
        })?;
        if kind == MemoryKind::Host {
            let mut p = core::ptr::null_mut();
            ok(unsafe {
                (self.fns.map_memory)(
                    self.handle,
                    a.memory,
                    0,
                    bytes,
                    vk::MemoryMapFlags::empty(),
                    &mut p,
                )
            })?;
            a.mapped = p.cast();
        }
        let n = bind_groups;
        let sizes = [
            vk::DescriptorPoolSize {
                ty: vk::DescriptorType::UNIFORM_BUFFER,
                descriptor_count: 4 * n,
            },
            vk::DescriptorPoolSize {
                ty: vk::DescriptorType::STORAGE_BUFFER,
                descriptor_count: 4 * n,
            },
            vk::DescriptorPoolSize {
                ty: vk::DescriptorType::SAMPLED_IMAGE,
                descriptor_count: 4 * n,
            },
            vk::DescriptorPoolSize {
                ty: vk::DescriptorType::STORAGE_IMAGE,
                descriptor_count: n,
            },
            vk::DescriptorPoolSize {
                ty: vk::DescriptorType::SAMPLER,
                descriptor_count: 2 * n,
            },
        ];
        let pi = vk::DescriptorPoolCreateInfo {
            max_sets: n,
            pool_size_count: sizes.len() as u32,
            p_pool_sizes: sizes.as_ptr(),
            ..Default::default()
        };
        ok(unsafe {
            (self.fns.create_descriptor_pool)(self.handle, &pi, core::ptr::null(), &mut a.pool)
        })?;
        Ok(a)
    }

    pub fn destroy_arena(&self, a: Arena) {
        unsafe {
            (self.fns.destroy_descriptor_pool)(self.handle, a.pool, core::ptr::null());
            (self.fns.free_memory)(self.handle, a.memory, core::ptr::null());
        }
    }

    pub fn create_buffer(
        &self,
        arena: &mut Arena,
        d: &BufferDescriptor,
    ) -> Result<Buffer, vk::Result> {
        let u = d.usage;
        let mut f = vk::BufferUsageFlags::empty();
        if u.has(BufferUsages::COPY_SRC) || u.has(BufferUsages::MAP_READ) {
            f |= vk::BufferUsageFlags::TRANSFER_SRC;
        }
        if u.has(BufferUsages::COPY_DST) || u.has(BufferUsages::MAP_WRITE) {
            f |= vk::BufferUsageFlags::TRANSFER_DST;
        }
        for (bit, flag) in [
            (BufferUsages::INDEX, vk::BufferUsageFlags::INDEX_BUFFER),
            (BufferUsages::VERTEX, vk::BufferUsageFlags::VERTEX_BUFFER),
            (BufferUsages::UNIFORM, vk::BufferUsageFlags::UNIFORM_BUFFER),
            (BufferUsages::STORAGE, vk::BufferUsageFlags::STORAGE_BUFFER),
            (
                BufferUsages::INDIRECT,
                vk::BufferUsageFlags::INDIRECT_BUFFER,
            ),
        ] {
            if u.has(bit) {
                f |= flag;
            }
        }
        let bi = vk::BufferCreateInfo {
            size: d.size,
            usage: f,
            sharing_mode: vk::SharingMode::EXCLUSIVE,
            ..Default::default()
        };
        let mut b = Buffer {
            handle: vk::Buffer::null(),
            size: d.size,
            mapped: core::ptr::null_mut(),
        };
        ok(unsafe {
            (self.fns.create_buffer)(self.handle, &bi, core::ptr::null(), &mut b.handle)
        })?;
        let mut req = vk::MemoryRequirements::default();
        unsafe { (self.fns.get_buffer_memory_requirements)(self.handle, b.handle, &mut req) };
        let at = arena.place(&req).inspect_err(|_| unsafe {
            (self.fns.destroy_buffer)(self.handle, b.handle, core::ptr::null())
        })?;
        ok(unsafe { (self.fns.bind_buffer_memory)(self.handle, b.handle, arena.memory, at) })?;
        if !arena.mapped.is_null() {
            b.mapped = unsafe { arena.mapped.add(at as usize) };
        }
        Ok(b)
    }

    pub fn destroy_buffer(&self, b: &Buffer) {
        unsafe { (self.fns.destroy_buffer)(self.handle, b.handle, core::ptr::null()) };
    }

    pub fn create_texture(
        &self,
        arena: &mut Arena,
        d: &TextureDescriptor,
    ) -> Result<Texture, vk::Result> {
        let mut f = vk::ImageUsageFlags::empty();
        for (bit, flag) in [
            (TextureUsages::COPY_SRC, vk::ImageUsageFlags::TRANSFER_SRC),
            (TextureUsages::COPY_DST, vk::ImageUsageFlags::TRANSFER_DST),
            (TextureUsages::TEXTURE_BINDING, vk::ImageUsageFlags::SAMPLED),
            (TextureUsages::STORAGE_BINDING, vk::ImageUsageFlags::STORAGE),
            (
                TextureUsages::RENDER_ATTACHMENT,
                vk::ImageUsageFlags::COLOR_ATTACHMENT,
            ),
        ] {
            if d.usage.has(bit) {
                f |= flag;
            }
        }
        let resting = if d.usage.has(TextureUsages::STORAGE_BINDING) {
            vk::ImageLayout::GENERAL
        } else {
            vk::ImageLayout::SHADER_READ_ONLY_OPTIMAL
        };
        let mut t = Texture {
            image: vk::Image::null(),
            view: vk::ImageView::null(),
            format: d.format,
            width: d.width,
            height: d.height,
            samples: d.sample_count,
            resting,
        };
        let ii = vk::ImageCreateInfo {
            image_type: vk::ImageType::TYPE_2D,
            format: d.format.vk(),
            extent: vk::Extent3D {
                width: d.width,
                height: d.height,
                depth: 1,
            },
            mip_levels: d.mip_level_count,
            array_layers: 1,
            samples: vk::SampleCountFlags::from_raw(d.sample_count),
            tiling: vk::ImageTiling::OPTIMAL,
            usage: f,
            sharing_mode: vk::SharingMode::EXCLUSIVE,
            initial_layout: vk::ImageLayout::UNDEFINED,
            ..Default::default()
        };
        ok(unsafe { (self.fns.create_image)(self.handle, &ii, core::ptr::null(), &mut t.image) })?;
        let mut req = vk::MemoryRequirements::default();
        unsafe { (self.fns.get_image_memory_requirements)(self.handle, t.image, &mut req) };
        let at = arena.place(&req).inspect_err(|_| unsafe {
            (self.fns.destroy_image)(self.handle, t.image, core::ptr::null())
        })?;
        ok(unsafe { (self.fns.bind_image_memory)(self.handle, t.image, arena.memory, at) })?;
        let vi = vk::ImageViewCreateInfo {
            image: t.image,
            view_type: vk::ImageViewType::TYPE_2D,
            format: ii.format,
            subresource_range: vk::ImageSubresourceRange {
                aspect_mask: d.format.aspect(),
                base_mip_level: 0,
                level_count: d.mip_level_count,
                base_array_layer: 0,
                layer_count: 1,
            },
            ..Default::default()
        };
        ok(unsafe {
            (self.fns.create_image_view)(self.handle, &vi, core::ptr::null(), &mut t.view)
        })?;
        Ok(t)
    }

    pub fn destroy_texture(&self, t: &Texture) {
        unsafe {
            (self.fns.destroy_image_view)(self.handle, t.view, core::ptr::null());
            (self.fns.destroy_image)(self.handle, t.image, core::ptr::null());
        }
    }

    pub fn create_sampler(&self, d: &SamplerDescriptor) -> Result<Sampler, vk::Result> {
        let filter = |f: FilterMode| {
            if f == FilterMode::Linear {
                vk::Filter::LINEAR
            } else {
                vk::Filter::NEAREST
            }
        };
        let address = |a: AddressMode| match a {
            AddressMode::ClampToEdge => vk::SamplerAddressMode::CLAMP_TO_EDGE,
            AddressMode::Repeat => vk::SamplerAddressMode::REPEAT,
            AddressMode::MirrorRepeat => vk::SamplerAddressMode::MIRRORED_REPEAT,
        };
        let si = vk::SamplerCreateInfo {
            mag_filter: filter(d.mag_filter),
            min_filter: filter(d.min_filter),
            mipmap_mode: if d.mipmap_filter == FilterMode::Linear {
                vk::SamplerMipmapMode::LINEAR
            } else {
                vk::SamplerMipmapMode::NEAREST
            },
            address_mode_u: address(d.address_mode_u),
            address_mode_v: address(d.address_mode_v),
            address_mode_w: address(d.address_mode_w),
            compare_op: vk::CompareOp::NEVER,
            min_lod: d.lod_min_clamp,
            max_lod: d.lod_max_clamp,
            ..Default::default()
        };
        let mut s = Sampler {
            handle: vk::Sampler::null(),
        };
        ok(unsafe {
            (self.fns.create_sampler)(self.handle, &si, core::ptr::null(), &mut s.handle)
        })?;
        Ok(s)
    }

    pub fn destroy_sampler(&self, s: &Sampler) {
        unsafe { (self.fns.destroy_sampler)(self.handle, s.handle, core::ptr::null()) };
    }

    /// A ring of `bytes` for texture writes, in a host arena.
    pub fn create_staging(&self, host: &mut Arena, bytes: u64) -> Result<Staging, vk::Result> {
        if host.mapped.is_null() {
            return Err(vk::Result::ERROR_MEMORY_MAP_FAILED);
        }
        Ok(Staging {
            buffer: self.create_buffer(
                host,
                &BufferDescriptor {
                    size: bytes,
                    usage: BufferUsages::COPY_SRC,
                },
            )?,
            used: 0,
        })
    }

    fn layout(
        &self,
        groups: &[&[BindingLayout]],
        sets: &mut [vk::DescriptorSetLayout; MAX_GROUPS],
        out: &mut vk::PipelineLayout,
    ) -> Result<(), vk::Result> {
        assert!(groups.len() <= MAX_GROUPS);
        for (g, bs) in groups.iter().enumerate() {
            let mut lb = [vk::DescriptorSetLayoutBinding::default(); 16];
            for (l, b) in lb.iter_mut().zip(bs.iter()) {
                *l = vk::DescriptorSetLayoutBinding {
                    binding: b.binding,
                    descriptor_type: b.kind.descriptor_type(),
                    descriptor_count: 1,
                    stage_flags: vk::ShaderStageFlags::ALL,
                    ..Default::default()
                };
            }
            let ci = vk::DescriptorSetLayoutCreateInfo {
                binding_count: bs.len() as u32,
                p_bindings: lb.as_ptr(),
                ..Default::default()
            };
            ok(unsafe {
                (self.fns.create_descriptor_set_layout)(
                    self.handle,
                    &ci,
                    core::ptr::null(),
                    &mut sets[g],
                )
            })?;
        }
        let pi = vk::PipelineLayoutCreateInfo {
            set_layout_count: groups.len() as u32,
            p_set_layouts: sets.as_ptr(),
            ..Default::default()
        };
        ok(unsafe { (self.fns.create_pipeline_layout)(self.handle, &pi, core::ptr::null(), out) })
    }

    fn module(&self, spirv: &[u32]) -> Result<vk::ShaderModule, vk::Result> {
        let mi = vk::ShaderModuleCreateInfo {
            code_size: spirv.len() * 4,
            p_code: spirv.as_ptr(),
            ..Default::default()
        };
        let mut m = vk::ShaderModule::null();
        ok(unsafe {
            (self.fns.create_shader_module)(self.handle, &mi, core::ptr::null(), &mut m)
        })?;
        Ok(m)
    }

    /// A render pipeline for shader `S` (from `include_shader!`). Its layout comes from the
    /// shader's reflected groups.
    pub fn create_render_pipeline<S: ShaderSource>(
        &self,
        d: &RenderPipelineDescriptor<'_>,
    ) -> Result<RenderPipelineOf<S>, vk::Result> {
        let mut p = RenderPipeline::default();
        self.layout(S::GROUPS, &mut p.set_layouts, &mut p.layout)?;
        let module = self.module(S::SPIRV)?;
        let frag = d.fragment.unwrap_or(FragmentState {
            entry_point: c"fs",
            targets: &[],
        });
        let stages = [
            vk::PipelineShaderStageCreateInfo {
                stage: vk::ShaderStageFlags::VERTEX,
                module,
                p_name: d.vertex.entry_point.as_ptr(),
                ..Default::default()
            },
            vk::PipelineShaderStageCreateInfo {
                stage: vk::ShaderStageFlags::FRAGMENT,
                module,
                p_name: frag.entry_point.as_ptr(),
                ..Default::default()
            },
        ];
        let mut bindings = [vk::VertexInputBindingDescription::default(); 8];
        let mut attrs = [vk::VertexInputAttributeDescription::default(); 16];
        let mut nattr = 0;
        for (slot, vb) in d.vertex.buffers.iter().enumerate() {
            bindings[slot] = vk::VertexInputBindingDescription {
                binding: slot as u32,
                stride: vb.array_stride as u32,
                input_rate: if vb.step_mode_instance {
                    vk::VertexInputRate::INSTANCE
                } else {
                    vk::VertexInputRate::VERTEX
                },
            };
            for a in vb.attributes {
                attrs[nattr] = vk::VertexInputAttributeDescription {
                    location: a.shader_location,
                    binding: slot as u32,
                    format: a.format.vk(),
                    offset: a.offset as u32,
                };
                nattr += 1;
            }
        }
        let vertex = vk::PipelineVertexInputStateCreateInfo {
            vertex_binding_description_count: d.vertex.buffers.len() as u32,
            p_vertex_binding_descriptions: bindings.as_ptr(),
            vertex_attribute_description_count: nattr as u32,
            p_vertex_attribute_descriptions: attrs.as_ptr(),
            ..Default::default()
        };
        let topology = match d.topology {
            PrimitiveTopology::PointList => vk::PrimitiveTopology::POINT_LIST,
            PrimitiveTopology::LineList => vk::PrimitiveTopology::LINE_LIST,
            PrimitiveTopology::LineStrip => vk::PrimitiveTopology::LINE_STRIP,
            PrimitiveTopology::TriangleList => vk::PrimitiveTopology::TRIANGLE_LIST,
            PrimitiveTopology::TriangleStrip => vk::PrimitiveTopology::TRIANGLE_STRIP,
        };
        let assembly = vk::PipelineInputAssemblyStateCreateInfo {
            topology,
            ..Default::default()
        };
        let viewport = vk::PipelineViewportStateCreateInfo {
            viewport_count: 1,
            scissor_count: 1,
            ..Default::default()
        };
        // naga's SPIR-V flips y, so framebuffer winding is WebGPU's: ccw stays ccw.
        let raster = vk::PipelineRasterizationStateCreateInfo {
            polygon_mode: vk::PolygonMode::FILL,
            cull_mode: match d.cull_mode {
                CullMode::None => vk::CullModeFlags::NONE,
                CullMode::Front => vk::CullModeFlags::FRONT,
                CullMode::Back => vk::CullModeFlags::BACK,
            },
            front_face: if d.front_face_ccw {
                vk::FrontFace::COUNTER_CLOCKWISE
            } else {
                vk::FrontFace::CLOCKWISE
            },
            line_width: 1.0,
            ..Default::default()
        };
        let mask = u32::MAX;
        let multisample = vk::PipelineMultisampleStateCreateInfo {
            rasterization_samples: vk::SampleCountFlags::from_raw(d.sample_count.max(1)),
            p_sample_mask: &mask,
            ..Default::default()
        };
        let mut blends = [vk::PipelineColorBlendAttachmentState::default(); MAX_COLOR_TARGETS];
        let mut formats = [vk::Format::UNDEFINED; MAX_COLOR_TARGETS];
        for (i, t) in frag.targets.iter().enumerate() {
            formats[i] = t.format.vk();
            blends[i].color_write_mask = vk::ColorComponentFlags::from_raw(t.write_mask);
            if let Some(b) = t.blend {
                let op = |o: BlendOperation| match o {
                    BlendOperation::Add => vk::BlendOp::ADD,
                    BlendOperation::Subtract => vk::BlendOp::SUBTRACT,
                    BlendOperation::ReverseSubtract => vk::BlendOp::REVERSE_SUBTRACT,
                    BlendOperation::Min => vk::BlendOp::MIN,
                    BlendOperation::Max => vk::BlendOp::MAX,
                };
                blends[i].blend_enable = vk::TRUE;
                blends[i].src_color_blend_factor = b.color.src_factor.vk();
                blends[i].dst_color_blend_factor = b.color.dst_factor.vk();
                blends[i].color_blend_op = op(b.color.operation);
                blends[i].src_alpha_blend_factor = b.alpha.src_factor.vk();
                blends[i].dst_alpha_blend_factor = b.alpha.dst_factor.vk();
                blends[i].alpha_blend_op = op(b.alpha.operation);
            }
        }
        let blend = vk::PipelineColorBlendStateCreateInfo {
            attachment_count: frag.targets.len() as u32,
            p_attachments: blends.as_ptr(),
            ..Default::default()
        };
        let dynamic_states = [
            vk::DynamicState::VIEWPORT,
            vk::DynamicState::SCISSOR,
            vk::DynamicState::BLEND_CONSTANTS,
        ];
        let dynamic = vk::PipelineDynamicStateCreateInfo {
            dynamic_state_count: 3,
            p_dynamic_states: dynamic_states.as_ptr(),
            ..Default::default()
        };
        let mut rendering = vk::PipelineRenderingCreateInfo {
            color_attachment_count: frag.targets.len() as u32,
            p_color_attachment_formats: formats.as_ptr(),
            ..Default::default()
        };
        let gi = vk::GraphicsPipelineCreateInfo {
            p_next: (&mut rendering as *mut vk::PipelineRenderingCreateInfo).cast(),
            stage_count: if d.fragment.is_some() { 2 } else { 1 },
            p_stages: stages.as_ptr(),
            p_vertex_input_state: &vertex,
            p_input_assembly_state: &assembly,
            p_viewport_state: &viewport,
            p_rasterization_state: &raster,
            p_multisample_state: &multisample,
            p_color_blend_state: &blend,
            p_dynamic_state: &dynamic,
            layout: p.layout,
            ..Default::default()
        };
        let r = unsafe {
            (self.fns.create_graphics_pipelines)(
                self.handle,
                vk::PipelineCache::null(),
                1,
                &gi,
                core::ptr::null(),
                &mut p.pipeline,
            )
        };
        unsafe { (self.fns.destroy_shader_module)(self.handle, module, core::ptr::null()) };
        ok(r)?;
        Ok(RenderPipelineOf {
            raw: p,
            _s: PhantomData,
        })
    }

    pub fn create_compute_pipeline<S: ShaderSource>(
        &self,
        entry_point: &CStr,
    ) -> Result<ComputePipelineOf<S>, vk::Result> {
        let mut p = ComputePipeline::default();
        self.layout(S::GROUPS, &mut p.set_layouts, &mut p.layout)?;
        let module = self.module(S::SPIRV)?;
        let ci = vk::ComputePipelineCreateInfo {
            stage: vk::PipelineShaderStageCreateInfo {
                stage: vk::ShaderStageFlags::COMPUTE,
                module,
                p_name: entry_point.as_ptr(),
                ..Default::default()
            },
            layout: p.layout,
            ..Default::default()
        };
        let r = unsafe {
            (self.fns.create_compute_pipelines)(
                self.handle,
                vk::PipelineCache::null(),
                1,
                &ci,
                core::ptr::null(),
                &mut p.pipeline,
            )
        };
        unsafe { (self.fns.destroy_shader_module)(self.handle, module, core::ptr::null()) };
        ok(r)?;
        Ok(ComputePipelineOf {
            raw: p,
            _s: PhantomData,
        })
    }

    pub fn destroy_pipeline(
        &self,
        pipeline: vk::Pipeline,
        layout: vk::PipelineLayout,
        sets: &[vk::DescriptorSetLayout; MAX_GROUPS],
    ) {
        unsafe {
            (self.fns.destroy_pipeline)(self.handle, pipeline, core::ptr::null());
            (self.fns.destroy_pipeline_layout)(self.handle, layout, core::ptr::null());
            for &l in sets {
                if l != vk::DescriptorSetLayout::null() {
                    (self.fns.destroy_descriptor_set_layout)(self.handle, l, core::ptr::null());
                }
            }
        }
    }

    pub fn destroy_render_pipeline(&self, p: &RenderPipeline) {
        self.destroy_pipeline(p.pipeline, p.layout, &p.set_layouts);
    }
    pub fn destroy_compute_pipeline(&self, p: &ComputePipeline) {
        self.destroy_pipeline(p.pipeline, p.layout, &p.set_layouts);
    }
    pub fn destroy_staging(&self, s: Staging) {
        self.destroy_buffer(&s.buffer);
    }

    /// A bind group from a generated `<shader>::GroupN`: one field per binding the WGSL declares,
    /// so a missing resource does not compile, nor does a group of another shader.
    pub fn create_bind_group<P: PipelineOf, G: Group<Shader = P::Shader>>(
        &self,
        arena: &mut Arena,
        pipeline: &P,
        group: &G,
    ) -> Result<G::BindGroup, vk::Result> {
        let ai = vk::DescriptorSetAllocateInfo {
            descriptor_pool: arena.pool,
            descriptor_set_count: 1,
            p_set_layouts: &pipeline.set_layouts()[G::INDEX as usize],
            ..Default::default()
        };
        let mut set = vk::DescriptorSet::null();
        ok(unsafe { (self.fns.allocate_descriptor_sets)(self.handle, &ai, &mut set) })?;
        let mut res = [Resource::EMPTY; 16];
        let n = group.resources(&mut res);
        let mut buffers = [vk::DescriptorBufferInfo::default(); 16];
        let mut images = [vk::DescriptorImageInfo::default(); 16];
        for i in 0..n {
            buffers[i] = vk::DescriptorBufferInfo {
                buffer: res[i].buffer,
                offset: 0,
                range: vk::WHOLE_SIZE,
            };
            images[i] = vk::DescriptorImageInfo {
                sampler: res[i].sampler,
                image_view: res[i].view,
                image_layout: res[i].layout,
            };
        }
        let mut writes = [vk::WriteDescriptorSet::default(); 16];
        for i in 0..n {
            let r = &res[i];
            writes[i] = vk::WriteDescriptorSet {
                dst_set: set,
                dst_binding: r.binding,
                descriptor_count: 1,
                descriptor_type: r.kind.descriptor_type(),
                ..Default::default()
            };
            match r.kind {
                BindingKind::Uniform | BindingKind::StorageRead | BindingKind::StorageReadWrite => {
                    writes[i].p_buffer_info = &buffers[i]
                }
                _ => writes[i].p_image_info = &images[i],
            }
        }
        unsafe {
            (self.fns.update_descriptor_sets)(
                self.handle,
                n as u32,
                writes.as_ptr(),
                0,
                core::ptr::null(),
            )
        };
        Ok((set, pipeline.layout()).into())
    }
}
