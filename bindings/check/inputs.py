"""Writes the input script the bindings' gate replays: one frame per line, `x y buttons [tabs]`,
or `set <field> <value>` (the panel's list count and choice selector, set before a frame).

The pointer sweeps the top 130 pixels of an 800 x 600 window in steps, and at each stop hovers,
presses, drags 30 pixels right while held and releases: every widget of the three UIs is
hovered, clicked and, for sliders, dragged. Between sweeps, Tab presses move keyboard focus
and the panel's list and choice change."""
import sys

out = []
def sweep(ys):
    for y in ys:
        for x in range(4, 420, 18):
            out.extend([f"{x} {y} 0", f"{x} {y} 1", f"{x + 15} {y} 1", f"{x + 30} {y} 1", f"{x + 30} {y} 0"])

sweep((14, 24, 34, 44, 54))
out += ["-1 -1 0 1", "-1 -1 0 1", "-1 -1 0 1", "set mode 1", "set len 4", "-1 -1 0 1"]
sweep((64, 84, 104, 124))
out += ["set len 0", "set mode 0", "-1 -1 0", "-1 -1 0"]
open(sys.argv[1], "w").write("\n".join(out) + "\n")
