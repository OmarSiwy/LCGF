// lcgf/gpu/d3d12.hpp: lcgf_render.gpu for C++ on Direct3D 12. Included by lcgf/gpu.hpp when
// LCGF_GPU_D3D12 is defined.
//
// src/render/d3d12/gpu.zig, inline: WebGPU's object model projected onto D3D12, call for call. A
// type is a plain struct of D3D12 objects and descriptors with public fields (`pass.Get()` is
// the ID3D12GraphicsCommandList, `buffer.handle` the ID3D12Resource). It builds on d3d12.h: the
// Windows SDK's, MinGW-w64's, or Microsoft's DirectX-Headers (`zig build abi` installs them under
// include/directx-headers; on Linux they make the header build for bindings/check's recorder).
// Link d3d12, dxgi and d3dcompiler on Windows.
//
// Bind groups are descriptor tables. A shader's root signature is built from its bind groups:
// for each group, one table of its buffers and textures (registers b/t/u = binding, space =
// group, as naga numbers them) and, if it has samplers, one table of those. A bind group is a run
// of descriptors in its arena's shader-visible heaps; SetBindGroup sets the heaps and one or two
// root tables. naga's sampler heap is rewritten to plain registered samplers by lcgf-gen.
//
// Resource states by convention, not tracking. A texture rests in one state: UNORDERED_ACCESS
// with StorageBinding, else shader-readable with TextureBinding, else RENDER_TARGET. Writes move
// it to COPY_DEST and Finish back; a render pass moves it to RENDER_TARGET and End back. Buffers
// rest in COMMON, promoted implicitly; the buffers an upload wrote return to COMMON at Finish.
// Writes go through the device's staging ring (an UPLOAD heap buffer), copied on the queue.
//
// Methods that return a struct (a heap's start, a resource's description) are called through
// their vtable slot with the result pointer after `this`: the Windows ABI, as the Zig back end
// calls them, on every target.
#pragma once
#include <algorithm>
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <type_traits>

#if defined(_WIN32)
#include <d3d12.h>
#include <d3dcompiler.h>
#else
#include <wsl/winadapter.h>
#include <directx/d3d12.h>
// d3dcompiler.h is not part of DirectX-Headers: what the projection calls of it.
#define D3DCOMPILE_OPTIMIZATION_LEVEL3 (1 << 15)
extern "C" HRESULT WINAPI D3DCompile(LPCVOID src, SIZE_T len, LPCSTR name, const void* defines, void* include, LPCSTR entry, LPCSTR target, UINT flags1,
                                     UINT flags2, ID3DBlob** code, ID3DBlob** errors);
#endif

#include "types.hpp"

