//! Branch-census probe for the runtime front end's reuse (docs/CHECKS.md section 2), imported by
//! src/census_probes.zig. Not exported from src/lcgr.zig.
const lcgr = @import("lcgr");

export fn p_reuse(f: *lcgr.frame.Frame, id: u32, deps: [*]const lcgr.runtime_signals.Signal, n: usize) bool {
    return f.reuse(@fromBackingInt(id), deps[0..n]);
}
