// lcgf/gpu/metal.hpp: lcgf_render.gpu for C++ on Metal. Included by lcgf/gpu.hpp when
// LCGF_GPU_METAL is defined.
//
// src/render/metal/gpu.zig, inline: WebGPU's object model projected onto Metal, message for
// message. A type is a plain struct of Metal objects with public fields (`pass.Get()` is the
// MTLRenderCommandEncoder, `buffer.handle` the MTLBuffer, as on the other back ends); an `id` here is Objective-C's, so it
// casts to metal-cpp's MTL:: types (or to an Objective-C object under ARC with __bridge) at no
// cost, and nothing here depends on either. The Objective-C runtime and Metal are opened at run
// time (`objc::Load`), as the Zig back end does, so the header builds on any host and a program
// without Metal fails to load it instead of failing to start.
//
// Bind groups are the Metal objects bound at the slots lcgf-gen gave naga's MSL (the shader's
// `metal` table): buffers, textures and samplers flat per kind in (group, binding) order, vertex
// buffers counted down from slot 30. SetBindGroup binds a group's objects to both stages.
// Runtime-sized storage arrays get their lengths through naga's `_buffer_sizes` slot before each
// draw or dispatch that needs them.
//
// Metal tracks hazards between encoders for the resources it creates, so the phases need no
// barriers: Upload is a blit encoder copying from the device's staging ring (queue-ordered,
// like WebGPU's writeBuffer), and each pass is its own encoder on the host's command buffer.
// Memory: each resource is its own allocation (a Device arena makes private storage, a Host
// arena shared and mapped); the arena is the projection's uniform interface.
//
// bindings/check/run.sh records this header's messages and the Zig projection's through a
// stand-in Objective-C runtime (bindings/check/objc_record.c) and requires the same log.
#pragma once
#include <algorithm>
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <type_traits>

#include <dlfcn.h>

#include "types.hpp"

