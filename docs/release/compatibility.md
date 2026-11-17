# Versioning and deprecation

The package version follows `MAJOR.MINOR.PATCH`. A release tag points to the tested source revision. The changelog records the exact Zig compiler supported by that version. Zig development builds can change language, build-system and object-format behavior, so a compiler migration is a release-note item.

| Change | Before 1.0 | From 1.0 |
|---|---|---|
| Compatible bug or performance fix | Patch | Patch |
| Additive public API, opt-in build option or backend | Minor | Minor |
| Removing a public declaration, changing a signature, changing caller-owned bounds or lifetime, or changing observable behavior beyond a documented bug | Minor with migration notes | Major with migration notes |
| Removing a build option, changing its default in a way that breaks a supported target, or changing a public GPU buffer layout | Minor with migration notes | Major with migration notes |

The compatibility surface includes the documented package modules, public production declarations, buffer sizing and borrowing contracts, supported renderer features and package options. A new member in an exhaustive enum or union can break a caller's exhaustive switch. A new field on a public record can affect size, alignment or construction. Evaluate those changes as source or layout changes before describing them as additive.

Public fixtures with names such as `testChain`, `encodeForTest`, the `*_tests` namespaces, benchmark data, generated documentation format and compiler assembly are development interfaces. Native graphics and OS handles also carry the contracts of their upstream SDKs. A release that changes an embedded coordinate or asset format names the affected profile and whether stored data must be rebuilt.

## Deprecation

1. Add the replacement, document its input, output and storage contracts, and give a compilable migration example.
2. Mark the old declaration or option in its doc comment and in the changelog. State the first version carrying the replacement and the earliest release in which removal is permitted.
3. Keep the old path working through at least one intervening minor release. A forwarding wrapper is appropriate when it preserves caller-visible results and lifetimes.
4. Remove it only at the breaking-change boundary above. Keep migration notes in the release that removes it.

A release that must change behavior promptly to correct invalid memory access or data corruption documents the affected inputs, fixed behavior and supported upgrade path. The milestone plan defines which implementations and gate histories are required to create a tag.
