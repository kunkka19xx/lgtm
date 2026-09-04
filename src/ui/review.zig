// SPDX-License-Identifier: Apache-2.0
//
// One diff generation, and everything derived from it: the git output, the
// file buffers it is an overlay on, the change ids carried across from the
// last generation, and the lexer cache the renderer draws from.
//
// The split from `ui/app.zig` is between *what changed* and *where the reader
// is looking*. This file has no cursor, no scroll offset and no notion of a
// current file - it is handed one and answers questions about it. That is what
// makes `rediff` eight lines up there instead of eighty, and what keeps the
// arena discipline in one place: everything here belongs to `arena` and dies
// at the next `regenerate` (ARCHITECTURE.md 4).

const std = @import("std");
const Allocator = std.mem.Allocator;

const anchor = @import("../core/anchor.zig");
const checkpoint = @import("../core/checkpoint.zig");
const snapshot = @import("../snapshot/snapshot.zig");
const diff = @import("../core/diff.zig");
const git = @import("../core/git.zig");
const hunk = @import("../core/hunk.zig");
const source = @import("../core/source.zig");
const Buffer = @import("../text/buffer.zig").Buffer;
const highlight = @import("../syntax/highlight.zig");
const lexer = @import("../syntax/lexer.zig");
const metrics = @import("../io/metrics.zig");

/// The buffers behind one file: the working tree and HEAD. Both optional - a
/// new file has no HEAD side, and a file that failed to load has neither.
pub const Buffers = struct {
    work: ?Buffer = null,
    head: ?Buffer = null,
};

/// What survives a re-diff. Both point into the arena that is about to be
/// reset, so `regenerate` copies them out before it resets anything.
pub const Carry = struct {
    /// The file the reader was on, so the same path stays selected even as
    /// files appear and disappear around it.
    path: ?[]const u8 = null,
    /// That file's hunks from the previous generation, so change ids survive
    /// an edit rather than being renumbered under the reader.
    hunks: []const hunk.Hunk = &.{},
    /// The working-tree line the reader was on, 1-based as `new_no` counts.
    /// Zero when the cursor was on chrome or on a deleted line, neither of
    /// which has a line in the new file to carry anywhere.
    line: u32 = 0,
};

