"""Compile an HTML document to an ordinary Zig module over LCGF's native widget API."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.parse import unquote, urlsplit

from mapping import BOXES, ELEMENTS, ELEMENT_GAPS, HEADINGS, METADATA, TEXT, inventory
from styles import compute_styles, emit_style

IDENT = re.compile(r"[A-Za-z_][A-Za-z_0-9]*\Z")
SPACE = re.compile(r"[ \t\n\r\f]+")
HANDLER = "data-zig-click"
WRITES = "data-zig-writes"
LANDMARKS = {"main": "main", "nav": "navigation", "article": "article", "aside": "complementary",
             "header": "banner", "footer": "content_info", "search": "search"}
SECTIONING = {"article", "aside", "main", "nav", "section"}


class CompileError(ValueError):
    pass


def quoted(value):
    # Zig and JSON use different escapes for control characters. Preserve printable Unicode.
    return '"' + "".join({"\\": "\\\\", '"': '\\"', "\n": "\\n", "\r": "\\r", "\t": "\\t"}.get(
        c, f"\\x{ord(c):02x}" if ord(c) < 32 or ord(c) == 127 else c) for c in value) + '"'


def ident(name):
    return "@" + quoted(name)


def literal(fields):
    return ".{ " + ", ".join(f".{key} = {value}" for key, value in fields.items()) + " }"


def typed_patch(type_name, fields):
    return literal({k: f'@as(@FieldType({type_name}, "{k}"), {v})' for k, v in fields.items()})


def attrs(node):
    return {a["name"]: a["value"] for a in node["attrs"]}


def loc(path, source, offset):
    prefix = source.encode()[:offset or 0].decode("utf-8", "replace")
    return f"{path}:{prefix.count(chr(10))+1}:{len(prefix.rsplit(chr(10), 1)[-1])+1}"


def text_content(node):
    return "".join(child["text"] for child in node["children"] if child["kind"] == "text")


def walk(node):
    yield node
    for child in node.get("children", []):
        if child["kind"] == "element":
            yield from walk(child)


def parse_native(parser, mode, source):
    process = subprocess.run([os.fspath(parser), mode, "-"], input=source, encoding="utf-8",
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if process.returncode:
        raise CompileError(f"decomposer-parse {mode} failed: {process.stderr.strip()}")
    return json.loads(process.stdout)


class Compiler:
    def __init__(self, parser, path, stylesheets, fragment=False):
        self.path = path
        self.source = path.read_bytes().decode("utf-8")
        self.dependencies = [path]
        self.nodes = []
        self.handlers = []
        self.title = ""
        self.theme = "dark"
        self.reads = set()
        self.conditions = set()
        self.writes = set()
        self.state_name = None
        prefix = "<!doctype html>" if fragment else ""
        doc = parse_native(parser, "html", prefix + self.source)
        if prefix:
            def adjust(obj):
                if isinstance(obj, dict):
                    for key, val in obj.items():
                        if key in ("offset", "value_offset") and isinstance(val, int):
                            obj[key] = max(0, val - len(prefix))
                        else:
                            adjust(val)
                elif isinstance(obj, list):
                    for entry in obj:
                        adjust(entry)
            adjust(doc)
        self.check(doc, path, self.source)
        elements = [n for n in doc["nodes"] if n["kind"] == "element"]
        if len(elements) != 1 or elements[0]["tag"] != "html":
            raise CompileError(f"{path}: expected an HTML document")
        self.root = elements[0]
        if doc.get("mode", "no-quirks") != "no-quirks":
            self.fail(self.root, "quirks rendering has no native mapping; add <!doctype html> or use --fragment")
        sheets = []
        ids = set()
        self.ids = ids
        for n in walk(self.root):
            tag, a = n["tag"], attrs(n)
            if n.get("namespace", "html") != "html" or tag not in ELEMENTS:
                self.fail(n, f"<{tag}> requires {ELEMENT_GAPS.get(tag, 'a native element mapping')}")
            self.validate_attrs(n, a)
            if "data-zig-if" in a:
                field = a["data-zig-if"]
                if not self.state_name or not IDENT.fullmatch(field):
                    self.fail(n, "data-zig-if needs a Zig state field and data-zig-state on <html>")
                self.conditions.add((field, self.at(n)))
            if "id" in a:
                if not a["id"] or a["id"] in ids:
                    self.fail(n, f"empty or duplicate id {a['id']!r}")
                if SPACE.search(a["id"]):
                    self.fail(n, "id must not contain ASCII whitespace")
                ids.add(a["id"])
            if tag == "title":
                self.title = text_content(n)
            elif tag == "meta":
                if a.get("charset", "").lower() != "utf-8":
                    self.fail(n, "only a UTF-8 charset declaration has a native metadata mapping")
            elif tag in ("link", "style"):
                if a.get("type", "text/css").strip().lower() != "text/css":
                    self.fail(n, "only text/css stylesheets have a native mapping")
                if tag == "style":
                    off = next((c.get("offset") for c in n["children"] if c["kind"] == "text"), 0)
                    sheets.append((str(path), text_content(n), off or 0))
                else:
                    if a.get("rel", "").strip().lower() != "stylesheet" or not a.get("href"):
                        self.fail(n, "link requires rel=stylesheet and a local href")
                    url = urlsplit(a["href"])
                    local_path = unquote(url.path)
                    if (url.scheme or url.netloc or url.query or url.fragment or not local_path
                            or local_path.startswith(("/", "\\")) or Path(local_path).is_absolute()):
                        self.fail(n, "stylesheet href must be a relative local file")
                    try:
                        self.add_sheet(sheets, path.parent / local_path)
                    except (OSError, UnicodeError) as exc:
                        self.fail(n, f"cannot read stylesheet {a['href']!r}: {exc}")
            if tag == "html":
                self.state_name = a.get("data-zig-state")
                if self.state_name is not None and not IDENT.fullmatch(self.state_name):
                    self.fail(n, "data-zig-state must name a Zig struct")
                self.theme = a.get("data-theme", "dark")
                if self.theme not in ("dark", "light"):
                    self.fail(n, "data-theme must be dark or light")
            if HANDLER in a or "on:click" in a:
                fn = a.get(HANDLER, a.get("on:click"))
                if HANDLER in a and "on:click" in a or not all(IDENT.fullmatch(p) for p in fn.split(".")):
                    self.fail(n, "declare one Zig callback using its dotted declaration name")
                if not a.get("id"):
                    self.fail(n, "a Zig writer needs a button id")
                fields = tuple(a.get(WRITES, "").split())
                if not all(IDENT.fullmatch(k) for k in fields) or len(set(fields)) != len(fields):
                    self.fail(n, "data-zig-writes must list the state fields this Zig callback may modify")
                self.writes.update(fields)
                self.handlers.append((a["id"], fn, fields, self.at(n)))
            elif WRITES in a:
                self.fail(n, "data-zig-writes requires an explicit Zig callback")
        if self.writes and not self.state_name:
            self.fail(self.root, "declare the handlers module's state type with data-zig-state on <html>")
        for sheet in stylesheets:
            self.add_sheet(sheets, sheet)
        self.styles = compute_styles(self.root, sheets, lambda css: parse_native(parser, "css", css),
                                     html_source=self.source, html_path=str(path),
                                     parse_declarations=lambda css: parse_native(parser, "declarations", css))

    def at(self, n):
        return loc(self.path, self.source, n.get("offset"))

    def fail(self, n, message):
        raise CompileError(f"{self.at(n)}: error: {message}")

    @staticmethod
    def check(result, path, source):
        for diag in result.get("diagnostics", []):
            raise CompileError(f"{loc(path, source, diag.get('offset'))}: error: {diag['message']}")

    def add_sheet(self, sheets, path):
        sheets.append((str(path), path.read_bytes().decode("utf-8")))
        self.dependencies.append(path)

    def validate_attrs(self, n, a):
        tag = n["tag"]
        extra = {"html": {"data-zig-state", "data-theme"}, "input": {"type", "value", HANDLER, WRITES, "on:click"},
                 "button": {"type", HANDLER, WRITES, "on:click"},
                 "style": {"type"}, "link": {"rel", "href", "type"}, "meta": {"charset"}}
        for attr in n["attrs"]:
            key = attr["name"]
            if key == "data-zig-if" and tag not in METADATA | {"html", "body"}:
                continue
            if key not in {"class", "id", "style"} | extra.get(tag, set()):
                self.fail(attr, f"attribute {key!r} on <{tag}> has no native mapping")
        if tag == "button" and a.get("type", "button").lower() != "button":
            self.fail(n, "button form submission/reset needs native form association")
        if tag == "input" and a.get("type", "text").lower() != "button":
            self.fail(n, f"input type={a.get('type', 'text')!r} needs a native read-only/writer mapping")

    def caption(self, n, text):
        text = SPACE.sub(" ", text).strip(" ")
        if self.state_name and ("{" in text or "}" in text):
            match = re.fullmatch(r"\{([A-Za-z_][A-Za-z0-9_]*)\}", text)
            if not match:
                self.fail(n, "a text binding must be one {field}; compose other text in Zig")
            name = match[1]
            self.reads.add((name, self.at(n)))
            # Only explicitly writable fields are native signal bindings. Other
            # fields are default values evaluated by Zig during compilation.
            return "." + ident(name) if name in self.writes else "@field(defaults, " + quoted(name) + ")"
        return quoted(text)

    def emit(self, n, ancestors=()):
        tag, a = n["tag"], attrs(n)
        if tag in METADATA:
            return None
        computed = self.styles[id(n)]
        block = tag in BOXES or tag in HEADINGS or tag == "p"
        defaults = (".fill" if block else ".fit", ".fill" if tag in ("html", "body") else ".fit")
        fields = dict(emit_style(computed, size_defaults=defaults))
        if block:
            fields.setdefault("size", ".{ " + ", ".join(defaults) + " }")
        text = {"wrap": "true", **computed.text}
        children = [c for c in n["children"] if c["kind"] == "element"]
        if tag in TEXT | HEADINGS | {"button", "input"}:
            if children:
                self.fail(n, f"inline child <{children[0]['tag']}> in <{tag}> needs native inline formatting")
            cap = self.caption(n, a.get("value", "") if tag == "input" else text_content(n))
            if tag in HEADINGS:
                expr = f"s.heading({tag[1]}, {cap})"
            elif tag in TEXT:
                expr = f"lcgf.widgets_label.ct.label(theme, {cap})"
            else:
                # Native buttons report transient interaction. Only Page's explicit
                # dispatch below has access to change the document state.
                widget_id = a.get("id")
                if widget_id is None:
                    widget_id = f"__decomposer_button_{len(self.nodes)}"
                    while widget_id in self.ids:
                        widget_id += "_"
                    self.ids.add(widget_id)
                expr = f"lcgf.widgets_button.ct.button(theme, .{ident(widget_id)}, {cap})"
            target = "buttonCaption" if tag in ("button", "input") else "labelStyle"
            expr = f"{target}({expr}, {typed_patch('lcgf.types.TextStyle', text)})"
        elif tag == "hr":
            expr = "lcgf.widgets_separator.ct.separator(theme, .horizontal)"
        elif tag in BOXES:
            inner = []
            inline_content = []
            for c in n["children"]:
                if c["kind"] == "element":
                    ref = self.emit(c, ancestors + (tag,))
                    if ref:
                        field = attrs(c).get("data-zig-if")
                        if field and field not in self.writes:
                            inner.append((ref, field))
                        else:
                            inner.append((ref, None))
                        inline_content.append(c["tag"] in {"span", "button", "input"})
                elif c["kind"] == "text" and SPACE.sub(" ", c["text"]).strip(" "):
                    cap = self.caption(c, c["text"])
                    value = f"lcgf.widgets_label.ct.label(theme, {cap})"
                    value = f"labelStyle({value}, {typed_patch('lcgf.types.TextStyle', text)})"
                    inner.append((value, None))
                    inline_content.append(True)
            if not computed.flex and any(a and b for a, b in zip(inline_content, inline_content[1:])):
                self.fail(n, "mixed or adjacent inline boxes need a native inline formatting context; use display:flex for a native flex container")
            builder = "row" if computed.axis == "x" else "col"
            if any(field for _, field in inner):
                kids = " ++ ".join(f"(if (@field(defaults, {quoted(field)})) .{{{ref}}} else .{{}})"
                                   if field else ".{" + ref + "}" for ref, field in inner)
            else:
                kids = ".{ " + ", ".join(ref for ref, _ in inner) + " }"
            role = LANDMARKS.get(tag)
            if tag in ("header", "footer") and any(t in SECTIONING for t in ancestors):
                role = None
            if role:
                fields["dir"] = "." + computed.axis
                expr = f"s.landmark(.{role}, {literal(fields)}, {kids})"
            else:
                expr = f"s.{builder}({literal(fields)}, {kids})"
            fields = {}
        else:
            self.fail(n, f"<{tag}> has no native widget builder")
        if fields:
            assignments = "\n".join(f"    n.style.{k} = {v};" for k, v in fields.items())
            expr = f"blk: {{\n    var n = {expr};\n{assignments}\n    break :blk n;\n}}"
        field = a.get("data-zig-if")
        if field and field in self.writes:
            expr = f"s.when(.{ident(field)}, {expr})"
        ref = f"node_{len(self.nodes)}"
        origin = self.at(n).replace("\r", " ").replace("\n", " ")
        self.nodes.append(f"// <{tag}> at {origin}\nconst {ref}: s.Spec = {expr};")
        return ref

    def generate(self):
        root = self.emit(self.root)
        required = bool(self.reads or self.handlers or self.conditions)
        lines = ['// Generated by LCGF decomposer.', 'const std = @import("std");', 'const lcgf = @import("lcgf");',
                 'const s = lcgf.spec;', 'const w = lcgf.widgets_base;']
        if required:
            lines.append('const handlers = @import("handlers");')
            if self.state_name:
                msg = quoted(self.at(self.root) + ": no public Zig state type " + self.state_name)
                lines.append(f'comptime {{ if (!@hasDecl(handlers, {quoted(self.state_name)})) @compileError({msg}); }}')
            source_type = f'@field(handlers, {quoted(self.state_name)})' if self.state_name else "struct {}"
            lines += [f'const SourceState = {source_type};',
                      'const defaults: SourceState = .{};']
        lines.append("pub const State = struct {")
        for name in sorted(self.writes):
            key = quoted(name)
            lines.append(f"    {ident(name)}: @FieldType(SourceState, {key}) = @field(defaults, {key}),")
        lines.append("};")
        theme_patch = typed_patch("w.Theme", self.styles[id(self.root)].theme)
        lines += [
                  'pub const title = ' + quoted(self.title) + ';',
                  f'pub const theme = lcgf.theme.override(lcgf.theme.widgets(&lcgf.theme.{self.theme}), {theme_patch});']
        for field, at in sorted(self.reads):
            lines.append(f'comptime {{ if (!@hasField(SourceState, {quoted(field)})) @compileError({quoted(at + ": unknown state field " + field)}); }}')
        for field, at in sorted(self.conditions):
            lines.append(f'comptime {{ if (!@hasField(SourceState, {quoted(field)}) or @FieldType(SourceState, {quoted(field)}) != bool) @compileError({quoted(at + ": condition requires a bool field " + field)}); }}')
        for _, fn, fields, at in self.handlers:
            scope = "handlers"
            for part in fn.split("."):
                lines.append(f'comptime {{ if (!@hasDecl({scope}, {quoted(part)})) @compileError({quoted(at + ": unknown Zig callback " + fn)}); }}')
                scope += "." + ident(part)
            for field in fields:
                lines.append(f'comptime {{ if (!@hasField(SourceState, {quoted(field)})) @compileError({quoted(at + ": unknown writer target " + field)}); }}')
        lines += self.nodes + [f'pub const spec = {root};', 'pub const Ui = w.ComptimeUi(State, spec, theme);']
        helper = Path(__file__).with_name("page_helpers.zig").read_text()
        lines.append(helper)
        if self.handlers:
            lines.append(Path(__file__).with_name("writer.zig").read_text())
        lines += ['pub const Page = struct {', '    ui: Ui = .{},', '    pub fn frame(self: *@This(), input: *const lcgf.input.Input) Ui.Output {']
        if self.handlers:
            binding = "var" if self.writes else "const"
            lines += [f'        {binding} out = self.ui.frame(input);', '        if (out.event) |event| {']
            for widget, fn, fields, at in self.handlers:
                callback = "handlers" + "".join("." + ident(k) for k in fn.split("."))
                path = ", ".join(quoted(k) for k in fields)
                lines += [f'            if (@hasField(@TypeOf(event), {quoted(widget)}) and event == .{ident(widget)}) {{', f'                var writer = Writer(.{{ {path} }}){{ .runtime = &self.ui.signals }};',
                          f'                {callback}(&writer);']
                if fields:
                    lines.append('                out.wake = 0;')
                lines.append('            }')
            lines += ['        }', '        return out;']
        else:
            lines += ['        return self.ui.frame(input);']
        return "\n".join(lines + ['    }', '};', ''])


def atomic_write(path, data):
    path = Path(path)
    # Invalid input and interrupted writes leave the last successful output intact.
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, encoding="utf-8", delete=False) as tmp:
        try:
            tmp.write(data)
            tmp.close()
            os.replace(tmp.name, path)
        finally:
            Path(tmp.name).unlink(missing_ok=True)


def dep_escape(path):
    return str(path).replace("\\", "\\\\").replace("$", "$$").replace("#", "\\#").replace(" ", "\\ ")


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("html", nargs="?", type=Path)
    cli.add_argument("--parser", default="decomposer-parse", help="path to the Lexbor host executable")
    cli.add_argument("--css", type=Path, action="append", default=[], help="append a stylesheet after document styles")
    cli.add_argument("-o", "--output", type=Path, help="write generated Zig here (default stdout)")
    cli.add_argument("--depfile", type=Path)
    cli.add_argument("--emit-zig", type=Path, metavar="DIR", help="export a standalone editable native Zig package")
    cli.add_argument("--handlers", type=Path, metavar="FILE", help="Zig source copied into the exported project")
    cli.add_argument("--mappings", action="store_true", help="emit the standards inventory, planned native targets and gaps")
    cli.add_argument("--fragment", action="store_true", help="compile a snippet in a synthetic standards-mode document")
    cli.add_argument("--explain", action="store_true", help="list runtime writers on stderr")
    args = cli.parse_args()
    if args.mappings:
        for row in inventory():
            print("\t".join(row))
        return 0
    if args.handlers and not args.emit_zig:
        cli.error("--handlers is used with --emit-zig")
    if not args.html or args.depfile and not args.output:
        cli.error("supply HTML input and use --output with --depfile")
    try:
        compiler = Compiler(args.parser, args.html, args.css, args.fragment)
        code = compiler.generate()
        if args.emit_zig:
            from export_project import export_project
            export_project(args.emit_zig, code, Path(__file__).resolve().parents[2], args.handlers)
        if args.explain:
            print("comptime native Spec", file=sys.stderr)
            for widget, fn, fields, at in compiler.handlers:
                print(f"{at}: #{widget} calls {fn}, writes {' '.join(fields)}", file=sys.stderr)
        if args.output:
            atomic_write(args.output, code)
        elif not args.emit_zig:
            sys.stdout.write(code)
        if args.depfile:
            atomic_write(args.depfile, dep_escape(args.output) + ": " + " ".join(
                dep_escape(p.resolve()) for p in dict.fromkeys(compiler.dependencies)) + "\n")
    except (ValueError, OSError, RecursionError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