namespace lcgf::gpu {

namespace objc {
using id = void*;
using SEL = void*;
using NSUInteger = std::uintptr_t;
using NSInteger = std::intptr_t;

/// libobjc's and Metal's entry points, once `Load` has opened them.
struct Runtime {
    void (*msgSend)() = nullptr;
    id (*getClass)(const char*) = nullptr;
    SEL (*registerName)(const char*) = nullptr;
    void* (*poolPush)() = nullptr;
    void (*poolPop)(void*) = nullptr;
    id (*createSystemDefaultDevice)() = nullptr;
    bool loaded = false;
};
inline Runtime runtime;

/// Where `Load` opens the runtime. The defaults are the system's; a null QuartzCore is skipped
/// (the projection itself needs no CAMetalLayer).
struct Paths {
    const char* objc = "/usr/lib/libobjc.A.dylib";
    const char* metal = "/System/Library/Frameworks/Metal.framework/Metal";
    const char* quartzCore = "/System/Library/Frameworks/QuartzCore.framework/QuartzCore";
};

/// Opens libobjc and Metal. Call once before anything else here; later calls return at once.
/// False off Apple platforms, or where a library or a function is missing.
inline bool Load(const Paths& p = {}) {
    if (runtime.loaded) return true;
    void* o = dlopen(p.objc, RTLD_NOW);
    void* m = dlopen(p.metal, RTLD_NOW);
    if (!o || !m || (p.quartzCore && !dlopen(p.quartzCore, RTLD_NOW))) return false;
    Runtime r;
    r.msgSend = reinterpret_cast<void (*)()>(dlsym(o, "objc_msgSend"));
    r.getClass = reinterpret_cast<id (*)(const char*)>(dlsym(o, "objc_getClass"));
    r.registerName = reinterpret_cast<SEL (*)(const char*)>(dlsym(o, "sel_registerName"));
    r.poolPush = reinterpret_cast<void* (*)()>(dlsym(o, "objc_autoreleasePoolPush"));
    r.poolPop = reinterpret_cast<void (*)(void*)>(dlsym(o, "objc_autoreleasePoolPop"));
    r.createSystemDefaultDevice = reinterpret_cast<id (*)()>(dlsym(m, "MTLCreateSystemDefaultDevice"));
    if (!r.msgSend || !r.getClass || !r.registerName || !r.poolPush || !r.poolPop || !r.createSystemDefaultDevice) return false;
    r.loaded = true;
    runtime = r;
    return true;
}

/// A selector name as a template argument, so each one is registered once (`Sel`).
template <std::size_t N>
struct Name {
    char s[N];
    consteval Name(const char (&a)[N]) { std::copy_n(a, N, s); }
};

/// One cache per selector: the cached path is one load.
template <Name N>
inline SEL Sel() {
    static const SEL s = runtime.registerName(N.s);
    return s;
}

/// Sends selector `N` to `target` with `args` and returns its `R`: objc_msgSend cast to the
/// call's C signature. Arguments are passed as their types are: pass NSUInteger, not int.
template <class R, Name N, class... A>
inline R Send(id target, A... args) {
    using F = R (*)(id, SEL, A...);
    return reinterpret_cast<F>(runtime.msgSend)(target, Sel<N>(), args...);
}

inline id Class(const char* name) { return runtime.getClass(name); }
inline void Release(id o) { Send<void, "release">(o); }
/// An autoreleased NSString with `s`'s bytes (UTF-8).
inline id String(const char* s) { return Send<id, "stringWithUTF8String:">(Class("NSString"), s); }

/// An autorelease pool for its scope: objects that methods return without new, alloc or copy
/// in their names live until it pops.
class Pool {
public:
    Pool() : token_(runtime.poolPush()) {}
    ~Pool() { runtime.poolPop(token_); }
    Pool(const Pool&) = delete;
    Pool& operator=(const Pool&) = delete;

private:
    void* token_;
};
} // namespace objc

using objc::id;
using objc::NSUInteger;

/// What creation reports. `kSuccess` is the one every back end has.
enum class Result : std::uint32_t { Success,
                                    ShaderCompile,
                                    MissingEntryPoint,
                                    PipelineFailed,
                                    ResourceFailed,
                                    NoCode,
                                    NoStaging,
                                    OutOfArena,
                                    IncompatibleMemory };
inline constexpr Result kSuccess = Result::Success;

namespace detail {
struct MTLViewport {
    double x, y, width, height, znear, zfar;
};
struct MTLScissorRect {
    NSUInteger x, y, width, height;
};
struct MTLSize {
    NSUInteger width, height, depth;
};
struct MTLOrigin {
    NSUInteger x = 0, y = 0, z = 0;
};
struct MTLClearColor {
    double r, g, b, a;
};
inline constexpr NSUInteger kStorageShared = 0, kStoragePrivate = 2 << 4;
inline constexpr std::uint32_t kMaxSized = 8, kMaxBindings = 16;
inline constexpr NSUInteger vertexBufferSlot(std::uint32_t slot) { return 30 - slot; }
} // namespace detail

struct Staging;

/// The host's MTLDevice. Set `staging` before the first Upload that is given none.
struct Device {
    id device;
    Staging* staging = nullptr;
    static Device Wrap(id device) { return {device}; }
};

struct Buffer {
    id handle;
    std::uint64_t size;
    /// Set in a Host arena (shared storage).
    std::byte* mapped = nullptr;
};

struct TextureView {
    id texture;
    std::uint32_t width, height, samples = 1;
    TextureFormat format = TextureFormat::RGBA8Unorm;
};

struct Texture {
    id texture;
    TextureFormat format;
    std::uint32_t width, height, samples = 1;
    TextureView CreateView() const { return {texture, width, height, samples, format}; }
};

struct Sampler {
    id handle;
};

/// A pipeline and what its passes need from its shader: the primitive, cull mode and winding
/// the encoder is set to, and its runtime-sized arrays.
struct RenderPipeline {
    id state;
    NSUInteger primitive, cull, winding;
    std::uint32_t sized, sizesSlot;
};
struct ComputePipeline {
    id state;
    std::uint32_t threads[3];
    std::uint32_t sized, sizesSlot;
};
template <class S>
struct RenderPipelineOf : RenderPipeline {
    using Shader = S;
};
template <class S>
struct ComputePipelineOf : ComputePipeline {
    using Shader = S;
};

/// A group's Metal objects in binding order, with their slots and buffers' sizes.
template <std::uint32_t G>
struct BindGroup {
    struct Entry {
        id object;
        BindingKind kind;
        std::uint32_t slot, sized;
        std::uint64_t size;
    };
    Entry entries[detail::kMaxBindings];
    std::uint32_t count = 0;
    static constexpr std::uint32_t index = G;
};

/// One resource of a bind group, as a generated `GroupN::Resources()` lists them.
struct Resource {
    std::uint32_t binding;
    BindingKind kind;
    id object;
    std::uint64_t size = 0;
};
inline Resource BufferResource(std::uint32_t binding, BindingKind kind, const Buffer& b) { return {binding, kind, b.handle, b.size}; }
inline Resource ViewResource(std::uint32_t binding, BindingKind kind, const TextureView& v) { return {binding, kind, v.texture}; }
inline Resource SamplerResource(std::uint32_t binding, BindingKind kind, const Sampler& s) { return {binding, kind, s.handle}; }

struct Arena {
    MemoryKind kind = MemoryKind::Device;
};
inline Result CreateArena(const Device&, std::uint64_t, MemoryKind kind, std::uint32_t, Arena* out) {
    out->kind = kind;
    return kSuccess;
}
inline void DestroyArena(const Device&, Arena&) {}

inline Result CreateBuffer(const Device& d, Arena& arena, const BufferDescriptor& desc, Buffer* out) {
    const bool shared = arena.kind == MemoryKind::Host;
    const id b = objc::Send<id, "newBufferWithLength:options:">(d.device, NSUInteger(std::max<std::uint64_t>(desc.size, 4)),
                                                                shared ? detail::kStorageShared : detail::kStoragePrivate);
    if (!b) return Result::ResourceFailed;
    *out = {b, desc.size, shared ? static_cast<std::byte*>(objc::Send<void*, "contents">(b)) : nullptr};
    return kSuccess;
}
inline void DestroyBuffer(const Device&, const Buffer& b) { objc::Release(b.handle); }

/// A shared buffer the frame's writes copy from, on the queue. One per frame in flight;
/// `Rewind` it when that frame's previous use has completed.
struct Staging {
    Buffer buffer{nullptr, 0};
    std::uint64_t used = 0;
    void Rewind() { used = 0; }
    /// Copies `bytes` in at `alignment`; its offset, or ~0 when it does not fit.
    std::uint64_t Push(const void* data, std::size_t size, std::uint64_t alignment) {
        const std::uint64_t at = (used + alignment - 1) & ~(alignment - 1);
        if (at + size > buffer.size) return ~std::uint64_t(0);
        std::memcpy(buffer.mapped + at, data, size);
        used = at + size;
        return at;
    }
};
inline Result CreateStaging(const Device& d, Arena& host, std::uint64_t bytes, Staging* out) {
    if (host.kind != MemoryKind::Host) return Result::IncompatibleMemory;
    *out = {};
    return CreateBuffer(d, host, {bytes, BufferUsage::CopySrc}, &out->buffer);
}

namespace detail {
inline NSUInteger pixelFormat(TextureFormat f) {
    constexpr NSUInteger t[] = {10, 30, 70, 71, 80, 81, 25, 115, 55, 105, 125, 53, 252};
    return t[std::uint32_t(f)];
}
inline NSUInteger vertexFormat(VertexFormat f) {
    constexpr NSUInteger t[] = {28, 29, 30, 31, 36, 37, 39, 32, 9};
    return t[std::uint32_t(f)];
}
inline NSUInteger blendFactor(BlendFactor f) {
    constexpr NSUInteger t[] = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12};
    return t[std::uint32_t(f)];
}
inline NSUInteger addressMode(AddressMode a) {
    constexpr NSUInteger t[] = {0, 2, 3};
    return t[std::uint32_t(a)];
}
inline id compile(id device, const char* msl) {
    id err = nullptr;
    const id lib = objc::Send<id, "newLibraryWithSource:options:error:">(device, objc::String(msl), id(nullptr), &err);
    if (!lib && err) std::fprintf(stderr, "lcgf/gpu.hpp (Metal): compiling MSL: %s\n",
                                  objc::Send<const char*, "UTF8String">(objc::Send<id, "localizedDescription">(err)));
    return lib;
}
/// An entry point by its WGSL name, or by naga's rename of it (`main` is `main_` in MSL).
inline id function(id library, const char* name) {
    if (const id f = objc::Send<id, "newFunctionWithName:">(library, objc::String(name))) return f;
    char buf[128];
    const std::size_t n = std::strlen(name);
    if (n + 2 > sizeof buf) return nullptr;
    std::memcpy(buf, name, n);
    buf[n] = '_';
    buf[n + 1] = 0;
    return objc::Send<id, "newFunctionWithName:">(library, objc::String(buf));
}
inline void failed(const char* what, id err) {
    std::fprintf(stderr, "lcgf/gpu.hpp (Metal): creating %s: %s\n", what,
                 err ? objc::Send<const char*, "UTF8String">(objc::Send<id, "localizedDescription">(err)) : "no error object");
}
} // namespace detail