namespace lcgf::gpu {

/// What creation reports: S_OK, or the failing HRESULT.
using Result = HRESULT;
inline constexpr Result kSuccess = S_OK;
inline constexpr Result kOutOfArena = HRESULT(0x8007000E); // E_OUTOFMEMORY
inline constexpr Result kNoCode = HRESULT(0x80004001);     // E_NOTIMPL: the shader was not built for D3D12

namespace detail {
// The interfaces' IIDs, as the Zig back end spells them (no __uuidof machinery needed).
inline constexpr IID kResource = {0x696442be, 0xa72e, 0x4059, {0xbc, 0x79, 0x5b, 0x5c, 0x98, 0x04, 0x0f, 0xad}};
inline constexpr IID kDescriptorHeap = {0x8efb471d, 0x616c, 0x4f49, {0x90, 0xf7, 0x12, 0x7b, 0xb7, 0x63, 0xfa, 0x51}};
inline constexpr IID kRootSignature = {0xc54a6b66, 0x72df, 0x4ee8, {0x8b, 0xe5, 0xa9, 0x46, 0xa1, 0x42, 0x92, 0x14}};
inline constexpr IID kPipelineState = {0x765a30f3, 0xf624, 0x4c6f, {0xa8, 0x28, 0xac, 0xe9, 0x48, 0x62, 0x24, 0x45}};

/// Method `slot` of a COM object, as `F`.
template <class F>
inline F method(void* obj, std::size_t slot) {
    return reinterpret_cast<F>((*static_cast<void***>(obj))[slot]);
}
inline D3D12_CPU_DESCRIPTOR_HANDLE cpuStart(ID3D12DescriptorHeap* h) {
    D3D12_CPU_DESCRIPTOR_HANDLE out;
    method<D3D12_CPU_DESCRIPTOR_HANDLE*(STDMETHODCALLTYPE*)(ID3D12DescriptorHeap*, D3D12_CPU_DESCRIPTOR_HANDLE*)>(h, 9)(h, &out);
    return out;
}
inline D3D12_GPU_DESCRIPTOR_HANDLE gpuStart(ID3D12DescriptorHeap* h) {
    D3D12_GPU_DESCRIPTOR_HANDLE out;
    method<D3D12_GPU_DESCRIPTOR_HANDLE*(STDMETHODCALLTYPE*)(ID3D12DescriptorHeap*, D3D12_GPU_DESCRIPTOR_HANDLE*)>(h, 10)(h, &out);
    return out;
}
inline D3D12_RESOURCE_DESC resourceDesc(ID3D12Resource* r) {
    D3D12_RESOURCE_DESC out;
    method<D3D12_RESOURCE_DESC*(STDMETHODCALLTYPE*)(ID3D12Resource*, D3D12_RESOURCE_DESC*)>(r, 10)(r, &out);
    return out;
}
template <class T>
inline void release(T* o) {
    if (o) o->Release();
}
inline constexpr D3D12_RESOURCE_STATES kShaderResource = D3D12_RESOURCE_STATES(D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE | D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
inline constexpr std::uint32_t kMaxVertexBuffers = 8, kMaxVertexAttributes = 16, kMaxUploadWrites = 32;

inline D3D12_HEAP_PROPERTIES heapProps(D3D12_HEAP_TYPE kind) {
    return {kind, D3D12_CPU_PAGE_PROPERTY_UNKNOWN, D3D12_MEMORY_POOL_UNKNOWN, 1, 1};
}
/// A transition barrier for all subresources of `res`.
inline D3D12_RESOURCE_BARRIER transition(ID3D12Resource* res, D3D12_RESOURCE_STATES before, D3D12_RESOURCE_STATES after) {
    D3D12_RESOURCE_BARRIER b{};
    b.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    b.Transition = {res, D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES, before, after};
    return b;
}
inline DXGI_FORMAT dxgiFormat(TextureFormat f) {
    constexpr DXGI_FORMAT t[] = {
        DXGI_FORMAT_R8_UNORM,
        DXGI_FORMAT_R8G8_UNORM,
        DXGI_FORMAT_R8G8B8A8_UNORM,
        DXGI_FORMAT_R8G8B8A8_UNORM_SRGB,
        DXGI_FORMAT_B8G8R8A8_UNORM,
        DXGI_FORMAT_B8G8R8A8_UNORM_SRGB,
        DXGI_FORMAT_R16_FLOAT,
        DXGI_FORMAT_R16G16B16A16_FLOAT,
        DXGI_FORMAT_R32_FLOAT,
        DXGI_FORMAT_R32G32_FLOAT,
        DXGI_FORMAT_R32G32B32A32_FLOAT,
        DXGI_FORMAT_R32_UINT,
        DXGI_FORMAT_D32_FLOAT,
    };
    return t[std::uint32_t(f)];
}
inline DXGI_FORMAT vertexFormat(VertexFormat f) {
    constexpr DXGI_FORMAT t[] = {DXGI_FORMAT_R32_FLOAT, DXGI_FORMAT_R32G32_FLOAT, DXGI_FORMAT_R32G32B32_FLOAT,
                                 DXGI_FORMAT_R32G32B32A32_FLOAT, DXGI_FORMAT_R32_UINT, DXGI_FORMAT_R32G32_UINT,
                                 DXGI_FORMAT_R32G32B32A32_UINT, DXGI_FORMAT_R32_SINT, DXGI_FORMAT_R8G8B8A8_UNORM};
    return t[std::uint32_t(f)];
}
inline D3D12_BLEND blendFactor(BlendFactor f) {
    constexpr D3D12_BLEND t[] = {D3D12_BLEND_ZERO, D3D12_BLEND_ONE, D3D12_BLEND_SRC_COLOR, D3D12_BLEND_INV_SRC_COLOR,
                                 D3D12_BLEND_SRC_ALPHA, D3D12_BLEND_INV_SRC_ALPHA, D3D12_BLEND_DEST_COLOR, D3D12_BLEND_INV_DEST_COLOR,
                                 D3D12_BLEND_DEST_ALPHA, D3D12_BLEND_INV_DEST_ALPHA, D3D12_BLEND_BLEND_FACTOR, D3D12_BLEND_INV_BLEND_FACTOR};
    return t[std::uint32_t(f)];
}
inline D3D12_BLEND_OP blendOp(BlendOperation o) {
    constexpr D3D12_BLEND_OP t[] = {D3D12_BLEND_OP_ADD, D3D12_BLEND_OP_SUBTRACT, D3D12_BLEND_OP_REV_SUBTRACT, D3D12_BLEND_OP_MIN, D3D12_BLEND_OP_MAX};
    return t[std::uint32_t(o)];
}
inline D3D12_TEXTURE_ADDRESS_MODE addressMode(AddressMode a) {
    constexpr D3D12_TEXTURE_ADDRESS_MODE t[] = {D3D12_TEXTURE_ADDRESS_MODE_CLAMP, D3D12_TEXTURE_ADDRESS_MODE_WRAP, D3D12_TEXTURE_ADDRESS_MODE_MIRROR};
    return t[std::uint32_t(a)];
}
inline D3D12_RENDER_TARGET_BLEND_DESC blendDesc(const ColorTargetState& t) {
    const std::uint32_t m = t.writeMask;
    D3D12_RENDER_TARGET_BLEND_DESC b{TRUE,
                                     FALSE,
                                     D3D12_BLEND_ONE,
                                     D3D12_BLEND_INV_SRC_ALPHA,
                                     D3D12_BLEND_OP_ADD,
                                     D3D12_BLEND_ONE,
                                     D3D12_BLEND_INV_SRC_ALPHA,
                                     D3D12_BLEND_OP_ADD,
                                     D3D12_LOGIC_OP_NOOP,
                                     UINT8(m & 0xf)}; // WebGPU's mask is D3D12's: red 1 ... alpha 8
    if (!t.blend) {
        b.BlendEnable = FALSE;
        return b;
    }
    const BlendState& s = *t.blend;
    b.SrcBlend = blendFactor(s.color.srcFactor);
    b.DestBlend = blendFactor(s.color.dstFactor);
    b.BlendOp = blendOp(s.color.operation);
    b.SrcBlendAlpha = blendFactor(s.alpha.srcFactor);
    b.DestBlendAlpha = blendFactor(s.alpha.dstFactor);
    b.BlendOpAlpha = blendOp(s.alpha.operation);
    return b;
}
inline bool isSampler(BindingKind k) { return k == BindingKind::Sampler || k == BindingKind::ComparisonSampler; }
} // namespace detail

struct Staging;

/// The host's ID3D12Device. Set `staging` before the first Upload that is given none.
struct Device {
    ID3D12Device* device;
    Staging* staging = nullptr;
    static Device Wrap(ID3D12Device* device) { return {device}; }
};

struct Buffer {
    ID3D12Resource* handle;
    /// Its GPU virtual address.
    std::uint64_t address;
    std::uint64_t size;
    /// Set in a Host arena (UPLOAD heap).
    std::byte* mapped = nullptr;
};

struct TextureView {
    ID3D12Resource* resource;
    D3D12_CPU_DESCRIPTOR_HANDLE rtv{0};
    std::uint32_t width, height, samples = 1;
    D3D12_RESOURCE_STATES resting = detail::kShaderResource;
    TextureFormat format = TextureFormat::RGBA8Unorm;
};

struct Texture {
    ID3D12Resource* resource;
    TextureFormat format;
    std::uint32_t width, height, samples;
    /// The state it keeps between passes (see the file comment).
    D3D12_RESOURCE_STATES resting;
    /// Its render target view, if it is a render attachment.
    D3D12_CPU_DESCRIPTOR_HANDLE rtv{0};
    TextureView CreateView() const { return {resource, rtv, width, height, samples, resting, format}; }
};

/// A sampler is a descriptor in D3D12: this is its description, written into a bind group's
/// sampler table when the group is made.
struct Sampler {
    D3D12_SAMPLER_DESC desc;
};

/// A pipeline, its root signature, and what its passes set from it: the topology, the vertex
/// strides, and where each group's tables are among the root parameters.
struct RenderPipeline {
    ID3D12PipelineState* pso;
    ID3D12RootSignature* root;
    D3D12_PRIMITIVE_TOPOLOGY topology;
    std::uint32_t strides[detail::kMaxVertexBuffers] = {};
};
struct ComputePipeline {
    ID3D12PipelineState* pso;
    ID3D12RootSignature* root;
};
template <class S>
struct RenderPipelineOf : RenderPipeline {
    using Shader = S;
};
template <class S>
struct ComputePipelineOf : ComputePipeline {
    using Shader = S;
};

/// A bind group: where its descriptor tables start in the arena's two shader-visible heaps, and
/// the root parameters they go to (~0u for a table the group does not have).
template <std::uint32_t G>
struct BindGroup {
    D3D12_GPU_DESCRIPTOR_HANDLE resources{0}, samplers{0};
    ID3D12DescriptorHeap* heaps[2];
    std::uint32_t resourceParam = ~0u, samplerParam = ~0u;
    static constexpr std::uint32_t index = G;
};

/// One resource of a bind group, as a generated `GroupN::Resources()` lists them.
struct Resource {
    std::uint32_t binding;
    BindingKind kind;
    const Buffer* buffer = nullptr;
    const TextureView* view = nullptr;
    const Sampler* sampler = nullptr;
};
inline Resource BufferResource(std::uint32_t binding, BindingKind kind, const Buffer& b) { return {binding, kind, &b}; }
inline Resource ViewResource(std::uint32_t binding, BindingKind kind, const TextureView& v) { return {binding, kind, nullptr, &v}; }
inline Resource SamplerResource(std::uint32_t binding, BindingKind kind, const Sampler& s) { return {binding, kind, nullptr, nullptr, &s}; }

/// The descriptor heaps bind groups and render targets live in, owned by the caller. A Host
/// arena also makes its buffers UPLOAD-heap memory, mapped for the CPU.
struct Arena {
    MemoryKind kind = MemoryKind::Device;
    ID3D12DescriptorHeap* heaps[3] = {}; // resources, samplers, render target views
    std::uint32_t used[3] = {}, capacity[3] = {}, strides[3] = {};
    enum Which { kResources,
                 kSamplers,
                 kRtv };

