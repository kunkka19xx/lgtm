// SPDX-License-Identifier: Apache-2.0
//
// The lexer benchmark. `zig build bench -- [dir] [ext]`, ReleaseFast.
//
// Instrument before optimising: the T1 and T2 items in
// The lexer's budget - comptime perfect hashing for keywords, delimiter skipping
// - are not to be built until this says which one is worth building. It
// measures four things, because they have different budgets:
//
//   structure   whole-file pass, once per changed file per re-diff (100 ms)
//   full lex    whole file to runs, the pathological render (8 ms)
//   screen      50 lines from the nearest checkpoint, what a frame draws (8 ms)
//   cache hit   the path a re-diff takes for a file nobody touched
//
// Best-of, not mean: a minimum is the measurement least polluted by whatever
// else the machine was doing.

const std = @import("std");
const lgtm = @import("lgtm");
const lexer = lgtm.lexer;
const highlight = lgtm.highlight;

/// A screen's worth of lines, plus a margin.
const screen_lines = 50;
const min_iterations = 5;
const max_iterations = 2000;
/// Long enough to swamp timer noise, short enough to stay interactive.
const target_ns = 150 * std.time.ns_per_ms;

const Case = struct {
    path: []const u8,
    text: []const u8,
    hl: highlight.Highlighter,
    lines: u32,
};

const Result = struct {
    ns: u64 = std.math.maxInt(u64),
    iterations: u64 = 0,

    fn take(self: *Result, ns: u64) void {
        if (ns < self.ns) self.ns = ns;
        self.iterations += 1;
    }
};

fn countLines(text: []const u8) u32 {
    var n: u32 = 0;
    for (text) |c| {
        if (c == '\n') n += 1;
    }
    if (text.len > 0 and text[text.len - 1] != '\n') n += 1;
    return n;
}

fn now(io: std.Io) std.Io.Timestamp {
    return std.Io.Timestamp.now(io, .awake);
}

fn since(io: std.Io, start: std.Io.Timestamp) u64 {
    return @intCast(@max(0, start.durationTo(now(io)).nanoseconds));
}

/// Accumulated so the optimiser cannot delete the work being measured.
var sink: u64 = 0;

fn benchStructure(io: std.Io, gpa: std.mem.Allocator, c: Case) !Result {
    var r: Result = .{};
    const deadline = now(io);
    while (r.iterations < max_iterations) {
        const t = now(io);
        var st = try c.hl.structure(gpa, c.text);
        r.take(since(io, t));
        sink +%= st.fns.len +% st.checkpoints.len;
        st.deinit(gpa);
        if (r.iterations >= min_iterations and since(io, deadline) > target_ns) break;
    }
    return r;
}

fn benchFullLex(io: std.Io, gpa: std.mem.Allocator, c: Case) !Result {
    var r: Result = .{};
    var out: std.ArrayList(lexer.Run) = .empty;
    defer out.deinit(gpa);

    const deadline = now(io);
    while (r.iterations < max_iterations) {
        out.clearRetainingCapacity();
        const t = now(io);
        _ = try c.hl.lex(gpa, c.text, 0, c.text.len, .{}, &out);
        r.take(since(io, t));
        sink +%= out.items.len;
        if (r.iterations >= min_iterations and since(io, deadline) > target_ns) break;
    }
    return r;
}

/// One screenful from the nearest checkpoint, which is what a frame actually
/// costs once the renderer exists. Averaged over every checkpoint in the file
/// so it is not a measurement of one lucky region.
fn benchScreen(io: std.Io, gpa: std.mem.Allocator, c: Case, st: lexer.Structure) !Result {
    var r: Result = .{};
    var out: std.ArrayList(lexer.Run) = .empty;
    defer out.deinit(gpa);
    if (st.checkpoints.len == 0) return r;

    const deadline = now(io);
    while (r.iterations < max_iterations) {
        var total: u64 = 0;
        for (st.checkpoints) |cp| {
            // Lex from the checkpoint to `screen_lines` past its start.
            var stop = cp.offset;
            var seen: u32 = 0;
            while (stop < c.text.len and seen < screen_lines) : (stop += 1) {
                if (c.text[stop] == '\n') seen += 1;
            }
            out.clearRetainingCapacity();
            const t = now(io);
            _ = try c.hl.lex(gpa, c.text, cp.offset, stop, cp.state, &out);
            total += since(io, t);
            sink +%= out.items.len;
        }
        r.take(total / st.checkpoints.len);
        if (r.iterations >= min_iterations and since(io, deadline) > target_ns) break;
    }
    return r;
}

