// The C++ side of the bindings' D3D12 gate: bindings/check/d3d12_dump.zig's resources, pipelines
// and frame, made through lcgf/gpu.hpp with LCGF_GPU_D3D12 on the recording device and command
// list of d3d12_record.c. run.sh requires the log to equal Zig's.
//
//   lcgf-cpp-d3d12-check <out.txt>
#include <cstdio>
#include <fstream>
#include <utility>

#include <lcgf/gpu.hpp>

#include "fill.lcgf.hpp"
#include "textured.lcgf.hpp"

extern "C" void* lcgf_d3d12_record_device();
extern "C" void* lcgf_d3d12_record_list();
extern "C" const char* lcgf_d3d12_record_log(std::size_t* len);

#define TRY(x)                                                                    \
    do {                                                                          \
        if ((x) != gpu::kSuccess) {                                               \
            std::fprintf(stderr, "%s:%d: %s failed\n", __FILE__, __LINE__, #x); \
            return 1;                                                             \
        }                                                                         \
    } while (0)

int main(int argc, char** argv) {
    if (argc != 2) return 2;
    namespace gpu = lcgf::gpu;
    gpu::Device d = gpu::Device::Wrap(static_cast<ID3D12Device*>(lcgf_d3d12_record_device()));
    const auto list = static_cast<ID3D12GraphicsCommandList*>(lcgf_d3d12_record_list());

    gpu::Arena arena, host;
    TRY(gpu::CreateArena(d, 1 << 20, gpu::MemoryKind::Device, 64, &arena));
    TRY(gpu::CreateArena(d, 1 << 16, gpu::MemoryKind::Host, 8, &host));
    gpu::Staging staging;
    TRY(gpu::CreateStaging(d, host, 4096, &staging));
    d.staging = &staging;
    using BU = gpu::BufferUsage;
    gpu::Buffer buffer, storage, base;
    TRY(gpu::CreateBuffer(d, arena, {64, BU::Vertex | BU::Index | BU::Uniform | BU::CopyDst}, &buffer));
    TRY(gpu::CreateBuffer(d, arena, {256, BU::Storage | BU::CopySrc}, &storage));
    TRY(gpu::CreateBuffer(d, arena, {16, BU::Uniform | BU::CopyDst}, &base));
    gpu::Texture texture;
    TRY(gpu::CreateTexture(d, arena, {64, 32, gpu::TextureFormat::RGBA8Unorm, gpu::TextureUsage::TextureBinding | gpu::TextureUsage::RenderAttachment},
                           &texture));
    gpu::Sampler sampler;
    TRY(gpu::CreateSampler(d, {.addressModeU = gpu::AddressMode::Repeat, .magFilter = gpu::FilterMode::Linear, .minFilter = gpu::FilterMode::Linear},
                           &sampler));

    const gpu::VertexAttribute at{gpu::VertexFormat::Float32x2, 0, 0};
    const gpu::VertexBufferLayout vb{8, gpu::VertexStepMode::Vertex, {&at, 1}};
    const gpu::ColorTargetState target{gpu::TextureFormat::RGBA8Unorm, &gpu::kPremultipliedBlend};
    const gpu::FragmentState frag{"fs", {&target, 1}};
    gpu::RenderPipelineOf<textured::Shader> pipeline;
    TRY(gpu::CreateRenderPipeline(d, {.vertex = {"vs", {&vb, 1}}, .fragment = &frag, .primitive = {.cullMode = gpu::CullMode::Back}}, &pipeline));
    gpu::ComputePipelineOf<fill::Shader> kpipe;
    TRY(gpu::CreateComputePipeline(d, {"main"}, &kpipe));
    gpu::BindGroup<0> group, kgroup;
    const gpu::TextureView view = texture.CreateView();
    TRY(gpu::CreateBindGroup(d, arena, pipeline, textured::Group0{buffer, view, sampler}, &group));
    TRY(gpu::CreateBindGroup(d, arena, kpipe, fill::Group0{storage, base}, &kgroup));

    gpu::Upload up(d, list);
    const float data[4] = {1, 2, 3, 4};
    up.WriteBuffer(buffer, 0, data, sizeof data);
    const gpu::CommandEncoder enc = std::move(up).Finish();

    const gpu::RenderPassColorAttachment color{.view = view, .clearValue = {.a = 1}};
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

    gpu::RenderPassEncoder ui = gpu::RenderPassEncoder::Wrap(d, list, 800, 600);
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

    gpu::DestroyPipeline(d, kpipe);
    gpu::DestroyPipeline(d, pipeline);
    gpu::DestroySampler(d, sampler);
    gpu::DestroyTexture(d, texture);
    for (const gpu::Buffer* b : {&base, &storage, &buffer, &staging.buffer}) gpu::DestroyBuffer(d, *b);
    gpu::DestroyArena(d, host);
    gpu::DestroyArena(d, arena);

    std::size_t len = 0;
    const char* log = lcgf_d3d12_record_log(&len);
    std::ofstream(argv[1], std::ios::binary).write(log, static_cast<std::streamsize>(len));
    return 0;
}
