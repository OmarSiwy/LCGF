"""Build-time CSS matching and lowering for the native LCGF markup compiler.

compute_styles(element, [(filename, css[, html_byte_offset])], parse_css) consumes
Lexbor's JSON. Pass html_path/html_source to locate inline declarations.
The id(element)-indexed result contains Zig expressions in .fields, .text and
.theme. currentColor can refer to the generated page's theme.text. emit_style(style, size_defaults) fills in missing axes of a .size pair.
No generated code parses CSS or changes application state.
"""

import colorsys
import math
import re
from dataclasses import dataclass, field

if __package__:
    from .colors import NAMED
else:
    from colors import NAMED


class StyleError(ValueError):
    """A CSS diagnostic anchored in the original input document."""

    def __init__(self, path, source, offset, message):
        offset = min(max(offset or 0, 0), len(source.encode()))
        prefix = source.encode()[:offset].decode(errors="replace")
        self.line = prefix.count("\n") + 1
        self.column = len(prefix.rsplit("\n", 1)[-1]) + 1
        self.path, self.offset, self.message = str(path), offset, message
        lines = source.split("\n")
        super().__init__(f"{path}:{self.line}:{self.column}: error: {message}\n"
                         f"{lines[self.line - 1]}\n{' ' * (self.column - 1)}^")


@dataclass(frozen=True)
class Location:
    path: str
    source: str
    offset: int

    def error(self, message):
        raise StyleError(self.path, self.source, self.offset, message)


@dataclass
class Computed:
    axis: str = "y"
    flex: bool = False
    flex_container: bool = False  # also true on the markup language's native row/col
    fields: dict = field(default_factory=dict)
    text: dict = field(default_factory=dict)
    theme: dict = field(default_factory=dict)
    sizes: list = field(default_factory=lambda: [None, None])
    variables: dict = field(default_factory=dict)
    font_px: float = 14
    stretch: bool = False
    containing_block: bool = False
    padding: tuple = (0, 0, 0, 0)


def emit_style(computed, size_defaults=(".fit", ".fit")):
    fields = computed.fields.copy()
    if any(computed.sizes):
        fields["size"] = array([x or default for x, default in zip(computed.sizes, size_defaults)])
    return fields


def array(items):
    return ".{ " + ", ".join(items) + " }"


def fmt(x):
    if not math.isfinite(x) or abs(x) > 3.40282346e38:
        raise ValueError("value does not fit a native f32")
    return format(x, ".12g") if x else "0"


NAME = r"(?:-?[_a-zA-Z\u0080-\U0010ffff])[-_a-zA-Z0-9\u0080-\U0010ffff]*"
NUMBER = r"[+-]?(?:\d*\.\d+|\d+)(?:[eE][+-]?\d+)?"
TOKEN = re.compile(rf"([.#]?)({NAME})|(:root)|(\*)")
COMPONENT = re.compile(rf"({NUMBER})(%|[a-z]+)?", re.I)
CUSTOM = re.compile(r"--[-\w]+")
INHERITED = {"color", "font-size", "white-space"}
# This is both the compiler's allow-list and the CLI's --mappings source.
PROPERTY_TARGETS = {}
for names, target in (
    ("box-sizing", "content-box or border-box converted to native outer dimensions"),
    ("width height", "Style.size[x or y], logical length, percentage or fit"),
    ("min-width min-height", "Style.min[x or y]"),
    ("max-width max-height", "Style.max[x or y]"),
    ("padding padding-left padding-top padding-right padding-bottom", "Style.pad (left, top, right, bottom)"),
    ("gap row-gap column-gap", "Style.gap along the container's layout axis"),
    ("flex flex-grow", "Style.size[parent main axis].grow"),
    ("flex-basis", "Style.size[parent main axis] for fixed or auto basis"),
    ("flex-shrink", "Style.shrink (0 or 1)"),
    ("flex-direction display", "Style.dir (one-dimensional native flow)"),
    ("align-self", "Style.size[parent cross axis] for stretch"),
    ("align-items", "Style.cross, or stretch an auto-sized child on the cross axis"),
    ("justify-content", "Style.main"),
    ("position", "Style.float for absolute, or a static/relative containing block"),
    ("left top", "Style.offset when absolutely positioned"),
    ("overflow", "Style.clip"),
    ("background background-color", "Style.fill (single color; excludes widget-owned backgrounds)"),
    ("color", "inherited TextStyle.color"),
    ("font-size", "inherited TextStyle.px"),
    ("white-space", "inherited TextStyle.wrap for normal or nowrap"),
    ("opacity", "Style.opacity"),
    ("border border-width border-style border-color", "Style.border and Style.border_color (uniform solid border)"),
    ("border-radius border-top-left-radius border-top-right-radius border-bottom-right-radius border-bottom-left-radius",
     "Style.radius or Style.radii (clockwise from top left)"),
    ("transform transform-origin", "Style.transform (2D affine about the node center)"),
):
    PROPERTY_TARGETS.update(dict.fromkeys(names.split(), target))

