#!/bin/sh
# The bindings' gate: the same UIs, the same input, frame by frame, in Zig (ComptimeUi, no seam),
# in Zig through the seam, in C++ (CMake, no Zig) and in Rust (cargo, no Zig). Every draw list
# and every event must be byte-identical. Usage: bindings/check/run.sh [prefix]
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
prefix=${1:-$root/zig-out}
work=${LCGF_CHECK_DIR:-$root/zig-out/bindings-check}
rm -rf "$work"; mkdir -p "$work"
python3 "$root/bindings/check/inputs.py" "$work/inputs.txt" "$work/page.txt"

cmake -S "$root/bindings/cpp/check" -B "$work/cpp" -DCMAKE_PREFIX_PATH="$prefix" \
    -DLCGF_SPECS="$root/src/abi/testdata" -DLCGF_SHADERS="$root/src/render/gpu" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$work/cpp" >/dev/null

have_rust=no; SKIP_RUST=${SKIP_RUST:-no}
if [ "$SKIP_RUST" = no ] && command -v cargo >/dev/null; then
    have_rust=yes
    LCGF_PREFIX="$prefix" LCGF_SPECS="$root/src/abi/testdata" LCGF_SHADERS="$root/src/render/gpu" \
        cargo build --release --quiet --manifest-path "$root/bindings/rust/Cargo.toml" --target-dir "$work/rust" -p lcgf-check --bins
fi

for ui in toolbar mixer panel; do
    "$prefix/bin/lcgf-dump" "$ui" comptime "$work/inputs.txt" "$work/$ui.zig.bin"
    "$prefix/bin/lcgf-dump" "$ui" seam "$work/inputs.txt" "$work/$ui.seam.bin"
    "$work/cpp/lcgf-cpp-check" "$ui" "$work/inputs.txt" "$work/$ui.cpp.bin"
    cmp "$work/$ui.zig.bin" "$work/$ui.seam.bin"
    cmp "$work/$ui.zig.bin" "$work/$ui.cpp.bin"
    langs="Zig through the seam, C++"
    if [ $have_rust = yes ]; then
        "$work/rust/release/lcgf-check" "$ui" "$work/inputs.txt" "$work/$ui.rust.bin"
        cmp "$work/$ui.zig.bin" "$work/$ui.rust.bin"
        langs="$langs, Rust"
    fi
    frames=$(grep -vc '^set' "$work/inputs.txt")
    echo "ok   $ui: $frames frames, $(wc -c < "$work/$ui.zig.bin") bytes of draw lists, identical in Zig, $langs"
done

# examples/markup's HTML page: its Zig spec frontend (the Zig widgets), and its `.zon` through the
# seam in Zig, C++ (lcgf_add_ui) and Rust (include_ui!). Every draw list and event must be
# byte-identical.
ui=counter
"$prefix/bin/lcgf-dump" $ui comptime "$work/page.txt" "$work/$ui.zig.bin"
"$prefix/bin/lcgf-dump" $ui seam "$work/page.txt" "$work/$ui.seam.bin"
"$work/cpp/lcgf-cpp-check" $ui "$work/page.txt" "$work/$ui.cpp.bin"
cmp "$work/$ui.zig.bin" "$work/$ui.seam.bin"
cmp "$work/$ui.zig.bin" "$work/$ui.cpp.bin"
langs="Zig through the seam, C++"
if [ $have_rust = yes ]; then
    "$work/rust/release/lcgf-check" $ui "$work/page.txt" "$work/$ui.rust.bin"
    cmp "$work/$ui.zig.bin" "$work/$ui.rust.bin"
    langs="$langs, Rust"
fi
python3 "$root/bindings/check/events.py" "$work/$ui.zig.bin" >/dev/null
echo "ok   markup $ui: $(grep -vc '^set' "$work/page.txt") frames, $(wc -c < "$work/$ui.zig.bin") bytes of draw lists, identical in Zig's spec frontend, $langs"