inline Result CreateTexture(const Device& d, Arena&, const TextureDescriptor& desc, Texture* out) {
    const id td = objc::Send<id, "texture2DDescriptorWithPixelFormat:width:height:mipmapped:">(
        objc::Class("MTLTextureDescriptor"), detail::pixelFormat(desc.format), NSUInteger(desc.width), NSUInteger(desc.height), bool(desc.mipLevelCount > 1));
    NSUInteger usage = 0;
    if (desc.usage & TextureUsage::TextureBinding) usage |= 1;
    if (desc.usage & TextureUsage::StorageBinding) usage |= 1 | 2;
    if (desc.usage & TextureUsage::RenderAttachment) usage |= 4;
    objc::Send<void, "setUsage:">(td, usage);
    objc::Send<void, "setStorageMode:">(td, NSUInteger(2)); // private: the GPU's alone
    if (desc.sampleCount > 1) {
        objc::Send<void, "setTextureType:">(td, NSUInteger(4)); // MTLTextureType2DMultisample
        objc::Send<void, "setSampleCount:">(td, NSUInteger(desc.sampleCount));
    }
    const id t = objc::Send<id, "newTextureWithDescriptor:">(d.device, td);
    if (!t) return Result::ResourceFailed;
    *out = {t, desc.format, desc.width, desc.height, desc.sampleCount};
    return kSuccess;
}
inline void DestroyTexture(const Device&, const Texture& t) { objc::Release(t.texture); }

