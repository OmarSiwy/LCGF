//! The Rust side of the bindings' GPU gate: bindings/check/gpu_dump.zig's frame, recorded
//! through `lcgf::gpu`. run.sh requires the log to equal Zig's.
//!
//!   lcgf-gpu-check <out.txt>

use ash::vk::Handle;
use lcgf::gpu::{self, vk};

unsafe extern "system" {
    fn lcgf_record_get_device_proc_addr(
        device: vk::Device,
        name: *const core::ffi::c_char,
    ) -> vk::PFN_vkVoidFunction;
}
unsafe extern "C" {
    fn lcgf_record_log(len: *mut usize) -> *const u8;
}

fn main() {
    let out = std::env::args()
        .nth(1)
        .expect("usage: lcgf-gpu-check <out.txt>");
    let fns = unsafe { gpu::DeviceFns::load(lcgf_record_get_device_proc_addr, vk::Device::null()) };
    let device = gpu::Device {
        handle: vk::Device::null(),
        fns: &fns,
        memory: Default::default(),
    };
    let cmd = vk::CommandBuffer::from_raw(0xc0);

    let pipeline = gpu::RenderPipeline {
        pipeline: vk::Pipeline::from_raw(0x4000),
        layout: vk::PipelineLayout::from_raw(0x4001),
        set_layouts: Default::default(),
    };
    let group = gpu::BindGroup::<0> {
        set: vk::DescriptorSet::from_raw(0x5000),
        layout: vk::PipelineLayout::from_raw(0x4001),
    };
    let kpipe = gpu::ComputePipeline {
        pipeline: vk::Pipeline::from_raw(0x4100),
        layout: vk::PipelineLayout::from_raw(0x4101),
        set_layouts: Default::default(),
    };
    let kgroup = gpu::BindGroup::<0> {
        set: vk::DescriptorSet::from_raw(0x5100),
        layout: vk::PipelineLayout::from_raw(0x4101),
    };
    let buffer = gpu::Buffer {
        handle: vk::Buffer::from_raw(0x2000),
        size: 64,
        mapped: core::ptr::null_mut(),
    };
    let texture = gpu::Texture {
        image: vk::Image::from_raw(0x3000),
        view: vk::ImageView::from_raw(0x3001),
        format: gpu::TextureFormat::Rgba8Unorm,
        width: 64,
        height: 32,
        samples: 1,
        resting: vk::ImageLayout::SHADER_READ_ONLY_OPTIMAL,
    };

    let mut up = gpu::Upload::new(&device, cmd);
    let data: Vec<u8> = [1.0f32, 2.0, 3.0, 4.0]
        .iter()
        .flat_map(|f| f.to_le_bytes())
        .collect();
    up.write_buffer(&buffer, 0, &data);
    let encoder = up.finish();

    let view = texture.create_view();
    {
        let attachments = [Some(gpu::RenderPassColorAttachment {
            view: &view,
            resolve_target: None,
            ops: gpu::Operations {
                load: gpu::LoadOp::Clear(gpu::Color {
                    a: 1.0,
                    ..Default::default()
                }),
                store: gpu::StoreOp::Store,
            },
        })];
        let mut pass = encoder.begin_render_pass(&gpu::RenderPassDescriptor {
            color_attachments: &attachments,
        });
        pass.set_pipeline(&pipeline);
        pass.set_bind_group(0, &group, &[]);
        pass.set_vertex_buffer(0, buffer.slice(16..));
        pass.set_index_buffer(buffer.slice(32..), gpu::IndexFormat::Uint16);
        pass.set_viewport(0.0, 0.0, 64.0, 32.0, 0.0, 1.0);
        pass.set_scissor_rect(8, 8, 16, 16);
        pass.set_blend_constant(gpu::Color {
            r: 0.5,
            g: 0.25,
            b: 0.0,
            a: 1.0,
        });
        pass.draw(0..6, 0..1);
        pass.draw_indexed(0..6, 0, 0..2);
    } // the pass ends here

    {
        let mut ui = gpu::RenderPass::wrap(&device, cmd, 800, 600);
        ui.set_pipeline(&pipeline);
        ui.set_bind_group(0, &group, &[]);
        ui.set_scissor_rect(10, 20, 30, 40);
        ui.draw(0..3, 0..1);
    }

    {
        let mut compute = encoder.begin_compute_pass();
        compute.set_pipeline(&kpipe);
        compute.set_bind_group(0, &kgroup, &[]);
        compute.dispatch_workgroups(4, 1, 1);
    }

    let mut len = 0usize;
    let log = unsafe { std::slice::from_raw_parts(lcgf_record_log(&mut len), len) };
    std::fs::write(out, log).unwrap();
}
