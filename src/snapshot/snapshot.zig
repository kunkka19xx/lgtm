// SPDX-License-Identifier: Apache-2.0
//
// When a snapshot is taken, under what session, and which ones are thrown away.
//
// The policy layer. `gitobj.zig` knows how to write one and knows
// nothing else; this file is the everything else. It decides that a turn has
// happened, numbers it, remembers where the reader had got to, and deletes the
// refs nobody will ever look at again.
//
// Three rules shape all of it.
//
// **A snapshot must never claim to be something it is not.** Hashing a file the
// agent is halfway through writing stores a corrupt turn under a ref that says
// it is good, and nothing downstream could tell. The diff path has `attach()`
// returning `ContentMismatch` to catch exactly this; there is no equivalent
// here, so the gate is upstream: `io/watch.zig`'s quiet period, which is
// silence *after* the writes, not during them.
//
// **Snapshots off is a normal state, not an error.** No repository, a failing
// plumbing call, a read-only checkout - all of them mean the store stops and
// everything else in the tool carries on. `enabled`
// latches false and nothing retries, because a store that failed once will
// fail every 500 ms and say so every time.
//
// **The paths come from the caller, already ignore-clean.** `update-index
// --add` is plumbing and will happily stage `node_modules`. What keeps hard
// boundary 5 true is that the path list is the watcher's, which is
// `git status --porcelain`'s, which is `.gitignore`-clean by construction.

const std = @import("std");
const Allocator = std.mem.Allocator;

const fs = @import("../io/fs.zig");
const proc = @import("../io/proc.zig");
const source = @import("../core/source.zig");
const gitobj = @import("gitobj.zig");

pub const state_path = ".lgtm/state.json";

/// A gap this long means the last session is over and this is a new one.
///
/// Four hours. Long enough that lunch, a meeting or a
/// rebuild does not split a session in two; short enough that yesterday's work
/// does not turn up in today's timeline as though it were part of it.
pub const session_gap_ms: i64 = 4 * 60 * 60 * 1000;

/// How many turns of the current session are kept.
///
/// A cap rather than an age, because what makes an old turn worth deleting is
/// that nobody will scroll that far, not that time passed. Pruning is ref
/// deletion; the objects go when `git gc` next runs, which is git's business
/// and not ours.
pub const default_keep: u32 = 100;

/// Room for `<seconds>-<suffix>`, which is what a session id is.
pub const max_session = 32;

pub const State = struct {
    session: [max_session]u8 = @splat(0),
    session_len: u8 = 0,
    /// The most recent turn written. Zero means only the baseline exists.
    latest_turn: u32 = 0,
    /// The turn the reader has read up to. Zero until they
    /// mark one, and the same state a pending badge would read - one source of
    /// truth, not two.
    reviewed_turn: u32 = 0,
    /// Whether `<session>/0` was written. Persisted rather than inferred,
    /// because the answer decides how far back `[t` may walk and asking git
    /// every keystroke to find out would be a subprocess per press.
    ///
    /// False is the ordinary case: a session that starts on a clean tree has
    /// nothing to preserve that HEAD does not already hold, so no baseline is
    /// written and the timeline starts at turn 1.
    has_baseline: bool = false,
    /// Wall clock of the last snapshot, for the four-hour rule. Wall rather
    /// than monotonic because the question is "was this today", and a
    /// monotonic clock does not survive the process that read it.
    last_ms: i64 = 0,

    pub fn name(self: *const State) []const u8 {
        return self.session[0..self.session_len];
    }

    fn setName(self: *State, text: []const u8) void {
        const n = @min(text.len, max_session);
        @memcpy(self.session[0..n], text[0..n]);
        self.session_len = @intCast(n);
    }
};

/// A session id: seconds since the epoch, then a suffix that disambiguates two
/// processes starting in the same second.
///
/// Not a formatted date, deliberately. It goes in a ref name, where the
/// characters have to be safe (`gitobj.refFor` refuses anything else) and where
/// nobody reads it; seconds sort the same way a date would and need no calendar
/// arithmetic to produce. The suffix is the sub-second part of the same clock:
/// two processes starting in the same nanosecond is not a case worth writing
/// code for, and this is a disambiguator rather than a secret.
pub fn sessionId(buf: []u8, now_ns: i128) []const u8 {
    const secs: i64 = @intCast(@divFloor(now_ns, std.time.ns_per_s));
    const sub: u64 = @intCast(@mod(now_ns, std.time.ns_per_s));
    return std.fmt.bufPrint(buf, "{d}-{x:0>4}", .{ secs, sub & 0xffff }) catch "session";
}

