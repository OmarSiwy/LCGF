// The checks of src/render/gpu/check.zig, written once against lcgf/gpu.hpp and run by every
// back end on a real device (vk_check.cpp, gles_check.cpp, wgpu_check.cpp), over shaders
// lcgf-gen made from the repository's WGSL. As in check.zig, the host supplies
//
//   gpu::Upload Upload(gpu::Staging*)           a command stream begun for one submission
//   bool Submit()                               submit it and wait
//   bool ReadTexture(const gpu::Texture&, std::uint8_t* rgba, std::size_t)   rows from the top
//   bool ReadBuffer(const gpu::Buffer&, void*, std::size_t)
//
// RenderToTexture: a 2 x 2 pattern uploaded through staging, drawn into 4 x 4, sampled into
// 8 x 8 in a second pass; each source texel must come back as a 4 x 4 block. Compute: element i
// of a storage buffer becomes i * 3 + 7.
#pragma once
#include <cstdio>
#include <cstring>
#include <utility>

#include <lcgf/gpu.hpp>

#include "fill.lcgf.hpp"
#include "textured.lcgf.hpp"

namespace checks {
namespace gpu = lcgf::gpu;

#define CHECK_TRY(x)                                                                         \
    do {                                                                                     \
        if (auto r_ = (x); r_ != gpu::kSuccess) {                                            \
            std::fprintf(stderr, "%s:%d: %s: %d\n", __FILE__, __LINE__, #x, int(r_));       \
            return false;                                                                    \
        }                                                                                    \
    } while (0)

template <class Host>
bool RenderToTexture(const gpu::Device& d, Host& h) {
    gpu::Arena arena, host;
    CHECK_TRY(gpu::CreateArena(d, 1 << 20, gpu::MemoryKind::Device, 64, &arena));
    CHECK_TRY(gpu::CreateArena(d, 1 << 16, gpu::MemoryKind::Host, 8, &host));
    gpu::Staging staging;
    CHECK_TRY(gpu::CreateStaging(d, host, 1 << 12, &staging));
    gpu::Texture pattern, middle, final_;
    using U = gpu::TextureUsage;
    CHECK_TRY(gpu::CreateTexture(d, arena, {2, 2, gpu::TextureFormat::RGBA8Unorm, U::TextureBinding | U::CopyDst}, &pattern));
    CHECK_TRY(gpu::CreateTexture(d, arena, {4, 4, gpu::TextureFormat::RGBA8Unorm, U::TextureBinding | U::RenderAttachment}, &middle));
    CHECK_TRY(gpu::CreateTexture(d, arena, {8, 8, gpu::TextureFormat::RGBA8Unorm, U::TextureBinding | U::RenderAttachment | U::CopySrc}, &final_));
    gpu::Sampler smp;
    CHECK_TRY(gpu::CreateSampler(d, {}, &smp));
    gpu::Buffer quad, tint;
    CHECK_TRY(gpu::CreateBuffer(d, arena, {6 * 8, gpu::BufferUsage::Vertex | gpu::BufferUsage::CopyDst}, &quad));
    CHECK_TRY(gpu::CreateBuffer(d, arena, {16, gpu::BufferUsage::Uniform | gpu::BufferUsage::CopyDst}, &tint));
    const gpu::VertexAttribute at{gpu::VertexFormat::Float32x2, 0, 0};
    const gpu::VertexBufferLayout vb{8, gpu::VertexStepMode::Vertex, {&at, 1}};
    const gpu::ColorTargetState target{gpu::TextureFormat::RGBA8Unorm};
    const gpu::FragmentState frag{"fs", {&target, 1}};
    gpu::RenderPipelineOf<textured::Shader> pipeline;
    CHECK_TRY(gpu::CreateRenderPipeline(d, {.vertex = {"vs", {&vb, 1}}, .fragment = &frag}, &pipeline));
    // textured.wgsl's group 0 as a struct: params, tex, smp.
    gpu::BindGroup<0> first, second;
    CHECK_TRY(gpu::CreateBindGroup(d, arena, pipeline, textured::Group0{tint, pattern.CreateView(), smp}, &first));
    CHECK_TRY(gpu::CreateBindGroup(d, arena, pipeline, textured::Group0{tint, middle.CreateView(), smp}, &second));

    gpu::Upload up = h.Upload(&staging);
    // Red, green / blue, white: rows from the top.
    const std::uint8_t px[16] = {255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255};
    if (!up.WriteTexture(pattern, px, sizeof px, 8)) return false;
    const float corners[12] = {0, 0, 1, 0, 0, 1, 1, 0, 1, 1, 0, 1};
    up.WriteBuffer(quad, 0, corners, sizeof corners);
    const float white[4] = {1, 1, 1, 1};
    up.WriteBuffer(tint, 0, white, sizeof white);
    {
        const gpu::CommandEncoder enc = std::move(up).Finish();
        for (const auto& [view, group] : {std::pair{middle.CreateView(), &first}, std::pair{final_.CreateView(), &second}}) {
            const gpu::RenderPassColorAttachment color{.view = view, .clearValue = {.a = 1}};
            gpu::RenderPassEncoder pass = enc.BeginRenderPass({{&color, 1}});
            pass.SetPipeline(pipeline);
            pass.SetBindGroup(0, *group);
            pass.SetVertexBuffer(0, quad);
            pass.Draw(6);
            pass.End();
        }
    }
    if (!h.Submit()) return false;
    std::uint8_t got[8 * 8 * 4];
    if (!h.ReadTexture(final_, got, sizeof got)) return false;
    const struct {
        int x, y;
        std::uint8_t px[4];
    } expected[] = {{1, 1, {255, 0, 0, 255}}, {6, 1, {0, 255, 0, 255}}, {1, 6, {0, 0, 255, 255}}, {6, 6, {255, 255, 255, 255}}};
    bool ok = true;
    for (const auto& e : expected) ok = ok && std::memcmp(got + (e.y * 8 + e.x) * 4, e.px, 4) == 0;
    gpu::DestroyPipeline(d, pipeline);
    for (const gpu::Texture* t : {&pattern, &middle, &final_}) gpu::DestroyTexture(d, *t);
    for (const gpu::Buffer* b : {&quad, &tint}) gpu::DestroyBuffer(d, *b);
    if (staging.buffer.handle) gpu::DestroyBuffer(d, staging.buffer);
    gpu::DestroySampler(d, smp);
    gpu::DestroyArena(d, arena);
    gpu::DestroyArena(d, host);
    return ok;
}

template <class Host>
bool Compute(const gpu::Device& d, Host& h) {
    gpu::Arena shared;
    CHECK_TRY(gpu::CreateArena(d, 1 << 16, gpu::MemoryKind::Host, 8, &shared));
    gpu::Buffer out, base;
    CHECK_TRY(gpu::CreateBuffer(d, shared, {200 * 4, gpu::BufferUsage::Storage | gpu::BufferUsage::CopySrc}, &out));
    CHECK_TRY(gpu::CreateBuffer(d, shared, {16, gpu::BufferUsage::Uniform | gpu::BufferUsage::CopyDst}, &base));
    gpu::ComputePipelineOf<fill::Shader> pipeline;
    CHECK_TRY(gpu::CreateComputePipeline(d, {"main"}, &pipeline));
    gpu::BindGroup<0> group;
    CHECK_TRY(gpu::CreateBindGroup(d, shared, pipeline, fill::Group0{out, base}, &group));
    gpu::Upload up = h.Upload(nullptr);
    const std::uint32_t seven[4] = {7, 0, 0, 0};
    up.WriteBuffer(base, 0, seven, sizeof seven);
    {
        gpu::ComputePassEncoder pass = std::move(up).Finish().BeginComputePass();
        pass.SetPipeline(pipeline);
        pass.SetBindGroup(0, group);
        pass.DispatchWorkgroups(4);
        pass.End();
    }
    if (!h.Submit()) return false;
    std::uint32_t v[200];
    if (!h.ReadBuffer(out, v, sizeof v)) return false;
    bool ok = fill::Shader::workgroup_size[0] == 64;
    for (std::uint32_t i = 0; i < 200; ++i) ok = ok && v[i] == i * 3 + 7;
    gpu::DestroyPipeline(d, pipeline);
    gpu::DestroyBuffer(d, out);
    gpu::DestroyBuffer(d, base);
    gpu::DestroyArena(d, shared);
    return ok;
}

} // namespace checks
