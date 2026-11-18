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
        self.assertEqual(styles.emit_style(st)["size"], ".{ .px(44), .px(66) }")
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
                                      ("gap", "10px 20px")), rule("div", ("width", "40%"), ("box-sizing", "border-box"),
                                      ("position", "absolute"), ("left", "-2px"), ("top", "0"), ("overflow", "hidden"),
                                      ("border", "2px solid hsl(120 100% 25%)"), ("border-radius", "1px 2px 3px")))
        self.assertTrue(got[id(root)].flex)
        self.assertFalse(got[id(child)].flex)
        self.assertEqual(got[id(root)].axis, "x")
        self.assertEqual(got[id(root)].fields["gap"], "20")
        self.assertEqual(got[id(root)].theme["panel"], ".hex(0x663399ff)")
        fields = styles.emit_style(got[id(child)])
        self.assertEqual(fields, {"size": ".{ .pct(0.4), .fit }", "min": ".{ 4, 0 }", "pad": ".{ 2, 2, 2, 2 }", "float": "true", "offset": ".{ -2, 0 }",
                                  "clip": "true", "border": "2", "border_color": ".hex(0x008000ff)",
                                  "radii": ".{ 1, 2, 3, 2 }"})

    def test_flex_parent_axis_and_shorthand_order(self):
        item = element("div")
        outer = element("div", item)
        st = compile_rules(outer, rule(":root", ("display", "flex"), ("flex-direction", "column")),
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

    def test_unmatched_and_overridden_unsupported_values_get_locations(self):
        for invalid in (("display", "grid"), ("width", "calc(100% - 2px)"),
                        ("width", "var(--size, 2vh)"), ("transform", "rotateX(var(--angle))"),
                        ("background", "url(example.png)"), ("border-style", "dashed")):
            name, value = invalid
            with self.subTest(invalid=invalid), self.assertRaises(styles.StyleError):
                compile_rules(element("main"), rule(".absent", (name, value)))
        with self.assertRaisesRegex(styles.StyleError, "unsupported CSS function"):
            compile_rules(element("p"), rule("p", ("width", "min(10px, 50%)"), ("width", "30px")))
        p = element("p")
        got = compile_rules(p, rule("p", ("width", "var(--unused)"), ("width", "30px")))[id(p)]
        self.assertEqual(styles.emit_style(got)["size"], ".{ .px(30), .fit }")

    def test_inactive_flex_context_does_not_change_block_layout(self):
        root = element("div", element("p"))
        for selector, key, val in (("div", "flex-direction", "row"), ("p", "flex-grow", "1"),
                                   ("p", "align-self", "stretch"), ("div", "gap", "2px")):
            with self.subTest(key=key), self.assertRaisesRegex(styles.StyleError, "flex"):
                compile_rules(root, rule(selector, (key, val)))
        child = root["children"][0]
        got = compile_rules(root, rule("div", ("display", "flex")), rule("p", ("height", "fit-content")))
        self.assertEqual(got[id(child)].sizes, [".fit", ".fit"])

    def test_border_presence_and_standard_box_dimensions(self):
        p = element("p")
        st = compile_rules(p, rule("p", ("border-width", "4px"), ("width", "50px")))[id(p)]
        self.assertEqual(st.fields["border"], "0")
        self.assertEqual(st.sizes[0], ".px(50)")
        st = compile_rules(p, rule("p", ("border-style", "solid"), ("width", "50px"),
                                   ("padding", "2px")))[id(p)]
        self.assertEqual(st.fields["border_color"], "theme.text")
        self.assertEqual(st.sizes[0], ".px(60)")
        self.assertEqual(st.fields["pad"], ".{ 5, 5, 5, 5 }")
        with self.assertRaisesRegex(styles.StyleError, "additive size"):
            compile_rules(p, rule("p", ("padding", "4px"), ("width", "50%")))

    def test_absolute_containing_block_and_insets(self):
        inner = element("aside")
        middle = element("div", inner)
        root = element("main", middle)
        rule_abs = rule("aside", ("position", "absolute"), ("top", "7px"), ("left", "5px"))
        with self.assertRaisesRegex(styles.StyleError, "containing block"):
            compile_rules(root, rule_abs)
        got = compile_rules(root, rule("div", ("position", "relative"), ("padding", "3px")), rule_abs)
        self.assertEqual(got[id(inner)].fields["offset"], ".{ 2, 4 }")

    def test_substituted_tokens_and_comments(self):
        p = element("p")
        result = compile_rules(p, rule("p", ("--note", '"var(--undefined)"'), ("padding", "2px/**/ 3px")))
        self.assertEqual(result[id(p)].variables["--note"], '"var(--undefined)"')
        self.assertEqual(result[id(p)].fields["pad"], ".{ 3, 2, 3, 2 }")
        with self.assertRaises(styles.StyleError):
            compile_rules(p, rule("p", ("--n", "2"), ("width", "var(--n)px")))
        with self.assertRaisesRegex(styles.StyleError, "requires a unit"):
            compile_rules(p, rule(".absent", ("width", "5")))
        result = compile_rules(p, rule(":root", ("--text-px", "20px"), ("width", "2em")))
        self.assertEqual(result[id(p)].sizes[0], ".px(40)")

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