inline Result CreateSampler(const Device& d, const SamplerDescriptor& desc, Sampler* out) {
    const id sd = objc::Send<id, "new">(objc::Class("MTLSamplerDescriptor"));
    objc::Send<void, "setMinFilter:">(sd, NSUInteger(desc.minFilter == FilterMode::Linear));
    objc::Send<void, "setMagFilter:">(sd, NSUInteger(desc.magFilter == FilterMode::Linear));
    objc::Send<void, "setMipFilter:">(sd, NSUInteger(desc.mipmapFilter == FilterMode::Linear ? 2 : 1));
    objc::Send<void, "setSAddressMode:">(sd, detail::addressMode(desc.addressModeU));
    objc::Send<void, "setTAddressMode:">(sd, detail::addressMode(desc.addressModeV));
    objc::Send<void, "setRAddressMode:">(sd, detail::addressMode(desc.addressModeW));
    objc::Send<void, "setLodMinClamp:">(sd, desc.lodMinClamp);
    objc::Send<void, "setLodMaxClamp:">(sd, desc.lodMaxClamp);
    out->handle = objc::Send<id, "newSamplerStateWithDescriptor:">(d.device, sd);
    objc::Release(sd);
    return out->handle ? kSuccess : Result::ResourceFailed;
}
inline void DestroySampler(const Device&, const Sampler& s) { objc::Release(s.handle); }

