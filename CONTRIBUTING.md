# Contributing

## Set up

```
nix develop          # Zig 0.17.1, Python 3, objdump
zig version          # must print 0.17.1
zig build test
```

Without Nix, install Zig 0.17.1 exactly; no other version is supported.

## One logical change per commit

- A commit does one thing: one plan commit, one fix, one port. If the message needs "and" between
  two unrelated things, it is two commits.
- **Every commit builds and passes its tests.** Before committing:
  ```
  zig build test
  zig build fmt
  (cd prototype && zig build test)
  ```
  No "fix the build" follow-ups. A history in which every commit is green is what makes
  `git bisect` and reverting one commit safe.
- Compress after the second use: duplicate once, extract when a second caller appears
  (`docs/CODE_STANDARD.md`).

## CI jobs

Each CI job is one file, `ci/jobs/<name>.sh`; `ci/run.sh <name>` runs it and `ci/run.sh all` runs
every job not marked `# all: no`. Add a job by adding a file: the workflow builds its matrix from
that directory, so neither `ci/run.sh` nor `.github/workflows/ci.yml` needs editing.

## Commit messages

```
<plan title, exactly>              subject: the title from `python3 plan/plan.py show <id>`

Why the change is shaped the way it is, and how "Done when" was shown:
the test name, or the tool output with its numbers.

Plan-Id: C0101                     trailer: the only record of progress
```

Commits outside the plan have no `Plan-Id` and a plain imperative subject of at most 72 characters.
`python3 tools/commitlint/commitlint.py main..HEAD` checks both forms; CI runs it with `zig build fmt`.

## Work in a lane

1. `python3 plan/plan.py next` shows lanes that can start.
2. Branch `plan/<lane>` from `main`; the branch marks the lane as taken.
3. Do the commits of `python3 plan/plan.py prompt <lane>` in order, inside the lane's home.
4. Report what you did and what in the plan was wrong; fix the plan in `plan/gen/`, not by
   working around it.

## Rules

The full list is in `CLAUDE.md` and `docs/DESIGN.md`. In short: port the prototype, do not
redesign it; keep the four rules (columns, explicit SIMD, branchless per-row loops, caller owns
memory and flow); respect the tiers (`docs/ARCHITECTURE.md`); add no dependency that is not in
`docs/DEPENDENCIES.md`; measure before claiming.
