# Decomposer parser protocol

`decomposer-parse html|widgets|css|declarations [FILE|-]` reads a UTF-8
source file or standard input and emits one JSON object to standard output.
The process reads one source per invocation. A UTF-8 BOM is accepted.
Byte offsets below are zero-based offsets in the original input, including
any BOM. A missing location is JSON `null`. Invalid UTF-8, I/O failures and
initialization failures produce a diagnostic on standard error and a nonzero
exit code. For parse and unsupported-syntax diagnostics, inspect the
`diagnostics` array in the successful JSON result.

## HTML documents

`html` invokes Lexbor’s HTML5 tree builder. It applies the HTML insertion
modes, implied elements, HTML void rules, namespace transitions, template
contents and character-reference decoding. Children contain element and text
nodes in DOM order. Comments are omitted. A separate `doctype` field records
the document type. The tree builder may recover from errors. Lexbor’s reported
tokenizer and tree errors appear as warnings with original source offsets
where available. The compiler can reject syntax, namespaces, encodings or
document modes according to its target capabilities.

```json
{
  "doctype": {"name":"html","public_id":"","system_id":""},
  "mode":"no-quirks",
  "nodes": [{
    "kind":"element","tag":"html","namespace":"html","offset":null,
    "attrs":[],"children":[]
  }],
  "diagnostics":[]
}
```

The `doctype` is null when absent. The document mode is `no-quirks`,
`limited-quirks` or `quirks`. Element namespaces are `html`, `svg`,
`mathml` or `other`. Each attribute is an ordered entry with `name`,
decoded `value`, `offset` at its name and `value_offset` at the start
of its unquoted source contents. Implied elements can have null offsets.
Each text node has `kind:"text"`, `text` and `offset` at the source token
that inserted it, when available. Character references and HTML tree
recovery can make decoded text differ from a literal source slice.

## Widget fragments

`widgets` uses Lexbor’s tokenizer with an explicit nesting stack. Its root
has `mode:"widgets"`, `doctype:null` and a list of fragment nodes.
Elements use `namespace:"widget"`. Tags such as `<row>` and `<col>`
can nest. Use matching closing tags or `/>` for an empty widget.
Standard HTML void tags other than `col` may omit their closing tag.
An unmatched or unclosed widget produces an error diagnostic. This mode
is selected by the caller.

## CSS

`css` emits an ordered `rules` array. A rule has `selector`, `offset`
and ordered `declarations`. A declaration has `name`, `value`,
`important`, `offset` at the property name and `value_offset`.
The selector and value preserve source spelling and inner whitespace.
The value excludes the priority suffix. Unknown property names are
passed to the consumer. At-rules, nested rules, invalid selectors,
unbalanced blocks and malformed declarations produce error diagnostics.

`declarations` parses an inline declaration list and returns the same
declaration objects in a top-level `declarations` array. Offsets refer
to the UTF-8 bytes of that list. Mapping them to an HTML attribute
requires accounting for entity decoding in its original source.

Every mode includes `diagnostics`, an array of
`{severity, message, offset}`. Run the protocol checks with
`python3 tools/decomposer/test_parser.py zig-out/bin/decomposer-parse`.