    /// `n` descriptors of heap `w`, or a null handle when they do not fit.
    D3D12_CPU_DESCRIPTOR_HANDLE Take(Which w, std::uint32_t n) {
        if (used[w] + n > capacity[w]) return {0};
        const D3D12_CPU_DESCRIPTOR_HANDLE at{detail::cpuStart(heaps[w]).ptr + SIZE_T(used[w]) * strides[w]};
        used[w] += n;
        return at;
    }
    D3D12_GPU_DESCRIPTOR_HANDLE GpuOf(Which w, D3D12_CPU_DESCRIPTOR_HANDLE cpu) const {
        return {detail::gpuStart(heaps[w]).ptr + (cpu.ptr - detail::cpuStart(heaps[w]).ptr)};
    }
    /// Forgets every bind group and render target view placed here.
    void Reset() { std::fill_n(used, 3, 0u); }
};

inline Result CreateArena(const Device& d, std::uint64_t, MemoryKind kind, std::uint32_t bindGroups, Arena* out) {
    Arena a;
    a.kind = kind;
    const std::uint32_t counts[3] = {8 * bindGroups, 4 * bindGroups, bindGroups};
    const D3D12_DESCRIPTOR_HEAP_TYPE kinds[3] = {D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER, D3D12_DESCRIPTOR_HEAP_TYPE_RTV};
    for (int i = 0; i < 3; ++i) {
        const D3D12_DESCRIPTOR_HEAP_DESC hd{kinds[i], counts[i], i < 2 ? D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE : D3D12_DESCRIPTOR_HEAP_FLAG_NONE, 0};
        if (const HRESULT r = d.device->CreateDescriptorHeap(&hd, detail::kDescriptorHeap, reinterpret_cast<void**>(&a.heaps[i])); FAILED(r)) return r;
        a.strides[i] = d.device->GetDescriptorHandleIncrementSize(kinds[i]);
        a.capacity[i] = counts[i];
    }
    *out = a;
    return kSuccess;
}
inline void DestroyArena(const Device&, Arena& a) {
    for (int i = 2; i >= 0; --i) detail::release(a.heaps[i]);
}

inline Result CreateBuffer(const Device& d, Arena& arena, const BufferDescriptor& desc, Buffer* out) {
    // Constant buffer views take whole 256-byte blocks.
    const std::uint64_t size = (desc.usage & BufferUsage::Uniform) ? (desc.size + 255) & ~std::uint64_t(255) : desc.size;
    const bool upload = arena.kind == MemoryKind::Host;
    D3D12_RESOURCE_DESC rd{};
    rd.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    rd.Width = size;
    rd.Height = 1;
    rd.DepthOrArraySize = 1;
    rd.MipLevels = 1;
    rd.Format = DXGI_FORMAT_UNKNOWN;
    rd.SampleDesc = {1, 0};
    rd.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    if (desc.usage & BufferUsage::Storage) rd.Flags = D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
    // An upload heap's resources stay in GENERIC_READ and the GPU never writes them: a host
    // buffer the GPU writes (storage, or a copy's destination) lives in a custom heap the CPU
    // maps write-back, in system memory (L0), resting in COMMON (src/render/d3d12/gpu.zig).
    const bool gpuWritten = (desc.usage & BufferUsage::Storage) || (desc.usage & BufferUsage::CopyDst);
    D3D12_HEAP_PROPERTIES heap = detail::heapProps(upload ? D3D12_HEAP_TYPE_UPLOAD : D3D12_HEAP_TYPE_DEFAULT);
    if (upload && gpuWritten) {
        heap.Type = D3D12_HEAP_TYPE_CUSTOM;
        heap.CPUPageProperty = D3D12_CPU_PAGE_PROPERTY_WRITE_BACK;
        heap.MemoryPoolPreference = D3D12_MEMORY_POOL_L0;
    }
    ID3D12Resource* r = nullptr;
    if (const HRESULT h = d.device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &rd, upload && !gpuWritten ? D3D12_RESOURCE_STATE_GENERIC_READ : D3D12_RESOURCE_STATE_COMMON,
                                                            nullptr, detail::kResource, reinterpret_cast<void**>(&r));
        FAILED(h))
        return h;
    *out = {r, r->GetGPUVirtualAddress(), desc.size};
    if (upload) {
        const D3D12_RANGE none{0, 0};
        void* p = nullptr;
        if (const HRESULT h = r->Map(0, &none, &p); FAILED(h)) return h;
        out->mapped = static_cast<std::byte*>(p);
    }
    return kSuccess;
}
inline void DestroyBuffer(const Device&, const Buffer& b) { detail::release(b.handle); }

/// An UPLOAD-heap ring the frame's writes copy from. One per frame in flight; `Rewind` it when
/// that frame's previous use has completed.
struct Staging {
    Buffer buffer{nullptr, 0, 0};
    std::uint64_t used = 0;
    void Rewind() { used = 0; }
    /// Room for `n` bytes at `alignment`: its offset, or ~0 when it does not fit.
    std::uint64_t Reserve(std::uint64_t n, std::uint64_t alignment) {
        const std::uint64_t at = (used + alignment - 1) / alignment * alignment;
        if (at + n > buffer.size) return ~std::uint64_t(0);
        used = at + n;
        return at;
    }
};
inline Result CreateStaging(const Device& d, Arena& host, std::uint64_t bytes, Staging* out) {
    if (host.kind != MemoryKind::Host) return E_INVALIDARG;
    *out = {};
    return CreateBuffer(d, host, {bytes, BufferUsage::CopySrc}, &out->buffer);
}

inline Result CreateTexture(const Device& d, Arena& arena, const TextureDescriptor& desc, Texture* out) {
    D3D12_RESOURCE_DESC rd{};
    rd.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    rd.Width = desc.width;
    rd.Height = desc.height;
    rd.DepthOrArraySize = 1;
    rd.MipLevels = UINT16(desc.mipLevelCount);
    rd.Format = detail::dxgiFormat(desc.format);
    rd.SampleDesc = {desc.sampleCount, 0};
    rd.Layout = D3D12_TEXTURE_LAYOUT_UNKNOWN;
    if (desc.usage & TextureUsage::RenderAttachment) rd.Flags |= D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    if (desc.usage & TextureUsage::StorageBinding) rd.Flags |= D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
    const D3D12_RESOURCE_STATES resting = (desc.usage & TextureUsage::StorageBinding)     ? D3D12_RESOURCE_STATE_UNORDERED_ACCESS
                                          : (desc.usage & TextureUsage::TextureBinding)   ? detail::kShaderResource
                                          : (desc.usage & TextureUsage::RenderAttachment) ? D3D12_RESOURCE_STATE_RENDER_TARGET
                                                                                          : D3D12_RESOURCE_STATE_COMMON;
    const D3D12_HEAP_PROPERTIES heap = detail::heapProps(D3D12_HEAP_TYPE_DEFAULT);
    ID3D12Resource* r = nullptr;
    if (const HRESULT h = d.device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &rd, resting, nullptr, detail::kResource, reinterpret_cast<void**>(&r));
        FAILED(h))
        return h;
    *out = {r, desc.format, desc.width, desc.height, desc.sampleCount, resting};
    if (desc.usage & TextureUsage::RenderAttachment) {
        out->rtv = arena.Take(Arena::kRtv, 1);
        if (!out->rtv.ptr) return kOutOfArena;
        d.device->CreateRenderTargetView(r, nullptr, out->rtv);
    }
    return kSuccess;
}
inline void DestroyTexture(const Device&, const Texture& t) { detail::release(t.resource); }

