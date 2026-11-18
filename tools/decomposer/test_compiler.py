"""Exercise the normal compiler entry point, including failed builds and file dependencies."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

COMPILER = Path(__file__).with_name("compiler.py")


class CompilerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.output = self.root / "page.zig"

    def run_cli(self, source, *args):
        (self.root / "ui.html").write_text(source)
        return subprocess.run([sys.executable, COMPILER, "--parser", os.environ["DECOMPOSER_PARSER"],
                               "ui.html", "-o", self.output, *args],
                              cwd=self.root, capture_output=True, text=True)

    def test_strict_mapping_and_atomic_failure(self):
        self.output.write_text("previous page")
        examples = [
            ('<table><tr><td>x', "table"),
            ('<div lang="es">hola</div>', "lang"),
            ('<p style="display:grid">title', "grid"),
            ('<style>@media (width > 30px) {p{color:red}}</style>', "@"),
            ('<p style="columns:2">columns', "columns"),
            ('<input type=password>', "password"),
            ('<p><span>inline</span></p>', "inline"),
            ('<svg><circle/></svg>', "svg"),
            ('<button id=b data-zig-click="toggle" data-zig-writes="123">Toggle</button>', "data-zig-writes"),
            ('<button data-zig-writes=x>Go</button>', "callback"),
            ('<button aria-label="different">Go</button>', "aria-label"),
        ]
        for src, reason in examples:
            with self.subTest(src=src):
                cmd = self.run_cli("<!doctype html>\n" + src)
                self.assertNotEqual(cmd.returncode, 0)
                self.assertIn("ui.html:2:", cmd.stderr)
                self.assertIn(reason, cmd.stderr)
                self.assertEqual(self.output.read_text(), "previous page")

    def test_standard_tree_entities_and_css_inputs(self):
        (self.root / "colors one.css").write_text(".badge { color: #040506 }")
        cmd = self.run_cli('<!doctype html><title>R&amp;D</title><link rel="stylesheet" '
                           'href="colors%20one.css"><p class="badge">A&amp;B<p>Second',
                           "--depfile", "page.d")
        self.assertEqual(cmd.returncode, 0, cmd.stderr)
        page = self.output.read_text()
        for value in ['"R&D"', '"A&B"', '"Second"', "0x040506ff"]:
            self.assertIn(value, page)
        self.assertNotIn('@import("handlers")', page)
        self.assertIn(r'colors\ one.css', (self.root / "page.d").read_text())

    def test_semantic_containers_follow_their_ancestry(self):
        src = ('<!doctype html><header><h1>Overview</h1></header><main>'
               '<article><header><h2>Article</h2></header><footer>By A</footer></article>'
               '<nav>Index</nav><section>Unnamed</section><aside>Related</aside>'
               '<search>Find</search></main><footer>Page footer</footer>')
        result = self.run_cli(src)
        self.assertEqual(result.returncode, 0, result.stderr)
        code = self.output.read_text()
        for role in ("banner", "main", "article", "navigation", "complementary", "search", "content_info"):
            self.assertEqual(code.count("s.landmark(." + role + ","), 1, role)
        self.assertIn('s.heading(2, "Article")', code)

    def test_snippet_requires_explicit_mode(self):
        src = "<p>hello"
        self.assertNotEqual(self.run_cli(src).returncode, 0)
        result = self.run_cli(src, "--fragment")
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
