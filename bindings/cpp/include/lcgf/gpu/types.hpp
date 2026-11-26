// lcgf/gpu/types.hpp: the parts of lcgf::gpu every back end shares, shaped like Dawn's
// webgpu_cpp.h: formats, usages, descriptors, and what a shader brings as lcgf-gen writes it
// from WGSL. The back end (lcgf/gpu/vulkan.hpp, gles.hpp, wgpu.hpp) adds the handles and calls.
#pragma once
#include <cstddef>
#include <cstdint>
#include <span>

namespace lcgf::gpu {

enum class TextureFormat : std::uint32_t {
    R8Unorm,
    RG8Unorm,
    RGBA8Unorm,
    RGBA8UnormSrgb,
    BGRA8Unorm,
    BGRA8UnormSrgb,
    R16Float,
    RGBA16Float,
    R32Float,
    RG32Float,
    RGBA32Float,
    R32Uint,
    Depth32Float,
};
enum class LoadOp : std::uint32_t { Load,
                                    Clear };
enum class StoreOp : std::uint32_t { Store,
                                     Discard };
enum class IndexFormat : std::uint32_t { Uint16,
                                         Uint32 };
enum class BindingKind : std::uint32_t { Uniform,
                                         StorageRead,
                                         StorageReadWrite,
                                         Texture,
                                         StorageTexture,
                                         Sampler,
                                         ComparisonSampler };

struct Color {
    double r = 0, g = 0, b = 0, a = 0;
};

inline constexpr std::uint32_t kMaxGroups = 4, kMaxColorTargets = 4;

/// One binding of a group, as lcgf-gen reflects it from WGSL.
struct BindingLayout {
    std::uint32_t binding;
    BindingKind kind;
};

namespace detail {
inline constexpr std::uint32_t bytesPerPixel(TextureFormat f) {
    constexpr std::uint32_t table[] = {1, 2, 4, 4, 4, 4, 2, 8, 4, 8, 16, 4, 4};
    return table[std::uint32_t(f)];
}
} // namespace detail

enum class BufferUsage : std::uint32_t {
    None = 0,
    MapRead = 1,
    MapWrite = 2,
    CopySrc = 4,
    CopyDst = 8,
    Index = 16,
    Vertex = 32,
    Uniform = 64,
    Storage = 128,
    Indirect = 256,
};
enum class TextureUsage : std::uint32_t { None = 0,
                                          CopySrc = 1,
                                          CopyDst = 2,
                                          TextureBinding = 4,
                                          StorageBinding = 8,
                                          RenderAttachment = 16 };
constexpr BufferUsage operator|(BufferUsage a, BufferUsage b) { return BufferUsage(std::uint32_t(a) | std::uint32_t(b)); }
constexpr TextureUsage operator|(TextureUsage a, TextureUsage b) { return TextureUsage(std::uint32_t(a) | std::uint32_t(b)); }
constexpr bool operator&(BufferUsage a, BufferUsage b) { return (std::uint32_t(a) & std::uint32_t(b)) != 0; }
constexpr bool operator&(TextureUsage a, TextureUsage b) { return (std::uint32_t(a) & std::uint32_t(b)) != 0; }

enum class MemoryKind : std::uint32_t { Device,
                                        Host };
enum class FilterMode : std::uint32_t { Nearest,
                                        Linear };
enum class AddressMode : std::uint32_t { ClampToEdge,
                                         Repeat,
                                         MirrorRepeat };
enum class VertexFormat : std::uint32_t { Float32,
                                          Float32x2,
                                          Float32x3,
                                          Float32x4,
                                          Uint32,
                                          Uint32x2,
                                          Uint32x4,
                                          Sint32,
                                          Unorm8x4 };
enum class VertexStepMode : std::uint32_t { Vertex,
                                            Instance };
enum class PrimitiveTopology : std::uint32_t { PointList,
                                               LineList,
                                               LineStrip,
                                               TriangleList,
                                               TriangleStrip };
enum class FrontFace : std::uint32_t { CCW,
                                       CW };
enum class CullMode : std::uint32_t { None,
                                      Front,
                                      Back };
enum class BlendFactor : std::uint32_t { Zero,
                                         One,
                                         Src,
                                         OneMinusSrc,
                                         SrcAlpha,
                                         OneMinusSrcAlpha,
                                         Dst,
                                         OneMinusDst,
                                         DstAlpha,
                                         OneMinusDstAlpha,
                                         Constant,
                                         OneMinusConstant };
enum class BlendOperation : std::uint32_t { Add,
                                            Subtract,
                                            ReverseSubtract,
                                            Min,
                                            Max };

struct BufferDescriptor {
    std::uint64_t size;
    BufferUsage usage;
};
struct TextureDescriptor {
    std::uint32_t width, height;
    TextureFormat format = TextureFormat::RGBA8Unorm;
    TextureUsage usage = TextureUsage::TextureBinding;
    std::uint32_t mipLevelCount = 1, sampleCount = 1;
};
struct SamplerDescriptor {
    AddressMode addressModeU = AddressMode::ClampToEdge, addressModeV = AddressMode::ClampToEdge, addressModeW = AddressMode::ClampToEdge;
    FilterMode magFilter = FilterMode::Nearest, minFilter = FilterMode::Nearest, mipmapFilter = FilterMode::Nearest;
    float lodMinClamp = 0, lodMaxClamp = 32;
};
struct VertexAttribute {
    VertexFormat format;
    std::uint64_t offset;
    std::uint32_t shaderLocation;
};
struct VertexBufferLayout {
    std::uint64_t arrayStride;
    VertexStepMode stepMode = VertexStepMode::Vertex;
    std::span<const VertexAttribute> attributes;
};
struct BlendComponent {
    BlendOperation operation = BlendOperation::Add;
    BlendFactor srcFactor = BlendFactor::One, dstFactor = BlendFactor::Zero;
};
struct BlendState {
    BlendComponent color, alpha;
    /// What the UI draws with: premultiplied colour over what is there.
    static constexpr BlendComponent kPremultiplied{BlendOperation::Add, BlendFactor::One, BlendFactor::OneMinusSrcAlpha};
};
inline constexpr BlendState kPremultipliedBlend{BlendState::kPremultiplied, BlendState::kPremultiplied};
struct ColorTargetState {
    TextureFormat format;
    const BlendState* blend = nullptr; // null replaces what is there
    std::uint32_t writeMask = 0xf;
};
struct VertexState {
    const char* entryPoint = "vs";
    std::span<const VertexBufferLayout> buffers;
};
struct FragmentState {
    const char* entryPoint = "fs";
    std::span<const ColorTargetState> targets;
};
struct PrimitiveState {
    PrimitiveTopology topology = PrimitiveTopology::TriangleList;
    bool stripIndexFormat = false;
    FrontFace frontFace = FrontFace::CCW;
    CullMode cullMode = CullMode::None;
};
struct MultisampleState {
    std::uint32_t count = 1, mask = 0xffffffffu;
    bool alphaToCoverageEnabled = false;
};
struct RenderPipelineDescriptor {
    VertexState vertex{};
    const FragmentState* fragment = nullptr;
    PrimitiveState primitive{};
    MultisampleState multisample{};
};
struct ComputePipelineDescriptor {
    const char* entryPoint = "main";
};

// ---- GL ES: what a shader brings for it -----------------------------------------------------

/// One entry point's GLSL ES, as naga wrote it with LCGF's bindings added (src/render/gpu/naga.zig).
struct GlslStage {
    const char* entryPoint;
    const char* code;
};

/// A name in the GLSL and the binding point or texture unit it gets after linking.
struct GlslName {
    const char* name;
    std::uint32_t slot;
};

/// How a binding is bound on GL ES: its binding point or unit, the sampler of its group a
/// texture is sampled with (its index in the group, or ~0u), a storage texture's format and
/// access (GL enums).
struct GlesBinding {
    BindingKind kind;
    std::uint32_t unit, sampler, format, access;
};

/// The binding table GL ES replays: per group its bindings, and the names bound after linking.
struct GlesTable {
    std::span<const std::span<const GlesBinding>> groups;
    std::span<const GlslName> blocks, textures;
};

// ---- Metal: what a shader brings for it ------------------------------------------------------

/// How a binding is bound on Metal: its slot (buffers, textures and samplers numbered apart, in
/// (group, binding) order: src/render/gpu/naga.zig), and for a runtime-sized storage array its
/// index in naga's `_buffer_sizes` (~0u otherwise).
struct MetalBinding {
    BindingKind kind;
    std::uint32_t slot, sized;
};

/// The binding table Metal replays: per group its bindings, how many runtime-sized arrays the
/// shader has and the buffer slot their lengths go to, and the compute workgroup size.
struct MetalTable {
    std::span<const std::span<const MetalBinding>> groups;
    std::uint32_t sized, sizesSlot;
    std::uint32_t workgroup[3];
};

} // namespace lcgf::gpu
