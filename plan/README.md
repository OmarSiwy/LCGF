# The plan

848 commits in 142 lanes and 19 phases. `plan.json` is what tools read; `commits.csv` and the
workbook are the same data for people.

## Reading a commit

```
python3 plan/plan.py show C0249
```

| Field | Meaning |
|---|---|
| `id` | `C0001` to `C0848`. Goes in the commit message as the trailer `Plan-Id: C0249`. |
| `title` | The subject line of the git commit. |
| `lane` | The sequence the commit belongs to. Commits in a lane are done in order. |
| `deps` | Commits that must be merged first: the previous one in the lane, plus any from other lanes. |
| `wave` | 1 + the longest chain of prerequisites. Commits in one wave are independent of each other. It is an ordering, not a calendar. |
| `critical` | On a longest chain: delaying it delays the last commit. 83 commits are. |
| `look_at` | What to read before writing it. Names resolve through `docs/REFERENCES.md`; most point into `prototype/`. |
| `spec` | An outside specification, for behaviour the earlier sources do not cover. |
| `done_when` | The acceptance test. |
| `targets` | Ids from `docs/TARGETS.md` that the commit advances. |

A lane also has a `home`: the directory or file its commits create and own.

## The work queue

```
python3 plan/plan.py status              # progress per phase, next critical commit
python3 plan/plan.py next                # lanes that can start now, critical path first
python3 plan/plan.py next --json         # the same, for a script that launches agents
python3 plan/plan.py lane layout-core    # [x] done  [>] can be done now  [ ] blocked, and by what
python3 plan/plan.py prompt layout-core  # the brief for an agent
python3 plan/plan.py prompt layout-core --max 4
python3 plan/plan.py prompt C0064        # a single commit
python3 plan/plan.py check               # plan is consistent; history respects it
python3 plan/plan.py --rev main next     # judge "done" by another branch than the current one
```

State is derived from git, so nothing has to be edited by hand:

- **done**: a commit reachable from `--rev` (default `HEAD`) carries `Plan-Id: <id>`.
- **claimed**: a branch `plan/<lane>` exists and is not merged into `--rev`. `next` hides claimed
  lanes; `next --all` shows them.
- **ready**: every prerequisite is done.

`check` fails if history contains a plan commit whose prerequisites are missing, the same id twice,
or an id that is not in the plan.

## A loop that works

```
main ──┬── worktree on plan/simd   ── agent A ──┐
       ├── worktree on plan/types  ── agent B ──┼── review ── merge to main ── plan.py next
       └── worktree on plan/mem    ── agent C ──┘
```

1. `plan.py next` on `main`.
2. For each lane you want to staff: create the branch `plan/<lane>` from `main`, and give the agent
   the output of `plan.py prompt <lane>`.
3. When an agent reports: run the tests and the relevant checks from `docs/CHECKS.md`, read its list
   of plan problems, merge.
4. Repeat. Lanes that were blocked appear in `next` once what they waited for is merged.

## Changing the plan

The plan will need changes; that is expected. Do not edit `plan.json` by hand.

```
cd plan/gen
# edit generate.py (lanes and commits) or refs.py (references)
python3 generate.py          # recomputes prerequisites, waves and the critical path
python3 export.py            # rewrites ../plan.json, ../commits.csv, ../../docs/REFERENCES.md
python3 build_xlsx.py        # optional: rewrites the workbook (needs the openpyxl package)
python3 ../plan.py check
```

Ids stay stable when the plan changes. `gen/ids.json` remembers the id each (lane, title) pair was
first given, so inserting a commit in the middle of a lane does not renumber the rest: the new commit
gets the next unused number (`C0849`, ...) and the lane's chain of prerequisites is rewired around it.
Ids are never reused. Changing a title makes it a new commit with a new id; to rename and keep the
id, change the key in `ids.json` too. A commit that is already in git history should not be removed
from the plan: `check` will report its trailer as unknown.

Where the lanes put their code is decided by `lane_home()` in `export.py`.
