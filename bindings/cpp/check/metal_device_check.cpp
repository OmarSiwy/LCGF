// lcgf/gpu.hpp on Metal (LCGF_GPU_METAL): check.zig's checks (gpu_checks.hpp) on the system's
// Metal device, over the repository's WGSL as naga's MSL. Exits 0 when both pass. On a machine
// without Metal (Linux, or a VM with no GPU) it prints "skip" and exits 0; run.sh builds it
// everywhere and cross-compiles it for aarch64-macos, and a Mac runs it.
//
//   lcgf-cpp-metal-device-check
#include <cstdio>

#include "gpu_checks.hpp"

namespace gpu = lcgf::gpu;
namespace objc = lcgf::gpu::objc;

namespace {

/// check.zig's host on Metal: one command buffer per submission, readback through a blit into
/// shared memory (the projection's device textures and buffers are private).
struct MetalHost {
    const gpu::Device& d;
    objc::id queue;
    gpu::Staging& own;
    objc::id cmd = nullptr;

    gpu::Upload Upload(gpu::Staging* staging) {
        cmd = objc::Send<objc::id, "commandBuffer">(queue);
        return gpu::Upload(d, cmd, staging ? staging : &own);
    }
    bool Submit() {
        objc::Send<void, "commit">(cmd);
        objc::Send<void, "waitUntilCompleted">(cmd);
        own.Rewind();
        return true;
    }
    template <class Copy>
    bool Readback(void* out, std::size_t size, Copy copy) {
        const objc::id shared = objc::Send<objc::id, "newBufferWithLength:options:">(d.device, objc::NSUInteger(size), objc::NSUInteger(0));
        const objc::id c = objc::Send<objc::id, "commandBuffer">(queue);
        const objc::id blit = objc::Send<objc::id, "blitCommandEncoder">(c);
        copy(blit, shared);
        objc::Send<void, "endEncoding">(blit);
        objc::Send<void, "commit">(c);
        objc::Send<void, "waitUntilCompleted">(c);
        std::memcpy(out, objc::Send<void*, "contents">(shared), size);
        objc::Release(shared);
        return true;
    }
    bool ReadTexture(const gpu::Texture& t, std::uint8_t* out, std::size_t size) {
        return Readback(out, size, [&](objc::id blit, objc::id to) {
            objc::Send<void,
                       "copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toBuffer:destinationOffset:destinationBytesPerRow:destinationBytesPerImage:">(
                blit, t.texture, objc::NSUInteger(0), objc::NSUInteger(0), gpu::detail::MTLOrigin{}, gpu::detail::MTLSize{t.width, t.height, 1}, to,
                objc::NSUInteger(0), objc::NSUInteger(t.width * 4), objc::NSUInteger(t.width * t.height * 4));
        });
    }
    bool ReadBuffer(const gpu::Buffer& b, void* out, std::size_t size) {
        return Readback(out, size, [&](objc::id blit, objc::id to) {
            objc::Send<void, "copyFromBuffer:sourceOffset:toBuffer:destinationOffset:size:">(blit, b.handle, objc::NSUInteger(0), to, objc::NSUInteger(0),
                                                                                              objc::NSUInteger(size));
        });
    }
};

} // namespace

int main() {
    if (!objc::Load()) {
        std::printf("skip: no Objective-C runtime and Metal (not macOS)\n");
        return 0;
    }
    objc::Pool pool;
    const objc::id device = objc::runtime.createSystemDefaultDevice();
    if (!device) {
        std::printf("skip: no Metal device\n");
        return 0;
    }
    gpu::Device d = gpu::Device::Wrap(device);
    gpu::Arena host;
    gpu::Staging staging;
    if (gpu::CreateArena(d, 1 << 16, gpu::MemoryKind::Host, 8, &host) != gpu::kSuccess || gpu::CreateStaging(d, host, 1 << 16, &staging) != gpu::kSuccess)
        return 1;
    MetalHost h{d, objc::Send<objc::id, "newCommandQueue">(device), staging};
    const bool rtt = checks::RenderToTexture(d, h);
    const bool cs = checks::Compute(d, h);
    std::printf("%s render-to-texture, %s compute (C++ lcgf/gpu.hpp on Metal)\n", rtt ? "ok  " : "FAIL", cs ? "ok  " : "FAIL");
    gpu::DestroyBuffer(d, staging.buffer);
    return rtt && cs ? 0 : 1;
}
