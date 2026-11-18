import csv
import io
import unittest

import mapping
import update_catalog as catalog


class FeatureCatalog(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = list(csv.DictReader(io.StringIO(catalog.catalog()), delimiter="\t"))

    def test_regeneration_and_scope_completeness(self):
        self.assertEqual(catalog.catalog().encode(), (catalog.ROOT / "catalog.tsv").read_bytes())
        groups = {}
        for item in self.source:
            groups.setdefault(item["kind"], []).append(item)
            self.assertTrue(item["specification"].startswith("https://"))
        expected = {"element": 116, "attribute": 383, "property": 822, "selector": 160,
                    "function": 172, "type": 530, "at-rule": 55, "descriptor": 103}
        self.assertEqual({kind: len(rows) for kind, rows in groups.items()}, expected)
        self.assertEqual(len({r["name"] for r in groups["attribute"]}), 234)
        self.assertEqual(mapping.ELEMENTS | mapping.ELEMENT_GAPS.keys(), {r["name"] for r in groups["element"]})
        self.assertFalse(mapping.ELEMENTS & mapping.ELEMENT_GAPS.keys())
        dims = {r["applies_to"] for r in groups["attribute"] if r["name"] == "width"}
        self.assertIn("source (in picture)", dims)
        self.assertNotIn("picture", dims)
        self.assertIn("img", {r["applies_to"] for r in groups["attribute"] if r["name"] == "controls"})

    def result(self, kind, name, scope=""):
        r = next(row for row in self.source if
                 (row["kind"], row["name"], row["applies_to"]) == (kind, name, scope))
        return mapping.destination(kind, name, r["specification"], scope)

    def test_every_definition_has_an_actionable_decision(self):
        records = list(mapping.inventory())
        self.assertEqual(len(records), len(self.source))
        for kind, name, status, work, url in records:
            with self.subTest(kind=kind, name=name, url=url):
                self.assertIn(status, {"mapped subset", "parser only", "gap"})
                self.assertTrue(work.strip())
                if kind in ("at-rule", "descriptor"):
                    self.assertEqual(status, "gap")
        with self.assertRaises(KeyError):
            mapping.destination("attribute", "unknown-attribute", "", "input")
        with self.assertRaises(KeyError):
            mapping.destination("element", "unknown-element", "")
        with self.assertRaises(KeyError):
            mapping.destination("function", "test()", "https://example.invalid/unknown-module/")
        with self.assertRaises(ValueError):
            mapping.destination("unknown category", "feature", "")

    def test_every_gap_property_is_rejected_even_on_an_unmatched_selector(self):
        from styles import StyleError, compute_styles
        root = {"kind": "element", "tag": "html", "attrs": [], "children": []}
        for kind, name, status, *_ in mapping.inventory():
            if kind != "property" or status != "gap":
                continue
            with self.subTest(property=name):
                # Feed the parser protocol directly so every catalog property is checked.
                rule = {"selector": ".absent", "declarations": [{"name": name, "value": "initial"}]}
                with self.assertRaises(StyleError) as raised:
                    compute_styles(root, [("page.css", "")], lambda _: {"rules": [rule]})
                self.assertIn(name, str(raised.exception))

    def test_html_and_css_decisions_are_contextual(self):
        for kind, name, scope in [("attribute", "href", "link"), ("attribute", "value", "input"),
                                  ("element", "h3", ""), ("element", "main", ""),
                                  ("selector", ":root", ""), ("selector", ">", ""),
                                  ("function", "translateY()", ""), ("function", "rgb()", ""),
                                  ("type", "hex-color", ""), ("property", "font-size", "")]:
            self.assertEqual(self.result(kind, name, scope)[0], "mapped subset")
        for kind, name, scope in [("attribute", "href", "a"), ("attribute", "value", "option"),
                                  ("attribute", "onclick", "HTML elements"), ("selector", ":hover", ""),
                                  ("function", "color-mix()", ""), ("type", "angle-percentage", ""),
                                  ("at-rule", "@media", ""), ("descriptor", "@font-face/src", "")]:
            self.assertEqual(self.result(kind, name, scope)[0], "gap")
        self.assertEqual(self.result("type", "bad-url-token")[0], "parser only")
        self.assertIn("ordered-list", self.result("attribute", "value", "li")[1])
        self.assertIn("focus", self.result("attribute", "tabindex", "HTML elements")[1])


if __name__ == "__main__":
    unittest.main()
