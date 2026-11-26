// lcgf/gpu/gles.hpp: lcgf_render.gpu for C++, shaped like Dawn's webgpu_cpp.h, on GL ES 3.
// Included by lcgf/gpu.hpp when LCGF_GPU_GLES is defined.
//
// src/render/gles/gpu.zig, inline: WebGPU's object model projected onto GL ES. A type is the
// GL names it stands for, with public fields (`buffer.handle` is the buffer name); a call is
// the gl* calls it stands for, through the function table you load (GlFns::Load). GL ES has
// neither bind groups nor command buffers, so a render pass is the current context, a pipeline
// is a program plus the fixed-function state it sets, and SetBindGroup replays the binding
// table lcgf-gen wrote from the shader's reflection (GlesBinding): one glBindBufferRange,
// glActiveTexture/glBindTexture/glBindSampler or glBindImageTexture per binding.
//
// Binding points are flat per kind, in (group, binding) order: the k-th uniform buffer of the
// shader is uniform block binding k, the k-th texture is texture unit k (src/render/gpu/naga.zig
// numbers them; lcgf-gen writes storage block and image bindings into naga's GLSL).
//
// Y: naga flips clip-space y for GL, so a row's index in GL memory is its index from the top in
// WebGPU. Scissor rects, viewports, texture uploads and readback use rows from the top.
//
// No GL header is needed: the GL types below are Khronos's, so names and function pointers
// pass to and from the host's own GL code unchanged.
#pragma once
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <span>
#include <type_traits>
#include <utility>

#include "types.hpp"

