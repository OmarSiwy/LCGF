"""CSS compiler unit tests; set DECOMPOSER_PARSER for the Lexbor end-to-end case."""

import json
import os
import subprocess
import unittest

if __package__:
    from . import styles
else:
    import styles


def element(tag, *children, **attrs):
    return {"kind": "element", "tag": tag, "children": list(children),
            "attrs": [{"name": name, "value": val} for name, val in attrs.items()]}


def rule(selector, *decls, offset=0):
    return {"selector": selector, "offset": offset, "declarations": [
        {"name": d[0], "value": d[1], "important": d[2] if len(d) > 2 else False, "offset": offset}
        for d in decls]}


def compile_rules(page, *rules, inline=None):
    return styles.compute_styles(page, [("main.css", "fixture")],
                                 lambda _: {"rules": rules},
                                 parse_declarations=lambda _: {"declarations": inline or []})


class CascadeTests(unittest.TestCase):
    def test_selectors_specificity_inheritance_and_order(self):
        title = element("label", id="title", **{"class": "muted"})
        item = element("article", title)
        root = element("div", item)
        rules = [
            rule("div", ("font-size", "20px"), ("color", "red")),
            rule("#title", ("color", "#123456")),
            rule("article > label, #absent", ("color", "yellow")),
            rule(":root .muted", ("padding", "1px 2px")),
            rule(".muted", ("color", "pink", True)),
            rule(".muted", ("color", "green", True)),
        ]
        computed = compile_rules(root, *rules)[id(title)]
        self.assertEqual(computed.text, {"px": "20", "color": ".hex(0x008000ff)"})
        self.assertEqual(computed.fields["pad"], ".{ 2, 1, 2, 1 }")

    def test_inline_and_important(self):
        root = element("p", style="color:green")
        rules = [rule("#absent,p", ("color", "red", True))]
        for important, expected in ((False, "ff0000"), (True, "008000")):
            inline = [{"name": "color", "value": "green", "important": important}]
            self.assertEqual(compile_rules(root, *rules, inline=inline)[id(root)].text["color"],
                             f".hex(0x{expected}ff)")

    def test_relative_units_and_custom_properties_compute_before_inheritance(self):
        title = element("h1")
        root = element("main", title)
        got = compile_rules(root,
                            rule(":root", ("--gap", "2px"), ("--Gap", "3px"), ("--saved", "var(--gap)"),
                                 ("font-size", "20px")),
                            rule("h1", ("--gap", "9px"), ("padding", "var(--Gap) var(--saved)"),
                                 ("width", "2rem"), ("height", "2em"), ("font-size", "150%")))
        st = got[id(title)]
        self.assertEqual(st.text["px"], "30")
        self.assertEqual(styles.emit_style(st)["size"], ".{ .px(40), .px(60) }")
        self.assertEqual(st.fields["pad"], ".{ 2, 3, 2, 3 }")

    def test_cycles_fallback_and_overridden_invalid_variable(self):
        p = element("p")
        st = compile_rules(p, rule("p", ("--a", "var(--b, red)"), ("--b", "var(--a)"),
                                   ("padding", "var(--undefined)"), ("padding", "3px 5px"),
                                   ("color", "var(--a, var(--fallback, #00f))")))[id(p)]
        self.assertEqual(st.text["color"], ".hex(0x0000ffff)")
        self.assertEqual(st.fields["pad"], ".{ 5, 3, 5, 3 }")

    def test_split_shorthand_cascade_and_unmatched_list_specificity(self):
        p = element("p", **{"class": "a"})
        st = compile_rules(p, rule("p, #unmatched", ("color", "red"), ("padding-left", "4px", True)),
                           rule(".a", ("padding", "2px 3px"), ("color", "blue")))[id(p)]
        self.assertEqual(st.fields["pad"], ".{ 4, 2, 3, 2 }")
        self.assertEqual(st.text["color"], ".hex(0x0000ffff)")

    def test_native_geometry_paint_and_theme(self):
        child = element("div")
        root = element("main", child)
        got = compile_rules(root, rule("main", ("display", "flex"), ("--panel", "rebeccapurple"),
                                      ("gap", "10px 20px")), rule("div", ("width", "40%"),
                                      ("position", "absolute"), ("left", "-2px"), ("overflow", "hidden"),
                                      ("border", "2px solid hsl(120 100% 25%)"), ("border-radius", "1px 2px 3px")))
        self.assertTrue(got[id(root)].flex)
        self.assertFalse(got[id(child)].flex)
        self.assertEqual(got[id(root)].axis, "x")
        self.assertEqual(got[id(root)].fields["gap"], "20")
        self.assertEqual(got[id(root)].theme["panel"], ".hex(0x663399ff)")
        fields = styles.emit_style(got[id(child)])
        self.assertEqual(fields, {"size": ".{ .pct(0.4), .fill }", "float": "true", "offset": ".{ -2, 0 }",
                                  "clip": "true", "border": "2", "border_color": ".hex(0x008000ff)",
                                  "radii": ".{ 1, 2, 3, 2 }"})

    def test_flex_parent_axis_and_shorthand_order(self):
        item = element("div")
        outer = element("div", item)
        st = compile_rules(outer, rule(":root", ("flex-direction", "column")),
                           rule(":root > div", ("flex", "2"), ("flex-grow", "3")))[id(item)]
        self.assertEqual(styles.emit_style(st, (".fill", ".fit"))["size"], ".{ .fill, .grow(3) }")
        self.assertEqual(st.fields["shrink"], "true")

    def test_affine_order_and_colors(self):
        st = element("div")
        got = compile_rules(st, rule("div", ("transform", "translate(5px, 7px) scale(2, 3)"),
                                    ("color", "rgb(100% 0% 80% / 50%)"),
                                    ("background", "currentcolor")))[id(st)]
        self.assertEqual(got.fields["transform"], ".{ 2, 0, 0, 3, 5, 7 }")
        self.assertEqual(got.fields["fill"], ".hex(0xff00cc80)")
        self.assertEqual(len(styles.NAMED), 148)

    def test_documented_properties_and_native_errors(self):
        self.assertTrue(all(target.strip() for target in styles.PROPERTY_TARGETS.values()))
        self.assertIn("border-bottom-right-radius", styles.PROPERTY_TARGETS)
        self.assertIn("flex-basis", styles.PROPERTY_TARGETS)
        for name, val in (("background", "red"), ("gap", "1vh"), ("display", "grid"),
                          ("z-index", "5"), ("overflow", "scroll"), ("color", "var(--absent)")):
            with self.subTest(name=name), self.assertRaises(styles.StyleError):
                compile_rules(element("button"), rule("button", (name, val)))
        for selector in ("p:hover", "p::after", "p + p", "div >", "p,,q", "[role]"):
            with self.subTest(selector=selector), self.assertRaises(styles.StyleError):
                compile_rules(element("article"), rule(selector, ("color", "red")))

    def test_visibility_and_environment_dependent_values_are_diagnosed(self):
        head = element("head")
        for prop, value in (("display", "block"), ("display", "flex")):
            with self.assertRaisesRegex(styles.StyleError, "nonvisual <head>"):
                compile_rules(element("html", head), rule("head", (prop, value)))
        for prop, value in (("width", "calc(1px + 3vw)"), ("transform", "rotateX(2deg)"),
                            ("background", "linear-gradient(red, blue)"), ("padding", "env(foo)")):
            with self.subTest(prop=prop), self.assertRaises(styles.StyleError):
                compile_rules(element("main"), rule("main", (prop, value)))

    def test_offsets_are_byte_based_and_use_inline_or_embedded_filename(self):
        html = '<main>é\n<style>p { margin: 1px }</style></main>'
        css = 'p { margin: 1px }'
        off = html.encode().index(css.encode())
        with self.assertRaises(styles.StyleError) as err:
            styles.compute_styles(element("main"), [("view.html", css, off)],
                                  lambda _: {"rules": [rule("p", ("margin", "1px"), offset=4)]},
                                  html_source=html)
        self.assertEqual((err.exception.path, err.exception.line, err.exception.column), ("view.html", 2, 12))

    @unittest.skipUnless(os.environ.get("DECOMPOSER_PARSER"), "set DECOMPOSER_PARSER for Lexbor integration")
    def test_real_lexbor_html_external_embedded_inline(self):
        def parse(mode, text):
            p = subprocess.run([os.environ["DECOMPOSER_PARSER"], mode, "-"], input=text, text=True,
                               capture_output=True, check=True)
            return json.loads(p.stdout)
        html = '<html><style>main { --pad:3px; }</style><body><main><p id="a" style="color:purple">Hi</p></main></body></html>'
        root = parse("html", html)["nodes"][0]
        css = "main { --pad:3px; }"
        result = styles.compute_styles(root, [("page.html", css, html.index(css)), ("main.css", "main > #a{padding:var(--pad);color:green}")],
                                       lambda css: parse("css", css),
                                       parse_declarations=lambda s: parse("declarations", s),
                                       html_source=html, html_path="page.html")
        unused, body = [n for n in root["children"] if n.get("kind") == "element"]
        p = body["children"][0]["children"][0]
        self.assertEqual(result[id(p)].fields["pad"], ".{ 3, 3, 3, 3 }")
        self.assertEqual(result[id(p)].text["color"], ".hex(0x800080ff)")


if __name__ == "__main__":
    unittest.main()
