// SPDX-License-Identifier: Apache-2.0
//
// Replays recorded edit sequences and reports the re-anchor hit rate. This is
// the go/no-go gate for review comments: below roughly 90%
// the feature gets redesigned rather than built on.

const std = @import("std");
const Allocator = std.mem.Allocator;
const lgtm = @import("lgtm");
const fs = lgtm.fs;
const anchor = lgtm.anchor;

const gate_hit_rate = 0.90;
const budget_ns_per_50_notes = 5 * std.time.ns_per_ms;
const max_file = 4 << 20;

const Expect = struct {
    id: []const u8,
    /// One per version, including v0. null means the note must go stale.
    lines: []?u32,
};

const Fixture = struct {
    name: []const u8,
    versions: [][]u8,
    expects: []Expect,
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var out_buf: [64 << 10]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &out_buf);
    const w = &fw.interface;

    var args = init.minimal.args.iterate();
    _ = args.next();
    const root = args.next() orelse "tests/fixtures";

    const entries = try fs.listDir(io, gpa, root);
    defer fs.freeNames(gpa, entries);

    var total: usize = 0;
    var hits: usize = 0;
    var elapsed_ns: u64 = 0;
    var migrations: usize = 0;
    var failed_fixtures: usize = 0;
    var tally: Tally = .{};

    try w.print("anchor harness: {s}\n\n", .{root});
    try w.print("{s: <22} {s: >7} {s: >7}  {s}\n", .{ "fixture", "hits", "total", "misses" });
    try w.writeAll("-" ** 64 ++ "\n");

    for (entries) |name| {
        if (std.mem.startsWith(u8, name, ".")) continue;
        var fx = loadFixture(io, gpa, root, name) catch |err| switch (err) {
            error.NotAFixture => continue,
            else => {
                try w.print("{s: <22}  LOAD FAILED: {t}\n", .{ name, err });
                failed_fixtures += 1;
                continue;
            },
        };
        defer freeFixture(gpa, &fx);

        const r = try run(gpa, io, &fx, w, &tally);
        total += r.total;
        hits += r.hits;
        elapsed_ns += r.ns;
        migrations += r.migrations;
    }

    try w.writeAll("-" ** 64 ++ "\n");
    if (total == 0) {
        try w.writeAll("no expectations found\n");
        try w.flush();
        return 1;
    }

    const rate = @as(f64, @floatFromInt(hits)) / @as(f64, @floatFromInt(total));
    try w.print("\nhit rate      {d:.1}%  ({d}/{d})\n", .{ rate * 100, hits, total });
    try tally.report(w);

    try w.print("index builds  {d} (lazy: only built when the line map misses)\n", .{anchor.Version.index_builds});

    if (migrations > 0) {
        const per_note = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(migrations));
        const per_50 = per_note * 50;
        try w.print("re-anchor     {d:.0} ns per note, {d:.3} ms per 50 notes (budget 5 ms)\n", .{ per_note, per_50 / std.time.ns_per_ms });
        if (per_50 > budget_ns_per_50_notes) try w.writeAll("              OVER BUDGET\n");
    }

    if (failed_fixtures > 0) {
        try w.print("\n{d} fixture(s) failed to load\n", .{failed_fixtures});
        try w.flush();
        return 1;
    }
    if (rate < gate_hit_rate) {
        try w.print("\nGATE FAILED: {d:.1}% is below the {d:.0}% review comments need.\n", .{ rate * 100, gate_hit_rate * 100 });
        try w.writeAll("Stop and redesign review notes before building on this.\n");
        try w.flush();
        return 1;
    }
    try w.writeAll("\nGATE PASSED\n");
    try w.flush();
    return 0;
}

const Result = struct { total: usize, hits: usize, ns: u64, migrations: usize };

fn run(gpa: Allocator, io: std.Io, fx: *Fixture, w: *std.Io.Writer, tally: *Tally) !Result {
    var exact_interner: anchor.Interner = .{};
    defer exact_interner.deinit(gpa);
    var norm_interner: anchor.Interner = .{};
    defer norm_interner.deinit(gpa);
    var norm_arena: std.heap.ArenaAllocator = .init(gpa);
    defer norm_arena.deinit();

    const versions = try gpa.alloc(anchor.Version, fx.versions.len);
    defer {
        for (versions) |*v| v.deinit(gpa);
        gpa.free(versions);
    }
    for (fx.versions, 0..) |text, i| {
        versions[i] = try anchor.Version.init(gpa, &exact_interner, &norm_interner, norm_arena.allocator(), text);
    }

    var anchors = try gpa.alloc(anchor.Anchor, fx.expects.len);
    defer gpa.free(anchors);
    for (fx.expects, 0..) |e, i| anchors[i] = .init(versions[0], e.lines[0].?);

    var res: Result = .{ .total = 0, .hits = 0, .ns = 0, .migrations = 0 };
    var miss_buf: std.ArrayList(u8) = .empty;
    defer miss_buf.deinit(gpa);

    var v: usize = 1;
    while (v < fx.versions.len) : (v += 1) {
        var map = try anchor.lineMap(gpa, versions[v - 1].ids, versions[v].ids);
        defer map.deinit(gpa);

        const start = std.Io.Timestamp.now(io, .awake);
        for (anchors) |*a| {
            const outcome = try a.reanchor(gpa, map, &versions[v]);
            tally.count(outcome);
        }
        const end = std.Io.Timestamp.now(io, .awake);
        res.ns += @intCast(@max(0, start.durationTo(end).nanoseconds));
        res.migrations += anchors.len;

        for (fx.expects, anchors) |e, a| {
            res.total += 1;
            const want = e.lines[v];
            const ok = if (want) |line| (!a.stale and a.line == line) else a.stale;
            if (ok) {
                res.hits += 1;
            } else {
                const got_desc = if (a.stale) "stale" else "line";
                const msg = try std.fmt.allocPrint(gpa, "      {s} v{d}: want {?d}, got {s} {d}\n", .{ e.id, v, want, got_desc, a.line });
                defer gpa.free(msg);
                try miss_buf.appendSlice(gpa, msg);
            }
        }
    }

    try w.print("{s: <22} {d: >7} {d: >7}  {s}\n", .{
        fx.name,
        res.hits,
        res.total,
        if (miss_buf.items.len == 0) "-" else "see below",
    });
    if (miss_buf.items.len > 0) try w.writeAll(miss_buf.items);
    return res;
}

