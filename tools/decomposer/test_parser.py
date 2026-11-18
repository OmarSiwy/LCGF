"""Run against the native decomposer-parse built by Zig."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

PARSER = Path(sys.argv.pop(1)).resolve()


def parse(mode, source):
    return json.loads(subprocess.check_output([PARSER, mode, "-"], input=source.encode()))


def tags(node):
    return [child for child in node["children"] if child["kind"] == "element"]


class ParserTest(unittest.TestCase):
    def test_html5_tree_and_locations(self):
        source = '<!doctype html><p id="a" title="A&amp;B">Caf&eacute;<br>!<p>next<table><tr><td>x'
        result = parse("html", source)
        self.assertEqual(result["diagnostics"], [])
        self.assertEqual(result["mode"], "no-quirks")
        self.assertEqual(result["doctype"], dict(name="html", public_id="", system_id=""))
        html, = result["nodes"]
        head, body = tags(html)
        self.assertEqual([html["offset"], head["offset"], body["offset"]], [None] * 3)
        p, next_p, table = tags(body)
        self.assertEqual(p["offset"], source.index("<p"))
        self.assertEqual([(a["name"], a["value"]) for a in p["attrs"]], [("id", "a"), ("title", "A&B")])
        self.assertEqual(p["attrs"][1]["value_offset"], source.index("A&amp;B"))
        self.assertEqual([c.get("text", c.get("tag")) for c in p["children"]], ["Café", "br", "!"])
        self.assertEqual(next_p["children"][0]["text"], "next")
        self.assertEqual(tags(table)[0]["tag"], "tbody")

    def test_foreign_tree_template_and_bom(self):
        result = parse("html", '\ufeff<!doctype html><template><p>inside</template><svg><title>x</title></svg><math><mi>y</mi></math>')
        head, body = tags(result["nodes"][0])
        self.assertEqual(tags(tags(head)[0])[0]["tag"], "p")
        self.assertEqual([n["namespace"] for n in tags(body)], ["svg", "mathml"])
        self.assertEqual(result["mode"], "no-quirks")
        self.assertEqual(parse("html", "<p>x")["mode"], "quirks")

    def test_fragments_are_explicit(self):
        source = '<row><col class="c"><label>Fish &amp; chips &#x1f41f;</label><slider/></col></row>'
        row, = parse("widgets", source)["nodes"]
        col, = tags(row)
        self.assertEqual(col["tag"], "col")
        self.assertEqual(tags(col)[0]["children"][0]["text"], "Fish & chips 🐟")
        self.assertEqual(len(tags(col)), 2)
        self.assertTrue(parse("widgets", "<row></col>")["diagnostics"])
        self.assertNotIn('"tag": "col"', json.dumps(parse("html", source)))

    def test_rules_values_and_offsets(self):
        source = '/* é */ p > a, .foo { gap: var(--g); color: red ! important; content: "x;}" }'
        result = parse("css", source)
        self.assertEqual(result["diagnostics"], [])
        rule, = result["rules"]
        self.assertEqual(rule["selector"], "p > a, .foo")
        self.assertEqual(rule["offset"], source.encode().index(b"p >"))
        self.assertEqual([d["value"] for d in rule["declarations"]], ["var(--g)", "red", '"x;}"'])
        self.assertTrue(rule["declarations"][1]["important"])
        decl, = parse("declarations", "padding: 2px  4px!important")["declarations"]
        self.assertEqual((decl["value_offset"], decl["value"], decl["important"]), (9, "2px  4px", True))

    def test_diagnostics(self):
        for mode, source in [("css", "p{} @import 'a';"), ("css", "p $ {a:b}"), ("css", "p{color:red"),
                             ("css", "missing-block"), ("declarations", "width:2px; broken; height:2px"),
                             ("css", "p { & a { color:red } }")]:
            with self.subTest(source=source):
                self.assertTrue(any(d["severity"] == "error" for d in parse(mode, source)["diagnostics"]))
        self.assertEqual(parse("css", "p{} @import 'a';")["diagnostics"][0]["offset"], 4)

    def test_source_file_and_invalid_utf8(self):
        with tempfile.TemporaryDirectory() as tmp:
            html = Path(tmp) / "test.html"
            html.write_text("<p>Hello", encoding="utf-8")
            result = subprocess.check_output([PARSER, "html", html])
            self.assertEqual(json.loads(result), parse("html", "<p>Hello"))
        bad = subprocess.run([PARSER, "html"], input=b"\xff", capture_output=True)
        self.assertNotEqual(bad.returncode, 0)
        self.assertIn(b"invalid UTF-8 at byte 0", bad.stderr)


if __name__ == "__main__":
    unittest.main()