inline Result CreateSampler(const Device&, const SamplerDescriptor& desc, Sampler* out) {
    const UINT filter = UINT(desc.mipmapFilter == FilterMode::Linear) | UINT(desc.magFilter == FilterMode::Linear) << 2 |
                        UINT(desc.minFilter == FilterMode::Linear) << 4;
    out->desc = {D3D12_FILTER(filter),
                 detail::addressMode(desc.addressModeU),
                 detail::addressMode(desc.addressModeV),
                 detail::addressMode(desc.addressModeW),
                 0,
                 1,
                 D3D12_COMPARISON_FUNC_NEVER,
                 {0, 0, 0, 0},
                 desc.lodMinClamp,
                 desc.lodMaxClamp};
    return kSuccess;
}
inline void DestroySampler(const Device&, const Sampler&) {}

namespace detail {
/// The root signature of a shader's bind groups (`groups`, as lcgf-gen reflects them).
inline Result rootSignature(ID3D12Device* d, std::span<const std::span<const BindingLayout>> groups, ID3D12RootSignature** out) {
    std::size_t total = 0;
    for (const auto& g : groups) total += g.size();
    D3D12_DESCRIPTOR_RANGE ranges[64];
    D3D12_ROOT_PARAMETER params[2 * kMaxGroups];
    if (total > 64 || groups.size() > kMaxGroups) return E_INVALIDARG;
    UINT nr = 0, np = 0;
    for (std::size_t g = 0; g < groups.size(); ++g) {
        for (const bool samplerTable : {false, true}) {
            const UINT first = nr;
            UINT k = 0;
            for (const BindingLayout& b : groups[g]) {
                if (isSampler(b.kind) != samplerTable) continue;
                D3D12_DESCRIPTOR_RANGE_TYPE t;
                switch (b.kind) {
                case BindingKind::Uniform: t = D3D12_DESCRIPTOR_RANGE_TYPE_CBV; break;
                case BindingKind::StorageRead:
                case BindingKind::Texture: t = D3D12_DESCRIPTOR_RANGE_TYPE_SRV; break;
                case BindingKind::StorageReadWrite:
                case BindingKind::StorageTexture: t = D3D12_DESCRIPTOR_RANGE_TYPE_UAV; break;
                default: t = D3D12_DESCRIPTOR_RANGE_TYPE_SAMPLER;
                }
                ranges[nr++] = {t, 1, b.binding, UINT(g), k++};
            }
            if (nr > first) {
                params[np] = {};
                params[np].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
                params[np].DescriptorTable = {nr - first, &ranges[first]};
                params[np].ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
                ++np;
            }
        }
    }
    const D3D12_ROOT_SIGNATURE_DESC rd{np, params, 0, nullptr, D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT};
    ID3DBlob* blob = nullptr;
    ID3DBlob* errors = nullptr;
    const HRESULT h = D3D12SerializeRootSignature(&rd, D3D_ROOT_SIGNATURE_VERSION_1, &blob, &errors);
    if (FAILED(h)) {
        if (errors) std::fprintf(stderr, "lcgf/gpu.hpp (D3D12): %.*s\n", int(errors->GetBufferSize()), static_cast<const char*>(errors->GetBufferPointer()));
        release(errors);
        return h;
    }
    const HRESULT c = d->CreateRootSignature(0, blob->GetBufferPointer(), blob->GetBufferSize(), kRootSignature, reinterpret_cast<void**>(out));
    release(blob);
    release(errors);
    return c;
}
/// The root parameter of group `g`'s resource table, then of its sampler table.
inline void rootParams(std::span<const std::span<const BindingLayout>> groups, std::uint32_t g, std::uint32_t* resources, std::uint32_t* samplers) {
    std::uint32_t n = 0;
    for (std::uint32_t k = 0; k <= g && k < groups.size(); ++k) {
        bool r = false, s = false;
        for (const BindingLayout& b : groups[k]) (isSampler(b.kind) ? s : r) = true;
        if (k == g) {
            *resources = r ? n : ~0u;
            *samplers = s ? n + r : ~0u;
        }
        n += std::uint32_t(r) + std::uint32_t(s);
    }
}
inline Result compile(std::string_view hlsl, const char* entry, const char* target, ID3DBlob** out) {
    ID3DBlob* errors = nullptr;
    const HRESULT h = D3DCompile(hlsl.data(), hlsl.size(), "quad.hlsl", nullptr, nullptr, entry, target, D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, out, &errors);
    if (FAILED(h) && errors) std::fprintf(stderr, "lcgf/gpu.hpp (D3D12): %.*s\n", int(errors->GetBufferSize()), static_cast<const char*>(errors->GetBufferPointer()));
    release(errors);
    return h;
}
} // namespace detail

