// SPDX-License-Identifier: Apache-2.0
//
// The re-diff benchmark. `zig build rediff -Doptimize=ReleaseFast -- [base] [repo]`.
//
// The lexer and the anchor both have a harness; the path between them did not,
// which is why the parse being twice the cost of git itself went unnoticed.
// It measures the three spans a re-diff is actually made of, against the same
// budgets io/metrics.zig flags:
//
//   parse         unified diff text to FileDiffs, once per re-diff (100 ms)
//   risk counts    what the change did to the tests, counts only
//   risk + rows    the same reading, also marking the rows `]w` stops on
//
// The last two are reported apart because the rows used to be a second walk
// over the same lines; the gap between them is what that walk now costs.
//
// Best-of, not mean: a minimum is the measurement least polluted by whatever
// else the machine was doing.

const std = @import("std");
const lgtm = @import("lgtm");
const diff = lgtm.diff;
const testrisk = lgtm.testrisk;
const highlight = lgtm.highlight;

const min_iterations = 3;
const max_iterations = 500;
/// Long enough to swamp timer noise, short enough to stay interactive.
const target_ns = 300 * std.time.ns_per_ms;

const Result = struct {
    ns: u64 = std.math.maxInt(u64),
    iterations: u64 = 0,

    fn take(self: *Result, ns: u64) void {
        if (ns < self.ns) self.ns = ns;
        self.iterations += 1;
    }
};

fn now(io: std.Io) std.Io.Timestamp {
    return std.Io.Timestamp.now(io, .awake);
}

fn since(io: std.Io, start: std.Io.Timestamp) u64 {
    return @intCast(@max(0, start.durationTo(now(io)).nanoseconds));
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

/// Accumulated so the optimiser cannot delete the work being measured.
var sink: u64 = 0;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var buf: [64 << 10]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    const w = &fw.interface;

    var args = init.minimal.args.iterate();
    _ = args.next();
    const base = args.next() orelse "HEAD~5";
    const repo = args.next() orelse ".";

    // The real thing git hands the parser, fetched once: the subprocess is
    // measured by the profile report, not here.
    const out = try lgtm.proc.run(gpa, io, &.{
        "git", "-C", repo, "diff", "--no-color", "--no-ext-diff", base,
    }, 64 << 20);
    defer out.deinit(gpa);
    const text = out.stdout;

    if (text.len == 0) {
        try w.print("no diff for {s} in {s}\n", .{ base, repo });
        try w.flush();
        return 1;
    }

    var lines: u32 = 0;
    for (text) |c| {
        if (c == '\n') lines += 1;
    }

    // Parse.
    var parse_r: Result = .{};
    {
        const deadline = now(io);
        while (parse_r.iterations < max_iterations) {
            const t = now(io);
            var d = try diff.parse(gpa, text);
            parse_r.take(since(io, t));
            sink +%= d.files.len;
            d.deinit(gpa);
            if (parse_r.iterations >= min_iterations and since(io, deadline) > target_ns) break;
        }
    }

    var d = try diff.parse(gpa, text);
    defer d.deinit(gpa);

    var diff_lines: usize = 0;
    var known: u32 = 0;
    for (d.files) |*f| {
        diff_lines += f.lines.len();
        if (highlight.forPath(f.path()) != null) known += 1;
    }

    // Risk scan, over every file, which is what one re-diff does.
    var scan_r: Result = .{};
    {
        const deadline = now(io);
        while (scan_r.iterations < max_iterations) {
            const t = now(io);
            for (d.files) |*f| {
                if (highlight.forPath(f.path())) |def| {
                    const r = testrisk.scan(f, def);
                    sink +%= @intFromBool(r.any());
                }
            }
            scan_r.take(since(io, t));
            if (scan_r.iterations >= min_iterations and since(io, deadline) > target_ns) break;
        }
    }

    // The fused pass: counts and rows from one reading, which is what a
    // re-diff actually runs.
    var rows_r: Result = .{};
    {
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const deadline = now(io);
        while (rows_r.iterations < max_iterations) {
            _ = arena_state.reset(.retain_capacity);
            const arena = arena_state.allocator();
            const t = now(io);
            for (d.files) |*f| {
                if (highlight.forPath(f.path())) |def| {
                    const found = try testrisk.scanRows(arena, f, def);
                    sink +%= found.rows.len +% @intFromBool(found.risk.any());
                }
            }
            rows_r.take(since(io, t));
            if (rows_r.iterations >= min_iterations and since(io, deadline) > target_ns) break;
        }
    }

    try w.print("lgtm re-diff benchmark - {s} vs {s}\n", .{ repo, base });
    try w.print("{d} files ({d} with a known language), {d} diff lines, {d} bytes of diff text\n", .{
        d.files.len, known, diff_lines, text.len,
    });
    try w.print("optimize: {t}, best-of over >= {d} iterations\n\n", .{
        @import("builtin").mode, min_iterations,
    });

    // `scanRows` is what a re-diff runs; `scan` is the same reading without
    // the rows, and the gap between them is what the rows now cost.
    const risk_total = rows_r.ns;
    try w.writeAll("stage                  ms      ns/line\n");
    try w.print("parse           {d: >9.3} {d: >12.0}\n", .{ ms(parse_r.ns), perLine(parse_r.ns, lines) });
    try w.print("risk counts     {d: >9.3} {d: >12.0}\n", .{ ms(scan_r.ns), perLine(scan_r.ns, @intCast(diff_lines)) });
    try w.print("risk + rows     {d: >9.3} {d: >12.0}\n", .{ ms(rows_r.ns), perLine(rows_r.ns, @intCast(diff_lines)) });

    try w.print("\nagainst budgets\n", .{});
    try w.print("  parse:     {d:.3} ms   {s} (re-diff budget 100 ms, shared with git)\n", .{
        ms(parse_r.ns), if (ms(parse_r.ns) <= 100) "ok" else "OVER",
    });
    try w.print("  test risk: {d:.3} ms   {s} (budget 10 ms)\n", .{
        ms(risk_total), if (ms(risk_total) <= 10) "ok" else "OVER",
    });

    try w.print("\nchecksum {d}\n", .{sink});
    try w.flush();
    return 0;
}

fn perLine(ns: u64, lines: u32) f64 {
    if (lines == 0) return 0;
    return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(lines));
}
