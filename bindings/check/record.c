/* A Vulkan command recorder for the bindings' GPU gate (bindings/check/run.sh). Its
 * vkGetDeviceProcAddr hands out functions that write each call, with every field of the
 * structs it takes, as one line of text. Zig (lcgf_render.gpu), C++ (lcgf/gpu.hpp) and Rust
 * (lcgf::gpu) record the same frame through it; equal logs mean the same native calls. */
#include <stdio.h>
#include <string.h>
#include <vulkan/vulkan_core.h>

static char log_buf[1 << 16];
static size_t log_len;

static void out(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
#include <stdarg.h>
static void out(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(log_buf + log_len, sizeof log_buf - log_len, fmt, ap);
    va_end(ap);
    if (n > 0 && log_len + (size_t)n < sizeof log_buf) log_len += (size_t)n;
}

#define H(x) ((unsigned long long)(uintptr_t)(x))

static void barrier_memory(const VkMemoryBarrier2 *m) {
    out("  memory sType=%d src=%llx/%llx dst=%llx/%llx\n", m->sType, (unsigned long long)m->srcStageMask,
        (unsigned long long)m->srcAccessMask, (unsigned long long)m->dstStageMask, (unsigned long long)m->dstAccessMask);
}

static void barrier_image(const VkImageMemoryBarrier2 *b) {
    out("  image sType=%d src=%llx/%llx dst=%llx/%llx layout=%d->%d qf=%u/%u image=%llx aspect=%u mips=%u+%u layers=%u+%u\n", b->sType,
        (unsigned long long)b->srcStageMask, (unsigned long long)b->srcAccessMask, (unsigned long long)b->dstStageMask,
        (unsigned long long)b->dstAccessMask, b->oldLayout, b->newLayout, b->srcQueueFamilyIndex, b->dstQueueFamilyIndex, H(b->image),
        b->subresourceRange.aspectMask, b->subresourceRange.baseMipLevel, b->subresourceRange.levelCount,
        b->subresourceRange.baseArrayLayer, b->subresourceRange.layerCount);
}

static VKAPI_ATTR void VKAPI_CALL rec_update_buffer(VkCommandBuffer cmd, VkBuffer b, VkDeviceSize off, VkDeviceSize size, const void *data) {
    out("vkCmdUpdateBuffer cmd=%llx buffer=%llx offset=%llu size=%llu data=", H(cmd), H(b), (unsigned long long)off, (unsigned long long)size);
    for (VkDeviceSize i = 0; i < size; ++i) out("%02x", ((const unsigned char *)data)[i]);
    out("\n");
}

static VKAPI_ATTR void VKAPI_CALL rec_barrier2(VkCommandBuffer cmd, const VkDependencyInfo *d) {
    out("vkCmdPipelineBarrier2 cmd=%llx sType=%d flags=%u memory=%u buffer=%u image=%u\n", H(cmd), d->sType, d->dependencyFlags,
        d->memoryBarrierCount, d->bufferMemoryBarrierCount, d->imageMemoryBarrierCount);
    for (uint32_t i = 0; i < d->memoryBarrierCount; ++i) barrier_memory(&d->pMemoryBarriers[i]);
    for (uint32_t i = 0; i < d->imageMemoryBarrierCount; ++i) barrier_image(&d->pImageMemoryBarriers[i]);
}

static VKAPI_ATTR void VKAPI_CALL rec_begin_rendering(VkCommandBuffer cmd, const VkRenderingInfo *r) {
    out("vkCmdBeginRendering cmd=%llx sType=%d flags=%u area=%d,%d,%u,%u layers=%u view=%u colors=%u depth=%d stencil=%d\n", H(cmd), r->sType, r->flags,
        r->renderArea.offset.x, r->renderArea.offset.y, r->renderArea.extent.width, r->renderArea.extent.height, r->layerCount, r->viewMask,
        r->colorAttachmentCount, r->pDepthAttachment != NULL, r->pStencilAttachment != NULL);
    for (uint32_t i = 0; i < r->colorAttachmentCount; ++i) {
        const VkRenderingAttachmentInfo *a = &r->pColorAttachments[i];
        out("  color sType=%d view=%llx layout=%d resolve=%d/%llx/%d load=%d store=%d clear=%g,%g,%g,%g\n", a->sType, H(a->imageView), a->imageLayout,
            a->resolveMode, H(a->resolveImageView), a->resolveImageLayout, a->loadOp, a->storeOp, a->clearValue.color.float32[0],
            a->clearValue.color.float32[1], a->clearValue.color.float32[2], a->clearValue.color.float32[3]);
    }
}

static VKAPI_ATTR void VKAPI_CALL rec_end_rendering(VkCommandBuffer cmd) { out("vkCmdEndRendering cmd=%llx\n", H(cmd)); }

static VKAPI_ATTR void VKAPI_CALL rec_set_viewport(VkCommandBuffer cmd, uint32_t first, uint32_t n, const VkViewport *v) {
    out("vkCmdSetViewport cmd=%llx first=%u n=%u %g,%g,%g,%g,%g,%g\n", H(cmd), first, n, v->x, v->y, v->width, v->height, v->minDepth, v->maxDepth);
}

static VKAPI_ATTR void VKAPI_CALL rec_set_scissor(VkCommandBuffer cmd, uint32_t first, uint32_t n, const VkRect2D *r) {
    out("vkCmdSetScissor cmd=%llx first=%u n=%u %d,%d,%u,%u\n", H(cmd), first, n, r->offset.x, r->offset.y, r->extent.width, r->extent.height);
}

static VKAPI_ATTR void VKAPI_CALL rec_bind_pipeline(VkCommandBuffer cmd, VkPipelineBindPoint bp, VkPipeline p) {
    out("vkCmdBindPipeline cmd=%llx point=%d pipeline=%llx\n", H(cmd), bp, H(p));
}

static VKAPI_ATTR void VKAPI_CALL rec_bind_sets(VkCommandBuffer cmd, VkPipelineBindPoint bp, VkPipelineLayout layout, uint32_t first, uint32_t n,
                                                const VkDescriptorSet *sets, uint32_t dyn, const uint32_t *offsets) {
    out("vkCmdBindDescriptorSets cmd=%llx point=%d layout=%llx first=%u n=%u set0=%llx dynamic=%u offsets=%d\n", H(cmd), bp, H(layout), first, n,
        H(sets[0]), dyn, offsets != NULL);
}

static VKAPI_ATTR void VKAPI_CALL rec_bind_vertex(VkCommandBuffer cmd, uint32_t first, uint32_t n, const VkBuffer *b, const VkDeviceSize *off) {
    out("vkCmdBindVertexBuffers cmd=%llx first=%u n=%u buffer=%llx offset=%llu\n", H(cmd), first, n, H(b[0]), (unsigned long long)off[0]);
}

static VKAPI_ATTR void VKAPI_CALL rec_bind_index(VkCommandBuffer cmd, VkBuffer b, VkDeviceSize off, VkIndexType t) {
    out("vkCmdBindIndexBuffer cmd=%llx buffer=%llx offset=%llu type=%d\n", H(cmd), H(b), (unsigned long long)off, t);
}

static VKAPI_ATTR void VKAPI_CALL rec_draw(VkCommandBuffer cmd, uint32_t v, uint32_t i, uint32_t fv, uint32_t fi) {
    out("vkCmdDraw cmd=%llx %u %u %u %u\n", H(cmd), v, i, fv, fi);
}

static VKAPI_ATTR void VKAPI_CALL rec_draw_indexed(VkCommandBuffer cmd, uint32_t n, uint32_t i, uint32_t fi, int32_t bv, uint32_t finst) {
    out("vkCmdDrawIndexed cmd=%llx %u %u %u %d %u\n", H(cmd), n, i, fi, bv, finst);
}

static VKAPI_ATTR void VKAPI_CALL rec_blend(VkCommandBuffer cmd, const float k[4]) {
    out("vkCmdSetBlendConstants cmd=%llx %g,%g,%g,%g\n", H(cmd), k[0], k[1], k[2], k[3]);
}

static VKAPI_ATTR void VKAPI_CALL rec_dispatch(VkCommandBuffer cmd, uint32_t x, uint32_t y, uint32_t z) {
    out("vkCmdDispatch cmd=%llx %u %u %u\n", H(cmd), x, y, z);
}

static VKAPI_ATTR void VKAPI_CALL rec_unexpected(void) { out("UNEXPECTED CALL\n"); }

/* The recorder's vkGetDeviceProcAddr: the commands above, and a function that logs itself as
 * unexpected for anything else a projection loads. */
VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL lcgf_record_get_device_proc_addr(VkDevice device, const char *name) {
    (void)device;
    static const struct { const char *name; PFN_vkVoidFunction fn; } table[] = {
        {"vkCmdUpdateBuffer", (PFN_vkVoidFunction)rec_update_buffer},
        {"vkCmdPipelineBarrier2", (PFN_vkVoidFunction)rec_barrier2},
        {"vkCmdBeginRendering", (PFN_vkVoidFunction)rec_begin_rendering},
        {"vkCmdEndRendering", (PFN_vkVoidFunction)rec_end_rendering},
        {"vkCmdSetViewport", (PFN_vkVoidFunction)rec_set_viewport},
        {"vkCmdSetScissor", (PFN_vkVoidFunction)rec_set_scissor},
        {"vkCmdBindPipeline", (PFN_vkVoidFunction)rec_bind_pipeline},
        {"vkCmdBindDescriptorSets", (PFN_vkVoidFunction)rec_bind_sets},
        {"vkCmdBindVertexBuffers", (PFN_vkVoidFunction)rec_bind_vertex},
        {"vkCmdBindIndexBuffer", (PFN_vkVoidFunction)rec_bind_index},
        {"vkCmdDraw", (PFN_vkVoidFunction)rec_draw},
        {"vkCmdDrawIndexed", (PFN_vkVoidFunction)rec_draw_indexed},
        {"vkCmdSetBlendConstants", (PFN_vkVoidFunction)rec_blend},
        {"vkCmdDispatch", (PFN_vkVoidFunction)rec_dispatch},
    };
    for (size_t i = 0; i < sizeof table / sizeof table[0]; ++i)
        if (strcmp(table[i].name, name) == 0) return table[i].fn;
    return (PFN_vkVoidFunction)rec_unexpected;
}

const char *lcgf_record_log(size_t *len) {
    *len = log_len;
    return log_buf;
}

void lcgf_record_reset(void) { log_len = 0; }
