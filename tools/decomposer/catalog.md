# Decomposer feature inventory

The offline catalog retains definitions and their links from the HTML element and attribute indices and the Webref CSS index. Each row in the report describes a particular definition. HTML attributes have one row per applicable element or global scope. CSS descriptors have their owning at-rule in their name. Same-named CSS functions defined by different specifications retain separate rows.

| Input | Source | SHA-256 of uncompressed bytes |
| --- | --- | --- |
| WHATWG HTML Living Standard, dated 17 November 2026 | [Indices](https://html.spec.whatwg.org/multipage/indices.html), [WHATWG attribution and copyright](https://html.spec.whatwg.org/multipage/acknowledgements.html#ipr) | `547826cea6e54951df190b66ecf6d4f6967e4f5c813c14d0ba8f7305c6e0c08c` |
| W3C Webref, `@webref/css` version 8.7.9, `package/css.json` | [Published package](https://registry.npmjs.org/@webref/css/-/css-8.7.9.tgz), [Webref project](https://github.com/w3c/webref) | `c4bba754fcb99891e256861fdd2bff0b5cb321d198162db43df5bc6fe05ad565` |

The compressed sources in `snapshots/` preserve these exact inputs as upstream indices evolve. Copyright, attribution, and license notices accompany the archived inputs. [Snapshot notices](snapshots/NOTICES.md) Regenerate or verify from the repository root using Python's standard library.

```sh
python3 tools/decomposer/update_catalog.py --check
python3 tools/decomposer/update_catalog.py > tools/decomposer/catalog.tsv
python3 -m unittest discover -s tools/decomposer -p test_catalog.py
```

To refresh the inputs, download the dated HTML index and a versioned Webref npm tarball. The following commands show the extraction and deterministic compression for the versions above.

```sh
curl -fLsS https://html.spec.whatwg.org/multipage/indices.html -o /tmp/whatwg-indices.html
curl -fLsS https://registry.npmjs.org/@webref/css/-/css-8.7.9.tgz -o /tmp/webref-css.tgz
tar -xOzf /tmp/webref-css.tgz package/css.json > /tmp/webref-css.json
sha256sum /tmp/whatwg-indices.html /tmp/webref-css.json
gzip -9nc /tmp/whatwg-indices.html > tools/decomposer/snapshots/whatwg-2026-11-17.html.gz
gzip -9nc /tmp/webref-css.json > tools/decomposer/snapshots/webref-css-8.7.9.json.gz
```

For a new standard revision, use its actual publication date/version in the destination filename. The live WHATWG URL serves the latest revision; the archived input is the reproducible source for the listed date. Replace the affected filename and uncompressed SHA-256 in `update_catalog.py`. Regenerate the TSV, review added and removed definitions, and update the explicit roadmap entries, snapshot counts and provenance. Passing paths to the raw HTML and JSON files in that order runs the same digest and generation checks.

**Mapped subset** identifies a native lowering for the documented inputs. A CSS property can support selected values and units. A global HTML attribute applies only on elements the compiler can lower. **Parser only** identifies lexical tokens recognized by the stylesheet parser. **Gap** identifies the concrete subsystem work needed for a given definition. A gap on an HTML event attribute includes its scripting model. Typed Zig event writers are a separate authoring extension.

The HTML snapshot indexes conforming HTML features, including its foreign roots and custom-element category. The index omits external vocabularies such as ARIA and the contents of SVG or MathML documents. The CSS snapshot includes draft definitions. The inventory reports implementation coverage independently of a browser's implementation status.