# The GPU half: one frame through lcgf_render.gpu (Zig), lcgf/gpu.hpp (C++) and lcgf::gpu (Rust),
# recorded as native calls (bindings/check/record.c); the logs must be equal.
"$prefix/bin/lcgf-gpu-dump" "$work/gpu.zig.txt"
"$work/cpp/lcgf-cpp-gpu-check" "$work/gpu.cpp.txt"
cmp "$work/gpu.zig.txt" "$work/gpu.cpp.txt"
langs="C++"
if [ $have_rust = yes ]; then
    "$work/rust/release/lcgf-gpu-check" "$work/gpu.rust.txt"
    cmp "$work/gpu.zig.txt" "$work/gpu.rust.txt"
    langs="$langs, Rust"
fi
echo "ok   gpu: $(wc -l < "$work/gpu.zig.txt") lines of recorded Vulkan calls, identical in Zig, $langs"

# Metal, recorded on Linux: resources, pipelines (with their MSL) and a frame made through the
# Zig projection, lcgf/gpu.hpp with LCGF_GPU_METAL and lcgf::gpu with `metal`, each talking to the
# stand-in Objective-C runtime (objc_record.c). The three logs must be equal.
if [ -f "$prefix/lib/liblcgf_objc_record.so" ]; then
    objc="$prefix/lib/liblcgf_objc_record.so"
    "$prefix/bin/lcgf-metal-dump" "$objc" "$work/metal.zig.txt"
    "$work/cpp/lcgf-cpp-metal-check" "$objc" "$work/metal.cpp.txt"
    cmp "$work/metal.zig.txt" "$work/metal.cpp.txt"
    langs="C++"
    if [ $have_rust = yes ]; then
        LCGF_PREFIX="$prefix" LCGF_SHADERS="$root/src/render/gpu" cargo build --release --quiet \
            --manifest-path "$root/bindings/rust/Cargo.toml" --target-dir "$work/rust-metal" -p lcgf-check --features metal \
            --bin lcgf-metal-check --bin lcgf-metal-device-check
        "$work/rust-metal/release/lcgf-metal-check" "$objc" "$work/metal.rust.txt"
        cmp "$work/metal.zig.txt" "$work/metal.rust.txt"
        langs="$langs, Rust"
    fi
    echo "ok   metal: $(wc -l < "$work/metal.zig.txt") lines of recorded Objective-C messages, identical in Zig, $langs"
    # check.zig's checks on a Metal device: they run on a Mac and say "skip" here.
    "$work/cpp/lcgf-cpp-metal-device-check"
    if [ $have_rust = yes ]; then "$work/rust-metal/release/lcgf-metal-device-check"; fi
    # And the header as a Mac compiles it, when a Zig compiler is at hand to cross-compile.
    if command -v zig >/dev/null; then
        for f in metal_check metal_device_check; do
            zig c++ -target aarch64-macos -std=c++20 -Wall -Wextra -Werror -DLCGF_GPU_METAL -c -o "$work/$f.macos.o" \
                -I "$prefix/include" -I "$work/cpp/lcgf_gen/metal" -I "$root/bindings/cpp/check" "$root/bindings/cpp/check/$f.cpp"
        done
        echo "ok   metal: the Metal checks compile for aarch64-macos with -Wall -Wextra -Werror"
    fi
else
    echo "skip metal: no liblcgf_objc_record.so (the recorder is for x86-64 Linux)"
fi