METADATA = {"head", "title", "base", "meta", "link", "style", "script", "template"}
CONTROLS = set("button input select textarea progress meter slider checkbox radio switch".split())


def attributes(node):
    attrs = node.get("attrs", [])
    return attrs if isinstance(attrs, dict) else {a["name"]: a["value"] for a in attrs}


def selector_list(source, loc):
    """Split only the supported static selector grammar. Reject unfamiliar syntax even when unmatched."""
    result = []
    for group in source.split(","):
        parts, links, weight = [], [], [0, 0, 0]
        group = group.strip()
        pos = 0
        while pos < len(group):
            tests = []
            while pos < len(group) and not group[pos].isspace() and group[pos] != ">":
                token = TOKEN.match(group, pos)
                if not token:
                    loc.error(f"unsupported selector {source!r} near {group[pos:]!r}")
                prefix, name, root, star = token.groups()
                if tests and ((name and not prefix) or star):
                    loc.error(f"invalid compound selector {source!r}")
                if name:
                    tests.append((prefix, name if prefix else name.lower()))
                    weight[{"#": 0, ".": 1, "": 2}[prefix]] += 1
                elif root:
                    tests.append(("root", ""))
                    weight[1] += 1
                else:
                    tests.append(("*", ""))
                pos = token.end()
            if not tests:
                loc.error(f"invalid selector {source!r}")
            parts.append(tests)
            while pos < len(group) and group[pos].isspace():
                pos += 1
            if pos == len(group):
                break
            child = group[pos] == ">"
            links.append(">" if child else " ")
            if child:
                pos += 1
                while pos < len(group) and group[pos].isspace():
                    pos += 1
                if pos == len(group):
                    loc.error(f"incomplete selector {source!r}")
        if not parts:
            loc.error("empty selector")
        result.append((parts, links, tuple(weight)))
    return result


def matches(selector, ancestry):
    parts, links, _ = selector

    def visit(part, depth):
        if depth < 0:
            return False
        node = ancestry[depth]
        attrs = attributes(node)
        for kind, value in parts[part]:
            if kind == "" and node["tag"].lower() != value:
                return False
            if kind == "." and value not in attrs.get("class", "").split():
                return False
            if kind == "#" and attrs.get("id") != value:
                return False
            if kind == "root" and depth:
                return False
        if part == 0:
            return True
        if links[part - 1] == ">":
            return visit(part - 1, depth - 1)
        return any(visit(part - 1, ancestor) for ancestor in range(depth - 1, -1, -1))
    return visit(len(parts) - 1, len(ancestry) - 1)


def var_parts(value):
    """Yield literal strings or (variable name, fallback token sequence) pairs."""
    pos, scan = 0, 0
    for_start = re.compile(QUOTED + r"|(?P<var>(?<![-\w])var\()", re.I)
    while match := for_start.search(value, scan):
        if not match.group("var"):
            scan = match.end()
            continue
        yield value[pos:match.start()]
        start = match.end()
        level, comma, quote = 1, None, None
        i = start
        while i < len(value):
            char = value[i]
            if quote:
                if char == "\\":
                    i += 1
                elif char == quote:
                    quote = None
            elif char in "\"'":
                quote = char
            elif char == "(":
                level += 1
            elif char == ")":
                level -= 1
                if not level:
                    break
            elif char == "," and level == 1 and comma is None:
                comma = i
            i += 1
        if level:
            raise ValueError("unterminated var()")
        name = value[start:i if comma is None else comma].strip()
        if not CUSTOM.fullmatch(name):
            raise ValueError("var() requires a custom property name")
        yield (name, None if comma is None else value[comma + 1:i].strip())
        pos = scan = i + 1
    yield value[pos:]


def expand_vars(value, lookup):
    output = []
    for part in var_parts(value):
        if isinstance(part, str):
            output.append(part)
            continue
        name, fallback = part
        result = lookup(name)
        if result is None:
            if fallback is None:
                raise ValueError(f"undefined or cyclic CSS variable {name}")
            result = expand_vars(fallback, lookup)
        # Substitution inserts CSS tokens: a number from var(--n) cannot fuse
        # with a following "px" identifier to manufacture a dimension token.
        output.extend((" ", result, " "))
    return "".join(output).strip()


def custom_properties(inherited, local):
    values = dict(inherited)
    pending = {}
    for name, value in local.items():
        if value.lower() in ("inherit", "unset"):
            continue
        if value.lower() == "initial":
            values[name] = None
        else:
            pending[name] = value

    # References in fallback arguments also participate in CSS cycle detection.
    def refs(value):
        for part in var_parts(value):
            if isinstance(part, tuple):
                yield part[0]
                if part[1] is not None:
                    yield from refs(part[1])

    visiting, done, cycles = [], set(), set()

    def check(name):
        if name in visiting:
            cycles.update(visiting[visiting.index(name):])
        elif name in pending and name not in done:
            visiting.append(name)
            for dep in refs(pending[name]):
                check(dep)
            visiting.pop()
            done.add(name)

    for name in pending:
        check(name)

    def resolve(name):
        if name in cycles:
            return None
        if name in pending:
            value = pending.pop(name)
            try:
                values[name] = expand_vars(value, resolve)
            except ValueError:
                values[name] = None
        return values.get(name)

    for name in list(pending):
        values[name] = resolve(name)
    return values