/// A pipeline for shader `S` from the HLSL lcgf-gen took naga's samplers out of.
template <class S>
Result CreateRenderPipeline(const Device& d, const RenderPipelineDescriptor& desc, RenderPipelineOf<S>* out) {
    if constexpr (!requires { S::hlsl; }) {
        return kNoCode; // build the shader with --hlsl (CMake: LCGF_GPU=D3D12)
    } else {
        ID3D12RootSignature* root = nullptr;
        if (const HRESULT h = detail::rootSignature(d.device, S::groups, &root); FAILED(h)) return h;
        static constexpr FragmentState kNoFragment{};
        const FragmentState& frag = desc.fragment ? *desc.fragment : kNoFragment;
        ID3DBlob* vs = nullptr;
        ID3DBlob* ps = nullptr;
        HRESULT h = detail::compile(S::hlsl, desc.vertex.entryPoint, "vs_5_1", &vs);
        if (SUCCEEDED(h)) h = detail::compile(S::hlsl, frag.entryPoint, "ps_5_1", &ps);
        if (FAILED(h)) {
            detail::release(vs);
            detail::release(root);
            return h;
        }
        RenderPipelineOf<S> p{};
        p.root = root;
        constexpr D3D_PRIMITIVE_TOPOLOGY topo[] = {D3D_PRIMITIVE_TOPOLOGY_POINTLIST, D3D_PRIMITIVE_TOPOLOGY_LINELIST, D3D_PRIMITIVE_TOPOLOGY_LINESTRIP,
                                                   D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST, D3D_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP};
        p.topology = topo[std::uint32_t(desc.primitive.topology)];
        D3D12_INPUT_ELEMENT_DESC elements[detail::kMaxVertexAttributes];
        UINT n = 0, slot = 0;
        for (const VertexBufferLayout& vb : desc.vertex.buffers) {
            p.strides[slot] = std::uint32_t(vb.arrayStride);
            const bool instance = vb.stepMode == VertexStepMode::Instance;
            for (const VertexAttribute& a : vb.attributes)
                elements[n++] = {"LOC",
                                 a.shaderLocation,
                                 detail::vertexFormat(a.format),
                                 slot,
                                 UINT(a.offset),
                                 instance ? D3D12_INPUT_CLASSIFICATION_PER_INSTANCE_DATA : D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA,
                                 UINT(instance)};
            ++slot;
        }
        D3D12_GRAPHICS_PIPELINE_STATE_DESC pd{};
        pd.pRootSignature = root;
        pd.VS = {vs->GetBufferPointer(), vs->GetBufferSize()};
        pd.PS = {ps->GetBufferPointer(), ps->GetBufferSize()};
        UINT i = 0;
        for (const ColorTargetState& t : frag.targets) {
            pd.BlendState.RenderTarget[i] = detail::blendDesc(t);
            pd.RTVFormats[i] = detail::dxgiFormat(t.format);
            ++i;
        }
        pd.BlendState.AlphaToCoverageEnable = desc.multisample.alphaToCoverageEnabled;
        pd.SampleMask = desc.multisample.mask;
        constexpr D3D12_CULL_MODE cull[] = {D3D12_CULL_MODE_NONE, D3D12_CULL_MODE_FRONT, D3D12_CULL_MODE_BACK};
        pd.RasterizerState = {D3D12_FILL_MODE_SOLID, cull[std::uint32_t(desc.primitive.cullMode)], desc.primitive.frontFace == FrontFace::CCW,
                              0, 0, 0, TRUE, desc.multisample.count > 1, FALSE, 0, D3D12_CONSERVATIVE_RASTERIZATION_MODE_OFF};
        pd.InputLayout = {elements, n};
        // C++'s stripIndexFormat names no index format, and D3D12's cut value needs one: strips
        // do not cut here.
        pd.IBStripCutValue = D3D12_INDEX_BUFFER_STRIP_CUT_VALUE_DISABLED;
        constexpr D3D12_PRIMITIVE_TOPOLOGY_TYPE type[] = {D3D12_PRIMITIVE_TOPOLOGY_TYPE_POINT, D3D12_PRIMITIVE_TOPOLOGY_TYPE_LINE, D3D12_PRIMITIVE_TOPOLOGY_TYPE_LINE,
                                                          D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE, D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE};
        pd.PrimitiveTopologyType = type[std::uint32_t(desc.primitive.topology)];
        pd.NumRenderTargets = UINT(frag.targets.size());
        pd.SampleDesc = {desc.multisample.count, 0};
        h = d.device->CreateGraphicsPipelineState(&pd, detail::kPipelineState, reinterpret_cast<void**>(&p.pso));
        detail::release(ps);
        detail::release(vs);
        if (FAILED(h)) {
            detail::release(root);
            return h;
        }
        *out = p;
        return kSuccess;
    }
}

