// SPDX-License-Identifier: Apache-2.0
//
// What the turn list shows: one row per turn, read from the object store.
//
// The rule that shapes this file is that **the list is
// built from the commit chain, never from parsed diffs**. A list that parsed
// forty diffs to draw itself is the version of this feature that takes a week
// and then feels slow.
//
// Two subprocesses, whatever the number of turns:
//
//   git for-each-ref        -> which commit is which turn
//   git log --numstat --raw -> what each turn changed, when, and to which blob
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
    /// lookup.
    when_s: i64 = 0,
    files: u32 = 0,
    added: u32 = 0,
    removed: u32 = 0,
    /// The largest changed file, which is what makes a turn recognisable at a
    /// glance. Borrowed from the caller's buffer.
    path: []const u8 = "",
    /// This turn walked a file back to a blob an earlier turn already had, so
    /// the agent undid its own work.
    ///
    /// The single most useful thing anyone can tell a reviewer of agent
    /// output, and no other tool in this space can: round-tripping is what
    /// agents do when they are stuck, and it is nearly invisible in a diff
    /// because a diff only shows the endpoints. Every snapshot is a git tree,
    /// so this is `==` on two hashes rather than a heuristic or a second diff.
    reverted: bool = false,
    /// Which turn it went back to, when it did. The useful half of the
    /// message: "back to 4" says how far the agent unwound.
    reverted_to: u32 = 0,
    /// This turn touched a file the caller is watching - in practice, one
    /// carrying a comment the reader has already sent. So this is the agent
    /// *responding to you*, as against doing something else.
    ///
    /// **File granularity, not line.** `SNAPSHOTS.md` 5.3c calls it a range
    /// intersection, and that would be better - but the line ranges are not
    /// here. This file's rule is one `git log` however long the session is,
    /// and `--numstat` counts lines without saying which; getting ranges means
    /// `-p` and parsing forty patches, which is exactly the version of this
    /// feature the rule exists to prevent. Touching the file you commented on
    /// is most of the signal and costs nothing: the per-turn path set is
    /// already being collected for `reverted`.
    answered: bool = false,
};

pub const Error = gitobj.Error;