/// Whether a stored session is still the one we are in.
pub fn continues(state: *const State, now_ms: i64) bool {
    if (state.session_len == 0) return false;
    // A clock that went backwards - an NTP correction, a laptop that slept
    // across a timezone edit - reads as "not today" rather than as a huge gap
    // in either direction. Starting a new session is the harmless answer; the
    // old refs are still there.
    if (now_ms < state.last_ms) return false;
    return now_ms - state.last_ms < session_gap_ms;
}

/// Which refs to delete, given every ref we have written and how many turns of
/// this session to keep.
///
/// Other sessions are left alone. They are somebody's afternoon, they cost
/// almost nothing because git shares the objects, and deleting them is how a
/// safety net becomes the thing that lost the work. Only the current session's
/// oldest turns are pruned, and never the baseline: `<session>/0` is the tree
/// as it was before the agent ran, which is the one snapshot nobody can
/// reconstruct from any other.
pub fn toPrune(
    gpa: Allocator,
    refs: []const []const u8,
    session: []const u8,
    latest: u32,
    keep: u32,
) Allocator.Error![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    if (latest <= keep) return out.toOwnedSlice(gpa);
    const oldest_kept = latest - keep;

    for (refs) |ref| {
        const turn = turnOf(ref, session) orelse continue;
        if (turn == 0) continue;
        if (turn < oldest_kept) try out.append(gpa, ref);
    }
    return out.toOwnedSlice(gpa);
}

/// The turn number in `refs/lgtm/<session>/<turn>`, when the session matches.
pub fn turnOf(ref: []const u8, session: []const u8) ?u32 {
    if (!std.mem.startsWith(u8, ref, gitobj.ref_prefix)) return null;
    const rest = ref[gitobj.ref_prefix.len..];
    const slash = std.mem.lastIndexOfScalar(u8, rest, '/') orelse return null;
    if (!std.mem.eql(u8, rest[0..slash], session)) return null;
    return std.fmt.parseInt(u32, rest[slash + 1 ..], 10) catch null;
}

// -- the state file --------------------------------------------------------
//
// Hand-rolled, the way `core/comments.zig` writes its jsonl: four flat fields,
// and a parser small enough to read is worth more here than a general one.

pub fn render(out: *std.ArrayList(u8), gpa: Allocator, state: *const State) Allocator.Error!void {
    var buf: [64]u8 = undefined;
    try out.appendSlice(gpa, "{\n  \"session\": \"");
    try out.appendSlice(gpa, state.name());
    try out.appendSlice(gpa, "\",\n  \"latest_turn\": ");
    try out.appendSlice(gpa, std.fmt.bufPrint(&buf, "{d}", .{state.latest_turn}) catch "0");
    try out.appendSlice(gpa, ",\n  \"reviewed_turn\": ");
    try out.appendSlice(gpa, std.fmt.bufPrint(&buf, "{d}", .{state.reviewed_turn}) catch "0");
    try out.appendSlice(gpa, ",\n  \"baseline\": ");
    try out.appendSlice(gpa, if (state.has_baseline) "true" else "false");
    try out.appendSlice(gpa, ",\n  \"last_ms\": ");
    try out.appendSlice(gpa, std.fmt.bufPrint(&buf, "{d}", .{state.last_ms}) catch "0");
    try out.appendSlice(gpa, "\n}\n");
}

/// Reads what `render` wrote. A field that is missing or malformed keeps its
/// default rather than failing the read: a corrupt state file should cost the
/// reader their place in the timeline, not their session.
pub fn parse(text: []const u8) State {
    var state: State = .{};
    if (stringField(text, "session")) |s| state.setName(s);
    if (intField(text, "latest_turn")) |n| state.latest_turn = std.math.lossyCast(u32, n);
    if (intField(text, "reviewed_turn")) |n| state.reviewed_turn = std.math.lossyCast(u32, n);
    if (valueAfter(text, "baseline")) |v| state.has_baseline = std.mem.startsWith(u8, v, "true");
    if (intField(text, "last_ms")) |n| state.last_ms = n;
    return state;
}

