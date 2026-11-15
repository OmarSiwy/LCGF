#!/usr/bin/env python3
"""Work queue for the commit plan. Standard library only, Python 3.8+.

    python3 plan/plan.py status               progress per phase and on the critical path
    python3 plan/plan.py next [-n 20]         lanes that can be worked on right now
    python3 plan/plan.py show C0101           one commit and the state of its prerequisites
    python3 plan/plan.py lane layout-core     every commit of a lane, with state
    python3 plan/plan.py prompt layout-core   a self-contained brief for one agent: the ready run of that lane
    python3 plan/plan.py prompt C0101         the same for a single commit
    python3 plan/plan.py check                validate plan.json and the git history against it

How state is tracked (no status file, so parallel branches never conflict):
    done      a git commit reachable from --rev (default HEAD) has the trailer  Plan-Id: C0101
    claimed   a branch named plan/<lane> exists and is not merged into --rev
    ready     every prerequisite is done
"""
import argparse
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PLAN = json.load(open(os.path.join(HERE, "plan.json")))
COMMITS = PLAN["commits"]
BY_ID = {c["id"]: c for c in COMMITS}
LANES = PLAN["lanes"]
ID_RE = re.compile(r"C\d{4}")


def git(*args):
    try:
        p = subprocess.run(["git", "-C", ROOT] + list(args), capture_output=True, text=True)
    except FileNotFoundError:
        return None
    return p.stdout if p.returncode == 0 else None


def done_ids(rev):
    """Plan ids recorded as trailers in the history of rev, with how often each appears."""
    log = git("log", rev, "--format=%B%x00")
    if log is None:
        print("note: no git history at {} (not a repository yet, or no commits): nothing counts as done".format(rev), file=sys.stderr)
        return {}
    seen = {}
    for line in log.splitlines():
        m = re.match(r"\s*Plan-Id:\s*(.+)$", line, re.I)
        if m:
            for cid in ID_RE.findall(m.group(1)):
                seen[cid] = seen.get(cid, 0) + 1
    return seen


def claimed_lanes(rev):
    """Lanes with an unmerged branch plan/<lane>, local or remote."""
    out = git("for-each-ref", "--format=%(refname:short)", "--no-merged=" + rev, "refs/heads", "refs/remotes")
    lanes = {}
    for name in (out or "").split():
        if "plan/" in name:
            lane = name.split("plan/", 1)[1]
            if lane in LANES:
                lanes.setdefault(lane, name)
    return lanes


def ready_run(lane, done):
    """(run, blocked): the commits of a lane that can be done now, in order, and the first one that cannot."""
    rest = [BY_ID[i] for i in LANES[lane]["commits"] if i not in done]
    run, have = [], set(done)
    for c in rest:
        missing = [d for d in c["deps"] if d not in have]
        if missing:
            return run, (c, missing)
        run.append(c)
        have.add(c["id"])
    return run, None


def phase_name(p):
    return "{} {}".format(p, PLAN["phases"][p]["name"])


def clip(text, width):
    return text if len(text) <= width else text[: width - 1] + "…"


# ---------------------------------------------------------------- commands

def cmd_status(a):
    done = done_ids(a.rev)
    claimed = claimed_lanes(a.rev)
    ready = set()
    for lane in LANES:
        ready.update(c["id"] for c in ready_run(lane, done)[0])
    total = len(COMMITS)
    n_done = sum(1 for c in COMMITS if c["id"] in done)
    print("{} of {} commits done ({:.1f}%). {} ready now in {} lanes; {} lanes claimed.".format(
        n_done, total, 100.0 * n_done / total, len(ready),
        sum(1 for lane in LANES if ready_run(lane, done)[0]), len(claimed)))
    crit = [c for c in COMMITS if c["critical"]]
    crit_left = sorted((c for c in crit if c["id"] not in done), key=lambda c: c["wave"])
    print("Critical path: {} of {} done.{}".format(
        len(crit) - len(crit_left), len(crit),
        " Next: {} {} (lane {})".format(crit_left[0]["id"], crit_left[0]["title"], crit_left[0]["lane"]) if crit_left else ""))
    print()
    print("{:38s} {:>5s} {:>5s} {:>6s} {:>8s}".format("phase", "done", "ready", "total", "blocked"))
    for p in PLAN["phases"]:
        cs = [c for c in COMMITS if c["phase"] == p]
        d = sum(1 for c in cs if c["id"] in done)
        r = sum(1 for c in cs if c["id"] in ready)
        print("{:38s} {:5d} {:5d} {:6d} {:8d}".format(clip(phase_name(p), 38), d, r, len(cs), len(cs) - d - r))


