//! `lcgf::gpu` on a real Vulkan device: check.zig's checks (gpu_checks.rs) over shaders
//! `include_shader!` made from the repository's WGSL and naga's SPIR-V.
//!
//!   lcgf-vk-check        (prints "skip" and exits 0 when there is no Vulkan 1.3 device)

use lcgf::gpu::{self, vk};

mod gpu_checks;

struct Vk {
    _entry: ash::Entry,
    instance: ash::Instance,
    physical: vk::PhysicalDevice,
    device: ash::Device,
    queue: vk::Queue,
    pool: vk::CommandPool,
}

fn setup() -> Option<Vk> {
    let entry = unsafe { ash::Entry::load() }.ok()?;
    let app = vk::ApplicationInfo {
        api_version: vk::API_VERSION_1_3,
        ..Default::default()
    };
    let instance = unsafe {
        entry.create_instance(
            &vk::InstanceCreateInfo {
                p_application_info: &app,
                ..Default::default()
            },
            None,
        )
    }
    .ok()?;
    let physical = *unsafe { instance.enumerate_physical_devices() }
        .ok()?
        .first()?;
    let family = unsafe { instance.get_physical_device_queue_family_properties(physical) }
        .iter()
        .position(|q| q.queue_flags.contains(vk::QueueFlags::GRAPHICS))? as u32;
    let priority = [1.0f32];
    let qi = [vk::DeviceQueueCreateInfo::default()
        .queue_family_index(family)
        .queue_priorities(&priority)];
    let mut f13 = vk::PhysicalDeviceVulkan13Features::default()
        .dynamic_rendering(true)
        .synchronization2(true);
    let di = vk::DeviceCreateInfo::default()
        .queue_create_infos(&qi)
        .push_next(&mut f13);
    let device = unsafe { instance.create_device(physical, &di, None) }.ok()?;
    let queue = unsafe { device.get_device_queue(family, 0) };
    let pool = unsafe {
        device.create_command_pool(
            &vk::CommandPoolCreateInfo::default().queue_family_index(family),
            None,
        )
    }
    .ok()?;
    Some(Vk {
        _entry: entry,
        instance,
        physical,
        device,
        queue,
        pool,
    })
}

impl Vk {
    fn begin(&self) -> vk::CommandBuffer {
        let ai = vk::CommandBufferAllocateInfo::default()
            .command_pool(self.pool)
            .level(vk::CommandBufferLevel::PRIMARY)
            .command_buffer_count(1);
        let cmd = unsafe { self.device.allocate_command_buffers(&ai) }.unwrap()[0];
        unsafe {
            self.device.begin_command_buffer(
                cmd,
                &vk::CommandBufferBeginInfo::default()
                    .flags(vk::CommandBufferUsageFlags::ONE_TIME_SUBMIT),
            )
        }
        .unwrap();
        cmd
    }
    fn submit(&self, cmd: vk::CommandBuffer) {
        unsafe {
            self.device.end_command_buffer(cmd).unwrap();
            let cmds = [cmd];
            self.device
                .queue_submit(
                    self.queue,
                    &[vk::SubmitInfo::default().command_buffers(&cmds)],
                    vk::Fence::null(),
                )
                .unwrap();
            self.device.queue_wait_idle(self.queue).unwrap();
        }
    }
}

/// check.zig's host on Vulkan: one command buffer per submission, readback through a host buffer.
struct VkHost<'a> {
    v: &'a Vk,
    d: gpu::Device<'a>,
    cmd: vk::CommandBuffer,
}

impl gpu_checks::Host for VkHost<'_> {
    fn upload<'s>(&'s mut self, staging: Option<&'s mut gpu::Staging>) -> gpu::Upload<'s> {
        self.cmd = self.v.begin();
        match staging {
            Some(s) => gpu::Upload::with_staging(&self.d, self.cmd, s),
            None => gpu::Upload::new(&self.d, self.cmd),
        }
    }
    fn submit(&mut self) -> bool {
        self.v.submit(self.cmd);
        true
    }
    fn read_texture(&mut self, t: &gpu::Texture, out: &mut [u8]) -> bool {
        let Ok(mut host) = self.d.create_arena(1 << 16, gpu::MemoryKind::Host, 1) else {
            return false;
        };
        let Ok(b) = self.d.create_buffer(
            &mut host,
            &gpu::BufferDescriptor {
                size: out.len() as u64,
                usage: gpu::BufferUsages::COPY_DST,
            },
        ) else {
            return false;
        };
        let cmd = self.v.begin();
        unsafe {
            let bar = [vk::ImageMemoryBarrier2::default()
                .image(t.image)
                .old_layout(t.resting)
                .new_layout(vk::ImageLayout::TRANSFER_SRC_OPTIMAL)
                .src_stage_mask(vk::PipelineStageFlags2::ALL_COMMANDS)
                .src_access_mask(vk::AccessFlags2::MEMORY_WRITE)
                .dst_stage_mask(vk::PipelineStageFlags2::COPY)
                .dst_access_mask(vk::AccessFlags2::TRANSFER_READ)
                .src_queue_family_index(vk::QUEUE_FAMILY_IGNORED)
                .dst_queue_family_index(vk::QUEUE_FAMILY_IGNORED)
                .subresource_range(vk::ImageSubresourceRange {
                    aspect_mask: vk::ImageAspectFlags::COLOR,
                    base_mip_level: 0,
                    level_count: 1,
                    base_array_layer: 0,
                    layer_count: 1,
                })];
            self.v.device.cmd_pipeline_barrier2(
                cmd,
                &vk::DependencyInfo::default().image_memory_barriers(&bar),
            );
            let copy = vk::BufferImageCopy {
                image_subresource: vk::ImageSubresourceLayers {
                    aspect_mask: vk::ImageAspectFlags::COLOR,
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
            self.v.device.cmd_copy_image_to_buffer(
                cmd,
                t.image,
                vk::ImageLayout::TRANSFER_SRC_OPTIMAL,
                b.handle,
                &[copy],
            );
        }
        self.v.submit(cmd);
        out.copy_from_slice(unsafe { std::slice::from_raw_parts(b.mapped, out.len()) });
        self.d.destroy_buffer(&b);
        self.d.destroy_arena(host);
        true
    }
    fn read_buffer(&mut self, b: &gpu::Buffer, out: &mut [u8]) -> bool {
        if b.mapped.is_null() {
            return false;
        }
        out.copy_from_slice(unsafe { std::slice::from_raw_parts(b.mapped, out.len()) });
        true
    }
}

fn main() {
    let Some(v) = setup() else {
        println!("skip: no Vulkan 1.3 device");
        return;
    };
    let fns = unsafe {
        gpu::DeviceFns::load(v.instance.fp_v1_0().get_device_proc_addr, v.device.handle())
    };
    let memory = unsafe { v.instance.get_physical_device_memory_properties(v.physical) };
    let d = gpu::Device {
        handle: v.device.handle(),
        fns: &fns,
        memory,
    };
    let mut h = VkHost {
        v: &v,
        d,
        cmd: vk::CommandBuffer::null(),
    };
    let rtt = gpu_checks::render_to_texture(&d, &mut h).unwrap();
    let cs = gpu_checks::compute(&d, &mut h).unwrap();
    println!(
        "{} render-to-texture, {} compute (Rust lcgf::gpu on a real device)",
        if rtt { "ok  " } else { "FAIL" },
        if cs { "ok  " } else { "FAIL" }
    );
    std::process::exit(if rtt && cs { 0 } else { 1 });
}