namespace lcgf::gpu {

namespace gl {
using Enum = unsigned int;
using Uint = unsigned int;
using Int = int;
using Sizei = int;
using Boolean = unsigned char;
using Bitfield = unsigned int;
using Float = float;
using Intptr = std::intptr_t;
using Sizeiptr = std::intptr_t;
using Char = char;

// The enums the projection uses (Khronos's values).
inline constexpr Enum kTexture2D = 0x0DE1, kTextureMinFilter = 0x2801, kTextureMagFilter = 0x2800, kTextureWrapS = 0x2802,
                      kTextureWrapT = 0x2803, kTextureWrapR = 0x8072, kNearest = 0x2600, kLinear = 0x2601,
                      kNearestMipmapNearest = 0x2700, kLinearMipmapNearest = 0x2701, kNearestMipmapLinear = 0x2702,
                      kLinearMipmapLinear = 0x2703, kClampToEdge = 0x812F, kRepeat = 0x2901, kMirroredRepeat = 0x8370,
                      kTextureMinLod = 0x813A, kTextureMaxLod = 0x813B, kFramebuffer = 0x8D40, kReadFramebuffer = 0x8CA8,
                      kDrawFramebuffer = 0x8CA9, kRenderbuffer = 0x8D41, kColorAttachment0 = 0x8CE0, kFramebufferComplete = 0x8CD5,
                      kArrayBuffer = 0x8892, kElementArrayBuffer = 0x8893, kUniformBuffer = 0x8A11, kShaderStorageBuffer = 0x90D2,
                      kCopyReadBuffer = 0x8F36, kCopyWriteBuffer = 0x8F37, kDynamicDraw = 0x88E8, kMapReadBit = 0x0001,
                      kUnpackAlignment = 0x0CF5, kUnpackRowLength = 0x0CF2, kPackAlignment = 0x0D05, kVertexShader = 0x8B31,
                      kFragmentShader = 0x8B30, kComputeShader = 0x91B9, kCompileStatus = 0x8B81, kLinkStatus = 0x8B82,
                      kTexture0 = 0x84C0, kScissorTest = 0x0C11, kBlend = 0x0BE2, kCullFace = 0x0B44, kDepthTest = 0x0B71,
                      kStencilTest = 0x0B90, kDither = 0x0BD0, kFront = 0x0404, kBack = 0x0405, kCW = 0x0900, kCCW = 0x0901,
                      kPrimitiveRestartFixedIndex = 0x8D69, kSampleAlphaToCoverage = 0x809E, kColorBufferBit = 0x4000,
                      kPoints = 0x0000, kLines = 0x0001, kLineStrip = 0x0003, kTriangles = 0x0004, kTriangleStrip = 0x0005,
                      kFloat = 0x1406, kUnsignedByte = 0x1401, kUnsignedShort = 0x1403, kUnsignedInt = 0x1405, kInt = 0x1404,
                      kHalfFloat = 0x140B, kRGBA = 0x1908, kRed = 0x1903, kRG = 0x8227, kRedInteger = 0x8D94,
                      kDepthComponent = 0x1902, kFuncAdd = 0x8006, kInvalidIndex = 0xFFFFFFFF, kNoError = 0;
inline constexpr Bitfield kAllBarrierBits = 0xFFFFFFFF;
} // namespace gl

/// The GL ES entry points the projection calls, loaded once from the host's context. The 3.1
/// ones (compute, images) stay null on a 3.0 context.
struct GlFns {
#define LCGF_GL_30(X) \
    X(void, GenBuffers, (gl::Sizei n, gl::Uint * b)) \
    X(void, DeleteBuffers, (gl::Sizei n, const gl::Uint* b)) \
    X(void, BindBuffer, (gl::Enum t, gl::Uint b)) \
    X(void, BufferData, (gl::Enum t, gl::Sizeiptr n, const void* d, gl::Enum u)) \
    X(void, BufferSubData, (gl::Enum t, gl::Intptr o, gl::Sizeiptr n, const void* d)) \
    X(void*, MapBufferRange, (gl::Enum t, gl::Intptr o, gl::Sizeiptr n, gl::Bitfield a)) \
    X(gl::Boolean, UnmapBuffer, (gl::Enum t)) \
    X(void, BindBufferRange, (gl::Enum t, gl::Uint i, gl::Uint b, gl::Intptr o, gl::Sizeiptr n)) \
    X(void, GenTextures, (gl::Sizei n, gl::Uint * t)) \
    X(void, DeleteTextures, (gl::Sizei n, const gl::Uint* t)) \
    X(void, BindTexture, (gl::Enum t, gl::Uint x)) \
    X(void, ActiveTexture, (gl::Enum u)) \
    X(void, TexStorage2D, (gl::Enum t, gl::Sizei l, gl::Enum f, gl::Sizei w, gl::Sizei h)) \
    X(void, TexSubImage2D, (gl::Enum t, gl::Int l, gl::Int x, gl::Int y, gl::Sizei w, gl::Sizei h, gl::Enum f, gl::Enum ty, const void* p)) \
    X(void, TexParameteri, (gl::Enum t, gl::Enum p, gl::Int v)) \
    X(void, PixelStorei, (gl::Enum p, gl::Int v)) \
    X(void, ReadPixels, (gl::Int x, gl::Int y, gl::Sizei w, gl::Sizei h, gl::Enum f, gl::Enum t, void* p)) \
    X(void, GenSamplers, (gl::Sizei n, gl::Uint * s)) \
    X(void, DeleteSamplers, (gl::Sizei n, const gl::Uint* s)) \
    X(void, BindSampler, (gl::Uint u, gl::Uint s)) \
    X(void, SamplerParameteri, (gl::Uint s, gl::Enum p, gl::Int v)) \
    X(void, SamplerParameterf, (gl::Uint s, gl::Enum p, gl::Float v)) \
    X(void, GenRenderbuffers, (gl::Sizei n, gl::Uint * r)) \
    X(void, DeleteRenderbuffers, (gl::Sizei n, const gl::Uint* r)) \
    X(void, BindRenderbuffer, (gl::Enum t, gl::Uint r)) \
    X(void, RenderbufferStorageMultisample, (gl::Enum t, gl::Sizei s, gl::Enum f, gl::Sizei w, gl::Sizei h)) \
    X(void, GenFramebuffers, (gl::Sizei n, gl::Uint * f)) \
    X(void, DeleteFramebuffers, (gl::Sizei n, const gl::Uint* f)) \
    X(void, BindFramebuffer, (gl::Enum t, gl::Uint f)) \
    X(void, FramebufferTexture2D, (gl::Enum t, gl::Enum a, gl::Enum tt, gl::Uint x, gl::Int l)) \
    X(void, FramebufferRenderbuffer, (gl::Enum t, gl::Enum a, gl::Enum rt, gl::Uint r)) \
    X(gl::Enum, CheckFramebufferStatus, (gl::Enum t)) \
    X(void, BlitFramebuffer, (gl::Int a, gl::Int b, gl::Int c, gl::Int d, gl::Int e, gl::Int f, gl::Int g, gl::Int h, gl::Bitfield m, gl::Enum fl)) \
    X(gl::Uint, CreateShader, (gl::Enum t)) \
    X(void, ShaderSource, (gl::Uint s, gl::Sizei n, const gl::Char* const* src, const gl::Int* len)) \
    X(void, CompileShader, (gl::Uint s)) \
    X(void, GetShaderiv, (gl::Uint s, gl::Enum p, gl::Int * v)) \
    X(void, GetShaderInfoLog, (gl::Uint s, gl::Sizei n, gl::Sizei * len, gl::Char * log)) \
    X(void, DeleteShader, (gl::Uint s)) \
    X(gl::Uint, CreateProgram, ()) \
    X(void, AttachShader, (gl::Uint p, gl::Uint s)) \
    X(void, LinkProgram, (gl::Uint p)) \
    X(void, GetProgramiv, (gl::Uint p, gl::Enum n, gl::Int * v)) \
    X(void, GetProgramInfoLog, (gl::Uint p, gl::Sizei n, gl::Sizei * len, gl::Char * log)) \
    X(void, DeleteProgram, (gl::Uint p)) \
    X(void, UseProgram, (gl::Uint p)) \
    X(gl::Uint, GetUniformBlockIndex, (gl::Uint p, const gl::Char* n)) \
    X(void, UniformBlockBinding, (gl::Uint p, gl::Uint i, gl::Uint b)) \
    X(gl::Int, GetUniformLocation, (gl::Uint p, const gl::Char* n)) \
    X(void, Uniform1i, (gl::Int l, gl::Int v)) \
    X(void, GenVertexArrays, (gl::Sizei n, gl::Uint * a)) \
    X(void, DeleteVertexArrays, (gl::Sizei n, const gl::Uint* a)) \
    X(void, BindVertexArray, (gl::Uint a)) \
    X(void, EnableVertexAttribArray, (gl::Uint i)) \
    X(void, VertexAttribPointer, (gl::Uint i, gl::Int n, gl::Enum t, gl::Boolean norm, gl::Sizei s, const void* p)) \
    X(void, VertexAttribIPointer, (gl::Uint i, gl::Int n, gl::Enum t, gl::Sizei s, const void* p)) \
    X(void, VertexAttribDivisor, (gl::Uint i, gl::Uint d)) \
    X(void, Enable, (gl::Enum c)) \
    X(void, Disable, (gl::Enum c)) \
    X(void, BlendFuncSeparate, (gl::Enum a, gl::Enum b, gl::Enum c, gl::Enum d)) \
    X(void, BlendEquationSeparate, (gl::Enum a, gl::Enum b)) \
    X(void, BlendColor, (gl::Float r, gl::Float g, gl::Float b, gl::Float a)) \
    X(void, ColorMask, (gl::Boolean r, gl::Boolean g, gl::Boolean b, gl::Boolean a)) \
    X(void, CullFace, (gl::Enum m)) \
    X(void, FrontFace, (gl::Enum m)) \
    X(void, Viewport, (gl::Int x, gl::Int y, gl::Sizei w, gl::Sizei h)) \
    X(void, Scissor, (gl::Int x, gl::Int y, gl::Sizei w, gl::Sizei h)) \
    X(void, ClearColor, (gl::Float r, gl::Float g, gl::Float b, gl::Float a)) \
    X(void, Clear, (gl::Bitfield m)) \
    X(void, DrawArraysInstanced, (gl::Enum m, gl::Int f, gl::Sizei n, gl::Sizei i)) \
    X(void, DrawElementsInstanced, (gl::Enum m, gl::Sizei n, gl::Enum t, const void* o, gl::Sizei i)) \
    X(gl::Enum, GetError, ()) \
    X(void, Finish, ())
#define LCGF_GL_31(X) \
    X(void, DispatchCompute, (gl::Uint x, gl::Uint y, gl::Uint z)) \
    X(void, MemoryBarrier, (gl::Bitfield b)) \
    X(void, BindImageTexture, (gl::Uint u, gl::Uint t, gl::Int l, gl::Boolean la, gl::Int ly, gl::Enum a, gl::Enum f))
#define LCGF_GL_FIELD(R, N, A) R(*N) A = nullptr;
    LCGF_GL_30(LCGF_GL_FIELD)
    LCGF_GL_31(LCGF_GL_FIELD)
#undef LCGF_GL_FIELD