fn valueAfter(text: []const u8, key: []const u8) ?[]const u8 {
    var buf: [64]u8 = undefined;
    const quoted = std.fmt.bufPrint(&buf, "\"{s}\"", .{key}) catch return null;
    const at = std.mem.indexOf(u8, text, quoted) orelse return null;
    const rest = text[at + quoted.len ..];
    const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
    return std.mem.trimStart(u8, rest[colon + 1 ..], " \t");
}

fn stringField(text: []const u8, key: []const u8) ?[]const u8 {
    const v = valueAfter(text, key) orelse return null;
    if (v.len == 0 or v[0] != '"') return null;
    const end = std.mem.indexOfScalar(u8, v[1..], '"') orelse return null;
    return v[1 .. 1 + end];
}

fn intField(text: []const u8, key: []const u8) ?i64 {
    const v = valueAfter(text, key) orelse return null;
    var n: usize = 0;
    while (n < v.len and (std.ascii.isDigit(v[n]) or (n == 0 and v[n] == '-'))) n += 1;
    if (n == 0) return null;
    return std.fmt.parseInt(i64, v[0..n], 10) catch null;
}

/// The marked snapshot's content for each of `paths`.
///
/// One `cat-file --batch`, never a process per file, with
/// `<ref>:<path>` request lines so no `ls-tree` is needed to find the blobs
/// first. A path the snapshot did not contain comes back empty, which is what
/// "the file was not there then" already means to `freshRows`.
///
/// This is the whole of what makes a mark survive a restart. The bytes live in
/// RAM afterwards exactly as they did before - reading them from git on every
/// re-diff would turn a 0.9 ms lookup into a subprocess - so the ref is where
/// the mark *is*, and the copy is a cache of it.
pub fn readPaths(
    gpa: Allocator,
    io: std.Io,
    ref: []const u8,
    paths: []const []const u8,
) ![][]const u8 {
    var req: std.ArrayList(u8) = .empty;
    defer req.deinit(gpa);
    for (paths) |p| {
        try req.appendSlice(gpa, ref);
        try req.append(gpa, ':');
        try req.appendSlice(gpa, p);
        try req.append(gpa, '\n');
    }

    const out = try proc.runWithInput(gpa, io, &.{ "git", "cat-file", "--batch" }, req.items, 64 << 20);
    defer out.deinit(gpa);
    // Non-zero means the ref is gone - pruned, or someone deleted it. Not an
    // error worth surfacing: the mark simply cannot be restored, and an empty
    // mark is the state every session starts in anyway.
    if (out.exit_code != 0) return error.GitFailed;

    const blobs = try gpa.alloc([]const u8, paths.len);
    errdefer gpa.free(blobs);
    @memset(blobs, "");

    var cursor: usize = 0;
    for (blobs) |*b| {
        b.* = try gpa.dupe(u8, source.nextBlob(out.stdout, &cursor) orelse break);
    }
    return blobs;
}

/// Whether a path is one lgtm may write during a restore.
///
/// Restore is the only thing in the tool that writes to the reader's files, so
/// the path it is handed gets checked rather than trusted. git's own paths are
/// repo-relative and cannot escape, which makes this insurance rather than a
/// fix - and insurance is exactly what the one destructive operation should be
/// carrying.
pub fn writablePath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.fs.path.isAbsolute(path)) return false;
    if (std.mem.indexOf(u8, path, "..") != null) return false;
    // Never our own state, and never git's.
    if (std.mem.startsWith(u8, path, ".git/")) return false;
    if (std.mem.startsWith(u8, path, ".lgtm/")) return false;
    return true;
}

// -- the store -------------------------------------------------------------

