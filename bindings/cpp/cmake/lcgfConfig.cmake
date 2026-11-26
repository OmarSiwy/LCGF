# The LCGF package for CMake, installed by `zig build abi` into <prefix>/lib/cmake/lcgf. It needs
# no Zig compiler: lcgf-gen and liblcgf are prebuilt.
#
#   find_package(lcgf REQUIRED)
#   add_executable(app main.cpp)
#   lcgf_add_ui(app mixer.zon)   # runs lcgf-gen: #include "mixer.lcgf.hpp"; links liblcgf
#
# LCGF_LANES picks the archive (4, 8 or 16 lanes) and the frame symbol the headers name. It
# defaults to what the compiler flags give: 8 when they enable AVX, else 4. LCGF_LANES=auto
# links liblcgf_auto.a (x86-64 Linux), which picks the width at run time from the CPU, for a
# program shipped to machines it does not know.
cmake_minimum_required(VERSION 3.20)
get_filename_component(_lcgf_prefix "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)
set(LCGF_GEN "${_lcgf_prefix}/bin/lcgf-gen" CACHE FILEPATH "lcgf-gen, the spec generator")

if(NOT DEFINED LCGF_LANES)
  include(CheckCXXSourceCompiles)
  set(CMAKE_REQUIRED_FLAGS "${CMAKE_CXX_FLAGS}")
  check_cxx_source_compiles("#if !defined(__AVX__)\n#error no\n#endif\nint main(){}" LCGF_HAVE_AVX)
  if(LCGF_HAVE_AVX)
    set(LCGF_LANES 8)
  else()
    set(LCGF_LANES 4)
  endif()
endif()

if(LCGF_LANES STREQUAL "auto")
  set(_lcgf_archive "${_lcgf_prefix}/lib/liblcgf_auto.a")
  set(_lcgf_lanes_def 0)
  if(NOT EXISTS "${_lcgf_archive}")
    message(FATAL_ERROR "LCGF_LANES=auto: ${_lcgf_archive} is built for x86-64 ELF targets only")
  endif()
else()
  set(_lcgf_archive "${_lcgf_prefix}/lib/liblcgf_l${LCGF_LANES}.a")
  set(_lcgf_lanes_def ${LCGF_LANES})
endif()

if(NOT TARGET lcgf::lcgf)
  add_library(lcgf::lcgf STATIC IMPORTED)
  set_target_properties(lcgf::lcgf PROPERTIES
    IMPORTED_LOCATION "${_lcgf_archive}"
    INTERFACE_INCLUDE_DIRECTORIES "${_lcgf_prefix}/include"
    INTERFACE_COMPILE_DEFINITIONS "LCGF_LANES=${_lcgf_lanes_def}"
    # A static UI's frame built from C (lcgf-gen --static --lang c) must keep Zig's arithmetic:
    # no a*b+c fused into an FMA.
    INTERFACE_COMPILE_OPTIONS "$<$<COMPILE_LANG_AND_ID:C,GNU,Clang,AppleClang>:-ffp-contract=off;-fno-strict-aliasing>"
    INTERFACE_COMPILE_FEATURES cxx_std_20)
endif()

# A static UI's frame is liblcgf's, specialized to the UI's tables: with a Zig compiler
# (LCGF_ZIG, found on PATH unless set to OFF), `zig build-obj` builds it from lcgf-gen --static
# --lang zig against the lcgf sources in share/lcgf/zig, as fast as Zig's own comptime UI.
# Without one it is built from C (lcgf-gen --static --lang c): specialized by clang, else a call
# into liblcgf's frame, slower (docs/guide/bindings.md). LCGF_ZIG_CPU is Zig's -mcpu for it.
if(NOT DEFINED LCGF_ZIG)
  find_program(LCGF_ZIG zig)
endif()
set(LCGF_ZIG_CPU "native" CACHE STRING "Zig's -mcpu for static UIs' frames")
set(_lcgf_zig_frames OFF)
if(LCGF_ZIG AND NOT LCGF_LANES STREQUAL "auto")
  set(_lcgf_zig_frames ON)
else()
  enable_language(C)
  if(NOT _lcgf_noted)
    set(_lcgf_noted ON)
    message(STATUS "lcgf: no Zig compiler for static UIs' frames (LCGF_ZIG, or zig on PATH; not with LCGF_LANES=auto): they are built from C, specialized only by clang and otherwise slower")
  endif()
endif()

# Generates <name>.lcgf.hpp from `spec` (a .zon UI spec) into the build tree and makes it
# includable by `target`, which also links liblcgf.
# lcgf_add_ui(target spec.zon [STATIC]): STATIC makes a static UI, the comptime pipeline's
# tables (lcgf::StaticUi: folded layout, paint templates) for a spec whose structure never
# changes, and builds its frame (above); without it the widgets' tables (lcgf::Ui: events,
# focus, springs).
# lcgf_add_ui(target page.html): an HTML page and its CSS, lowered to the same tables
# (docs/guide/markup.md, "C++ and Rust"). lcgf-gen writes a depfile, so editing the page or a
# stylesheet it links regenerates the header; its errors name the HTML or CSS line.
function(lcgf_add_ui target spec)
  cmake_parse_arguments(_ui "STATIC" "" "" ${ARGN})
  get_filename_component(_spec "${spec}" ABSOLUTE)
  get_filename_component(_name "${spec}" NAME_WE)
  set(_dir "${CMAKE_CURRENT_BINARY_DIR}/lcgf_gen")
  set(_out "${_dir}/${_name}.lcgf.hpp")
  if(_spec MATCHES "\\.html$")
    if(_ui_STATIC)
      message(FATAL_ERROR "lcgf_add_ui: an HTML page makes the widgets' tables; STATIC takes a .zon")
    endif()
    file(MAKE_DIRECTORY "${_dir}")
    add_custom_command(OUTPUT "${_out}"
      COMMAND "${LCGF_GEN}" "${_spec}" --lang cpp -o "${_out}" --depfile "${_out}.d"
      DEPENDS "${_spec}" "${LCGF_GEN}"
      DEPFILE "${_out}.d"
      COMMENT "lcgf-gen ${_name}.html"
      VERBATIM)
    target_sources(${target} PRIVATE "${_out}")
    target_include_directories(${target} PRIVATE "${_dir}")
    target_link_libraries(${target} PRIVATE lcgf::lcgf)
    return()
  endif()
  set(_static "")
  if(_ui_STATIC)
    # Its own directory, so one project can hold a static and a widgets' UI of the same name.
    set(_static "--static")
    set(_dir "${CMAKE_CURRENT_BINARY_DIR}/lcgf_gen_static")
    set(_out "${_dir}/${_name}.lcgf.hpp")
  endif()
  file(MAKE_DIRECTORY "${_dir}")
  add_custom_command(OUTPUT "${_out}"
    COMMAND "${LCGF_GEN}" "${_spec}" ${_static} --lang cpp -o "${_out}"
    DEPENDS "${_spec}" "${LCGF_GEN}"
    COMMENT "lcgf-gen ${_name}.zon ${_static}"
    VERBATIM)
  target_sources(${target} PRIVATE "${_out}")
  if(_ui_STATIC)
    set(_share "${_lcgf_prefix}/share/lcgf")
    if(_lcgf_zig_frames)
      set(_zig "${_dir}/${_name}.lcgf.zig")
      set(_obj "${_dir}/${_name}.frame.o")
      add_custom_command(OUTPUT "${_obj}"
        COMMAND "${LCGF_GEN}" "${_spec}" --static --lang zig -o "${_zig}"
        COMMAND "${LCGF_ZIG}" build-obj -OReleaseFast -mcpu "${LCGF_ZIG_CPU}" -fPIC --cache-dir "${_dir}/zig-cache"
          --dep lcgf "-Mroot=${_zig}" --dep build_options --dep unicode_tables "-Mlcgf=${_share}/zig/src/lcgf.zig"
          "-Mbuild_options=${_share}/zig/options_l${LCGF_LANES}.zig" "-Municode_tables=${_share}/zig/unicode_tables.zig"
          --name "${_name}_frame" "-femit-bin=${_obj}"
        DEPENDS "${_spec}" "${LCGF_GEN}"
        COMMENT "zig build-obj ${_name}'s frame"
        VERBATIM)
      target_sources(${target} PRIVATE "${_obj}")
      set_source_files_properties("${_obj}" PROPERTIES EXTERNAL_OBJECT ON GENERATED ON)
    else()
      set(_c "${_dir}/${_name}.lcgf.c")
      add_custom_command(OUTPUT "${_c}"
        COMMAND "${LCGF_GEN}" "${_spec}" --static --lang c -o "${_c}"
        DEPENDS "${_spec}" "${LCGF_GEN}"
        COMMENT "lcgf-gen ${_name}.zon --static --lang c"
        VERBATIM)
      target_sources(${target} PRIVATE "${_c}")
      set_source_files_properties("${_c}" PROPERTIES INCLUDE_DIRECTORIES "${_share}")
    endif()
  endif()
  target_include_directories(${target} PRIVATE "${_dir}")
  target_link_libraries(${target} PRIVATE lcgf::lcgf)
endfunction()

# Generates <name>.lcgf.hpp from a WGSL shader into the build tree: naga translates it to
# SPIR-V, and lcgf-gen reflects its bind groups as lcgf_render.gpu does (one struct per group,
# the shader's layouts and code). naga (naga-cli) must be on PATH or in LCGF_NAGA.
find_program(LCGF_NAGA naga)
# Generates <name>.lcgf.hpp from a WGSL shader for the GPU back end LCGF_GPU names (VULKAN, the
# default, GLES, WGPU or METAL): its bind groups reflected by lcgf-gen, and the back end's code
# (naga's SPIR-V for Vulkan, naga's GLSL ES per entry point for GL ES, the WGSL itself for wgpu,
# naga's MSL with its slots for Metal, naga's HLSL with its samplers registered for D3D12). Link
# lcgf::gpu_gles, lcgf::gpu_wgpu, lcgf::gpu_metal or lcgf::gpu_d3d12 to compile lcgf/gpu.hpp for
# the same back end. `MSL <file>` / `HLSL <file>` take a translation made already instead of
# running naga.
set(LCGF_GPU "VULKAN" CACHE STRING "lcgf/gpu.hpp's back end: VULKAN, GLES, WGPU, METAL or D3D12")
function(lcgf_add_shader target wgsl)
  cmake_parse_arguments(_arg "" "MSL;HLSL" "" ${ARGN})
  get_filename_component(_wgsl "${wgsl}" ABSOLUTE)
  get_filename_component(_name "${wgsl}" NAME_WE)
  # One directory per back end: the same shader can be built for two in one project.
  string(TOLOWER "${LCGF_GPU}" _gpu)
  set(_dir "${CMAKE_CURRENT_BINARY_DIR}/lcgf_gen/${_gpu}")
  set(_out "${_dir}/${_name}.lcgf.hpp")
  file(MAKE_DIRECTORY "${_dir}")
  set(_naga_cmds)
  set(_code_args)
  if(LCGF_GPU STREQUAL "VULKAN" OR LCGF_GPU STREQUAL "GLES" OR (LCGF_GPU STREQUAL "METAL" AND NOT _arg_MSL)
     OR (LCGF_GPU STREQUAL "D3D12" AND NOT _arg_HLSL))
    if(NOT LCGF_NAGA)
      message(FATAL_ERROR "lcgf_add_shader: naga (naga-cli) not found; set LCGF_NAGA")
    endif()
  endif()
  if(LCGF_GPU STREQUAL "VULKAN")
    set(_spv "${_dir}/${_name}.spv")
    list(APPEND _naga_cmds COMMAND "${LCGF_NAGA}" "${_wgsl}" "${_spv}")
    list(APPEND _code_args --spirv "${_spv}")
  elseif(LCGF_GPU STREQUAL "GLES")
    # The entry points decide the files naga writes, so they are read when configuring.
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${_wgsl}")
    execute_process(COMMAND "${LCGF_GEN}" --wgsl "${_wgsl}" --entry-points
      OUTPUT_VARIABLE _entries RESULT_VARIABLE _rc)
    if(NOT _rc EQUAL 0)
      message(FATAL_ERROR "lcgf_add_shader: lcgf-gen could not read ${wgsl}")
    endif()
    string(REPLACE "\n" ";" _entries "${_entries}")
    foreach(_line IN LISTS _entries)
      if(_line STREQUAL "")
        continue()
      endif()
      string(REPLACE " " ";" _f "${_line}")
      list(GET _f 0 _entry)
      list(GET _f 1 _stage)
      list(GET _f 2 _profile)
      list(GET _f 3 _ext)
      set(_glsl "${_dir}/${_name}.${_entry}.${_ext}")
      list(APPEND _naga_cmds COMMAND "${LCGF_NAGA}" --profile ${_profile} --shader-stage ${_stage} --entry-point ${_entry} "${_wgsl}" "${_glsl}")
      list(APPEND _code_args --glsl "${_entry}=${_glsl}")
    endforeach()
  elseif(LCGF_GPU STREQUAL "METAL")
    if(_arg_MSL)
      get_filename_component(_msl "${_arg_MSL}" ABSOLUTE)
    else()
      set(_msl "${_dir}/${_name}.metal")
      list(APPEND _naga_cmds COMMAND "${LCGF_NAGA}" "${_wgsl}" "${_msl}")
    endif()
    list(APPEND _code_args --msl "${_msl}")
  elseif(LCGF_GPU STREQUAL "D3D12")
    if(_arg_HLSL)
      get_filename_component(_hlsl "${_arg_HLSL}" ABSOLUTE)
    else()
      set(_hlsl "${_dir}/${_name}.hlsl")
      list(APPEND _naga_cmds COMMAND "${LCGF_NAGA}" "${_wgsl}" "${_hlsl}")
    endif()
    list(APPEND _code_args --hlsl "${_hlsl}")
  elseif(NOT LCGF_GPU STREQUAL "WGPU")
    message(FATAL_ERROR "lcgf_add_shader: LCGF_GPU is ${LCGF_GPU}; use VULKAN, GLES, WGPU, METAL or D3D12")
  endif()
  add_custom_command(OUTPUT "${_out}"
    ${_naga_cmds}
    COMMAND "${LCGF_GEN}" --wgsl "${_wgsl}" ${_code_args} --name "${_name}" --lang cpp -o "${_out}"
    DEPENDS "${_wgsl}" "${LCGF_GEN}"
    COMMENT "lcgf-gen ${_name}.wgsl (${LCGF_GPU})"
    VERBATIM)
  target_sources(${target} PRIVATE "${_out}")
  target_include_directories(${target} PRIVATE "${_dir}")
endfunction()

# lcgf/gpu.hpp on GL ES, wgpu-native or Metal: the define that picks the back end. The host
# links its own GL ES or wgpu-native library.
if(NOT TARGET lcgf::gpu_gles)
  add_library(lcgf::gpu_gles INTERFACE IMPORTED)
  set_target_properties(lcgf::gpu_gles PROPERTIES INTERFACE_COMPILE_DEFINITIONS LCGF_GPU_GLES
    INTERFACE_INCLUDE_DIRECTORIES "${_lcgf_prefix}/include" INTERFACE_COMPILE_FEATURES cxx_std_20)
  add_library(lcgf::gpu_wgpu INTERFACE IMPORTED)
  set_target_properties(lcgf::gpu_wgpu PROPERTIES INTERFACE_COMPILE_DEFINITIONS LCGF_GPU_WGPU
    INTERFACE_INCLUDE_DIRECTORIES "${_lcgf_prefix}/include" INTERFACE_COMPILE_FEATURES cxx_std_20)
  # Metal is opened at run time (dlopen), so nothing is linked but the loader.
  add_library(lcgf::gpu_metal INTERFACE IMPORTED)
  set_target_properties(lcgf::gpu_metal PROPERTIES INTERFACE_COMPILE_DEFINITIONS LCGF_GPU_METAL
    INTERFACE_INCLUDE_DIRECTORIES "${_lcgf_prefix}/include" INTERFACE_COMPILE_FEATURES cxx_std_20
    INTERFACE_LINK_LIBRARIES "${CMAKE_DL_LIBS}")
  # Direct3D 12: d3d12.h from the Windows SDK or MinGW on Windows; elsewhere DirectX-Headers, as
  # `zig build abi` installs them (for bindings/check's recorder).
  add_library(lcgf::gpu_d3d12 INTERFACE IMPORTED)
  if(WIN32)
    set_target_properties(lcgf::gpu_d3d12 PROPERTIES INTERFACE_COMPILE_DEFINITIONS LCGF_GPU_D3D12
      INTERFACE_INCLUDE_DIRECTORIES "${_lcgf_prefix}/include" INTERFACE_COMPILE_FEATURES cxx_std_20
      INTERFACE_LINK_LIBRARIES "d3d12;dxgi;d3dcompiler")
  else()
    set(_dxh "${_lcgf_prefix}/include/directx-headers")
    set_target_properties(lcgf::gpu_d3d12 PROPERTIES INTERFACE_COMPILE_DEFINITIONS LCGF_GPU_D3D12
      INTERFACE_INCLUDE_DIRECTORIES "${_lcgf_prefix}/include;${_dxh};${_dxh}/wsl/stubs;${_dxh}/directx"
      INTERFACE_COMPILE_FEATURES cxx_std_20)
  endif()
endif()
