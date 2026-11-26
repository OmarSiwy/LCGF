// lcgf/gpu.hpp on a real Vulkan device: check.zig's checks (gpu_checks.hpp) over shaders
// lcgf-gen made from the repository's WGSL and naga's SPIR-V. Exits 0 when both pass.
//
//   lcgf-cpp-vk-check        (prints "skip" and exits 0 when there is no Vulkan 1.3 device)
#include <cstdio>
#include <cstring>
#include <dlfcn.h>

#include "gpu_checks.hpp"

namespace gpu = lcgf::gpu;

namespace {

PFN_vkGetInstanceProcAddr gipa;
VkInstance instance;
VkPhysicalDevice physical;
VkDevice device;
VkQueue queue;
std::uint32_t family;
VkCommandPool pool;
PFN_vkGetDeviceProcAddr gdpa;

template <class F>
F inst(const char* name) {
    return reinterpret_cast<F>(gipa(instance, name));
}
template <class F>
F dev(const char* name) {
    return reinterpret_cast<F>(gdpa(device, name));
}

bool setup() {
    void* lib = dlopen("libvulkan.so.1", RTLD_NOW);
    if (!lib) return false;
    gipa = reinterpret_cast<PFN_vkGetInstanceProcAddr>(dlsym(lib, "vkGetInstanceProcAddr"));
    VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO, nullptr, "lcgf-cpp-vk-check", 0, "lcgf", 0, VK_API_VERSION_1_3};
    VkInstanceCreateInfo ici{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, nullptr, 0, &app, 0, nullptr, 0, nullptr};
    if (inst<PFN_vkCreateInstance>("vkCreateInstance")(&ici, nullptr, &instance) != VK_SUCCESS) return false;
    std::uint32_t n = 1;
    auto enumerate = inst<PFN_vkEnumeratePhysicalDevices>("vkEnumeratePhysicalDevices");
    if (enumerate(instance, &n, &physical) < 0 || n == 0) return false;
    VkQueueFamilyProperties qf[8];
    std::uint32_t nq = 8;
    inst<PFN_vkGetPhysicalDeviceQueueFamilyProperties>("vkGetPhysicalDeviceQueueFamilyProperties")(physical, &nq, qf);
    family = 0;
    while (family < nq && !(qf[family].queueFlags & VK_QUEUE_GRAPHICS_BIT)) ++family;
    const float priority = 1;
    VkDeviceQueueCreateInfo qi{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, nullptr, 0, family, 1, &priority};
    VkPhysicalDeviceVulkan13Features f13{};
    f13.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES;
    f13.dynamicRendering = VK_TRUE;
    f13.synchronization2 = VK_TRUE;
    VkDeviceCreateInfo di{};
    di.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    di.pNext = &f13;
    di.queueCreateInfoCount = 1;
    di.pQueueCreateInfos = &qi;
    if (inst<PFN_vkCreateDevice>("vkCreateDevice")(physical, &di, nullptr, &device) != VK_SUCCESS) return false;
    gdpa = inst<PFN_vkGetDeviceProcAddr>("vkGetDeviceProcAddr");
    dev<PFN_vkGetDeviceQueue>("vkGetDeviceQueue")(device, family, 0, &queue);
    VkCommandPoolCreateInfo pi{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, nullptr, 0, family};
    return dev<PFN_vkCreateCommandPool>("vkCreateCommandPool")(device, &pi, nullptr, &pool) == VK_SUCCESS;
}

VkCommandBuffer begin() {
    VkCommandBufferAllocateInfo ai{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, nullptr, pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY, 1};
    VkCommandBuffer cmd;
    dev<PFN_vkAllocateCommandBuffers>("vkAllocateCommandBuffers")(device, &ai, &cmd);
    VkCommandBufferBeginInfo bi{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, nullptr, VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT, nullptr};
    dev<PFN_vkBeginCommandBuffer>("vkBeginCommandBuffer")(cmd, &bi);
    return cmd;
}

void submit(VkCommandBuffer cmd) {
    dev<PFN_vkEndCommandBuffer>("vkEndCommandBuffer")(cmd);
    VkSubmitInfo si{VK_STRUCTURE_TYPE_SUBMIT_INFO, nullptr, 0, nullptr, nullptr, 1, &cmd, 0, nullptr};
    dev<PFN_vkQueueSubmit>("vkQueueSubmit")(queue, 1, &si, VK_NULL_HANDLE);
    dev<PFN_vkQueueWaitIdle>("vkQueueWaitIdle")(queue);
}

/// check.zig's host on Vulkan: one command buffer per submission, readback by copying into a
/// host buffer.
struct VkHost {
    const gpu::Device& d;
    VkCommandBuffer cmd = VK_NULL_HANDLE;
    gpu::Upload Upload(gpu::Staging* staging) {
        cmd = begin();
        return gpu::Upload(d, cmd, staging);
    }
    bool Submit() {
        submit(cmd);
        return true;
    }
    bool ReadTexture(const gpu::Texture& t, std::uint8_t* out, std::size_t size) {
        gpu::Arena host;
        gpu::Buffer b;
        if (gpu::CreateArena(d, 1 << 16, gpu::MemoryKind::Host, 1, &host) != VK_SUCCESS) return false;
        if (gpu::CreateBuffer(d, host, {size, gpu::BufferUsage::CopyDst}, &b) != VK_SUCCESS) return false;
        cmd = begin();
        VkImageMemoryBarrier2 bar = gpu::detail::layoutBarrier(t.image, t.resting, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
                                                               VK_ACCESS_2_MEMORY_WRITE_BIT, VK_PIPELINE_STAGE_2_COPY_BIT, VK_ACCESS_2_TRANSFER_READ_BIT);
        VkDependencyInfo dep{};
        dep.sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
        dep.imageMemoryBarrierCount = 1;
        dep.pImageMemoryBarriers = &bar;
        d.fns->CmdPipelineBarrier2(cmd, &dep);
        VkBufferImageCopy copy{};
        copy.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1};
        copy.imageExtent = {t.width, t.height, 1};
        dev<PFN_vkCmdCopyImageToBuffer>("vkCmdCopyImageToBuffer")(cmd, t.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, b.handle, 1, &copy);
        submit(cmd);
        std::memcpy(out, b.mapped, size);
        gpu::DestroyBuffer(d, b);
        gpu::DestroyArena(d, host);
        return true;
    }
    bool ReadBuffer(const gpu::Buffer& b, void* out, std::size_t size) {
        if (!b.mapped) return false;
        std::memcpy(out, b.mapped, size);
        return true;
    }
};

} // namespace

int main() {
    if (!setup()) {
        std::printf("skip: no Vulkan 1.3 device\n");
        return 0;
    }
    const gpu::DeviceFns fns = gpu::DeviceFns::Load(gdpa, device);
    gpu::Device d{device, &fns};
    inst<PFN_vkGetPhysicalDeviceMemoryProperties>("vkGetPhysicalDeviceMemoryProperties")(physical, &d.memory);
    VkHost h{d};
    const bool rtt = checks::RenderToTexture(d, h);
    const bool cs = checks::Compute(d, h);
    std::printf("%s render-to-texture, %s compute (C++ lcgf/gpu.hpp on a real device)\n", rtt ? "ok  " : "FAIL", cs ? "ok  " : "FAIL");
    return rtt && cs ? 0 : 1;
}
