"""Generate the offline inventory from digest-pinned WHATWG and Webref snapshots.

Run `python3 update_catalog.py --check` to verify the checked-in catalog.
"""
import argparse
import csv
import gzip
from hashlib import sha256
from html.parser import HTMLParser
import io
import json
from pathlib import Path
import sys
from urllib.parse import urljoin

ROOT = Path(__file__).resolve().parent
HTML = "https://html.spec.whatwg.org/multipage/"
SNAPSHOTS = {
    "html": ("whatwg-2026-11-17.html.gz", "547826cea6e54951df190b66ecf6d4f6967e4f5c813c14d0ba8f7305c6e0c08c"),
    "css": ("webref-css-8.7.9.json.gz", "c4bba754fcb99891e256861fdd2bff0b5cb321d198162db43df5bc6fe05ad565"),
}
CATEGORIES = {"properties": "property", "atrules": "at-rule", "functions": "function",
              "selectors": "selector", "types": "type"}
COLUMNS = ("kind", "name", "applies_to", "specification")


def snapshot(kind, path):
    filename, digest = SNAPSHOTS[kind]
    path = path or ROOT / "snapshots" / filename
    data = path.read_bytes()
    if path.suffix == ".gz":
        data = gzip.decompress(data)
    if sha256(data).hexdigest() != digest:
        raise ValueError(f"{path}: SHA-256 does not match the pinned {kind} snapshot")
    return data.decode("utf-8")


class Index(HTMLParser):
    """Read the index's heading and scope cells, including optional HTML end tags."""
    def __init__(self):
        super().__init__()
        self.section = None
        self.body = False
        self.cells = []
        self.link = self.code = None
        self.rows = set()

    def finish(self):
        if self.body and self.cells:
            first = self.cells[0]
            if self.section == "element":
                for href, name, _ in first["links"]:
                    name = {"SVG svg": "svg", "MathML math": "math"}.get(name, name)
                    self.rows.add(("element", name, "", urljoin(HTML, href)))
            elif self.section == "attribute":
                if not first["codes"] or len(self.cells) < 2 or not self.cells[1]["links"]:
                    raise ValueError(f"attribute applicability missing for {first}")
                scope = self.cells[1]
                text = "".join(scope["text"])
                # Links inside "(in picture)" or "(in video or audio)" qualify the
                # preceding source element. They do not introduce new element scopes.
                roots = [(href, start) for href, _, start in scope["links"]
                         if text[:start].count("(") == text[:start].count(")")]
                for i, (href, start) in enumerate(roots):
                    end = roots[i + 1][1] if i + 1 < len(roots) else len(text)
                    element = " ".join(text[start:end].strip(" ;\n\t").split())
                    for name in first["codes"]:
                        self.rows.add(("attribute", name, element, urljoin(HTML, href)))
        self.cells.clear()
        self.link = self.code = None

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "h3":
            self.section = {"elements-3": "element", "attributes-3": "attribute"}.get(attrs.get("id"))
        elif tag == "tbody" and self.section:
            self.body = True
        elif tag == "tr":
            self.finish()
        elif tag in ("th", "td") and self.body:
            self.cells.append({"codes": [], "links": [], "text": []})
        elif self.cells and tag == "a":
            self.link = (attrs["href"], [], sum(map(len, self.cells[-1]["text"])))
        elif self.cells and tag == "code":
            self.code = []

    def handle_data(self, text):
        if self.cells:
            self.cells[-1]["text"].append(text)
        if self.link is not None:
            self.link[1].append(text)
        if self.code is not None:
            self.code.append(text)

    def handle_endtag(self, tag):
        if tag == "a" and self.link is not None:
            href, label, start = self.link
            self.cells[-1]["links"].append((href, " ".join("".join(label).split()), start))
            self.link = None
        elif tag == "code" and self.code is not None:
            self.cells[-1]["codes"].append("".join(self.code).strip())
            self.code = None
        elif tag in ("tr", "tbody", "table"):
            self.finish()
            if tag != "tr":
                self.body = False


def rows(html, css):
    index = Index()
    index.feed(html)
    yield from index.rows
    definitions = json.loads(css)
    if definitions.keys() != CATEGORIES.keys():
        raise ValueError(f"unexpected CSS index categories: {definitions.keys()}")
    for category, entries in definitions.items():
        kind = CATEGORIES[category]
        for entry in entries:
            yield kind, entry["name"], "", entry["href"]
            for desc in entry.get("descriptors", []):
                yield "descriptor", entry["name"] + "/" + desc["name"], "", desc["href"]


def catalog(html_path=None, css_path=None):
    out = io.StringIO(newline="")
    writer = csv.writer(out, delimiter="\t", lineterminator="\n")
    writer.writerow(COLUMNS)
    writer.writerows(sorted(set(rows(snapshot("html", html_path), snapshot("css", css_path)))))
    return out.getvalue()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("html", type=Path, nargs="?")
    parser.add_argument("css", type=Path, nargs="?")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    content = catalog(args.html, args.css)
    if args.check:
        if content.encode() != (ROOT / "catalog.tsv").read_bytes():
            parser.exit(1, "catalog.tsv differs from the pinned sources\n")
    else:
        sys.stdout.write(content)


if __name__ == "__main__":
    main()
