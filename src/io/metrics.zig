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
    git_subprocess,
    diff_parse,
    reanchor,
    /// Recomputing what changed since the mark, over every file in the review.
    /// Its own span because it is the one thing a mark adds to every re-diff,
    /// and the whole argument for doing it this way is that it is a line map
    /// rather than a second diff.
    checkpoint,
    /// Reading every file's diff for a weakened test. Its own span because the
    /// claim made for it is that it is a pass over lines already in memory,
    /// and a claim like that should be checkable.
    test_risk,
    /// Reading both sides of every changed file: the HEAD blobs out of
    /// `cat-file --batch`, the working copies off disk. Split from
    /// `git_subprocess`, which only covers the diff itself, because the two
    /// have completely different fixes if either turns out to be the cost.
    source_load,
    /// Verifying every diff line against the buffer it came from, and
    /// indexing line starts. Pure CPU over bytes already in memory.
    attach,
    lex,
    layout,
    render,
    frame,

    pub const count = @typeInfo(Kind).@"enum".fields.len;
};

const Stat = struct {
    calls: u64 = 0,
    total_ns: u64 = 0,
    max_ns: u64 = 0,
};

var stats: [Kind.count]Stat = @splat(.{});

pub const Span = struct {
    kind: Kind,
    start: std.Io.Timestamp,

    pub fn end(self: Span) void {
        if (!enabled) return;
        const io = handle orelse return;
        const now = std.Io.Timestamp.now(io, .awake);
        const elapsed = self.start.durationTo(now).nanoseconds;
        const ns: u64 = @intCast(@max(0, elapsed));

        const s = &stats[@intFromEnum(self.kind)];
        s.calls += 1;
        s.total_ns += ns;
        if (ns > s.max_ns) s.max_ns = ns;
    }
};

pub inline fn span(comptime kind: Kind) Span {
    if (!enabled) return .{ .kind = kind, .start = .zero };
    const io = handle orelse return .{ .kind = kind, .start = .zero };
    return .{ .kind = kind, .start = .now(io, .awake) };
}

/// The budgets, used to flag regressions in the report.
fn budgetMs(kind: Kind) ?f64 {
    return switch (kind) {
        .frame => 8.0,
        .git_subprocess, .diff_parse => 100.0,
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
    try w.writeAll("\nspan                calls       total ms         avg ms         max ms\n");
    for (stats, 0..) |s, i| {
        if (s.calls == 0) continue;
        const kind: Kind = @enumFromInt(i);
        const total_ms = @as(f64, @floatFromInt(s.total_ns)) / std.time.ns_per_ms;
        const avg_ms = total_ms / @as(f64, @floatFromInt(s.calls));
        const max_ms = @as(f64, @floatFromInt(s.max_ns)) / std.time.ns_per_ms;
        const over: []const u8 = if (budgetMs(kind)) |b| (if (max_ms > b) "  OVER" else "") else "";
        try w.print("{s: <18} {d: >5} {d: >14.3} {d: >14.3} {d: >14.3}{s}\n", .{
            @tagName(kind), s.calls, total_ms, avg_ms, max_ms, over,
        });
    }
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
