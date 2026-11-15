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
        # The plan pins Zig 0.17.1 exactly (docs/DESIGN.md).
        zig = zig-overlay.packages.${system}."0.17.1";
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
          packages = [ (pkgs.python3.withPackages (ps: [ ps.wgpu ])) ];
          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [ pkgs.vulkan-loader ];
          VK_ICD_FILENAMES = "${pkgs.mesa}/share/vulkan/icd.d/lvp_icd.x86_64.json";
        };
      }
    );
}
