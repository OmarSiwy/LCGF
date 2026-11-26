// lcgf/gpu/vulkan.hpp: lcgf_render.gpu for C++, shaped like Dawn's webgpu_cpp.h, on Vulkan.
//
// The frame phases and the per-draw calls of src/render/vk/gpu.zig, inline: a type is the
// Vulkan handles it stands for, with public fields, and a call is the vkCmd* it stands for,
// through the function table you load (DeviceFns::Load). bindings/check/run.sh records a frame
// through this header and through the Zig projection and requires the same native calls.
//
//   lcgf::gpu::Upload up(device, cmd);
//   up.WriteBuffer(tint, 0, &opacity, sizeof opacity);
//   lcgf::gpu::RenderPassEncoder pass = std::move(up).Finish().BeginRenderPass(desc);
//   pass.SetPipeline(pipeline);
//   pass.SetBindGroup(0, group);
//   pass.Draw(3);
//   pass.End();
//   VkCommandBuffer raw = pass.Get();
//
// `Finish` takes the upload by rvalue: after it there are no more writes in this frame, which
// is the projection's phase rule. Pipelines and bind groups are made with Vulkan directly (or
// by Zig through lcgf_render.gpu); their structs here are what the per-draw calls read.
#pragma once
#include <cassert>
#include <cstddef>
#include <array>
#include <cstdint>
#include <cstring>
#include <optional>
#include <span>
#include <type_traits>
#include <utility>

#include <vulkan/vulkan_core.h>

#include "types.hpp"

namespace lcgf::gpu {

/// The device commands the projection records, loaded once from the device.
struct DeviceFns {
    PFN_vkCmdUpdateBuffer CmdUpdateBuffer;
    PFN_vkCmdPipelineBarrier2 CmdPipelineBarrier2;
    PFN_vkCmdBeginRendering CmdBeginRendering;
    PFN_vkCmdEndRendering CmdEndRendering;
    PFN_vkCmdSetViewport CmdSetViewport;
    PFN_vkCmdSetScissor CmdSetScissor;
    PFN_vkCmdBindPipeline CmdBindPipeline;
    PFN_vkCmdBindDescriptorSets CmdBindDescriptorSets;
    PFN_vkCmdBindVertexBuffers CmdBindVertexBuffers;
    PFN_vkCmdBindIndexBuffer CmdBindIndexBuffer;
    PFN_vkCmdDraw CmdDraw;
    PFN_vkCmdDrawIndexed CmdDrawIndexed;
    PFN_vkCmdSetBlendConstants CmdSetBlendConstants;
    PFN_vkCmdDispatch CmdDispatch;
    PFN_vkCmdCopyBufferToImage CmdCopyBufferToImage;
    // Creation: not per frame.
    PFN_vkCreateBuffer CreateBuffer;
    PFN_vkDestroyBuffer DestroyBuffer;
    PFN_vkGetBufferMemoryRequirements GetBufferMemoryRequirements;
    PFN_vkBindBufferMemory BindBufferMemory;
    PFN_vkCreateImage CreateImage;
    PFN_vkDestroyImage DestroyImage;
    PFN_vkGetImageMemoryRequirements GetImageMemoryRequirements;
    PFN_vkBindImageMemory BindImageMemory;
    PFN_vkCreateImageView CreateImageView;
    PFN_vkDestroyImageView DestroyImageView;
    PFN_vkCreateSampler CreateSampler;
    PFN_vkDestroySampler DestroySampler;
    PFN_vkAllocateMemory AllocateMemory;
    PFN_vkFreeMemory FreeMemory;
    PFN_vkMapMemory MapMemory;
    PFN_vkCreateDescriptorPool CreateDescriptorPool;
    PFN_vkDestroyDescriptorPool DestroyDescriptorPool;
    PFN_vkResetDescriptorPool ResetDescriptorPool;
    PFN_vkAllocateDescriptorSets AllocateDescriptorSets;
    PFN_vkUpdateDescriptorSets UpdateDescriptorSets;
    PFN_vkCreateDescriptorSetLayout CreateDescriptorSetLayout;
    PFN_vkDestroyDescriptorSetLayout DestroyDescriptorSetLayout;
    PFN_vkCreatePipelineLayout CreatePipelineLayout;
    PFN_vkDestroyPipelineLayout DestroyPipelineLayout;
    PFN_vkCreateShaderModule CreateShaderModule;
    PFN_vkDestroyShaderModule DestroyShaderModule;
    PFN_vkCreateGraphicsPipelines CreateGraphicsPipelines;
    PFN_vkCreateComputePipelines CreateComputePipelines;
    PFN_vkDestroyPipeline DestroyPipeline;

