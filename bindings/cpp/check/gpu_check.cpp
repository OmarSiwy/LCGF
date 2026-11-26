// The C++ side of the bindings' GPU gate: bindings/check/gpu_dump.zig's frame, recorded through
// lcgf/gpu.hpp. run.sh requires the log to equal Zig's.
//
//   lcgf-cpp-gpu-check <out.txt>
#include <cstdint>
#include <fstream>
#include <utility>

#include <lcgf/gpu.hpp>

extern "C" PFN_vkVoidFunction lcgf_record_get_device_proc_addr(VkDevice, const char*);
extern "C" const char* lcgf_record_log(std::size_t* len);

template <class T>
static T h(std::uintptr_t v) {
    return reinterpret_cast<T>(v);
}

int main(int argc, char** argv) {
    if (argc != 2) return 2;
    namespace gpu = lcgf::gpu;
    const gpu::DeviceFns fns = gpu::DeviceFns::Load(lcgf_record_get_device_proc_addr, nullptr);
    const gpu::Device device{nullptr, &fns};
    const auto cmd = h<VkCommandBuffer>(0xc0);

    const gpu::RenderPipeline pipeline{h<VkPipeline>(0x4000), h<VkPipelineLayout>(0x4001), {}};
    const gpu::BindGroup<0> group{h<VkDescriptorSet>(0x5000), h<VkPipelineLayout>(0x4001)};
    const gpu::ComputePipeline kpipe{h<VkPipeline>(0x4100), h<VkPipelineLayout>(0x4101), {}};
    const gpu::BindGroup<0> kgroup{h<VkDescriptorSet>(0x5100), h<VkPipelineLayout>(0x4101)};
    const gpu::Buffer buffer{h<VkBuffer>(0x2000), 64};
    const gpu::Texture texture{h<VkImage>(0x3000), h<VkImageView>(0x3001), gpu::TextureFormat::RGBA8Unorm, 64, 32};

    gpu::Upload up(device, cmd);
    const float data[4] = {1, 2, 3, 4};
    up.WriteBuffer(buffer, 0, data, sizeof data);
    const gpu::CommandEncoder enc = std::move(up).Finish();

    const gpu::RenderPassColorAttachment color{.view = texture.CreateView(), .clearValue = {.a = 1}};
    gpu::RenderPassEncoder pass = enc.BeginRenderPass({.colorAttachments = {&color, 1}});
    pass.SetPipeline(pipeline);
    pass.SetBindGroup(0, group);
    pass.SetVertexBuffer(0, buffer, 16);
    pass.SetIndexBuffer(buffer, gpu::IndexFormat::Uint16, 32);
    pass.SetViewport(0, 0, 64, 32, 0, 1);
    pass.SetScissorRect(8, 8, 16, 16);
    pass.SetBlendConstant({0.5, 0.25, 0, 1});
    pass.Draw(6);
    pass.DrawIndexed(6, 2);
    pass.End();

    gpu::RenderPassEncoder ui = gpu::RenderPassEncoder::Wrap(device, cmd, 800, 600);
    ui.SetPipeline(pipeline);
    ui.SetBindGroup(0, group);
    ui.SetScissorRect(10, 20, 30, 40);
    ui.Draw(3);
    ui.End();

    gpu::ComputePassEncoder compute = enc.BeginComputePass();
    compute.SetPipeline(kpipe);
    compute.SetBindGroup(0, kgroup);
    compute.DispatchWorkgroups(4);
    compute.End();

    std::size_t len = 0;
    const char* log = lcgf_record_log(&len);
    std::ofstream(argv[1], std::ios::binary).write(log, static_cast<std::streamsize>(len));
    return 0;
}
