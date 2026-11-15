"""Turns generated.json (from generate.py) into the files agents and people read:

    ../plan.json            the plan, with references resolved to places in this repo
    ../commits.csv          the same commits as a flat table
    ../../docs/REFERENCES.md  every reference name and where it lives

Run:  python3 generate.py && python3 export.py
Standard library only.

Commit ids are kept stable across edits of the plan by ids.json (see below). To rename a commit and
keep its id, change its key in ids.json as well.
"""
import csv
import json
import os

from refs import OURS, SPEC

HERE = os.path.dirname(os.path.abspath(__file__))
PLAN_DIR = os.path.dirname(HERE)
ROOT = os.path.dirname(PLAN_DIR)

G = json.load(open(os.path.join(HERE, "generated.json")))
TARGETS = json.load(open(os.path.join(HERE, "targets.json")))

# Where each file reference lives in this repository.
LOCAL = {
    "UI": "prototype/ui.zig",
    "WG": "prototype/ui_wgpu.zig",
    "EX": "prototype/example.zig",
    "API": "prototype/API.md",
    "CT": "prototype/comptime_ui_probe.zig",
    "MX": "docs/TARGETS.md",
    "CHK": "docs/CHECKS.md",
    "CASEY_API": ".claude/skills/system-api-design/SKILL.md (summary); original: caseymuratori.com/blog_0024",
    "CASEY_COMP": ".claude/skills/system-api-design/SKILL.md (summary); original: caseymuratori.com/blog_0015",
    "CASEY_CLEAN": ".claude/skills/data-oriented-design/SKILL.md (summary); original: computerenhance.com",
    "KELLEY_DOD": ".claude/skills/data-oriented-design/SKILL.md (summary); original: Andrew Kelley, Practical Data-Oriented Design (talk)",
    "FABIAN": ".claude/skills/data-oriented-design/SKILL.md (summary); original: dataorienteddesign.com",
    "ACTON": ".claude/skills/data-oriented-design/SKILL.md (summary); original: Mike Acton, CppCon 2014 (talk)",
    "ZIG17": "docs/ZIG_0_17_1.md (verified on the compiler); background: https://blog.codercops.com/blog/zig-0-17-upgrade-guide-breaking-changes-2026",
    "ZIG17_NOTES": "docs/ZIG_0_17_1.md (verified on the compiler); background: https://daily.dev/posts/zig-0-17-0-release-notes-y2kcmyvvv",
    "ZIG17_BUILD": "prototype/build.zig (verified example); background: https://dispatch-blog.hashnode.dev/zig-0-17-split-its-build-into-two-processes-why-that-matters",
    "ZIG_VEC": "docs/ZIG_0_17_1.md (verified on the compiler); background: https://ziggit.dev/t/vector-abuse/17854",
}


def short(desc):
    return desc.split(":")[0].split(" (")[0]


def build_refs(table, local):
    out = {}
    for key, (desc, where) in table.items():
        name = short(desc)
        entry = {"what": desc, "where": local.get(key, where)}
        out.setdefault(name, []).append(entry)
    return out


REFS = build_refs(OURS, LOCAL)
REFS["Targets matrix"] = REFS["GUI framework targets matrix"]
SPECS = build_refs(SPEC, {})


