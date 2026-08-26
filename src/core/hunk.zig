// SPDX-License-Identifier: Apache-2.0
//
// The hunk model and change ids. A hunk is not an object with identity: git
// recomputes hunks from scratch every run and has no memory that #3 existed.
// The id is what the user and the agent say to each other; the hash is what
// stops the id from lying (SPEC.md 6.5).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ChangeId = u32;
pub const no_id: ChangeId = 0;

pub const LineKind = enum(u8) { context, add, del };

/// Struct-of-arrays: rendering walks `kind` and `new_no` for every visible row
/// and touches `text` only for rows it draws (PERFORMANCE.md 7.3).
pub const DiffLines = struct {
    kind: []LineKind = &.{},
    /// 1-based line number in the old file, 0 when the line is an addition.
    old_no: []u32 = &.{},
    /// 1-based line number in the new file, 0 when the line is a deletion.
    new_no: []u32 = &.{},
    /// Borrowed from the diff arena, never owned by a note (hard rule 4).
    text: [][]const u8 = &.{},

    pub fn len(self: DiffLines) usize {
        return self.kind.len;
    }

    pub fn deinit(self: *DiffLines, gpa: Allocator) void {
        gpa.free(self.kind);
        gpa.free(self.old_no);
        gpa.free(self.new_no);
        gpa.free(self.text);
        self.* = undefined;
    }
};

pub const Hunk = struct {
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
    /// Text after the second @@, which git fills with a guessed enclosing
    /// symbol. Replaced by the lexer's brace-depth scan later (SPEC.md 6.1).
    section: []const u8 = "",
    /// Range into the owning FileDiff's DiffLines.
    lo: u32,
    hi: u32,
    hash: u64 = 0,
    id: ChangeId = no_id,

    pub fn lineCount(self: Hunk) u32 {
        return self.hi - self.lo;
    }

    /// True when the new-file ranges touch or overlap.
    pub fn overlapsNew(self: Hunk, start: u32, count: u32) u32 {
        const a0 = self.new_start;
        const a1 = self.new_start + self.new_count;
        const b0 = start;
        const b1 = start + count;
        const lo = @max(a0, b0);
        const hi = @min(a1, b1);
        return if (hi > lo) hi - lo else 0;
    }
};

/// Identity of a change, independent of where it sits in the file.
///
/// Only added and removed lines are hashed, never context. Including context
/// would make a hunk's identity change whenever unrelated neighbouring code
/// moved, which is exactly the spurious id churn the hash exists to prevent.
pub fn hashHunk(lines: DiffLines, lo: u32, hi: u32) u64 {
    var hasher: std.hash.Wyhash = .init(0);
    var i = lo;
    while (i < hi) : (i += 1) {
        switch (lines.kind[i]) {
            .context => continue,
            .add => hasher.update("+"),
            .del => hasher.update("-"),
        }
        hasher.update(lines.text[i]);
        hasher.update("\n");
    }
    return hasher.final();
}

