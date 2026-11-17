# HTML + CSS parser choice for a `zig build` build-time tool

Research for docs/plans/markup.md, section 4. The probe program and its inputs are in
`lexbor-probe/` next to this file; downloads went to a scratch directory outside the repository.

Date: 2026-11-16. Zig used for the probe: `0.18.0-dev.1151+8dfb7a7cc` (from the repository's `nix develop`);
the system zig 0.16.0 gave identical output.

Hard rule applied: pinnable in `build.zig.zon` (URL + hash) and buildable by `zig build` alone.
Rust (needs cargo) and anything that needs cmake/meson/perl codegen at build time are ruled out or penalised.

## Recommendation

- **HTML: lexbor v3.0.1, *tokenizer only* (`lxb_html_tokenizer_*`), with our own tree builder on top.**
  Do not use lexbor's (or any) HTML5 *tree construction*. It runs the WHATWG insertion modes, and those
  silently delete our `<col>` root (see probe). The tokenizer keeps every tag, every attribute
  (`on:click` included) and the `{...}` text, and gives a source pointer for every token and attribute name.
- **CSS: lexbor v3.0.1 CSS module** (same tarball, same `build.zig`). It does CSS Syntax 3 tokenizing,
  and the stylesheet parse returns rules, selector lists and declarations with byte offsets for the
  prelude, name and value. Unknown properties (`gap`, `background`) are kept as `_custom` declarations
  with their raw value, not dropped.
- Reasons: one Apache-2.0 C99 dependency with no generated headers and no system libs. It compiled
  first time under `zig cc` (0.16 and 0.18-dev). It is actively maintained (v3.0.0 released 2026-03-31,
  pushed 2026-11-15). Positions come from tokens, so errors map back to markup lines. Since it is C, the
  churn in Zig's language each dev cycle doesn't touch it, which matters on 0.18-dev (see superhtml below).
- Fallback if Zig-native is preferred later: superhtml (MIT; HTML+CSS; spans on every node; has an `xml`
  mode that skips HTML content models). Today v0.7.1 **does not compile on 0.18-dev** (probe below).

Pin, verified with `zig fetch` on 0.18.0-dev.1151 (a harmless `failed to delete temporary directory` warning was printed):

```zig
.lexbor = .{
    .url = "https://github.com/lexbor/lexbor/archive/refs/tags/v3.0.1.tar.gz",
    .hash = "N-V-__8AABbVvAJ6W3IAOXu1CuKXDihBIiJuvDPd8NDcYyWf",
},
```

## Candidate table

| Candidate | Lang / licence | Size | Maintenance | Spec | Source positions | `zig build` effort |
|---|---|---|---|---|---|---|
| **lexbor** v3.0.1 | C99 / Apache-2.0 [1] | tarball 5.5 MB; whole tree 644k lines `.c+.h` (mostly encoding/unicode tables); the subset needed for HTML+CSS is 190 `.c` files, 62.8k lines (HTML side 37.2k, CSS+selectors 25.6k) [probe] | v3.0.0 2026-03-31, tag v3.0.1, pushed 2026-11-15, 2.1k stars [2] | HTML5 "Passes all tree construction tests"; "Full conformance with CSS Syntax"; Selectors; CSSOM [3] | HTML token `begin/end` pointers into the input; attr `name_begin/value_begin`; tree errors carry `begin/end` [4]. DOM nodes have **no** position field, but `node->user` plus the 3.0 `mutation.inserted` hook stamp one (probe). CSS tokens have `offset`; CSSOM style rules have `prelude_begin/end`; declarations have `offset.{name,value,important}_{begin,end}` [5] | Easy. No generated headers (the only `configure_file` is `lexbor.pc` [6]). Needs `-DLEXBOR_STATIC`, `-I source`, and the `ports/posix` (or `ports/windows_nt`) `.c` files. No allyourcodebase port; third-party Zig wrappers exist (`carlos-sweb/z-lexbor`, Zig 0.16; `Wikidepia/lexbor-zig`, lexbor 2.4) [7]. One gotcha: duplicate basenames (`error.c`) in one `zig cc` command gave `CacheCheckFailed`. Compile each file separately (`addCSourceFiles` does that) |
| libxml2 2.15.4 | C / MIT [8] | large (repo 34 MB) | active, tag v2.15.4 [2] | 2.14: "HTML tokenizer now conforms fully to HTML5 … HTML5 tree construction isn't implemented yet" [9]. No CSS | `xmlNode.line` is `unsigned short` (line only, no column, caps at 65535) [10] | allyourcodebase/libxml2 exists (min zig 0.16.0), but it needs `addConfigHeader` for `config.h` and `xmlversion.h`, plus lazy zlib/iconv deps [11] |
| google/gumbo-parser | C99 / Apache-2.0 | ~1 MB src | **archived**, last release v0.10.1 (2015) [2] | HTML5 tree construction. No CSS | best in class: `GumboSourcePosition {line,column,offset}` on text, element start/end and every attribute name/value [12] | Plain C, but archived |
| codeberg gumbo-parser fork | C99 / Apache-2.0 | `src/` ≈1.0 MB [13] | 0.14.1 on 2026-09-27, active [13] | "Full compliance with the HTML5 spec", WPT tree-construction tests [14] | same as gumbo [12] | Upstream build is meson/autotools [14]. Sources are committed (`tag.in` is gperf input with generated output checked in), so a hand `build.zig` is easy. No allyourcodebase port [7]. HTML only, and its HTML5 tree construction has the same `<col>` problem |
| NetSurf libhubbub 0.3.8 + libparserutils | C / MIT [2] | small | pushed 2026-11, tiny community | "aims to comply with the HTML5 specification" [15] | none found in public `tree.h` | Make-based build. Needs libparserutils (+ iconv) [15] |
| NetSurf libcss 0.9.2 (+ libwapcaplet, libparserutils) | C / MIT [2] | repo 8 MB | active | CSS 2.1 + parts of CSS3, built to *select/cascade* for NetSurf | no public per-rule offsets | Hard: property parsers are generated at build time by `gen_parser` from `properties.gen` (Makefile + perl) [16]. Would need a host-exe codegen step in `build.zig` |
| katana-parser | C / MIT | repo 0.5 MB | **archived**, last push 2021-03 [2] | "Fully conformant with the CSS-syntax" (claim, 2016-era) [17] | line/column only on `KatanaError`, not on rules [17] | Easy C, but dead |
| html5ever | Rust / MIT+Apache [2] | — | active (html5ever-v0.35.0) | HTML5 | — | **Excluded**: needs cargo |
| lightningcss | Rust / MPL-2.0 [2] | — | active, v1.33.0 2026-07-20 | CSS | has locations | **Excluded**: cargo |
| servo/rust-cssparser, Stylo | Rust / MPL-2.0 [2] | — | active, tag v0.38.0 | CSS Syntax 3 | has `SourceLocation` | **Excluded**: cargo |
| superhtml v0.7.1 (kristoff-it) | Zig / MIT [2] | `src/html/Tokenizer.zig` 252 KB, `Ast.zig` 90 KB, `src/css/` 48 KB [18] | active, pushed 2026-10-30, 1.4k stars | HTML5 tokenizer + validator. Modes `html`, `superhtml`, `xml` [19]. Small CSS tokenizer + AST (style + `@media` rules, selectors, declarations) [20] | every AST node has `open: Loc`, `close: Loc` byte spans [19] | `minimum_zig_version = "0.17.0"`; deps tracy, scripty, lsp-kit, known-folders [21]. **Fails on 0.18-dev** (probe) |
| chadwain/rem 0.3.0 | Zig / **GPL-3.0** [2] | repo 1.1 MB | last push 2026-01 | tokenizer complete, tree constructor "works well enough", html5lib tests [22] | — | min zig 0.15.1. GPL rules it out for most uses |
| chadwain/zss | Zig / CC0 [23] | — | last push 2025-12 | CSS Syntax 3 "Partial", Selectors 3 "Partial"; it's a layout engine [23] | — | Zig 0.15.2 pinned [23] |
| others (OrlovEvgeny/zigquery, SmallThingz/zhtml, baskingspot/html, watzon/zhtml, terence-css, …) | Zig | — | 0–20 stars | unknown/partial | — | Not mature enough to rely on [7] |

## Probe

Layout (each download in its own empty directory):
- `probe/lexbor-src/` holds the lexbor tarball + extracted tree (untrusted data)
- `probe/prog/` holds `probe.c`, `sample.html`, `sample.css` (committed in `lexbor-probe/` next to this file), `srcs.txt`, `obj/`, `out.txt`
- `probe/superhtml-src/` holds the superhtml v0.7.1 tarball

### Commands

```sh
P=$(mktemp -d)   # any empty scratch directory
cd $P/lexbor-src && curl -sL -o lexbor.tar.gz https://github.com/lexbor/lexbor/archive/refs/tags/v3.0.1.tar.gz && tar xzf lexbor.tar.gz
# sha256 08ce3d18efdd09b8b3488779b97509f83cc181e09a5a4cd8162ac08d77266600, 5.5 MB
L=$P/lexbor-src/lexbor-3.0.1/source
cd $P/prog
find $L/lexbor/{core,dom,html,css,tag,ns,selectors,ports/posix} -name '*.c' > srcs.txt   # 190 files
# one command with all files fails: "error.c: error: CacheCheckFailed" (3 files named error.c). Per-file works:
cat srcs.txt | xargs -P8 -I{} sh -c 'o=obj/$(echo "{}" | sed "s|.*/source/||; s|/|_|g").o; \
  zig cc -std=c99 -O2 -DLEXBOR_STATIC -D_POSIX_C_SOURCE=199309L -I'$L' -c "{}" -o $o'
#   -> 0 errors, ~6-7.6 s wall at -P8 (35 s CPU)
zig cc -O2 -DLEXBOR_STATIC -I$L probe.c obj/*.o -o probe     # 3.8 MB binary
./probe sample.html sample.css
# same with Zig 0.18.0-dev.1151+8dfb7a7cc via `nix develop -c`: 0 errors, output byte-identical
```

The only C flags needed are `-DLEXBOR_STATIC -D_POSIX_C_SOURCE=199309L` (from `ports/posix/config.cmake`) and `-I source`.
A `build.zig` is therefore one `addCSourceFiles` over a file list (or a `walk` of those dirs) plus `addIncludePath`.

Position hooks used in `probe.c` (public API only, no lexbor patches):
1. After `lxb_html_document_parse_chunk_begin`, wrap `tkz->callback_token_done` so it records `token->begin - input` before calling lexbor's tree callback.
2. Copy `document->mutation` and set `.inserted = on_inserted`, which writes `cur_offset+1` into `node->user` when it is still empty.
   (Wrapping `document->create_interface` does **not** work: the HTML tree builder calls `lxb_html_interface_create` directly, `html/tree.h:273`.)

### Output (the probe run; `~` = newline; `@line:col`, col points at the tag name just after `<`)

```
== HTML tree (document parse) ==
<html>   @1:2
  <head>   @1:2
  <body>   @1:2
    #text "~  "   @1:22
    <label>   @2:4
      #text "{count}"   @2:10
    #text "~  "   @2:25
    <row>   @3:4
      <button> on:click="counter.dec"   @3:9
        #text "-"   @3:39
      <button> on:click="counter.inc"   @3:50
        #text "+"   @3:80
    #text "~  {#each items as item max=16}"   @3:96
    <label>   @4:32
      #text "{item.name}"   @4:38
    #text "{/each}~~"   @4:57

== HTML tree errors ==
tree parse errors: 3
  @1:2 unexpected token in initial mode
  @1:2 unexpected token
  @5:3 unexpected closed token

== HTML tokenizer only ==
@1:2 <col> pad="8"@1:6 gap="4"@1:14
@1:22 TEXT "~  "
@2:4 <label>
@2:10 TEXT "{count}"
@2:19 </label>
@2:25 TEXT "~  "
@3:4 <row>
@3:9 <button> on:click="counter.dec"@3:16
@3:39 TEXT "-"
@3:42 </button>
@3:50 <button> on:click="counter.inc"@3:57
@3:80 TEXT "+"
@3:83 </button>
@3:92 </row>
@3:96 TEXT "~  {#each items as item max=16}"
@4:32 <label>
@4:38 TEXT "{item.name}"
@4:51 </label>
@4:57 TEXT "{/each}~"
@5:3 </col>
@5:7 TEXT "~"
EOF

== CSS stylesheet (lxb_css_stylesheet_parse + serialize) ==
status=0
.toolbar {gap: 4px; padding: 8px; background: var(--surface)}
button:hover {color: red}
-- per rule --
selector @1:1 [prelude 0..9]: .toolbar
  decl @1:12 [name 11..14 value 16..19] type=1: gap: 4px
  decl @1:22 [name 21..28 value 30..33] type=69: padding: 8px
  decl @1:36 [name 35..45 value 47..61] type=1: background: var(--surface)
selector @2:1 [prelude 65..78]: button:hover
  decl @2:16 [name 80..85 value 87..90] type=21: color: red

== CSS raw tokens with offsets ==
[delim off=0] .
[ident off=1] toolbar
[left-curly-bracket off=9] {
[ident off=11] gap
... (full list in out.txt) ...
[right-curly-bracket off=92] }
```

### What happened to the markup

- **`<col>` is deleted by HTML5 tree construction.** In "in body" mode a `col` start tag is a parse error
  and is ignored, and its `</col>` is an "unexpected closed token". Implied `<html><head><body>` are inserted.
  Any spec-compliant tree builder will do this (gumbo, html5ever, lexbor alike), and likewise for
  `tr/td/th/tbody/thead/tfoot/caption/colgroup/frame/head/html/body/template/table`-style names, plus
  auto-closing rules for `p`, `li`, `option`, … So no compliant HTML5 *tree builder* can parse this DSL as-is.
- **Tokenizer-only keeps everything.** `<col>`, `<row>`, `<label>` and their closing tags all come through,
  with tag-name positions. Unknown names get dynamic tag ids, and `lxb_tag_name_by_id` returns the name.
- **`on:click`**: an ordinary attribute name in HTML (no namespace processing), value intact, name position available.
- **`{count}`, `{item.name}`**: plain text tokens, untouched.
- **`{#each items as item max=16}` / `{/each}`**: plain text, merged with the surrounding whitespace into
  one text token (`"~  {#each items as item max=16}"`, `"{/each}~"`). The tool must scan text tokens for `{…}`
  itself and add the token's start offset to positions inside it. Characters inside `{}` such as `<` would
  break tokenizing, so the DSL should forbid `<` in expressions or escape it.
- Entities in text are decoded by the tree builder, not the tokenizer (`TEXT` tokens are raw `begin..end`).
  Attribute values *are* decoded (`attr->value`) and the raw span is also available (`value_begin..value_end`).
- **CSS**: `gap` and `background` aren't in lexbor's property table, so they parse as `_custom` (type 1)
  with the raw value kept. `padding`/`color` parse into typed structs. `var(--surface)` is preserved.
  Selectors (`.toolbar`, `button:hover`) parse into selector lists. All offsets are byte offsets into the input.

### superhtml on Zig 0.18-dev

```sh
mkdir -p $P/superhtml-src && cd $P/superhtml-src && curl -sL -o s.tgz https://github.com/kristoff-it/superhtml/archive/refs/tags/v0.7.1.tar.gz && tar xzf s.tgz
nix develop -c sh -c "cd $P/superhtml-src/superhtml-0.7.1 && zig build"
src/html/Element.zig:130:19: error: expected 'bitpack', found 'packed'
src/html/named_character_references.zig:65:18: error: expected 'bitpack', found 'packed'
zig-pkg/known_folders-…/known-folders.zig:250:15: error: ambiguous operator precedence with operators ... catch ... orelse ...
```

## Sources

1. lexbor LICENSE (Apache 2.0): `probe/lexbor-src/lexbor-3.0.1/LICENSE`; https://github.com/lexbor/lexbor
2. GitHub REST API repo/releases/tags metadata (licence SPDX, pushed_at, archived, size, stars), queried 2026-11-16: `https://api.github.com/repos/{lexbor/lexbor, GNOME/libxml2, google/gumbo-parser, hackers-painters/katana-parser, servo/html5ever, parcel-bundler/lightningcss, servo/rust-cssparser, kristoff-it/superhtml, chadwain/rem, chadwain/zss, netsurf-browser/libcss, netsurf-browser/libhubbub}`
3. https://raw.githubusercontent.com/lexbor/lexbor/v3.0.1/README.md ; `probe/lexbor-src/lexbor-3.0.1/CHANGELOG.md` (3.0.0 entry: mutation tables, `LXB_DOM_DOCUMENT_OPT_WO_EVENTS`)
4. `source/lexbor/html/token.h` (`lxb_html_token_t.begin/end`), `source/lexbor/html/token_attr.h` (`name_begin`, `value_begin`), `source/lexbor/html/tree/error.h:110` (`lxb_html_tree_error_t{id,begin,end}`), `source/lexbor/dom/interfaces/node.h` (`struct lxb_dom_node`: no position, `void *user`), `source/lexbor/dom/interfaces/document.h:46` (mutation callbacks)
5. `source/lexbor/css/syntax/token.h:203` (`uintptr_t offset`), `source/lexbor/css/rule.h:60-125` (`prelude_begin/end`, `lxb_css_rule_declaration_offset_t`)
6. `probe/lexbor-src/lexbor-3.0.1/CMakeLists.txt:428` (only `configure_file` is `lexbor.pc`); `source/lexbor/ports/posix/config.cmake`; `source/lexbor/core/def.h:35` (`LEXBOR_STATIC`)
7. https://api.github.com/orgs/allyourcodebase/repos (relevant: `libxml2`, `libexpat`; no lexbor/gumbo); https://api.github.com/search/repositories?q=lexbor+zig ; `q=html+parser+language:zig` ; `q=css+parser+language:zig`
8. https://gitlab.gnome.org/GNOME/libxml2 (Copyright file, MIT)
9. https://gitlab.gnome.org/GNOME/libxml2/-/raw/master/NEWS (v2.14.0 entry, lines ~200-204)
10. https://gitlab.gnome.org/GNOME/libxml2/-/raw/master/include/libxml/tree.h (`unsigned short line;`)
11. https://raw.githubusercontent.com/allyourcodebase/libxml2/master/build.zig.zon and `/build.zig` lines 82, 118 (`addConfigHeader` for `xmlversion.h.in`, `config.h.cmake.in`)
12. https://raw.githubusercontent.com/google/gumbo-parser/master/src/gumbo.h lines 67-71, 264-277, 465, 500
13. https://codeberg.org/api/v1/repos/gumbo-parser/gumbo-parser (+ `/releases`, `/contents/src?ref=0.14.1`)
14. https://codeberg.org/gumbo-parser/gumbo-parser/raw/branch/master/README.md (HTML5 compliance, meson build)
15. https://raw.githubusercontent.com/netsurf-browser/libhubbub/master/README
16. https://raw.githubusercontent.com/netsurf-browser/libcss/master/Makefile and `/src/parse/properties/Makefile` (`gen_parser`, `properties.gen`, `autogenerated_*.c`)
17. https://raw.githubusercontent.com/hackers-painters/katana-parser/master/README.md ; `/src/katana.h:454-462`
18. https://api.github.com/repos/kristoff-it/superhtml/contents/src/html , `/src/css`
19. https://raw.githubusercontent.com/kristoff-it/superhtml/main/src/html/Ast.zig (`Node.open: Loc`, `close: Loc`, `language == .xml` branches) ; `/src/root.zig:75` (`Language = enum { html, superhtml, xml }`)
20. https://raw.githubusercontent.com/kristoff-it/superhtml/main/src/css/Ast.zig
21. https://raw.githubusercontent.com/kristoff-it/superhtml/main/build.zig.zon
22. https://raw.githubusercontent.com/chadwain/rem/master/README.md , `/build.zig.zon`
23. https://raw.githubusercontent.com/chadwain/zss/master/LICENSE.md , `/README.md`, `/build.zig.zon`

Not verified: libxml2's HTML parser behaviour on this sample (not probed); html5ever/lightningcss internals (excluded on the cargo rule).

## Raw text in style blocks

The tokenizer-only token callback in the probe selects the HTML RAWTEXT state on the
opening style tag through `lxb_html_tokenizer_set_state_by_tag`. With lexbor 3.0.1, the
fragment below produced one text token between the style tags and a separate column token
afterwards. Compare the text with the input to check that the tag-looking comment and entity
spelling both survive unchanged.

```html
<ui><style>/* <row> &amp; */ .bar { gap: 4px }</style><col/></ui>
```
