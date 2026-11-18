"""Native targets for the standards inventory. Unimplemented features fail closed."""
import csv
from pathlib import Path
import re
from urllib.parse import urlsplit

from roadmap import (ATTRIBUTES, CSS_FUNCTIONS, CSS_MODULES, CSS_TYPES, ELEMENT_GAPS,
                     EVENTS, FUNCTION_GAPS, SCOPED, SELECTOR_GAPS)

# The short names are also used by the emitter. All other HTML names have an
# explicit target family in the roadmap below.
HEADINGS = {f"h{level}" for level in range(1, 7)}
LANDMARKS = {"main", "header", "footer", "nav", "aside", "search", "article", "section"}
BOXES = {"html", "body", "div"} | LANDMARKS
TEXT = {"p", "span"} | HEADINGS
METADATA = {"head", "title", "meta", "style", "link"}
ELEMENTS = BOXES | TEXT | METADATA | {"button", "input", "hr"}

ELEMENT_TARGETS = {
    "html": "document root and page layout", "body": "page layout", "div": "native layout container",
    "p": "native paragraph label with plain content", "span": "standalone native text run",
    "head": "compile-time metadata", "title": "exported document title", "meta": "UTF-8 charset declaration",
    "style": "author stylesheet in source order", "link": "relative local stylesheet dependency",
    "button": "native button and optional typed Zig writer", "input": "button input with literal or bound caption",
    "hr": "native horizontal separator", "main": "native main landmark",
    "nav": "native navigation landmark", "aside": "native complementary landmark",
    "search": "native search landmark", "article": "native article role",
    "section": "ordinary section container; named region semantics require a supported accessible-name source",
    "header": "page banner landmark outside sectioning contexts; otherwise a container",
    "footer": "page content-information landmark outside sectioning contexts; otherwise a container",
    **{h: f"native accessible heading level {h[1]} with a plain literal or bound caption" for h in HEADINGS},
}
ATTRIBUTE_TARGETS = {
    ("HTML elements", "id"): "stable document identity and CSS selector on mapped elements; buttons expose a generated widget id",
    ("HTML elements", "class"): "compile-time class selector on mapped elements",
    ("HTML elements", "style"): "inline CSS cascade on mapped elements, limited to supported properties and values",
    ("meta", "charset"): "require the document's UTF-8 encoding declaration",
    ("link", "href"): "resolve the relative local stylesheet file and track the build dependency",
    ("link", "rel"): "recognize stylesheet as the sole resource relationship",
    ("link", "type"): "accept text/css for a local stylesheet",
    ("button", "type"): "accept type=button; submission and reset require form ownership",
    ("input", "type"): "instantiate the native button for type=button",
    ("input", "value"): "native input-button caption for type=button",
}


def css_work(url):
    path = urlsplit(url)
    module = re.sub(r"-[0-9]+$", "", path.path.rstrip("/").split("/")[-1] or path.netloc)
    return CSS_MODULES[module]


def destination(kind, name, url, scope=""):
    if kind == "element":
        if name in ELEMENTS:
            return "mapped subset", ELEMENT_TARGETS[name]
        return "gap", f"<{name}> needs {ELEMENT_GAPS[name]}"
    if kind == "attribute":
        tag = scope.partition(" (")[0]
        if not tag:
            raise ValueError(f"attribute {name!r} is missing its WHATWG applicability")
        if (tag, name) in ATTRIBUTE_TARGETS:
            return "mapped subset", f"{scope}: {ATTRIBUTE_TARGETS[tag, name]}"
        if name.startswith("on"):
            work = EVENTS[name[2:]]
            return "gap", f"{scope}: {name} needs {work}; HTML script-valued handlers require scripting"
        work = SCOPED[(name, tag)] if (name, tag) in SCOPED else ATTRIBUTES[name]
        return "gap", f"{scope}: {work}"
    if kind == "property":
        from styles import PROPERTY_TARGETS
        if name in PROPERTY_TARGETS:
            return "mapped subset", PROPERTY_TARGETS[name]
    elif kind == "selector":
        if name in SELECTOR_GAPS:
            return "gap", f"{name}: {SELECTOR_GAPS[name]}"
        if name == ":root":
            return "mapped subset", "match the static document root during selector evaluation"
        if name == ">":
            return "mapped subset", "match the immediately enclosing author element"
    elif kind == "function":
        if name.lower() in FUNCTION_GAPS:
            return "gap", f"{name}: {FUNCTION_GAPS[name.lower()]}"
        if name.lower() in CSS_FUNCTIONS:
            return "mapped subset", CSS_FUNCTIONS[name.lower()]
    elif kind == "type":
        if urlsplit(url).path.rstrip("/") == "/css-syntax-3" and name.endswith("-token"):
            return "parser only", f"Lexbor tokenizes {name}; its presence alone does not give the enclosing value native semantics"
        if name in CSS_TYPES:
            return "mapped subset", CSS_TYPES[name]
    elif kind == "descriptor":
        parent, desc = name.split("/", 1)
        return "gap", f"{desc} has no consumer until {parent} is implemented: {css_work(url)}"
    elif kind != "at-rule":
        raise ValueError(f"unclassified standards feature kind {kind!r}")
    return "gap", f"{kind} {name}: {css_work(url)}"


def inventory():
    with Path(__file__).with_name("catalog.tsv").open(encoding="utf-8", newline="") as src:
        for row in csv.DictReader(src, delimiter="\t"):
            kind, name, url = (row[k] for k in ("kind", "name", "specification"))
            yield kind, name, *destination(kind, name, url, row["applies_to"]), url