def ready_lanes(done, claimed, include_claimed=False):
    rows = []
    for lane, info in LANES.items():
        run, blocked = ready_run(lane, done)
        if not run:
            continue
        if lane in claimed and not include_claimed:
            continue
        left = sum(1 for i in info["commits"] if i not in done)
        rows.append({
            "lane": lane, "phase": info["phase"], "home": info["home"],
            "ready": [c["id"] for c in run], "left_in_lane": left,
            "critical": any(c["critical"] for c in run), "wave": run[0]["wave"],
            "first_title": run[0]["title"], "claimed_by": claimed.get(lane),
            "then_blocked_on": blocked[1] if blocked else [],
        })
    rows.sort(key=lambda r: (not r["critical"], r["wave"], r["lane"]))
    return rows


def cmd_next(a):
    done = done_ids(a.rev)
    claimed = claimed_lanes(a.rev)
    rows = ready_lanes(done, claimed, a.all)
    if a.json:
        json.dump(rows[: a.n] if a.n else rows, sys.stdout, indent=1)
        print()
        return
    if not rows:
        print("Nothing is ready. Either everything is done, or every ready lane is claimed (try --all).")
        return
    print("Lanes that can start now. One agent per lane; lanes do not depend on each other at this point.")
    print("* = on the critical path (staff these first).")
    print()
    print("  {:20s} {:5s} {:>9s}  {:13s} {}".format("lane", "phase", "ready/left", "commits", "first commit"))
    for r in (rows[: a.n] if a.n else rows):
        span = r["ready"][0] if len(r["ready"]) == 1 else "{}..{}".format(r["ready"][0], r["ready"][-1][1:])
        mark = "*" if r["critical"] else " "
        tail = "  [claimed: {}]".format(r["claimed_by"]) if r["claimed_by"] else ""
        print("{} {:20s} {:5s} {:>4d}/{:<4d}  {:13s} {}{}".format(
            mark, r["lane"], r["phase"], len(r["ready"]), r["left_in_lane"], span, clip(r["first_title"], 70), tail))
    if a.n and len(rows) > a.n:
        print("  ... {} more (use -n 0 for all)".format(len(rows) - a.n))
    print()
    print("Brief for an agent:  python3 plan/plan.py prompt <lane>")


def state_of(c, done):
    if c["id"] in done:
        return "done"
    return "ready" if all(d in done for d in c["deps"]) else "blocked"


def describe_refs(items, table, indent):
    """One block per reference: its name and detail, then where to find it."""
    lines, listed = [], set()
    for it in items:
        entries = table[it["ref"]]
        lines.append("{}- {}".format(indent, it["ref"] + (": " + it["detail"] if it["detail"] else "")))
        if len(entries) == 1:
            lines.append("{}    at {}".format(indent, entries[0]["where"]))
        elif it["ref"] in listed:
            lines.append("{}    (same candidates as above)".format(indent))
        else:
            listed.add(it["ref"])
            lines.append("{}    the name covers several works; the detail says which:".format(indent))
            for e in entries:
                lines.append("{}      {} -> {}".format(indent, e["what"], e["where"]))
    return lines


def cmd_show(a):
    cid = a.id.upper()
    if cid not in BY_ID:
        sys.exit("unknown commit id " + a.id)
    done = done_ids(a.rev)
    c = BY_ID[cid]
    print("{}  {}".format(c["id"], c["title"]))
    print("state: {}   lane: {} ({})   wave: {}   critical: {}".format(
        state_of(c, done), c["lane"], phase_name(c["phase"]), c["wave"], "yes" if c["critical"] else "no"))
    print("home: {}".format(LANES[c["lane"]]["home"]))
    print("depends on:" + ("" if c["deps"] else " nothing"))
    for d in c["deps"]:
        print("  [{}] {} {}".format("x" if d in done else " ", d, BY_ID[d]["title"]))
    print("look at:")
    print("\n".join(describe_refs(c["look_at"], PLAN["references"], "  ")))
    if c["spec"]:
        print("specification:")
        print("\n".join(describe_refs(c["spec"], PLAN["specs"], "  ")))
    print("done when: {}".format(c["done_when"]))
    if c["targets"]:
        print("targets: " + ", ".join("{} {}".format(t, PLAN["targets"][t]["name"]) for t in c["targets"]))
    users = [x["id"] for x in COMMITS if cid in x["deps"]]
    print("unblocks: " + (" ".join(users) if users else "nothing directly"))


