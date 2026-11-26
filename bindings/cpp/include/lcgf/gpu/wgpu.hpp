// lcgf/gpu/wgpu.hpp: lcgf_render.gpu for C++ on wgpu-native, through its webgpu.h. Included by
// lcgf/gpu.hpp when LCGF_GPU_WGPU is defined.
//
// src/render/wgpu/gpu.zig, inline: the projection is the identity. A type is the webgpu.h
// handle it names (`pass.Get()` is the WGPURenderPassEncoder), a call is one wgpu* call. The
// WGSL goes to wgpu as written; bind group layouts are the pipeline's own (layout = null,
// WebGPU's "auto"), which is why CreateBindGroup takes the pipeline. The phases are WebGPU's:
// Upload writes through the queue, ordered before the commands submitted after it.
//
// It gives the shape the native back ends have, so code written against lcgf/gpu.hpp runs on
// real WebGPU unchanged. wgpu-native validates every call, in every build: the cost the native
// projections avoid. `zig build abi -Dwgpu-native=v29` installs the headers and the library.
#pragma once
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <span>
#include <string_view>
#include <type_traits>
#include <utility>

#include <webgpu/webgpu.h>
#include <webgpu/wgpu.h>

#include "types.hpp"

namespace lcgf::gpu {

/// What creation reports. `kSuccess` is the one every back end has.
enum class Result : std::uint32_t { Success, PipelineFailed, MapFailed, NoCode };
inline constexpr Result kSuccess = Result::Success;

/// The host's device and queue; the instance runs map callbacks for ReadBuffer.
struct Device {
    WGPUDevice device;
    WGPUQueue queue;
    WGPUInstance instance = nullptr;
};

struct Buffer {
    WGPUBuffer handle;
    std::uint64_t size;
    /// Always null on WebGPU: read results back with ReadBuffer.
    std::byte* mapped = nullptr;
};

struct TextureView {
    WGPUTextureView view;
    WGPUTexture texture = nullptr;
    std::uint32_t width, height, samples = 1;
    TextureFormat format = TextureFormat::RGBA8Unorm;
};

struct Texture {
    WGPUTexture texture;
    /// The default view, made with the texture.
    WGPUTextureView view;
    TextureFormat format;
    std::uint32_t width, height, samples = 1;
    TextureView CreateView() const { return {view, texture, width, height, samples, format}; }
};

struct Sampler {
    WGPUSampler handle;
};

struct RenderPipeline {
    WGPURenderPipeline pipeline;
};
struct ComputePipeline {
    WGPUComputePipeline pipeline;
};
template <class S>
struct RenderPipelineOf : RenderPipeline {
    using Shader = S;
};
template <class S>
struct ComputePipelineOf : ComputePipeline {
    using Shader = S;
};

template <std::uint32_t G>
struct BindGroup {
    WGPUBindGroup group;
    static constexpr std::uint32_t index = G;
};

/// One resource of a bind group, as a generated `GroupN::Resources()` lists them.
struct Resource {
    std::uint32_t binding;
    BindingKind kind;
    WGPUBuffer buffer = nullptr;
    WGPUTextureView view = nullptr;
    WGPUSampler sampler = nullptr;
};
inline Resource BufferResource(std::uint32_t binding, BindingKind kind, const Buffer& b) { return {binding, kind, b.handle}; }
inline Resource ViewResource(std::uint32_t binding, BindingKind kind, const TextureView& v) { return {binding, kind, nullptr, v.view}; }
inline Resource SamplerResource(std::uint32_t binding, BindingKind kind, const Sampler& s) { return {binding, kind, nullptr, nullptr, s.handle}; }

/// WebGPU allocates its own memory: an arena is only the projection's uniform interface.
struct Arena {};
inline Result CreateArena(const Device&, std::uint64_t, MemoryKind, std::uint32_t, Arena*) { return kSuccess; }
inline void DestroyArena(const Device&, Arena&) {}
/// WebGPU stages writes itself; staging exists for the uniform interface.
struct Staging {
    Buffer buffer{nullptr, 0};
    void Rewind() {}
};
inline Result CreateStaging(const Device&, Arena&, std::uint64_t, Staging*) { return kSuccess; }

struct RenderPassColorAttachment {
    TextureView view;
    const TextureView* resolveTarget = nullptr;
    LoadOp loadOp = LoadOp::Clear;
    StoreOp storeOp = StoreOp::Store;
    Color clearValue{};
};
struct RenderPassDescriptor {
    std::span<const RenderPassColorAttachment> colorAttachments;
};

namespace detail {
inline WGPUStringView sv(const char* s) { return {s, WGPU_STRLEN}; }
inline WGPUTextureFormat format(TextureFormat f) {
    constexpr WGPUTextureFormat t[] = {
        WGPUTextureFormat_R8Unorm,     WGPUTextureFormat_RG8Unorm,       WGPUTextureFormat_RGBA8Unorm,  WGPUTextureFormat_RGBA8UnormSrgb,
        WGPUTextureFormat_BGRA8Unorm,  WGPUTextureFormat_BGRA8UnormSrgb, WGPUTextureFormat_R16Float,    WGPUTextureFormat_RGBA16Float,
        WGPUTextureFormat_R32Float,    WGPUTextureFormat_RG32Float,      WGPUTextureFormat_RGBA32Float, WGPUTextureFormat_R32Uint,
        WGPUTextureFormat_Depth32Float,
    };
    return t[std::uint32_t(f)];
}
inline WGPUBufferUsage bufferUsage(BufferUsage u) {
    // Our bits are WebGPU's, from MapRead (1) to Indirect (256).
    return WGPUBufferUsage(std::uint32_t(u));
}
inline WGPUTextureUsage textureUsage(TextureUsage u) {
    // Our bits are WebGPU's, from CopySrc (1) to RenderAttachment (16).
    return WGPUTextureUsage(std::uint32_t(u));
}
inline WGPUVertexFormat vertexFormat(VertexFormat f) {
    constexpr WGPUVertexFormat t[] = {WGPUVertexFormat_Float32, WGPUVertexFormat_Float32x2, WGPUVertexFormat_Float32x3,
                                      WGPUVertexFormat_Float32x4, WGPUVertexFormat_Uint32, WGPUVertexFormat_Uint32x2,
                                      WGPUVertexFormat_Uint32x4, WGPUVertexFormat_Sint32, WGPUVertexFormat_Unorm8x4};
    return t[std::uint32_t(f)];
}
inline WGPUBlendComponent blend(const BlendComponent& b) {
    constexpr WGPUBlendFactor f[] = {WGPUBlendFactor_Zero, WGPUBlendFactor_One, WGPUBlendFactor_Src, WGPUBlendFactor_OneMinusSrc,
                                     WGPUBlendFactor_SrcAlpha, WGPUBlendFactor_OneMinusSrcAlpha, WGPUBlendFactor_Dst,
                                     WGPUBlendFactor_OneMinusDst, WGPUBlendFactor_DstAlpha, WGPUBlendFactor_OneMinusDstAlpha,
                                     WGPUBlendFactor_Constant, WGPUBlendFactor_OneMinusConstant};
    constexpr WGPUBlendOperation o[] = {WGPUBlendOperation_Add, WGPUBlendOperation_Subtract, WGPUBlendOperation_ReverseSubtract,
                                        WGPUBlendOperation_Min, WGPUBlendOperation_Max};
    return {o[std::uint32_t(b.operation)], f[std::uint32_t(b.srcFactor)], f[std::uint32_t(b.dstFactor)]};
}
inline WGPUAddressMode address(AddressMode a) {
    constexpr WGPUAddressMode t[] = {WGPUAddressMode_ClampToEdge, WGPUAddressMode_Repeat, WGPUAddressMode_MirrorRepeat};
    return t[std::uint32_t(a)];
}
inline WGPUShaderModule module(WGPUDevice d, std::string_view wgsl) {
    WGPUShaderSourceWGSL source{};
    source.chain.sType = WGPUSType_ShaderSourceWGSL;
    source.code = {wgsl.data(), wgsl.size()};
    WGPUShaderModuleDescriptor desc{};
    desc.nextInChain = &source.chain;
    return wgpuDeviceCreateShaderModule(d, &desc);
}
} // namespace detail

// ---- the frame ------------------------------------------------------------------------------

class RenderPassEncoder {
public:
    /// The pass the host is recording (the UI's, for an inline custom draw). `End` leaves it.
    static RenderPassEncoder Wrap(const Device&, WGPURenderPassEncoder pass, std::uint32_t width, std::uint32_t height) {
        return RenderPassEncoder(pass, width, height, false);
    }
    void SetPipeline(const RenderPipeline& p) { wgpuRenderPassEncoderSetPipeline(pass_, p.pipeline); }
    template <std::uint32_t G>
    void SetBindGroup(std::uint32_t index, const BindGroup<G>& group) {
        assert(index == G && "bind group made for another @group");
        wgpuRenderPassEncoderSetBindGroup(pass_, index, group.group, 0, nullptr);
    }
    void SetVertexBuffer(std::uint32_t slot, const Buffer& buffer, std::uint64_t offset = 0) {
        wgpuRenderPassEncoderSetVertexBuffer(pass_, slot, buffer.handle, offset, WGPU_WHOLE_SIZE);
    }
    void SetIndexBuffer(const Buffer& buffer, IndexFormat format, std::uint64_t offset = 0) {
        wgpuRenderPassEncoderSetIndexBuffer(pass_, buffer.handle, format == IndexFormat::Uint16 ? WGPUIndexFormat_Uint16 : WGPUIndexFormat_Uint32, offset,
                                            WGPU_WHOLE_SIZE);
    }
    void SetViewport(float x, float y, float w, float h, float minDepth, float maxDepth) {
        wgpuRenderPassEncoderSetViewport(pass_, x, y, w, h, minDepth, maxDepth);
    }
    void SetScissorRect(std::uint32_t x, std::uint32_t y, std::uint32_t w, std::uint32_t h) { wgpuRenderPassEncoderSetScissorRect(pass_, x, y, w, h); }
    void SetBlendConstant(const Color& c) {
        const WGPUColor k{c.r, c.g, c.b, c.a};
        wgpuRenderPassEncoderSetBlendConstant(pass_, &k);
    }
    void Draw(std::uint32_t vertexCount, std::uint32_t instanceCount = 1, std::uint32_t firstVertex = 0, std::uint32_t firstInstance = 0) {
        wgpuRenderPassEncoderDraw(pass_, vertexCount, instanceCount, firstVertex, firstInstance);
    }
    void DrawIndexed(std::uint32_t indexCount, std::uint32_t instanceCount = 1, std::uint32_t firstIndex = 0, std::int32_t baseVertex = 0,
                     std::uint32_t firstInstance = 0) {
        wgpuRenderPassEncoderDrawIndexed(pass_, indexCount, instanceCount, firstIndex, baseVertex, firstInstance);
    }
    /// Ends and releases a pass the projection began. A wrapped pass is the host's.
    void End() {
        if (!owned_) return;
        wgpuRenderPassEncoderEnd(pass_);
        wgpuRenderPassEncoderRelease(pass_);
        owned_ = false;
    }
    WGPURenderPassEncoder Get() const { return pass_; }

private:
    friend class CommandEncoder;
    RenderPassEncoder(WGPURenderPassEncoder pass, std::uint32_t w, std::uint32_t h, bool owned) : pass_(pass), width_(w), height_(h), owned_(owned) {}
    WGPURenderPassEncoder pass_;
    std::uint32_t width_, height_;
    bool owned_;
};

class ComputePassEncoder {
public:
    void SetPipeline(const ComputePipeline& p) { wgpuComputePassEncoderSetPipeline(pass_, p.pipeline); }
    template <std::uint32_t G>
    void SetBindGroup(std::uint32_t index, const BindGroup<G>& group) {
        assert(index == G && "bind group made for another @group");
        wgpuComputePassEncoderSetBindGroup(pass_, index, group.group, 0, nullptr);
    }
    void DispatchWorkgroups(std::uint32_t x, std::uint32_t y = 1, std::uint32_t z = 1) { wgpuComputePassEncoderDispatchWorkgroups(pass_, x, y, z); }
    void End() {
        wgpuComputePassEncoderEnd(pass_);
        wgpuComputePassEncoderRelease(pass_);
    }
    WGPUComputePassEncoder Get() const { return pass_; }

private:
    friend class CommandEncoder;
    explicit ComputePassEncoder(WGPUComputePassEncoder pass) : pass_(pass) {}
    WGPUComputePassEncoder pass_;
};

/// The draw phase of a frame: the host's command encoder. Made by `Upload::Finish`.
class CommandEncoder {
public:
    RenderPassEncoder BeginRenderPass(const RenderPassDescriptor& d) const {
        WGPURenderPassColorAttachment as[kMaxColorTargets]{};
        std::uint32_t w = 0, h = 0, n = 0;
        for (const RenderPassColorAttachment& a : d.colorAttachments) {
            WGPURenderPassColorAttachment& x = as[n++];
            x.view = a.view.view;
            x.depthSlice = WGPU_DEPTH_SLICE_UNDEFINED;
            x.resolveTarget = a.resolveTarget ? a.resolveTarget->view : nullptr;
            x.loadOp = a.loadOp == LoadOp::Clear ? WGPULoadOp_Clear : WGPULoadOp_Load;
            x.storeOp = a.storeOp == StoreOp::Store ? WGPUStoreOp_Store : WGPUStoreOp_Discard;
            x.clearValue = {a.clearValue.r, a.clearValue.g, a.clearValue.b, a.clearValue.a};
            w = a.view.width, h = a.view.height;
        }
        WGPURenderPassDescriptor rp{};
        rp.colorAttachmentCount = n;
        rp.colorAttachments = as;
        return RenderPassEncoder(wgpuCommandEncoderBeginRenderPass(encoder_, &rp), w, h, true);
    }
    ComputePassEncoder BeginComputePass() const { return ComputePassEncoder(wgpuCommandEncoderBeginComputePass(encoder_, nullptr)); }
    WGPUCommandEncoder Get() const { return encoder_; }

private:
    friend class Upload;
    explicit CommandEncoder(WGPUCommandEncoder e) : encoder_(e) {}
    WGPUCommandEncoder encoder_;
};

/// The write phase: WebGPU's queue writes, ordered before the commands submitted after them.
class Upload {
public:
    Upload(const Device& d, WGPUCommandEncoder encoder, Staging* = nullptr) : queue_(d.queue), encoder_(encoder) {}
    void WriteBuffer(const Buffer& buffer, std::uint64_t offset, const void* data, std::size_t size) {
        wgpuQueueWriteBuffer(queue_, buffer.handle, offset, data, size);
    }
    bool WriteTexture(const Texture& t, const void* data, std::size_t size, std::uint32_t bytesPerRow) {
        WGPUTexelCopyTextureInfo dst{};
        dst.texture = t.texture;
        dst.aspect = WGPUTextureAspect_All;
        WGPUTexelCopyBufferLayout layout{};
        layout.bytesPerRow = bytesPerRow;
        layout.rowsPerImage = t.height;
        const WGPUExtent3D extent{t.width, t.height, 1};
        wgpuQueueWriteTexture(queue_, &dst, data, size, &layout, &extent);
        return true;
    }
    void Prepare(const Texture&) {}
    CommandEncoder Finish() && { return CommandEncoder(encoder_); }
    WGPUCommandEncoder Get() const { return encoder_; }

private:
    WGPUQueue queue_;
    WGPUCommandEncoder encoder_;
};

// ---- creation ---------------------------------------------------------------------------------

inline Result CreateBuffer(const Device& d, Arena&, const BufferDescriptor& desc, Buffer* out) {
    WGPUBufferDescriptor bd{};
    bd.usage = detail::bufferUsage(desc.usage);
    bd.size = desc.size;
    *out = {wgpuDeviceCreateBuffer(d.device, &bd), desc.size};
    return kSuccess;
}
inline void DestroyBuffer(const Device&, const Buffer& b) { wgpuBufferRelease(b.handle); }

inline Result CreateTexture(const Device& d, Arena&, const TextureDescriptor& desc, Texture* out) {
    WGPUTextureDescriptor td{};
    td.usage = detail::textureUsage(desc.usage);
    td.dimension = WGPUTextureDimension_2D;
    td.size = {desc.width, desc.height, 1};
    td.format = detail::format(desc.format);
    td.mipLevelCount = desc.mipLevelCount;
    td.sampleCount = desc.sampleCount;
    const WGPUTexture t = wgpuDeviceCreateTexture(d.device, &td);
    *out = {t, wgpuTextureCreateView(t, nullptr), desc.format, desc.width, desc.height, desc.sampleCount};
    return kSuccess;
}
inline void DestroyTexture(const Device&, const Texture& t) {
    wgpuTextureViewRelease(t.view);
    wgpuTextureRelease(t.texture);
}

inline Result CreateSampler(const Device& d, const SamplerDescriptor& desc, Sampler* out) {
    WGPUSamplerDescriptor sd{};
    sd.addressModeU = detail::address(desc.addressModeU);
    sd.addressModeV = detail::address(desc.addressModeV);
    sd.addressModeW = detail::address(desc.addressModeW);
    sd.magFilter = desc.magFilter == FilterMode::Linear ? WGPUFilterMode_Linear : WGPUFilterMode_Nearest;
    sd.minFilter = desc.minFilter == FilterMode::Linear ? WGPUFilterMode_Linear : WGPUFilterMode_Nearest;
    sd.mipmapFilter = desc.mipmapFilter == FilterMode::Linear ? WGPUMipmapFilterMode_Linear : WGPUMipmapFilterMode_Nearest;
    sd.lodMinClamp = desc.lodMinClamp;
    sd.lodMaxClamp = desc.lodMaxClamp;
    sd.maxAnisotropy = 1;
    out->handle = wgpuDeviceCreateSampler(d.device, &sd);
    return kSuccess;
}
inline void DestroySampler(const Device&, const Sampler& s) { wgpuSamplerRelease(s.handle); }

/// A pipeline for shader `S` from its WGSL, with WebGPU's "auto" layout.
template <class S>
Result CreateRenderPipeline(const Device& d, const RenderPipelineDescriptor& desc, RenderPipelineOf<S>* out) {
    const WGPUShaderModule m = detail::module(d.device, S::wgsl);
    WGPUVertexBufferLayout buffers[8]{};
    WGPUVertexAttribute attrs[16]{};
    std::size_t na = 0, nb = 0;
    for (const VertexBufferLayout& vb : desc.vertex.buffers) {
        const std::size_t first = na;
        for (const VertexAttribute& a : vb.attributes) {
            attrs[na].format = detail::vertexFormat(a.format);
            attrs[na].offset = a.offset;
            attrs[na].shaderLocation = a.shaderLocation;
            ++na;
        }
        buffers[nb].stepMode = vb.stepMode == VertexStepMode::Instance ? WGPUVertexStepMode_Instance : WGPUVertexStepMode_Vertex;
        buffers[nb].arrayStride = vb.arrayStride;
        buffers[nb].attributeCount = na - first;
        buffers[nb].attributes = &attrs[first];
        ++nb;
    }
    WGPUBlendState blends[kMaxColorTargets]{};
    WGPUColorTargetState targets[kMaxColorTargets]{};
    WGPUFragmentState fragment{};
    if (desc.fragment) {
        std::size_t i = 0;
        for (const ColorTargetState& t : desc.fragment->targets) {
            targets[i].format = detail::format(t.format);
            targets[i].writeMask = t.writeMask;
            if (t.blend) {
                blends[i] = {detail::blend(t.blend->color), detail::blend(t.blend->alpha)};
                targets[i].blend = &blends[i];
            }
            ++i;
        }
        fragment.module = m;
        fragment.entryPoint = detail::sv(desc.fragment->entryPoint);
        fragment.targetCount = i;
        fragment.targets = targets;
    }
    constexpr WGPUPrimitiveTopology topo[] = {WGPUPrimitiveTopology_PointList, WGPUPrimitiveTopology_LineList, WGPUPrimitiveTopology_LineStrip,
                                              WGPUPrimitiveTopology_TriangleList, WGPUPrimitiveTopology_TriangleStrip};
    constexpr WGPUCullMode cull[] = {WGPUCullMode_None, WGPUCullMode_Front, WGPUCullMode_Back};
    WGPURenderPipelineDescriptor pd{};
    pd.vertex.module = m;
    pd.vertex.entryPoint = detail::sv(desc.vertex.entryPoint);
    pd.vertex.bufferCount = nb;
    pd.vertex.buffers = buffers;
    pd.primitive.topology = topo[std::uint32_t(desc.primitive.topology)];
    pd.primitive.frontFace = desc.primitive.frontFace == FrontFace::CCW ? WGPUFrontFace_CCW : WGPUFrontFace_CW;
    pd.primitive.cullMode = cull[std::uint32_t(desc.primitive.cullMode)];
    pd.multisample.count = desc.multisample.count;
    pd.multisample.mask = desc.multisample.mask;
    pd.multisample.alphaToCoverageEnabled = desc.multisample.alphaToCoverageEnabled;
    pd.fragment = desc.fragment ? &fragment : nullptr;
    out->pipeline = wgpuDeviceCreateRenderPipeline(d.device, &pd);
    wgpuShaderModuleRelease(m);
    return out->pipeline ? kSuccess : Result::PipelineFailed;
}

template <class S>
Result CreateComputePipeline(const Device& d, const ComputePipelineDescriptor& desc, ComputePipelineOf<S>* out) {
    const WGPUShaderModule m = detail::module(d.device, S::wgsl);
    WGPUComputePipelineDescriptor pd{};
    pd.compute.module = m;
    pd.compute.entryPoint = detail::sv(desc.entryPoint);
    out->pipeline = wgpuDeviceCreateComputePipeline(d.device, &pd);
    wgpuShaderModuleRelease(m);
    return out->pipeline ? kSuccess : Result::PipelineFailed;
}

template <class P>
void DestroyPipeline(const Device&, const P& p) {
    if constexpr (std::is_base_of_v<ComputePipeline, P>)
        wgpuComputePipelineRelease(p.pipeline);
    else
        wgpuRenderPipelineRelease(p.pipeline);
}

/// A bind group for `group` (a generated GroupN of the pipeline's shader), with the layout the
/// pipeline made for its group.
template <class P, class G>
    requires std::is_same_v<typename P::Shader, typename G::Shader>
Result CreateBindGroup(const Device& d, Arena&, const P& pipeline, const G& group, BindGroup<G::index>* out) {
    WGPUBindGroupLayout layout;
    if constexpr (std::is_base_of_v<ComputePipeline, P>)
        layout = wgpuComputePipelineGetBindGroupLayout(pipeline.pipeline, G::index);
    else
        layout = wgpuRenderPipelineGetBindGroupLayout(pipeline.pipeline, G::index);
    const auto rs = group.Resources();
    WGPUBindGroupEntry es[16]{};
    for (std::size_t i = 0; i < rs.size(); ++i) {
        es[i].binding = rs[i].binding;
        es[i].buffer = rs[i].buffer;
        es[i].size = rs[i].buffer ? WGPU_WHOLE_SIZE : 0;
        es[i].textureView = rs[i].view;
        es[i].sampler = rs[i].sampler;
    }
    WGPUBindGroupDescriptor bd{};
    bd.layout = layout;
    bd.entryCount = rs.size();
    bd.entries = es;
    out->group = wgpuDeviceCreateBindGroup(d.device, &bd);
    wgpuBindGroupLayoutRelease(layout);
    return kSuccess;
}

namespace detail {
struct Mapped {
    bool done = false, ok = false;
    static void On(WGPUMapAsyncStatus status, WGPUStringView, void* ud, void*) {
        auto* m = static_cast<Mapped*>(ud);
        m->done = true;
        m->ok = status == WGPUMapAsyncStatus_Success;
    }
};
/// Maps `staging` for reading and waits (WebGPU's mapAsync, made synchronous).
inline bool mapRead(const Device& d, WGPUBuffer staging, std::size_t size) {
    Mapped m;
    WGPUBufferMapCallbackInfo cb{};
    cb.mode = WGPUCallbackMode_AllowProcessEvents;
    cb.callback = Mapped::On;
    cb.userdata1 = &m;
    wgpuBufferMapAsync(staging, WGPUMapMode_Read, 0, size, cb);
    for (std::uint32_t polls = 0; !m.done && polls < 1000000; ++polls) {
        wgpuDevicePoll(d.device, 1, nullptr);
        if (d.instance) wgpuInstanceProcessEvents(d.instance);
    }
    return m.ok;
}
inline void submit(const Device& d, WGPUCommandEncoder e) {
    const WGPUCommandBuffer cb = wgpuCommandEncoderFinish(e, nullptr);
    wgpuQueueSubmit(d.queue, 1, &cb);
    wgpuCommandBufferRelease(cb);
    wgpuCommandEncoderRelease(e);
}
} // namespace detail

/// Copies `size` bytes of `b` from `offset` into `out`, through a mappable buffer, waiting for
/// the GPU. `b` needs CopySrc.
inline Result ReadBuffer(const Device& d, const Buffer& b, std::uint64_t offset, void* out, std::size_t size) {
    const std::size_t padded = (size + 3) & ~std::size_t(3);
    WGPUBufferDescriptor bd{};
    bd.usage = WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst;
    bd.size = padded;
    const WGPUBuffer staging = wgpuDeviceCreateBuffer(d.device, &bd);
    const WGPUCommandEncoder e = wgpuDeviceCreateCommandEncoder(d.device, nullptr);
    wgpuCommandEncoderCopyBufferToBuffer(e, b.handle, offset, staging, 0, padded);
    detail::submit(d, e);
    const bool ok = detail::mapRead(d, staging, padded);
    if (ok) {
        std::memcpy(out, wgpuBufferGetConstMappedRange(staging, 0, padded), size);
        wgpuBufferUnmap(staging);
    }
    wgpuBufferRelease(staging);
    return ok ? kSuccess : Result::MapFailed;
}

/// Copies an RGBA8 texture's rows (from the top) into `out`, waiting for the GPU. `t` needs
/// CopySrc.
inline Result ReadTexture(const Device& d, const Texture& t, std::uint8_t* out) {
    const std::uint32_t row = t.width * 4, padded = (row + 255) & ~255u;
    WGPUBufferDescriptor bd{};
    bd.usage = WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst;
    bd.size = std::uint64_t(padded) * t.height;
    const WGPUBuffer staging = wgpuDeviceCreateBuffer(d.device, &bd);
    const WGPUCommandEncoder e = wgpuDeviceCreateCommandEncoder(d.device, nullptr);
    WGPUTexelCopyTextureInfo src{};
    src.texture = t.texture;
    src.aspect = WGPUTextureAspect_All;
    WGPUTexelCopyBufferInfo dst{};
    dst.layout.bytesPerRow = padded;
    dst.layout.rowsPerImage = t.height;
    dst.buffer = staging;
    const WGPUExtent3D extent{t.width, t.height, 1};
    wgpuCommandEncoderCopyTextureToBuffer(e, &src, &dst, &extent);
    detail::submit(d, e);
    const bool ok = detail::mapRead(d, staging, bd.size);
    if (ok) {
        const auto* p = static_cast<const std::uint8_t*>(wgpuBufferGetConstMappedRange(staging, 0, bd.size));
        for (std::uint32_t y = 0; y < t.height; ++y) std::memcpy(out + y * row, p + y * padded, row);
        wgpuBufferUnmap(staging);
    }
    wgpuBufferRelease(staging);
    return ok ? kSuccess : Result::MapFailed;
}

} // namespace lcgf::gpu
