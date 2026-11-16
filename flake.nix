{
  description = "LCGR: Lightweight Comptime Graphics Renderer";

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
        # spirv-val and glslangValidator.
        devShells.shaders = pkgs.mkShell {
          inputsFrom = [ devShells.golden ];
          packages = [
            naga-cli
            pkgs.spirv-tools
            pkgs.glslang
          ];
          inherit (devShells.golden) LD_LIBRARY_PATH VK_ICD_FILENAMES;
        };
        # Competitor harnesses in Rust and QML (bench/vs/, docs/perf/vs.md): cargo and rustc for
        # egui, Iced and Slint (crates pinned by each Cargo.lock), Qt 6 for Qt Quick. Comparison
        # only, CI only (ci/jobs/vs-*.sh, `# shell: vs`); never used by `zig build`.
        devShells.vs = pkgs.mkShell {
          inputsFrom = [ devShells.default ];
          packages = [
            pkgs.cargo
            pkgs.rustc
            pkgs.pkg-config
            pkgs.qt6.qtbase
            pkgs.qt6.qtdeclarative
          ];
          QT_PLUGIN_PATH = "${pkgs.qt6.qtbase}/${pkgs.qt6.qtbase.qtPluginPrefix}";
          QML_IMPORT_PATH = "${pkgs.qt6.qtdeclarative}/${pkgs.qt6.qtbase.qtQmlPrefix}";
        };
      }
    );
}