def one_of(value, options):
    if value.lower() not in options:
        raise ValueError(f"cannot represent {value!r}; expected one of {', '.join(options)}")
    return value.lower()


def number(value, units=("",)):
    m = COMPONENT.fullmatch(value.strip().lower())
    if not m or (m[2] or "") not in units:
        raise ValueError(f"unsupported value or unit {value!r}")
    x = float(m[1])
    fmt(x)
    return x, m[2] or ""


def px(value, em, rem, signed=False):
    n, unit = number(value, ("", "px", "em", "rem", "pt", "pc", "in", "cm", "mm", "q"))
    if n < 0 and not signed:
        raise ValueError("a nonnegative length is required")
    if not unit and n != 0:
        raise ValueError("a nonzero CSS length requires a unit")
    result = n * {"": 1, "px": 1, "em": em, "rem": rem, "pt": 96/72, "pc": 16,
                  "in": 96, "cm": 96/2.54, "mm": 96/25.4, "q": 96/101.6}[unit]
    fmt(result)
    return result


def alpha_value(s):
    n, unit = number(s, ("", "%"))
    return max(0, min(1, n / 100 if unit == "%" else n))


def color(value):
    value = value.strip().lower()
    if value == "transparent":
        return ".transparent"
    if value in NAMED:
        value = "#" + NAMED[value]
    if value.startswith("#"):
        digits = value[1:]
        if len(digits) in (3, 4):
            digits = "".join(c * 2 for c in digits)
        if len(digits) == 6:
            digits += "ff"
        if not re.fullmatch(r"[0-9a-f]{8}", digits):
            raise ValueError(f"invalid hex color {value!r}")
    else:
        m = re.fullmatch(r"(rgba?|hsla?)\(([^()]*)\)", value)
        if not m:
            raise ValueError(f"unsupported color {value!r}")
        args = m[2]
        if "," in args:
            channels = [part.strip() for part in args.split(",")]
            alpha = channels.pop() if len(channels) == 4 else "1"
        else:
            channels, delimiter, alpha = args.partition("/")
            channels, alpha = channels.split(), alpha.strip() if delimiter else "1"
        if len(channels) != 3:
            raise ValueError("color requires three channels")
        if m[1].startswith("hsl"):
            hue, unit = number(channels[0], ("", "deg", "turn", "rad", "grad"))
            angle = hue * {"": 1/360, "deg": 1/360, "turn": 1, "rad": 1/math.tau, "grad": 1/400}[unit]
            sat, light = [max(0, min(1, number(v, ("%",))[0] / 100)) for v in channels[1:]]
            values = colorsys.hls_to_rgb(angle % 1, light, sat)
        else:
            rgb = [number(v, ("", "%")) for v in channels]
            values = [max(0, min(1, n / (100 if unit == "%" else 255))) for n, unit in rgb]
        digits = "".join(f"{math.floor(c * 255 + .5):02x}" for c in (*values, alpha_value(alpha)))
    return f".hex(0x{digits})"


def four(words):
    if not 1 <= len(words) <= 4:
        raise ValueError("expected one to four values")
    a = words[0]
    b = words[1] if len(words) > 1 else a
    c = words[2] if len(words) > 2 else a
    d = words[3] if len(words) > 3 else b
    return a, b, c, d


def longhands(name, value):
    if name == "padding":
        return dict(zip(("padding-top", "padding-right", "padding-bottom", "padding-left"), four(value.split())))
    if name == "border-radius":
        return dict(zip(CORNERS, four(value.split())))
    if name == "gap":
        vals = value.split()
        if not 1 <= len(vals) <= 2:
            raise ValueError("gap takes one or two lengths")
        return {"row-gap": vals[0], "column-gap": vals[-1]}
    if name == "flex":
        keywords = {"none": ("0", "0", "auto"), "auto": ("1", "1", "auto"),
                    "initial": ("0", "1", "auto")}
        if value.lower() in keywords:
            grow, shrink, basis = keywords[value.lower()]
        else:
            words = value.split()
            if not 1 <= len(words) <= 3:
                raise ValueError("invalid flex shorthand")
            grow, shrink, basis = "1", "1", "0%"
            if COMPONENT.fullmatch(words[0]) and COMPONENT.fullmatch(words[0])[2] is None:
                grow = words.pop(0)
                if words and COMPONENT.fullmatch(words[0]) and COMPONENT.fullmatch(words[0])[2] is None:
                    shrink = words.pop(0)
            if words:
                basis = words.pop(0)
            if words:
                raise ValueError("unsupported flex shorthand")
        return {"flex-grow": grow, "flex-shrink": shrink, "flex-basis": basis}
    if name == "background":
        return {"background-color": value}
    if name == "border":
        # A functional color can contain whitespace.
        tokens = re.findall(r"[\w-]+\([^()]*\)|[^\s]+", value)
        width, style, tint = "3px", "none", "currentcolor"
        seen = set()
        for token in tokens:
            if token.lower() in ("solid", "none", "hidden"):
                typ, style = "style", token.lower()
            elif COMPONENT.fullmatch(token):
                typ, width = "width", token
            else:
                typ, tint = "color", token
            if typ in seen:
                raise ValueError(f"unsupported border shorthand {value!r}")
            seen.add(typ)
        return {"border-width": width, "border-style": style, "border-color": tint}
    return {name: value}