/// A pipeline for shader `S` from the MSL lcgf-gen gave it slots in.
template <class S>
Result CreateRenderPipeline(const Device& d, const RenderPipelineDescriptor& desc, RenderPipelineOf<S>* out) {
    if constexpr (!requires { S::msl; }) {
        return Result::NoCode; // build the shader with --msl (CMake: LCGF_GPU=METAL)
    } else {
        objc::Pool pool;
        const id library = detail::compile(d.device, S::msl.data());
        if (!library) return Result::ShaderCompile;
        const id vs = detail::function(library, desc.vertex.entryPoint);
        if (!vs) {
            objc::Release(library);
            return Result::MissingEntryPoint;
        }
        const id pd = objc::Send<id, "new">(objc::Class("MTLRenderPipelineDescriptor"));
        objc::Send<void, "setVertexFunction:">(pd, vs);
        Result r = kSuccess;
        if (desc.fragment) {
            if (const id fs = detail::function(library, desc.fragment->entryPoint)) {
                objc::Send<void, "setFragmentFunction:">(pd, fs);
                objc::Release(fs);
            } else {
                r = Result::MissingEntryPoint;
            }
        }
        if (r == kSuccess) {
            objc::Send<void, "setRasterSampleCount:">(pd, NSUInteger(desc.multisample.count));
            objc::Send<void, "setAlphaToCoverageEnabled:">(pd, desc.multisample.alphaToCoverageEnabled);
            const id vd = objc::Send<id, "vertexDescriptor">(objc::Class("MTLVertexDescriptor"));
            const id attributes = objc::Send<id, "attributes">(vd);
            const id layouts = objc::Send<id, "layouts">(vd);
            std::uint32_t slot = 0;
            for (const VertexBufferLayout& vb : desc.vertex.buffers) {
                const NSUInteger index = detail::vertexBufferSlot(slot++);
                for (const VertexAttribute& a : vb.attributes) {
                    const id at = objc::Send<id, "objectAtIndexedSubscript:">(attributes, NSUInteger(a.shaderLocation));
                    objc::Send<void, "setFormat:">(at, detail::vertexFormat(a.format));
                    objc::Send<void, "setOffset:">(at, NSUInteger(a.offset));
                    objc::Send<void, "setBufferIndex:">(at, index);
                }
                const id layout = objc::Send<id, "objectAtIndexedSubscript:">(layouts, index);
                objc::Send<void, "setStride:">(layout, NSUInteger(vb.arrayStride));
                objc::Send<void, "setStepFunction:">(layout, NSUInteger(vb.stepMode == VertexStepMode::Instance ? 2 : 1));
                objc::Send<void, "setStepRate:">(layout, NSUInteger(1));
            }
            objc::Send<void, "setVertexDescriptor:">(pd, vd);
            const id colors = objc::Send<id, "colorAttachments">(pd);
            if (desc.fragment) {
                NSUInteger i = 0;
                for (const ColorTargetState& t : desc.fragment->targets) {
                    const id color = objc::Send<id, "objectAtIndexedSubscript:">(colors, i++);
                    objc::Send<void, "setPixelFormat:">(color, detail::pixelFormat(t.format));
                    // WebGPU's mask is red 1 ... alpha 8; Metal's is alpha 1 ... red 8.
                    const std::uint32_t m = t.writeMask;
                    objc::Send<void, "setWriteMask:">(color, NSUInteger((m >> 3 & 1) | (m >> 2 & 1) << 1 | (m >> 1 & 1) << 2 | (m & 1) << 3));
                    if (t.blend) {
                        const BlendState& b = *t.blend;
                        objc::Send<void, "setBlendingEnabled:">(color, true);
                        objc::Send<void, "setSourceRGBBlendFactor:">(color, detail::blendFactor(b.color.srcFactor));
                        objc::Send<void, "setDestinationRGBBlendFactor:">(color, detail::blendFactor(b.color.dstFactor));
                        objc::Send<void, "setRgbBlendOperation:">(color, NSUInteger(b.color.operation)); // same order as WebGPU
                        objc::Send<void, "setSourceAlphaBlendFactor:">(color, detail::blendFactor(b.alpha.srcFactor));
                        objc::Send<void, "setDestinationAlphaBlendFactor:">(color, detail::blendFactor(b.alpha.dstFactor));
                        objc::Send<void, "setAlphaBlendOperation:">(color, NSUInteger(b.alpha.operation));
                    }
                }
            }
            id err = nullptr;
            const id state = objc::Send<id, "newRenderPipelineStateWithDescriptor:error:">(d.device, pd, &err);
            if (state) {
                constexpr NSUInteger primitive[] = {0, 1, 2, 3, 4};
                *out = {};
                out->state = state;
                out->primitive = primitive[std::uint32_t(desc.primitive.topology)];
                out->cull = NSUInteger(desc.primitive.cullMode);
                out->winding = desc.primitive.frontFace == FrontFace::CCW; // MTLWindingCounterClockwise = 1
                out->sized = S::metal.sized;
                out->sizesSlot = S::metal.sizesSlot;
            } else {
                detail::failed("a pipeline", err);
                r = Result::PipelineFailed;
            }
        }
        objc::Release(pd);
        objc::Release(vs);
        objc::Release(library);
        return r;
    }
}

template <class S>
Result CreateComputePipeline(const Device& d, const ComputePipelineDescriptor& desc, ComputePipelineOf<S>* out) {
    if constexpr (!requires { S::msl; }) {
        return Result::NoCode;
    } else {
        objc::Pool pool;
        const id library = detail::compile(d.device, S::msl.data());
        if (!library) return Result::ShaderCompile;
        const id cs = detail::function(library, desc.entryPoint);
        if (!cs) {
            objc::Release(library);
            return Result::MissingEntryPoint;
        }
        id err = nullptr;
        const id state = objc::Send<id, "newComputePipelineStateWithFunction:error:">(d.device, cs, &err);
        if (!state) detail::failed("a compute pipeline", err);
        else *out = {{state, {S::metal.workgroup[0], S::metal.workgroup[1], S::metal.workgroup[2]}, S::metal.sized, S::metal.sizesSlot}};
        objc::Release(cs);
        objc::Release(library);
        return state ? kSuccess : Result::PipelineFailed;
    }
}

