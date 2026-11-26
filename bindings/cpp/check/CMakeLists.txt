# The C++ side of the bindings' gate (bindings/check/run.sh): built against an installed
# `zig build abi` prefix with CMake and a C++20 compiler, no Zig.
cmake_minimum_required(VERSION 3.20)
project(lcgf_cpp_check CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
find_package(lcgf REQUIRED)
add_executable(lcgf-cpp-check check.cpp)
lcgf_add_ui(lcgf-cpp-check ${LCGF_SPECS}/toolbar.zon)
lcgf_add_ui(lcgf-cpp-check ${LCGF_SPECS}/mixer.zon)
lcgf_add_ui(lcgf-cpp-check ${LCGF_SPECS}/panel.zon)
# examples/markup's HTML page, through lcgf-gen's HTML front end.
lcgf_add_ui(lcgf-cpp-check ${LCGF_SPECS}/../../../examples/markup/ui/counter.html)

# The GPU half: one frame recorded through lcgf/gpu.hpp into bindings/check/record.c's recorder.
find_library(LCGF_RECORD lcgf_record PATH_SUFFIXES lib REQUIRED)
add_executable(lcgf-cpp-gpu-check gpu_check.cpp)
target_link_libraries(lcgf-cpp-gpu-check PRIVATE lcgf::lcgf ${LCGF_RECORD})

# lcgf/gpu.hpp on a real device: check.zig's checks over the repository's own WGSL.
add_executable(lcgf-cpp-vk-check vk_check.cpp)
target_link_libraries(lcgf-cpp-vk-check PRIVATE lcgf::lcgf ${CMAKE_DL_LIBS})
lcgf_add_shader(lcgf-cpp-vk-check ${LCGF_SHADERS}/textured.wgsl)
lcgf_add_shader(lcgf-cpp-vk-check ${LCGF_SHADERS}/fill.wgsl)

# The same checks on GL ES (Mesa llvmpipe through EGL): lcgf/gpu.hpp with LCGF_GPU_GLES, and
# the shaders as naga's GLSL ES.
add_executable(lcgf-cpp-gles-check gles_check.cpp)
target_link_libraries(lcgf-cpp-gles-check PRIVATE lcgf::gpu_gles ${CMAKE_DL_LIBS})
target_include_directories(lcgf-cpp-gles-check PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
set(LCGF_GPU GLES)
lcgf_add_shader(lcgf-cpp-gles-check ${LCGF_SHADERS}/textured.wgsl)
lcgf_add_shader(lcgf-cpp-gles-check ${LCGF_SHADERS}/fill.wgsl)
set(LCGF_GPU VULKAN)

# And on wgpu-native, when the prefix has it (`zig build abi -Dwgpu-native=v29`): lcgf/gpu.hpp
# with LCGF_GPU_WGPU, the shaders as WGSL.
find_library(LCGF_WGPU_NATIVE wgpu_native PATHS ${CMAKE_PREFIX_PATH} PATH_SUFFIXES lib NO_DEFAULT_PATH)
if(LCGF_WGPU_NATIVE)
  add_executable(lcgf-cpp-wgpu-check wgpu_check.cpp)
  target_link_libraries(lcgf-cpp-wgpu-check PRIVATE lcgf::gpu_wgpu ${LCGF_WGPU_NATIVE} ${CMAKE_DL_LIBS})
  set_target_properties(lcgf-cpp-wgpu-check PROPERTIES BUILD_RPATH "${CMAKE_PREFIX_PATH}/lib")
  set(LCGF_GPU WGPU)
  lcgf_add_shader(lcgf-cpp-wgpu-check ${LCGF_SHADERS}/textured.wgsl)
  lcgf_add_shader(lcgf-cpp-wgpu-check ${LCGF_SHADERS}/fill.wgsl)
  set(LCGF_GPU VULKAN)
endif()

# Metal, recorded on Linux: lcgf/gpu.hpp with LCGF_GPU_METAL talking to bindings/check's stand-in
# Objective-C runtime, over the committed MSL the Zig side uses (src/render/shaders/gen/).
add_executable(lcgf-cpp-metal-check metal_check.cpp)
target_link_libraries(lcgf-cpp-metal-check PRIVATE lcgf::gpu_metal)
set(LCGF_GPU METAL)
lcgf_add_shader(lcgf-cpp-metal-check ${LCGF_SHADERS}/textured.wgsl MSL ${LCGF_SHADERS}/../shaders/gen/gpu_textured.metal)
lcgf_add_shader(lcgf-cpp-metal-check ${LCGF_SHADERS}/fill.wgsl MSL ${LCGF_SHADERS}/../shaders/gen/gpu_fill.metal)
# The same header on a real Metal device (a Mac): check.zig's checks; "skip" where there is none.
add_executable(lcgf-cpp-metal-device-check metal_device_check.cpp)
target_link_libraries(lcgf-cpp-metal-device-check PRIVATE lcgf::gpu_metal)
target_include_directories(lcgf-cpp-metal-device-check PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
lcgf_add_shader(lcgf-cpp-metal-device-check ${LCGF_SHADERS}/textured.wgsl MSL ${LCGF_SHADERS}/../shaders/gen/gpu_textured.metal)
lcgf_add_shader(lcgf-cpp-metal-device-check ${LCGF_SHADERS}/fill.wgsl MSL ${LCGF_SHADERS}/../shaders/gen/gpu_fill.metal)
set(LCGF_GPU VULKAN)

# Direct3D 12, recorded on Linux: lcgf/gpu.hpp with LCGF_GPU_D3D12 on bindings/check's recording
# device (d3d12_record.c, over DirectX-Headers), the committed HLSL the Zig side uses.
find_library(LCGF_D3D12_RECORD lcgf_d3d12_record PATHS ${CMAKE_PREFIX_PATH} PATH_SUFFIXES lib NO_DEFAULT_PATH)
if(LCGF_D3D12_RECORD AND NOT WIN32)
  add_executable(lcgf-cpp-d3d12-check d3d12_check.cpp)
  target_link_libraries(lcgf-cpp-d3d12-check PRIVATE lcgf::gpu_d3d12 ${LCGF_D3D12_RECORD})
  set(LCGF_GPU D3D12)
  lcgf_add_shader(lcgf-cpp-d3d12-check ${LCGF_SHADERS}/textured.wgsl HLSL ${LCGF_SHADERS}/../shaders/gen/gpu_textured.hlsl)
  lcgf_add_shader(lcgf-cpp-d3d12-check ${LCGF_SHADERS}/fill.wgsl HLSL ${LCGF_SHADERS}/../shaders/gen/gpu_fill.hlsl)
  set(LCGF_GPU VULKAN)
endif()

# Static UIs (lcgf-gen --static, lcgf::StaticUi): the comptime examples' frames, compared with
# Zig's comptime pipeline.
add_executable(lcgf-cpp-ct-check ct_check.cpp)
foreach(_ui mixer card settings badge dash todo feed controls palette meter)
  lcgf_add_ui(lcgf-cpp-ct-check ${LCGF_SPECS}/static/${_ui}.zon STATIC)
endforeach()

# The runtime front end from C++: bench/scenes' scenes, compared with Zig's frames.
add_executable(lcgf-cpp-rt-check rt_check.cpp)
target_link_libraries(lcgf-cpp-rt-check PRIVATE lcgf::lcgf)
