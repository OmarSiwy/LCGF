# GUI framework: handoff package

Everything an agent needs to work through the 848-commit plan without the conversation it came from.
Unzip this as the root of a new repository.

## What is here

| Path | What it is |
|---|---|
| `CLAUDE.md` | The brief every agent reads first: rules, commands, how progress is recorded. |
| `plan/plan.py` | The work queue. Says what can start now and prints a self-contained brief per lane. |
| `plan/plan.json`, `plan/commits.csv` | The plan: 848 commits, 142 lanes, each commit with prerequisites, references and an acceptance test. |
| `plan/gui-framework-commit-plan.xlsx` | The same plan as a workbook, for reading. |
| `plan/gen/` | The scripts that generate the plan. Change the plan here, not in `plan.json`. |
| `prototype/` | Working Zig 0.17.1 code: the core, a wgpu renderer, usage tests, the comptime-UI probe, a build file, and the check tools. |
| `docs/ZIG_0_17_1.md` | What changed in Zig, verified on the compiler. The single most useful file for an agent. |
| `docs/DESIGN.md` | Architecture, the four rules, settled decisions, and the three decisions that are yours. |
| `docs/CHECKS.md` | How to repeat every measurement, with the recorded output. |
| `docs/TARGETS.md`, `GATES.md`, `DEPENDENCIES.md`, `REFERENCES.md` | The 30 targets and the framework comparison, the release gates, the dependency list, and where every reference in the plan lives. |
| `tools/zigcheck/` | 70 compile checks behind the Zig notes. Run it on your machine first. |
| `.claude/skills/` | The two design guides the API follows (system API design, data-oriented design). |

## Start

1. **Toolchain.** `zig version` must print `0.17.1`. (This package was built with the `ziglang`
   0.17.1 Python package: `pip install ziglang==0.17.1`, then `python3 -m ziglang` is the compiler.)
2. **Confirm the package on your machine.**
   ```
   (cd prototype && zig build test && zig build cross)
   python3 tools/zigcheck/zigcheck.py
   ```
   If `zigcheck` reports a mismatch, your compiler differs from the one the notes were written for.
3. **Make it a repository** and commit everything: `git init -b main && git add -A && git commit -m "Import handoff package"`.
4. **Decide three things** agents are told not to decide: the licence, the package name, where CI
   runs. The first commit of the plan needs the first two.
5. **Hand out work.**
   ```
   python3 plan/plan.py next              # what can start now
   python3 plan/plan.py prompt repo       # the brief for that lane: give this text to an agent
   ```
   Give each agent its own checkout (a `git worktree` is enough) on a branch named `plan/<lane>`.
   When it reports, review, merge into `main`, and run `next` again.
6. **Keep score.** `python3 plan/plan.py status` and `python3 plan/plan.py check`.

## How parallel it gets

Progress is recorded by a `Plan-Id: C0101` trailer on each commit, so there is no status file to
conflict on. If whole lanes are merged in rounds, the plan takes 14 rounds:

| Round | Lanes at once | Commits | What |
|---|---|---|---|
| 1 | 1 | 5 | repository set-up |
| 2 | 2 | 4 | CI, gates document |
| 3 | 7 | 33 | check tools, SIMD helpers, value types, memory |
| 4 to 6 | 2 to 3 | 51 | input, tree, side lists, layout core, comptime spec, text protocol |
| 7 | 16 | 101 | the layout family, draw core, hit testing, font loading, Unicode |
| 8 to 10 | 10 to 18 | 262 | comptime front end, interaction, runtime front end, text, renderers |
| 11 | 57 | 278 | 42 widgets, shells interface, animation, accessibility core, benchmarks |
| 12 to 14 | 1 to 11 | 114 | platform shells, accessibility bridge, embedded profile, release |

Merging commits as they land, instead of whole lanes, opens later lanes sooner.

## Things to know before spending money on it

- **The start is narrow.** The first nine commits are close to sequential. Parallelism pays from
  round 3 and most of all in round 11.
- **One agent per lane, not per commit.** A brief covers the run of commits a lane can do now, so
  the cost of reading the context is paid once per lane. `--max N` caps a brief.
- **Sibling lanes can conflict.** Lanes of one family (`layout-*`, `ct-*`, `draw-*`) share a
  directory and sometimes a pass. Either give a family to one agent, or merge its lanes one at a
  time and let the next one rebase.
- **The plan is firm at the front and soft at the back.** Phases P01 to P06 (core, layout, comptime
  front end, interaction, runtime front end, draw list: 272 commits) stand on code that exists; 229
  of them cite the prototype directly. Platform shells (3 of 75 cite it), text (21 of 57),
  accessibility (7 of 20) and the embedded profile (1 of 10) were planned before any of their code
  existed, so expect agents to report splits that need changing. Fix those in `plan/gen/` and
  regenerate (`plan/README.md`); commit ids stay stable when you do.
- **"Faster and lighter than everything else" is a set of gates, not a result.** Only the gates
  marked "Measured" in `docs/GATES.md` have numbers behind them today.
- **Review is still needed.** `Done when` is checked by the agent that did the work. The branch
  census, the benchmark and the pixel check in `docs/CHECKS.md` are the independent checks; run them
  before merging anything that touches a pass or a renderer.
