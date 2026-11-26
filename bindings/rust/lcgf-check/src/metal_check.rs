//! The Rust side of the bindings' Metal gate: bindings/check/metal_dump.zig's resources,
//! pipelines and frame, made through `lcgf::gpu` with the `metal` feature against the
//! recording Objective-C runtime (objc_record.c). run.sh requires the log to equal Zig's.
//!
//!   lcgf-metal-check <liblcgf_objc_record.so> <out.txt>

use lcgf::gpu;
use lcgf::gpu::objc::{self, Id};
use std::ffi::{CString, c_char, c_void};

// The committed MSL the Zig side uses (src/render/shaders/gen/), so the logs hash the same code.
lcgf::include_shader!("textured.wgsl", msl = "../shaders/gen/gpu_textured.metal");
lcgf::include_shader!("fill.wgsl", msl = "../shaders/gen/gpu_fill.metal");

unsafe extern "C" {
    fn dlopen(path: *const c_char, mode: i32) -> *mut c_void;
    fn dlsym(handle: *mut c_void, name: *const c_char) -> *mut c_void;
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    assert!(
        args.len() == 3,
        "usage: lcgf-metal-check <liblcgf_objc_record.so> <out.txt>"
    );
    let lib = CString::new(args[1].as_str()).unwrap();
    assert!(objc::load_from(&objc::Paths {
        objc: &lib,
        metal: &lib,
        quartz_core: None,
    }));
    let device = objc::create_system_default_device();
    let mut d = gpu::Device::wrap(device);
    let (queue, cmd): (Id, Id) = unsafe {
        let q: Id = lcgf::objc_send!(Id; device, "newCommandQueue");
        (q, lcgf::objc_send!(Id; q, "commandBuffer"))
    };
    let _ = queue;

    let mut host = d.create_arena(1 << 16, gpu::MemoryKind::Host, 8).unwrap();
    let mut arena = d
        .create_arena(1 << 20, gpu::MemoryKind::Device, 64)
        .unwrap();
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

    let mut up = gpu::Upload::new(&d, cmd);
    let data: Vec<u8> = [1.0f32, 2.0, 3.0, 4.0]
        .iter()
        .flat_map(|f| f.to_le_bytes())
        .collect();
    up.write_buffer(&buffer, 0, &data);
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
        let (host_pass, host_encoder): (Id, Id) = unsafe {
            let rp: Id = lcgf::objc_send!(Id; objc::class(c"MTLRenderPassDescriptor"), "renderPassDescriptor");
            (
                rp,
                lcgf::objc_send!(Id; cmd, "renderCommandEncoderWithDescriptor:", rp => Id),
            )
        };
        let _ = host_pass;
        let mut ui = gpu::RenderPass::wrap(&d, host_encoder, 800, 600);
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
    d.destroy_buffer(&base);
    d.destroy_buffer(&storage);
    d.destroy_buffer(&buffer);
    d.destroy_staging(staging);

    let log = unsafe {
        let h = dlopen(lib.as_ptr(), 2);
        let f: unsafe extern "C" fn(*mut usize) -> *const u8 =
            std::mem::transmute(dlsym(h, c"lcgf_objc_record_log".as_ptr()));
        let mut len = 0usize;
        let p = f(&mut len);
        std::slice::from_raw_parts(p, len).to_vec()
    };
    std::fs::write(&args[2], log).expect("write");
}
