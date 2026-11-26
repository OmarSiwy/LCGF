//! The checks of src/render/gpu/check.zig, written once against `lcgf::gpu` and run by every back
//! end on a real device (vk_check.rs, gles_check.rs, wgpu_check.rs), over shaders
//! `include_shader!` made from the repository's WGSL. As in check.zig, the host supplies a
//! command stream, submission and readback (`Host`).
//!
//! `render_to_texture`: a 2 x 2 pattern uploaded through staging, drawn into 4 x 4, sampled into
//! 8 x 8 in a second pass; each source texel must come back as a 4 x 4 block. `compute`: element
//! i of a storage buffer becomes i * 3 + 7.

use lcgf::gpu;

lcgf::include_shader!("textured.wgsl");
lcgf::include_shader!("fill.wgsl");

pub trait Host {
    /// A command stream begun for one submission.
    fn upload<'s>(&'s mut self, staging: Option<&'s mut gpu::Staging>) -> gpu::Upload<'s>;
    /// Submits it and waits.
    fn submit(&mut self) -> bool;
    /// RGBA8 rows from the top.
    fn read_texture(&mut self, t: &gpu::Texture, out: &mut [u8]) -> bool;
    fn read_buffer(&mut self, b: &gpu::Buffer, out: &mut [u8]) -> bool;
}

fn bytes(f: &[f32]) -> Vec<u8> {
    f.iter().flat_map(|x| x.to_le_bytes()).collect()
}

