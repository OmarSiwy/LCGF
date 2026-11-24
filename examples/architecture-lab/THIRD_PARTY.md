# Third-party components

## LCGF

This example consumes one [LCGF](https://github.com/OmarSiwy/LCGF) dependency.
Its default manifest points to the containing checkout with `.path = "../.."`.
The framework is not copied into the example. The application and adapted X11
host are covered by this project's [MIT license](LICENSE), which retains the
LCGF authors' notice.

The build installs the selected framework's MIT notice, this application's
notice, the example-font notice, and the Unicode notices under
`share/licenses/architecture-lab/` beside installed executables.

## DejaVu font

LCGF's shared software host embeds the DejaVu Sans Mono coverage atlas. Its
license is supplied by the framework at `src/example/font/LICENSE.txt` and is
installed by this example's build. Alpha8 sampling changes its storage binding,
not the underlying font asset or its license.

## Unicode Character Database

The framework generates Unicode tables using its pinned UCD dependency. The
example uses that dependency's module and generated tables directly; it does
not generate a second copy or change the dependency hash.

The [Unicode license](licenses/Unicode.txt) and
[UCD 16.0.0 release notice](licenses/UCD-16.0.0-ReadMe.txt) are retained here for
distribution with the installed application. Obtain the matching framework
revision and its declared dependencies when copying this example.