    static DeviceFns Load(PFN_vkGetDeviceProcAddr get, VkDevice device) {
        DeviceFns f;
#define LCGF_LOAD(name) f.name = reinterpret_cast<PFN_vk##name>(get(device, "vk" #name))
        LCGF_LOAD(CmdUpdateBuffer);
        LCGF_LOAD(CmdPipelineBarrier2);
        LCGF_LOAD(CmdBeginRendering);
        LCGF_LOAD(CmdEndRendering);
        LCGF_LOAD(CmdSetViewport);
        LCGF_LOAD(CmdSetScissor);
        LCGF_LOAD(CmdBindPipeline);
        LCGF_LOAD(CmdBindDescriptorSets);
        LCGF_LOAD(CmdBindVertexBuffers);
        LCGF_LOAD(CmdBindIndexBuffer);
        LCGF_LOAD(CmdDraw);
        LCGF_LOAD(CmdDrawIndexed);
        LCGF_LOAD(CmdSetBlendConstants);
        LCGF_LOAD(CmdDispatch);
        LCGF_LOAD(CmdCopyBufferToImage);
        LCGF_LOAD(CreateBuffer);
        LCGF_LOAD(DestroyBuffer);
        LCGF_LOAD(GetBufferMemoryRequirements);
        LCGF_LOAD(BindBufferMemory);
        LCGF_LOAD(CreateImage);
        LCGF_LOAD(DestroyImage);
        LCGF_LOAD(GetImageMemoryRequirements);
        LCGF_LOAD(BindImageMemory);
        LCGF_LOAD(CreateImageView);
        LCGF_LOAD(DestroyImageView);
        LCGF_LOAD(CreateSampler);
        LCGF_LOAD(DestroySampler);
        LCGF_LOAD(AllocateMemory);
        LCGF_LOAD(FreeMemory);
        LCGF_LOAD(MapMemory);
        LCGF_LOAD(CreateDescriptorPool);
        LCGF_LOAD(DestroyDescriptorPool);
        LCGF_LOAD(ResetDescriptorPool);
        LCGF_LOAD(AllocateDescriptorSets);
        LCGF_LOAD(UpdateDescriptorSets);
        LCGF_LOAD(CreateDescriptorSetLayout);
        LCGF_LOAD(DestroyDescriptorSetLayout);
        LCGF_LOAD(CreatePipelineLayout);
        LCGF_LOAD(DestroyPipelineLayout);
        LCGF_LOAD(CreateShaderModule);
        LCGF_LOAD(DestroyShaderModule);
        LCGF_LOAD(CreateGraphicsPipelines);
        LCGF_LOAD(CreateComputePipelines);
        LCGF_LOAD(DestroyPipeline);
#undef LCGF_LOAD
        return f;
    }
};

/// The device: its handle, the function table and the memory types (from
/// vkGetPhysicalDeviceMemoryProperties). Copied by value; the table is yours. The creation
/// functions are declared below, after the types they make.
/// What creation reports: Vulkan's own result. `kSuccess` is the one every back end has.
using Result = VkResult;
inline constexpr Result kSuccess = VK_SUCCESS;

struct Device {
    VkDevice handle;
    const DeviceFns* fns;
    VkPhysicalDeviceMemoryProperties memory{};
};

struct Buffer {
    VkBuffer handle;
    std::uint64_t size;
    /// Set when the buffer is in host memory: its bytes, written directly.
    std::byte* mapped = nullptr;
};

struct TextureView {
    VkImageView view;
    VkImage image;
    std::uint32_t width, height, samples = 1;
    /// The layout shaders see it in: its texture's resting layout.
    VkImageLayout layout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    TextureFormat format = TextureFormat::RGBA8Unorm;
};

struct Texture {
    VkImage image;
    VkImageView view;
    TextureFormat format;
    std::uint32_t width, height, samples = 1;
    /// The layout it keeps between passes: shader-readable, or general for storage.
    VkImageLayout resting = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    TextureView CreateView() const { return {view, image, width, height, samples, resting, format}; }
};

struct Sampler {
    VkSampler handle;
};


struct RenderPipeline {
    VkPipeline pipeline;
    VkPipelineLayout layout;
    VkDescriptorSetLayout set_layouts[kMaxGroups];
};
struct ComputePipeline {
    VkPipeline pipeline;
    VkPipelineLayout layout;
    VkDescriptorSetLayout set_layouts[kMaxGroups];
};

/// A descriptor set made for @group(G), and the layout it binds with.
template <std::uint32_t G>
struct BindGroup {
    VkDescriptorSet set;
    VkPipelineLayout layout;
    static constexpr std::uint32_t index = G;
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

namespace detail {
inline VkImageAspectFlags aspect(TextureFormat f) { return f == TextureFormat::Depth32Float ? VK_IMAGE_ASPECT_DEPTH_BIT : VK_IMAGE_ASPECT_COLOR_BIT; }
inline VkImageMemoryBarrier2 layoutBarrier(VkImage image, VkImageLayout from, VkImageLayout to, VkPipelineStageFlags2 srcStage,
                                           VkAccessFlags2 srcAccess, VkPipelineStageFlags2 dstStage, VkAccessFlags2 dstAccess) {
    VkImageMemoryBarrier2 b{};
    b.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2;
    b.srcStageMask = srcStage;
    b.srcAccessMask = srcAccess;
    b.dstStageMask = dstStage;
    b.dstAccessMask = dstAccess;
    b.oldLayout = from;
    b.newLayout = to;
    b.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    b.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    b.image = image;
    b.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    return b;
}
} // namespace detail

class CommandEncoder;

/// A render pass: the command buffer inside dynamic rendering, and the function table.
class RenderPassEncoder {
public:
    /// The UI's own pass, begun by the host (the inline route). `End` leaves it to the host.
    static RenderPassEncoder Wrap(const Device& device, VkCommandBuffer cmd, std::uint32_t width, std::uint32_t height) {
        return RenderPassEncoder(cmd, device.fns, width, height);
    }

    void SetPipeline(const RenderPipeline& p) {
#ifndef NDEBUG
        has_pipeline_ = true;
#endif
        fns_->CmdBindPipeline(cmd_, VK_PIPELINE_BIND_POINT_GRAPHICS, p.pipeline);
    }
    template <std::uint32_t G>
    void SetBindGroup(std::uint32_t index, const BindGroup<G>& group) {
        assert(index == G && "bind group made for another @group");
        fns_->CmdBindDescriptorSets(cmd_, VK_PIPELINE_BIND_POINT_GRAPHICS, group.layout, G, 1, &group.set, 0, nullptr);
    }
    void SetVertexBuffer(std::uint32_t slot, const Buffer& buffer, std::uint64_t offset = 0) {
        fns_->CmdBindVertexBuffers(cmd_, slot, 1, &buffer.handle, &offset);
    }
    void SetIndexBuffer(const Buffer& buffer, IndexFormat format, std::uint64_t offset = 0) {
        fns_->CmdBindIndexBuffer(cmd_, buffer.handle, offset, format == IndexFormat::Uint16 ? VK_INDEX_TYPE_UINT16 : VK_INDEX_TYPE_UINT32);
    }
    void SetViewport(float x, float y, float width, float height, float minDepth, float maxDepth) {
        const VkViewport v{x, y, width, height, minDepth, maxDepth};
        fns_->CmdSetViewport(cmd_, 0, 1, &v);
    }
    void SetScissorRect(std::uint32_t x, std::uint32_t y, std::uint32_t width, std::uint32_t height) {
        assert(x + width <= width_ && y + height <= height_ && "scissor outside the target");
        const VkRect2D r{{static_cast<std::int32_t>(x), static_cast<std::int32_t>(y)}, {width, height}};
        fns_->CmdSetScissor(cmd_, 0, 1, &r);
    }
    void SetBlendConstant(const Color& c) {
        const float k[4] = {static_cast<float>(c.r), static_cast<float>(c.g), static_cast<float>(c.b), static_cast<float>(c.a)};
        fns_->CmdSetBlendConstants(cmd_, k);
    }
    void Draw(std::uint32_t vertexCount, std::uint32_t instanceCount = 1, std::uint32_t firstVertex = 0, std::uint32_t firstInstance = 0) {
        assert(has_pipeline_ && "draw with no pipeline");
        fns_->CmdDraw(cmd_, vertexCount, instanceCount, firstVertex, firstInstance);
    }
    void DrawIndexed(std::uint32_t indexCount, std::uint32_t instanceCount = 1, std::uint32_t firstIndex = 0, std::int32_t baseVertex = 0,
                     std::uint32_t firstInstance = 0) {
        assert(has_pipeline_ && "draw with no pipeline");
        fns_->CmdDrawIndexed(cmd_, indexCount, instanceCount, firstIndex, baseVertex, firstInstance);
    }
    /// Ends a pass the projection began, leaving its attachments in their resting layout. A
    /// wrapped pass is the host's: nothing happens.
    void End() {
        if (!owned_) return;
        fns_->CmdEndRendering(cmd_);
        VkImageMemoryBarrier2 barriers[2 * kMaxColorTargets];
        for (std::uint32_t i = 0; i < end_count_; ++i)
            barriers[i] = detail::layoutBarrier(ends_[i].image, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, ends_[i].layout,
                                                VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
                                                VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, VK_ACCESS_2_MEMORY_READ_BIT);
        VkDependencyInfo dep{};
        dep.sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
        dep.imageMemoryBarrierCount = end_count_;
        dep.pImageMemoryBarriers = barriers;
        fns_->CmdPipelineBarrier2(cmd_, &dep);
    }
    VkCommandBuffer Get() const { return cmd_; }
    const DeviceFns& Fns() const { return *fns_; }

private:
    friend class CommandEncoder;
    struct EndLayout {
        VkImage image;
        VkImageLayout layout;
    };
    RenderPassEncoder(VkCommandBuffer cmd, const DeviceFns* fns, std::uint32_t w, std::uint32_t h)
        : cmd_(cmd), fns_(fns), width_(w), height_(h) {}