# Direct3D 12, recorded on Linux: the same resources, pipelines (HLSL and root signatures) and frame
# through the Zig D3D12 projection, lcgf/gpu.hpp with LCGF_GPU_D3D12 and lcgf::gpu with `d3d12`, on
# the recording device of d3d12_record.c (over DirectX-Headers). The three logs must be equal.
if [ -x "$prefix/bin/lcgf-d3d12-dump" ]; then
    "$prefix/bin/lcgf-d3d12-dump" "$work/d3d12.zig.txt"
    "$work/cpp/lcgf-cpp-d3d12-check" "$work/d3d12.cpp.txt"
    cmp "$work/d3d12.zig.txt" "$work/d3d12.cpp.txt"
    langs="C++"
    if [ $have_rust = yes ]; then
        LCGF_PREFIX="$prefix" LCGF_SHADERS="$root/src/render/gpu" cargo build --release --quiet \
            --manifest-path "$root/bindings/rust/Cargo.toml" --target-dir "$work/rust-d3d12" -p lcgf-check --features d3d12 --bin lcgf-d3d12-check
        "$work/rust-d3d12/release/lcgf-d3d12-check" "$work/d3d12.rust.txt"
        cmp "$work/d3d12.zig.txt" "$work/d3d12.rust.txt"
        langs="$langs, Rust"
    fi
    echo "ok   d3d12: $(wc -l < "$work/d3d12.zig.txt") lines of recorded COM calls, identical in Zig, $langs"
    # And the header as MinGW compiles it for Windows, when a Zig compiler is at hand.
    if command -v zig >/dev/null; then
        zig c++ -target x86_64-windows-gnu -std=c++20 -Wall -Wextra -Werror -DLCGF_GPU_D3D12 -c -o "$work/d3d12_check.windows.o" \
            -I "$prefix/include" -I "$work/cpp/lcgf_gen/d3d12" "$root/bindings/cpp/check/d3d12_check.cpp"
        echo "ok   d3d12: lcgf/gpu.hpp compiles for x86_64-windows-gnu (MinGW's d3d12.h) with -Wall -Wextra -Werror"
    fi
else
    echo "skip d3d12: no lcgf-d3d12-dump (the recorder is for x86-64 Linux)"
fi

# lcgf/gpu.hpp and lcgf::gpu on a real Vulkan device (lavapipe in CI): check.zig's checks, with
# pipelines and bind groups made from WGSL that lcgf-gen reflected.
"$work/cpp/lcgf-cpp-vk-check"
if [ $have_rust = yes ]; then "$work/rust/release/lcgf-vk-check"; fi
# The same checks on GL ES (llvmpipe through EGL): lcgf/gpu.hpp with LCGF_GPU_GLES and
# lcgf::gpu with the `gles` feature, over naga's GLSL ES.
"$work/cpp/lcgf-cpp-gles-check"
if [ $have_rust = yes ]; then
    LCGF_PREFIX="$prefix" LCGF_SHADERS="$root/src/render/gpu" cargo build --release --quiet \
        --manifest-path "$root/bindings/rust/Cargo.toml" --target-dir "$work/rust-gles" -p lcgf-check --features gles --bin lcgf-gles-check
    "$work/rust-gles/release/lcgf-gles-check"
fi
# And on wgpu-native, when the prefix has it (`zig build abi -Dwgpu-native=v29`): lcgf/gpu.hpp
# with LCGF_GPU_WGPU and lcgf::gpu with `wgpu`, over the WGSL itself. The Rust crate declares the
# webgpu.h structs it uses; their sizes and field offsets must be the C header's.
if [ -e "$prefix/lib/libwgpu_native.so" ] || [ -e "$prefix/lib/libwgpu_native.dylib" ]; then
    export LD_LIBRARY_PATH="$prefix/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    "$work/cpp/lcgf-cpp-wgpu-check"
    if [ $have_rust = yes ]; then
        LCGF_PREFIX="$prefix" LCGF_SHADERS="$root/src/render/gpu" cargo build --release --quiet \
            --manifest-path "$root/bindings/rust/Cargo.toml" --target-dir "$work/rust-wgpu" -p lcgf-check --features wgpu --bin lcgf-wgpu-check
        "$work/rust-wgpu/release/lcgf-wgpu-check"
        cc -I"$prefix/include" "$root/bindings/check/wgpu_layout.c" -o "$work/wgpu-layout"
        "$work/wgpu-layout" > "$work/wgpu-layout.c.txt"
        "$work/rust-wgpu/release/lcgf-wgpu-check" --layout > "$work/wgpu-layout.rust.txt"
        cmp "$work/wgpu-layout.c.txt" "$work/wgpu-layout.rust.txt"
        echo "ok   wgpu layout: $(wc -l < "$work/wgpu-layout.c.txt") webgpu.h structs, the same size and field offsets in Rust as in C"
    fi
else
    echo "skip wgpu: the prefix has no wgpu-native (zig build abi -Dwgpu-native=v29)"
fi