pub const Review = struct {
    gpa: Allocator,
    io: std.Io,
    /// Holds a whole diff generation and is reset by `regenerate`.
    arena: std.heap.ArenaAllocator,

    ids: hunk.IdTable = .{},
    cache: highlight.Cache = .{},
    parsed: ?git.Parsed = null,
    sources: ?source.Sources = null,
    /// A file changed between git running and our read of it, so the diff and
    /// the buffer disagree. Surfaced rather than rendered as a blend of two
    /// states (SPEC.md 9).
    torn: bool = false,
    /// `[review] ignore` patterns, and whether they are being applied. Held
    /// here because a re-diff is where they take effect: toggling is a
    /// re-diff, not a filter over what is already parsed.
    ignore: []const []const u8 = &.{},
    show_ignored: bool = false,
    /// How many changed files the patterns kept out, so the status line can
    /// say so. Nothing is ever hidden silently.
    hidden: u32 = 0,
    /// There is no repository here. Held rather than returned, because it is
    /// not a failure to report once and forget: the pane stays open on an
    /// empty review, and the reader has to be told why every frame rather than
    /// left looking at a wordmark wondering what happened.
    no_repo: bool = false,
    /// The turn on screen, or null for the working tree.
    ///
    /// Held here because it is a property of *this generation* - which diff is
    /// being shown - rather than of where the reader is looking. `regenerate`
    /// reads it and everything downstream is unchanged: a turn is a diff
    /// source, and nothing above `core/git.zig` ever knew where a diff came
    /// from (SNAPSHOTS.md 5.3).
    viewing: ?u32 = null,
    view_ref: [128]u8 = @splat(0),
    view_ref_len: u8 = 0,

    /// The carried file's working-tree text as it was before the last reset,
    /// and the line the reader was on in it. gpa-owned, not arena-owned:
    /// re-anchoring needs the old text and the new text at the same moment,
    /// and the old one lived in the arena `regenerate` just reset
    /// (PERFORMANCE.md 3.1).
    prev_work: []u8 = &.{},
    prev_line: u32 = 0,

    /// Paths the reader has opened out of their summary (SPEC.md 6.1).
    /// gpa-owned, for the same reason `prev_work` is: surviving the reset is
    /// the whole point. A file that folded itself again every time the agent
    /// touched anything would be a file you cannot read while it is being
    /// written, which is the only time you want to.
    expanded: std.ArrayList([]u8) = .empty,

    /// The mark, and what changed after it. The mark is gpa-owned for the same
    /// reason `prev_work` is; `fresh` is one bool per row of each file and
    /// belongs to the generation, because rows do.
    mark_at: checkpoint.Checkpoint,
    fresh: [][]bool = &.{},

    pub fn init(gpa: Allocator, io: std.Io) Review {
        return .{ .gpa = gpa, .io = io, .arena = .init(gpa), .mark_at = .init(gpa) };
    }

    pub fn deinit(self: *Review) void {
        self.mark_at.deinit();
        for (self.expanded.items) |p| self.gpa.free(p);
        self.expanded.deinit(self.gpa);
        self.gpa.free(self.prev_work);
        self.ids.deinit(self.gpa);
        self.cache.deinit(self.gpa);
        self.arena.deinit();
        self.* = undefined;
    }

    /// The generation's allocator. Callers building something that lives
    /// exactly as long as this diff - the row list, the hunk names - use it,
    /// and never free.
    pub fn allocator(self: *Review) Allocator {
        return self.arena.allocator();
    }

    pub fn files(self: *const Review) []diff.FileDiff {
        const p = self.parsed orelse return &.{};
        return p.diff.files;
    }

    pub fn fileAt(self: *const Review, index: u32) ?*diff.FileDiff {
        const fs = self.files();
        if (index >= fs.len) return null;
        return &fs[index];
    }

    /// Hunks across the whole review, and how many come before `index` -
    /// together they are the status line's "4 of 17".
    pub fn totalHunks(self: *const Review) u32 {
        var n: u32 = 0;
        for (self.files()) |f| n += @intCast(f.hunks.len);
        return n;
    }

    pub fn hunksBefore(self: *const Review, index: u32) u32 {
        var n: u32 = 0;
        for (self.files(), 0..) |f, i| {
            if (i >= index) break;
            n += @intCast(f.hunks.len);
        }
        return n;
    }

    /// Runs git, loads the buffers, attaches them and inherits change ids.
    /// Returns the file index to look at now: the same path where it still
    /// exists, and the first file where it does not.
    ///
    /// Order is fixed by ARCHITECTURE.md 3 and is not an implementation
    /// detail: ids are inherited before anything that reads them.
    pub fn regenerate(self: *Review, carry: Carry) !u32 {
        // Copied to the gpa first: both point into the arena this is about to
        // reset, and reading them afterwards would be reading freed memory.
        const carried = try self.gpa.alloc(hunk.Hunk, carry.hunks.len);
        defer self.gpa.free(carried);
        @memcpy(carried, carry.hunks);

        const keep_path = if (carry.path) |p| try self.gpa.dupe(u8, p) else null;
        defer if (keep_path) |p| self.gpa.free(p);

        // The reader's line, and the text it was a line of, copied out for the
        // same reason and while the buffers still exist. A failed dupe leaves
        // `prev_work` empty, which re-anchoring reads as "nothing to carry".
        self.gpa.free(self.prev_work);
        self.prev_work = &.{};
        self.prev_line = carry.line;
        if (keep_path) |p| {
            if (self.buffersFor(p).work) |w| self.prev_work = try self.gpa.dupe(u8, w.bytes);
        }

        _ = self.arena.reset(.retain_capacity);
        const arena = self.arena.allocator();
        self.parsed = null;
        self.sources = null;
        self.torn = false;
        self.fresh = &.{};

        const git_span = metrics.span(.git_subprocess);
        const skip: []const []const u8 = if (self.show_ignored) &.{} else self.ignore;
        if (self.viewRef()) |ref| {
            // A turn. The same left-hand side, a different right-hand one, and
            // the buffers for it read out of the tree rather than off disk -
            // `attach` still checks every line against the buffer it should
            // have come from, so the historical view obeys the same rule the
            // live one does.
            const at = git.diffAt(arena, self.io, null, skip, ref) catch {
                self.viewing = null;
                self.view_ref_len = 0;
                return 0;
            };
            git_span.end();
            self.parsed = at;
            self.sources = source.loadAt(arena, self.io, null, at.diff, ref) catch null;
            if (self.sources) |srcs| {
                for (at.diff.files) |*f| {
                    const s = srcs.find(f.path()) orelse continue;
                    source.attach(f, s.*) catch {};
                }
            }
            for (at.diff.files) |*f| try self.ids.inherit(arena, &.{}, f.hunks);
            try self.refresh();
            return 0;
        }
        // Not a repository is a state to sit in, not an error to die from. The
        // review is empty, the splash draws, and `?`, `:q` and the compose box
        // all still work - which is the same shape as a clean tree, and for
        // the same reason: a pane that crashed is a pane that cannot tell you
        // what went wrong.
        const parsed = git.diffPathsIn(arena, self.io, null, &.{}, skip) catch |err| switch (err) {
            error.NotARepository => {
                self.no_repo = true;
                return 0;
            },
            else => return err,
        };
        git_span.end();
        self.no_repo = false;
        self.parsed = parsed;

        // What the patterns kept out, counted rather than assumed - which is
        // what lets the status line say a number instead of leaving the reader
        // to wonder what they have not looked at.
        self.hidden = git.hiddenCount(self.gpa, self.io, skip);

        // Before the buffers are attached and before ids are inherited, both
        // of which skip a summarised file: what the reader opened has to
        // become a real file again first, or the next re-diff would quietly
        // fold it back and lose their place in it.
        for (self.expanded.items) |p| {
            for (parsed.diff.files) |*f| {
                if (!f.summarised) continue;
                if (!std.mem.eql(u8, f.path(), p)) continue;
                diff.materialise(arena, f, parsed.raw) catch {};
            }
        }

        // Buffers are the source of truth; the diff is an overlay on them.
        self.sources = source.load(arena, self.io, null, parsed.diff) catch null;
        if (self.sources) |srcs| {
            for (parsed.diff.files) |*f| {
                const s = srcs.find(f.path()) orelse continue;
                source.attach(f, s.*) catch |err| switch (err) {
                    // The file changed under us. Say so and let the caller
                    // re-diff, rather than draw a blend of two states.
                    error.ContentMismatch => self.torn = true,
                    else => return err,
                };
            }
        }

        var index: u32 = 0;
        if (keep_path) |p| {
            for (parsed.diff.files, 0..) |*f, i| {
                if (std.mem.eql(u8, f.path(), p)) index = @intCast(i);
            }
        }
        if (index >= parsed.diff.files.len) index = 0;

        for (parsed.diff.files, 0..) |*f, i| {
            const prev: []const hunk.Hunk = if (i == index) carried else &.{};
            try self.ids.inherit(arena, prev, f.hunks);
        }

        try self.refresh();
        return index;
    }

    /// Recomputes what changed since the mark, for every file.
    ///
    /// Costs nothing at all until a mark is taken, which is the common case
    /// and the reason this is a check rather than a config flag. After one, it
    /// is a line map per changed file per re-diff - the same map anchoring
    /// already runs for the cursor's file, now run for all of them
    /// (PERFORMANCE.md 3.1). The 100 ms re-diff budget is what to watch here,
    /// and `--profile` is what watches it.
    fn refresh(self: *Review) Allocator.Error!void {
        if (!self.mark_at.taken()) {
            self.fresh = &.{};
            return;
        }
        const sp = metrics.span(.checkpoint);
        defer sp.end();

        const arena = self.arena.allocator();
        const fs = self.files();
        const out = try arena.alloc([]bool, fs.len);
        for (fs, 0..) |*f, i| out[i] = try self.freshOf(f);
        self.fresh = out;
    }

    fn freshOf(self: *Review, f: *diff.FileDiff) Allocator.Error![]bool {
        const arena = self.arena.allocator();
        const work = self.buffersFor(f.path()).work;
        const now: []const u8 = if (work) |w| w.bytes else "";
        return checkpoint.freshRows(arena, f, now, self.mark_at.find(f.path()));
    }

    /// Takes the mark: this working tree, as the reader has now read it.
    ///
    /// Every changed file, including one already deleted - which is recorded
    /// with empty content rather than skipped, because "absent from the mark"
    /// has to keep meaning "not in the review then", or a file deleted before
    /// the mark would light up whole afterwards.
    pub fn mark(self: *Review) Allocator.Error!void {
        self.mark_at.clear();
        for (self.files()) |*f| {
            const work = self.buffersFor(f.path()).work;
            const now: []const u8 = if (work) |w| w.bytes else "";
            const removed = try checkpoint.removedLines(self.gpa, f);
            defer self.gpa.free(removed);
            try self.mark_at.add(f.path(), now, removed);
        }
        self.mark_at.turn += 1;
        try self.refresh();
    }

    /// Fills the mark from a snapshot ref instead of from the live buffers.
    ///
    /// This is the whole of what step 3 changed. `mark()` copies what is on
    /// screen, which is exact and free and dies with the process; this reads
    /// the same content back out of `refs/lgtm/<session>/<turn>` so that
    /// "since I last looked" still means something tomorrow.
    ///
    /// Everything above it is untouched - `freshRows` cannot tell where the
    /// bytes came from, and neither can the gutter, `]m` or the count. That was
    /// the point of `Checkpoint.find` being the only thing the review layer
    /// ever asked of the mark.
    ///
    /// Best effort. A ref that was pruned, a repository that has moved on, a
    /// failing plumbing call: all of them leave the mark unset, which is the
    /// state every session starts in and needs no explaining.
    pub fn restoreMark(self: *Review, ref: []const u8, turn: u32) void {
        const fs = self.files();
        if (fs.len == 0) return;

        var paths = self.gpa.alloc([]const u8, fs.len) catch return;
        defer self.gpa.free(paths);
        for (fs, 0..) |*f, i| paths[i] = f.path();

        const blobs = snapshot.readPaths(self.gpa, self.io, ref, paths) catch return;
        defer {
            for (blobs) |b| self.gpa.free(b);
            self.gpa.free(blobs);
        }

        self.mark_at.clear();
        for (fs, 0..) |*f, i| {
            const marked = blobs[i];
            // Absent from the snapshot means the file was not in the review
            // then, and `freshRows` reads a missing entry as exactly that. It
            // must not be recorded as present-and-empty, which would say the
            // file existed and was blank.
            if (marked.len == 0 and self.buffersFor(f.path()).head == null) continue;

            // The deleted-line set cannot be read back - it lived in a diff
            // that no longer exists - so it is derived from the marked tree
            // against HEAD, which is the same question asked of the data that
            // did survive (`core/checkpoint.zig`).
            const head = self.buffersFor(f.path()).head;
            const removed: []u32 = if (head) |h|
                checkpoint.derivedRemoved(self.gpa, h.bytes, marked) catch &.{}
            else
                &.{};
            defer if (removed.len > 0) self.gpa.free(removed);
            self.mark_at.add(f.path(), marked, removed) catch {};
        }
        self.mark_at.turn = turn;
        self.refresh() catch {};
    }

    /// The ref of the turn on screen, or null when the working tree is.
    pub fn viewRef(self: *const Review) ?[]const u8 {
        if (self.view_ref_len == 0) return null;
        return self.view_ref[0..self.view_ref_len];
    }

    /// Shows a turn instead of the working tree. The caller re-diffs.
    pub fn showTurn(self: *Review, turn: u32, ref: []const u8) void {
        const n = @min(ref.len, self.view_ref.len);
        @memcpy(self.view_ref[0..n], ref[0..n]);
        self.view_ref_len = @intCast(n);
        self.viewing = turn;
    }

    /// Back to the working tree, which is the only place the reader can act.
    pub fn showWorking(self: *Review) void {
        self.view_ref_len = 0;
        self.viewing = null;
    }

    /// Drops the mark, and with it every freshness marker.
    pub fn unmark(self: *Review) void {
        self.mark_at.clear();
        self.mark_at.turn = 0;
        self.fresh = &.{};
    }

    /// Which rows of file `index` changed since the mark. Empty when there is
    /// no mark, which every caller can treat as "none of them".
    pub fn freshFor(self: *const Review, index: u32) []const bool {
        if (index >= self.fresh.len) return &.{};
        return self.fresh[index];
    }

    /// Rows across the whole review that changed since the mark. The status
    /// line's count, and the answer to "is there anything left to look at".
    pub fn freshCount(self: *const Review) u32 {
        var n: u32 = 0;
        for (self.fresh) |rows| {
            for (rows) |b| {
                if (b) n += 1;
            }
        }
        return n;
    }

    /// Parses a summarised file's hunks now, and keeps it parsed across every
    /// re-diff until it is folded again.
    ///
    /// Deferring a large file is a rendering decision, never a discard
    /// (`core/diff.zig`), but for a while it was the same thing from the
    /// reader's side: the summary row was where a big file stopped, because
    /// nothing called `materialise`. This is that call.
    ///
    /// Returns false when there was nothing to open - the file renders in
    /// full already, or its bytes are not in this generation's git output,
    /// which is true of a synthesised entry for an untracked file.
    pub fn expand(self: *Review, path: []const u8) !bool {
        const p = self.parsed orelse return false;
        const f = find(p.diff.files, path) orelse return false;
        if (!f.summarised) return false;

        const arena = self.arena.allocator();
        try diff.materialise(arena, f, p.raw);
        // `materialise` leaves the flag set when the range is unusable. It is
        // the honest test for whether anything happened.
        if (f.summarised) return false;

        // The two things `regenerate` does to every other file, done late for
        // this one: attach it to its buffers, then give its hunks ids. Neither
        // reached it while it was a summary.
        if (self.sources) |srcs| {
            if (srcs.find(path)) |s| {
                source.attach(f, s.*) catch |err| switch (err) {
                    error.ContentMismatch => self.torn = true,
                    else => return err,
                };
            }
        }
        try self.ids.inherit(arena, &.{}, f.hunks);

        // The file had one row and now has thousands; the array that says
        // which of them are fresh was sized for the summary.
        if (self.mark_at.taken()) {
            for (self.files(), 0..) |*g, i| {
                if (g != f) continue;
                if (i < self.fresh.len) self.fresh[i] = try self.freshOf(f);
            }
        }

        try self.remember(path);
        return true;
    }

    /// Folds a file the reader opened. Returns false when it was not one -
    /// an ordinary file has nothing to fold, and saying so is better than
    /// appearing to do something.
    ///
    /// Only forgets; the caller re-diffs, which is what actually re-summarises
    /// it. That is the same shape as `[review] ignore`: git is what decided,
    /// so git is what gets asked again.
    pub fn collapse(self: *Review, path: []const u8) bool {
        for (self.expanded.items, 0..) |p, i| {
            if (!std.mem.eql(u8, p, path)) continue;
            self.gpa.free(self.expanded.swapRemove(i));
            return true;
        }
        return false;
    }

    fn remember(self: *Review, path: []const u8) Allocator.Error!void {
        for (self.expanded.items) |p| {
            if (std.mem.eql(u8, p, path)) return;
        }
        const owned = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(owned);
        try self.expanded.append(self.gpa, owned);
    }

    fn find(in: []diff.FileDiff, path: []const u8) ?*diff.FileDiff {
        for (in) |*f| {
            if (std.mem.eql(u8, f.path(), path)) return f;
        }
        return null;
    }

    /// The working-tree and HEAD buffers for one path.
    pub fn buffersFor(self: *const Review, path: []const u8) Buffers {
        const srcs = self.sources orelse return .{};
        const s = srcs.find(path) orelse return .{};
        return .{ .work = s.work, .head = s.head };
    }

    /// Where the reader's line went, or null when it did not go anywhere that
    /// can be pointed at.
    ///
    /// This is the primary path of PERFORMANCE.md 3.1: diff the previous
    /// working tree against the new one and read the answer out of the line
    /// map, which is a lookup rather than a search. The hash tiers inside
    /// `Anchor.reanchor` pick up what the map cannot, and `stale` is reported
    /// as null so the caller keeps the row it already had rather than jumping
    /// the reader somewhere arbitrary.
    ///
    /// The carrying itself is `core/anchor.zig`'s; what belongs here is only
    /// knowing which two texts to hand it.
    pub fn reanchorLine(self: *Review, path: []const u8) Allocator.Error!?u32 {
        if (self.prev_work.len == 0 or self.prev_line == 0) return null;
        const work = self.buffersFor(path).work orelse return null;

        // `new_no` is 1-based; anchors index lines from zero.
        const got = try anchor.carryLine(self.gpa, self.prev_work, work.bytes, self.prev_line - 1);
        return if (got) |ln| ln + 1 else null;
    }

    /// Enclosing function name per hunk, from the lexer's whole-file scan.
    /// Names are copied into the arena: the cache owns its own copies and may
    /// evict them, and a dangling name renders as garbage rather than failing.
    pub fn enclosingNames(self: *Review, f: *diff.FileDiff) ![][]const u8 {
        const arena = self.allocator();
        const out = try arena.alloc([]const u8, f.hunks.len);
        @memset(out, "");

        const work = self.buffersFor(f.path()).work orelse return out;
        const hl = highlight.Highlighter.choose(f.path(), work.bytes.len, work.lineCount());
        const st = self.cache.structureFor(self.gpa, hl, blobKey(f.new_blob, work.bytes), work.bytes) catch return out;

        for (f.hunks, 0..) |h, i| {
            const at = anchorLine(f, h);
            if (at == 0) continue;
            if (st.enclosingFn(at - 1)) |fd| {
                out[i] = arena.dupe(u8, fd.name) catch "";
            }
        }
        return out;
    }

    /// Token runs for one buffer, from the cache. Empty for a file the
    /// highlighter declines - which the renderer draws as plain text rather
    /// than as nothing.
    pub fn runsFor(self: *Review, path: []const u8, blob: []const u8, buf: ?Buffer) []const lexer.Run {
        const b = buf orelse return &.{};
        const hl = highlight.Highlighter.choose(path, b.bytes.len, b.lineCount());
        if (hl == .plain) return &.{};
        return self.cache.runsFor(self.gpa, hl, blobKey(blob, b.bytes), b.bytes) catch &.{};
    }
};