template <class P>
void DestroyPipeline(const Device&, const P& p) {
    objc::Release(p.state);
}

/// A bind group for `group` (a generated GroupN of the pipeline's shader): its objects, at the
/// slots the shader's MSL has them.
template <class P, class G>
    requires std::is_same_v<typename P::Shader, typename G::Shader>
Result CreateBindGroup(const Device&, Arena&, const P&, const G& group, BindGroup<G::index>* out) {
    using S = typename P::Shader;
    const auto rs = group.Resources();
    const auto layout = S::metal.groups[G::index];
    out->count = std::uint32_t(rs.size());
    for (std::size_t i = 0; i < rs.size(); ++i) {
        out->entries[i] = {rs[i].object, layout[i].kind, layout[i].slot, layout[i].sized, rs[i].size};
    }
    return kSuccess;
}

// ---- the frame ------------------------------------------------------------------------------

namespace detail {
/// The lengths of the bound runtime-sized arrays, for naga's `_buffer_sizes`.
struct Sizes {
    std::uint32_t lengths[kMaxSized] = {};
    std::uint32_t count = 0, slot = 0;
    template <std::uint32_t G>
    void Take(const BindGroup<G>& g) {
        for (std::uint32_t i = 0; i < g.count; ++i)
            if (g.entries[i].sized < kMaxSized) lengths[g.entries[i].sized] = std::uint32_t(g.entries[i].size);
    }
};
} // namespace detail

class RenderPassEncoder {
public:
    /// The pass the host is encoding (the UI's, for an inline custom draw). `End` leaves it.
    static RenderPassEncoder Wrap(const Device&, id encoder, std::uint32_t width, std::uint32_t height) {
        return RenderPassEncoder(encoder, width, height, false);
    }
    void SetPipeline(const RenderPipeline& p) {
        objc::Send<void, "setRenderPipelineState:">(encoder_, p.state);
        objc::Send<void, "setCullMode:">(encoder_, p.cull);
        objc::Send<void, "setFrontFacingWinding:">(encoder_, p.winding);
        objc::Send<void, "setTriangleFillMode:">(encoder_, NSUInteger(0));
        primitive_ = p.primitive;
        sizes_.count = p.sized;
        sizes_.slot = p.sizesSlot;
    }
    template <std::uint32_t G>
    void SetBindGroup(std::uint32_t index, const BindGroup<G>& group) {
        assert(index == G && "bind group made for another @group");
        (void)index;
        for (std::uint32_t i = 0; i < group.count; ++i) {
            const auto& e = group.entries[i];
            const NSUInteger slot = e.slot;
            switch (e.kind) {
            case BindingKind::Uniform:
            case BindingKind::StorageRead:
            case BindingKind::StorageReadWrite:
                objc::Send<void, "setVertexBuffer:offset:atIndex:">(encoder_, e.object, NSUInteger(0), slot);
                objc::Send<void, "setFragmentBuffer:offset:atIndex:">(encoder_, e.object, NSUInteger(0), slot);
                break;
            case BindingKind::Texture:
            case BindingKind::StorageTexture:
                objc::Send<void, "setVertexTexture:atIndex:">(encoder_, e.object, slot);
                objc::Send<void, "setFragmentTexture:atIndex:">(encoder_, e.object, slot);
                break;
            case BindingKind::Sampler:
            case BindingKind::ComparisonSampler:
                objc::Send<void, "setVertexSamplerState:atIndex:">(encoder_, e.object, slot);
                objc::Send<void, "setFragmentSamplerState:atIndex:">(encoder_, e.object, slot);
                break;
            }
        }
        sizes_.Take(group);
    }
    void SetVertexBuffer(std::uint32_t slot, const Buffer& buffer, std::uint64_t offset = 0) {
        objc::Send<void, "setVertexBuffer:offset:atIndex:">(encoder_, buffer.handle, NSUInteger(offset), detail::vertexBufferSlot(slot));
    }
    void SetIndexBuffer(const Buffer& buffer, IndexFormat format, std::uint64_t offset = 0) {
        index_ = {buffer.handle, NSUInteger(format == IndexFormat::Uint32), offset, format == IndexFormat::Uint16 ? 2u : 4u};
    }
    void SetViewport(float x, float y, float w, float h, float minDepth, float maxDepth) {
        objc::Send<void, "setViewport:">(encoder_, detail::MTLViewport{x, y, w, h, minDepth, maxDepth});
    }
    void SetScissorRect(std::uint32_t x, std::uint32_t y, std::uint32_t w, std::uint32_t h) {
        assert(x + w <= width_ && y + h <= height_);
        objc::Send<void, "setScissorRect:">(encoder_, detail::MTLScissorRect{x, y, w, h});
    }
    void SetBlendConstant(const Color& c) {
        objc::Send<void, "setBlendColorRed:green:blue:alpha:">(encoder_, float(c.r), float(c.g), float(c.b), float(c.a));
    }
    void Draw(std::uint32_t vertexCount, std::uint32_t instanceCount = 1, std::uint32_t firstVertex = 0, std::uint32_t firstInstance = 0) {
        PushSizes();
        objc::Send<void, "drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:">(
            encoder_, primitive_, NSUInteger(firstVertex), NSUInteger(vertexCount), NSUInteger(instanceCount), NSUInteger(firstInstance));
    }
    void DrawIndexed(std::uint32_t indexCount, std::uint32_t instanceCount = 1, std::uint32_t firstIndex = 0, std::int32_t baseVertex = 0,
                     std::uint32_t firstInstance = 0) {
        PushSizes();
        objc::Send<void, "drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:baseVertex:baseInstance:">(
            encoder_, primitive_, NSUInteger(indexCount), index_.type, index_.buffer, NSUInteger(index_.offset + std::uint64_t(firstIndex) * index_.size),
            NSUInteger(instanceCount), objc::NSInteger(baseVertex), NSUInteger(firstInstance));
    }
    /// Ends an encoder the projection began. A wrapped pass is the host's.
    void End() {
        if (!owned_) return;
        objc::Send<void, "endEncoding">(encoder_);
        owned_ = false;
    }
    id Get() const { return encoder_; }

private:
    friend class CommandEncoder;
    RenderPassEncoder(id encoder, std::uint32_t w, std::uint32_t h, bool owned) : encoder_(encoder), width_(w), height_(h), owned_(owned) {}
    void PushSizes() {
        if (sizes_.count == 0) return;
        const NSUInteger n = sizes_.count * 4;
        objc::Send<void, "setVertexBytes:length:atIndex:">(encoder_, static_cast<const void*>(sizes_.lengths), n, NSUInteger(sizes_.slot));
        objc::Send<void, "setFragmentBytes:length:atIndex:">(encoder_, static_cast<const void*>(sizes_.lengths), n, NSUInteger(sizes_.slot));
    }
    id encoder_;
    std::uint32_t width_, height_;
    bool owned_;
    NSUInteger primitive_ = 3;
    struct {
        id buffer = nullptr;
        NSUInteger type = 0;
        std::uint64_t offset = 0;
        std::uint32_t size = 2;
    } index_;
    detail::Sizes sizes_;
};