# Rows made by the caller: a sweep of styles, each made into a row by Zig's `Template.from`, by
# lcgf::Row in C++ and by Row::from in Rust, and by the library's lcgf_template_from.
"$prefix/bin/lcgf-rt-dump" rows 4096 "$work/rows.bin"
"$work/cpp/lcgf-cpp-rt-check" rows "$work/rows.bin"
langs="C++"
if [ $have_rust = yes ]; then
    "$work/rust/release/lcgf-rt-check" rows "$work/rows.bin"
    langs="$langs, Rust"
fi
echo "ok   rows: 4096 styles, the same 66-word row from Zig, the library, $langs"

# Ids: C++'s and Rust's compile-time Id (FNV-1a, `with`) against Zig's Id.hash over a sweep of
# names of every length to 40 and every byte value.
"$prefix/bin/lcgf-rt-dump" ids 4096 "$work/ids.bin"
"$work/cpp/lcgf-cpp-rt-check" ids "$work/ids.bin"
langs="C++"
if [ $have_rust = yes ]; then
    "$work/rust/release/lcgf-rt-check" ids "$work/ids.bin"
    langs="$langs, Rust"
fi
echo "ok   ids: 4096 names, the same id and child id in Zig, $langs"

# The runtime front end: bench/scenes' scenes (and the gate's `kit` and `canvas`) built each frame from C++ (lcgf/runtime.hpp) and
# Rust (lcgf::runtime), against the same scenes built in Zig.
for scene in form list text springs resize idle kit canvas act; do
    "$prefix/bin/lcgf-rt-dump" "$scene" 120 "$work/rt-$scene.zig.bin"
    "$work/cpp/lcgf-cpp-rt-check" "$scene" 120 "$work/rt-$scene.cpp.bin"
    cmp "$work/rt-$scene.zig.bin" "$work/rt-$scene.cpp.bin"
    langs="C++"
    if [ $have_rust = yes ]; then
        "$work/rust/release/lcgf-rt-check" "$scene" 120 "$work/rt-$scene.rust.bin"
        cmp "$work/rt-$scene.zig.bin" "$work/rt-$scene.rust.bin"
        langs="$langs, Rust"
    fi
    echo "ok   runtime $scene: 120 frames, $(wc -c < "$work/rt-$scene.zig.bin") bytes of draw lists, identical in Zig, $langs"
done

# Static UIs: the comptime examples through Zig's comptime pipeline (ct_layout, ct_paint,
# ct_events), and their `.zon` through lcgf-gen --static into C++ and Rust, over 240 frames of
# changing viewports, label text, list counts, conditions, choices and scroll offsets, with
# pointer and Tab input. The draw lists, events and focus must be byte-identical.
# C++ three ways: each UI's frame built by `zig build-obj` (lcgf-gen --lang zig, the fast path),
# and without Zig from C (lcgf-gen --lang c): by clang, specialized, and by gcc, a call into
# liblcgf. Rust the same three ways, its frames built by lcgf_build::static_ui.
for cc in clang gcc; do
    cmake -S "$root/bindings/cpp/check" -B "$work/cpp-$cc" -DCMAKE_PREFIX_PATH="$prefix" -DLCGF_ZIG=OFF \
        -DCMAKE_C_COMPILER=$cc -DLCGF_SPECS="$root/src/abi/testdata" -DLCGF_SHADERS="$root/src/render/gpu" -DCMAKE_BUILD_TYPE=Release >/dev/null
    cmake --build "$work/cpp-$cc" --target lcgf-cpp-ct-check >/dev/null
    if [ $have_rust = yes ]; then
        LCGF_ZIG=OFF CC=$cc LCGF_PREFIX="$prefix" LCGF_SPECS="$root/src/abi/testdata" LCGF_SHADERS="$root/src/render/gpu" \
            cargo build --release --quiet --manifest-path "$root/bindings/rust/Cargo.toml" --target-dir "$work/rust-$cc" -p lcgf-check --bin lcgf-ct-check
    fi
