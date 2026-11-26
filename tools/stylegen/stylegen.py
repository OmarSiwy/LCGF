#!/usr/bin/env python3
"""Compile a declared DTCG 2025.10 subset to caller-owned LCGF data.

Host tool, Python standard library only. It never evaluates expressions, imports input
modules, fetches references or executes generated code. Source/metadata round-trip in the
optional JSON report; the target profile records rem, blur and color lowering decisions.
See docs/styling/recipes.md for the supported format and consumer examples.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import re
import sys
from dataclasses import dataclass
from typing import Any


class TokenError(ValueError):
    def __init__(self, code: str, path: str, message: str):
        self.code, self.path, self.message = code, path, message
        super().__init__(f"{code} at {path or '<root>'}: {message}")


@dataclass(frozen=True)
class Profile:
    root_font_size: float = 16.0
    # DTCG defines a blur radius, not a Gaussian sigma. This target explicitly chooses
    # the CSS shadow convention; hosts using another radius convention can override it.
    shadow_radius_to_sigma: float = 0.5
    max_tokens: int = 10000
    max_depth: int = 64
    max_bytes: int = 8 * 1024 * 1024


@dataclass(frozen=True)
class Token:
    name: str
    pointer: str
    type: str | None
    value: Any
    source: dict[str, Any]


TYPES = frozenset(("color", "dimension", "fontFamily", "fontWeight", "duration", "cubicBezier", "number", "strokeStyle", "border", "transition", "shadow", "gradient", "typography"))
WEIGHTS = {"thin": 100, "hairline": 100, "extra-light": 200, "ultra-light": 200, "light": 300, "normal": 400, "regular": 400, "book": 400, "medium": 500, "semi-bold": 600, "demi-bold": 600, "bold": 700, "extra-bold": 800, "ultra-bold": 800, "black": 900, "heavy": 900, "extra-black": 950, "ultra-black": 950}
STROKES = frozenset(("solid", "dashed", "dotted", "double", "groove", "ridge", "outset", "inset"))
COLORS = frozenset(("srgb", "srgb-linear", "display-p3", "lab", "lch", "oklab", "oklch", "hsl", "hwb", "xyz-d50", "xyz-d65", "a98-rgb", "prophoto-rgb", "rec2020"))


def fail(code: str, path: str, message: str) -> None:
    raise TokenError(code, path, message)


def pairs(items: list[tuple[str, Any]]) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for key, value in items:
        if key in out:
            fail("DuplicateKey", key, "duplicate JSON object key")
        out[key] = value
    return out


def load(source: str, profile: Profile = Profile()) -> dict[str, Any]:
    if len(source.encode("utf-8")) > profile.max_bytes:
        fail("Limit", "", "input exceeds max_bytes")
    try:
        document = json.loads(source, object_pairs_hook=pairs, parse_constant=lambda x: fail("InvalidNumber", "", x))
    except TokenError:
        raise
    except (ValueError, RecursionError) as error:
        fail("InvalidJSON", "", str(error))
    if not isinstance(document, dict):
        fail("InvalidDocument", "", "top level must be an object")
    return document


def scalar(value: Any, path: str, lower: float | None = None, upper: float | None = None) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        fail("InvalidNumber", path, "expected a finite number")
    try:
        number = float(value)
    except OverflowError:
        fail("InvalidNumber", path, "number is outside the target range")
    if not math.isfinite(number):
        fail("InvalidNumber", path, "expected a finite number")
    # Every generated numeric value is representable in the core's f32 properties.
    if abs(number) > 3.402823466e38 or (lower is not None and number < lower) or (upper is not None and number > upper):
        fail("InvalidNumber", path, "number is outside the target range")
    return number


def object_keys(value: Any, required: set[str], optional: set[str], path: str) -> dict[str, Any]:
    if not isinstance(value, dict) or not required.issubset(value) or set(value) - required - optional:
        fail("InvalidValue", path, f"expected object keys {sorted(required)}; optional {sorted(optional)}")
    return value


def ptr_escape(text: str) -> str:
    return text.replace("~", "~0").replace("/", "~1")


def zig_string(value: str) -> str:
    result = '"'
    for char in value:
        n = ord(char)
        if char in ('"', "\\"):
            result += "\\" + char
        elif char == "\n":
            result += "\\n"
        elif char == "\r":
            result += "\\r"
        elif char == "\t":
            result += "\\t"
        elif n < 32 or n == 127:
            result += f"\\x{n:02x}"
        elif 0xD800 <= n <= 0xDFFF:
            fail("InvalidUnicode", "", "unpaired surrogate is not UTF-8")
        else:
            result += char
    return result + '"'


def znum(value: float) -> str:
    return format(float(value), ".17g")


def zid(value: str) -> str:
    return "@" + zig_string(value)


def token_hash(name: str) -> int:
    h = 0x811C9DC5
    for byte in name.encode("utf-8"):
        h = ((h ^ byte) * 0x01000193) & 0xFFFFFFFF
    return h or 1


class Compiler:
    def __init__(self, document: dict[str, Any], profile: Profile):
        scalar(profile.root_font_size, "profile.root_font_size", 0.0001)
        scalar(profile.shadow_radius_to_sigma, "profile.shadow_radius_to_sigma", 0)
        if min(profile.max_tokens, profile.max_depth, profile.max_bytes) < 1:
            fail("InvalidProfile", "", "limits must be positive")
        self.document, self.profile = document, profile
        self.tokens: dict[str, Token] = {}
        self.by_pointer: dict[str, str] = {}
        self.cache: dict[str, Any] = {}
        self.type_cache: dict[str, str] = {}
        self._bounds(document, 0)
        self._collect(document, (), "#", None)
        hashes: dict[int, str] = {}
        for name in self.tokens:
            h = token_hash(name)
            if h in hashes and hashes[h] != name:
                fail("IdCollision", name, f"LCGF Id collides with {hashes[h]!r}")
            hashes[h] = name

    def _bounds(self, value: Any, depth: int) -> None:
        if depth > self.profile.max_depth:
            fail("Limit", "", "JSON nesting exceeds max_depth")
        if isinstance(value, dict):
            for key, child in value.items():
                zig_string(key)
                self._bounds(child, depth + 1)
        elif isinstance(value, list):
            for child in value:
                self._bounds(child, depth + 1)
        elif isinstance(value, str):
            zig_string(value)

    def _collect(self, node: dict[str, Any], path: tuple[str, ...], pointer: str, inherited: str | None) -> None:
        name = ".".join(path)
        if "$extends" in node:
            fail("UnsupportedGroupExtension", name, "$extends must be expanded by the authoring tool before this target compiler")
        kind = node.get("$type", inherited)
        if kind is not None and (not isinstance(kind, str) or kind not in TYPES):
            fail("UnsupportedType", name, str(kind))
        if "$value" in node:
            if not path:
                fail("InvalidToken", name, "root object is a group")
            unknown = set(node) - {"$value", "$type", "$description", "$extensions", "$deprecated"}
            if unknown:
                fail("InvalidToken", name, f"token has non-metadata children {sorted(unknown)}")
            if len(self.tokens) >= self.profile.max_tokens:
                fail("Limit", name, "token count exceeds max_tokens")
            self.tokens[name] = Token(name, pointer, kind, node["$value"], node)
            self.by_pointer[pointer + "/$value"] = name
            return
        for key, child in node.items():
            if key in {"$type", "$description", "$extensions", "$deprecated", "$schema"}:
                continue
            if key != "$root" and (not key or key.startswith("$") or any(c in key for c in ".{}")):
                fail("InvalidName", name + "." + key, "names cannot contain dots/braces or start with $")
            if not isinstance(child, dict):
                fail("InvalidGroup", name + "." + key, "group children must be tokens or groups")
            self._collect(child, path + (key,), pointer + "/" + ptr_escape(key), kind)

    def reference(self, value: Any, path: str) -> tuple[str, str] | None:
        if isinstance(value, str) and (value.startswith("{") or value.endswith("}")):
            if not re.fullmatch(r"\{[^{}]+\}", value):
                fail("InvalidReference", path, "an alias must occupy the whole value")
            return "token", value[1:-1]
        if isinstance(value, dict) and "$ref" in value:
            if set(value) != {"$ref"} or not isinstance(value["$ref"], str) or not value["$ref"].startswith("#/"):
                fail("InvalidReference", path, "only local JSON Pointer {$ref:'#/...'} is supported")
            return "pointer", value["$ref"]
        return None

    def pointer(self, pointer: str, path: str) -> Any:
        at: Any = self.document
        for raw in pointer[2:].split("/"):
            if re.search(r"~(?![01])", raw):
                fail("InvalidReference", path, "invalid JSON Pointer escape")
            key = raw.replace("~1", "/").replace("~0", "~")
            if isinstance(at, dict) and key in at:
                at = at[key]
            elif isinstance(at, list) and re.fullmatch(r"0|[1-9][0-9]*", key) and int(key) < len(at):
                at = at[int(key)]
            else:
                fail("MissingReference", path, pointer)
        return at

    def chain(self, marker: str, chain: tuple[str, ...], path: str) -> tuple[str, ...]:
        if marker in chain:
            fail("ReferenceCycle", path, " -> ".join(chain + (marker,)))
        if len(chain) >= self.profile.max_depth:
            fail("Limit", path, "reference chain exceeds max_depth")
        return chain + (marker,)

    def type_of(self, name: str, chain: tuple[str, ...] = ()) -> str:
        if name in self.type_cache:
            return self.type_cache[name]
        if name not in self.tokens:
            fail("MissingReference", name, "token does not exist")
        token = self.tokens[name]
        if token.type is not None:
            return token.type
        chain = self.chain("type:" + name, chain, name)
        ref = self.reference(token.value, name)
        target = ref[1] if ref and ref[0] == "token" else self.by_pointer.get(ref[1]) if ref else None
        if target is None:
            fail("MissingType", name, "no declared/inherited type or whole-token alias type")
        result = self.type_of(target, chain)
        self.type_cache[name] = result
        return result

    def resolve(self, name: str, chain: tuple[str, ...] = ()) -> Any:
        if name in self.cache:
            return self.cache[name]
        kind = self.type_of(name)
        chain = self.chain("token:" + name, chain, name)
        out = self.typed(self.tokens[name].value, kind, name, chain)
        self.cache[name] = out
        return out

    def typed(self, value: Any, kind: str, path: str, chain: tuple[str, ...]) -> Any:
        ref = self.reference(value, path)
        if ref:
            target = ref[1] if ref[0] == "token" else self.by_pointer.get(ref[1])
            if target is not None:
                actual = self.type_of(target)
                if actual != kind:
                    fail("TypeMismatch", path, f"requires {kind}, references {actual} token {target}")
                return self.resolve(target, chain)
            pointer_chain = self.chain("pointer:" + ref[1], chain, path)
            return self.typed(self.pointer(ref[1], path), kind, path, pointer_chain)
        child = lambda v, t, suffix: self.typed(v, t, path + "." + suffix, chain)
        number = lambda v, suffix: child(v, "number", suffix)
        if kind == "number":
            return scalar(value, path)
        if kind in {"dimension", "duration"}:
            object_keys(value, {"value", "unit"}, set(), path)
            n = number(value["value"], "value")
            units = {"px": 1, "rem": self.profile.root_font_size} if kind == "dimension" else {"s": 1, "ms": 0.001}
            if not isinstance(value["unit"], str) or value["unit"] not in units:
                fail("UnsupportedUnit", path, str(value["unit"]))
            return scalar(n * units[value["unit"]], path, 0 if kind == "duration" else None)
        if kind == "fontFamily":
            families = [value] if isinstance(value, str) else value
            if not isinstance(families, list) or not families or any(not isinstance(s, str) or not s for s in families):
                fail("InvalidValue", path, "fontFamily needs a nonempty string or list of strings")
            return families
        if kind == "fontWeight":
            if isinstance(value, str):
                if value not in WEIGHTS:
                    fail("UnsupportedValue", path, "unknown fontWeight name")
                return float(WEIGHTS[value])
            return scalar(value, path, 1, 1000)
        if kind == "cubicBezier":
            if not isinstance(value, list) or len(value) != 4:
                fail("InvalidValue", path, "cubicBezier needs four numbers")
            out = [number(v, str(i)) for i, v in enumerate(value)]
            scalar(out[0], path, 0, 1)
            scalar(out[2], path, 0, 1)
            return out
        if kind == "color":
            object_keys(value, {"colorSpace", "components"}, {"alpha", "hex"}, path)
            if not isinstance(value["colorSpace"], str) or value["colorSpace"] not in COLORS:
                fail("UnsupportedColorSpace", path, str(value["colorSpace"]))
            components = value["components"]
            if not isinstance(components, list) or len(components) != 3:
                fail("InvalidValue", path, "color needs three components")
            if "none" in components or value.get("alpha") == "none":
                fail("UnsupportedMissingComponent", path, "this native target requires concrete color components")
            alpha = scalar(number(value.get("alpha", 1), "alpha"), path, 0, 1)
            return {"space": value["colorSpace"], "components": [number(v, str(i)) for i, v in enumerate(components)], "alpha": alpha}
        if kind == "strokeStyle":
            if isinstance(value, str):
                if value not in STROKES:
                    fail("InvalidValue", path, "unknown strokeStyle keyword")
                return {"keyword": value}
            object_keys(value, {"dashArray", "lineCap"}, set(), path)
            if not isinstance(value["lineCap"], str) or value["lineCap"] not in {"butt", "round", "square"} or not isinstance(value["dashArray"], list) or not value["dashArray"]:
                fail("InvalidValue", path, "strokeStyle needs a dashArray and a native lineCap")
            array = [scalar(child(v, "dimension", f"dashArray.{i}"), path, 0) for i, v in enumerate(value["dashArray"])]
            if not any(array):
                fail("InvalidValue", path, "dashArray cannot be all zero")
            return {"array": array, "cap": value["lineCap"]}
        if kind == "border":
            object_keys(value, {"color", "width", "style"}, set(), path)
            stroke = child(value["style"], "strokeStyle", "style")
            if "keyword" not in stroke:
                fail("UnsupportedBorderPattern", path, "arbitrary dash arrays are native path styles; decoration.Border requires a keyword")
            return {"color": child(value["color"], "color", "color"), "width": scalar(child(value["width"], "dimension", "width"), path, 0), "style": stroke["keyword"]}
        if kind == "transition":
            object_keys(value, {"duration", "delay", "timingFunction"}, set(), path)
            return {"duration": child(value["duration"], "duration", "duration"), "delay": child(value["delay"], "duration", "delay"), "curve": child(value["timingFunction"], "cubicBezier", "timingFunction")}
        if kind in {"shadow", "gradient"}:
            rows = value if isinstance(value, list) else [value] if kind == "shadow" else None
            if not rows:
                fail("InvalidValue", path, f"{kind} requires a nonempty array" if kind == "gradient" else "shadow requires an object or nonempty array")
            out = []
            for i, row in enumerate(rows):
                at = f"{path}.{i}"
                if self.reference(row, at):
                    target = child(row, kind, str(i))
                    if len(target) != 1:
                        fail("InvalidCompositeReference", at, "array element references must resolve to one object, not an array to flatten")
                    out.append(target[0])
                elif kind == "shadow":
                    object_keys(row, {"color", "offsetX", "offsetY", "blur", "spread"}, {"inset"}, at)
                    if not isinstance(row.get("inset", False), bool):
                        fail("InvalidValue", at, "inset must be a boolean")
                    out.append({"color": child(row["color"], "color", f"{i}.color"), "x": child(row["offsetX"], "dimension", f"{i}.offsetX"), "y": child(row["offsetY"], "dimension", f"{i}.offsetY"), "sigma": scalar(child(row["blur"], "dimension", f"{i}.blur"), at, 0) * self.profile.shadow_radius_to_sigma, "spread": child(row["spread"], "dimension", f"{i}.spread"), "inset": row.get("inset", False)})
                else:
                    object_keys(row, {"color", "position"}, set(), at)
                    out.append({"color": child(row["color"], "color", f"{i}.color"), "position": min(1, max(0, number(row["position"], f"{i}.position")))})
            return sorted(out, key=lambda row: row["position"]) if kind == "gradient" else out
        if kind == "typography":
            object_keys(value, {"fontFamily", "fontSize", "fontWeight", "letterSpacing", "lineHeight"}, set(), path)
            return {"families": child(value["fontFamily"], "fontFamily", "fontFamily"), "size": scalar(child(value["fontSize"], "dimension", "fontSize"), path, 0), "weight": child(value["fontWeight"], "fontWeight", "fontWeight"), "spacing": child(value["letterSpacing"], "dimension", "letterSpacing"), "height": scalar(number(value["lineHeight"], "lineHeight"), path, 0)}
        fail("UnsupportedType", path, kind)

    def alias_target(self, token: Token) -> str | None:
        ref = self.reference(token.value, token.name)
        return ref[1] if ref and ref[0] == "token" else self.by_pointer.get(ref[1]) if ref else None

    def output(self) -> tuple[str, dict[str, Any]]:
        for name in self.tokens:
            self.resolve(name)
        lines = [HEADER]
        entries: list[str] = []
        metadata = []
        values: list[tuple[str, str, str]] = []
        primitive = {"color": "color", "dimension": "number", "duration": "number", "number": "number", "fontWeight": "number", "cubicBezier": "vector4"}
        lines.append("        pub const values = struct {")
        for name in sorted(self.tokens):
            token = self.tokens[name]
            kind, value = self.type_of(name), self.cache[name]
            alias = self.alias_target(token)
            native_type, expression = emit(kind, value)
            # Struct fields cannot shadow helper declarations; valid tokens named `color`,
            # `lcgf`, `Typography`, etc. remain valid. Scalar alias identity lives in entries.
            values.append((name, native_type, expression))
            lines.append(f"            {zid(name)}: {native_type},")
            if kind in primitive:
                if alias is not None:
                    entries.append(f"style.tokens.alias(.from({zig_string(name)}), .from({zig_string(alias)}))")
                else:
                    expr = "values." + zid(name)
                    if kind == "color":
                        expr = "@bitCast(color.pack(" + expr + "))"
                    elif kind == "cubicBezier":
                        expr += ".cubic"
                    entries.append(".{ .id = .from(" + zig_string(name) + "), .binding = .{ .value = .{ ." + primitive[kind] + " = " + expr + " } } }")
            metadata.append({"name": name, "id": token_hash(name), "type": kind, "alias": alias, "source_pointer": token.pointer, "source": token.source})
        lines.append("        }{")
        for name, _, expression in values:
            lines.append(f"            .{zid(name)} = {expression},")
        lines.append("        };")
        lines.append("        pub const entries = [_]style.tokens.Entry{\n            " + ",\n            ".join(entries) + ("," if entries else "") + "\n        };")
        lines.append("        pub const metadata = [_]Metadata{")
        for row in metadata:
            description = row["source"].get("$description", "")
            if not isinstance(description, str):
                fail("InvalidMetadata", row["name"], "$description must be a string")
            lines.append("            .{ .id = .from(" + zig_string(row["name"]) + "), .name = " + zig_string(row["name"]) + ", .type_name = " + zig_string(row["type"]) + ", .description = " + zig_string(description) + " },")
        lines.extend(("        };", "    };", "}", ""))
        report = {"format": "DTCG 2025.10 declared native subset", "profile": {"root_font_size": self.profile.root_font_size, "shadow_radius_to_sigma": self.profile.shadow_radius_to_sigma, "native_colors": "extended sRGB floats; style Entry colors are clamped RGBA8", "gradient_order": "stable sort by clamped position", "whole_aliases": "preserved by id in scalar entries"}, "tokens": metadata, "source": self.document}
        return "\n".join(lines), report


def rgba(value: dict[str, Any]) -> str:
    name = value["space"]
    components = value["components"] + [value["alpha"]]
    if name in {"hsl", "hwb"}:
        components = [components[0], components[1] / 100, components[2] / 100, components[3]]
    args = ", ".join(znum(v) for v in components)
    if name == "srgb":
        return '@"$color".rgba(' + args + ")"
    if name == "srgb-linear":
        return '@"$color".encoded(.{ ' + args + " })"
    if name == "display-p3":
        return '@"$color".displayP3(.{ ' + args + " })"
    spaces = {"xyz-d50": "xyzD50", "xyz-d65": "xyzD65", "a98-rgb": "a98Rgb", "prophoto-rgb": "prophotoRgb", "rec2020": "rec2020"}
    if name in spaces:
        return '@"$color".' + spaces[name] + "(.{ " + args + " })"
    return '@"$color".' + name + "(" + args + ")"


def emit(kind: str, value: Any) -> tuple[str, str]:
    if kind == "color":
        return '@"$color".Rgba', rgba(value)
    if kind in {"dimension", "duration", "number", "fontWeight"}:
        return "f32", znum(value)
    if kind == "fontFamily":
        return "[]const []const u8", "&.{ " + ", ".join(zig_string(v) for v in value) + " }"
    if kind == "cubicBezier":
        return '@"$api".motion.Curve', ".{ .cubic = .{ " + ", ".join(znum(v) for v in value) + " } }"
    if kind == "strokeStyle":
        if "keyword" in value:
            return '@"$StrokeStyle"', ".{ .keyword = ." + value["keyword"] + " }"
        return '@"$StrokeStyle"', ".{ .pattern = .{ .array = &.{ " + ", ".join(znum(v) for v in value["array"]) + " }, .cap = ." + value["cap"] + " } }"
    if kind == "border":
        return '@"$api".decoration.Border', ".{ .edges = @splat(.{ .width = " + znum(value["width"]) + ", .brush = .{ .solid = " + rgba(value["color"]) + " }, .style = ." + value["style"] + " }) }"
    if kind == "transition":
        return '@"$Transition"', ".{ .timing = .{ .duration = " + znum(value["duration"]) + ", .delay = " + znum(value["delay"]) + " }, .curve = " + emit("cubicBezier", value["curve"])[1] + " }"
    if kind == "shadow":
        rows = [".{ .offset = .{ " + znum(v["x"]) + ", " + znum(v["y"]) + " }, .sigma = " + znum(v["sigma"]) + ", .spread = " + znum(v["spread"]) + ", .color = " + rgba(v["color"]) + ", .inset = " + str(v["inset"]).lower() + " }" for v in value]
        return '[]const @"$api".decoration.Shadow', "&.{ " + ", ".join(rows) + " }"
    if kind == "gradient":
        rows = [".{ .position = " + znum(v["position"]) + ", .color = " + rgba(v["color"]) + " }" for v in value]
        return '[]const @"$api".brushes.Stop', "&.{ " + ", ".join(rows) + " }"
    if kind == "typography":
        return '@"$Typography"', ".{ .families = " + emit("fontFamily", value["families"])[1] + ", .request = .{ .weight = " + znum(value["weight"]) + " }, .size = " + znum(value["size"]) + ", .letter_spacing = " + znum(value["spacing"]) + ", .line_height = " + znum(value["height"]) + " }"
    raise AssertionError(kind)


HEADER = '''// Generated by tools/stylegen/stylegen.py. Edit the DTCG source, then regenerate.
// Units/profile and original metadata are recorded in the optional JSON report.
// Pass the imported lcgf module; no generated import path or global registry is required.
pub fn Tokens(comptime lcgf: type) type {
    return struct {
        const style = lcgf.style;
        const color = lcgf.color_math;
        // $-prefixed helper identities cannot collide with valid DTCG token names.
        const @"$api" = lcgf;
        const @"$color" = color;
        const @"$Typography" = Typography;
        const @"$Transition" = Transition;
        const @"$StrokeStyle" = StrokeStyle;
        pub const Metadata = struct { id: lcgf.types.Id, name: []const u8, type_name: []const u8, description: []const u8 };
        pub const Transition = struct { timing: lcgf.motion.Timing, curve: lcgf.motion.Curve };
        /// Pattern arrays feed vector.dash; cap feeds paths.stroke. Keyword borders feed
        /// decoration.Border directly. Neither representation silently approximates the other.
        pub const StrokeStyle = union(enum) {
            keyword: lcgf.decoration.BorderStyle,
            pattern: lcgf.vector.DashStyle,
        };
        pub const Typography = struct {
            families: []const []const u8,
            request: lcgf.font_match.Request,
            size: f32,
            letter_spacing: f32,
            line_height: f32,
            pub fn textStyle(value: @This(), faces: []const lcgf.font_match.Entry) error{FontNotFound}!lcgf.types.TextStyle {
                const index = lcgf.font_match.find(faces, value.families, value.request) orelse return error.FontNotFound;
                return .{ .font = @fromBackingInt(faces[index].font), .px = value.size };
            }
            pub fn paragraph(value: @This()) lcgf.text_stack.Paragraph {
                return .{ .letter_spacing = value.letter_spacing, .line_height = .{ .multiple = value.line_height } };
            }
        };
'''


def generate(document: dict[str, Any], profile: Profile = Profile()) -> tuple[str, dict[str, Any]]:
    return Compiler(document, profile).output()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("--output", "-o", required=True, type=Path)
    parser.add_argument("--metadata", type=Path)
    parser.add_argument("--root-font-size", type=float, default=16)
    parser.add_argument("--shadow-radius-to-sigma", type=float, default=0.5)
    parser.add_argument("--max-tokens", type=int, default=10000)
    parser.add_argument("--max-depth", type=int, default=64)
    parser.add_argument("--max-bytes", type=int, default=8 * 1024 * 1024)
    args = parser.parse_args(argv)
    profile = Profile(args.root_font_size, args.shadow_radius_to_sigma, args.max_tokens, args.max_depth, args.max_bytes)
    try:
        if args.input.stat().st_size > profile.max_bytes:
            fail("Limit", "", "input exceeds max_bytes")
        document = load(args.input.read_text(encoding="utf-8"), profile)
        generated, metadata = generate(document, profile)
        # All parsing/reference/type validation finishes before any output is opened.
        args.output.write_text(generated, encoding="utf-8")
        if args.metadata:
            args.metadata.write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    except (TokenError, OSError, UnicodeError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