def lane_home(name):
    exact = {
        "repo": "repository root and docs/",
        "ci": "ci/ (and the CI configuration of your host)",
        "gates-doc": "docs/",
        "tools-census": "tools/census/",
        "tools-bench": "tools/bench/",
        "tools-golden": "tools/golden/",
        "tools-fuzz": "tools/fuzz/",
        "simd": "src/core/simd.zig",
        "types": "src/core/types.zig",
        "mem": "src/core/mem.zig",
        "input": "src/core/input.zig",
        "tree": "src/core/tree.zig",
        "sidelists": "src/core/ (strings.zig, texts.zig, customs.zig)",
        "hit": "src/interact/hit.zig",
        "interaction": "src/interact/interaction.zig",
        "focus": "src/interact/focus.zig",
        "keyboard": "src/interact/keyboard.zig",
        "gestures": "src/interact/gestures.zig",
        "context": "src/runtime/ (context.zig, frame.zig)",
        "signals": "src/runtime/signals.zig",
        "reuse": "src/runtime/reuse.zig",
        "scheduler": "src/runtime/scheduler.zig",
        "damage": "src/draw/damage.zig",
        "text-protocol": "src/text/protocol.zig",
        "font-load": "src/text/font/",
        "glyph-raster": "src/text/raster/",
        "shaping": "src/text/shape/",
        "unicode": "src/text/unicode/",
        "text-layout": "src/text/layout/",
        "font-fallback": "src/text/fallback/",
        "text-edit": "src/text/edit/",
        "render-iface": "src/render/ (iface.zig, conformance scenes)",
        "shaders": "src/render/shaders/",
        "shell-iface": "src/shell/ (iface.zig, headless.zig)",
        "widget-base": "src/widgets/ (base.zig)",
        "anim": "src/anim/",
        "theme": "src/theme/",
        "images": "src/assets/",
        "i18n": "src/i18n/",
        "bench-scenes": "bench/scenes/",
        "gates": "bench/gates/",
        "optimise": "the module being optimised; record every measurement in docs/perf/",
        "devtools": "src/devtools/",
        "docs": "docs/",
        "examples": "examples/",
        "embedded": "src/embedded/ and examples/embedded/",
        "release": "repository root and docs/",
        "milestones": "repository root (tags) and docs/",
    }
    if name in exact:
        return exact[name]
    for prefix, home in (
        ("layout-", "src/layout/"),
        ("ct-", "src/comptime/"),
        ("draw-", "src/draw/"),
        ("a11y-", "src/a11y/"),
    ):
        if name.startswith(prefix):
            return home
    for prefix, home in (("render-", "src/render/{}/"), ("shell-", "src/shell/{}/"), ("vs-", "bench/vs/{}/")):
        if name.startswith(prefix):
            return home.format(name[len(prefix):])
    if name.startswith("w-"):
        return "src/widgets/{}.zig".format(name[2:])
    raise SystemExit("no home for lane " + name)


def split_refs(text, table):
    out = []
    for part in [p.strip() for p in text.split(";") if p.strip()]:
        name, _, detail = part.partition(":")
        name = name.strip()
        if name not in table:
            raise SystemExit("unknown reference name: " + name)
        out.append({"ref": name, "detail": detail.strip()})
    return out


# Stable ids. generate.py numbers commits in file order, so an insertion would renumber everything
# after it and orphan the Plan-Id trailers already in git history. ids.json remembers the id each
# (lane, title) was first given; new commits get the next unused number; ids are never reused.
IDS_PATH = os.path.join(HERE, "ids.json")
first_run = not os.path.exists(IDS_PATH)
ids = {} if first_run else json.load(open(IDS_PATH))
next_number = max((int(v[1:]) for v in ids.values()), default=0) + 1
remap, added = {}, []
for c in G["commits"]:
    key = c["lane"] + "\t" + c["title"]
    if key not in ids:
        if first_run:
            ids[key] = c["id"]
        else:
            ids[key] = "C{:04d}".format(next_number)
            next_number += 1
            added.append(ids[key] + " " + c["title"])
    remap[c["id"]] = ids[key]
live = {c["lane"] + "\t" + c["title"] for c in G["commits"]}
retired = sorted(v for k, v in ids.items() if k not in live)
json.dump(ids, open(IDS_PATH, "w"), indent=0, sort_keys=True)

