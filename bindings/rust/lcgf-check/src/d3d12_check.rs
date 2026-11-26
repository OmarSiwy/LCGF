//! The Rust side of the bindings' D3D12 gate: bindings/check/d3d12_dump.zig's resources,
//! pipelines and frame, made through `lcgf::gpu` with the `d3d12` feature on the recording
//! device and command list of d3d12_record.c. run.sh requires the log to equal Zig's.
//!
//!   lcgf-d3d12-check <out.txt>

use core::ffi::c_void;
use lcgf::gpu;

// The committed HLSL the Zig side uses (src/render/shaders/gen/), so the logs hash the same code.
lcgf::include_shader!("textured.wgsl", hlsl = "../shaders/gen/gpu_textured.hlsl");
lcgf::include_shader!("fill.wgsl", hlsl = "../shaders/gen/gpu_fill.hlsl");

unsafe extern "C" {
    fn lcgf_d3d12_record_device() -> *mut c_void;
    fn lcgf_d3d12_record_list() -> *mut c_void;
    fn lcgf_d3d12_record_log(len: *mut usize) -> *const u8;
}

fn main() {
    let out = std::env::args()
        .nth(1)
        .expect("usage: lcgf-d3d12-check <out.txt>");
    let mut d = gpu::Device::wrap(unsafe { lcgf_d3d12_record_device() });
    let list = unsafe { lcgf_d3d12_record_list() };

    let mut arena = d
        .create_arena(1 << 20, gpu::MemoryKind::Device, 64)
        .unwrap();
    let mut host = d.create_arena(1 << 16, gpu::MemoryKind::Host, 8).unwrap();
    let mut staging = d.create_staging(&mut host, 4096).unwrap();
    d.staging = &mut staging;
    use gpu::BufferUsages as BU;
    let buffer = d
        .create_buffer(
            &mut arena,
            &gpu::BufferDescriptor {
                size: 64,
                usage: BU::VERTEX | BU::INDEX | BU::UNIFORM | BU::COPY_DST,
            },
        )
        .unwrap();
    let storage = d
        .create_buffer(
            &mut arena,
            &gpu::BufferDescriptor {
                size: 256,
                usage: BU::STORAGE | BU::COPY_SRC,
            },
        )
        .unwrap();
    let base = d
        .create_buffer(
            &mut arena,
            &gpu::BufferDescriptor {
                size: 16,
                usage: BU::UNIFORM | BU::COPY_DST,
            },
        )
        .unwrap();
    // A host buffer the GPU writes: a custom heap, not the upload heap (create_buffer).
    let shared = d
        .create_buffer(
            &mut host,
            &gpu::BufferDescriptor {
                size: 16,
                usage: BU::UNIFORM | BU::COPY_DST,
            },
        )
        .unwrap();
    let texture = d
        .create_texture(
            &mut arena,
            &gpu::TextureDescriptor {
                width: 64,
                height: 32,
                format: gpu::TextureFormat::Rgba8Unorm,
                usage: gpu::TextureUsages::TEXTURE_BINDING | gpu::TextureUsages::RENDER_ATTACHMENT,
                mip_level_count: 1,
                sample_count: 1,
            },
        )
        .unwrap();
    let sampler = d
        .create_sampler(&gpu::SamplerDescriptor {
            address_mode_u: gpu::AddressMode::Repeat,
            mag_filter: gpu::FilterMode::Linear,
            min_filter: gpu::FilterMode::Linear,
            ..Default::default()
        })
        .unwrap();

    let attrs = [gpu::VertexAttribute {
        format: gpu::VertexFormat::Float32x2,
        offset: 0,
        shader_location: 0,
    }];
    let buffers = [gpu::VertexBufferLayout {
        array_stride: 8,
        step_mode_instance: false,
        attributes: &attrs,
    }];
    let targets = [gpu::ColorTargetState {
        format: gpu::TextureFormat::Rgba8Unorm,
        blend: Some(gpu::BlendState::PREMULTIPLIED),
        write_mask: 0xf,
    }];
    let pipeline = d
        .create_render_pipeline::<textured::Shader>(&gpu::RenderPipelineDescriptor {
            vertex: gpu::VertexState {
                entry_point: c"vs",
                buffers: &buffers,
            },
            fragment: Some(gpu::FragmentState {
                entry_point: c"fs",
                targets: &targets,
            }),
            topology: gpu::PrimitiveTopology::TriangleList,
            cull_mode: gpu::CullMode::Back,
            front_face_ccw: true,
            sample_count: 1,
        })
        .unwrap();
    let kpipe = d.create_compute_pipeline::<fill::Shader>(c"main").unwrap();
    let view = texture.create_view();
    let group = d
        .create_bind_group(
            &mut arena,
            &pipeline,
            &textured::Group0 {
                params: &buffer,
                tex: &view,
                smp: &sampler,
            },
        )
        .unwrap();
    let kgroup = d
        .create_bind_group(
            &mut arena,
            &kpipe,
            &fill::Group0 {
                out: &storage,
                base: &base,
            },
        )
        .unwrap();

    let mut up = gpu::Upload::new(&d, list);
    let data: Vec<u8> = [1.0f32, 2.0, 3.0, 4.0]
        .iter()
        .flat_map(|f| f.to_le_bytes())
        .collect();
    up.write_buffer(&buffer, 0, &data);
    up.write_buffer(&shared, 0, &data);
    let encoder = up.finish();

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
        let mut ui = gpu::RenderPass::wrap(&d, list, 800, 600);
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

    d.destroy_compute_pipeline(&kpipe);
    d.destroy_render_pipeline(&pipeline);
    d.destroy_sampler(&sampler);
    d.destroy_texture(&texture);
    d.destroy_buffer(&shared);
    d.destroy_buffer(&base);
    d.destroy_buffer(&storage);
    d.destroy_buffer(&buffer);
    d.destroy_staging(staging);
    d.destroy_arena(host);
    d.destroy_arena(arena);

    let mut len = 0usize;
    let log = unsafe { std::slice::from_raw_parts(lcgf_d3d12_record_log(&mut len), len) };
    std::fs::write(out, log).expect("write");
}