template <class S>
Result CreateComputePipeline(const Device& d, const ComputePipelineDescriptor& desc, ComputePipelineOf<S>* out) {
    if constexpr (!requires { S::hlsl; }) {
        return kNoCode;
    } else {
        ID3D12RootSignature* root = nullptr;
        if (const HRESULT h = detail::rootSignature(d.device, S::groups, &root); FAILED(h)) return h;
        ID3DBlob* cs = nullptr;
        if (const HRESULT h = detail::compile(S::hlsl, desc.entryPoint, "cs_5_1", &cs); FAILED(h)) {
            detail::release(root);
            return h;
        }
        D3D12_COMPUTE_PIPELINE_STATE_DESC pd{};
        pd.pRootSignature = root;
        pd.CS = {cs->GetBufferPointer(), cs->GetBufferSize()};
        ID3D12PipelineState* pso = nullptr;
        const HRESULT h = d.device->CreateComputePipelineState(&pd, detail::kPipelineState, reinterpret_cast<void**>(&pso));
        detail::release(cs);
        if (FAILED(h)) {
            detail::release(root);
            return h;
        }
        *out = {{pso, root}};
        return kSuccess;
    }
}

template <class P>
void DestroyPipeline(const Device&, const P& p) {
    detail::release(p.pso);
    detail::release(p.root);
}

/// A bind group for `group` (a generated GroupN of the pipeline's shader): its descriptors,
/// written into a run of the arena's shader-visible heaps.
template <class P, class G>
    requires std::is_same_v<typename P::Shader, typename G::Shader>
Result CreateBindGroup(const Device& d, Arena& arena, const P&, const G& group, BindGroup<G::index>* out) {
    using S = typename P::Shader;
    const auto rs = group.Resources();
    std::uint32_t nres = 0, nsmp = 0;
    for (const Resource& r : rs) ++(detail::isSampler(r.kind) ? nsmp : nres);
    BindGroup<G::index> bg{};
    bg.heaps[0] = arena.heaps[Arena::kResources];
    bg.heaps[1] = arena.heaps[Arena::kSamplers];
    detail::rootParams(S::groups, G::index, &bg.resourceParam, &bg.samplerParam);
    D3D12_CPU_DESCRIPTOR_HANDLE res{0}, smp{0};
    if (nres > 0 && !(res = arena.Take(Arena::kResources, nres)).ptr) return kOutOfArena;
    if (nsmp > 0 && !(smp = arena.Take(Arena::kSamplers, nsmp)).ptr) return kOutOfArena;
    if (nres > 0) bg.resources = arena.GpuOf(Arena::kResources, res);
    if (nsmp > 0) bg.samplers = arena.GpuOf(Arena::kSamplers, smp);
    std::uint32_t r = 0, s = 0;
    for (const Resource& v : rs) {
        const D3D12_CPU_DESCRIPTOR_HANDLE at{res.ptr + SIZE_T(r) * arena.strides[Arena::kResources]};
        switch (v.kind) {
        case BindingKind::Uniform: {
            const D3D12_CONSTANT_BUFFER_VIEW_DESC cd{v.buffer->address, UINT((v.buffer->size + 255) & ~std::uint64_t(255))};
            d.device->CreateConstantBufferView(&cd, at);
            ++r;
            break;
        }
        case BindingKind::StorageRead: {
            D3D12_SHADER_RESOURCE_VIEW_DESC sd{};
            sd.Format = DXGI_FORMAT_R32_TYPELESS;
            sd.ViewDimension = D3D12_SRV_DIMENSION_BUFFER;
            sd.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
            sd.Buffer = {0, UINT(v.buffer->size / 4), 0, D3D12_BUFFER_SRV_FLAG_RAW};
            d.device->CreateShaderResourceView(v.buffer->handle, &sd, at);
            ++r;
            break;
        }
        case BindingKind::StorageReadWrite: {
            D3D12_UNORDERED_ACCESS_VIEW_DESC ud{};
            ud.Format = DXGI_FORMAT_R32_TYPELESS;
            ud.ViewDimension = D3D12_UAV_DIMENSION_BUFFER;
            ud.Buffer = {0, UINT(v.buffer->size / 4), 0, 0, D3D12_BUFFER_UAV_FLAG_RAW};
            d.device->CreateUnorderedAccessView(v.buffer->handle, nullptr, &ud, at);
            ++r;
            break;
        }
        case BindingKind::Texture:
            d.device->CreateShaderResourceView(v.view->resource, nullptr, at);
            ++r;
            break;
        case BindingKind::StorageTexture:
            d.device->CreateUnorderedAccessView(v.view->resource, nullptr, nullptr, at);
            ++r;
            break;
        case BindingKind::Sampler:
        case BindingKind::ComparisonSampler:
            d.device->CreateSampler(&v.sampler->desc, {smp.ptr + SIZE_T(s) * arena.strides[Arena::kSamplers]});
            ++s;
            break;
        }
    }
    *out = bg;
    return kSuccess;
}

// ---- the frame ------------------------------------------------------------------------------

