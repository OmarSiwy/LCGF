#!/usr/bin/env python3
"""Check commit messages in a git range against CONTRIBUTING.md.

    python3 tools/commitlint/commitlint.py main..HEAD
    python3 tools/commitlint/commitlint.py --self-test

Subjects are 1 to 72 characters. Merge commits are skipped.
"""
import subprocess
import sys

def problems(message):
    subject = message.split("\n", 1)[0].strip()
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


def self_test():
    assert problems("Fix a typo in the README") == []
    assert problems("x" * 73)
    assert problems("\n\nbody")
    print("commitlint self-test ok")


def main():
    if sys.argv[1:] == ["--self-test"]:
        return self_test()
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    bad = 0
    for sha, message in commits(sys.argv[1]):
        for p in problems(message):
            print("{} {}: {}".format(sha[:10], message.split("\n", 1)[0][:60], p))
            bad += 1
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
