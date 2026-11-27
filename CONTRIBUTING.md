# Contributing

## Set up

```
nix develop          # Zig 0.18.0-dev.1151+8dfb7a7cc, Python 3, objdump
zig version          # must print 0.18.0-dev.1151+8dfb7a7cc
zig build test
```

Without Nix, install Zig 0.18.0-dev.1151+8dfb7a7cc exactly (ziglang.org/builds); no other build is supported.

## One logical change per commit

- A commit does one thing: one feature, one fix, or one port. If the message needs "and" between
  two unrelated things, it is two commits.
- **Every commit builds and passes its tests.** Before committing:
  ```
  zig build test
  zig build fmt
  zig build lint
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

Use an imperative subject of at most 72 characters. Include the reason for the change and relevant tests or measurements in the body. CI checks the commit range with `python3 ci/commitlint.py main..HEAD`.