    VkCommandBuffer cmd_;
    const DeviceFns* fns_;
    std::uint32_t width_, height_;
    bool owned_ = false;
    EndLayout ends_[2 * kMaxColorTargets]{};
    std::uint32_t end_count_ = 0;
#ifndef NDEBUG
    bool has_pipeline_ = false;
#else
    static constexpr bool has_pipeline_ = true;
#endif
};

class ComputePassEncoder {
public:
    void SetPipeline(const ComputePipeline& p) { fns_->CmdBindPipeline(cmd_, VK_PIPELINE_BIND_POINT_COMPUTE, p.pipeline); }
    template <std::uint32_t G>
    void SetBindGroup(std::uint32_t index, const BindGroup<G>& group) {
        assert(index == G && "bind group made for another @group");
        fns_->CmdBindDescriptorSets(cmd_, VK_PIPELINE_BIND_POINT_COMPUTE, group.layout, G, 1, &group.set, 0, nullptr);
    }
    void DispatchWorkgroups(std::uint32_t x, std::uint32_t y = 1, std::uint32_t z = 1) { fns_->CmdDispatch(cmd_, x, y, z); }
    /// One global barrier from the dispatches' writes to every read after them.
    void End() {
        VkMemoryBarrier2 m{};
        m.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER_2;
        m.srcStageMask = VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT;
        m.srcAccessMask = VK_ACCESS_2_SHADER_WRITE_BIT;
        m.dstStageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT;
        m.dstAccessMask = VK_ACCESS_2_MEMORY_READ_BIT;
        VkDependencyInfo dep{};
        dep.sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
        dep.memoryBarrierCount = 1;
        dep.pMemoryBarriers = &m;
        fns_->CmdPipelineBarrier2(cmd_, &dep);
    }
    VkCommandBuffer Get() const { return cmd_; }

private:
    friend class CommandEncoder;
    ComputePassEncoder(VkCommandBuffer cmd, const DeviceFns* fns) : cmd_(cmd), fns_(fns) {}
    VkCommandBuffer cmd_;
    const DeviceFns* fns_;
};

/// The draw phase of a frame: render and compute passes. Made by `Upload::Finish`.
class CommandEncoder {
public:
    /// Moves the attachments into place, clears or loads them, and sets the viewport and
    /// scissor to the whole target (WebGPU's defaults); `End` leaves them resting.
    RenderPassEncoder BeginRenderPass(const RenderPassDescriptor& d) const {
        RenderPassEncoder p(cmd_, fns_, 0, 0);
        VkImageMemoryBarrier2 barriers[2 * kMaxColorTargets];
        VkRenderingAttachmentInfo infos[kMaxColorTargets];
        std::uint32_t nb = 0, i = 0;
        for (const RenderPassColorAttachment& a : d.colorAttachments) {
            const VkImageLayout from = a.loadOp == LoadOp::Clear ? VK_IMAGE_LAYOUT_UNDEFINED : a.view.layout;
            barriers[nb++] = detail::layoutBarrier(a.view.image, from, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
                                                   VK_ACCESS_2_MEMORY_READ_BIT | VK_ACCESS_2_MEMORY_WRITE_BIT,
                                                   VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
                                                   VK_ACCESS_2_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT);
            p.ends_[p.end_count_++] = {a.view.image, a.view.layout};
            if (a.resolveTarget) {
                barriers[nb++] = detail::layoutBarrier(a.resolveTarget->image, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                                                       VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, VK_ACCESS_2_MEMORY_READ_BIT,
                                                       VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT);
                p.ends_[p.end_count_++] = {a.resolveTarget->image, a.resolveTarget->layout};
            }
            VkRenderingAttachmentInfo& info = infos[i++];
            info = {};
            info.sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO;
            info.imageView = a.view.view;
            info.imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
            info.resolveMode = a.resolveTarget ? VK_RESOLVE_MODE_AVERAGE_BIT : VK_RESOLVE_MODE_NONE;
            info.resolveImageView = a.resolveTarget ? a.resolveTarget->view : VK_NULL_HANDLE;
            info.resolveImageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
            info.loadOp = a.loadOp == LoadOp::Clear ? VK_ATTACHMENT_LOAD_OP_CLEAR : VK_ATTACHMENT_LOAD_OP_LOAD;
            info.storeOp = a.storeOp == StoreOp::Store ? VK_ATTACHMENT_STORE_OP_STORE : VK_ATTACHMENT_STORE_OP_DONT_CARE;
            info.clearValue.color.float32[0] = static_cast<float>(a.clearValue.r);
            info.clearValue.color.float32[1] = static_cast<float>(a.clearValue.g);
            info.clearValue.color.float32[2] = static_cast<float>(a.clearValue.b);
            info.clearValue.color.float32[3] = static_cast<float>(a.clearValue.a);
            p.width_ = a.view.width;
            p.height_ = a.view.height;
        }
        VkDependencyInfo dep{};
        dep.sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
        dep.imageMemoryBarrierCount = nb;
        dep.pImageMemoryBarriers = barriers;
        fns_->CmdPipelineBarrier2(cmd_, &dep);
        VkRenderingInfo ri{};
        ri.sType = VK_STRUCTURE_TYPE_RENDERING_INFO;
        ri.renderArea = {{0, 0}, {p.width_, p.height_}};
        ri.layerCount = 1;
        ri.colorAttachmentCount = static_cast<std::uint32_t>(d.colorAttachments.size());
        ri.pColorAttachments = infos;
        fns_->CmdBeginRendering(cmd_, &ri);
        p.owned_ = true;
        p.SetViewport(0, 0, static_cast<float>(p.width_), static_cast<float>(p.height_), 0, 1);
        p.SetScissorRect(0, 0, p.width_, p.height_);
        return p;
    }
    ComputePassEncoder BeginComputePass() const { return ComputePassEncoder(cmd_, fns_); }
    VkCommandBuffer Get() const { return cmd_; }

private:
    friend class Upload;
    CommandEncoder(VkCommandBuffer cmd, const DeviceFns* fns) : cmd_(cmd), fns_(fns) {}
    VkCommandBuffer cmd_;
    const DeviceFns* fns_;
};

/// A ring of mapped memory for texture writes, in a host arena. One per frame in flight;
/// `Rewind` it when that frame's previous use has completed.
struct Staging {
    Buffer buffer;
    std::uint64_t used = 0;
    void Rewind() { used = 0; }
    /// Copies `bytes` in at a 16-byte boundary; false when the ring is full.
    bool Push(const void* data, std::size_t size, std::uint64_t* at) {
        const std::uint64_t start = (used + 15) & ~std::uint64_t(15);
        if (start + size > buffer.size || buffer.mapped == nullptr) return false;
        std::memcpy(buffer.mapped + start, data, size);
        used = start + size;
        *at = start;
        return true;
    }
};

/// The write phase of a frame: copies and writes only, recorded into your command buffer
/// before any pass. `Finish` ends it with one barrier and returns the draw phase.
class Upload {
public:
    Upload(const Device& device, VkCommandBuffer cmd, Staging* staging = nullptr) : cmd_(cmd), fns_(device.fns), staging_(staging) {}