done
# volume is an HTML page in the static subset (lcgf-gen page.html --static), against a Zig twin.
for ui in mixer card settings badge dash todo feed controls palette meter volume; do
    "$prefix/bin/lcgf-ct-dump" "$ui" 240 "$work/ct-$ui.zig.bin"
    for how in cpp cpp-clang cpp-gcc; do
        "$work/$how/lcgf-cpp-ct-check" "$ui" 240 "$work/ct-$ui.$how.bin"
        cmp "$work/ct-$ui.zig.bin" "$work/ct-$ui.$how.bin"
        # Events: pointer and Tab input through ct_events in each language.
        cmp "$work/ct-$ui.zig.bin.events" "$work/ct-$ui.$how.bin.events"
    done
    langs="C++ (zig, clang, gcc)"
    if [ $have_rust = yes ]; then
        for how in rust rust-clang rust-gcc; do
            "$work/$how/release/lcgf-ct-check" "$ui" 240 "$work/ct-$ui.$how.bin"
            cmp "$work/ct-$ui.zig.bin" "$work/ct-$ui.$how.bin"
            cmp "$work/ct-$ui.zig.bin.events" "$work/ct-$ui.$how.bin.events"
        done
        langs="$langs, Rust (zig, clang, gcc)"
    fi
    events=$(python3 -c "import struct,sys; d=open(sys.argv[1],'rb').read(); r=[struct.unpack_from('<III',d,i) for i in range(0,len(d),12)]; print(sum(x[0]!=0xffffffff for x in r))" "$work/ct-$ui.zig.bin.events")
    echo "ok   static $ui: 240 frames, $(wc -c < "$work/ct-$ui.zig.bin") bytes of draw lists and $events pointer events, identical in Zig's comptime pipeline, $langs"
done

# Partial updates: one label's field laid out again over its dirty span (ct_layout's
# `relayout`), and colours patched into the draw list (ct_paint's `Patches`), in Zig and in the
# compiled C++ and Rust UIs. Draw lists and dirty sets must be byte-identical.
for ui in mixer dash todo palette meter; do
    "$prefix/bin/lcgf-ct-dump" "$ui" 240 "$work/ctp-$ui.zig.bin" partial
    "$work/cpp/lcgf-cpp-ct-check" "$ui" 240 "$work/ctp-$ui.cpp.bin" partial
    cmp "$work/ctp-$ui.zig.bin" "$work/ctp-$ui.cpp.bin"
    langs="C++"
    if [ $have_rust = yes ]; then
        "$work/rust/release/lcgf-ct-check" "$ui" 240 "$work/ctp-$ui.rust.bin" partial
        cmp "$work/ctp-$ui.zig.bin" "$work/ctp-$ui.rust.bin"
        langs="$langs, Rust"
    fi
    echo "ok   static $ui, partial: 120 relayouts and 60 patch frames, identical in Zig, $langs"
done

# The same with the tree and the stack too small: the inline pushes take the overflow paths.
for scene in form springs; do
    "$prefix/bin/lcgf-rt-dump" "$scene" 30 "$work/rt-$scene-tight.zig.bin" 40 3
    "$work/cpp/lcgf-cpp-rt-check" "$scene" 30 "$work/rt-$scene-tight.cpp.bin" 40 3
    cmp "$work/rt-$scene-tight.zig.bin" "$work/rt-$scene-tight.cpp.bin"
    if [ $have_rust = yes ]; then
        "$work/rust/release/lcgf-rt-check" "$scene" 30 "$work/rt-$scene-tight.rust.bin" 40 3
        cmp "$work/rt-$scene-tight.zig.bin" "$work/rt-$scene-tight.rust.bin"
    fi
    echo "ok   runtime $scene, 40 nodes and depth 3: overflowing frames identical in Zig, $langs"
done