pub const Store = struct {
    gpa: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    state: State = .{},
    /// Latched. A store that has failed once will fail every quiet period, and
    /// a message repeated every ten seconds is noise rather than information.
    enabled: bool = true,
    keep: u32 = default_keep,

    /// Reads `.lgtm/state.json` and decides whether this is a new session.
    ///
    /// Never fails. A missing file is a first run, an unreadable one is a first
    /// run with a warning nobody needs, and neither is a reason for the tool
    /// not to start (hard rule 8's shape, applied to state rather than config).
    pub fn open(gpa: Allocator, io: std.Io, environ: *const std.process.Environ.Map) Store {
        var self: Store = .{ .gpa = gpa, .io = io, .environ = environ };
        const now = wallMs(io);

        if (fs.readFile(io, gpa, state_path, 1 << 16)) |text| {
            defer gpa.free(text);
            const stored = parse(text);
            if (continues(&stored, now)) {
                self.state = stored;
                return self;
            }
            // A session that ended: its refs stay, its numbering does not.
            // Continuing to count from turn 40 into a new session would make
            // two afternoons look like one.
        } else |_| {}

        var buf: [max_session]u8 = undefined;
        self.state.setName(sessionId(&buf, wallNs(io)));
        self.state.last_ms = now;
        return self;
    }

    /// Takes a snapshot of `paths` as turn `latest + 1`, or the baseline when
    /// nothing has been taken yet. Returns the turn number, or null when
    /// snapshots are off or nothing changed.
    ///
    /// The commit message: a subject, then the paths this turn staged.
    ///
    /// The list needs to know which files a turn is *about*, and the tree diff
    /// cannot tell it. A snapshot is `read-tree HEAD` plus the changed paths,
    /// so when HEAD moves - a commit - the base moves with it and the diff
    /// between two consecutive turns reports everything that commit touched as
    /// though the agent had done it. Recording the paths here is the only
    /// place that knows the truth, and it costs a longer message.
    ///
    /// Newline-separated, because a commit message cannot hold a NUL. A path
    /// containing a newline is therefore not matched and simply drops out of
    /// the row's counts, which understates a turn rather than inventing one.
    fn messageFor(gpa: Allocator, subject: []const u8, paths: []const []const u8) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.appendSlice(gpa, subject);
        try out.appendSlice(gpa, "\n");
        for (paths) |p| {
            try out.appendSlice(gpa, "\n");
            try out.appendSlice(gpa, p);
        }
        return out.toOwnedSlice(gpa);
    }

    /// The parent is the previous turn, which is what makes the store a chain -
    /// and what will make it a shallow tree the first time a restore continues
    /// from an older turn.
    pub fn take(self: *Store, paths: []const []const u8, message: []const u8) ?u32 {
        if (!self.enabled or paths.len == 0) return null;

        const turn = self.state.latest_turn + 1;
        var ref_buf: [128]u8 = undefined;
        const ref = gitobj.refFor(&ref_buf, self.state.name(), turn) catch {
            self.enabled = false;
            return null;
        };

        var parent_buf: [128]u8 = undefined;
        // The previous turn, or the baseline when this is the first one. The
        // baseline used to be an orphan - `take` only looked at `latest_turn`,
        // which the baseline does not raise - so the chain started at turn 1
        // and the tree that mattered most hung off nothing. `git log` on the
        // newest ref now walks the whole session back to what was there first.
        const parent: ?[]const u8 = if (self.state.latest_turn > 0)
            gitobj.refFor(&parent_buf, self.state.name(), self.state.latest_turn) catch null
        else if (self.state.has_baseline)
            gitobj.refFor(&parent_buf, self.state.name(), 0) catch null
        else
            null;

        const body = messageFor(self.gpa, message, paths) catch message;
        defer if (body.ptr != message.ptr) self.gpa.free(body);

        _ = gitobj.writeSnapshot(self.gpa, self.io, self.environ, .{
            .paths = paths,
            .ref = ref,
            .parent = parent,
            .message = body,
        }) catch {
            // Off for the session. Not a message: the reader did not ask for a
            // snapshot and cannot act on its absence mid-turn.
            self.enabled = false;
            return null;
        };

        self.state.latest_turn = turn;
        self.state.last_ms = wallMs(self.io);
        self.save();
        self.prune();
        return turn;
    }

    /// Records the working tree as `<session>/0`, before the agent has run.
    ///
    /// The one snapshot no other snapshot can reconstruct:
    /// every later turn is the agent's work, and this is what was there first.
    /// It is also the only uncommitted state git alone could never recover,
    /// which is the argument for the whole store.
    ///
    /// Once per session, including on a clean tree.
    ///
    /// Taking one on a clean tree looked like waste - HEAD already holds that
    /// content - until the turn *after* it had nowhere to be diffed from. Every
    /// turn's view is the diff from the turn before, and without a baseline the
    /// first turn has no before: it opened empty. One snapshot per session buys
    /// every later turn a well-defined parent, and that is worth more than the
    /// five subprocesses it costs.
    ///
    /// Returns whether one was written.
    pub fn baseline(self: *Store, paths: []const []const u8) bool {
        if (!self.enabled or self.state.has_baseline) return false;
        // A session that already has turns is one being continued; its baseline
        // was written when it began, or deliberately was not.
        if (self.state.latest_turn > 0) return false;

        var buf: [128]u8 = undefined;
        const ref = gitobj.refFor(&buf, self.state.name(), 0) catch return false;
        const body = messageFor(self.gpa, "baseline", paths) catch "baseline";
        defer if (body.len > "baseline".len) self.gpa.free(body);

        _ = gitobj.writeSnapshot(self.gpa, self.io, self.environ, .{
            .paths = paths,
            .ref = ref,
            .message = body,
        }) catch {
            self.enabled = false;
            return false;
        };
        self.state.has_baseline = true;
        self.state.last_ms = wallMs(self.io);
        self.save();
        return true;
    }

    /// The oldest turn `[t` may walk to: the baseline when there is one, and
    /// the first real turn when there is not.
    pub fn oldestTurn(self: *const Store) u32 {
        return if (self.state.has_baseline) 0 else 1;
    }

    /// The ref the reader has read up to, or null when they have marked nothing.
    pub fn reviewedRef(self: *const Store, buf: []u8) ?[]const u8 {
        if (self.state.reviewed_turn == 0) return null;
        return gitobj.refFor(buf, self.state.name(), self.state.reviewed_turn) catch null;
    }

    /// The reader has read up to the latest turn. The same
    /// state a pending badge reads, which is why it is one field and not two.
    pub fn markReviewed(self: *Store) void {
        self.state.reviewed_turn = self.state.latest_turn;
        self.save();
    }

    /// Turns written since the reader last marked. What "unreviewed" means,
    /// for the status row and, later, for a badge.
    pub fn unreviewed(self: *const Store) u32 {
        return self.state.latest_turn -| self.state.reviewed_turn;
    }

    fn prune(self: *Store) void {
        const listed = gitobj.listRefs(self.gpa, self.io) catch return;
        defer self.gpa.free(listed.text);
        defer self.gpa.free(listed.refs);

        const doomed = toPrune(
            self.gpa,
            listed.refs,
            self.state.name(),
            self.state.latest_turn,
            self.keep,
        ) catch return;
        defer self.gpa.free(doomed);
        for (doomed) |ref| gitobj.deleteRef(self.gpa, self.io, ref);
    }

    fn save(self: *Store) void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        render(&out, self.gpa, &self.state) catch return;
        fs.writeStateFile(self.io, state_path, out.items) catch {};
    }
};

