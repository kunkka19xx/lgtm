// SPDX-License-Identifier: Apache-2.0
//
// What the turn list shows: one row per turn, read from the object store.
//
// SNAPSHOTS.md 5.3b-c. The rule that shapes this file is that **the list is
// built from the commit chain, never from parsed diffs**. A list that parsed
// forty diffs to draw itself is the version of this feature that takes a week
// and then feels slow.
//
// Two subprocesses, whatever the number of turns:
//
//   git for-each-ref  -> which commit is which turn
//   git log --numstat -> what each turn changed, and when
//
// `git log` walks the parent chain, and the chain is ours: turn N's parent is
// turn N-1, and turn 1's is the baseline. So one walk from the newest ref
// yields the whole session in order, with per-turn file counts and line counts
// that git computed rather than that we parsed.
//
// Pure of the screen: this knows nothing about rails, glyphs or elision. It
// answers what happened, and `ui/` decides how much of it fits.

const std = @import("std");
const Allocator = std.mem.Allocator;

const proc = @import("../io/proc.zig");
const gitobj = @import("gitobj.zig");
const snapshot = @import("snapshot.zig");

/// One turn, as a row wants it.
pub const Turn = struct {
    number: u32,
    /// Committer date, seconds since the epoch. Rendered as an age, because
    /// "2m ago" is the question being asked of a turn and a timestamp is a
    /// lookup (SNAPSHOTS.md 5.3a).
    when_s: i64 = 0,
    files: u32 = 0,
    added: u32 = 0,
    removed: u32 = 0,
    /// The largest changed file, which is what makes a turn recognisable at a
    /// glance. Borrowed from the caller's buffer.
    path: []const u8 = "",
    /// This turn walked a file back to a blob an earlier turn already had, so
    /// the agent undid its own work. The single most useful thing anyone can
    /// tell a reviewer of agent output, and `==` on two hashes to find
    /// (SNAPSHOTS.md 5.3c) - though nothing computes it yet.
    reverted: bool = false,
};

pub const Error = gitobj.Error;

/// Every turn of `session`, newest first. Caller owns both the text and the
/// slice; every `path` borrows from the text.
pub fn read(
    gpa: Allocator,
    io: std.Io,
    session: []const u8,
    newest: u32,
) Error!struct { text: []u8, turns: []Turn } {
    var ref_buf: [128]u8 = undefined;
    const head_ref = gitobj.refFor(&ref_buf, session, newest) catch return error.GitFailed;

    // `%x00` rather than a newline between the fields: a commit subject cannot
    // contain a NUL, and this parser then never has to guess whether a line is
    // a header or a numstat row.
    const out = try proc.run(gpa, io, &.{
        "git",                 "log",
        "--format=%x00%H %ct", "--numstat",
        head_ref,
    }, 8 << 20);
    errdefer out.deinit(gpa);
    if (out.exit_code != 0) {
        out.deinit(gpa);
        return error.GitFailed;
    }
    gpa.free(out.stderr);
    const text = out.stdout;
    errdefer gpa.free(text);

    // One call for every ref and the commit it points at. Resolving them one
    // at a time was the first version and was a subprocess per ref per commit,
    // which is quadratic in the length of a session.
    const refs = try gitobj.listRefOids(gpa, io);
    defer gpa.free(refs.text);
    defer gpa.free(refs.pairs);

    var turns: std.ArrayList(Turn) = .empty;
    errdefer turns.deinit(gpa);

    var records = std.mem.splitScalar(u8, text, 0);
    _ = records.next(); // before the first NUL there is nothing
    while (records.next()) |rec| {
        var lines = std.mem.splitScalar(u8, rec, '\n');
        const header = lines.next() orelse continue;
        const sp = std.mem.indexOfScalar(u8, header, ' ') orelse continue;
        const oid = header[0..sp];

        const number = turnFor(refs.pairs, session, oid) orelse continue;
        var turn: Turn = .{
            .number = number,
            .when_s = std.fmt.parseInt(i64, std.mem.trim(u8, header[sp + 1 ..], " \r"), 10) catch 0,
        };

        var biggest: u32 = 0;
        while (lines.next()) |line| {
            const row = std.mem.trim(u8, line, " \r");
            if (row.len == 0) continue;
            // `<added> TAB <removed> TAB <path>`, with `-` for a binary file.
            var it = std.mem.splitScalar(u8, row, '\t');
            const a = it.next() orelse continue;
            const r = it.next() orelse continue;
            const p = it.next() orelse continue;
            const added = std.fmt.parseInt(u32, a, 10) catch 0;
            const removed = std.fmt.parseInt(u32, r, 10) catch 0;
            turn.files += 1;
            turn.added += added;
            turn.removed += removed;
            if (added + removed >= biggest) {
                biggest = added + removed;
                turn.path = p;
            }
        }
        try turns.append(gpa, turn);
    }
    return .{ .text = text, .turns = try turns.toOwnedSlice(gpa) };
}

