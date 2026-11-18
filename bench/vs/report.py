#!/usr/bin/env python3
"""Render one complete comparison run as Markdown alongside its raw measurements."""
import argparse
import datetime
import json
import math
import os
from pathlib import Path
import platform
import statistics
import subprocess

from measure import SCENES, summarize_scene

FRAMEWORKS = json.loads(Path(__file__).with_name("frameworks.json").read_text())
RESIZES = ("grow", "shrink", "drag-settle")


def number(value):
    if isinstance(value, bool) or not isinstance(value, (float, int)) or not math.isfinite(value) or value < 0:
        raise ValueError(f"invalid measurement {value!r}")
    return value


def read_samples(directory, resize_file):
    runs = {}
    for key in FRAMEWORKS:
        sample = json.loads((directory / f"{key}.json").read_text())
        if sample["name"] != key or set(sample["scenes"]) != set(SCENES):
            raise ValueError(f"incomplete or mislabelled scenes for {key}")
        if type(sample["runs"]) is not int or sample["runs"] < 1 or number(sample["idle_seconds"]) <= 0:
            raise ValueError(f"invalid repetitions for {key}")
        for scene, values in sample["scenes"].items():
            samples = values.get("samples")
            if ("rss_kib" not in values or "peak_kib" not in values
                    or not isinstance(samples, list) or len(samples) != sample["runs"]
                    or summarize_scene(key, scene, samples) != values):
                raise ValueError(f"{key}/{scene}: inconsistent run summaries")
        for field in ("rss_kib", "peak_kib", "loaded_bytes", "bss_bytes", "library_bytes",
                      "idle_wakeups_per_s", "first_frame_ms", "load_before", "load_after"):
            number(sample[field])
        runs[key] = sample
    if len({(r["runs"], r["idle_seconds"]) for r in runs.values()}) != 1:
        raise ValueError("frameworks measured with different repetition counts or idle durations")
    resize = json.loads(resize_file.read_text())
    rounds = resize["rounds"]
    if type(rounds) is not int or rounds < 1 or set(resize["samples"]) != set(FRAMEWORKS):
        raise ValueError("incomplete window-resize comparison")
    for key, rows in resize["samples"].items():
        if [(row["round"], row["kind"]) for row in rows] != [
                (r, kind) for r in range(1, rounds + 1) for kind in RESIZES]:
            raise ValueError(f"incomplete window-resize rounds for {key}")
        for row in rows:
            number(row["latency_ms"])
            number(row["readback_ms"])
    return runs, resize


def table(headers, rows):
    return ["| " + " | ".join(headers) + " |", "|" + "|".join(["---"] * len(headers)) + "|",
            *["| " + " | ".join(map(str, row)) + " |" for row in rows], ""]