    /// Writes `size` bytes at `offset`, ordered on the queue like WebGPU's writeBuffer.
    /// Offset and size are multiples of 4; the buffer has copy_dst.
    void WriteBuffer(const Buffer& buffer, std::uint64_t offset, const void* data, std::size_t size) {
        assert(offset % 4 == 0 && size % 4 == 0 && offset + size <= buffer.size);
        const auto* bytes = static_cast<const std::byte*>(data);
        for (std::size_t at = 0; at < size;) {
            const std::size_t n = size - at < 65536 ? size - at : 65536;
            fns_->CmdUpdateBuffer(cmd_, buffer.handle, offset + at, n, bytes + at);
            at += n;
        }
    }

    /// Replaces the whole first mip level of `t` with `data` (rows of `bytesPerRow`), through
    /// the staging ring. False when there is no ring or it is full.
    bool WriteTexture(const Texture& t, const void* data, std::size_t size, std::uint32_t bytesPerRow) {
        std::uint64_t at = 0;
        if (staging_ == nullptr || !staging_->Push(data, size, &at)) return false;
        const VkImageMemoryBarrier2 to = detail::layoutBarrier(t.image, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                                                               VK_PIPELINE_STAGE_2_NONE, 0, VK_PIPELINE_STAGE_2_COPY_BIT, VK_ACCESS_2_TRANSFER_WRITE_BIT);
        VkDependencyInfo dep{};
        dep.sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
        dep.imageMemoryBarrierCount = 1;
        dep.pImageMemoryBarriers = &to;
        fns_->CmdPipelineBarrier2(cmd_, &dep);
        VkBufferImageCopy copy{};
        copy.bufferOffset = at;
        copy.bufferRowLength = bytesPerRow / detail::bytesPerPixel(t.format);
        copy.imageSubresource = {detail::aspect(t.format), 0, 0, 1};
        copy.imageExtent = {t.width, t.height, 1};
        fns_->CmdCopyBufferToImage(cmd_, staging_->buffer.handle, t.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy);
        Rest(t.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, t.resting);
        return true;
    }

    /// Brings a texture that was never written into its resting layout (a render target before
    /// its first load, a storage texture before its first dispatch).
    void Prepare(const Texture& t) { Rest(t.image, VK_IMAGE_LAYOUT_UNDEFINED, t.resting); }