fn wallNs(io: std.Io) i128 {
    const ts = std.Io.Timestamp.now(io, .real);
    return ts.toNanoseconds();
}

fn wallMs(io: std.Io) i64 {
    return @intCast(@divFloor(wallNs(io), std.time.ns_per_ms));
}

const testing = std.testing;

test "a session id is safe in a ref name" {
    var buf: [max_session]u8 = undefined;
    const id = sessionId(&buf, 1_757_000_000_123_456_789);
    // Sorts like a date without needing a calendar, and `refFor` will take it -
    // which it will not do for anything containing a slash or a dot.
    var ref: [128]u8 = undefined;
    const r = try gitobj.refFor(&ref, id, 7);
    try testing.expect(std.mem.startsWith(u8, r, "refs/lgtm/"));
    try testing.expect(std.mem.endsWith(u8, r, "/7"));
    try testing.expect(gitobj.ours(r));
}

test "a session continues across a restart, and not across a night" {
    var s: State = .{ .last_ms = 1_000_000 };
    s.setName("abc-1234");

    try testing.expect(continues(&s, 1_000_000));
    try testing.expect(continues(&s, 1_000_000 + session_gap_ms - 1));
    try testing.expect(!continues(&s, 1_000_000 + session_gap_ms));
    // A clock that went backwards starts a new session rather than guessing
    // which direction to trust. The old refs are still there either way.
    try testing.expect(!continues(&s, 999_999));
    // Nothing stored is a first run.
    const empty: State = .{};
    try testing.expect(!continues(&empty, 1_000_000));
}