class ComputePassEncoder {
public:
    void SetPipeline(const ComputePipeline& p) {
        objc::Send<void, "setComputePipelineState:">(encoder_, p.state);
        std::copy_n(p.threads, 3, threads_);
        sizes_.count = p.sized;
        sizes_.slot = p.sizesSlot;
    }
    template <std::uint32_t G>
    void SetBindGroup(std::uint32_t index, const BindGroup<G>& group) {
        assert(index == G && "bind group made for another @group");
        (void)index;
        for (std::uint32_t i = 0; i < group.count; ++i) {
            const auto& e = group.entries[i];
            const NSUInteger slot = e.slot;
            switch (e.kind) {
            case BindingKind::Uniform:
            case BindingKind::StorageRead:
            case BindingKind::StorageReadWrite: objc::Send<void, "setBuffer:offset:atIndex:">(encoder_, e.object, NSUInteger(0), slot); break;
            case BindingKind::Texture:
            case BindingKind::StorageTexture: objc::Send<void, "setTexture:atIndex:">(encoder_, e.object, slot); break;
            case BindingKind::Sampler:
            case BindingKind::ComparisonSampler: objc::Send<void, "setSamplerState:atIndex:">(encoder_, e.object, slot); break;
            }
        }
        sizes_.Take(group);
    }
    void DispatchWorkgroups(std::uint32_t x, std::uint32_t y = 1, std::uint32_t z = 1) {
        if (sizes_.count > 0)
            objc::Send<void, "setBytes:length:atIndex:">(encoder_, static_cast<const void*>(sizes_.lengths), NSUInteger(sizes_.count * 4), NSUInteger(sizes_.slot));
        objc::Send<void, "dispatchThreadgroups:threadsPerThreadgroup:">(encoder_, detail::MTLSize{x, y, z},
                                                                        detail::MTLSize{threads_[0], threads_[1], threads_[2]});
    }
    void End() { objc::Send<void, "endEncoding">(encoder_); }
    id Get() const { return encoder_; }

private:
    friend class CommandEncoder;
    explicit ComputePassEncoder(id encoder) : encoder_(encoder) {}
    id encoder_;
    std::uint32_t threads_[3] = {1, 1, 1};
    detail::Sizes sizes_;
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

/// The draw phase of a frame: the host's command buffer. Made by `Upload::Finish`.
class CommandEncoder {
public:
    RenderPassEncoder BeginRenderPass(const RenderPassDescriptor& d) const;
    ComputePassEncoder BeginComputePass() const { return ComputePassEncoder(objc::Send<id, "computeCommandEncoder">(cmd_)); }
    id Get() const { return cmd_; }

private:
    friend class Upload;
    explicit CommandEncoder(id cmd) : cmd_(cmd) {}
    id cmd_;
};

inline RenderPassEncoder CommandEncoder::BeginRenderPass(const RenderPassDescriptor& d) const {
    const id rp = objc::Send<id, "renderPassDescriptor">(objc::Class("MTLRenderPassDescriptor"));
    const id colors = objc::Send<id, "colorAttachments">(rp);
    std::uint32_t w = 0, h = 0;
    NSUInteger i = 0;
    for (const RenderPassColorAttachment& a : d.colorAttachments) {
        const id color = objc::Send<id, "objectAtIndexedSubscript:">(colors, i++);
        objc::Send<void, "setTexture:">(color, a.view.texture);
        objc::Send<void, "setLoadAction:">(color, NSUInteger(a.loadOp == LoadOp::Clear ? 2 : 1));
        const bool store = a.storeOp == StoreOp::Store;
        objc::Send<void, "setStoreAction:">(color, NSUInteger(a.resolveTarget ? (store ? 3 : 2) : (store ? 1 : 0)));
        if (a.resolveTarget) objc::Send<void, "setResolveTexture:">(color, a.resolveTarget->texture);
        objc::Send<void, "setClearColor:">(color, detail::MTLClearColor{a.clearValue.r, a.clearValue.g, a.clearValue.b, a.clearValue.a});
        w = a.view.width, h = a.view.height;
    }
    return RenderPassEncoder(objc::Send<id, "renderCommandEncoderWithDescriptor:">(cmd_, rp), w, h, true);
}

/// The write phase: a blit encoder on the host's command buffer, copying from the staging ring
/// (the one given, else the device's). Made on the first write; `Finish` ends it.
class Upload {
public:
    Upload(const Device& d, id cmd, Staging* staging = nullptr) : cmd_(cmd), staging_(staging ? staging : d.staging) {}
    void WriteBuffer(const Buffer& buffer, std::uint64_t offset, const void* data, std::size_t size) {
        assert(offset % 4 == 0 && size % 4 == 0 && offset + size <= buffer.size);
        const std::uint64_t at = staging_->Push(data, size, 4);
        assert(at != ~std::uint64_t(0) && "the staging ring is full");
        objc::Send<void, "copyFromBuffer:sourceOffset:toBuffer:destinationOffset:size:">(Encoder(), staging_->buffer.handle, NSUInteger(at), buffer.handle,
                                                                                         NSUInteger(offset), NSUInteger(size));
    }
    bool WriteTexture(const Texture& t, const void* data, std::size_t size, std::uint32_t bytesPerRow) {
        const std::uint64_t at = staging_->Push(data, size, 256);
        if (at == ~std::uint64_t(0)) return false;
        objc::Send<void,
                   "copyFromBuffer:sourceOffset:sourceBytesPerRow:sourceBytesPerImage:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:">(
            Encoder(), staging_->buffer.handle, NSUInteger(at), NSUInteger(bytesPerRow), NSUInteger(size), detail::MTLSize{t.width, t.height, 1}, t.texture,
            NSUInteger(0), NSUInteger(0), detail::MTLOrigin{});
        return true;
    }
    void Prepare(const Texture&) {}
    CommandEncoder Finish() && {
        if (blit_) objc::Send<void, "endEncoding">(blit_);
        return CommandEncoder(cmd_);
    }
    id Get() const { return cmd_; }

private:
    id Encoder() {
        if (!blit_) blit_ = objc::Send<id, "blitCommandEncoder">(cmd_);
        return blit_;
    }
    id cmd_;
    Staging* staging_;
    id blit_ = nullptr;
};

} // namespace lcgf::gpu