CORNERS = ("border-top-left-radius", "border-top-right-radius",
           "border-bottom-right-radius", "border-bottom-left-radius")


def affine(value, em, rem):
    if value == "none":
        return array(map(fmt, [1, 0, 0, 1, 0, 0]))
    a, b, c, d, e, f = 1, 0, 0, 1, 0, 0
    pos = 0
    while pos < len(value):
        match = re.compile(r"\s*([a-z]+)\(([^()]*)\)\s*", re.I).match(value, pos)
        if not match:
            raise ValueError("expected a sequence of 2D transform functions")
        name, raw = match[1].lower(), match[2].strip()
        args = [s.strip() for s in raw.split(",")] if "," in raw else raw.split()
        def angle(v):
            n, u = number(v, ("deg", "rad", "turn", "grad", ""))
            if not u and n:
                raise ValueError("a nonzero rotation requires an angle unit")
            return n * {"": 1, "rad": 1, "deg": math.pi/180, "turn": math.tau, "grad": math.pi/200}[u]
        p, q, r, s, x, y = 1, 0, 0, 1, 0, 0
        if name == "matrix" and len(args) == 6:
            p, q, r, s, x, y = [number(v)[0] for v in args]
        elif name in ("translate", "scale", "skew") and len(args) in (1, 2):
            if name == "translate":
                x = px(args[0], em, rem, True)
                y = px(args[1], em, rem, True) if len(args) == 2 else 0
            elif name == "scale":
                p, s = number(args[0])[0], number(args[-1])[0]
            else:
                r = math.tan(angle(args[0]))
                q = math.tan(angle(args[1])) if len(args) == 2 else 0
        elif name in ("translatex", "translatey", "scalex", "scaley", "skewx", "skewy", "rotate") and len(args) == 1:
            arg = args[0]
            if name == "translatex":
                x = px(arg, em, rem, True)
            elif name == "translatey":
                y = px(arg, em, rem, True)
            elif name == "scalex":
                p = number(arg)[0]
            elif name == "scaley":
                s = number(arg)[0]
            elif name == "skewx":
                r = math.tan(angle(arg))
            elif name == "skewy":
                q = math.tan(angle(arg))
            else:
                t = angle(arg)
                p, q, r, s = math.cos(t), math.sin(t), -math.sin(t), math.cos(t)
        else:
            raise ValueError(f"unsupported transform {name} or wrong number of arguments")
        a, b, c, d, e, f = a*p+c*q, b*p+d*q, a*r+c*s, b*r+d*s, a*x+c*y+e, b*x+d*y+f
        pos = match.end()
    return array(map(fmt, (a, b, c, d, e, f)))


# Validate source declarations even when their selectors match no elements or
# a later declaration supersedes them. Resolution of var() still belongs to
# the winning element. Custom property values themselves are opaque token lists.
QUOTED = r"""(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')"""
CSS_COMMENTS = re.compile(QUOTED + r"|/\*.*?\*/", re.S)
COLOR_FUNCTIONS = {"rgb", "rgba", "hsl", "hsla"}
TRANSFORMS = {"matrix", "rotate", "scale", "scalex", "scaley", "skew", "skewx", "skewy",
              "translate", "translatex", "translatey"}
KEYWORDS = {
    "box-sizing": ("border-box", "content-box"),
    "align-items": ("start", "end", "flex-start", "flex-end", "center", "stretch"),
    "align-self": ("auto", "stretch"),
    "justify-content": ("start", "end", "flex-start", "flex-end", "center"),
    "display": ("flex", "block"), "flex-direction": ("row", "column"),
    "flex-shrink": ("0", "1"), "overflow": ("hidden", "clip", "visible"),
    "position": ("static", "absolute", "relative"),
    "border-style": ("none", "hidden", "solid"),
    "white-space": ("normal", "nowrap"),
    "transform-origin": ("center", "center center", "50% 50%"),
}


