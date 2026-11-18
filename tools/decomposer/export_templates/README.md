# Native Zig page

Edit `page.zig` to change the page's native widget tree. It contains the source
emitted by the Decomposer. The Zig package uses LCGF through the relative path
in `build.zig.zon`. Use the framework revision that generated this page and
its pinned Zig version, `0.18.0-dev.1151+8dfb7a7cc`.

```sh
zig build
zig build test
```

The first command compiles the package's native frame test. The second lays out
the page, shapes its labels and draws one frame into a 320 × 200 software
framebuffer. A project using this package can import its `page` module,
instantiate `page.Page` and pass native input to its `frame` method. For
example, if the consuming project's manifest names this dependency `screen`,
wire it into an executable in its build script as follows.

```zig
const screen = b.dependency("screen", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("page", screen.module("page"));
```

If you move this directory, run `zig fetch --save=lcgf ../gui-framework` with
the relative path to your framework checkout. An offline build can use
`zig build test --pkg-dir ../gui-framework/zig-pkg` with that same layout.