/// git already hashed this content; re-hashing the file on every lookup costs
/// more than the miss it avoids (PERFORMANCE.md 7.2).
fn blobKey(blob: []const u8, bytes: []const u8) u64 {
    if (blob.len == 0) return highlight.hashContent(bytes);
    return std.hash.Wyhash.hash(0, blob);
}

/// The line a hunk's header should name: its first changed line, not its first
/// line. A hunk opens on context, and for a change near the top of a function
/// that context sits above the declaration - which is how a hunk squarely
/// inside `hashHunk` came out with no name at all.
pub fn anchorLine(f: *const diff.FileDiff, h: hunk.Hunk) u32 {
    var i = h.lo;
    while (i < h.hi and i < f.lines.len()) : (i += 1) {
        if (f.lines.kind[i] == .context) continue;
        const n = f.lines.new_no[i];
        if (n != 0) return n;
    }
    // A pure deletion has no new-file line of its own; the hunk's position in
    // the new file is the closest honest answer.
    return h.new_start;
}

const testing = std.testing;

test "a hunk header names its first changed line, not its first line" {
    const gpa = testing.allocator;
    const n = 5;
    var lines: hunk.DiffLines = .{
        .kind = try gpa.alloc(hunk.LineKind, n),
        .old_no = try gpa.alloc(u32, n),
        .new_no = try gpa.alloc(u32, n),
        .text = try gpa.alloc([]const u8, n),
    };
    defer lines.deinit(gpa);
    // Three context lines, then the change: the shape that hid `hashHunk`.
    for (0..n) |i| {
        lines.kind[i] = if (i == 3) .add else .context;
        lines.old_no[i] = @intCast(73 + i);
        lines.new_no[i] = @intCast(73 + i);
        lines.text[i] = "x";
    }
    var f: diff.FileDiff = .{
        .old_path = "a.zig",
        .new_path = "a.zig",
        .status = .modified,
        .lines = lines,
    };
    const h: hunk.Hunk = .{ .old_start = 73, .old_count = 5, .new_start = 73, .new_count = 5, .lo = 0, .hi = 5 };
    try testing.expectEqual(@as(u32, 76), anchorLine(&f, h));
}

test "a pure deletion falls back to the hunk position" {
    const gpa = testing.allocator;
    var lines: hunk.DiffLines = .{
        .kind = try gpa.alloc(hunk.LineKind, 2),
        .old_no = try gpa.alloc(u32, 2),
        .new_no = try gpa.alloc(u32, 2),
        .text = try gpa.alloc([]const u8, 2),
    };
    defer lines.deinit(gpa);
    for (0..2) |i| {
        lines.kind[i] = .del;
        lines.old_no[i] = @intCast(10 + i);
        lines.new_no[i] = 0;
        lines.text[i] = "gone";
    }
    var f: diff.FileDiff = .{ .old_path = "a", .new_path = "a", .status = .modified, .lines = lines };
    const h: hunk.Hunk = .{ .old_start = 10, .old_count = 2, .new_start = 9, .new_count = 0, .lo = 0, .hi = 2 };
    try testing.expectEqual(@as(u32, 9), anchorLine(&f, h));
}