fn benchCacheHit(io: std.Io, gpa: std.mem.Allocator, c: Case) !Result {
    var cache: highlight.Cache = .{};
    defer cache.deinit(gpa);
    // The key a real caller supplies: git's blob hash, computed once, not a
    // re-hash of the file on every lookup.
    const key = highlight.hashContent(c.text);
    _ = try cache.structureFor(gpa, c.hl, key, c.text);

    var r: Result = .{};
    const deadline = now(io);
    while (r.iterations < max_iterations) {
        const t = now(io);
        const st = try cache.structureFor(gpa, c.hl, key, c.text);
        r.take(since(io, t));
        sink +%= st.fns.len;
        if (r.iterations >= min_iterations and since(io, deadline) > target_ns) break;
    }
    return r;
}

fn perLine(ns: u64, lines: u32) f64 {
    if (lines == 0) return 0;
    return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(lines));
}

fn mbPerSec(ns: u64, bytes: usize) f64 {
    if (ns == 0) return 0;
    const secs = @as(f64, @floatFromInt(ns)) / std.time.ns_per_s;
    return (@as(f64, @floatFromInt(bytes)) / (1024 * 1024)) / secs;
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var buf: [64 << 10]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    const w = &fw.interface;

    var args = init.minimal.args.iterate();
    _ = args.next();
    const root = args.next() orelse "src";
    const ext = args.next() orelse "zig";

    const paths = try lgtm.fs.walkExt(io, gpa, root, &.{ext});
    defer lgtm.fs.freeNames(gpa, paths);
    if (paths.len == 0) {
        try w.print("no .{s} files under {s}\n", .{ ext, root });
        try w.flush();
        return 1;
    }

    var cases: std.ArrayList(Case) = .empty;
    defer {
        for (cases.items) |c| gpa.free(c.text);
        cases.deinit(gpa);
    }

    var corpus: std.ArrayList(u8) = .empty;
    defer corpus.deinit(gpa);

    for (paths) |p| {
        const text = try lgtm.fs.readFile(io, gpa, p, 8 << 20);
        const lines = countLines(text);
        try corpus.appendSlice(gpa, text);
        try cases.append(gpa, .{
            .path = p,
            .text = text,
            .hl = highlight.Highlighter.choose(p, text.len, lines),
            .lines = lines,
        });
    }

    // Everything concatenated: the large-file case, and the only sample big
    // enough for the per-byte numbers to mean much.
    const whole: Case = .{
        .path = "<corpus>",
        .text = corpus.items,
        .hl = highlight.Highlighter.choose(paths[0], corpus.items.len, countLines(corpus.items)),
        .lines = countLines(corpus.items),
    };

    try w.print("lgtm lexer benchmark - {d} file(s) under {s}/, {d} lines, {d} bytes\n", .{
        paths.len, root, whole.lines, whole.text.len,
    });
    try w.print("optimize: {t}, best-of over >= {d} iterations\n\n", .{
        @import("builtin").mode, min_iterations,
    });

    try w.writeAll("file                             lines   structure      full lex        screen\n");
    try w.writeAll("                                          ms  ns/ln       ms  MB/s     us/screen\n");

    var all: std.ArrayList(Case) = .empty;
    defer all.deinit(gpa);
    try all.appendSlice(gpa, cases.items);
    try all.append(gpa, whole);

    for (all.items) |c| {
        var st = try c.hl.structure(gpa, c.text);
        defer st.deinit(gpa);

        const s = try benchStructure(io, gpa, c);
        const f = try benchFullLex(io, gpa, c);
        const scr = try benchScreen(io, gpa, c, st);

        const name = if (c.path.len > 30) c.path[c.path.len - 30 ..] else c.path;
        try w.print("{s: <30} {d: >6}  {d: >8.3} {d: >6.0} {d: >8.3} {d: >5.0} {d: >13.1}\n", .{
            name,
            c.lines,
            ms(s.ns),
            perLine(s.ns, c.lines),
            ms(f.ns),
            mbPerSec(f.ns, c.text.len),
            @as(f64, @floatFromInt(scr.ns)) / 1000.0,
        });
    }

    const hit = try benchCacheHit(io, gpa, whole);
    try w.print("\ncache hit on the corpus: {d} ns\n", .{hit.ns});

    // Budgets restated so a regression is visible without opening the docs.
    const s_whole = try benchStructure(io, gpa, whole);
    const f_whole = try benchFullLex(io, gpa, whole);
    try w.print("\nagainst budgets\n", .{});
    try w.print("  structure, {d} lines: {d:.3} ms   {s} (re-diff budget 100 ms)\n", .{
        whole.lines, ms(s_whole.ns), if (ms(s_whole.ns) <= 100) "ok" else "OVER",
    });
    try w.print("  full lex,  {d} lines: {d:.3} ms   {s} (frame budget 8 ms)\n", .{
        whole.lines, ms(f_whole.ns), if (ms(f_whole.ns) <= 8) "ok" else "OVER",
    });

    try w.print("\nchecksum {d}\n", .{sink});
    try w.flush();
    return 0;
}
