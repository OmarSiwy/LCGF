// lcgf/gpu.hpp on GL ES (LCGF_GPU_GLES): check.zig's checks (gpu_checks.hpp) on a real driver
// (Mesa llvmpipe in CI), through a headless EGL context, over shaders lcgf-gen made from the
// repository's WGSL with naga's GLSL ES. Exits 0 when both pass; the compute check needs GL ES
// 3.1 and is reported as skipped without it.
//
//   lcgf-cpp-gles-check      (prints "skip" and exits 0 when there is no EGL / GL ES 3 driver)
#include <cstdio>
#include <cstring>
#include <dlfcn.h>

#include "gpu_checks.hpp"

namespace gpu = lcgf::gpu;

namespace {

// EGL, as much as a headless context takes (Khronos's values; no EGL header needed).
using EGLDisplay = void*;
using EGLConfig = void*;
using EGLContext = void*;
using EGLSurface = void*;
using EGLint = std::int32_t;
constexpr EGLint kNone = 0x3038, kExtensions = 0x3055, kRenderableType = 0x3040, kOpenGLES3Bit = 0x0040, kSurfaceType = 0x3033,
                 kPbufferBit = 0x0001, kRedSize = 0x3024, kGreenSize = 0x3023, kBlueSize = 0x3022, kAlphaSize = 0x3021,
                 kContextMajor = 0x3098, kContextMinor = 0x30FB, kWidth = 0x3057, kHeight = 0x3056;
constexpr unsigned kOpenGLESAPI = 0x30A0, kPlatformSurfacelessMESA = 0x31DD;

struct Egl {
    void* (*GetProcAddress)(const char*);
    EGLDisplay (*GetDisplay)(void*);
    EGLDisplay (*GetPlatformDisplay)(unsigned, void*, const std::intptr_t*);
    unsigned (*Initialize)(EGLDisplay, EGLint*, EGLint*);
    const char* (*QueryString)(EGLDisplay, EGLint);
    unsigned (*BindAPI)(unsigned);
    unsigned (*ChooseConfig)(EGLDisplay, const EGLint*, EGLConfig*, EGLint, EGLint*);
    EGLContext (*CreateContext)(EGLDisplay, EGLConfig, EGLContext, const EGLint*);
    EGLSurface (*CreatePbufferSurface)(EGLDisplay, EGLConfig, const EGLint*);
    unsigned (*MakeCurrent)(EGLDisplay, EGLSurface, EGLSurface, EGLContext);
} egl;

bool has(const char* list, const char* name) {
    const std::size_t n = std::strlen(name);
    for (const char* p = list; p && (p = std::strstr(p, name)); p += n)
        if ((p == list || p[-1] == ' ') && (p[n] == ' ' || p[n] == 0)) return true;
    return false;
}

/// A GL ES 3.1 context if the driver has one, else 3.0, current on this thread.
bool setup(int* minor) {
    void* lib = dlopen("libEGL.so.1", RTLD_NOW);
    if (!lib) return false;
#define LOAD(n) egl.n = reinterpret_cast<decltype(egl.n)>(dlsym(lib, "egl" #n))
    LOAD(GetProcAddress), LOAD(GetDisplay), LOAD(GetPlatformDisplay), LOAD(Initialize), LOAD(QueryString), LOAD(BindAPI);
    LOAD(ChooseConfig), LOAD(CreateContext), LOAD(CreatePbufferSurface), LOAD(MakeCurrent);
#undef LOAD
    EGLDisplay dpy = nullptr;
    if (egl.GetPlatformDisplay && has(egl.QueryString(nullptr, kExtensions), "EGL_MESA_platform_surfaceless"))
        dpy = egl.GetPlatformDisplay(kPlatformSurfacelessMESA, nullptr, nullptr);
    if (!dpy) dpy = egl.GetDisplay(nullptr);
    if (!dpy || !egl.Initialize(dpy, nullptr, nullptr) || !egl.BindAPI(kOpenGLESAPI)) return false;
    const EGLint attrs[] = {kRenderableType, kOpenGLES3Bit, kSurfaceType, kPbufferBit, kRedSize, 8, kGreenSize, 8, kBlueSize, 8, kAlphaSize, 8, kNone};
    EGLConfig config = nullptr;
    EGLint n = 0;
    if (!egl.ChooseConfig(dpy, attrs, &config, 1, &n) || n == 0) return false;
    EGLContext ctx = nullptr;
    for (*minor = 1; *minor >= 0 && !ctx; --*minor) {
        const EGLint ca[] = {kContextMajor, 3, kContextMinor, *minor, kNone};
        ctx = egl.CreateContext(dpy, config, nullptr, ca);
    }
    ++*minor;
    if (!ctx) return false;
    EGLSurface surface = nullptr;
    if (!has(egl.QueryString(dpy, kExtensions), "EGL_KHR_surfaceless_context")) {
        const EGLint pa[] = {kWidth, 1, kHeight, 1, kNone};
        surface = egl.CreatePbufferSurface(dpy, config, pa);
    }
    return egl.MakeCurrent(dpy, surface, surface, ctx) != 0;
}

/// check.zig's host on GL ES: the current context; readback through the texture's framebuffer.
struct GlesHost {
    const gpu::Device& d;
    bool Errors() const {
        bool failed = false;
        while (d.fns->GetError() != gpu::gl::kNoError) failed = true;
        return failed;
    }
    gpu::Upload Upload(gpu::Staging* staging) { return gpu::Upload(d, staging); }
    bool Submit() {
        d.fns->Finish();
        return !Errors();
    }
    bool ReadTexture(const gpu::Texture& t, std::uint8_t* out, std::size_t) {
        d.fns->BindFramebuffer(gpu::gl::kFramebuffer, t.fbo);
        d.fns->PixelStorei(gpu::gl::kPackAlignment, 1);
        d.fns->ReadPixels(0, 0, gpu::gl::Sizei(t.width), gpu::gl::Sizei(t.height), gpu::gl::kRGBA, gpu::gl::kUnsignedByte, out);
        d.fns->BindFramebuffer(gpu::gl::kFramebuffer, 0);
        return !Errors();
    }
    bool ReadBuffer(const gpu::Buffer& b, void* out, std::size_t size) {
        gpu::ReadBuffer(d, b, 0, out, size);
        return !Errors();
    }
};

} // namespace

int main() {
    int minor = 0;
    gpu::GlFns fns;
    if (!setup(&minor) || !fns.Load(egl.GetProcAddress)) {
        std::printf("skip: no GL ES 3 driver\n");
        return 0;
    }
    const gpu::Device d{&fns};
    GlesHost h{d};
    const bool rtt = checks::RenderToTexture(d, h);
    const bool compute = minor >= 1 && fns.HasCompute();
    const bool cs = compute && checks::Compute(d, h);
    std::printf("%s render-to-texture, %s compute (C++ lcgf/gpu.hpp on GL ES 3.%d)\n", rtt ? "ok  " : "FAIL", compute ? (cs ? "ok  " : "FAIL") : "skip", minor);
    return rtt && (cs || !compute) ? 0 : 1;
}