def cmd_lane(a):
    if a.name not in LANES:
        sys.exit("unknown lane {}. Lanes: {}".format(a.name, " ".join(LANES)))
    done = done_ids(a.rev)
    info = LANES[a.name]
    print("lane {}  ({})  home: {}".format(a.name, phase_name(info["phase"]), info["home"]))
    run_ids = {c["id"] for c in ready_run(a.name, done)[0]}
    for i in info["commits"]:
        c = BY_ID[i]
        mark = "x" if i in done else (">" if i in run_ids else " ")
        missing = [d for d in c["deps"] if d not in done and d not in run_ids]
        print("  [{}] {} w{:<2d} {}{}".format(mark, i, c["wave"], c["title"],
                                             "   (waits for {})".format(" ".join(missing)) if missing and mark == " " else ""))
    print("  x done   > can be done now, in this order   blank = blocked")


RULES = """\
Rules for every commit in this brief:
  1. Read CLAUDE.md, docs/ZIG_0_17_1.md and docs/DESIGN.md before writing code. Your memory of
     older Zig versions is wrong in places; the notes and the compiler win.
  2. One git commit per plan commit, in the order given. Subject = the plan title. End the message
     with the trailer shown (Plan-Id: ...). plan.py counts a commit as done by that trailer.
  3. Before each commit: `zig fmt --check .` and `zig build test` pass on Zig 0.17.1.
  4. "Done when" is the acceptance test. Show it with a test or a tool's output. If it cannot be
     met, stop and report why; do not weaken it.
  5. Where a commit cites prototype/ code, port that behaviour into the lane's home. Keep the
     prototype's results (its tests are the reference); do not redesign while porting.
  6. Stay inside the lane's home unless the commit itself requires otherwise. No new dependency
     without it being named in docs/DEPENDENCIES.md.
  7. Do not start commits that are not in this brief.

When you finish or get stuck, report for each commit: id, git hash, how "Done when" was shown.
Then list anything in the plan that was wrong, missing or out of order, so the plan can be fixed
in plan/gen/ rather than worked around."""


def cmd_prompt(a):
    done = done_ids(a.rev)
    target = a.target
    if target.upper() in BY_ID:
        c = BY_ID[target.upper()]
        missing = [d for d in c["deps"] if d not in done]
        if c["id"] in done and not a.force:
            sys.exit("{} is already done (use --force to print the brief anyway)".format(c["id"]))
        if missing and not a.force:
            sys.exit("{} is not ready: waits for {} (use --force to print the brief anyway)".format(c["id"], " ".join(missing)))
        lane, run = c["lane"], [c]
    elif target in LANES:
        lane = target
        run, blocked = ready_run(lane, done)
        if not run:
            if blocked:
                sys.exit("lane {} is blocked: {} waits for {}".format(lane, blocked[0]["id"], " ".join(blocked[1])))
            sys.exit("lane {} is finished".format(lane))
        if a.max:
            run = run[: a.max]
    else:
        sys.exit("'{}' is neither a commit id nor a lane".format(target))

    info = LANES[lane]
    in_run = {c["id"] for c in run}
    outside = []
    for c in run:
        for d in c["deps"]:
            if d not in in_run and d not in outside:
                outside.append(d)
    out = []
    out.append("You are implementing part of a GUI framework written in Zig 0.17.1. This brief is one lane of a")
    out.append("larger plan; other agents work on other lanes at the same time. Do only the commits listed here.")
    out.append("")
    out.append("Lane:    {}  ({}: {})".format(lane, phase_name(info["phase"]), PLAN["phases"][info["phase"]]["delivers"]))
    out.append("Home:    {}".format(info["home"]))
    out.append("Branch:  plan/{}  (create it from the integration branch; its existence marks the lane as taken)".format(lane))
    out.append("")
    if outside:
        out.append("Already merged, which this work builds on:")
        for d in outside:
            out.append("  {} {}{}".format(d, BY_ID[d]["title"], "" if d in done else "   <-- NOT MERGED YET"))
        out.append("")
    out.append("Commits, in order ({}):".format(len(run)))
    for c in run:
        out.append("")
        out.append("{}  {}".format(c["id"], c["title"]))
        out.append("  Read first:")
        out.extend(describe_refs(c["look_at"], PLAN["references"], "    "))
        if c["spec"]:
            out.append("  Specification (authoritative for behaviour the sources above do not cover):")
            out.extend(describe_refs(c["spec"], PLAN["specs"], "    "))
        out.append("  Done when: {}".format(c["done_when"]))
        if c["targets"]:
            out.append("  Advances: " + "; ".join("{} {}".format(t, PLAN["targets"][t]["name"]) for t in c["targets"])
                       + "  (definitions in docs/TARGETS.md)")
        out.append("  Trailer:   Plan-Id: {}".format(c["id"]))
    out.append("")
    out.append(RULES)
    print("\n".join(out))