    /// Ends the write phase: one global barrier from every transfer write to every read that
    /// follows, plus the layout moves of the textures written. The upload is spent.
    CommandEncoder Finish() && {
        VkMemoryBarrier2 m{};
        m.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER_2;
        m.srcStageMask = VK_PIPELINE_STAGE_2_ALL_TRANSFER_BIT;
        m.srcAccessMask = VK_ACCESS_2_TRANSFER_WRITE_BIT;
        m.dstStageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT;
        m.dstAccessMask = VK_ACCESS_2_MEMORY_READ_BIT;
        VkDependencyInfo dep{};
        dep.sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
        dep.memoryBarrierCount = 1;
        dep.pMemoryBarriers = &m;
        dep.imageMemoryBarrierCount = image_count_;
        dep.pImageMemoryBarriers = images_;
        fns_->CmdPipelineBarrier2(cmd_, &dep);
        return CommandEncoder(cmd_, fns_);
    }
    VkCommandBuffer Get() const { return cmd_; }

private:
    void Rest(VkImage image, VkImageLayout from, VkImageLayout to) {
        assert(image_count_ < 16);
        images_[image_count_++] = detail::layoutBarrier(image, from, to, VK_PIPELINE_STAGE_2_COPY_BIT, VK_ACCESS_2_TRANSFER_WRITE_BIT,
                                                        VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
                                                        VK_ACCESS_2_SHADER_READ_BIT | VK_ACCESS_2_SHADER_WRITE_BIT | VK_ACCESS_2_COLOR_ATTACHMENT_READ_BIT);
    }
    VkCommandBuffer cmd_;
    const DeviceFns* fns_;
    Staging* staging_;
    VkImageMemoryBarrier2 images_[16];
    std::uint32_t image_count_ = 0;
};

// ---- creation ---------------------------------------------------------------------------------

/// What a shader brings, as lcgf-gen writes it from WGSL (and naga's SPIR-V): the bind group
/// layouts by group, and the code.
struct ShaderInfo {
    std::span<const std::uint32_t> spirv;
    std::span<const std::span<const BindingLayout>> groups;
};

/// One resource of a bind group, as a generated `GroupN::Resources()` lists them.
struct Resource {
    std::uint32_t binding;
    BindingKind kind;
    VkBuffer buffer = VK_NULL_HANDLE;
    VkImageView view = VK_NULL_HANDLE;
    VkImageLayout layout = VK_IMAGE_LAYOUT_UNDEFINED;
    VkSampler sampler = VK_NULL_HANDLE;
};

/// A pipeline made for shader `S`: bind groups of `S`'s groups go with it, others do not
/// compile.
template <class S>
struct RenderPipelineOf : RenderPipeline {
    using Shader = S;
};
template <class S>
struct ComputePipelineOf : ComputePipeline {
    using Shader = S;
};

/// One block of device memory and one descriptor pool, owned by the caller. Resources are
/// placed by bumping an offset; `Reset` forgets them all at once (destroy the objects first).
struct Arena {
    VkDeviceMemory memory = VK_NULL_HANDLE;
    std::uint32_t typeIndex = 0;
    std::uint64_t size = 0, used = 0;
    std::byte* mapped = nullptr;
    VkDescriptorPool pool = VK_NULL_HANDLE;
};

namespace detail {
inline VkResult check(VkResult r, VkResult* out) {
    if (out && r != VK_SUCCESS) *out = r;
    return r;
}
inline VkDescriptorType descriptorType(BindingKind k) {
    switch (k) {
    case BindingKind::Uniform: return VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    case BindingKind::StorageRead:
    case BindingKind::StorageReadWrite: return VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    case BindingKind::Texture: return VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE;
    case BindingKind::StorageTexture: return VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
    default: return VK_DESCRIPTOR_TYPE_SAMPLER;
    }
}
inline VkFormat format(TextureFormat f) {
    constexpr VkFormat table[] = {VK_FORMAT_R8_UNORM, VK_FORMAT_R8G8_UNORM, VK_FORMAT_R8G8B8A8_UNORM, VK_FORMAT_R8G8B8A8_SRGB,
                                  VK_FORMAT_B8G8R8A8_UNORM, VK_FORMAT_B8G8R8A8_SRGB, VK_FORMAT_R16_SFLOAT, VK_FORMAT_R16G16B16A16_SFLOAT,
                                  VK_FORMAT_R32_SFLOAT, VK_FORMAT_R32G32_SFLOAT, VK_FORMAT_R32G32B32A32_SFLOAT, VK_FORMAT_R32_UINT,
                                  VK_FORMAT_D32_SFLOAT};
    return table[std::uint32_t(f)];
}
inline VkFormat vertexFormat(VertexFormat f) {
    constexpr VkFormat table[] = {VK_FORMAT_R32_SFLOAT, VK_FORMAT_R32G32_SFLOAT, VK_FORMAT_R32G32B32_SFLOAT, VK_FORMAT_R32G32B32A32_SFLOAT,
                                  VK_FORMAT_R32_UINT, VK_FORMAT_R32G32_UINT, VK_FORMAT_R32G32B32A32_UINT, VK_FORMAT_R32_SINT,
                                  VK_FORMAT_R8G8B8A8_UNORM};
    return table[std::uint32_t(f)];
}
inline VkBlendFactor blendFactor(BlendFactor f) {
    constexpr VkBlendFactor table[] = {VK_BLEND_FACTOR_ZERO, VK_BLEND_FACTOR_ONE, VK_BLEND_FACTOR_SRC_COLOR, VK_BLEND_FACTOR_ONE_MINUS_SRC_COLOR,
                                       VK_BLEND_FACTOR_SRC_ALPHA, VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA, VK_BLEND_FACTOR_DST_COLOR,
                                       VK_BLEND_FACTOR_ONE_MINUS_DST_COLOR, VK_BLEND_FACTOR_DST_ALPHA, VK_BLEND_FACTOR_ONE_MINUS_DST_ALPHA,
                                       VK_BLEND_FACTOR_CONSTANT_COLOR, VK_BLEND_FACTOR_ONE_MINUS_CONSTANT_COLOR};
    return table[std::uint32_t(f)];
}
inline VkBlendOp blendOp(BlendOperation o) {
    constexpr VkBlendOp table[] = {VK_BLEND_OP_ADD, VK_BLEND_OP_SUBTRACT, VK_BLEND_OP_REVERSE_SUBTRACT, VK_BLEND_OP_MIN, VK_BLEND_OP_MAX};
    return table[std::uint32_t(o)];
}
inline VkSamplerAddressMode address(AddressMode a) {
    constexpr VkSamplerAddressMode table[] = {VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE, VK_SAMPLER_ADDRESS_MODE_REPEAT,
                                              VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT};
    return table[std::uint32_t(a)];
}
inline std::optional<std::uint32_t> memoryType(const Device& d, std::uint32_t bits, VkMemoryPropertyFlags flags) {
    for (std::uint32_t i = 0; i < d.memory.memoryTypeCount; ++i)
        if (((bits >> i) & 1) && (d.memory.memoryTypes[i].propertyFlags & flags) == flags) return i;
    return std::nullopt;
}
inline bool place(Arena& a, const VkMemoryRequirements& req, std::uint64_t* at) {
    if (((req.memoryTypeBits >> a.typeIndex) & 1) == 0) return false;
    const std::uint64_t start = (a.used + req.alignment - 1) / req.alignment * req.alignment;
    if (start + req.size > a.size) return false;
    a.used = start + req.size;
    *at = start;
    return true;
}
} // namespace detail

/// The creation calls, as Device's: `lcgf::gpu::Create...(device, ...)`. Each returns
/// VK_SUCCESS or the first failing result (VK_ERROR_OUT_OF_DEVICE_MEMORY when an arena is full
/// or its memory type does not fit).
inline VkResult CreateArena(const Device& d, std::uint64_t bytes, MemoryKind kind, std::uint32_t bindGroups, Arena* out) {
    const VkMemoryPropertyFlags flags = kind == MemoryKind::Device ? VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT
                                                                   : VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    const auto index = detail::memoryType(d, 0xffffffffu, flags);
    if (!index) return VK_ERROR_OUT_OF_DEVICE_MEMORY;
    Arena a;
    a.typeIndex = *index;
    a.size = bytes;
    VkMemoryAllocateInfo mi{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, nullptr, bytes, *index};
    if (VkResult r = d.fns->AllocateMemory(d.handle, &mi, nullptr, &a.memory); r != VK_SUCCESS) return r;
    if (kind == MemoryKind::Host) {
        void* p = nullptr;
        if (VkResult r = d.fns->MapMemory(d.handle, a.memory, 0, bytes, 0, &p); r != VK_SUCCESS) return r;
        a.mapped = static_cast<std::byte*>(p);
    }
    const std::uint32_t n = bindGroups;
    const VkDescriptorPoolSize sizes[] = {{VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 4 * n}, {VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 4 * n},
                                          {VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 4 * n}, {VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, n},
                                          {VK_DESCRIPTOR_TYPE_SAMPLER, 2 * n}};
    VkDescriptorPoolCreateInfo pi{VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, nullptr, 0, n, 5, sizes};
    if (VkResult r = d.fns->CreateDescriptorPool(d.handle, &pi, nullptr, &a.pool); r != VK_SUCCESS) return r;
    *out = a;
    return VK_SUCCESS;
}

inline void DestroyArena(const Device& d, Arena& a) {
    d.fns->DestroyDescriptorPool(d.handle, a.pool, nullptr);
    d.fns->FreeMemory(d.handle, a.memory, nullptr);
    a = {};
}

inline VkResult CreateBuffer(const Device& d, Arena& arena, const BufferDescriptor& desc, Buffer* out) {
    VkBufferUsageFlags f = 0;
    if (desc.usage & (BufferUsage::CopySrc | BufferUsage::MapRead)) f |= VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
    if (desc.usage & (BufferUsage::CopyDst | BufferUsage::MapWrite)) f |= VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    if (desc.usage & BufferUsage::Index) f |= VK_BUFFER_USAGE_INDEX_BUFFER_BIT;
    if (desc.usage & BufferUsage::Vertex) f |= VK_BUFFER_USAGE_VERTEX_BUFFER_BIT;
    if (desc.usage & BufferUsage::Uniform) f |= VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT;
    if (desc.usage & BufferUsage::Storage) f |= VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
    if (desc.usage & BufferUsage::Indirect) f |= VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT;
    VkBufferCreateInfo bi{};
    bi.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    bi.size = desc.size;
    bi.usage = f;
    bi.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    Buffer b{VK_NULL_HANDLE, desc.size, nullptr};
    if (VkResult r = d.fns->CreateBuffer(d.handle, &bi, nullptr, &b.handle); r != VK_SUCCESS) return r;
    VkMemoryRequirements req;
    d.fns->GetBufferMemoryRequirements(d.handle, b.handle, &req);
    std::uint64_t at = 0;
    if (!detail::place(arena, req, &at)) {
        d.fns->DestroyBuffer(d.handle, b.handle, nullptr);
        return VK_ERROR_OUT_OF_DEVICE_MEMORY;
    }
    if (VkResult r = d.fns->BindBufferMemory(d.handle, b.handle, arena.memory, at); r != VK_SUCCESS) return r;
    if (arena.mapped) b.mapped = arena.mapped + at;
    *out = b;
    return VK_SUCCESS;
}

inline void DestroyBuffer(const Device& d, const Buffer& b) { d.fns->DestroyBuffer(d.handle, b.handle, nullptr); }

inline VkResult CreateTexture(const Device& d, Arena& arena, const TextureDescriptor& desc, Texture* out) {
    VkImageUsageFlags f = 0;
    if (desc.usage & TextureUsage::CopySrc) f |= VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    if (desc.usage & TextureUsage::CopyDst) f |= VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    if (desc.usage & TextureUsage::TextureBinding) f |= VK_IMAGE_USAGE_SAMPLED_BIT;
    if (desc.usage & TextureUsage::StorageBinding) f |= VK_IMAGE_USAGE_STORAGE_BIT;
    if (desc.usage & TextureUsage::RenderAttachment) f |= VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    Texture t{VK_NULL_HANDLE, VK_NULL_HANDLE, desc.format, desc.width, desc.height, desc.sampleCount,
              (desc.usage & TextureUsage::StorageBinding) ? VK_IMAGE_LAYOUT_GENERAL : VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL};
    VkImageCreateInfo ii{};
    ii.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    ii.imageType = VK_IMAGE_TYPE_2D;
    ii.format = detail::format(desc.format);
    ii.extent = {desc.width, desc.height, 1};
    ii.mipLevels = desc.mipLevelCount;
    ii.arrayLayers = 1;
    ii.samples = VkSampleCountFlagBits(desc.sampleCount);
    ii.tiling = VK_IMAGE_TILING_OPTIMAL;
    ii.usage = f;
    ii.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    ii.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    if (VkResult r = d.fns->CreateImage(d.handle, &ii, nullptr, &t.image); r != VK_SUCCESS) return r;
    VkMemoryRequirements req;
    d.fns->GetImageMemoryRequirements(d.handle, t.image, &req);
    std::uint64_t at = 0;
    if (!detail::place(arena, req, &at)) {
        d.fns->DestroyImage(d.handle, t.image, nullptr);
        return VK_ERROR_OUT_OF_DEVICE_MEMORY;
    }
    if (VkResult r = d.fns->BindImageMemory(d.handle, t.image, arena.memory, at); r != VK_SUCCESS) return r;
    VkImageViewCreateInfo vi{};
    vi.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    vi.image = t.image;
    vi.viewType = VK_IMAGE_VIEW_TYPE_2D;
    vi.format = ii.format;
    vi.subresourceRange = {detail::aspect(desc.format), 0, desc.mipLevelCount, 0, 1};
    if (VkResult r = d.fns->CreateImageView(d.handle, &vi, nullptr, &t.view); r != VK_SUCCESS) return r;
    *out = t;
    return VK_SUCCESS;
}

inline void DestroyTexture(const Device& d, const Texture& t) {
    d.fns->DestroyImageView(d.handle, t.view, nullptr);
    d.fns->DestroyImage(d.handle, t.image, nullptr);
}

inline VkResult CreateSampler(const Device& d, const SamplerDescriptor& desc, Sampler* out) {
    VkSamplerCreateInfo si{};
    si.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
    si.magFilter = desc.magFilter == FilterMode::Linear ? VK_FILTER_LINEAR : VK_FILTER_NEAREST;
    si.minFilter = desc.minFilter == FilterMode::Linear ? VK_FILTER_LINEAR : VK_FILTER_NEAREST;
    si.mipmapMode = desc.mipmapFilter == FilterMode::Linear ? VK_SAMPLER_MIPMAP_MODE_LINEAR : VK_SAMPLER_MIPMAP_MODE_NEAREST;
    si.addressModeU = detail::address(desc.addressModeU);
    si.addressModeV = detail::address(desc.addressModeV);
    si.addressModeW = detail::address(desc.addressModeW);
    si.compareOp = VK_COMPARE_OP_NEVER;
    si.minLod = desc.lodMinClamp;
    si.maxLod = desc.lodMaxClamp;
    return d.fns->CreateSampler(d.handle, &si, nullptr, &out->handle);
}

inline void DestroySampler(const Device& d, const Sampler& s) { d.fns->DestroySampler(d.handle, s.handle, nullptr); }

namespace detail {
inline VkResult layout(const Device& d, const ShaderInfo& s, VkDescriptorSetLayout* sets, VkPipelineLayout* out) {
    assert(s.groups.size() <= kMaxGroups);
    for (std::size_t g = 0; g < s.groups.size(); ++g) {
        VkDescriptorSetLayoutBinding lb[16];
        const auto& bs = s.groups[g];
        assert(bs.size() <= 16);
        for (std::size_t i = 0; i < bs.size(); ++i) lb[i] = {bs[i].binding, descriptorType(bs[i].kind), 1, VK_SHADER_STAGE_ALL, nullptr};
        VkDescriptorSetLayoutCreateInfo ci{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, nullptr, 0, std::uint32_t(bs.size()), lb};
        if (VkResult r = d.fns->CreateDescriptorSetLayout(d.handle, &ci, nullptr, &sets[g]); r != VK_SUCCESS) return r;
    }
    VkPipelineLayoutCreateInfo pi{};
    pi.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    pi.setLayoutCount = std::uint32_t(s.groups.size());
    pi.pSetLayouts = sets;
    return d.fns->CreatePipelineLayout(d.handle, &pi, nullptr, out);
}
inline VkResult module(const Device& d, const ShaderInfo& s, VkShaderModule* out) {
    VkShaderModuleCreateInfo mi{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, nullptr, 0, s.spirv.size() * 4, s.spirv.data()};
    return d.fns->CreateShaderModule(d.handle, &mi, nullptr, out);
}
} // namespace detail

/// A render pipeline for shader `S` (generated by lcgf-gen from WGSL). Its layout comes from
/// the shader's reflected groups.
template <class S>
VkResult CreateRenderPipeline(const Device& d, const RenderPipelineDescriptor& desc, RenderPipelineOf<S>* out) {
    const ShaderInfo& s = S::info;
    RenderPipelineOf<S> p{};
    if (VkResult r = detail::layout(d, s, p.set_layouts, &p.layout); r != VK_SUCCESS) return r;
    VkShaderModule module;
    if (VkResult r = detail::module(d, s, &module); r != VK_SUCCESS) return r;
    const FragmentState none{};
    const FragmentState& frag = desc.fragment ? *desc.fragment : none;
    VkPipelineShaderStageCreateInfo stages[2] = {
        {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, nullptr, 0, VK_SHADER_STAGE_VERTEX_BIT, module, desc.vertex.entryPoint, nullptr},
        {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, nullptr, 0, VK_SHADER_STAGE_FRAGMENT_BIT, module, frag.entryPoint, nullptr},
    };
    VkVertexInputBindingDescription bindings[8];
    VkVertexInputAttributeDescription attrs[16];
    std::uint32_t nattr = 0;
    for (std::uint32_t slot = 0; slot < desc.vertex.buffers.size(); ++slot) {
        const VertexBufferLayout& vb = desc.vertex.buffers[slot];
        bindings[slot] = {slot, std::uint32_t(vb.arrayStride), vb.stepMode == VertexStepMode::Instance ? VK_VERTEX_INPUT_RATE_INSTANCE : VK_VERTEX_INPUT_RATE_VERTEX};
        for (const VertexAttribute& a : vb.attributes) attrs[nattr++] = {a.shaderLocation, slot, detail::vertexFormat(a.format), std::uint32_t(a.offset)};
    }
    VkPipelineVertexInputStateCreateInfo vertex{VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO, nullptr, 0,
                                                std::uint32_t(desc.vertex.buffers.size()), bindings, nattr, attrs};
    constexpr VkPrimitiveTopology topologies[] = {VK_PRIMITIVE_TOPOLOGY_POINT_LIST, VK_PRIMITIVE_TOPOLOGY_LINE_LIST, VK_PRIMITIVE_TOPOLOGY_LINE_STRIP,
                                                  VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP};
    VkPipelineInputAssemblyStateCreateInfo assembly{VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, nullptr, 0,
                                                    topologies[std::uint32_t(desc.primitive.topology)], desc.primitive.stripIndexFormat};
    VkPipelineViewportStateCreateInfo viewport{VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, nullptr, 0, 1, nullptr, 1, nullptr};
    VkPipelineRasterizationStateCreateInfo raster{};
    raster.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
    raster.polygonMode = VK_POLYGON_MODE_FILL;
    raster.cullMode = desc.primitive.cullMode == CullMode::None ? VK_CULL_MODE_NONE
                      : desc.primitive.cullMode == CullMode::Front ? VK_CULL_MODE_FRONT_BIT
                                                                   : VK_CULL_MODE_BACK_BIT;
    // naga's SPIR-V flips y, so framebuffer winding is WebGPU's: ccw stays ccw.
    raster.frontFace = desc.primitive.frontFace == FrontFace::CCW ? VK_FRONT_FACE_COUNTER_CLOCKWISE : VK_FRONT_FACE_CLOCKWISE;
    raster.lineWidth = 1;
    VkPipelineMultisampleStateCreateInfo multisample{};
    multisample.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
    multisample.rasterizationSamples = VkSampleCountFlagBits(desc.multisample.count);
    multisample.pSampleMask = &desc.multisample.mask;
    multisample.alphaToCoverageEnable = desc.multisample.alphaToCoverageEnabled;
    VkPipelineColorBlendAttachmentState blends[kMaxColorTargets]{};
    VkFormat formats[kMaxColorTargets];
    for (std::size_t i = 0; i < frag.targets.size(); ++i) {
        const ColorTargetState& t = frag.targets[i];
        formats[i] = detail::format(t.format);
        blends[i].colorWriteMask = t.writeMask;
        if (t.blend) {
            blends[i].blendEnable = VK_TRUE;
            blends[i].srcColorBlendFactor = detail::blendFactor(t.blend->color.srcFactor);
            blends[i].dstColorBlendFactor = detail::blendFactor(t.blend->color.dstFactor);
            blends[i].colorBlendOp = detail::blendOp(t.blend->color.operation);
            blends[i].srcAlphaBlendFactor = detail::blendFactor(t.blend->alpha.srcFactor);
            blends[i].dstAlphaBlendFactor = detail::blendFactor(t.blend->alpha.dstFactor);
            blends[i].alphaBlendOp = detail::blendOp(t.blend->alpha.operation);
        }
    }
    VkPipelineColorBlendStateCreateInfo blend{};
    blend.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
    blend.attachmentCount = std::uint32_t(frag.targets.size());
    blend.pAttachments = blends;
    const VkDynamicState dynamicStates[] = {VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR, VK_DYNAMIC_STATE_BLEND_CONSTANTS};
    VkPipelineDynamicStateCreateInfo dynamic{VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO, nullptr, 0, 3, dynamicStates};
    VkPipelineRenderingCreateInfo rendering{};
    rendering.sType = VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO;
    rendering.colorAttachmentCount = std::uint32_t(frag.targets.size());
    rendering.pColorAttachmentFormats = formats;
    VkGraphicsPipelineCreateInfo gi{};
    gi.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
    gi.pNext = &rendering;
    gi.stageCount = desc.fragment ? 2 : 1;
    gi.pStages = stages;
    gi.pVertexInputState = &vertex;
    gi.pInputAssemblyState = &assembly;
    gi.pViewportState = &viewport;
    gi.pRasterizationState = &raster;
    gi.pMultisampleState = &multisample;
    gi.pColorBlendState = &blend;
    gi.pDynamicState = &dynamic;
    gi.layout = p.layout;
    const VkResult r = d.fns->CreateGraphicsPipelines(d.handle, VK_NULL_HANDLE, 1, &gi, nullptr, &p.pipeline);
    d.fns->DestroyShaderModule(d.handle, module, nullptr);
    if (r == VK_SUCCESS) *out = p;
    return r;
}

template <class S>
VkResult CreateComputePipeline(const Device& d, const ComputePipelineDescriptor& desc, ComputePipelineOf<S>* out) {
    const ShaderInfo& s = S::info;
    ComputePipelineOf<S> p{};
    if (VkResult r = detail::layout(d, s, p.set_layouts, &p.layout); r != VK_SUCCESS) return r;
    VkShaderModule module;
    if (VkResult r = detail::module(d, s, &module); r != VK_SUCCESS) return r;
    VkComputePipelineCreateInfo ci{};
    ci.sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
    ci.stage = {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, nullptr, 0, VK_SHADER_STAGE_COMPUTE_BIT, module, desc.entryPoint, nullptr};
    ci.layout = p.layout;
    const VkResult r = d.fns->CreateComputePipelines(d.handle, VK_NULL_HANDLE, 1, &ci, nullptr, &p.pipeline);
    d.fns->DestroyShaderModule(d.handle, module, nullptr);
    if (r == VK_SUCCESS) *out = p;
    return r;
}

template <class P>
void DestroyPipeline(const Device& d, const P& p) {
    if (p.pipeline) d.fns->DestroyPipeline(d.handle, p.pipeline, nullptr);
    if (p.layout) d.fns->DestroyPipelineLayout(d.handle, p.layout, nullptr);
    for (VkDescriptorSetLayout l : p.set_layouts)
        if (l) d.fns->DestroyDescriptorSetLayout(d.handle, l, nullptr);
}

/// A bind group from a generated `<shader>::GroupN`: one member per binding the WGSL declares,
/// so a missing or misspelt resource does not compile, and a group of another shader neither.
template <class P, class G>
    requires std::is_same_v<typename P::Shader, typename G::Shader>
VkResult CreateBindGroup(const Device& d, Arena& arena, const P& pipeline, const G& group, BindGroup<G::index>* out) {
    VkDescriptorSetAllocateInfo ai{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, nullptr, arena.pool, 1, &pipeline.set_layouts[G::index]};
    VkDescriptorSet set;
    if (VkResult r = d.fns->AllocateDescriptorSets(d.handle, &ai, &set); r != VK_SUCCESS) return r;
    const auto resources = group.Resources();
    VkDescriptorBufferInfo buffers[16];
    VkDescriptorImageInfo images[16];
    VkWriteDescriptorSet writes[16];
    for (std::size_t i = 0; i < resources.size(); ++i) {
        const Resource& res = resources[i];
        writes[i] = {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, nullptr, set, res.binding, 0, 1, detail::descriptorType(res.kind), nullptr, nullptr, nullptr};
        switch (res.kind) {
        case BindingKind::Uniform:
        case BindingKind::StorageRead:
        case BindingKind::StorageReadWrite:
            buffers[i] = {res.buffer, 0, VK_WHOLE_SIZE};
            writes[i].pBufferInfo = &buffers[i];
            break;
        case BindingKind::Texture:
        case BindingKind::StorageTexture:
            images[i] = {VK_NULL_HANDLE, res.view, res.layout};
            writes[i].pImageInfo = &images[i];
            break;
        default:
            images[i] = {res.sampler, VK_NULL_HANDLE, VK_IMAGE_LAYOUT_UNDEFINED};
            writes[i].pImageInfo = &images[i];
        }
    }
    d.fns->UpdateDescriptorSets(d.handle, std::uint32_t(resources.size()), writes, 0, nullptr);
    *out = {set, pipeline.layout};
    return VK_SUCCESS;
}

/// A ring of `bytes` for texture writes, in a host arena.
inline VkResult CreateStaging(const Device& d, Arena& host, std::uint64_t bytes, Staging* out) {
    if (host.mapped == nullptr) return VK_ERROR_MEMORY_MAP_FAILED;
    out->used = 0;
    return CreateBuffer(d, host, {bytes, BufferUsage::CopySrc}, &out->buffer);
}

/// Resources as a generated group lists them.
inline Resource BufferResource(std::uint32_t binding, BindingKind kind, const Buffer& b) { return {binding, kind, b.handle}; }
inline Resource ViewResource(std::uint32_t binding, BindingKind kind, const TextureView& v) {
    return {binding, kind, VK_NULL_HANDLE, v.view, v.layout};
}
inline Resource SamplerResource(std::uint32_t binding, BindingKind kind, const Sampler& s) {
    return {binding, kind, VK_NULL_HANDLE, VK_NULL_HANDLE, VK_IMAGE_LAYOUT_UNDEFINED, s.handle};
}

} // namespace lcgf::gpu
