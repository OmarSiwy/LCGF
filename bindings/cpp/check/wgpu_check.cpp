// lcgf/gpu.hpp on wgpu-native (LCGF_GPU_WGPU): check.zig's checks (gpu_checks.hpp) on a real
// adapter (Mesa lavapipe through wgpu's Vulkan back end in CI), over the repository's WGSL as
// wgpu takes it. Exits 0 when both pass.
//
//   lcgf-cpp-wgpu-check      (prints "skip" and exits 0 when there is no adapter)
#include <cstdio>

#include "gpu_checks.hpp"

namespace gpu = lcgf::gpu;

namespace {

struct Got {
    bool done = false;
    void* handle = nullptr;
};

void onAdapter(WGPURequestAdapterStatus, WGPUAdapter a, WGPUStringView, void* ud, void*) {
    auto* g = static_cast<Got*>(ud);
    g->done = true, g->handle = a;
}
void onDevice(WGPURequestDeviceStatus, WGPUDevice d, WGPUStringView, void* ud, void*) {
    auto* g = static_cast<Got*>(ud);
    g->done = true, g->handle = d;
}
void onError(const WGPUDevice*, WGPUErrorType, WGPUStringView message, void*, void*) {
    std::fprintf(stderr, "wgpu: %.*s\n", int(message.length), message.data);
}

/// An instance on wgpu's Vulkan back end, its first adapter and a device on it.
bool setup(gpu::Device* out) {
    WGPUInstanceExtras extras{};
    extras.chain.sType = WGPUSType(WGPUSType_InstanceExtras);
    extras.backends = WGPUInstanceBackend_Vulkan;
    WGPUInstanceDescriptor id{};
    id.nextInChain = &extras.chain;
    const WGPUInstance instance = wgpuCreateInstance(&id);
    if (!instance) return false;
    Got adapter, device;
    WGPURequestAdapterCallbackInfo ac{};
    ac.mode = WGPUCallbackMode_AllowProcessEvents;
    ac.callback = onAdapter;
    ac.userdata1 = &adapter;
    wgpuInstanceRequestAdapter(instance, nullptr, ac);
    for (int i = 0; i < 10000 && !adapter.done; ++i) wgpuInstanceProcessEvents(instance);
    if (!adapter.handle) return false;
    WGPUDeviceDescriptor dd{};
    dd.uncapturedErrorCallbackInfo.callback = onError;
    WGPURequestDeviceCallbackInfo dc{};
    dc.mode = WGPUCallbackMode_AllowProcessEvents;
    dc.callback = onDevice;
    dc.userdata1 = &device;
    wgpuAdapterRequestDevice(static_cast<WGPUAdapter>(adapter.handle), &dd, dc);
    for (int i = 0; i < 10000 && !device.done; ++i) wgpuInstanceProcessEvents(instance);
    if (!device.handle) return false;
    const auto dev = static_cast<WGPUDevice>(device.handle);
    *out = {dev, wgpuDeviceGetQueue(dev), instance};
    return true;
}

/// check.zig's host on wgpu-native: one command encoder per upload, submitted whole.
struct WgpuHost {
    const gpu::Device& d;
    WGPUCommandEncoder encoder = nullptr;
    gpu::Upload Upload(gpu::Staging* staging) {
        encoder = wgpuDeviceCreateCommandEncoder(d.device, nullptr);
        return gpu::Upload(d, encoder, staging);
    }
    bool Submit() {
        gpu::detail::submit(d, encoder);
        return true;
    }
    bool ReadTexture(const gpu::Texture& t, std::uint8_t* out, std::size_t) { return gpu::ReadTexture(d, t, out) == gpu::kSuccess; }
    bool ReadBuffer(const gpu::Buffer& b, void* out, std::size_t size) { return gpu::ReadBuffer(d, b, 0, out, size) == gpu::kSuccess; }
};

} // namespace

int main() {
    gpu::Device d{};
    if (!setup(&d)) {
        std::printf("skip: no wgpu adapter\n");
        return 0;
    }
    WgpuHost h{d};
    const bool rtt = checks::RenderToTexture(d, h);
    const bool cs = checks::Compute(d, h);
    std::printf("%s render-to-texture, %s compute (C++ lcgf/gpu.hpp on wgpu-native)\n", rtt ? "ok  " : "FAIL", cs ? "ok  " : "FAIL");
    return rtt && cs ? 0 : 1;
}
