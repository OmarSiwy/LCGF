# Layout of static comptime UIs against the runtime tree (plans C0160-C0167):
# src/comptime/layout_bench.zig, ReleaseFast. Prints ns per frame; no gate (a shared CI machine's
# timings are not stable enough to fail on). Equality of the results is the tests' job.
zig build ct-layout-bench