class RenderPassEncoder {
public:
    /// The pass the host is recording (the UI's, for an inline custom draw). `End` leaves it.
    static RenderPassEncoder Wrap(const Device&, ID3D12GraphicsCommandList* list, std::uint32_t width, std::uint32_t height) {
        return RenderPassEncoder(list, width, height, false);
    }
    void SetPipeline(const RenderPipeline& p) {
        list_->SetGraphicsRootSignature(p.root);
        list_->SetPipelineState(p.pso);
        list_->IASetPrimitiveTopology(p.topology);
        std::copy_n(p.strides, detail::kMaxVertexBuffers, strides_);
    }
    template <std::uint32_t G>
    void SetBindGroup(std::uint32_t index, const BindGroup<G>& group) {
        assert(index == G && "bind group made for another @group");
        (void)index;
        list_->SetDescriptorHeaps(2, group.heaps);
        if (group.resourceParam != ~0u) list_->SetGraphicsRootDescriptorTable(group.resourceParam, group.resources);
        if (group.samplerParam != ~0u) list_->SetGraphicsRootDescriptorTable(group.samplerParam, group.samplers);
    }
    void SetVertexBuffer(std::uint32_t slot, const Buffer& buffer, std::uint64_t offset = 0) {
        const D3D12_VERTEX_BUFFER_VIEW view{buffer.address + offset, UINT(buffer.size - offset), strides_[slot]};
        list_->IASetVertexBuffers(slot, 1, &view);
    }
    void SetIndexBuffer(const Buffer& buffer, IndexFormat format, std::uint64_t offset = 0) {
        const D3D12_INDEX_BUFFER_VIEW view{buffer.address + offset, UINT(buffer.size - offset),
                                           format == IndexFormat::Uint16 ? DXGI_FORMAT_R16_UINT : DXGI_FORMAT_R32_UINT};
        list_->IASetIndexBuffer(&view);
    }
    void SetViewport(float x, float y, float w, float h, float minDepth, float maxDepth) {
        const D3D12_VIEWPORT v{x, y, w, h, minDepth, maxDepth};
        list_->RSSetViewports(1, &v);
    }
    void SetScissorRect(std::uint32_t x, std::uint32_t y, std::uint32_t w, std::uint32_t h) {
        assert(x + w <= width_ && y + h <= height_);
        const D3D12_RECT r{LONG(x), LONG(y), LONG(x + w), LONG(y + h)};
        list_->RSSetScissorRects(1, &r);
    }
    void SetBlendConstant(const Color& c) {
        const FLOAT k[4] = {FLOAT(c.r), FLOAT(c.g), FLOAT(c.b), FLOAT(c.a)};
        list_->OMSetBlendFactor(k);
    }
    void Draw(std::uint32_t vertexCount, std::uint32_t instanceCount = 1, std::uint32_t firstVertex = 0, std::uint32_t firstInstance = 0) {
        list_->DrawInstanced(vertexCount, instanceCount, firstVertex, firstInstance);
    }
    void DrawIndexed(std::uint32_t indexCount, std::uint32_t instanceCount = 1, std::uint32_t firstIndex = 0, std::int32_t baseVertex = 0,
                     std::uint32_t firstInstance = 0) {
        list_->DrawIndexedInstanced(indexCount, instanceCount, firstIndex, baseVertex, firstInstance);
    }
    /// Resolves multisampled attachments and returns every attachment to its resting state. A
    /// wrapped pass is the host's.
    void End() {
        if (!owned_) return;
        for (std::uint32_t i = 0; i < count_; ++i) {
            const TextureView& a = attachments_[i].view;
            if (attachments_[i].resolve) {
                const TextureView& r = *attachments_[i].resolve;
                const D3D12_RESOURCE_BARRIER to[2] = {detail::transition(a.resource, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_RESOLVE_SOURCE),
                                                      detail::transition(r.resource, r.resting, D3D12_RESOURCE_STATE_RESOLVE_DEST)};
                list_->ResourceBarrier(2, to);
                list_->ResolveSubresource(r.resource, 0, a.resource, 0, detail::dxgiFormat(a.format));
                const D3D12_RESOURCE_BARRIER back[2] = {detail::transition(a.resource, D3D12_RESOURCE_STATE_RESOLVE_SOURCE, D3D12_RESOURCE_STATE_RENDER_TARGET),
                                                        detail::transition(r.resource, D3D12_RESOURCE_STATE_RESOLVE_DEST, r.resting)};
                list_->ResourceBarrier(2, back);
            }
            if (a.resting != D3D12_RESOURCE_STATE_RENDER_TARGET) {
                const D3D12_RESOURCE_BARRIER b = detail::transition(a.resource, D3D12_RESOURCE_STATE_RENDER_TARGET, a.resting);
                list_->ResourceBarrier(1, &b);
            }
        }
        owned_ = false;
    }
    ID3D12GraphicsCommandList* Get() const { return list_; }

private:
    friend class CommandEncoder;
    RenderPassEncoder(ID3D12GraphicsCommandList* list, std::uint32_t w, std::uint32_t h, bool owned) : list_(list), width_(w), height_(h), owned_(owned) {}
    ID3D12GraphicsCommandList* list_;
    std::uint32_t width_, height_;
    bool owned_;
    struct Attachment {
        TextureView view;
        const TextureView* resolve;
    } attachments_[kMaxColorTargets] = {};
    std::uint32_t count_ = 0;
    std::uint32_t strides_[detail::kMaxVertexBuffers] = {};
};

class ComputePassEncoder {
public:
    void SetPipeline(const ComputePipeline& p) {
        list_->SetComputeRootSignature(p.root);
        list_->SetPipelineState(p.pso);
    }
    template <std::uint32_t G>
    void SetBindGroup(std::uint32_t index, const BindGroup<G>& group) {
        assert(index == G && "bind group made for another @group");
        (void)index;
        list_->SetDescriptorHeaps(2, group.heaps);
        if (group.resourceParam != ~0u) list_->SetComputeRootDescriptorTable(group.resourceParam, group.resources);
        if (group.samplerParam != ~0u) list_->SetComputeRootDescriptorTable(group.samplerParam, group.samplers);
    }
    void DispatchWorkgroups(std::uint32_t x, std::uint32_t y = 1, std::uint32_t z = 1) { list_->Dispatch(x, y, z); }
    /// One UAV barrier over every resource: the dispatches' writes before any later access.
    void End() {
        D3D12_RESOURCE_BARRIER b{};
        b.Type = D3D12_RESOURCE_BARRIER_TYPE_UAV;
        list_->ResourceBarrier(1, &b);
    }
    ID3D12GraphicsCommandList* Get() const { return list_; }

private:
    friend class CommandEncoder;
    explicit ComputePassEncoder(ID3D12GraphicsCommandList* list) : list_(list) {}
    ID3D12GraphicsCommandList* list_;
};

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