def preflight(name, value):
    if not value:
        raise ValueError("empty property value")
    if name.startswith("--"):
        return
    shape = re.sub(QUOTED, '""', value)
    functions = {m[1].lower() for m in re.finditer(r"([-\w]+)\(", shape)}
    allowed = COLOR_FUNCTIONS if name in ("color", "background", "background-color", "border", "border-color") else set()
    if name == "transform":
        allowed = TRANSFORMS
    unsupported = functions - allowed - {"var"}
    if unsupported:
        raise ValueError(f"unsupported CSS function {min(unsupported)}()")
    if "var" in functions:
        list(var_parts(value))  # verify argument syntax without looking up missing variables
        if name in ("width", "height", "flex-basis", "flex", "font-size", "transform",
                    "top", "left", "gap", "row-gap", "column-gap") or name.startswith(("padding", "min-", "max-", "border")):
            units = {"px", "em", "rem", "pt", "pc", "in", "cm", "mm", "q"}
            if name in ("transform", "border", "border-color"):
                units.update(("deg", "rad", "turn", "grad"))
            for unit in re.finditer(rf"(?<![-\w#.]){NUMBER}([a-zA-Z]+)\b", shape):
                if unit[1].lower() not in units:
                    raise ValueError(f"unsupported CSS unit {unit[1]}")
        return
    if name in INHERITED and value.lower() in ("inherit", "unset"):
        return
    for key, raw in longhands(name, value).items():
        v = raw.lower()
        if key in KEYWORDS:
            one_of(v, KEYWORDS[key])
        elif key in ("color", "background-color", "border-color"):
            if v != "currentcolor":
                color(v)
        elif key in ("width", "height", "flex-basis"):
            if v not in ("auto", "fit-content"):
                if v.endswith("%"):
                    if number(v, ("%",))[0] < 0:
                        raise ValueError("negative dimension")
                else:
                    px(v, 14, 14)
        elif key in ("max-width", "max-height") and v == "none":
            continue
        elif key == "font-size" and v.endswith("%"):
            if number(v, ("%",))[0] < 0:
                raise ValueError("negative font size")
        elif key == "flex-grow":
            if number(v)[0] < 0:
                raise ValueError("negative grow weight")
        elif key == "opacity":
            alpha_value(v)
        elif key == "transform":
            affine(v, 14, 14)
        else:
            px(v, 14, 14, signed=key in ("left", "top"))


