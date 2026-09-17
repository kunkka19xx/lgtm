// SPDX-License-Identifier: Apache-2.0
//
// Instrument before optimising. Compiled out entirely
// unless -Dprofile, so spans may be left in hot paths permanently.
//
// Zig 0.16 moved clocks into std.Io, so timing needs an Io handle. It is set
// once at startup rather than threaded through every call site.

const std = @import("std");
const build_options = @import("build_options");

pub const enabled = build_options.profile;

var handle: ?std.Io = null;

pub fn init(io: std.Io) void {
    if (!enabled) return;
    handle = io;
}

pub const Kind = enum {
    /// The whole re-diff: the git call, reading both sides, attaching them,
    /// the checkpoint and the risk scan all happen inside it. It was called
    /// `diff_parse` while parsing unified diff text was under a twentieth of
    /// it, which sent every reading of this report at the wrong thing.
    rediff,
    git_subprocess,
    /// Reading both sides of every changed file: the HEAD blobs out of
    /// `cat-file --batch`, the working copies off disk. Split from
    /// `git_subprocess`, which only covers the diff itself, because the two
    /// have completely different fixes if either turns out to be the cost.
    source_load,
    /// Verifying every diff line against the buffer it came from, and
    /// indexing line starts. Pure CPU over bytes already in memory.
    attach,
    /// Recomputing what changed since the mark, over every file in the review.
    /// Its own span because it is the one thing a mark adds to every re-diff,
    /// and the whole argument for doing it this way is that it is a line map
    /// rather than a second diff.
    checkpoint,
    /// Reading every file's diff for a weakened test. Its own span because the
    /// claim made for it is that it is a pass over lines already in memory,
    /// and a claim like that should be checkable.
    test_risk,
    reanchor,
    frame,
    render,
    layout,
    lex,

    pub const count = @typeInfo(Kind).@"enum".fields.len;
};

const Stat = struct {
    calls: u64 = 0,
    total_ns: u64 = 0,
    /// Time spent inside spans opened within this one, so that `total - child`
    /// is the time this span is actually answerable for.
    child_ns: u64 = 0,
    max_ns: u64 = 0,
};

var stats: [Kind.count]Stat = @splat(.{});

/// Nanoseconds charged to each open span by the spans closed inside it,
/// innermost last.
///
/// Nesting is a fact about the call path, not about the kind: `checkpoint`
/// runs inside a re-diff and also on its own, so which span is whose parent
/// can only be known while both are open.
var stack: [max_depth]u64 = @splat(0);
var depth: u32 = 0;

const max_depth = 16;
/// A span nested deeper than the stack goes, or raised before `init`. It still
/// records its own time; it just does not take part in the accounting.
const untracked = std.math.maxInt(u32);

pub const Span = struct {
    kind: Kind,
    start: std.Io.Timestamp,
    /// Where this span sits in `stack`, so `end` can unwind to it.
    index: u32 = untracked,

    pub fn end(self: Span) void {
        if (!enabled) return;
        const io = handle orelse return;
        const now = std.Io.Timestamp.now(io, .awake);
        const elapsed = self.start.durationTo(now).nanoseconds;
        const ns: u64 = @intCast(@max(0, elapsed));

        // Unwind to this span's frame rather than popping one. Not every span
        // ends under a `defer`, so one skipped on an error path would stay open
        // for the rest of the process and collect every later span as a child.
        var child_ns: u64 = 0;
        if (self.index != untracked and self.index < depth) {
            child_ns = stack[self.index];
            depth = self.index;
            if (depth > 0) stack[depth - 1] += ns;
        }

        const s = &stats[@intFromEnum(self.kind)];
        s.calls += 1;
        s.total_ns += ns;
        s.child_ns += child_ns;
        if (ns > s.max_ns) s.max_ns = ns;
    }
};

pub inline fn span(comptime kind: Kind) Span {
    if (!enabled) return .{ .kind = kind, .start = .zero };
    const io = handle orelse return .{ .kind = kind, .start = .zero };
    var index: u32 = untracked;
    if (depth < max_depth) {
        index = depth;
        stack[depth] = 0;
        depth += 1;
    }
    return .{ .kind = kind, .start = .now(io, .awake), .index = index };
}