test "state survives a round trip, and a corrupt field costs only itself" {
    const gpa = testing.allocator;
    var s: State = .{ .latest_turn = 12, .reviewed_turn = 9, .last_ms = 1_757_000_000_000 };
    s.setName("1757000000-a3f9");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try render(&out, gpa, &s);

    const back = parse(out.items);
    try testing.expectEqualStrings("1757000000-a3f9", back.name());
    try testing.expectEqual(@as(u32, 12), back.latest_turn);
    try testing.expectEqual(@as(u32, 9), back.reviewed_turn);
    try testing.expectEqual(@as(i64, 1_757_000_000_000), back.last_ms);

    // A file someone edited by hand, or half-written by a crash. Losing the
    // reader's place in the timeline is the right cost; losing their session
    // is not.
    const broken = parse("{ \"session\": \"abc\", \"latest_turn\": banana }");
    try testing.expectEqualStrings("abc", broken.name());
    try testing.expectEqual(@as(u32, 0), broken.latest_turn);
    try testing.expectEqual(@as(u32, 0), parse("").latest_turn);
    try testing.expectEqual(@as(usize, 0), parse("{}").name().len);
}

test "a turn number is read back out of its ref, and only for this session" {
    try testing.expectEqual(@as(u32, 7), turnOf("refs/lgtm/s1/7", "s1").?);
    try testing.expectEqual(@as(u32, 0), turnOf("refs/lgtm/s1/0", "s1").?);
    // Another session's refs are not ours to count or to delete.
    try testing.expect(turnOf("refs/lgtm/other/7", "s1") == null);
    try testing.expect(turnOf("refs/heads/main", "s1") == null);
    try testing.expect(turnOf("refs/lgtm/s1/notanumber", "s1") == null);
}

test "pruning keeps the recent turns, the baseline, and every other session" {
    const gpa = testing.allocator;
    const refs = [_][]const u8{
        "refs/lgtm/s1/0", // the baseline, never pruned
        "refs/lgtm/s1/1",
        "refs/lgtm/s1/2",
        "refs/lgtm/s1/3",
        "refs/lgtm/s1/4",
        "refs/lgtm/other/1", // someone else's afternoon
        "refs/heads/main", // not ours at all
    };

    const doomed = try toPrune(gpa, &refs, "s1", 4, 2);
    defer gpa.free(doomed);

    // latest 4, keep 2 -> turns below 2 go, except turn 0.
    try testing.expectEqual(@as(usize, 1), doomed.len);
    try testing.expectEqualStrings("refs/lgtm/s1/1", doomed[0]);
}

test "the baseline is never pruned, however long the session runs" {
    const gpa = testing.allocator;
    // `<session>/0` is the working tree as it was before the agent ran, and it
    // is the one snapshot no other snapshot can reconstruct (5.5).
    const refs = [_][]const u8{ "refs/lgtm/s1/0", "refs/lgtm/s1/1", "refs/lgtm/s1/500" };
    const doomed = try toPrune(gpa, &refs, "s1", 500, 1);
    defer gpa.free(doomed);

    for (doomed) |ref| try testing.expect(!std.mem.endsWith(u8, ref, "/0"));
    try testing.expectEqual(@as(usize, 1), doomed.len);
}

test "nothing is pruned before there is more than the cap" {
    const gpa = testing.allocator;
    const refs = [_][]const u8{ "refs/lgtm/s1/0", "refs/lgtm/s1/1", "refs/lgtm/s1/2" };
    const doomed = try toPrune(gpa, &refs, "s1", 2, default_keep);
    defer gpa.free(doomed);
    try testing.expectEqual(@as(usize, 0), doomed.len);
}

