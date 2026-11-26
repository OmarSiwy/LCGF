"""Writes the input scripts the bindings' gate replays: one frame per line, `x y buttons [tabs]`,
or `set <field> <value>` (the panel's list count and choice selector, set before a frame).

The pointer sweeps the top 130 pixels of an 800 x 600 window in steps, and at each stop hovers,
presses, drags 30 pixels right while held and releases: every widget of the three UIs is
hovered, clicked and, for sliders, dragged. Between sweeps, Tab presses move keyboard focus
and the panel's list and choice change.

The second file, when given, is for examples/markup's page: clicks in place (its buttons are
narrower than the drags above) and drags over its 166 x 166 card, Tab and Shift+Tab presses,
`set count` and `set clicks` between them."""
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

if len(sys.argv) > 2:
    out = []
    def clicks(ys):
        for y in ys:
            for x in range(4, 170, 6):
                out.extend([f"{x} {y} 0", f"{x} {y} 1", f"{x} {y} 0", f"{x} {y} 1", f"{x + 20} {y} 1", f"{x + 20} {y} 0"])
    clicks(range(20, 170, 7))
    out += ["-1 -1 0 1"] * 6 + ["set count 7", "-1 -1 0", "set clicks 3", "-1 -1 0", "set clicks 8", "-1 -1 0"]
    clicks((62, 100, 129))
    out += ["set clicks 0", "set count 0", "-1 -1 0"]
    open(sys.argv[2], "w").write("\n".join(out) + "\n")