# liblcgf_auto.a: the same UIs and scenes from C++ and Rust with each lane width forced in turn
# (LCGF_FORCE_LANES; widths this CPU cannot run are skipped). Every width must make Zig's frames.
if [ -f "$prefix/lib/liblcgf_auto.a" ]; then
    cmake -S "$root/bindings/cpp/check" -B "$work/cpp-auto" -DCMAKE_PREFIX_PATH="$prefix" -DLCGF_LANES=auto \
        -DLCGF_SPECS="$root/src/abi/testdata" -DLCGF_SHADERS="$root/src/render/gpu" -DCMAKE_BUILD_TYPE=Release >/dev/null
    cmake --build "$work/cpp-auto" --target lcgf-cpp-check lcgf-cpp-rt-check lcgf-cpp-ct-check >/dev/null
    if [ $have_rust = yes ]; then
        LCGF_PREFIX="$prefix" LCGF_SPECS="$root/src/abi/testdata" LCGF_SHADERS="$root/src/render/gpu" \
            cargo build --release --quiet --manifest-path "$root/bindings/rust/Cargo.toml" --target-dir "$work/rust-auto" \
            -p lcgf-check --features lanes-auto --bin lcgf-check --bin lcgf-rt-check --bin lcgf-ct-check
    fi
    langs="C++"; [ $have_rust = yes ] && langs="C++, Rust"
    best=$(grep -q avx512bw /proc/cpuinfo 2>/dev/null && echo 16 || { grep -q avx2 /proc/cpuinfo 2>/dev/null && echo 8 || echo 4; })
    for w in 4 8 16; do
        [ "$w" -le "$best" ] || { echo "skip auto, $w lanes: this CPU cannot run them"; continue; }
        export LCGF_FORCE_LANES=$w
        for ui in toolbar mixer panel; do
            "$work/cpp-auto/lcgf-cpp-check" "$ui" "$work/inputs.txt" "$work/$ui.auto.bin"
            cmp "$work/$ui.zig.bin" "$work/$ui.auto.bin"
            if [ $have_rust = yes ]; then
                "$work/rust-auto/release/lcgf-check" "$ui" "$work/inputs.txt" "$work/$ui.auto.bin"
                cmp "$work/$ui.zig.bin" "$work/$ui.auto.bin"
            fi
        done
        for scene in form springs text; do
            "$work/cpp-auto/lcgf-cpp-rt-check" "$scene" 120 "$work/rt-$scene.auto.bin"
            cmp "$work/rt-$scene.zig.bin" "$work/rt-$scene.auto.bin"
            if [ $have_rust = yes ]; then
                "$work/rust-auto/release/lcgf-rt-check" "$scene" 120 "$work/rt-$scene.auto.bin"
                cmp "$work/rt-$scene.zig.bin" "$work/rt-$scene.auto.bin"
            fi
        done
        for ui in mixer dash todo; do
            "$work/cpp-auto/lcgf-cpp-ct-check" "$ui" 240 "$work/ct-$ui.auto.bin"
            cmp "$work/ct-$ui.zig.bin" "$work/ct-$ui.auto.bin"
            if [ $have_rust = yes ]; then
                "$work/rust-auto/release/lcgf-ct-check" "$ui" 240 "$work/ct-$ui.auto.bin"
                cmp "$work/ct-$ui.zig.bin" "$work/ct-$ui.auto.bin"
            fi
        done
        unset LCGF_FORCE_LANES
        echo "ok   auto, $w lanes: 3 UIs, 3 static UIs and 3 scenes from liblcgf_auto.a identical to Zig's, $langs"
    done
else
    echo "skip auto: no liblcgf_auto.a (x86-64 ELF targets only)"
fi

# Every widget of each UI had an event in the replay, so the comparison covered input too.
for ui in toolbar mixer panel; do python3 "$root/bindings/check/events.py" "$work/$ui.zig.bin"; done

# Frame time, each language over the same frames (not a gate: shown so a regression is seen).
for ui in mixer settings dash todo; do
    "$prefix/bin/lcgf-ct-dump" "$ui" 240 --bench
    for how in cpp cpp-clang cpp-gcc; do "$work/$how/lcgf-cpp-ct-check" "$ui" 240 --bench; done
    if [ $have_rust = yes ]; then
        for how in rust rust-clang rust-gcc; do "$work/$how/release/lcgf-ct-check" "$ui" 240 --bench; done
    fi
done
for ui in toolbar mixer; do
    "$prefix/bin/lcgf-dump" "$ui" comptime "$work/inputs.txt" --bench
    "$prefix/bin/lcgf-dump" "$ui" seam "$work/inputs.txt" --bench
    "$work/cpp/lcgf-cpp-check" "$ui" "$work/inputs.txt" --bench
    if [ $have_rust = yes ]; then "$work/rust/release/lcgf-check" "$ui" "$work/inputs.txt" --bench; fi
done