test "the reviewed ref is null until something is marked" {
    var store: Store = .{ .gpa = testing.allocator, .io = undefined, .environ = undefined };
    store.state.setName("s1");

    var buf: [128]u8 = undefined;
    // Nothing marked: there is no ref to restore from, which is the state
    // every first run is in.
    try testing.expect(store.reviewedRef(&buf) == null);

    store.state.latest_turn = 4;
    store.state.reviewed_turn = 4;
    try testing.expectEqualStrings("refs/lgtm/s1/4", store.reviewedRef(&buf).?);

    // The reviewed turn is what is restored, not the latest: turns written
    // after the reader marked are exactly the ones that must still read as new.
    store.state.latest_turn = 9;
    try testing.expectEqualStrings("refs/lgtm/s1/4", store.reviewedRef(&buf).?);
}

test "pending is a subtraction, which is why it is one state and not two" {
    // `markReviewed` writes the state file, so the arithmetic is asserted
    // without it - the field it sets is the whole of what it does, and a test
    // that needed a filesystem to check a subtraction would be testing the
    // filesystem.
    var store: Store = .{ .gpa = testing.allocator, .io = undefined, .environ = undefined };
    store.state.latest_turn = 7;
    try testing.expectEqual(@as(u32, 7), store.unreviewed());

    store.state.reviewed_turn = store.state.latest_turn;
    try testing.expectEqual(@as(u32, 0), store.unreviewed());

    // Two turns since the reader marked. This is the badge a notification
    // rule 3 describes, rather than a second thing to keep in step with it.
    store.state.latest_turn = 9;
    try testing.expectEqual(@as(u32, 2), store.unreviewed());

    // And it never goes negative, however the state file was edited.
    store.state.reviewed_turn = 99;
    try testing.expectEqual(@as(u32, 0), store.unreviewed());
}

test "the baseline is written once, and not onto a clean tree" {
    var store: Store = .{ .gpa = testing.allocator, .io = undefined, .environ = undefined };
    store.state.setName("s1");

    // A clean tree gets one too. It looked like waste until the first turn had
    // no parent to be diffed from and opened empty; a baseline is what gives
    // every later turn a before.
    try testing.expectEqual(@as(u32, 1), store.oldestTurn());

    // Already taken: a session being continued keeps the baseline it began
    // with, rather than overwriting it with the agent's work so far.
    store.state.has_baseline = true;
    try testing.expect(!store.baseline(&.{"a.zig"}));
    try testing.expectEqual(@as(u32, 0), store.oldestTurn());

    // A session that already has turns is being continued, whatever the flag
    // says - writing turn 0 now would record the agent's output as the state
    // before the agent ran, which is a lie in the one place it must not be.
    store.state.has_baseline = false;
    store.state.latest_turn = 3;
    try testing.expect(!store.baseline(&.{"a.zig"}));

    // Snapshots off stays off.
    store.state.latest_turn = 0;
    store.enabled = false;
    try testing.expect(!store.baseline(&.{"a.zig"}));
}

test "the baseline flag survives the state file" {
    const gpa = testing.allocator;
    var s: State = .{ .latest_turn = 2, .has_baseline = true, .last_ms = 5 };
    s.setName("s1");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try render(&out, gpa, &s);

    const back = parse(out.items);
    try testing.expect(back.has_baseline);
    try testing.expectEqual(@as(i64, 5), back.last_ms);

    // Absent means false, which is what every state file written before this
    // field existed says, and the safe answer: the floor stays at turn 1 and
    // `[t` reports no baseline rather than walking to a ref nobody wrote.
    try testing.expect(!parse("{ \"session\": \"s1\" }").has_baseline);
}

test "restore refuses any path that is not plainly inside the repository" {
    // The only thing in the tool that writes to the reader's files, so the
    // path is checked rather than trusted. git's own paths cannot escape,
    // which makes this insurance - and insurance is what the one destructive
    // operation should carry.
    try testing.expect(writablePath("src/auth.zig"));
    try testing.expect(writablePath("a/b/c.txt"));

    try testing.expect(!writablePath(""));
    try testing.expect(!writablePath("/etc/passwd"));
    try testing.expect(!writablePath("../outside.zig"));
    try testing.expect(!writablePath("src/../../outside.zig"));
    // Never git's own state, and never ours: restoring either would break the
    // thing doing the restoring.
    try testing.expect(!writablePath(".git/config"));
    try testing.expect(!writablePath(".lgtm/state.json"));
}