def cmd_check(a):
    problems = []
    ids = [c["id"] for c in COMMITS]
    if len(set(ids)) != len(ids):
        problems.append("duplicate commit ids in plan.json")
    for c in COMMITS:
        for d in c["deps"]:
            if d not in BY_ID:
                problems.append("{} depends on unknown {}".format(c["id"], d))
        for r in c["look_at"]:
            if r["ref"] not in PLAN["references"]:
                problems.append("{} cites unknown reference {}".format(c["id"], r["ref"]))
        for r in c["spec"]:
            if r["ref"] not in PLAN["specs"]:
                problems.append("{} cites unknown specification {}".format(c["id"], r["ref"]))
        if not c["look_at"]:
            problems.append("{} has no reference".format(c["id"]))
    for lane, info in LANES.items():
        prev = None
        for i in info["commits"]:
            if prev and prev not in BY_ID[i]["deps"]:
                problems.append("{} does not depend on the commit before it in lane {}".format(i, lane))
            prev = i
    # cycles: every dependency must sit in an earlier wave
    for c in COMMITS:
        for d in c["deps"]:
            if d in BY_ID and BY_ID[d]["wave"] >= c["wave"]:
                problems.append("{} (wave {}) depends on {} (wave {})".format(c["id"], c["wave"], d, BY_ID[d]["wave"]))
    done = done_ids(a.rev)
    for cid, n in sorted(done.items()):
        if cid not in BY_ID:
            problems.append("history has Plan-Id {} which is not in the plan".format(cid))
            continue
        if n > 1:
            problems.append("history has {} commits with Plan-Id {}".format(n, cid))
        missing = [d for d in BY_ID[cid]["deps"] if d not in done]
        if missing:
            problems.append("{} is in history but its prerequisites are not: {}".format(cid, " ".join(missing)))
    for ref_table in (PLAN["references"],):
        for name, entries in ref_table.items():
            for e in entries:
                path = e["where"].split(" ")[0]
                if path.startswith(("prototype/", "docs/", ".claude/")) and not os.path.exists(os.path.join(ROOT, path)):
                    problems.append("reference '{}' points at {}, which is not in the repository".format(name, path))
    if problems:
        print("\n".join(problems))
        sys.exit(1)
    print("ok: {} commits, {} lanes, {} waves; {} done in history; every reference resolves".format(
        len(COMMITS), len(LANES), PLAN["meta"]["waves"], sum(1 for c in done if c in BY_ID)))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rev", default="HEAD", help="history that defines what is done (default HEAD; use your integration branch)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status").set_defaults(fn=cmd_status)
    p = sub.add_parser("next")
    p.add_argument("-n", type=int, default=20, help="rows to show; 0 for all")
    p.add_argument("--all", action="store_true", help="include lanes that are claimed by a branch")
    p.add_argument("--json", action="store_true", help="machine-readable output")
    p.set_defaults(fn=cmd_next)
    p = sub.add_parser("show")
    p.add_argument("id")
    p.set_defaults(fn=cmd_show)
    p = sub.add_parser("lane")
    p.add_argument("name")
    p.set_defaults(fn=cmd_lane)
    p = sub.add_parser("prompt")
    p.add_argument("target", help="a lane name or a commit id")
    p.add_argument("--max", type=int, default=0, help="at most this many commits of the lane's ready run")
    p.add_argument("--force", action="store_true", help="print a brief for a commit that is done or not ready")
    p.set_defaults(fn=cmd_prompt)
    sub.add_parser("check").set_defaults(fn=cmd_check)
    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        pass