def lower(node, parent, rem, properties, initial_font=14):
    tag = node["tag"].lower()
    st = Computed(axis="x" if tag == "row" else "y", containing_block=parent is None, font_px=initial_font)
    if parent:
        st.text = parent.text.copy()
        st.font_px = parent.font_px
    props = {k: value for k, (value, _) in properties.items()}

    def checked(name, func):
        try:
            return func(props[name])
        except ValueError as err:
            properties[name][1].error(f"{name}: {err}")

    def length(v, signed=False):
        return fmt(px(v, st.font_px, rem, signed))

    if "font-size" in props:
        def font_size(value):
            if value.endswith("%"):
                n = number(value, ("%",))[0]
                if n < 0:
                    raise ValueError("negative font size")
                return st.font_px * n / 100
            return px(value, st.font_px, rem)
        st.font_px = checked("font-size", font_size)
        st.text["px"] = fmt(st.font_px)
    if parent is None:
        rem = st.font_px
    if "color" in props:
        if props["color"].lower() != "currentcolor":
            st.text["color"] = checked("color", color)
    if "white-space" in props:
        value = checked("white-space", lambda v: one_of(v, ["normal", "nowrap"]))
        st.text["wrap"] = "true" if value == "normal" else "false"

    def tint(value):
        if value.lower() == "currentcolor":
            return st.text.get("color", "theme.text")
        return color(value)

    if "display" in props:
        display = checked("display", lambda v: one_of(v, ["flex", "block"]))
        if tag in METADATA:
            properties["display"][1].error(f"display: {display} would render the nonvisual <{tag}> element")
        if display == "flex":
            st.flex = True
            st.axis = "x"
            st.fields["dir"] = ".x"
            st.stretch = True
        if tag in ("row", "col") and "flex-direction" not in props and st.axis != ("x" if tag == "row" else "y"):
            properties["display"][1].error(f"display direction contradicts <{tag}>")
    st.flex_container = st.flex or (tag in ("row", "col") and "display" not in props)
    if tag == "row" and props.get("display", "").lower() == "block":
        properties["display"][1].error("display: block contradicts the native row container")
    if not st.flex_container:
        for k in ("flex-direction", "justify-content", "align-items", "row-gap", "column-gap"):
            if k in props:
                properties[k][1].error(f"{k} requires display: flex on this native container")
    in_flow = props.get("position", "static").lower() != "absolute"
    flex_item = parent is not None and parent.flex_container and in_flow
    if not flex_item:
        for k in ("flex-grow", "flex-basis", "flex-shrink", "align-self"):
            if k in props:
                properties[k][1].error(f"{k} requires an in-flow child of a flex container")
    if "flex-direction" in props:
        v = checked("flex-direction", lambda v: one_of(v, ["row", "column"]))
        st.axis = "x" if v == "row" else "y"
        if tag in ("row", "col") and st.axis != ("x" if tag == "row" else "y"):
            properties["flex-direction"][1].error(f"flex-direction contradicts <{tag}>")
        st.fields["dir"] = "." + st.axis
    main = int(parent.axis == "y") if parent else 1
    cross = 1 - main
    # Native dimensions include the insets. CSS content-box sizes exclude both
    # padding and border. The native border is paint-only, so include it in
    # the layout padding for either box-sizing mode.
    border = 0.0
    if any(k in props for k in ("border-style", "border-width", "border-color")):
        if props.get("border-style", "none").lower() == "solid":
            border = float(checked("border-width", length)) if "border-width" in props else 3.0
            st.fields["border_color"] = checked("border-color", tint) if "border-color" in props else tint("currentcolor")
        st.fields["border"] = fmt(border)
    pads = ("padding-left", "padding-top", "padding-right", "padding-bottom")
    st.padding = tuple(float(checked(k, length)) if k in props else 0.0 for k in pads)
    insets = tuple(p + border for p in st.padding)
    if border or any(k in props for k in pads):
        st.fields["pad"] = array([fmt(v) for v in insets])
    totals = (insets[0] + insets[2], insets[1] + insets[3])
    content_box = props.get("box-sizing", "content-box").lower() == "content-box"

    def outer(value, dim):
        n = float(length(value))
        return fmt(n + totals[dim] if content_box else max(n, totals[dim]))

    def size(value, dim):
        if value.lower() in ("auto", "fit-content"):
            return ".fit"
        if value.endswith("%"):
            n = number(value, ("%",))[0]
            if n < 0:
                raise ValueError("negative dimension")
            if content_box and totals[dim]:
                raise ValueError("a percentage plus padding or border needs a dynamic additive size; use box-sizing: border-box")
            if not in_flow and parent and (parent.padding[dim] or parent.padding[dim + 2]):
                raise ValueError("absolute percentage size refers to the parent's padding box")
            return ".pct(" + fmt(n / 100) + ")"
        return ".px(" + outer(value, dim) + ")"

    for i, key in enumerate(("width", "height")):
        if key in props:
            st.sizes[i] = checked(key, lambda v: size(v, i))
    for axis in ("min", "max"):
        pair = ["0" if axis == "min" else "lcgf.types.inf"] * 2
        present = False
        for i, dim in enumerate(("width", "height")):
            key = f"{axis}-{dim}"
            if key in props:
                present = True
                pair[i] = checked(key, lambda v: "lcgf.types.inf" if v.lower() == "none" and axis == "max" else outer(v, i))
            elif axis == "min" and totals[i] and (st.sizes[i] or "").startswith(".pct("):
                present = True
                pair[i] = fmt(totals[i])
        if present:
            st.fields[axis] = array(pair)
    grow = checked("flex-grow", lambda v: number(v)[0]) if "flex-grow" in props else 0
    basis = props.get("flex-basis", "").lower()
    if grow < 0:
        properties["flex-grow"][1].error("flex-grow requires a nonnegative weight")
    if grow:
        intrinsic = any(c.get("kind") == "element" or c.get("text", "").strip() for c in node.get("children", []))
        if totals[main]:
            properties["flex-grow"][1].error("native grow weights cannot reserve an additive padding or border size")
        if basis not in ("0", "0%", "0px") and (intrinsic or basis or st.sizes[main] is not None):
            properties["flex-grow"][1].error("native grow with a fixed or content-based main-axis basis is not representable")
        st.sizes[main] = ".grow(" + fmt(grow) + ")"
    elif basis and basis != "auto":
        st.sizes[main] = checked("flex-basis", lambda v: size(v, main))
    if flex_item:
        if st.sizes[main] is None:
            st.sizes[main] = ".fit"
        st.fields["shrink"] = "true"
    if "flex-shrink" in props:
        value = checked("flex-shrink", lambda v: one_of(v, ["0", "1"]))
        st.fields["shrink"] = "true" if value == "1" else "false"
    if "align-self" in props:
        self_align = checked("align-self", lambda v: one_of(v, ["stretch", "auto"]))
    else:
        self_align = "auto"
    if flex_item and (self_align == "stretch" or (parent.stretch and self_align == "auto")):
        if props.get(("width", "height")[cross], "auto").lower() == "auto":
            st.sizes[cross] = ".fill"
    for name, field_name in (("align-items", "cross"), ("justify-content", "main")):
        if name in props:
            choices = ["start", "end", "flex-start", "flex-end", "center"]
            if name == "align-items":
                choices.append("stretch")
            v = checked(name, lambda v: one_of(v, choices))
            if v == "stretch":
                st.stretch = True
            else:
                if name == "align-items":
                    st.stretch = False
                st.fields[field_name] = "." + v.removeprefix("flex-")
    gaps = {k: checked(k, length) for k in ("row-gap", "column-gap") if k in props}
    if gaps:
        # Single-line native layout has one gap along the main axis.
        st.fields["gap"] = gaps.get("column-gap" if st.axis == "x" else "row-gap", "0")
    if "overflow" in props:
        v = checked("overflow", lambda v: one_of(v, ["hidden", "clip", "visible"]))
        st.fields["clip"] = "false" if v == "visible" else "true"
    position = props.get("position", "static").lower()
    if position != "static":
        st.containing_block = True
    if "position" in props:
        st.fields["float"] = "true" if position == "absolute" else "false"
    if position == "absolute":
        if parent and not parent.containing_block:
            properties["position"][1].error("absolute layout needs the immediate native parent to establish its containing block")
        if "left" not in props or "top" not in props:
            properties["position"][1].error("absolute layout requires explicit left and top; automatic static-position offsets are unavailable")
        offsets = [float(checked(k, lambda v: length(v, True))) for k in ("left", "top")]
        if parent:
            offsets = [x - p for x, p in zip(offsets, parent.padding)]
        st.fields["offset"] = array([fmt(x) for x in offsets])
    elif "left" in props or "top" in props:
        key = "left" if "left" in props else "top"
        properties[key][1].error("native in-flow layout cannot apply CSS positioning offsets")
    if "background-color" in props:
        if tag in CONTROLS:
            properties["background-color"][1].error(f"<{tag}> draws its interactive background from the widget theme")
        st.fields["fill"] = checked("background-color", tint)
    if "opacity" in props:
        st.fields["opacity"] = checked("opacity", lambda v: fmt(alpha_value(v)))
        has_contents = any(c.get("kind") == "element" or c.get("text", "").strip() for c in node.get("children", []))
        if 0 < float(st.fields["opacity"]) < 1 and (any(c.get("kind") == "element" for c in node.get("children", []))
                                                      or has_contents and ("fill" in st.fields or border)):
            properties["opacity"][1].error("overlapping content needs group opacity compositing")
    if any(k in props for k in CORNERS):
        radii = [checked(k, length) if k in props else "0" for k in CORNERS]
        if len(set(radii)) == 1:
            st.fields["radius"] = radii[0]
        else:
            st.fields["radii"] = array(radii)
    if "transform" in props:
        st.fields["transform"] = checked("transform", lambda v: affine(v, st.font_px, rem))
        if props["transform"].lower() != "none":
            st.containing_block = True
    if "transform-origin" in props:
        checked("transform-origin", lambda v: one_of(v, ["center", "center center", "50% 50%"]))
    return st