/// Which tier placed each note. Recorded so the unbuilt tiers stay scoped by
/// evidence rather than speculation.
const Tally = struct {
    counts: [@typeInfo(anchor.Outcome).@"enum".fields.len]usize = @splat(0),

    fn count(self: *Tally, o: anchor.Outcome) void {
        self.counts[@intFromEnum(o)] += 1;
    }

    fn report(self: Tally, w: *std.Io.Writer) !void {
        try w.writeAll("\nresolved by\n");
        inline for (@typeInfo(anchor.Outcome).@"enum".fields) |f| {
            const n = self.counts[f.value];
            if (n > 0) try w.print("  {s: <18} {d}\n", .{ f.name, n });
        }
    }
};

fn loadFixture(io: std.Io, gpa: Allocator, root: []const u8, name: []const u8) !Fixture {
    const dir = try std.fs.path.join(gpa, &.{ root, name });
    defer gpa.free(dir);

    const notes_path = try std.fs.path.join(gpa, &.{ dir, "notes.txt" });
    defer gpa.free(notes_path);
    if (!fs.fileExists(io, notes_path)) return error.NotAFixture;

    // Versions, in numeric order.
    var versions: std.ArrayList([]u8) = .empty;
    errdefer {
        for (versions.items) |v| gpa.free(v);
        versions.deinit(gpa);
    }
    var n: usize = 0;
    while (true) : (n += 1) {
        const vp = try std.fmt.allocPrint(gpa, "{s}/v{d}.txt", .{ dir, n });
        defer gpa.free(vp);
        if (!fs.fileExists(io, vp)) break;
        try versions.append(gpa, try fs.readFile(io, gpa, vp, max_file));
    }
    if (versions.items.len < 2) return error.NeedTwoVersions;

    const notes = try fs.readFile(io, gpa, notes_path, max_file);
    defer gpa.free(notes);

    var expects: std.ArrayList(Expect) = .empty;
    errdefer {
        for (expects.items) |e| {
            gpa.free(e.id);
            gpa.free(e.lines);
        }
        expects.deinit(gpa);
    }

    var it = std.mem.splitScalar(u8, notes, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        var field = std.mem.tokenizeAny(u8, line, " \t");
        const id = field.next() orelse continue;
        var lines: std.ArrayList(?u32) = .empty;
        errdefer lines.deinit(gpa);
        while (field.next()) |tok| {
            if (std.mem.eql(u8, tok, "stale")) {
                try lines.append(gpa, null);
            } else {
                try lines.append(gpa, try std.fmt.parseInt(u32, tok, 10));
            }
        }
        if (lines.items.len != versions.items.len) return error.ArityMismatch;
        if (lines.items[0] == null) return error.NoteStartsStale;

        try expects.append(gpa, .{
            .id = try gpa.dupe(u8, id),
            .lines = try lines.toOwnedSlice(gpa),
        });
    }
    if (expects.items.len == 0) return error.NoExpectations;

    const fx: Fixture = .{
        .name = name,
        .versions = try versions.toOwnedSlice(gpa),
        .expects = try expects.toOwnedSlice(gpa),
    };
    try validate(fx);
    return fx;
}

/// Hand-written expectations are wrong often enough that scoring against a bad
/// one would silently corrupt the gate. Every expected line must hold the same
/// content as the v0 anchor, ignoring leading whitespace.
fn validate(fx: Fixture) !void {
    for (fx.expects) |e| {
        const base = try nthLine(fx.versions[0], e.lines[0].?);
        if (isWeakAnchor(base)) return error.WeakAnchor;
        for (e.lines, 0..) |maybe, v| {
            const want = maybe orelse continue;
            const got = try nthLine(fx.versions[v], want);
            if (!std.mem.eql(u8, std.mem.trim(u8, got, " \t"), std.mem.trim(u8, base, " \t"))) {
                return error.ExpectationContentMismatch;
            }
        }
    }
}

/// A bare brace or blank line recurs many times per file and makes a fixture
/// pass or fail for reasons unrelated to what it tests.
fn isWeakAnchor(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t");
    if (t.len == 0) return true;
    for (t) |c| if (std.mem.indexOfScalar(u8, "}){];,", c) == null) return false;
    return true;
}

fn nthLine(text: []const u8, one_based: u32) ![]const u8 {
    if (one_based == 0) return error.LineOutOfRange;
    var it = std.mem.splitScalar(u8, text, '\n');
    var i: u32 = 0;
    while (it.next()) |line| {
        i += 1;
        if (i == one_based) return std.mem.trimEnd(u8, line, "\r");
    }
    return error.LineOutOfRange;
}

fn freeFixture(gpa: Allocator, fx: *Fixture) void {
    for (fx.versions) |v| gpa.free(v);
    gpa.free(fx.versions);
    for (fx.expects) |e| {
        gpa.free(e.id);
        gpa.free(e.lines);
    }
    gpa.free(fx.expects);
}
