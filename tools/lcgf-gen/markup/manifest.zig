//! The mapping manifest (manifest.zon): one row per HTML element, attribute, CSS property,
//! selector or at-rule the compiler decides about, with its status, its target in the framework
//! and, when it is not mapped, the exact diagnostic. The compiler reads its rejections from
//! here, so the messages exist once; `lcgf-gen --mappings` prints the rows as TSV.

const std = @import("std");

pub const Status = enum {
    /// Lowered onto the framework as it is today; has a fixture.
    mapped,
    /// Lowered onto engine API specified in docs/plans/markup-engine-api.md that main has not
    /// landed yet (`spec` names the entry); its fixture is in the `markup-pending` step.
    pending,
    /// Not lowered yet by the compiler itself; rejected with `diagnostic`.
    planned,
    /// Not modelled by design; rejected with `diagnostic`.
    rejected,
};

pub const Row = struct {
    kind: []const u8,
    name: []const u8,
    applies_to: []const u8 = "",
    status: Status,
    target: []const u8 = "",
    diagnostic: []const u8 = "",
    fixture: []const u8 = "",
    spec: []const u8 = "",
};

pub const Fixture = struct {
    name: []const u8,
    /// Spec entries it waits for; empty when it runs in the normal suite.
    waits_for: []const []const u8 = &.{},
    /// The runtime frontend cannot build it yet (engine spec R1); its runtime parity test is
    /// in `markup-pending`.
    spec_only: bool = false,
    /// Built for the runtime frontend with `--runtime-vars=<this>`, and its runtime_test.zig run.
    runtime_vars: []const u8 = "",
    /// Its page and twin import `app` from `<name>/app.zig` (app components).
    app: bool = false,
    /// The compile-fail cases also get the page built over each `<name>/app_<x>.zig` listed,
    /// as `<name>_<x>`.
    wrong_apps: []const []const u8 = &.{},
    /// More apps the comptime page is built over, each `<name>/app_<x>.zig`, that must give the
    /// twin's spec and pass its fixture test: an app with only the spec forms, as before the
    /// runtime frontend lowered components.
    spec_apps: []const []const u8 = &.{},
};

pub const Manifest = struct { rows: []const Row, fixtures: []const Fixture };

pub const manifest: Manifest = @import("manifest.zon");

/// The row for (`kind`, `name`), preferring one whose `applies_to` is `scope`.
pub fn find(kind: []const u8, name: []const u8, scope: []const u8) ?*const Row {
    var found: ?*const Row = null;
    for (manifest.rows) |*r| {
        if (!std.mem.eql(u8, r.kind, kind) or !std.mem.eql(u8, r.name, name)) continue;
        if (std.mem.eql(u8, r.applies_to, scope)) return r;
        if (r.applies_to.len == 0) found = r;
    }
    return found;
}

/// The diagnostic of a rejected or planned row, or null when the row is mapped or pending.
pub fn refusal(kind: []const u8, name: []const u8, scope: []const u8) ?[]const u8 {
    const r = find(kind, name, scope) orelse return null;
    return switch (r.status) {
        .rejected, .planned => r.diagnostic,
        .mapped, .pending => null,
    };
}

/// `lcgf-gen --mappings`: the rows as TSV, with a header.
pub fn writeTsv(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("kind\tname\tapplies_to\tstatus\ttarget\tdiagnostic\tfixture\tspec\n");
    for (manifest.rows) |r|
        try w.print("{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\n", .{ r.kind, r.name, r.applies_to, @tagName(r.status), r.target, r.diagnostic, r.fixture, r.spec });
}

test "manifest: every row is unique, refused rows carry a message, pending rows name a spec entry" {
    for (manifest.rows, 0..) |r, i| {
        for (manifest.rows[0..i]) |o| if (std.mem.eql(u8, o.kind, r.kind) and std.mem.eql(u8, o.name, r.name) and std.mem.eql(u8, o.applies_to, r.applies_to)) {
            std.debug.print("duplicate manifest row {s} {s} {s}\n", .{ r.kind, r.name, r.applies_to });
            return error.Duplicate;
        };
        switch (r.status) {
            .rejected, .planned => if (r.diagnostic.len == 0) return error.NoDiagnostic,
            .pending => if (r.spec.len == 0) return error.NoSpecEntry,
            .mapped => if (r.target.len == 0) return error.NoTarget,
        }
        // Every mapped or pending row names the fixture that shows it.
        if (r.status == .mapped or r.status == .pending) for (manifest.fixtures) |f| {
            if (std.mem.eql(u8, f.name, r.fixture)) break;
        } else {
            std.debug.print("manifest row {s} {s} names no fixture of the manifest ('{s}')\n", .{ r.kind, r.name, r.fixture });
            return error.NoFixture;
        };
    }
    for (manifest.fixtures) |f| for (manifest.rows) |r| {
        if (std.mem.eql(u8, r.fixture, f.name) and r.status == .pending) {
            for (f.waits_for) |wf| {
                if (std.mem.eql(u8, wf, r.spec)) break;
            } else {
                std.debug.print("fixture {s} has the pending row {s} but does not wait for {s}\n", .{ f.name, r.name, r.spec });
                return error.FixtureNotPending;
            }
        }
    };
}