    /// Loads every entry point through `get` (eglGetProcAddress, SDL_GL_GetProcAddress, ...).
    /// False when a GL ES 3.0 one is missing; the 3.1 ones may be.
    template <class Get>
    bool Load(Get&& get) {
        bool ok = true;
#define LCGF_GL_LOAD(R, N, A) ok = (N = reinterpret_cast<R(*) A>(get("gl" #N))) != nullptr && ok;
#define LCGF_GL_LOAD_OPT(R, N, A) N = reinterpret_cast<R(*) A>(get("gl" #N));
        LCGF_GL_30(LCGF_GL_LOAD)
        LCGF_GL_31(LCGF_GL_LOAD_OPT)
#undef LCGF_GL_LOAD
#undef LCGF_GL_LOAD_OPT
        return ok;
    }
    bool HasCompute() const { return DispatchCompute != nullptr && MemoryBarrier != nullptr && BindImageTexture != nullptr; }
};

/// What creation reports. `kSuccess` is the one every back end has.
enum class Result : std::uint32_t { Success,
                                    CompileFailed,
                                    LinkFailed,
                                    UnsupportedFormat,
                                    IncompleteFramebuffer,
                                    NoCompute,
                                    NoCode };
inline constexpr Result kSuccess = Result::Success;

/// The host's current GL ES context: its function table.
struct Device {
    const GlFns* fns;
};

struct Buffer {
    gl::Uint handle;
    std::uint64_t size;
    /// Always null on GL ES: read results back with ReadBuffer.
    std::byte* mapped = nullptr;
};

struct TextureView {
    gl::Uint texture;
    /// The framebuffer that draws into it, if it is a render attachment.
    gl::Uint fbo = 0;
    std::uint32_t width, height, samples = 1;
    TextureFormat format = TextureFormat::RGBA8Unorm;
};

struct Texture {
    gl::Uint handle, renderbuffer, fbo;
    TextureFormat format;
    std::uint32_t width, height, samples = 1;
    TextureView CreateView() const { return {handle, fbo, width, height, samples, format}; }
};

struct Sampler {
    gl::Uint handle;
};

namespace detail {
struct GlVertexBuffer {
    std::uint32_t stride;
    bool instance;
    std::uint8_t first, count;
};
struct GlAttribute {
    std::uint32_t location;
    VertexFormat format;
    std::uint32_t offset;
};
inline constexpr std::uint32_t kMaxVertexBuffers = 8, kMaxVertexAttributes = 16;
} // namespace detail

struct RenderPipeline {
    gl::Uint program, vao;
    gl::Enum mode;
    detail::GlVertexBuffer buffers[detail::kMaxVertexBuffers]{};
    std::uint8_t bufferCount = 0;
    detail::GlAttribute attributes[detail::kMaxVertexAttributes]{};
    std::uint8_t attributeCount = 0;
    CullMode cull = CullMode::None;
    bool frontCCW = true, restart = false, alphaToCoverage = false, hasBlend = false;
    BlendState blend{};
    std::uint32_t writeMask = 0xf;
};
struct ComputePipeline {
    gl::Uint program;
};
template <class S>
struct RenderPipelineOf : RenderPipeline {
    using Shader = S;
};
template <class S>
struct ComputePipelineOf : ComputePipeline {
    using Shader = S;
};

/// The GL names of a group's resources in binding order, the sizes of its buffers, and the
/// shader's binding table for the group.
template <std::uint32_t G>
struct BindGroup {
    gl::Uint names[16];
    std::uint64_t sizes[16];
    std::span<const GlesBinding> table;
    static constexpr std::uint32_t index = G;
};

/// One resource of a bind group, as a generated `GroupN::Resources()` lists them.
struct Resource {
    std::uint32_t binding;
    BindingKind kind;
    gl::Uint name = 0;
    std::uint64_t size = 0;
};
inline Resource BufferResource(std::uint32_t binding, BindingKind kind, const Buffer& b) { return {binding, kind, b.handle, b.size}; }
inline Resource ViewResource(std::uint32_t binding, BindingKind kind, const TextureView& v) { return {binding, kind, v.texture}; }
inline Resource SamplerResource(std::uint32_t binding, BindingKind kind, const Sampler& s) { return {binding, kind, s.handle}; }

/// GL allocates its own memory: an arena is only the projection's uniform interface.
struct Arena {};
inline Result CreateArena(const Device&, std::uint64_t, MemoryKind, std::uint32_t, Arena*) { return kSuccess; }
inline void DestroyArena(const Device&, Arena&) {}
/// GL uploads through the driver; staging exists for the uniform interface.
struct Staging {
    Buffer buffer{0, 0};
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
struct GlFormat {
    gl::Enum internal, format, type;
};
inline bool glFormat(TextureFormat f, GlFormat* out) {
    switch (f) {
    case TextureFormat::R8Unorm: *out = {0x8229, gl::kRed, gl::kUnsignedByte}; return true;
    case TextureFormat::RG8Unorm: *out = {0x822B, gl::kRG, gl::kUnsignedByte}; return true;
    case TextureFormat::RGBA8Unorm: *out = {0x8058, gl::kRGBA, gl::kUnsignedByte}; return true;
    case TextureFormat::RGBA8UnormSrgb: *out = {0x8C43, gl::kRGBA, gl::kUnsignedByte}; return true;
    case TextureFormat::R16Float: *out = {0x822D, gl::kRed, gl::kHalfFloat}; return true;
    case TextureFormat::RGBA16Float: *out = {0x881A, gl::kRGBA, gl::kHalfFloat}; return true;
    case TextureFormat::R32Float: *out = {0x822E, gl::kRed, gl::kFloat}; return true;
    case TextureFormat::RG32Float: *out = {0x8230, gl::kRG, gl::kFloat}; return true;
    case TextureFormat::RGBA32Float: *out = {0x8814, gl::kRGBA, gl::kFloat}; return true;
    case TextureFormat::R32Uint: *out = {0x8236, gl::kRedInteger, gl::kUnsignedInt}; return true;
    case TextureFormat::Depth32Float: *out = {0x8CAC, gl::kDepthComponent, gl::kFloat}; return true;
    default: return false; // GL ES has no BGRA storage
    }
}
inline gl::Enum blendFactor(BlendFactor f) {
    constexpr gl::Enum t[] = {0, 1, 0x0300, 0x0301, 0x0302, 0x0303, 0x0306, 0x0307, 0x0304, 0x0305, 0x8001, 0x8002};
    return t[std::uint32_t(f)];
}
inline gl::Enum blendOp(BlendOperation o) {
    constexpr gl::Enum t[] = {gl::kFuncAdd, 0x800A, 0x800B, 0x8007, 0x8008};
    return t[std::uint32_t(o)];
}
inline gl::Int wrapMode(AddressMode a) {
    constexpr gl::Int t[] = {gl::kClampToEdge, gl::kRepeat, gl::kMirroredRepeat};
    return t[std::uint32_t(a)];
}
inline gl::Enum drawMode(PrimitiveTopology t) {
    constexpr gl::Enum m[] = {gl::kPoints, gl::kLines, gl::kLineStrip, gl::kTriangles, gl::kTriangleStrip};
    return m[std::uint32_t(t)];
}

/// The bind calls of a group, from the shader's binding table.
template <std::uint32_t G>
inline void replay(const GlFns& f, const BindGroup<G>& g) {
    for (std::size_t i = 0; i < g.table.size(); ++i) {
        const GlesBinding& b = g.table[i];
        switch (b.kind) {
        case BindingKind::Uniform: f.BindBufferRange(gl::kUniformBuffer, b.unit, g.names[i], 0, gl::Sizeiptr(g.sizes[i])); break;
        case BindingKind::StorageRead:
        case BindingKind::StorageReadWrite: f.BindBufferRange(gl::kShaderStorageBuffer, b.unit, g.names[i], 0, gl::Sizeiptr(g.sizes[i])); break;
        case BindingKind::Texture:
            f.ActiveTexture(gl::kTexture0 + b.unit);
            f.BindTexture(gl::kTexture2D, g.names[i]);
            // The group's sampler on this texture's unit (lcgf-gen chose which).
            if (b.sampler != ~0u) f.BindSampler(b.unit, g.names[b.sampler]);
            break;
        case BindingKind::StorageTexture: f.BindImageTexture(b.unit, g.names[i], 0, 0, 0, b.access, b.format); break;
        case BindingKind::Sampler:
        case BindingKind::ComparisonSampler: break; // bound with their textures
        }
    }
}

inline gl::Uint compile(const GlFns& f, gl::Enum stage, const char* code, Result* r) {
    const gl::Uint s = f.CreateShader(stage);
    f.ShaderSource(s, 1, &code, nullptr);
    f.CompileShader(s);
    gl::Int ok = 0;
    f.GetShaderiv(s, gl::kCompileStatus, &ok);
    if (!ok) {
        char log[2048];
        gl::Sizei n = 0;
        f.GetShaderInfoLog(s, sizeof log, &n, log);
        std::fprintf(stderr, "lcgf::gpu (GL ES): compile failed: %.*s\n", int(n), log);
        f.DeleteShader(s);
        *r = Result::CompileFailed;
        return 0;
    }
    return s;
}

/// Links the stages and binds the shader's uniform blocks and sampler uniforms to their slots.
inline Result link(const GlFns& f, const GlesTable& t, std::span<const std::pair<gl::Enum, const char*>> stages, gl::Uint* out) {
    Result r = kSuccess;
    const gl::Uint p = f.CreateProgram();
    gl::Uint objects[2] = {0, 0};
    for (std::size_t i = 0; i < stages.size() && r == kSuccess; ++i) {
        objects[i] = compile(f, stages[i].first, stages[i].second, &r);
        if (objects[i]) f.AttachShader(p, objects[i]);
    }
    if (r == kSuccess) {
        f.LinkProgram(p);
        gl::Int ok = 0;
        f.GetProgramiv(p, gl::kLinkStatus, &ok);
        if (!ok) {
            char log[2048];
            gl::Sizei n = 0;
            f.GetProgramInfoLog(p, sizeof log, &n, log);
            std::fprintf(stderr, "lcgf::gpu (GL ES): link failed: %.*s\n", int(n), log);
            r = Result::LinkFailed;
        }
    }
    for (gl::Uint s : objects)
        if (s) f.DeleteShader(s);
    if (r != kSuccess) {
        f.DeleteProgram(p);
        return r;
    }
    f.UseProgram(p);
    for (const GlslName& b : t.blocks) {
        const gl::Uint i = f.GetUniformBlockIndex(p, b.name);
        if (i != gl::kInvalidIndex) f.UniformBlockBinding(p, i, b.slot);
    }
    for (const GlslName& u : t.textures) {
        const gl::Int loc = f.GetUniformLocation(p, u.name);
        if (loc >= 0) f.Uniform1i(loc, gl::Int(u.slot));
    }
    f.UseProgram(0);
    *out = p;
    return kSuccess;
}

template <class S>
inline const char* glslOf(const char* entry) {
    for (const GlslStage& s : S::glsl) {
        const char *a = s.entryPoint, *b = entry;
        while (*a && *a == *b) ++a, ++b;
        if (*a == *b) return s.code;
    }
    return nullptr;
}
} // namespace detail

// ---- the frame ------------------------------------------------------------------------------

/// A render pass: the current GL context, and the vertex layout of the bound pipeline (GL ES
/// 3.0 binds attribute formats together with buffers).
class RenderPassEncoder {
public:
    /// The pass the host is drawing in (the UI's, for an inline custom draw). `End` leaves it.
    static RenderPassEncoder Wrap(const Device& d, std::uint32_t width, std::uint32_t height) { return RenderPassEncoder(d.fns, width, height); }

