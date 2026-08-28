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

    pub fn init(gpa: Allocator, io: std.Io) Review {
        return .{ .gpa = gpa, .io = io, .arena = .init(gpa) };
    }

    pub fn deinit(self: *Review) void {
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

        _ = self.arena.reset(.retain_capacity);
        const arena = self.arena.allocator();
        self.parsed = null;
        self.sources = null;
        self.torn = false;

        const git_span = metrics.span(.git_subprocess);
        const parsed = try git.diffPathsIn(arena, self.io, null, &.{});
        git_span.end();
        self.parsed = parsed;

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
        return index;
    }

    /// The working-tree and HEAD buffers for one path.
    pub fn buffersFor(self: *const Review, path: []const u8) Buffers {
        const srcs = self.sources orelse return .{};
        const s = srcs.find(path) orelse return .{};
        return .{ .work = s.work, .head = s.head };
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