/// Assigns and inherits change ids across re-diffs. Ids are stable for as long
/// as the change is recognisably the same change.
pub const IdTable = struct {
    next: ChangeId = 1,
    /// Merged-away ids, pointing at the id that absorbed them, so "fix #4"
    /// still resolves after #3 and #4 collapse into one hunk.
    aliases: std.AutoHashMapUnmanaged(ChangeId, ChangeId) = .empty,

    pub fn deinit(self: *IdTable, gpa: Allocator) void {
        self.aliases.deinit(gpa);
        self.* = undefined;
    }

    pub fn fresh(self: *IdTable) ChangeId {
        const id = self.next;
        self.next += 1;
        return id;
    }

    /// Follows an alias chain to the id still in use.
    pub fn resolve(self: IdTable, id: ChangeId) ChangeId {
        var cur = id;
        var guard: usize = 0;
        while (self.aliases.get(cur)) |next| {
            cur = next;
            guard += 1;
            if (guard > 64) break; // cycles cannot happen, but never hang
        }
        return cur;
    }

    /// Matches new hunks to old ones and carries ids across.
    ///
    /// Exact hash matches first, then greedy by maximum overlap of new-file
    /// ranges, highest overlap first. The Hungarian algorithm would be optimal
    /// and is unnecessary at n < 50 (PERFORMANCE.md 4). Merge and split both
    /// fall out of the overlap scores rather than being special-cased.
    pub fn inherit(self: *IdTable, gpa: Allocator, prev: []const Hunk, cur: []Hunk) Allocator.Error!void {
        const prev_taken = try gpa.alloc(bool, prev.len);
        defer gpa.free(prev_taken);
        @memset(prev_taken, false);

        const cur_done = try gpa.alloc(bool, cur.len);
        defer gpa.free(cur_done);
        @memset(cur_done, false);

        // Pass 1: exact content match. Unambiguous, so it wins outright.
        for (cur, 0..) |*h, ci| {
            for (prev, 0..) |p, pi| {
                if (prev_taken[pi]) continue;
                if (p.hash != h.hash) continue;
                h.id = p.id;
                prev_taken[pi] = true;
                cur_done[ci] = true;
                break;
            }
        }

        // Pass 2: greedy by overlap. Repeatedly take the best remaining pair.
        while (true) {
            var best_overlap: u32 = 0;
            var best_ci: usize = 0;
            var best_pi: usize = 0;
            for (cur, 0..) |h, ci| {
                if (cur_done[ci]) continue;
                for (prev, 0..) |p, pi| {
                    if (prev_taken[pi]) continue;
                    const ov = h.overlapsNew(p.new_start, p.new_count);
                    if (ov > best_overlap) {
                        best_overlap = ov;
                        best_ci = ci;
                        best_pi = pi;
                    }
                }
            }
            if (best_overlap == 0) break;
            cur[best_ci].id = prev[best_pi].id;
            cur_done[best_ci] = true;
            prev_taken[best_pi] = true;
        }

        // Pass 3: a merge absorbed more than one old hunk. Any old hunk still
        // unclaimed but overlapping a now-identified hunk becomes an alias of
        // it, lower id winning (SPEC.md 6.5).
        for (prev, 0..) |p, pi| {
            if (prev_taken[pi]) continue;
            for (cur) |*h| {
                if (h.id == no_id) continue;
                if (h.overlapsNew(p.new_start, p.new_count) == 0) continue;
                const winner = @min(h.id, p.id);
                const loser = @max(h.id, p.id);
                if (winner != loser) {
                    try self.aliases.put(gpa, loser, winner);
                    h.id = winner;
                }
                prev_taken[pi] = true;
                break;
            }
        }

        // Anything still unclaimed is genuinely new.
        for (cur) |*h| {
            if (h.id == no_id) h.id = self.fresh();
        }
    }
};

const testing = std.testing;

/// Builds DiffLines from a compact spec: each line is "<kind><text>" where kind
/// is one of ' ', '+', '-'.
fn linesFrom(gpa: Allocator, spec: []const []const u8) !DiffLines {
    var out: DiffLines = .{
        .kind = try gpa.alloc(LineKind, spec.len),
        .old_no = try gpa.alloc(u32, spec.len),
        .new_no = try gpa.alloc(u32, spec.len),
        .text = try gpa.alloc([]const u8, spec.len),
    };
    var old_n: u32 = 1;
    var new_n: u32 = 1;
    for (spec, 0..) |s, i| {
        out.kind[i] = switch (s[0]) {
            '+' => .add,
            '-' => .del,
            else => .context,
        };
        out.text[i] = s[1..];
        switch (out.kind[i]) {
            .add => {
                out.old_no[i] = 0;
                out.new_no[i] = new_n;
                new_n += 1;
            },
            .del => {
                out.old_no[i] = old_n;
                out.new_no[i] = 0;
                old_n += 1;
            },
            .context => {
                out.old_no[i] = old_n;
                out.new_no[i] = new_n;
                old_n += 1;
                new_n += 1;
            },
        }
    }
    return out;
}

test "hunk hash ignores context and position" {
    var a = try linesFrom(testing.allocator, &.{ " one", "-two", "+TWO", " three" });
    defer a.deinit(testing.allocator);
    var b = try linesFrom(testing.allocator, &.{ " different", "-two", "+TWO", " context" });
    defer b.deinit(testing.allocator);

    try testing.expectEqual(hashHunk(a, 0, 4), hashHunk(b, 0, 4));
}

test "hunk hash distinguishes different changes" {
    var a = try linesFrom(testing.allocator, &.{ "-two", "+TWO" });
    defer a.deinit(testing.allocator);
    var b = try linesFrom(testing.allocator, &.{ "-two", "+THREE" });
    defer b.deinit(testing.allocator);

    try testing.expect(hashHunk(a, 0, 2) != hashHunk(b, 0, 2));
}