    /// Program, vertex array, and the fixed-function state the pipeline describes.
    void SetPipeline(const RenderPipeline& p) {
        const GlFns& f = *f_;
#ifndef NDEBUG
        has_pipeline_ = true;
#endif
        f.UseProgram(p.program);
        f.BindVertexArray(p.vao);
        mode_ = p.mode;
        for (std::uint32_t i = 0; i < detail::kMaxVertexBuffers; ++i) buffers_[i] = p.buffers[i];
        for (std::uint32_t i = 0; i < detail::kMaxVertexAttributes; ++i) attributes_[i] = p.attributes[i];
        if (p.hasBlend) {
            f.Enable(gl::kBlend);
            f.BlendFuncSeparate(detail::blendFactor(p.blend.color.srcFactor), detail::blendFactor(p.blend.color.dstFactor),
                                detail::blendFactor(p.blend.alpha.srcFactor), detail::blendFactor(p.blend.alpha.dstFactor));
            f.BlendEquationSeparate(detail::blendOp(p.blend.color.operation), detail::blendOp(p.blend.alpha.operation));
        } else {
            f.Disable(gl::kBlend);
        }
        const std::uint32_t m = p.writeMask;
        f.ColorMask(m & 1, (m >> 1) & 1, (m >> 2) & 1, (m >> 3) & 1);
        if (p.cull == CullMode::None) {
            f.Disable(gl::kCullFace);
        } else {
            f.Enable(gl::kCullFace);
            f.CullFace(p.cull == CullMode::Front ? gl::kFront : gl::kBack);
        }
        // naga's y flip mirrors the image in GL's clip space, which reverses the winding GL sees.
        f.FrontFace(p.frontCCW ? gl::kCW : gl::kCCW);
        if (p.restart) f.Enable(gl::kPrimitiveRestartFixedIndex);
        else f.Disable(gl::kPrimitiveRestartFixedIndex);
        if (p.alphaToCoverage) f.Enable(gl::kSampleAlphaToCoverage);
        else f.Disable(gl::kSampleAlphaToCoverage);
        f.Disable(gl::kDepthTest);
        f.Disable(gl::kStencilTest);
        f.Disable(gl::kDither);
        f.Enable(gl::kScissorTest);
    }
    template <std::uint32_t G>
    void SetBindGroup(std::uint32_t index, const BindGroup<G>& group) {
        assert(index == G && "bind group made for another @group");
        (void)index;
        detail::replay(*f_, group);
    }
    void SetVertexBuffer(std::uint32_t slot, const Buffer& buffer, std::uint64_t offset = 0) {
        const GlFns& f = *f_;
        const detail::GlVertexBuffer vb = buffers_[slot];
        f.BindBuffer(gl::kArrayBuffer, buffer.handle);
        for (std::uint32_t k = 0; k < vb.count; ++k) {
            const detail::GlAttribute a = attributes_[vb.first + k];
            gl::Int n = 1;
            gl::Enum ty = gl::kFloat;
            bool integer = false, norm = false;
            switch (a.format) {
            case VertexFormat::Float32: break;
            case VertexFormat::Float32x2: n = 2; break;
            case VertexFormat::Float32x3: n = 3; break;
            case VertexFormat::Float32x4: n = 4; break;
            case VertexFormat::Uint32: ty = gl::kUnsignedInt, integer = true; break;
            case VertexFormat::Uint32x2: n = 2, ty = gl::kUnsignedInt, integer = true; break;
            case VertexFormat::Uint32x4: n = 4, ty = gl::kUnsignedInt, integer = true; break;
            case VertexFormat::Sint32: ty = gl::kInt, integer = true; break;
            case VertexFormat::Unorm8x4: n = 4, ty = gl::kUnsignedByte, norm = true; break;
            }
            const void* at = reinterpret_cast<const void*>(std::uintptr_t(offset + a.offset));
            f.EnableVertexAttribArray(a.location);
            if (integer)
                f.VertexAttribIPointer(a.location, n, ty, gl::Sizei(vb.stride), at);
            else
                f.VertexAttribPointer(a.location, n, ty, norm, gl::Sizei(vb.stride), at);
            f.VertexAttribDivisor(a.location, vb.instance ? 1 : 0);
        }
    }
    void SetIndexBuffer(const Buffer& buffer, IndexFormat format, std::uint64_t offset = 0) {
        f_->BindBuffer(gl::kElementArrayBuffer, buffer.handle);
        index_type_ = format == IndexFormat::Uint16 ? gl::kUnsignedShort : gl::kUnsignedInt;
        index_offset_ = offset;
    }
    void SetViewport(float x, float y, float width, float height, float, float) {
        f_->Viewport(gl::Int(x), gl::Int(y), gl::Sizei(width), gl::Sizei(height));
    }
    void SetScissorRect(std::uint32_t x, std::uint32_t y, std::uint32_t width, std::uint32_t height) {
        assert(x + width <= width_ && y + height <= height_ && "scissor outside the target");
        f_->Enable(gl::kScissorTest);
        f_->Scissor(gl::Int(x), gl::Int(y), gl::Sizei(width), gl::Sizei(height));
    }
    void SetBlendConstant(const Color& c) { f_->BlendColor(float(c.r), float(c.g), float(c.b), float(c.a)); }
    void Draw(std::uint32_t vertexCount, std::uint32_t instanceCount = 1, std::uint32_t firstVertex = 0, std::uint32_t firstInstance = 0) {
        assert(has_pipeline_ && firstInstance == 0 && "draw with no pipeline, or a first instance GL ES cannot draw");
        (void)firstInstance;
        f_->DrawArraysInstanced(mode_, gl::Int(firstVertex), gl::Sizei(vertexCount), gl::Sizei(instanceCount));
    }
    void DrawIndexed(std::uint32_t indexCount, std::uint32_t instanceCount = 1, std::uint32_t firstIndex = 0, std::int32_t baseVertex = 0,
                     std::uint32_t firstInstance = 0) {
        assert(has_pipeline_ && baseVertex == 0 && firstInstance == 0 && "GL ES 3.0 draws no base vertex or first instance");
        (void)baseVertex, (void)firstInstance;
        const std::uint64_t size = index_type_ == gl::kUnsignedShort ? 2 : 4;
        f_->DrawElementsInstanced(mode_, gl::Sizei(indexCount), index_type_, reinterpret_cast<const void*>(std::uintptr_t(index_offset_ + firstIndex * size)),
                                  gl::Sizei(instanceCount));
    }
    /// Ends a pass the projection began: resolves a multisampled target, unbinds the
    /// framebuffer. A wrapped pass is the host's.
    void End() {
        if (!owned_) return;
        if (resolve_to_) {
            f_->BindFramebuffer(gl::kReadFramebuffer, resolve_from_);
            f_->BindFramebuffer(gl::kDrawFramebuffer, resolve_to_);
            f_->BlitFramebuffer(0, 0, gl::Int(width_), gl::Int(height_), 0, 0, gl::Int(width_), gl::Int(height_), gl::kColorBufferBit, gl::kNearest);
        }
        f_->BindFramebuffer(gl::kFramebuffer, 0);
        owned_ = false;
    }
    const GlFns& Fns() const { return *f_; }

private:
    friend class CommandEncoder;
    RenderPassEncoder(const GlFns* f, std::uint32_t w, std::uint32_t h) : f_(f), width_(w), height_(h) {}
    const GlFns* f_;
    std::uint32_t width_, height_;
    bool owned_ = false;
    gl::Uint resolve_from_ = 0, resolve_to_ = 0;
    gl::Enum mode_ = gl::kTriangles, index_type_ = gl::kUnsignedShort;
    std::uint64_t index_offset_ = 0;
    detail::GlVertexBuffer buffers_[detail::kMaxVertexBuffers]{};
    detail::GlAttribute attributes_[detail::kMaxVertexAttributes]{};
#ifndef NDEBUG
    bool has_pipeline_ = false;
#else
    static constexpr bool has_pipeline_ = true;
#endif
};

class ComputePassEncoder {
public:
    void SetPipeline(const ComputePipeline& p) { f_->UseProgram(p.program); }
    template <std::uint32_t G>
    void SetBindGroup(std::uint32_t index, const BindGroup<G>& group) {
        assert(index == G && "bind group made for another @group");
        (void)index;
        detail::replay(*f_, group);
    }
    void DispatchWorkgroups(std::uint32_t x, std::uint32_t y = 1, std::uint32_t z = 1) { f_->DispatchCompute(x, y, z); }
    /// One barrier over every kind of access after the dispatches.
    void End() { f_->MemoryBarrier(gl::kAllBarrierBits); }

private:
    friend class CommandEncoder;
    explicit ComputePassEncoder(const GlFns* f) : f_(f) {}
    const GlFns* f_;
};

/// The draw phase of a frame. Made by `Upload::Finish`.
class CommandEncoder {
public:
    /// Draws into the first attachment's framebuffer (GL ES draws one colour target per
    /// framebuffer here); clears it when asked; viewport and scissor cover it.
    RenderPassEncoder BeginRenderPass(const RenderPassDescriptor& d) const {
        const RenderPassColorAttachment& a = d.colorAttachments[0];
        RenderPassEncoder p(f_, a.view.width, a.view.height);
        p.owned_ = true;
        f_->BindFramebuffer(gl::kFramebuffer, a.view.fbo);
        if (a.resolveTarget) p.resolve_from_ = a.view.fbo, p.resolve_to_ = a.resolveTarget->fbo;
        f_->Enable(gl::kScissorTest);
        p.SetViewport(0, 0, float(p.width_), float(p.height_), 0, 1);
        p.SetScissorRect(0, 0, p.width_, p.height_);
        if (a.loadOp == LoadOp::Clear) {
            f_->ColorMask(1, 1, 1, 1);
            f_->ClearColor(float(a.clearValue.r), float(a.clearValue.g), float(a.clearValue.b), float(a.clearValue.a));
            f_->Clear(gl::kColorBufferBit);
        }
        return p;
    }
    ComputePassEncoder BeginComputePass() const {
        assert(f_->HasCompute() && "compute needs GL ES 3.1");
        return ComputePassEncoder(f_);
    }

private:
    friend class Upload;
    explicit CommandEncoder(const GlFns* f) : f_(f) {}
    const GlFns* f_;
};

/// The write phase of a frame: GL orders writes itself, so these are direct calls in the
/// projection's shape. `Finish` returns the draw phase.
class Upload {
public:
    explicit Upload(const Device& d, Staging* = nullptr) : f_(d.fns) {}