pub fn render_to_texture(d: &gpu::Device, h: &mut impl Host) -> Result<bool, gpu::Error> {
    let mut arena = d.create_arena(1 << 20, gpu::MemoryKind::Device, 64)?;
    let mut host = d.create_arena(1 << 16, gpu::MemoryKind::Host, 8)?;
    let mut staging = d.create_staging(&mut host, 1 << 12)?;
    let tex = |w, h, usage| gpu::TextureDescriptor {
        width: w,
        height: h,
        format: gpu::TextureFormat::Rgba8Unorm,
        usage,
        mip_level_count: 1,
        sample_count: 1,
    };
    use gpu::TextureUsages as T;
    let pattern = d.create_texture(&mut arena, &tex(2, 2, T::TEXTURE_BINDING | T::COPY_DST))?;
    let middle = d.create_texture(
        &mut arena,
        &tex(4, 4, T::TEXTURE_BINDING | T::RENDER_ATTACHMENT),
    )?;
    let final_ = d.create_texture(
        &mut arena,
        &tex(
            8,
            8,
            T::TEXTURE_BINDING | T::RENDER_ATTACHMENT | T::COPY_SRC,
        ),
    )?;
    let smp = d.create_sampler(&Default::default())?;
    use gpu::BufferUsages as B;
    let quad = d.create_buffer(
        &mut arena,
        &gpu::BufferDescriptor {
            size: 48,
            usage: B::VERTEX | B::COPY_DST,
        },
    )?;
    let tint = d.create_buffer(
        &mut arena,
        &gpu::BufferDescriptor {
            size: 16,
            usage: B::UNIFORM | B::COPY_DST,
        },
    )?;
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
        blend: None,
        write_mask: 0xf,
    }];
    let pipeline =
        d.create_render_pipeline::<textured::Shader>(&gpu::RenderPipelineDescriptor {
            vertex: gpu::VertexState {
                entry_point: c"vs",
                buffers: &buffers,
            },
            fragment: Some(gpu::FragmentState {
                entry_point: c"fs",
                targets: &targets,
            }),
            topology: gpu::PrimitiveTopology::TriangleList,
            cull_mode: gpu::CullMode::None,
            front_face_ccw: true,
            sample_count: 1,
        })?;
    // textured.wgsl's group 0 as a struct: params, tex, smp.
    let (pv, mv) = (pattern.create_view(), middle.create_view());
    let first = d.create_bind_group(
        &mut arena,
        &pipeline,
        &textured::Group0 {
            params: &tint,
            tex: &pv,
            smp: &smp,
        },
    )?;
    let second = d.create_bind_group(
        &mut arena,
        &pipeline,
        &textured::Group0 {
            params: &tint,
            tex: &mv,
            smp: &smp,
        },
    )?;
    {
        let mut up = h.upload(Some(&mut staging));
        // Red, green / blue, white: rows from the top.
        assert!(up.write_texture(
            &pattern,
            &[
                255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255
            ],
            8
        ));
        up.write_buffer(
            &quad,
            0,
            &bytes(&[0., 0., 1., 0., 0., 1., 1., 0., 1., 1., 0., 1.]),
        );
        up.write_buffer(&tint, 0, &bytes(&[1.; 4]));
        let enc = up.finish();
        for (view, group) in [
            (middle.create_view(), &first),
            (final_.create_view(), &second),
        ] {
            let at = [Some(gpu::RenderPassColorAttachment {
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
            let mut pass = enc.begin_render_pass(&gpu::RenderPassDescriptor {
                color_attachments: &at,
            });
            pass.set_pipeline(&pipeline);
            pass.set_bind_group(0, group, &[]);
            pass.set_vertex_buffer(0, quad.slice(0..));
            pass.draw(0..6, 0..1);
        }
    }
    let mut got = [0u8; 8 * 8 * 4];
    let ok = h.submit() && h.read_texture(&final_, &mut got);
    let expected: [(usize, usize, [u8; 4]); 4] = [
        (1, 1, [255, 0, 0, 255]),
        (6, 1, [0, 255, 0, 255]),
        (1, 6, [0, 0, 255, 255]),
        (6, 6, [255, 255, 255, 255]),
    ];
    let ok = ok
        && expected
            .iter()
            .all(|&(x, y, px)| got[(y * 8 + x) * 4..][..4] == px);
    d.destroy_render_pipeline(&pipeline);
    for t in [&pattern, &middle, &final_] {
        d.destroy_texture(t);
    }
    for b in [&quad, &tint] {
        d.destroy_buffer(b);
    }
    d.destroy_staging(staging);
    d.destroy_sampler(&smp);
    d.destroy_arena(arena);
    d.destroy_arena(host);
    Ok(ok)
}

pub fn compute(d: &gpu::Device, h: &mut impl Host) -> Result<bool, gpu::Error> {
    let mut shared = d.create_arena(1 << 16, gpu::MemoryKind::Host, 8)?;
    use gpu::BufferUsages as B;
    let out = d.create_buffer(
        &mut shared,
        &gpu::BufferDescriptor {
            size: 800,
            usage: B::STORAGE | B::COPY_SRC,
        },
    )?;
    let base = d.create_buffer(
        &mut shared,
        &gpu::BufferDescriptor {
            size: 16,
            usage: B::UNIFORM | B::COPY_DST,
        },
    )?;
    let pipeline = d.create_compute_pipeline::<fill::Shader>(c"main")?;
    let group = d.create_bind_group(
        &mut shared,
        &pipeline,
        &fill::Group0 {
            out: &out,
            base: &base,
        },
    )?;
    {
        let mut up = h.upload(None);
        up.write_buffer(&base, 0, &[7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
        let enc = up.finish();
        let mut pass = enc.begin_compute_pass();
        pass.set_pipeline(&pipeline);
        pass.set_bind_group(0, &group, &[]);
        pass.dispatch_workgroups(4, 1, 1);
    }
    let mut raw = [0u8; 800];
    let ok = h.submit() && h.read_buffer(&out, &mut raw);
    let ok = ok
        && fill::WORKGROUP_SIZE == [64, 1, 1]
        && raw
            .chunks(4)
            .enumerate()
            .all(|(i, x)| u32::from_le_bytes(x.try_into().unwrap()) == i as u32 * 3 + 7);
    d.destroy_compute_pipeline(&pipeline);
    d.destroy_buffer(&out);
    d.destroy_buffer(&base);
    d.destroy_arena(shared);
    Ok(ok)
}
