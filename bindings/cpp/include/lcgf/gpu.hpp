// lcgf/gpu.hpp: lcgf_render.gpu for C++, shaped like Dawn's webgpu_cpp.h, on the back end the
// build picks. As in Zig (-Drender), one back end per build: define LCGF_GPU_GLES (GL ES 3),
// LCGF_GPU_WGPU (wgpu-native's webgpu.h), LCGF_GPU_METAL (Metal, through the Objective-C
// runtime opened at run time) or LCGF_GPU_D3D12 (Direct3D 12, on d3d12.h) before including it, or
// none for Vulkan. The types are that back
// end's handles with public fields; a call is the native call it stands for.
#pragma once
#if defined(LCGF_GPU_GLES) + defined(LCGF_GPU_WGPU) + defined(LCGF_GPU_METAL) + defined(LCGF_GPU_D3D12) > 1
#error "lcgf/gpu.hpp: define one of LCGF_GPU_GLES, LCGF_GPU_WGPU, LCGF_GPU_METAL and LCGF_GPU_D3D12"
#elif defined(LCGF_GPU_D3D12)
#include "gpu/d3d12.hpp"
#elif defined(LCGF_GPU_METAL)
#include "gpu/metal.hpp"
#elif defined(LCGF_GPU_GLES)
#include "gpu/gles.hpp"
#elif defined(LCGF_GPU_WGPU)
#include "gpu/wgpu.hpp"
#else
#include "gpu/vulkan.hpp"
#endif
