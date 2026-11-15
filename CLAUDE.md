# Agent brief

You are one of several agents building a GUI framework in **Zig 0.17.1** from a fixed plan of 848
commits. Other agents work on other parts at the same time. Your job is the brief you were given
(`python3 plan/plan.py prompt <lane>`), done exactly, and an honest report at the end.

## Read first, in this order

1. `docs/ZIG_0_17_1.md`. Zig changed a lot; code written from memory of older versions does not
   compile. Every statement in that file was checked on the 0.17.1 compiler.
2. `docs/DESIGN.md`. The architecture, the four rules, and the decisions that are settled.
3. Your brief, and the references it lists under each commit.

`prototype/` holds working, tested code for the core (`ui.zig`), a renderer (`ui_wgpu.zig`), usage
and tests (`example.zig`) and the comptime front end (`comptime_ui_probe.zig`). `prototype/API.md`
is an index of every public declaration. When a commit cites the prototype, that code is the
reference behaviour.

## Commands

```
zig version                              # must print 0.17.1; stop and say so if it does not
zig build test                           # at the repository root once commit C0001 exists
(cd prototype && zig build test)         # the prototype's own tests; must keep passing
zig fmt --check .
python3 plan/plan.py next                # lanes that can start now
python3 plan/plan.py lane <lane>         # a lane's commits and their state
python3 plan/plan.py show C0101          # one commit in full
python3 plan/plan.py prompt <lane>       # the brief for a lane
python3 plan/plan.py check               # plan and history are consistent
python3 tools/zigcheck/zigcheck.py       # settle a question about the language or std
```

More checks (branch census, benchmark, GPU pixel check): `docs/CHECKS.md`.

## How the work is organised

- The plan is `plan/plan.json`. A **lane** is a sequence of commits in one area with one home
  directory. Commits inside a lane are sequential; different lanes run in parallel.
- Work on a branch named `plan/<lane>`. The branch's existence is how others see the lane is taken.
- One git commit per plan commit. Subject line = the plan title. The message ends with the trailer
  `Plan-Id: C0101`. That trailer is the only record of progress: `plan.py` reads it from history.
- A commit is finished when its **Done when** condition is shown by a test or a tool's output, and
  `zig build test` and `zig fmt --check .` pass.

## Rules

1. **Port, do not redesign.** Where the plan cites prototype code, move that behaviour into the
   lane's home and keep its results. Improvements belong to the commits that ask for them.
2. **Keep the four rules** of `docs/DESIGN.md`: columns and `u32` indices, explicit `@Vector` over
   padded columns, no data-dependent branch in a per-row loop, and an API where the caller owns
   memory and control flow. A commit that breaks one needs a measured reason in its message.
3. **Respect the tiers.** Tier 0 code imports no allocator, no I/O, no OS and no GPU API. Renderers
   and shells are never imported by the core.
4. **No new dependencies** beyond `docs/DEPENDENCIES.md`.
5. **Stay in your lane's home.** If a commit cannot be done without editing another lane's files,
   that is a missing dependency in the plan: stop and report it.
6. **Do not weaken an acceptance test** to make it pass, and do not mark work done that is not.
   "Blocked, because ..." is a good result; a commit that only looks finished is not.
7. **Measure before claiming.** Performance and size statements in commit messages or docs come
   from the tools in `docs/CHECKS.md`, with the numbers included.
8. **Ask, do not choose,** on the owner's decisions listed in `docs/DESIGN.md` (licence, name, CI).

## What is solid and what is not

- Solid: everything in `prototype/` (tests pass in Debug, ReleaseSafe and ReleaseFast, at 2, 4, 8
  and 16 SIMD lanes, and it cross-compiles for five targets), `docs/ZIG_0_17_1.md`, and the numbers
  in `docs/CHECKS.md`.
- Intent, not fact: the plan beyond the commits that port prototype code. Titles and splits for
  shells, text shaping, accessibility and the GPU back ends were written before any of that code
  existed. Expect to find mistakes there, and report them instead of working around them.
- Targets, not results: every gate in `docs/GATES.md` marked "Target".

## Your report

For each commit: its id, the git hash, and how "Done when" was shown (the test name or the tool
output). Then, separately: anything in the plan that was wrong, missing or in the wrong order;
anything you could not verify; and anything you changed outside your lane's home, with the reason.