test "identical hunks keep their ids across a re-diff" {
    var table: IdTable = .{};
    defer table.deinit(testing.allocator);

    var prev = [_]Hunk{
        .{ .old_start = 10, .old_count = 2, .new_start = 10, .new_count = 2, .lo = 0, .hi = 2, .hash = 0xaa, .id = 1 },
        .{ .old_start = 40, .old_count = 2, .new_start = 40, .new_count = 2, .lo = 2, .hi = 4, .hash = 0xbb, .id = 2 },
    };
    // Both drifted down by 5 but their content is unchanged.
    var cur = [_]Hunk{
        .{ .old_start = 15, .old_count = 2, .new_start = 15, .new_count = 2, .lo = 0, .hi = 2, .hash = 0xaa },
        .{ .old_start = 45, .old_count = 2, .new_start = 45, .new_count = 2, .lo = 2, .hi = 4, .hash = 0xbb },
    };
    try table.inherit(testing.allocator, &prev, &cur);

    try testing.expectEqual(@as(ChangeId, 1), cur[0].id);
    try testing.expectEqual(@as(ChangeId, 2), cur[1].id);
}

test "a merge keeps the lower id and aliases the other" {
    var table: IdTable = .{ .next = 3 };
    defer table.deinit(testing.allocator);

    var prev = [_]Hunk{
        .{ .old_start = 10, .old_count = 2, .new_start = 10, .new_count = 2, .lo = 0, .hi = 2, .hash = 0xaa, .id = 1 },
        .{ .old_start = 13, .old_count = 2, .new_start = 13, .new_count = 2, .lo = 2, .hi = 4, .hash = 0xbb, .id = 2 },
    };
    // The gap closed: one hunk now spans both.
    var cur = [_]Hunk{
        .{ .old_start = 10, .old_count = 5, .new_start = 10, .new_count = 5, .lo = 0, .hi = 5, .hash = 0xcc },
    };
    try table.inherit(testing.allocator, &prev, &cur);

    try testing.expectEqual(@as(ChangeId, 1), cur[0].id);
    try testing.expectEqual(@as(ChangeId, 1), table.resolve(2));
    try testing.expectEqual(@as(ChangeId, 1), table.resolve(1));
}

test "a split keeps the id on the larger fragment and numbers the rest" {
    var table: IdTable = .{ .next = 2 };
    defer table.deinit(testing.allocator);

    var prev = [_]Hunk{
        .{ .old_start = 10, .old_count = 10, .new_start = 10, .new_count = 10, .lo = 0, .hi = 10, .hash = 0xaa, .id = 1 },
    };
    var cur = [_]Hunk{
        .{ .old_start = 10, .old_count = 2, .new_start = 10, .new_count = 2, .lo = 0, .hi = 2, .hash = 0xdd },
        .{ .old_start = 14, .old_count = 6, .new_start = 14, .new_count = 6, .lo = 2, .hi = 8, .hash = 0xee },
    };
    try table.inherit(testing.allocator, &prev, &cur);

    // The larger overlap keeps #1; the smaller fragment is a new change.
    try testing.expectEqual(@as(ChangeId, 1), cur[1].id);
    try testing.expect(cur[0].id != 1);
    try testing.expect(cur[0].id != no_id);
}

test "an unrelated hunk gets a fresh id" {
    var table: IdTable = .{ .next = 7 };
    defer table.deinit(testing.allocator);

    var prev = [_]Hunk{
        .{ .old_start = 10, .old_count = 2, .new_start = 10, .new_count = 2, .lo = 0, .hi = 2, .hash = 0xaa, .id = 1 },
    };
    var cur = [_]Hunk{
        .{ .old_start = 10, .old_count = 2, .new_start = 10, .new_count = 2, .lo = 0, .hi = 2, .hash = 0xaa },
        .{ .old_start = 90, .old_count = 3, .new_start = 90, .new_count = 3, .lo = 2, .hi = 5, .hash = 0xff },
    };
    try table.inherit(testing.allocator, &prev, &cur);

    try testing.expectEqual(@as(ChangeId, 1), cur[0].id);
    try testing.expectEqual(@as(ChangeId, 7), cur[1].id);
}

test "overlap is measured on new-file ranges" {
    const h: Hunk = .{ .old_start = 0, .old_count = 0, .new_start = 10, .new_count = 5, .lo = 0, .hi = 0 };
    try testing.expectEqual(@as(u32, 5), h.overlapsNew(10, 5));
    try testing.expectEqual(@as(u32, 2), h.overlapsNew(13, 4));
    try testing.expectEqual(@as(u32, 0), h.overlapsNew(15, 3));
    try testing.expectEqual(@as(u32, 0), h.overlapsNew(0, 5));
}