/// The turn number for a commit id, from the ref list already read.
pub fn turnFor(pairs: []const gitobj.Entry, session: []const u8, oid: []const u8) ?u32 {
    for (pairs) |pair| {
        if (!std.mem.eql(u8, pair.oid, oid)) continue;
        return snapshot.turnOf(pair.path, session);
    }
    return null;
}

/// "2m ago", "3h ago", "just now". The question a reader asks of a turn.
///
/// Coarse on purpose: the difference between 118 and 121 seconds is not a fact
/// anyone acts on, and a row that changes while being read is a row that draws
/// the eye for nothing.
pub fn age(buf: []u8, when_s: i64, now_s: i64) []const u8 {
    const d = now_s - when_s;
    if (when_s == 0 or d < 0) return "";
    if (d < 60) return "just now";
    if (d < 3600) return std.fmt.bufPrint(buf, "{d}m ago", .{@divTrunc(d, 60)}) catch "";
    if (d < 86400) return std.fmt.bufPrint(buf, "{d}h ago", .{@divTrunc(d, 3600)}) catch "";
    return std.fmt.bufPrint(buf, "{d}d ago", .{@divTrunc(d, 86400)}) catch "";
}

const testing = std.testing;

test "an age is coarse, because the exact second is not a fact anyone acts on" {
    var buf: [32]u8 = undefined;
    const now: i64 = 1_000_000;
    try testing.expectEqualStrings("just now", age(&buf, now - 5, now));
    try testing.expectEqualStrings("just now", age(&buf, now - 59, now));
    try testing.expectEqualStrings("2m ago", age(&buf, now - 120, now));
    try testing.expectEqualStrings("59m ago", age(&buf, now - 3599, now));
    try testing.expectEqualStrings("3h ago", age(&buf, now - 3600 * 3, now));
    try testing.expectEqualStrings("2d ago", age(&buf, now - 86400 * 2, now));

    // A turn with no date, and a clock that went backwards, both say nothing
    // rather than guessing. An age is the only column a reader trusts without
    // checking, so it must not be the one that lies.
    try testing.expectEqualStrings("", age(&buf, 0, now));
    try testing.expectEqualStrings("", age(&buf, now + 60, now));
}

test "a commit is mapped back to its turn, and only within this session" {
    const pairs = [_]gitobj.Entry{
        .{ .oid = "aaa111", .path = "refs/lgtm/s1/0" },
        .{ .oid = "bbb222", .path = "refs/lgtm/s1/1" },
        .{ .oid = "ccc333", .path = "refs/lgtm/other/9" },
    };
    try testing.expectEqual(@as(u32, 0), turnFor(&pairs, "s1", "aaa111").?);
    try testing.expectEqual(@as(u32, 1), turnFor(&pairs, "s1", "bbb222").?);
    // Another session's commits are in the object store and are not this
    // session's history; a walk that picked them up would show somebody else's
    // afternoon as though it were this one.
    try testing.expect(turnFor(&pairs, "s1", "ccc333") == null);
    try testing.expect(turnFor(&pairs, "s1", "unknown") == null);
}
