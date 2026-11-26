{
  description = "LCGF: Lightweight Comptime Graphics Framework";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay.url = "github:mitchellh/zig-overlay";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      zig-overlay,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        # One exact Zig development build (docs/DESIGN.md): 0.18.0-dev.1151+8dfb7a7cc, chosen for
        # its loop auto-vectorizer. Change it on purpose only, and re-run the census and bench.
        zig = zig-overlay.packages.${system}."master-2026-11-14";
        # The shader translator (docs/DEPENDENCIES.md): naga-cli from crates.io, pinned. Used only
        # to regenerate the committed translations in src/render/shaders/ (ci/run.sh shaders).
        naga-cli = pkgs.rustPlatform.buildRustPackage rec {
          pname = "naga-cli";
          version = "30.0.2";
          src = pkgs.fetchCrate {
            inherit pname version;
            hash = "sha256-40wlyw1nIgI/+WRkbc3Na2IS+vcG6JDJr9mJMlmAD6k=";
          };
          cargoHash = "sha256-v2nxue/x+f64e9B+aGVCoPABqbEX7vZrw6xswNRoaOk=";
          doCheck = false;
        };
      in
      rec {
        devShells.default = pkgs.mkShell {
          packages = [
            zig
            pkgs.python3
            pkgs.binutils # objdump, for the branch census (docs/CHECKS.md)
          ];
          # One global cache per Zig store path, so the system Zig 0.16 cache is never shared.
          shellHook = ''export ZIG_GLOBAL_CACHE_DIR="''${XDG_CACHE_HOME:-$HOME/.cache}/zig-${builtins.baseNameOf zig}"'';
        };
        # GPU pixel checks (docs/CHECKS.md section 4, lane tools-golden): wgpu-py on
        # Mesa's lavapipe, so no GPU or system driver is needed.
        devShells.golden = pkgs.mkShell {
          inputsFrom = [ devShells.default ];
          packages = [
            (pkgs.python3.withPackages (ps: [ ps.wgpu ]))
            # A headless X server for the X11 shell's tests (ci/run.sh x11).
            pkgs.xvfb
            pkgs.xvfb-run
            # A compositor with no display or input devices, for the Wayland shell's example
            # (lane shell-wayland, ci/run.sh wayland-weston). A CI tool; the shell links nothing.
            pkgs.weston
            # The Direct3D 12 back end under Wine (ci/run.sh d3d12): its d3d12.dll is vkd3d,
            # drawing through this shell's lavapipe.
            pkgs.wineWow64Packages.stable
          ];
          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [
            pkgs.vulkan-loader
            pkgs.libglvnd
          ];
          VK_ICD_FILENAMES = "${pkgs.mesa}/share/vulkan/icd.d/lvp_icd.x86_64.json";
          # EGL and GL ES (lane render-gles): libglvnd's libEGL / libGLESv2 dispatching to Mesa,
          # forced onto llvmpipe so a machine with a GPU draws the same pixels.
          __EGL_VENDOR_LIBRARY_FILENAMES = "${pkgs.mesa}/share/glvnd/egl_vendor.d/50_mesa.json";
          LIBGL_ALWAYS_SOFTWARE = "1";
          GALLIUM_DRIVER = "llvmpipe";
          EGL_LOG_LEVEL = "fatal";
        };
        # The web back end and shell in a real browser (lanes render-web, shell-web): headless
        # Chromium with WebGPU on its bundled SwiftShader (the vulkan-loader from the golden
        # shell lets Chromium find it). Driven over the DevTools pipe by src/render/web/browser.py;
        # CI only (ci/jobs/web.sh, `# shell: web`).
        devShells.web = pkgs.mkShell {
          inputsFrom = [ devShells.golden ];
          packages = [ pkgs.chromium ];
          inherit (devShells.golden) LD_LIBRARY_PATH VK_ICD_FILENAMES;
        };
        # Hardware counters for the benchmark (lane optimise, docs/perf/cache.md): perf stat
        # over a whole run; `zig build bench -- --counters` counts per pass itself.
        devShells.bench = pkgs.mkShell {
          inputsFrom = [ devShells.default ];
          packages = [ pkgs.perf ];
        };
        # Shader translation and validation (lane shaders): the golden shell plus naga-cli,
        # spirv-val and glslangValidator, and the Khronos validation layer for the custom-draw
        # probe (ci/jobs/custom-draw.sh).
        devShells.shaders = pkgs.mkShell {
          inputsFrom = [ devShells.golden ];
          packages = [
            naga-cli
            pkgs.spirv-tools
            pkgs.glslang
            pkgs.vulkan-validation-layers
          ];
          inherit (devShells.golden) LD_LIBRARY_PATH VK_ICD_FILENAMES;
          VK_LAYER_PATH = "${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d";
        };
        # Competitor harnesses in Rust and QML (bench/vs/, docs/perf/vs.md): cargo and rustc for
        # egui, Iced and Slint (crates pinned by each Cargo.lock), Qt 6 for Qt Quick. Comparison
        # only, CI only (ci/jobs/vs-*.sh, `# shell: vs`); never used by `zig build`.
        devShells.vs = pkgs.mkShell {
          inputsFrom = [ devShells.default ];
          packages = [
            pkgs.cargo
            pkgs.rustc
            # The bindings' format checks (ci/jobs/bindings.sh): cargo fmt and clang-format.
            pkgs.rustfmt
            pkgs.clang-tools
            # The C++ bindings' check (ci/jobs/bindings.sh) builds with CMake.
            pkgs.cmake
            # ...and counts the runtime scenes' instructions against Zig's (bindings/check/parity.sh).
            pkgs.perf
            # ...and translates its WGSL shaders with naga (lcgf_add_shader); static UIs' frames
            # built without Zig are checked with clang (specialized) as well as gcc.
            naga-cli
            pkgs.clang
            pkgs.pkg-config
            pkgs.libx11
            pkgs.cairo
            pkgs.gtk4
            pkgs.xvfb
            pkgs.xvfb-run
            pkgs.qt6.qtbase
            pkgs.qt6.qtdeclarative
          ];
          # Source-only comparators, available exclusively in the benchmark shell.
          NUKLEAR_SRC = pkgs.fetchFromGitHub {
            owner = "Immediate-Mode-UI";
            repo = "Nuklear";
            rev = "f101764f7a2ec99e0db7895d148069eda96cce2b"; # v4.13.4
            hash = "sha256-4JFgxAay5jlfE/sKsWzbA8ORJqEavJf8jyOv8M9sD5A=";
          };
          MICROUI_SRC = pkgs.fetchFromGitHub {
            owner = "rxi";
            repo = "microui";
            rev = "0850aba860959c3e75fb3e97120ca92957f9d057";
            hash = "sha256-oilNz95OZJ5mv6NA17fnwnFmXq6L7j1w5Nkg/34gf64=";
          };
          QT_PLUGIN_PATH = "${pkgs.qt6.qtbase}/${pkgs.qt6.qtbase.qtPluginPrefix}";
          QML_IMPORT_PATH = "${pkgs.qt6.qtdeclarative}/${pkgs.qt6.qtbase.qtQmlPrefix}";
        };
      }
    );
}
