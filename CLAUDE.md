# Working on LCGF

Use the Zig version pinned in `flake.nix`. Read `docs/DESIGN.md` for the architecture and `docs/ZIG_0_17_1.md` for verified compiler behavior.

- Keep the core's columns, integer indices, SIMD over padded columns and caller-owned memory. Keep OS, allocator and GPU dependencies out of Tier 0.
- Use `docs/CODE_STANDARD.md`, `docs/DEPENDENCIES.md` and `CONTRIBUTING.md` when changing the implementation.
- Preserve observable behavior and verify changes on the normal production entry points. Report measurements with the workload and conditions that produced them.

```sh
nix develop -c zig build test fmt
nix develop -c ci/run.sh census-src
```

`docs/CHECKS.md` describes the remaining verification tools. `docs/GATES.md` tracks the release targets.
