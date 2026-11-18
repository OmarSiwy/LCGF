# LCGF (Lightweight Comptime Graphics Framework)

A Zig GUI framework with runtime and comptime front ends over shared layout, interaction and draw-list data. The application owns its buffers, frame loop and graphics resources.

## Documentation

| To | Start here |
|---|---|
| Run or copy a standalone sample application | [Example projects](examples/README.md) |
| Add the package and select a renderer | [Package options](docs/release/package.md) |
| Build a UI | [Runtime guide](docs/guide/runtime.md), [comptime guide](docs/guide/comptime.md) |
| Compile HTML and CSS to native widgets | [Decomposer guide and feature inventory](tools/decomposer/README.md) |
| Integrate a renderer, platform or custom drawing | [Backends](docs/guide/backends.md), [porting](docs/guide/porting.md), [custom rendering](docs/guide/custom.md) |
| Work with text or diagnose a compile error | [Text guide](docs/guide/text.md), [compiler errors](docs/guide/errors.md) |
| Look up a declaration | [Public API index](docs/api/API.md), [ownership and API review](docs/release/api-review.md) |
| Compare frameworks | [Latest twelve-framework CI results](https://github.com/OmarSiwy/LCGF/blob/benchmark-results/README.md), [workloads and methodology](docs/perf/vs.md), [historical results](docs/perf/RESULTS.md), [capability matrix](docs/TARGETS.md) |
| Reproduce performance and footprint measurements | [Performance guide](docs/guide/perf.md), [CI checks](docs/CHECKS.md) |
| Find release information | [Changelog](CHANGELOG.md), [compatibility policy](docs/release/compatibility.md), [dependency licences](docs/release/licenses.md) |

Use `nix develop -c zig build test` to run the framework tests and `nix develop -c zig build docs` to regenerate the declaration index and verify the guides. Run `nix develop -c zig build embedded-sim` to replay the counter on the simulated SPI board.

Post-release design work is tracked in [TODO.md](TODO.md).

## Original development plan

The following handoff records how the implementation plan was set up.

## What is here

| Path | What it is |
|---|---|
| `CLAUDE.md` | The brief every agent reads first: rules, commands, how progress is recorded. |
| `docs/ZIG_0_17_1.md` | What changed in Zig, verified on the compiler. The single most useful file for an agent. |
| `docs/DESIGN.md` | Architecture, the four rules, settled decisions, and the three decisions that are yours. |
| `docs/CHECKS.md` | How to repeat every measurement, with the recorded output. |
| `docs/TARGETS.md`, `GATES.md`, `DEPENDENCIES.md`, `REFERENCES.md` | The 30 targets and the framework comparison, the release gates, the dependency list, and implementation references. |
| `tools/zigcheck/` | 70 compile checks behind the Zig notes. Run it on your machine first. |
| `.claude/skills/` | The two design guides the API follows (system API design, data-oriented design). |

## Build and verify

Run the package tests and formatting checks from the repository root with the pinned toolchain.

```sh
nix develop -c zig build test fmt
```

The platform and renderer jobs run through `ci/run.sh`. Benchmarks, release gates and recorded results are linked in the comparison section above. [Verification commands](docs/CHECKS.md) · [Contributing](CONTRIBUTING.md)