/// Every turn of `session`, newest first. Caller owns both the text and the
/// slice; every `path` borrows from the text.
pub fn read(
    gpa: Allocator,
    io: std.Io,
    session: []const u8,
    newest: u32,
    /// Paths worth noticing a turn touched. The caller's business what they
    /// mean; this file only reports which turns touched one, which keeps it
    /// ignorant of what a comment is.
    watching: []const []const u8,
) Error!struct { text: []u8, turns: []Turn } {
    var ref_buf: [128]u8 = undefined;
    const head_ref = gitobj.refFor(&ref_buf, session, newest) catch return error.GitFailed;

    // `%x00` between records and `%x01` after the body: a commit message can
    // hold neither, so the parser never has to guess whether a line is a
    // header, one of the turn's paths, or a numstat row.
    // `--raw` alongside `--numstat`, which costs nothing: the same walk that
    // counts lines also prints each file's before and after blob, and those
    // ids are what makes a self-revert detectable. `--no-abbrev` because two
    // abbreviated ids that match may still be two different blobs.
    const out = try proc.run(gpa, io, &.{
        "git",                         "log",
        "--format=%x00%H %ct%n%B%x01", "--numstat",
        "--raw",                       "--no-abbrev",
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

    // One entry per file per turn, for the self-revert pass below. Borrows
    // from `text` like everything else here, and is dropped on the way out -
    // only the two booleans it produces are kept.
    var blobs: std.ArrayList(Blob) = .empty;
    defer blobs.deinit(gpa);

    var records = std.mem.splitScalar(u8, text, 0);
    _ = records.next(); // before the first NUL there is nothing
    while (records.next()) |rec| {
        // The body ends at \x01; the numstat follows it.
        const split = std.mem.indexOfScalar(u8, rec, 1) orelse continue;
        var lines = std.mem.splitScalar(u8, rec[0..split], '\n');
        const header = lines.next() orelse continue;
        const sp = std.mem.indexOfScalar(u8, header, ' ') orelse continue;
        const oid = header[0..sp];

        const number = turnFor(refs.pairs, session, oid) orelse continue;
        var turn: Turn = .{
            .number = number,
            .when_s = std.fmt.parseInt(i64, std.mem.trim(u8, header[sp + 1 ..], " \r"), 10) catch 0,
        };

        // Everything after the subject is the paths this turn staged. A turn
        // written before they were recorded has none, and then nothing is
        // filtered - an old row keeps reading as it always did rather than
        // reading as empty.
        const staged = lines.rest();
        const filter = std.mem.trim(u8, staged, " \r\n").len > 0;

        var biggest: u32 = 0;
        var rows = std.mem.splitScalar(u8, rec[split + 1 ..], '\n');
        while (rows.next()) |line| {
            const row = std.mem.trim(u8, line, " \r");
            if (row.len == 0) continue;
            // `:<mode> <mode> <old> <new> <status>\t<path>` - the raw half of
            // the same output. Recorded and skipped; the numstat row below is
            // what the counts come from.
            if (row[0] == ':') {
                if (rawBlob(row)) |b| {
                    if (filter and !stagedHas(staged, b.path)) continue;
                    blobs.append(gpa, .{
                        .turn = @intCast(turns.items.len),
                        .path = b.path,
                        .sha = b.sha,
                    }) catch {};
                }
                continue;
            }
            // `<added> TAB <removed> TAB <path>`, with `-` for a binary file.
            var it = std.mem.splitScalar(u8, row, '\t');
            const a = it.next() orelse continue;
            const r = it.next() orelse continue;
            const p = it.next() orelse continue;

            // Not one of this turn's paths, so not this turn's doing. The tree
            // diff picks these up whenever HEAD moves under the chain: a commit
            // between two turns otherwise reports its whole changeset as the
            // agent's work, which is what made one row claim 66 files.
            if (filter and !stagedHas(staged, p)) continue;

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

    markReverts(turns.items, blobs.items);
    markAnswers(turns.items, blobs.items, watching);
    return .{ .text = text, .turns = try turns.toOwnedSlice(gpa) };
}

/// Marks every turn that touched one of `watching`.
///
/// The same per-turn path set `markReverts` walks, asked a different question:
/// one says the agent went backwards, the other says it was listening. The
/// pair is most of what a reader wants from this list.
pub fn markAnswers(turns: []Turn, blobs: []const Blob, watching: []const []const u8) void {
    if (watching.len == 0) return;
    for (blobs) |b| {
        if (b.turn >= turns.len) continue;
        if (turns[b.turn].answered) continue;
        for (watching) |w| {
            if (std.mem.eql(u8, w, b.path)) {
                turns[b.turn].answered = true;
                break;
            }
        }
    }
}

/// One file's identity in one turn.
const Blob = struct {
    /// Index into `turns`, which is newest-first.
    turn: u32,
    path: []const u8,
    /// The blob this turn left the file at. Full, never abbreviated.
    sha: []const u8,
};

/// `:<mode> <mode> <old_sha> <new_sha> <status>\t<path>`.
///
/// The new sha and the path, or null for a row that is not one - a merge
/// prints a different shape, and a status this does not recognise is better
/// skipped than guessed at.
fn rawBlob(row: []const u8) ?struct { path: []const u8, sha: []const u8 } {
    const tab = std.mem.indexOfScalar(u8, row, '\t') orelse return null;
    var it = std.mem.tokenizeScalar(u8, row[1..tab], ' ');
    _ = it.next() orelse return null; // old mode
    _ = it.next() orelse return null; // new mode
    _ = it.next() orelse return null; // old sha
    const new = it.next() orelse return null;
    // A deleted file's new sha is all zeroes, which is not a blob any earlier
    // turn can have been at.
    if (new.len == 0 or std.mem.allEqual(u8, new, '0')) return null;
    const path = std.mem.trim(u8, row[tab + 1 ..], " \r");
    if (path.len == 0) return null;
    return .{ .path = path, .sha = new };
}

/// Marks every turn that walked a file back to a blob an earlier turn had.
///
/// `turns` is newest-first, so an *earlier* turn is one at a higher index. The
/// nearest such turn is the answer: "back to 4" should name where the file was
/// last at this content, not the first time it ever was.
///
/// Quadratic in files-times-turns, which is a few hundred entries for a
/// session of any length - and it is `==` on two hashes, not a diff. The whole
/// pass is under a millisecond on a session this list can display.
pub fn markReverts(turns: []Turn, blobs: []const Blob) void {
    for (blobs) |now| {
        var best: ?u32 = null;
        for (blobs) |then| {
            // Strictly older, and the same file at the same content.
            if (then.turn <= now.turn) continue;
            if (!std.mem.eql(u8, then.path, now.path)) continue;
            if (!std.mem.eql(u8, then.sha, now.sha)) continue;
            if (best == null or then.turn < best.?) best = then.turn;
        }
        const at = best orelse continue;
        if (now.turn >= turns.len or at >= turns.len) continue;
        // The nearest match wins, and a turn already marked keeps the nearer
        // of the two: one turn can walk two files back to two different
        // places, and the closer one is the more useful thing to say.
        if (turns[now.turn].reverted and turns[now.turn].reverted_to <= turns[at].number) continue;
        turns[now.turn].reverted = true;
        turns[now.turn].reverted_to = turns[at].number;
    }
}

/// Whether `path` is one of the newline-separated paths in `staged`.
///
/// A whole-line match: `src/a.zig` must not match `src/ab.zig`, and a suffix
/// match would let a row claim a file the turn never touched.
pub fn stagedHas(staged: []const u8, path: []const u8) bool {
    var it = std.mem.splitScalar(u8, staged, '\n');
    while (it.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \r"), path)) return true;
    }
    return false;
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

test "a turn that touched a commented file is the agent answering" {
    var turns = [_]Turn{ .{ .number = 3 }, .{ .number = 2 }, .{ .number = 1 } };
    const blobs = [_]Blob{
        .{ .turn = 0, .path = "src/auth.zig", .sha = "ccc" },
        .{ .turn = 1, .path = "docs/README.md", .sha = "bbb" },
        .{ .turn = 2, .path = "src/auth.zig", .sha = "aaa" },
    };
    // The reader has a sent comment on auth.zig, so the turns that touched it
    // are the agent responding and the one that did not is it doing something
    // else - which is the whole of FEATURES.md 1.4.
    markAnswers(&turns, &blobs, &.{"src/auth.zig"});

    try testing.expect(turns[0].answered);
    try testing.expect(!turns[1].answered);
    try testing.expect(turns[2].answered);
}

test "nothing to watch marks nothing" {
    var turns = [_]Turn{.{ .number = 1 }};
    const blobs = [_]Blob{.{ .turn = 0, .path = "a.zig", .sha = "aaa" }};
    // No comments sent is the ordinary state, and it must cost nothing and
    // claim nothing.
    markAnswers(&turns, &blobs, &.{});
    try testing.expect(!turns[0].answered);

    markAnswers(&turns, &blobs, &.{"b.zig"});
    try testing.expect(!turns[0].answered);
}

test "a raw row yields the path and the blob it was left at" {
    const got = rawBlob(":100644 100644 aaa111 bbb222 M\tsrc/ui/app.zig").?;
    try testing.expectEqualStrings("src/ui/app.zig", got.path);
    try testing.expectEqualStrings("bbb222", got.sha);

    // A deletion lands on the all-zero id, which is not a blob any earlier
    // turn can have been at - so it is not a revert target.
    try testing.expect(rawBlob(":100644 000000 aaa111 0000000000 D\tgone.zig") == null);
    // A numstat row is not a raw row.
    try testing.expect(rawBlob("12\t3\tsrc/ui/app.zig") == null);
}

test "a turn that walks a file back to an earlier blob is marked" {
    // Newest first, the way `git log` prints and the way `read` builds them.
    var turns = [_]Turn{
        .{ .number = 3 },
        .{ .number = 2 },
        .{ .number = 1 },
    };
    // Turn 3 leaves a.zig at the same content turn 1 did: the agent added
    // something in turn 2 and took it back out. Invisible in a diff, because a
    // diff only shows the endpoints.
    const blobs = [_]Blob{
        .{ .turn = 0, .path = "a.zig", .sha = "aaa" },
        .{ .turn = 1, .path = "a.zig", .sha = "bbb" },
        .{ .turn = 2, .path = "a.zig", .sha = "aaa" },
    };
    markReverts(&turns, &blobs);

    try testing.expect(turns[0].reverted);
    try testing.expectEqual(@as(u32, 1), turns[0].reverted_to);
    // The turns it passed through did nothing of the kind.
    try testing.expect(!turns[1].reverted);
    try testing.expect(!turns[2].reverted);
}

test "the nearest earlier match is the one named" {
    // The same content at turns 1 and 2; turn 4 comes back to it. "back to 2"
    // says how far the agent unwound, which "back to 1" would overstate.
    var turns = [_]Turn{
        .{ .number = 4 },
        .{ .number = 3 },
        .{ .number = 2 },
        .{ .number = 1 },
    };
    const blobs = [_]Blob{
        .{ .turn = 0, .path = "a.zig", .sha = "aaa" },
        .{ .turn = 1, .path = "a.zig", .sha = "zzz" },
        .{ .turn = 2, .path = "a.zig", .sha = "aaa" },
        .{ .turn = 3, .path = "a.zig", .sha = "aaa" },
    };
    markReverts(&turns, &blobs);
    try testing.expect(turns[0].reverted);
    try testing.expectEqual(@as(u32, 2), turns[0].reverted_to);
}

test "the same content in two different files is not a revert" {
    // Two files can hold identical bytes - an empty file, a licence header,
    // two generated stubs - and neither is the agent undoing anything.
    var turns = [_]Turn{ .{ .number = 2 }, .{ .number = 1 } };
    const blobs = [_]Blob{
        .{ .turn = 0, .path = "b.zig", .sha = "aaa" },
        .{ .turn = 1, .path = "a.zig", .sha = "aaa" },
    };
    markReverts(&turns, &blobs);
    try testing.expect(!turns[0].reverted);
}

test "moving forward is not moving back" {
    // Turn 1 then turn 2 with different content each time: ordinary work.
    var turns = [_]Turn{ .{ .number = 2 }, .{ .number = 1 } };
    const blobs = [_]Blob{
        .{ .turn = 0, .path = "a.zig", .sha = "bbb" },
        .{ .turn = 1, .path = "a.zig", .sha = "aaa" },
    };
    markReverts(&turns, &blobs);
    try testing.expect(!turns[0].reverted);
    try testing.expectEqual(@as(u32, 0), turns[0].reverted_to);
}

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