commits = []
for c in G["commits"]:
    commits.append({
        "id": remap[c["id"]],
        "title": c["title"],
        "lane": c["lane"],
        "phase": c["phase"],
        "wave": c["wave"],
        "critical": c["critical"],
        "deps": sorted(remap[d] for d in c["deps"]),
        "look_at": split_refs(c["ref"], REFS),
        "spec": split_refs(c["spec"], SPECS),
        "targets": [t.strip() for t in c["tg"].replace(";", ",").split(",") if t.strip()],
        "done_when": c["done"],
        "unblocks": c["unblocks"],
    })
for c in commits:
    for t in c["targets"]:
        assert t in TARGETS, (c["id"], t)

lanes = {}
for L in G["lanes"]:
    lanes[L["name"]] = {"phase": L["phase"], "home": lane_home(L["name"]), "commits": []}
for c in commits:
    lanes[c["lane"]]["commits"].append(c["id"])

plan = {
    "meta": {
        "commits": len(commits),
        "lanes": len(lanes),
        "waves": max(c["wave"] for c in commits),
        "critical_path_commits": sum(c["critical"] for c in commits),
        "how_to_read": "A commit can start when every id in deps is merged. Commits in one lane are sequential. "
                       "wave = 1 + the longest chain of prerequisites; commits in the same wave do not depend on each other.",
    },
    "phases": {k: {"name": v[0], "delivers": v[1]} for k, v in G["phases"].items()},
    "targets": TARGETS,
    "references": REFS,
    "specs": SPECS,
    "lanes": lanes,
    "commits": commits,
}
json.dump(plan, open(os.path.join(PLAN_DIR, "plan.json"), "w"), indent=1)

with open(os.path.join(PLAN_DIR, "commits.csv"), "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["id", "title", "wave", "depends_on", "look_at", "spec", "done_when", "lane", "home", "phase", "targets", "critical", "unblocks"])
    for c in commits:
        join = lambda items: "; ".join(i["ref"] + (": " + i["detail"] if i["detail"] else "") for i in items)
        w.writerow([c["id"], c["title"], c["wave"], " ".join(c["deps"]), join(c["look_at"]), join(c["spec"]), c["done_when"],
                    c["lane"], lanes[c["lane"]]["home"], c["phase"], " ".join(c["targets"]), "yes" if c["critical"] else "", c["unblocks"]])

used = {}
for c in commits:
    for r in c["look_at"]:
        used[r["ref"]] = used.get(r["ref"], 0) + 1
used_spec = {}
for c in commits:
    for r in c["spec"]:
        used_spec[r["ref"]] = used_spec.get(r["ref"], 0) + 1

md = ["# References", "",
      "Every name that appears in a commit's `look_at` or `spec` field, and where to find it.",
      "Generated by `plan/gen/export.py`; edit `plan/gen/refs.py`, not this file.", "",
      "## Sources the design came from", "",
      "| Name in the plan | What it is | Where | Commits |", "|---|---|---|---|"]
for name in sorted(REFS, key=lambda n: -used.get(n, 0)):
    if name == "Targets matrix":
        continue
    n = used.get(name, 0) + (used.get("Targets matrix", 0) if name == "GUI framework targets matrix" else 0)
    for e in REFS[name]:
        md.append("| {} | {} | {} | {} |".format(name, e["what"], e["where"], n))
md += ["", "`Targets matrix` in a commit means the same thing as `GUI framework targets matrix`.", "",
       "## Specifications the earlier sources do not cover", "",
       "| Name in the plan | Where | Commits |", "|---|---|---|"]
for name in sorted(SPECS, key=lambda n: -used_spec.get(n, 0)):
    for e in SPECS[name]:
        md.append("| {} | {} | {} |".format(e["what"], e["where"], used_spec.get(name, 0)))
open(os.path.join(ROOT, "docs", "REFERENCES.md"), "w").write("\n".join(md) + "\n")

print("plan.json: {} commits, {} lanes, {} waves".format(len(commits), len(lanes), plan["meta"]["waves"]))
if added:
    print("new ids:\n  " + "\n  ".join(added))
if retired:
    print("retired ids (in ids.json, no longer in the plan; a renamed title counts as a new commit): " + " ".join(retired))
