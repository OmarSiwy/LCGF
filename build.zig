//! Build file for LCGR. Zig 0.18.0-dev.1151+8dfb7a7cc (prototype/build.zig is the verified example of this API).
//!
//!   zig build                      compile the library module
//!   zig build test                 run every test reachable from src/lcgr.zig
//!   zig build test -Dcpu=x86_64_v3 same, with 8 SIMD lanes on x86-64
//!   zig build test -Dlanes=16      same, with the SIMD lane count forced (simd.lanes)
//!   zig build test-build           compile the tests only, e.g. with -Dtarget=aarch64-linux
//!   zig build fmt                  fail if any Zig file is not formatted (CI runs this)
//!   zig build fuzz [--fuzz=N]      tools/fuzz tests; with --fuzz, coverage-guided fuzzing
//!   zig build fuzz-run -- 60       tools/fuzz seeded loop for 60 s (ci/run.sh fuzz)
//!   zig build ct-rodata            object for the comptime read-only-data check (ci/run.sh ct-rodata)
//!   zig build ct-setter            object for the comptime setter-shape check (ci/run.sh ct-setter)
//!   zig build font-fuzz -- 300     font parser seeded mutation loop for 300 s (ci/run.sh font-fuzz)
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // std's width query never returns 16, so 16 lanes can only be tested by forcing the count.
    const options = b.addOptions();
    options.addOption(?u32, "lanes", b.option(u32, "lanes", "SIMD lanes per vector (default: the target's)"));

    // The package root. Every lane exports its file from here, so one module sees them all.
    const lcgr = b.addModule("lcgr", .{
        .root_source_file = b.path("src/lcgr.zig"),
        .target = target,
        .optimize = optimize,
    });
    lcgr.addOptions("build_options", options);

    // Unicode property tables, generated on the host from the UCD files (src/text/unicode/gen.zig).
    const ucd_gen = b.addRunArtifact(b.addExecutable(.{ .name = "ucd-gen", .root_module = b.createModule(.{
        .root_source_file = b.path("src/text/unicode/gen.zig"),
        .target = b.graph.host,
    }) }));
    const ucd_tables = ucd_gen.addOutputFileArg("unicode_tables.zig");
    for ([_][]const u8{ "GraphemeBreakProperty", "emoji-data", "DerivedCoreProperties", "WordBreakProperty", "LineBreak", "EastAsianWidth", "DerivedGeneralCategory", "DerivedBidiClass", "BidiBrackets", "Scripts" }) |f|
        ucd_gen.addFileArg(b.path(b.fmt("src/text/unicode/data/{s}.txt", .{f})));
    lcgr.addAnonymousImport("unicode_tables", .{ .root_source_file = ucd_tables });

    const lib = b.addLibrary(.{ .name = "lcgr", .root_module = lcgr });
    b.getInstallStep().dependOn(&lib.step);

    const tests = b.addTest(.{ .root_module = lcgr });
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    // For targets this machine cannot run (ci/run.sh cross).
    b.step("test-build", "Compile the tests without running them").dependOn(&tests.step);
    // The Unicode conformance files (src/text/unicode/conformance.zig): seconds, so not in `test`.
    const conformance = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/text/unicode/conformance.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lcgr", .module = lcgr }},
    }) });
    b.step("conformance", "Run the Unicode conformance files").dependOn(&b.addRunArtifact(conformance).step);

    // The package root built ReleaseFast, for the branch census and the benchmark.
    const lcgr_fast = b.createModule(.{ .root_source_file = b.path("src/lcgr.zig"), .target = target, .optimize = .ReleaseFast });
    lcgr_fast.addOptions("build_options", options);
    const census_probe = b.addObject(.{ .name = "census_src", .root_module = b.createModule(.{
        .root_source_file = b.path("src/layout/census_probe.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "lcgr", .module = lcgr_fast }},
    }) });
    b.step("census-src-obj", "Emit zig-out/census_src.o, the ported passes for the branch census").dependOn(&b.addInstallFile(census_probe.getEmittedBin(), "census_src.o").step);

    // tools/bench builds frames with the prototype core ("ui") and times the ported layout ("lcgr");
    // the rest moves to src/ as it is ported.
    const bench_core = b.createModule(.{ .root_source_file = b.path("prototype/ui.zig"), .target = target, .optimize = .ReleaseFast });
    const bench = b.addExecutable(.{ .name = "bench", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/bench/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{ .{ .name = "ui", .module = bench_core }, .{ .name = "lcgr", .module = lcgr_fast } },
    }) });
    const bench_run = b.addRunArtifact(bench);
    bench_run.addPassthruArgs();
    b.step("bench", "Run the frame benchmark (Linux)").dependOn(&bench_run.step);
    const probe = b.addSystemCommand(&.{ "python3", "tools/bench/probe.py", "--" });
    probe.addArtifactArg(bench);
    probe.addArg("--idle");
    b.step("probe", "Print resident memory and idle wake-ups after one frame (Linux)").dependOn(&probe.step);

    // Section sizes per example, built ReleaseSmall. Linux (ELF64) only. Until examples/ exists the
    // examples are the prototype's frame dumper and the benchmark.
    const size_tool = b.addExecutable(.{ .name = "size", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/bench/size.zig"),
        .target = b.graph.host,
    }) });
    const size_run = b.addRunArtifact(size_tool);
    const small_core = b.createModule(.{ .root_source_file = b.path("prototype/ui.zig"), .target = target, .optimize = .ReleaseSmall });
    const lcgr_small = b.createModule(.{ .root_source_file = b.path("src/lcgr.zig"), .target = target, .optimize = .ReleaseSmall });
    lcgr_small.addOptions("build_options", options);
    for ([_][2][]const u8{ .{ "dump", "prototype/dump.zig" }, .{ "bench", "tools/bench/bench.zig" } }) |ex| {
        const exe = b.addExecutable(.{ .name = ex[0], .root_module = b.createModule(.{
            .root_source_file = b.path(ex[1]),
            .target = target,
            .optimize = .ReleaseSmall,
            .imports = &.{ .{ .name = "ui", .module = small_core }, .{ .name = "lcgr", .module = lcgr_small } },
        }) });
        size_run.addArtifactArg(exe);
    }
    b.step("size", "Print text, rodata, data and bss of each example (Linux)").dependOn(&size_run.step);
    const size_tests = b.addTest(.{ .root_module = size_tool.root_module });
    test_step.dependOn(&b.addRunArtifact(size_tests).step);

    // Fuzz entry points (tools/fuzz). They drive the prototype core until it is ported to src/.
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("tools/fuzz/fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ui", .module = b.createModule(.{ .root_source_file = b.path("prototype/ui.zig") }) }},
    });
    const fuzz_tests = b.addTest(.{ .root_module = fuzz_mod });
    b.step("fuzz", "Run the fuzz tests (add --fuzz=N to fuzz)").dependOn(&b.addRunArtifact(fuzz_tests).step);
    const fuzz_run = b.addRunArtifact(b.addExecutable(.{ .name = "fuzz", .root_module = fuzz_mod }));
    fuzz_run.addPassthruArgs();
    b.step("fuzz-run", "Fuzz for a time: -- [seconds] [seed] [first]").dependOn(&fuzz_run.step);

    // Object whose exported functions read the comptime flatten tables (ci/jobs/ct-rodata.sh
    // checks they land in read-only data).
    const ct_rodata = b.addObject(.{ .name = "ct_rodata", .root_module = b.createModule(.{
        .root_source_file = b.path("src/comptime/rodata_probe.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lcgr", .module = lcgr }},
    }) });
    b.step("ct-rodata", "Build the object the read-only-data check reads").dependOn(&b.addInstallFile(ct_rodata.getEmittedBin(), "ct_rodata.o").step);
    // Object exporting the comptime setter (ci/jobs/ct-setter.sh checks it is a store and an OR).
    const ct_setter = b.addObject(.{ .name = "ct_setter", .root_module = b.createModule(.{
        .root_source_file = b.path("src/comptime/setter_probe.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lcgr", .module = lcgr }},
    }) });
    b.step("ct-setter", "Build the object the setter-shape check reads").dependOn(&b.addInstallFile(ct_setter.getEmittedBin(), "ct_setter.o").step);
    // Font parser fuzzing (src/text/font/fuzz.zig): seeded mutation loop for a set time.
    const font_fuzz = b.addRunArtifact(b.addExecutable(.{ .name = "font-fuzz", .root_module = b.createModule(.{
        .root_source_file = b.path("src/text/font/fuzz.zig"),
        .target = target,
        .optimize = optimize,
    }) }));
    font_fuzz.addPassthruArgs();
    b.step("font-fuzz", "Fuzz the font parser: -- [seconds] [seed] [first]").dependOn(&font_fuzz.step);

    const fmt = b.addFmt(.{ .paths = &.{b.path(".")}, .check = true });
    b.step("fmt", "Check formatting of every Zig file").dependOn(&fmt.step);
}