def compute_styles(root, stylesheets, parse_css, *, html_path="<html>", html_source="", parse_declarations=None):
    """Cascade author rules, inline styles, custom properties and inherited text.

    stylesheets must already be in document order. Each pair contains path and
    CSS source. A third item gives the byte offset of an embedded sheet within
    html_source. A stylesheet with an unsupported feature is a build error.
    """
    rules = []
    sequence = 0

    def diagnostics(result, at):
        for diag in result.get("diagnostics", []):
            # A recovery can discard or reinterpret a declaration. Require an
            # unambiguous stylesheet before emitting native code.
            at(diag.get("offset")).error(diag["message"])

    def declarations(rows, at):
        nonlocal sequence
        result = []
        for decl in rows:
            name = decl["name"]
            if not name.startswith("--"):
                name = name.lower()
            loc = at(decl.get("offset"))
            if not CUSTOM.fullmatch(name) and name not in PROPERTY_TARGETS:
                loc.error(f"unsupported CSS property {name!r} in native LCGF layout")
            value = CSS_COMMENTS.sub(lambda m: " " if m[0].startswith("/*") else m[0], decl["value"]).strip()
            try:
                preflight(name, value)
            except ValueError as err:
                loc.error(f"{name}: {err}")
            sequence += 1
            result.append((name, value, bool(decl.get("important")), sequence, loc))
        return result

    for sheet in stylesheets:
        path, css, *base = sheet
        def at(offset):
            return Location(str(path), html_source if base else css, (base[0] if base else 0) + (offset or 0))
        parsed = parse_css(css)
        diagnostics(parsed, at)
        for rule in parsed["rules"]:
            loc = at(rule.get("offset"))
            if not rule.get("selector"):
                loc.error("unsupported at-rule or malformed qualified CSS rule")
            selectors = selector_list(rule["selector"], loc)
            rules.append((selectors, declarations(rule["declarations"], at)))

    styles = {}
    def walk(node, ancestry, parent, root_font):
        if node.get("kind", "element") != "element":
            return
        ancestry = ancestry + [node]
        candidates = []
        for selectors, decls in rules:
            weights = [selector[2] for selector in selectors if matches(selector, ancestry)]
            if weights:
                weight = max(weights)
                candidates.extend(((important, 0, weight, order), name, value, loc)
                                  for name, value, important, order, loc in decls)

        inline = attributes(node).get("style")
        if inline is not None:
            attrs = node.get("attrs", [])
            attr = {} if isinstance(attrs, dict) else next(a for a in attrs if a["name"] == "style")
            start = attr.get("value_offset")
            inline_path = node.get("file", html_path)
            # Entity expansion changes byte offsets. An offset inside that value
            # must then point to the attribute rather than an unrelated source byte.
            exact = (start is not None and html_source.encode()[start:start + len(inline.encode())] == inline.encode())
            prefix = "" if parse_declarations else "*{"
            if parse_declarations:
                parsed = parse_declarations(inline)
            else:
                parsed = parse_css(prefix + inline + "}")
            def at_inline(offset):
                if not html_source:
                    return Location(str(inline_path), inline, max(0, (offset or 0) - len(prefix)))
                pos = start + max(0, (offset or 0) - len(prefix)) if exact else attr.get("offset") or node.get("offset") or 0
                return Location(str(inline_path), html_source, pos)
            diagnostics(parsed, at_inline)
            if parse_declarations:
                rows = parsed["declarations"]
            else:
                found = parsed["rules"]
                if len(found) != 1 or found[0]["selector"].strip() != "*":
                    at_inline(0).error("inline style requires a declaration list")
                rows = found[0]["declarations"]
            for name, value, important, order, loc in declarations(rows, at_inline):
                candidates.append(((important, 1, (0, 0, 0), order), name, value, loc))

        candidates.sort(key=lambda decl: decl[0])
        local = {name: value for _, name, value, _ in candidates if name.startswith("--")}
        try:
            variables = custom_properties(parent.variables if parent else {}, local)
        except ValueError as err:
            next(loc for _, name, _, loc in candidates if name in local).error(str(err))

        # A var() in a shorthand is resolved only after that shorthand wins
        # each individual longhand. Losing declarations may reference missing
        # variables without invalidating the winner.
        shorthand_keys = {
            "border-radius": CORNERS, "background": ("background-color",),
            "border": ("border-width", "border-style", "border-color"),
            "padding": ("padding-top", "padding-right", "padding-bottom", "padding-left"),
            "gap": ("row-gap", "column-gap"), "flex": ("flex-grow", "flex-shrink", "flex-basis"),
        }
        winners = {}
        for _, name, value, loc in candidates:
            if not name.startswith("--"):
                for key in shorthand_keys.get(name, (name,)):
                    winners[key] = name, value, loc
        props = {}
        for key, (name, raw, loc) in winners.items():
            try:
                value = expand_vars(raw, variables.get)
                if raw != value:
                    preflight(name, value)
                if value.lower() in ("inherit", "unset") and key in INHERITED:
                    continue
                val = longhands(name, value)[key]
                if not val:
                    raise ValueError("empty property value")
                props[key] = val, loc
            except ValueError as err:
                loc.error(f"{name}: {err}")
        initial_font = root_font
        if parent is None and "--text-px" in local:
            location = next(loc for _, name, _, loc in reversed(candidates) if name == "--text-px")
            try:
                initial_font = px(variables.get("--text-px") or "", root_font, root_font)
            except ValueError as err:
                location.error(f"--text-px: {err}")
        computed = lower(node, parent, root_font, props, initial_font)
        computed.variables = variables

        # The reserved root tokens are explicit native theme overrides. An
        # ordinary custom property remains an inherited CSS variable.
        if not parent:
            theme_tokens = {
                "--text": ("text", color), "--text-px": ("text_px", None),
                "--panel": ("panel", color), "--control": ("control", color),
                "--control-hot": ("control_hot", color), "--control-held": ("control_held", color),
                "--accent": ("accent", color), "--radius": ("radius", None),
                "--pad": ("pad", None), "--gap": ("gap", None),
            }
            for _, name, _, loc in candidates:
                if name not in theme_tokens:
                    continue
                field_name, convert = theme_tokens[name]
                try:
                    val = variables[name]
                    if val is None:
                        raise ValueError("unresolved theme token")
                    if field_name == "text_px":
                        computed.theme[field_name] = fmt(initial_font)
                    else:
                        computed.theme[field_name] = convert(val) if convert else fmt(px(val, computed.font_px, root_font))
                except ValueError as err:
                    loc.error(f"{name}: {err}")
            if "text" in computed.theme:
                computed.text.setdefault("color", computed.theme["text"])
            if "text_px" in computed.theme and "px" not in computed.text:
                computed.font_px = float(computed.theme["text_px"])
                computed.text["px"] = computed.theme["text_px"]
            root_font = computed.font_px

        styles[id(node)] = computed
        for child in node.get("children", []):
            walk(child, ancestry, computed, root_font)
    walk(root, [], None, 14)
    return styles