/// The budgets, used to flag regressions in the report.
fn budgetMs(kind: Kind) ?f64 {
    return switch (kind) {
        .frame => 8.0,
        .rediff, .git_subprocess => 100.0,
        .reanchor => 5.0,
        // Part of the 100 ms re-diff, so it gets a slice of it rather than a
        // budget of its own size.
        .checkpoint => 20.0,
        .test_risk => 10.0,
        else => null,
    };
}

pub fn report(w: *std.Io.Writer) !void {
    if (!enabled) {
        try w.writeAll("lgtm: built without -Dprofile, no metrics collected\n");
        return;
    }
    // Spans nest, so the totals overlap: `rediff` already contains the git
    // call, the source load, the attach and the risk scan. Adding the total
    // column up counts those three times over, which is exactly the reading
    // this column set exists to prevent. `self` is the span's own time with
    // everything opened inside it taken out, and those do sum.
    try w.writeByte('\n');
    try w.print("{s: <18} {s: >5} {s: >14} {s: >14} {s: >14}\n", .{
        "span", "calls", "total ms", "self ms", "max ms",
    });
    for (stats, 0..) |s, i| {
        if (s.calls == 0) continue;
        const kind: Kind = @enumFromInt(i);
        const total_ms = @as(f64, @floatFromInt(s.total_ns)) / std.time.ns_per_ms;
        const self_ms = @as(f64, @floatFromInt(s.total_ns - s.child_ns)) / std.time.ns_per_ms;
        const max_ms = @as(f64, @floatFromInt(s.max_ns)) / std.time.ns_per_ms;
        const over: []const u8 = if (budgetMs(kind)) |b| (if (max_ms > b) "  OVER" else "") else "";
        try w.print("{s: <18} {d: >5} {d: >14.3} {d: >14.3} {d: >14.3}{s}\n", .{
            @tagName(kind), s.calls, total_ms, self_ms, max_ms, over,
        });
    }
    try w.writeAll("\ntotals nest and must not be added up; self times do.\n");
}

test "a nested span is taken out of its parent's self time" {
    if (!enabled) return;
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    init(threaded.io());

    const outer_before = stats[@intFromEnum(Kind.rediff)];
    const inner_before = stats[@intFromEnum(Kind.test_risk)];

    const outer = span(.rediff);
    const inner = span(.test_risk);
    inner.end();
    outer.end();

    const o = stats[@intFromEnum(Kind.rediff)];
    const i = stats[@intFromEnum(Kind.test_risk)];
    const inner_ns = i.total_ns - inner_before.total_ns;
    const outer_child = o.child_ns - outer_before.child_ns;

    // The inner span's whole elapsed time is charged to the outer one, so the
    // outer's self time is what is left of it.
    try std.testing.expectEqual(inner_ns, outer_child);
    // And the inner span, having nothing inside it, is all self.
    try std.testing.expectEqual(inner_before.child_ns, i.child_ns);
    // The stack is balanced again, or every later span becomes a child.
    try std.testing.expectEqual(@as(u32, 0), depth);
}

test "a span whose end is skipped does not adopt every later span" {
    if (!enabled) return;
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    init(threaded.io());

    // `git_subprocess` and `source_load` do not end under a `defer`, so an
    // error path between them leaves one open. Ending the outer span has to
    // unwind past it rather than pop one frame.
    const outer = span(.rediff);
    _ = span(.git_subprocess); // never ended
    outer.end();
    try std.testing.expectEqual(@as(u32, 0), depth);

    const before = stats[@intFromEnum(Kind.lex)];
    const after_leak = span(.lex);
    after_leak.end();
    const s = stats[@intFromEnum(Kind.lex)];
    // Charged to nobody: the leaked frame is gone, not still open above it.
    try std.testing.expectEqual(before.child_ns, s.child_ns);
    try std.testing.expectEqual(@as(u32, 0), depth);
}

test "span is inert when metrics are disabled" {
    const before = stats[@intFromEnum(Kind.lex)].calls;
    const s = span(.lex);
    s.end();
    if (!enabled) try std.testing.expectEqual(before, stats[@intFromEnum(Kind.lex)].calls);
}

test "span records a call when enabled" {
    if (!enabled) return;
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    init(threaded.io());

    const before = stats[@intFromEnum(Kind.layout)].calls;
    const s = span(.layout);
    s.end();
    try std.testing.expectEqual(before + 1, stats[@intFromEnum(Kind.layout)].calls);
}
