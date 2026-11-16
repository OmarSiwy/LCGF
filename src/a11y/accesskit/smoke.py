#!/usr/bin/env python3
"""Screen-reader smoke test for the AccessKit bridge on Linux (ci/jobs/accesskit-linux.sh).

    dbus-run-session -- python3 smoke.py ACCESSKIT_SMOKE AT_SPI2_CORE OUT_DIR

Inside a private D-Bus session: starts the accessibility bus and registry (at-spi2-core),
enables accessibility, runs the example (zig-out/bin/accesskit-smoke) and then

1. walks its AT-SPI tree with busctl, as any assistive technology sees it, and checks the
   window, the Reset button, the Wireframe check box and the slider are there with their
   names and roles;
2. clicks Reset and Wireframe through AT-SPI's Action interface and checks the example ran
   them (it prints `resets=1`, `wireframe=true`);
3. runs Orca while the example moves focus round its controls, and checks Orca announced
   each one (`SPEECH OUTPUT:` lines in Orca's debug log).

Needs busctl (systemd), at-spi2-core and orca on PATH. Exits non-zero on the first failure.
"""
import json
import os
import subprocess
import sys
import time

app_bin, spi, out = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(out, exist_ok=True)
procs = []


def start(args, log):
    p = subprocess.Popen(args, stdout=open(os.path.join(out, log), "w"), stderr=subprocess.STDOUT)
    procs.append(p)
    return p


def busctl(*args):
    r = subprocess.run(["busctl", *args], capture_output=True, text=True)
    if r.returncode != 0:
        fail("busctl %s: %s" % (" ".join(args), r.stderr.strip()))
    return r.stdout


def fail(msg):
    print("FAIL:", msg)
    for p in procs:
        p.kill()
    sys.exit(1)


def wait_for(pred, what, seconds=10):
    end = time.time() + seconds
    while time.time() < end:
        if pred():
            return
        time.sleep(0.1)
    fail("timed out waiting for " + (what() if callable(what) else what))


start([spi + "/libexec/at-spi-bus-launcher", "--launch-immediately"], "bus.log")
wait_for(lambda: subprocess.run(["busctl", "--user", "status", "org.a11y.Bus"], capture_output=True).returncode == 0, "the accessibility bus")
start([spi + "/libexec/at-spi2-registryd"], "registry.log")
busctl("--user", "set-property", "org.a11y.Bus", "/org/a11y/bus", "org.a11y.Status", "IsEnabled", "b", "true")
address = json.loads(busctl("--user", "--json=short", "call", "org.a11y.Bus", "/org/a11y/bus", "org.a11y.Bus", "GetAddress"))["data"][0]
bus = "--address=" + address
wait_for(lambda: subprocess.run(["busctl", bus, "status", "org.a11y.atspi.Registry"], capture_output=True).returncode == 0, "the registry")

app_log = os.path.join(out, "app.log")
start([app_bin, "30"], "app.log")


def app_says(line):
    return line in open(app_log).read().split("\n")


wait_for(lambda: app_says("connected"), "the example's first update")


def call(dest, path, iface, method, *args):
    return json.loads(busctl(bus, "--json=short", "call", dest, path, iface, method, *args))["data"]


def prop(dest, path, iface, name):
    return json.loads(busctl(bus, "--json=short", "get-property", dest, path, iface, name))["data"]


# 1. The tree, from the registry's desktop down.
atspi_roles = {7: "check box", 23: "frame", 29: "label", 39: "panel", 43: "push button", 51: "slider", 62: "tool bar", 75: "application"}
nodes = {}  # name -> (role name, dest, path)


def walk(dest, path, depth):
    name = prop(dest, path, "org.a11y.atspi.Accessible", "Name")
    # AccessKit implements GetRole, not GetRoleName; the numbers are AtspiRole's.
    number = call(dest, path, "org.a11y.atspi.Accessible", "GetRole")[0]
    role = atspi_roles.get(number, str(number))
    print("  " * depth + "%s %r" % (role, name))
    if name:
        nodes.setdefault(name, (role, dest, path))
    for child_dest, child_path in call(dest, path, "org.a11y.atspi.Accessible", "GetChildren")[0]:
        walk(child_dest, child_path, depth + 1)


apps = call("org.a11y.atspi.Registry", "/org/a11y/atspi/accessible/root", "org.a11y.atspi.Accessible", "GetChildren")[0]
if len(apps) != 1:
    fail("expected one application on the bus, got %r" % apps)
walk(apps[0][0], apps[0][1], 0)
for name, role in [("LCGR example", "frame"), ("Reset", "push button"), ("Wireframe", "check box"), ("Add layer", "push button"), ("Layer 0", "label")]:
    if nodes.get(name, ("missing",))[0] != role:
        fail("%r: expected role %r, got %r" % (name, role, nodes.get(name)))
print("ok   tree: window, buttons, check box and labels with their names and roles")


# 2. Actions from the assistive technology's side.
def click(name):
    _, dest, path = nodes[name]
    actions = [a[0] for a in call(dest, path, "org.a11y.atspi.Action", "GetActions")[0]]
    if "click" not in actions:
        fail("%r offers no click: %r" % (name, actions))
    if not call(dest, path, "org.a11y.atspi.Action", "DoAction", "i", str(actions.index("click")))[0]:
        fail("DoAction click on %r returned false" % name)


click("Reset")
wait_for(lambda: app_says("resets=1"), "Reset's click to reach the example")
click("Wireframe")
wait_for(lambda: app_says("wireframe=true"), "Wireframe's click to reach the example")
print("ok   actions: AT-SPI clicks on Reset and Wireframe ran in the example")

# 3. Orca, while the example moves focus round Reset, Wireframe and Exposure.
orca_log = os.path.join(out, "orca.log")
start(["orca", "--debug", "--debug-file=" + orca_log], "orca.out")
expected = ["'LCGR example'", "'Reset button'", "'Wireframe check box checked'", "'slider "]
spoken = []


def heard():
    global spoken
    if os.path.exists(orca_log):
        spoken = [l.split("SPEECH OUTPUT: ", 1)[1] for l in open(orca_log, errors="replace") if "SPEECH OUTPUT: " in l]
    return all(any(s.startswith(e) for s in spoken) for e in expected)


wait_for(heard, lambda: "Orca to announce %s (it said %r)" % (expected, spoken), seconds=20)
for s in spoken:
    print("     orca: " + s.split("{")[0])
print("ok   orca announced the window, Reset, Wireframe (checked) and the slider")
for p in procs:
    p.kill()
