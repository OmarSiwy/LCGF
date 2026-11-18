import json
from pathlib import Path
import tempfile
import unittest

from measure import parse_frame, summarize_scene
from report import FRAMEWORKS, RESIZES, SCENES, read_samples, render


class ComparisonReportTest(unittest.TestCase):
    def test_raw_poll_contract(self):
        raw = "scene=text core=port nodes=4 frames=2 polls=3000 lanes=8\nframe 12 16\npoll 0.2 1.2\n"
        self.assertEqual(parse_frame(raw, "text"), dict(frames=2, median_us=.2, p99_us=1.2))
        for value in (raw.replace("polls=3000", "polls=3"), raw.replace("scene=text", "scene=form"),
                      raw.replace("polls=3000", "other=3000")):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "3000 polls"):
                parse_frame(value, "text")

    def test_each_repetition_must_have_a_valid_frame_count_and_percentiles(self):
        sample = dict(frames=2, median_us=.2, p99_us=1.2)
        for bad in (dict(frames=0), dict(frames=3001), dict(frames=2.5), dict(frames=True),
                    dict(median_us=1.3), dict(median_us=-.1), dict(p99_us=float("nan"))):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                summarize_scene("lcgf", "text", [sample, sample | bad, sample])
        with self.assertRaisesRegex(ValueError, "expected 3000 frames"):
            summarize_scene("microui", "list", [sample])
        variable = summarize_scene("qtquick", "idle", [sample | dict(frames=0), sample, sample])
        self.assertEqual(variable["frames"], 2)
        self.assertEqual([v["frames"] for v in variable["samples"]], [0, 2, 2])

    def test_complete_run_and_incomplete_negative_controls(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            for key in FRAMEWORKS:
                measurement = dict(frames=3000, median_us=2 if key == "lcgf" else 1, p99_us=3)
                sample = dict(name=key, runs=5, idle_seconds=2, load_before=1, load_after=2,
                              rss_kib=100, peak_kib=200, loaded_bytes=300, bss_bytes=0,
                              library_bytes=0, first_frame_ms=0.4, idle_wakeups_per_s=0,
                              scenes={s: summarize_scene(key, s, [measurement] * 5) for s in SCENES})
                (directory / f"{key}.json").write_text(json.dumps(sample))
            resize = dict(rounds=1, samples={
                k: [dict(round=1, kind=knd, latency_ms=1, readback_ms=.1) for knd in RESIZES]
                for k in FRAMEWORKS})
            path = directory / "window.json"
            path.write_text(json.dumps(resize))
            runs, windows = read_samples(directory, path)
            meta = dict(revision="c3a55bd", repository=None, utc="test", run_url=None,
                        cpu_model="test CPU", system="Linux", cpu=2, zig="test")
            output = render(runs, windows, meta)
            self.assertIn("| 2.000 |", output)
            self.assertIn("Qt Widgets", output)
            old = runs["lcgf"]["scenes"]["list"]
            lcgf_path = directory / "lcgf.json"
            for changed in ({k: v for k, v in old.items() if k != "samples"},
                            old | dict(samples=old["samples"][:4]), old | dict(median_us=2.5)):
                runs["lcgf"]["scenes"]["list"] = changed
                lcgf_path.write_text(json.dumps(runs["lcgf"]))
                with self.assertRaisesRegex(ValueError, "inconsistent run summaries"):
                    read_samples(directory, path)
            runs["lcgf"]["scenes"]["list"] = old
            lcgf_path.write_text(json.dumps(runs["lcgf"] | dict(idle_seconds=1)))
            with self.assertRaisesRegex(ValueError, "different repetition counts or idle durations"):
                read_samples(directory, path)
            lcgf_path.write_text(json.dumps(runs["lcgf"]))
            resize["samples"]["gtk4"].pop()
            path.write_text(json.dumps(resize))
            with self.assertRaisesRegex(ValueError, "incomplete window-resize rounds"):
                read_samples(directory, path)
            (directory / "microui.json").unlink()
            with self.assertRaises(FileNotFoundError):
                read_samples(directory, path)
