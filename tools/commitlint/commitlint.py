#!/usr/bin/env python3
"""Check commit messages in a git range against CONTRIBUTING.md.

    python3 tools/commitlint/commitlint.py main..HEAD
    python3 tools/commitlint/commitlint.py --self-test

A commit with a Plan-Id trailer must name a plan commit and use its title as the subject.
Any other commit needs a subject of 1 to 72 characters. Merge commits are skipped.
"""
import json
import re
import subprocess
import sys
from pathlib import Path

PLAN = Path(__file__).resolve().parents[2] / "plan" / "plan.json"
TRAILER = re.compile(r"^\s*Plan-Id:\s*(\S+)\s*$", re.I | re.M)


def problems(message, titles):
    subject = message.split("\n", 1)[0].strip()
    ids = TRAILER.findall(message)
    if len(ids) > 1:
        return ["more than one Plan-Id trailer: " + ", ".join(ids)]
    if ids:
        cid = ids[0]
        if cid not in titles:
            return ["Plan-Id {} is not in the plan".format(cid)]
        if subject != titles[cid]:
            return ["subject must be the plan title of {}: {!r}".format(cid, titles[cid])]
        return []
    if not subject:
        return ["empty subject"]
    if len(subject) > 72:
        return ["subject is {} characters; at most 72".format(len(subject))]
    return []


def commits(rev_range):
    out = subprocess.run(
        ["git", "log", "--no-merges", "--format=%H%x00%B%x01", rev_range],
        check=True, capture_output=True, text=True,
    ).stdout
    for record in out.split("\x01"):
        if record.strip():
            sha, message = record.strip("\n").split("\x00", 1)
            yield sha, message


def self_test(titles):
    cid, title = next(iter(titles.items()))
    assert problems("{}\n\nbody\n\nPlan-Id: {}".format(title, cid), titles) == []
    assert problems("wrong subject\n\nPlan-Id: {}".format(cid), titles)
    assert problems("x\n\nPlan-Id: C9999", titles)
    assert problems("Fix a typo in the README", titles) == []
    assert problems("x" * 73, titles)
    assert problems("\n\nbody", titles)
    print("commitlint self-test ok")


def main():
    titles = {c["id"]: c["title"] for c in json.loads(PLAN.read_text())["commits"]}
    if sys.argv[1:] == ["--self-test"]:
        return self_test(titles)
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    bad = 0
    for sha, message in commits(sys.argv[1]):
        for p in problems(message, titles):
            print("{} {}: {}".format(sha[:10], message.split("\n", 1)[0][:60], p))
            bad += 1
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