def render(runs, resize, meta):
    sha = meta["revision"]
    repo = meta["repository"]
    revision = f"[`{sha[:10]}`](https://github.com/{repo}/commit/{sha})" if repo else f"`{sha[:10]}`"
    source = f" [CI run]({meta['run_url']})" if meta["run_url"] else ""
    repetitions = runs["lcgf"]["runs"]
    lines = ["# GUI framework benchmark results", "",
             f"Measured {meta['utc']} at {revision}.{source}", "",
             f"{meta['cpu_model']}, {meta['system']}. Frame harnesses used CPU {meta['cpu']}. "
             f"Start/end load readings ranged from {min(min(r['load_before'], r['load_after']) for r in runs.values()):.1f} "
             f"to {max(max(r['load_before'], r['load_after']) for r in runs.values()):.1f}.", "",
             "## LCGF against the lowest other measurement", "",
             "The ratio divides LCGF's measured value by the lowest other value in the same run. "
             "Values below 1 favor LCGF. Ties share the comparison column.", ""]
    comparisons = []
    for metric, units, getter in [
        *[(scene.title() + " frame median", "µs", lambda r, scene=scene: r["scenes"][scene]["median_us"])
          for scene in SCENES if scene != "idle"],
        ("First frame", "ms", lambda r: r["first_frame_ms"]),
        ("Idle resident memory", "KiB", lambda r: r["rss_kib"]),
    ]:
        values = {key: getter(row) for key, row in runs.items() if key != "lcgf"}
        best = min(values.values())
        winners = ", ".join(FRAMEWORKS[k] for k, v in values.items() if v == best)
        ours = getter(runs["lcgf"])
        ratio = f"{ours / best:.3f}" if best else ("tie at zero" if not ours else "reference zero")
        comparisons.append([metric, f"{ours:,.3g} {units}", f"{best:,.3g} {units} ({winners})", ratio])
    lines += table(["Measurement", "LCGF", "Lowest other", "Ratio"], comparisons)
    lines += ["## Frame time", "",
             f"Each harness ran 3,000 polls per scene in each of {repetitions} runs. "
             "Each cell shows the median of the run medians and the median of the run p99s, in microseconds per poll. "
             "The cost can include command generation, tessellation or software rasterization depending on the toolkit. "
             "Idle polling and idle process wake-ups are separate measurements.", ""]
    lines += table(["Framework", *[s.title() for s in SCENES]],
                   [[name, *[f"{r['median_us']:.1f} / {r['p99_us']:.1f}" for r in
                             (runs[key]["scenes"][scene] for scene in SCENES)]] for key, name in FRAMEWORKS.items()])
    lines += ["## Polls that produced a frame", "",
              "Median count per 3,000 polls. Retained toolkits can reuse their previous output. "
              "The time table includes the polls they skipped.", ""]
    lines += table(["Framework", *[s.title() for s in SCENES]],
                   [[name, *[runs[key]["scenes"][scene]["frames"] for scene in SCENES]]
                    for key, name in FRAMEWORKS.items()])
    lines += ["## Resident memory by workload", "",
              "Each cell shows end-of-scene RSS / peak RSS in KiB. Each run launches a fresh speed-build process. "
              "Linux reports its resident pages after 3,000 polls and the highest resident count since launch. "
              "Both columns are medians across runs and include resident shared pages.", ""]
    lines += table(["Framework", *[s.title() for s in SCENES]],
                   [[name, *[f"{row['rss_kib']:,} / {row['peak_kib']:,}" for row in
                             (runs[key]["scenes"][scene] for scene in SCENES)]] for key, name in FRAMEWORKS.items()])
    lines += ["## Startup and footprint", "",
              "Startup is the median of 11 launches to the first completed frame. Idle RSS and the peak observed through the first idle frame include "
              "touched shared pages. Executable bytes sum text, read-only data and initialized data in the size build. "
              "Mapped libraries are the on-disk sizes of shared objects mapped by the speed build at idle. "
              "Clay, Nuklear and microui use static musl builds for startup, idle RSS and idle wake-ups. BSS is zero-initialized address space.", ""]
    lines += table(["Framework", "Startup ms", "Idle RSS KiB", "Peak RSS KiB", "Wake-ups/s",
                    "Executable bytes", "BSS bytes", "Mapped library bytes"],
                   [[name, f"{runs[k]['first_frame_ms']:.3f}", runs[k]["rss_kib"], runs[k]["peak_kib"],
                     f"{runs[k]['idle_wakeups_per_s']:.1f}", *[f"{runs[k][f]:,}" for f in
                     ("loaded_bytes", "bss_bytes", "library_bytes")]] for k, name in FRAMEWORKS.items()])
    lines += ["## Window resize to verified pixels", "",
              f"Median / p95 milliseconds across {resize['rounds']} samples per resize type. An independent X11 "
              "observer verifies every pixel of the resized window on the X server.", ""]
    sizes = []
    for key, name in FRAMEWORKS.items():
        row = [name]
        for kind in RESIZES:
            x = sorted(t["latency_ms"] for t in resize["samples"][key] if t["kind"] == kind)
            row.append(f"{statistics.median(x):.2f} / {x[math.ceil(.95 * len(x)) - 1]:.2f}")
        sizes.append(row)
    lines += table(["Framework", "Grow", "Shrink", "Drag and settle"], sizes)
    if repo:
        lines += [f"[Workloads and adapter boundaries](https://github.com/{repo}/blob/{sha}/docs/perf/vs.md) · "
                  f"[Release thresholds](https://github.com/{repo}/blob/{sha}/bench/gates/README.md)", ""]
    lines += [f"Measured with Zig `{meta['zig']}`. The raw file includes the frame counts, "
              "load readings and individual verified window-resize samples.",
              "[Raw measurements and runner metadata](measurements.json)", ""]
    return "\n".join(lines)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("samples", type=Path)
    p.add_argument("resize", type=Path)
    p.add_argument("output", type=Path)
    p.add_argument("--cpu", type=int, required=True)
    args = p.parse_args()
    runs, resize = read_samples(args.samples, args.resize)
    cpu_info = Path("/proc/cpuinfo").read_text().splitlines()
    model = next((v.split(":", 1)[1].strip() for v in cpu_info if v.startswith("model name")), platform.machine())
    repo = os.environ.get("GITHUB_REPOSITORY")
    run = os.environ.get("GITHUB_RUN_ID")
    meta = dict(revision=subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
                repository=repo, run_url=f"https://github.com/{repo}/actions/runs/{run}" if repo and run else None,
                run_number=int(os.getenv("GITHUB_RUN_NUMBER", "0")), attempt=int(os.getenv("GITHUB_RUN_ATTEMPT", "1")),
                utc=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
                system=f"{platform.system()} {platform.release()} {platform.machine()}", cpu=args.cpu, cpu_model=model,
                zig=subprocess.check_output(["zig", "version"], text=True).strip())
    report = render(runs, resize, meta)
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "measurements.json").write_text(json.dumps(dict(metadata=meta, scenes=runs, window_resize=resize),
                                                           indent=2, allow_nan=False) + "\n")
    (args.output / "README.md").write_text(report)


if __name__ == "__main__":
    main()
