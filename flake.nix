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
      {
        devShells.default = pkgs.mkShell {
          packages = [
            zig
            pkgs.python3
            pkgs.binutils # objdump, for the branch census (docs/CHECKS.md)
          ];
          # One global cache per Zig store path, so the system Zig 0.16 cache is never shared.
          shellHook = ''export ZIG_GLOBAL_CACHE_DIR="''${XDG_CACHE_HOME:-$HOME/.cache}/zig-${builtins.baseNameOf zig}"'';
        };
      }
    );
}