/// The draw phase of a frame: the host's command list. Made by `Upload::Finish`.
class CommandEncoder {
public:
    /// Moves the attachments to RENDER_TARGET, sets them, clears them when asked, and sets the
    /// viewport and scissor to the whole target. `End` moves them back.
    RenderPassEncoder BeginRenderPass(const RenderPassDescriptor& d) const {
        RenderPassEncoder p(list_, 0, 0, true);
        D3D12_CPU_DESCRIPTOR_HANDLE rtvs[kMaxColorTargets];
        D3D12_RESOURCE_BARRIER barriers[kMaxColorTargets];
        UINT nb = 0, i = 0;
        for (const RenderPassColorAttachment& a : d.colorAttachments) {
            rtvs[i] = a.view.rtv;
            if (a.view.resting != D3D12_RESOURCE_STATE_RENDER_TARGET) barriers[nb++] = detail::transition(a.view.resource, a.view.resting, D3D12_RESOURCE_STATE_RENDER_TARGET);
            p.attachments_[i] = {a.view, a.resolveTarget};
            p.width_ = a.view.width, p.height_ = a.view.height;
            ++i;
        }
        p.count_ = i;
        if (nb > 0) list_->ResourceBarrier(nb, barriers);
        list_->OMSetRenderTargets(p.count_, rtvs, FALSE, nullptr);
        for (const RenderPassColorAttachment& a : d.colorAttachments)
            if (a.loadOp == LoadOp::Clear) {
                const FLOAT c[4] = {FLOAT(a.clearValue.r), FLOAT(a.clearValue.g), FLOAT(a.clearValue.b), FLOAT(a.clearValue.a)};
                list_->ClearRenderTargetView(a.view.rtv, c, 0, nullptr);
            }
        p.SetViewport(0, 0, float(p.width_), float(p.height_), 0, 1);
        p.SetScissorRect(0, 0, p.width_, p.height_);
        return p;
    }
    ComputePassEncoder BeginComputePass() const { return ComputePassEncoder(list_); }
    ID3D12GraphicsCommandList* Get() const { return list_; }

private:
    friend class Upload;
    explicit CommandEncoder(ID3D12GraphicsCommandList* list) : list_(list) {}
    ID3D12GraphicsCommandList* list_;
};

/// The write phase: copies from the staging ring (the one given, else the device's), recorded
/// into the host's command list before any pass. `Finish` returns what it wrote to its resting
/// state.
class Upload {
public:
    Upload(const Device& d, ID3D12GraphicsCommandList* list, Staging* staging = nullptr)
        : list_(list), device_(d.device), staging_(staging ? staging : d.staging) {}
    void WriteBuffer(const Buffer& buffer, std::uint64_t offset, const void* data, std::size_t size) {
        assert(offset % 4 == 0 && size % 4 == 0 && offset + size <= buffer.size);
        const std::uint64_t at = staging_->Reserve(size, 4);
        assert(at != ~std::uint64_t(0) && "the staging ring is full");
        std::memcpy(staging_->buffer.mapped + at, data, size);
        // COMMON is promoted to COPY_DEST by the copy itself.
        list_->CopyBufferRegion(buffer.handle, offset, staging_->buffer.handle, at, size);
        Wrote(buffer.handle, D3D12_RESOURCE_STATE_COMMON);
    }
    bool WriteTexture(const Texture& t, const void* data, std::size_t, std::uint32_t bytesPerRow) {
        const D3D12_RESOURCE_DESC rd = detail::resourceDesc(t.resource);
        D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint;
        UINT64 total = 0;
        device_->GetCopyableFootprints(&rd, 0, 1, 0, &footprint, nullptr, nullptr, &total);
        const std::uint64_t at = staging_->Reserve(total, D3D12_TEXTURE_DATA_PLACEMENT_ALIGNMENT);
        if (at == ~std::uint64_t(0)) return false;
        const std::uint32_t row = t.width * detail::bytesPerPixel(t.format);
        for (std::uint32_t y = 0; y < t.height; ++y)
            std::memcpy(staging_->buffer.mapped + at + std::uint64_t(y) * footprint.Footprint.RowPitch, static_cast<const std::byte*>(data) + std::size_t(y) * bytesPerRow,
                        row);
        footprint.Offset = at;
        if (t.resting != D3D12_RESOURCE_STATE_COPY_DEST) {
            const D3D12_RESOURCE_BARRIER b = detail::transition(t.resource, t.resting, D3D12_RESOURCE_STATE_COPY_DEST);
            list_->ResourceBarrier(1, &b);
        }
        D3D12_TEXTURE_COPY_LOCATION to{};
        to.pResource = t.resource;
        to.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        D3D12_TEXTURE_COPY_LOCATION from{};
        from.pResource = staging_->buffer.handle;
        from.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
        from.PlacedFootprint = footprint;
        list_->CopyTextureRegion(&to, 0, 0, 0, &from, nullptr);
        Wrote(t.resource, t.resting);
        return true;
    }
    /// Textures are created in their resting state: nothing to do.
    void Prepare(const Texture&) {}
    /// Everything written returns from COPY_DEST to its resting state, in one barrier call.
    CommandEncoder Finish() && {
        D3D12_RESOURCE_BARRIER barriers[detail::kMaxUploadWrites];
        for (std::uint32_t i = 0; i < count_; ++i) barriers[i] = detail::transition(written_[i].resource, D3D12_RESOURCE_STATE_COPY_DEST, written_[i].after);
        if (count_ > 0) list_->ResourceBarrier(count_, barriers);
        return CommandEncoder(list_);
    }
    ID3D12GraphicsCommandList* Get() const { return list_; }

private:
    void Wrote(ID3D12Resource* resource, D3D12_RESOURCE_STATES after) {
        for (std::uint32_t i = 0; i < count_; ++i)
            if (written_[i].resource == resource) return;
        assert(count_ < detail::kMaxUploadWrites);
        written_[count_++] = {resource, after};
    }
    ID3D12GraphicsCommandList* list_;
    ID3D12Device* device_;
    Staging* staging_;
    struct {
        ID3D12Resource* resource;
        D3D12_RESOURCE_STATES after;
    } written_[detail::kMaxUploadWrites] = {};
    std::uint32_t count_ = 0;
};

} // namespace lcgf::gpu