    void WriteBuffer(const Buffer& buffer, std::uint64_t offset, const void* data, std::size_t size) {
        assert(offset % 4 == 0 && size % 4 == 0 && offset + size <= buffer.size);
        f_->BindBuffer(gl::kCopyWriteBuffer, buffer.handle);
        f_->BufferSubData(gl::kCopyWriteBuffer, gl::Intptr(offset), gl::Sizeiptr(size), data);
        f_->BindBuffer(gl::kCopyWriteBuffer, 0);
    }
    /// Replaces the whole first mip level of `t` with `data` (rows of `bytesPerRow`).
    bool WriteTexture(const Texture& t, const void* data, std::size_t, std::uint32_t bytesPerRow) {
        detail::GlFormat fmt;
        if (!detail::glFormat(t.format, &fmt)) return false;
        f_->BindTexture(gl::kTexture2D, t.handle);
        f_->PixelStorei(gl::kUnpackAlignment, 1);
        f_->PixelStorei(gl::kUnpackRowLength, gl::Int(bytesPerRow / detail::bytesPerPixel(t.format)));
        f_->TexSubImage2D(gl::kTexture2D, 0, 0, 0, gl::Sizei(t.width), gl::Sizei(t.height), fmt.format, fmt.type, data);
        f_->PixelStorei(gl::kUnpackRowLength, 0);
        return true;
    }
    void Prepare(const Texture&) {}
    CommandEncoder Finish() && { return CommandEncoder(f_); }

private:
    const GlFns* f_;
};

// ---- creation ---------------------------------------------------------------------------------

inline Result CreateBuffer(const Device& d, Arena&, const BufferDescriptor& desc, Buffer* out) {
    const GlFns& f = *d.fns;
    *out = {0, desc.size};
    f.GenBuffers(1, &out->handle);
    f.BindBuffer(gl::kCopyWriteBuffer, out->handle);
    f.BufferData(gl::kCopyWriteBuffer, gl::Sizeiptr(desc.size), nullptr, gl::kDynamicDraw);
    f.BindBuffer(gl::kCopyWriteBuffer, 0);
    return kSuccess;
}
inline void DestroyBuffer(const Device& d, const Buffer& b) { d.fns->DeleteBuffers(1, &b.handle); }

/// Copies `size` bytes of `b` from `offset` into `out`, waiting for the GPU (WebGPU's mapAsync
/// and getMappedRange, synchronous: the caller knows the writes are done).
inline void ReadBuffer(const Device& d, const Buffer& b, std::uint64_t offset, void* out, std::size_t size) {
    const GlFns& f = *d.fns;
    f.BindBuffer(gl::kCopyReadBuffer, b.handle);
    if (const void* p = f.MapBufferRange(gl::kCopyReadBuffer, gl::Intptr(offset), gl::Sizeiptr(size), gl::kMapReadBit))
        for (std::size_t i = 0; i < size; ++i) static_cast<std::byte*>(out)[i] = static_cast<const std::byte*>(p)[i];
    f.UnmapBuffer(gl::kCopyReadBuffer);
    f.BindBuffer(gl::kCopyReadBuffer, 0);
}

inline void DestroyTexture(const Device& d, const Texture& t) {
    if (t.fbo) d.fns->DeleteFramebuffers(1, &t.fbo);
    if (t.handle) d.fns->DeleteTextures(1, &t.handle);
    if (t.renderbuffer) d.fns->DeleteRenderbuffers(1, &t.renderbuffer);
}

inline Result CreateTexture(const Device& d, Arena&, const TextureDescriptor& desc, Texture* out) {
    const GlFns& f = *d.fns;
    detail::GlFormat fmt;
    if (!detail::glFormat(desc.format, &fmt)) return Result::UnsupportedFormat;
    Texture t{0, 0, 0, desc.format, desc.width, desc.height, desc.sampleCount};
    if (desc.sampleCount > 1) {
        // GL ES 3.0 multisamples only renderbuffers: a multisampled target is drawn and resolved.
        f.GenRenderbuffers(1, &t.renderbuffer);
        f.BindRenderbuffer(gl::kRenderbuffer, t.renderbuffer);
        f.RenderbufferStorageMultisample(gl::kRenderbuffer, gl::Sizei(desc.sampleCount), fmt.internal, gl::Sizei(desc.width), gl::Sizei(desc.height));
    } else {
        f.GenTextures(1, &t.handle);
        f.BindTexture(gl::kTexture2D, t.handle);
        f.TexStorage2D(gl::kTexture2D, gl::Sizei(desc.mipLevelCount), fmt.internal, gl::Sizei(desc.width), gl::Sizei(desc.height));
        // Complete without a sampler object; a bound sampler overrides these.
        f.TexParameteri(gl::kTexture2D, gl::kTextureMinFilter, gl::kNearest);
        f.TexParameteri(gl::kTexture2D, gl::kTextureMagFilter, gl::kNearest);
    }
    if (desc.usage & TextureUsage::RenderAttachment) {
        f.GenFramebuffers(1, &t.fbo);
        f.BindFramebuffer(gl::kFramebuffer, t.fbo);
        if (t.renderbuffer)
            f.FramebufferRenderbuffer(gl::kFramebuffer, gl::kColorAttachment0, gl::kRenderbuffer, t.renderbuffer);
        else
            f.FramebufferTexture2D(gl::kFramebuffer, gl::kColorAttachment0, gl::kTexture2D, t.handle, 0);
        const gl::Enum status = f.CheckFramebufferStatus(gl::kFramebuffer);
        f.BindFramebuffer(gl::kFramebuffer, 0);
        if (status != gl::kFramebufferComplete) {
            DestroyTexture(d, t);
            return Result::IncompleteFramebuffer;
        }
    }
    *out = t;
    return kSuccess;
}

inline Result CreateSampler(const Device& d, const SamplerDescriptor& desc, Sampler* out) {
    const GlFns& f = *d.fns;
    f.GenSamplers(1, &out->handle);
    const bool linear = desc.minFilter == FilterMode::Linear;
    const gl::Int min = desc.mipmapFilter == FilterMode::Linear ? (linear ? gl::kLinearMipmapLinear : gl::kNearestMipmapLinear)
                                                                : (linear ? gl::kLinearMipmapNearest : gl::kNearestMipmapNearest);
    f.SamplerParameteri(out->handle, gl::kTextureMinFilter, min);
    f.SamplerParameteri(out->handle, gl::kTextureMagFilter, desc.magFilter == FilterMode::Linear ? gl::kLinear : gl::kNearest);
    f.SamplerParameteri(out->handle, gl::kTextureWrapS, detail::wrapMode(desc.addressModeU));
    f.SamplerParameteri(out->handle, gl::kTextureWrapT, detail::wrapMode(desc.addressModeV));
    f.SamplerParameteri(out->handle, gl::kTextureWrapR, detail::wrapMode(desc.addressModeW));
    f.SamplerParameterf(out->handle, gl::kTextureMinLod, desc.lodMinClamp);
    f.SamplerParameterf(out->handle, gl::kTextureMaxLod, desc.lodMaxClamp);
    return kSuccess;
}
inline void DestroySampler(const Device& d, const Sampler& s) { d.fns->DeleteSamplers(1, &s.handle); }

/// A pipeline for shader `S` (lcgf-gen with --glsl): its program linked from naga's GLSL ES,
/// its vertex layout and the fixed-function state SetPipeline sets.
template <class S>
Result CreateRenderPipeline(const Device& d, const RenderPipelineDescriptor& desc, RenderPipelineOf<S>* out) {
    static_assert(requires { S::glsl; S::gles; }, "this shader has no GLSL ES: run lcgf-gen with --glsl (lcgf_add_shader with LCGF_GPU=GLES)");
    const GlFns& f = *d.fns;
    const FragmentState none{};
    const FragmentState& frag = desc.fragment ? *desc.fragment : none;
    const char* vs = detail::glslOf<S>(desc.vertex.entryPoint);
    const char* fs = detail::glslOf<S>(frag.entryPoint);
    if (!vs || !fs) return Result::NoCode;
    RenderPipelineOf<S> p{};
    p.mode = detail::drawMode(desc.primitive.topology);
    const std::pair<gl::Enum, const char*> stages[] = {{gl::kVertexShader, vs}, {gl::kFragmentShader, fs}};
    if (Result r = detail::link(f, S::gles, stages, &p.program); r != kSuccess) return r;
    f.GenVertexArrays(1, &p.vao);
    for (const VertexBufferLayout& vb : desc.vertex.buffers) {
        p.buffers[p.bufferCount++] = {std::uint32_t(vb.arrayStride), vb.stepMode == VertexStepMode::Instance, p.attributeCount,
                                      std::uint8_t(vb.attributes.size())};
        for (const VertexAttribute& a : vb.attributes) p.attributes[p.attributeCount++] = {a.shaderLocation, a.format, std::uint32_t(a.offset)};
    }
    p.cull = desc.primitive.cullMode;
    p.frontCCW = desc.primitive.frontFace == FrontFace::CCW;
    p.restart = desc.primitive.stripIndexFormat;
    p.alphaToCoverage = desc.multisample.alphaToCoverageEnabled;
    if (!frag.targets.empty()) {
        const ColorTargetState& t = frag.targets[0];
        p.hasBlend = t.blend != nullptr;
        if (t.blend) p.blend = *t.blend;
        p.writeMask = t.writeMask;
    }
    *out = p;
    return kSuccess;
}

template <class S>
Result CreateComputePipeline(const Device& d, const ComputePipelineDescriptor& desc, ComputePipelineOf<S>* out) {
    static_assert(requires { S::glsl; S::gles; }, "this shader has no GLSL ES: run lcgf-gen with --glsl (lcgf_add_shader with LCGF_GPU=GLES)");
    if (!d.fns->HasCompute()) return Result::NoCompute;
    const char* cs = detail::glslOf<S>(desc.entryPoint);
    if (!cs) return Result::NoCode;
    const std::pair<gl::Enum, const char*> stages[] = {{gl::kComputeShader, cs}};
    ComputePipelineOf<S> p{};
    if (Result r = detail::link(*d.fns, S::gles, stages, &p.program); r != kSuccess) return r;
    *out = p;
    return kSuccess;
}

template <class P>
void DestroyPipeline(const Device& d, const P& p) {
    d.fns->DeleteProgram(p.program);
    if constexpr (requires { p.vao; }) d.fns->DeleteVertexArrays(1, &p.vao);
}

/// A bind group for `group` (a generated GroupN of the pipeline's shader): the GL names to
/// bind, and the shader's binding table for the group.
template <class P, class G>
    requires std::is_same_v<typename P::Shader, typename G::Shader>
Result CreateBindGroup(const Device&, Arena&, const P&, const G& group, BindGroup<G::index>* out) {
    const auto rs = group.Resources();
    BindGroup<G::index> bg{};
    for (std::size_t i = 0; i < rs.size(); ++i) bg.names[i] = rs[i].name, bg.sizes[i] = rs[i].size;
    bg.table = G::Shader::gles.groups[G::index];
    *out = bg;
    return kSuccess;
}

} // namespace lcgf::gpu
