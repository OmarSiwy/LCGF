"""Behavioral importer regressions; generated Zig consumer coverage lives in style/import_tests.zig."""

import copy
import json
from pathlib import Path
import unittest

import stylegen


FIXTURE = Path(__file__).parents[2] / "src/style/testdata/dtcg.json"


class StylegenTests(unittest.TestCase):
    def setUp(self):
        self.document = stylegen.load(FIXTURE.read_text(encoding="utf-8"))

    def test_all_native_consumers_and_round_trip_metadata(self):
        generated, report = stylegen.generate(self.document)
        self.assertEqual(report["source"], self.document)
        self.assertIn("style.tokens.alias(.from(\"color.accent\"), .from(\"color.base\"))", generated)
        for target in ('@"$color".Rgba', '@"$api".decoration.Border', '@"$api".decoration.Shadow', '@"$api".brushes.Stop', '@"$api".motion.Curve', "lcgf.vector.DashStyle", "lcgf.font_match.find"):
            self.assertIn(target, generated)
        self.assertEqual(generated, stylegen.generate(copy.deepcopy(self.document))[0])
        self.assertEqual(report["tokens"], sorted(report["tokens"], key=lambda row: row["name"]))

    def test_alias_cycles_missing_references_and_cross_type_aliases_fail(self):
        cases = [
            ({"a": {"$type": "number", "$value": "{b}"}, "b": {"$value": "{a}"}}, "ReferenceCycle"),
            ({"a": {"$type": "number", "$value": "{absent}"}}, "MissingReference"),
            ({"a": {"$type": "number", "$value": "{b}"}, "b": {"$type": "dimension", "$value": {"value": 2, "unit": "px"}}}, "TypeMismatch"),
            ({"a": {"$type": "number", "$value": {"$ref": "#/b/$value"}}, "b": {"$type": "number", "$value": {"$ref": "#/a/$value"}}}, "ReferenceCycle"),
        ]
        for document, code in cases:
            with self.subTest(code=code), self.assertRaises(stylegen.TokenError) as caught:
                stylegen.generate(document)
            self.assertEqual(caught.exception.code, code)

    def test_json_pointer_component_and_escaped_names(self):
        document = {
            "a/b~c": {"$type": "color", "$value": {"colorSpace": "srgb", "components": [0.25, 0.5, 0.75]}},
            "red": {"$type": "number", "$value": {"$ref": "#/a~1b~0c/$value/components/0"}},
        }
        compiler = stylegen.Compiler(document, stylegen.Profile())
        self.assertEqual(compiler.resolve("red"), 0.25)
        self.assertIn('@"a/b~c"', compiler.output()[0])
        document["red"]["$value"] = {"$ref": "https://example.invalid/token.json"}
        with self.assertRaises(stylegen.TokenError) as caught:
            stylegen.generate(document)
        self.assertEqual(caught.exception.code, "InvalidReference")

    def test_units_gradient_and_explicit_target_profile(self):
        compiler = stylegen.Compiler(self.document, stylegen.Profile(root_font_size=20, shadow_radius_to_sigma=0.25))
        self.assertEqual(compiler.resolve("space.base"), 10)
        self.assertEqual(compiler.resolve("motion.duration"), 0.12)
        self.assertEqual(compiler.resolve("elevation.soft")[0]["sigma"], 1)
        self.assertEqual([s["position"] for s in compiler.resolve("gradient.brand")], [0, 1])

    def test_inherited_types_root_tokens_and_reference_identity(self):
        document = {"space": {"$type": "number", "$root": {"$value": 3}, "nested": {"a": {"$value": "{space.$root}"}}}}
        generated, report = stylegen.generate(document)
        self.assertIn("style.tokens.alias(.from(\"space.nested.a\"), .from(\"space.$root\"))", generated)
        self.assertEqual(report["tokens"][1]["type"], "number")

    def test_invalid_inputs_and_declared_subset_are_explicit(self):
        cases = [
            ({"a": {"$type": "dimension", "$value": {"value": 1, "unit": "vw"}}}, "UnsupportedUnit"),
            ({"a": {"$type": "color", "$value": {"colorSpace": "srgb", "components": ["none", 0, 0]}}}, "UnsupportedMissingComponent"),
            ({"a": {"$extends": "{b}"}}, "UnsupportedGroupExtension"),
            ({"a.b": {"$type": "number", "$value": 1}}, "InvalidName"),
            ({"a": {"$type": "number", "$value": 10 ** 400}}, "InvalidNumber"),
            ({"a": {"$type": "color", "$value": {"colorSpace": [], "components": [0, 0, 0]}}}, "UnsupportedColorSpace"),
            ({"a": {"$type": "strokeStyle", "$value": {"dashArray": [], "lineCap": "butt"}}}, "InvalidValue"),
        ]
        for document, code in cases:
            with self.subTest(code=code), self.assertRaises(stylegen.TokenError) as caught:
                stylegen.generate(document)
            self.assertEqual(caught.exception.code, code)
        with self.assertRaises(stylegen.TokenError) as caught:
            stylegen.load('{"x": 1, "x": 2}')
        self.assertEqual(caught.exception.code, "DuplicateKey")

    def test_limits_do_not_silently_drop_tokens(self):
        with self.assertRaises(stylegen.TokenError) as caught:
            stylegen.generate(self.document, stylegen.Profile(max_tokens=1))
        self.assertEqual(caught.exception.code, "Limit")
        with self.assertRaises(stylegen.TokenError):
            stylegen.load(json.dumps(self.document), stylegen.Profile(max_bytes=8))

    def test_color_percentage_conversion_and_wide_gamut_functions(self):
        document = {"pink": {"$type": "color", "$value": {"colorSpace": "hsl", "components": [330, 100, 50]}}, "xyz": {"$type": "color", "$value": {"colorSpace": "xyz-d50", "components": [0.96422, 1, 0.82521]}}}
        generated, _ = stylegen.generate(document)
        self.assertIn('@"$color".hsl(330, 1, 0.5, 1)', generated)
        self.assertIn('@"$color".xyzD50', generated)


if __name__ == "__main__":
    unittest.main()
