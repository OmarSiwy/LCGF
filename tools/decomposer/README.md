# HTML and CSS to native Zig

Decomposer reads UTF-8 HTML and CSS on the build host and emits an ordinary Zig module. A page exports its title, native widget specification, generated state type and a `Page.frame(input)` entry point. Zig compiles the specification into the same widget and accessibility tables used by handwritten LCGF pages. The application links its chosen renderer. Python and Lexbor are build tools.

## Compile and inspect a page

From the LCGF checkout with the pinned Zig and Python 3.10 or newer installed, run the following commands.

```sh
zig build -Ddecomposer decompose -- tools/decomposer/testdata/counter.html -o /tmp/page.zig --explain
zig build -Ddecomposer decompose -- --mappings > /tmp/native-mappings.tsv
zig build -Ddecomposer decomposer-test
```

Use a standards-mode document starting with `<!doctype html>`. For a snippet such as `<p>Hello</p>`, pass `--fragment` to supply a standards-mode document around it. The parser resolves character references, optional end tags, implied containers and foreign namespaces. It reports syntax recovery and unsupported mappings before replacing an existing output file.

A `<style>` block or a local `<link rel="stylesheet" href="page.css">` participates in document order. Additional `--css FILE` arguments follow those sheets. Selectors, author priority, specificity, supported inheritance, inline styles and custom properties resolve during generation. Linked files are dependencies of the generated page. LCGF supplies the default widget theme. Author CSS controls supported aspects of the native appearance.

## Read-only declarations and Zig writers

```html
<!doctype html>
<html data-zig-state="App">
  <main>
    <h1>{title}</h1>
    <p>{message}</p>
    <button id="save" data-zig-click="actions.save" data-zig-writes="message">Save</button>
  </main>
</html>
```

```zig
pub const App = struct {
    title: []const u8 = "Editor",
    message: []const u8 = "Ready",
};

pub const actions = struct {
    pub fn save(writer: anytype) void {
        writer.set(.message, "Saved");
    }
};
```

Here Zig evaluates `title` once and stores it as literal text. Only `message` becomes a runtime signal field. Removing the write declaration makes the page's document state zero bytes and makes the existing call to `set` a compile error. A callback can use `get(.title)` to read a default. A click callback with no write targets can observe an event. Layout still uses the current window size, and the native button still handles focus, hover and activation.

The native front end reserves the exact literal caption bytes and a shared 1,024-byte allowance for additional runtime text. Keep the total dynamic text within that allowance to display it in full.

The source state struct supplies typed defaults through `.{}`. A caption can contain one `{field}` with a string value. Declare multiple write targets as a space-separated list. Each callback receives its own list of permitted fields. The native state setter updates signal dependencies, and the generated page schedules another frame after a writer. `data-zig-if="field"` takes a Boolean. A read-only condition includes or removes the subtree at comptime. An explicitly writable condition uses the native conditional-region builder.

## Use a page from another Zig project

Declare `lcgf` in your package dependencies. In your application’s `build.zig`, add the generated module to the executable. The build helper returns null while Zig fetches the optional host parser.

```zig
const framework = b.dependency("lcgf", .{ .target = target, .optimize = optimize });
const handlers = b.createModule(.{ .root_source_file = b.path("src/handlers.zig") });
const page = @import("lcgf").addMarkup(b, framework, .{
    .html = b.path("src/ui.html"),
    .handlers = handlers,
}) orelse return;
exe.root_module.addImport("page", page);
```

Omit `.handlers` for literal-only pages. Store one `var app: page.Page = .{};` per instance and pass the current input to `app.frame(&input)`. Consume its draw list, tree, event and wake time as for a native widget page. The output views borrow the page's frame buffers.

To export an editable project, choose a new directory. The exported tests render a native software frame. The project records a relative path to the framework checkout. Update that dependency if the two directories move relative to each other.

```sh
zig build -Ddecomposer decompose -- tools/decomposer/testdata/counter.html \
    --handlers tools/decomposer/testdata/handlers.zig --emit-zig /tmp/native-counter
(cd /tmp/native-counter && zig build test)
```

## Coverage and the next mappings

`--mappings` prints one tab-separated decision per indexed definition with its kind, spelling, implementation status, native target or missing capability, and normative link. The HTML inventory distinguishes the same attribute on different elements. The CSS inventory covers properties, functions, selectors, at-rules, descriptors and value types. The checked-in inputs, exact versions and offline regeneration procedure are in the [catalog guide](catalog.md).

The implemented HTML subset includes document metadata, native containers and landmarks, plain-text headings, paragraphs, standalone spans, buttons, button inputs and horizontal rules. The CSS inventory describes the supported values of each mapped property. A recognized element or property can still require a missing value, layout context or semantic behavior. For example, adjacent inline runs need native inline formatting, form submission needs native form ownership, and `display: grid` needs a grid layout implementation. These inputs produce errors. A supported selector can match zero elements.

Add mappings in this order. First make the framework express the feature and its observable behavior, including layout, state or accessibility where applicable. Then implement the compiler mapping and add a case exercising the generated native output. Keep a rejection case for the next unsupported combination. Update the inventory status when the corresponding compiler path is usable. Browser conformance also includes algorithms and interactions beyond a list of feature names. Relevant upstream fixtures can be imported from [Web Platform Tests](https://web-platform-tests.org/).

## Parser and engine research

Lexbor 3.0.1 provides the HTML5 tree builder and CSS parser under Apache-2.0. Zig builds the pinned upstream C source lazily for the build host. Our adapter retains source locations for diagnostics and feeds the cascade and widget emitter. This reuses HTML parsing behavior such as implied table sections without introducing a DOM into the target application. [Lexbor](https://github.com/lexbor/lexbor/tree/v3.0.1) · [Parser protocol](parser.md)

Servo's html5ever is an HTML parser in Rust. Stylo implements CSS styling, and Blitz combines a document, style and layout engine. These are candidates for future differential testing and for research on harder mappings. Lexbor provided both input parsers through the existing Zig/C toolchain. LCGF's own layout, rendering, accessibility and signal APIs determine which constructs can produce native output. [html5ever](https://github.com/servo/html5ever) · [Stylo](https://github.com/servo/stylo) · [Blitz](https://github.com/DioxusLabs/blitz)
