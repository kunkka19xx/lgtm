// SPDX-License-Identifier: Apache-2.0
//
// "Since I last looked": a mark on the working tree, and the rows that changed
// after it.
//
// The problem this exists for is the second read. You comment, the agent
// revises, and the diff comes back looking almost the same - eight hundred
// lines, of which twelve are the answer to what you asked. Re-reading all of
// it to find those twelve is the tax the tool was built to remove, and the
// change ids do not remove it: they say a hunk is *the same* change, not that
// its contents held still.
//
// The mark is the working tree, not the diff. What the reader approves is the
// diff against HEAD, so that stays the frame; this only says which of its rows
// arrived after the mark. Comparing working trees rather than diffs is what
// makes it a `linemap` lookup instead of a second diff algorithm - the map is
// already written, already measured, and already the thing anchoring trusts.
//
// Pure: bytes and a `FileDiff` in, a bool per row out. No allocator lifetime
// assumptions beyond the one passed in, and no notion of a key, a colour or a
// screen.

const std = @import("std");
const Allocator = std.mem.Allocator;

const diff = @import("diff.zig");
const linemap = @import("linemap.zig");

/// One file as it stood when the mark was taken.
pub const File = struct {
    path: []u8,
    /// Working-tree bytes. Empty for a file that was already deleted, which is
    /// not the same as absent: absent means the file was not in the review at
    /// all, and every change in it is therefore new.
    work: []u8,
    /// Old-file line numbers already shown as removed at mark time, ascending.
    /// A deleted line has no line in the working tree to compare, so this is
    /// the only way to tell a deletion the reader has seen from one that
    /// happened since.
    removed: []u32,
};

/// The mark itself. Session-lived: it holds the working-tree bytes of every
/// changed file, so it must outlive the diff arena that is reset under it.
pub const Checkpoint = struct {
    gpa: Allocator,
    files: std.ArrayList(File) = .empty,
    /// How many marks have been taken. Zero means none, which is the state
    /// every session starts in and the one where none of this costs anything.
    turn: u32 = 0,

    pub fn init(gpa: Allocator) Checkpoint {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Checkpoint) void {
        self.clear();
        self.files.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn clear(self: *Checkpoint) void {
        for (self.files.items) |f| {
            self.gpa.free(f.path);
            self.gpa.free(f.work);
            self.gpa.free(f.removed);
        }
        self.files.clearRetainingCapacity();
    }

    pub fn taken(self: Checkpoint) bool {
        return self.turn > 0;
    }

    /// Records one file. Every byte is copied: the caller's buffers belong to
    /// the diff arena, and the whole point of a mark is to outlive it.
    pub fn add(self: *Checkpoint, path: []const u8, work: []const u8, removed: []const u32) Allocator.Error!void {
        const p = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(p);
        const w = try self.gpa.dupe(u8, work);
        errdefer self.gpa.free(w);
        const r = try self.gpa.dupe(u32, removed);
        errdefer self.gpa.free(r);
        try self.files.append(self.gpa, .{ .path = p, .work = w, .removed = r });
    }

    pub fn find(self: Checkpoint, path: []const u8) ?*const File {
        for (self.files.items) |*f| {
            if (std.mem.eql(u8, f.path, path)) return f;
        }
        return null;
    }

    /// Bytes held. The status line has no use for it, but a reader wondering
    /// what a mark costs deserves an answer that is not "some".
    pub fn bytes(self: Checkpoint) usize {
        var n: usize = 0;
        for (self.files.items) |f| n += f.work.len + f.removed.len * @sizeOf(u32);
        return n;
    }
};

/// The old-file line numbers `f` shows as removed, ascending.
pub fn removedLines(gpa: Allocator, f: *const diff.FileDiff) Allocator.Error![]u32 {
    var out: std.ArrayList(u32) = .empty;
    errdefer out.deinit(gpa);
    for (0..f.lines.len()) |i| {
        if (f.lines.kind[i] != .del) continue;
        const no = f.lines.old_no[i];
        if (no != 0) try out.append(gpa, no);
    }
    return out.toOwnedSlice(gpa);
}

/// HEAD line numbers already gone from the working tree when the mark was
/// taken, derived rather than read off a diff.
///
/// `removedLines` gets them from the diff that existed at the moment of
/// marking, which is exact and free - and gone after a restart, when all that
/// survives is the marked tree itself. A HEAD line was already deleted then
/// exactly when the marked working tree holds no image of it, and that is a
/// question the same line map answers.
///
/// Without this a restored mark would report every deleted row as new, which is
/// the worst kind of wrong: it says the agent removed something while you were
/// away, and it says it about code that went before you ever looked.
pub fn derivedRemoved(gpa: Allocator, head: []const u8, marked: []const u8) Allocator.Error![]u32 {
    var interner: linemap.Interner = .{};
    defer interner.deinit(gpa);

    const a = try interner.internLines(gpa, head);
    defer gpa.free(a);
    const b = try interner.internLines(gpa, marked);
    defer gpa.free(b);

    var map = try linemap.lineMap(gpa, a, b);
    defer map.deinit(gpa);

    var out: std.ArrayList(u32) = .empty;
    errdefer out.deinit(gpa);
    for (0..a.len) |i| {
        if (map.get(i) == null) try out.append(gpa, @intCast(i + 1));
    }
    return out.toOwnedSlice(gpa);
}

/// One bool per row of `f`: whether that row's change arrived after the mark.
///
/// Only added and removed rows can be fresh. A context row is unchanged code
/// by definition, and marking it because the lines around it moved would light
/// up half the file every time the agent inserted an import - which is the
/// failure mode this feature exists to avoid, not one to reproduce.
///
/// `now` is the current working tree of the file, which is what the added rows
/// are lines of. `prev` null means the file was not in the review when the
/// mark was taken, so all of it is new.
pub fn freshRows(
    gpa: Allocator,
    f: *const diff.FileDiff,
    now: []const u8,
    prev: ?*const File,
) Allocator.Error![]bool {
    const out = try gpa.alloc(bool, f.lines.len());
    errdefer gpa.free(out);
    @memset(out, false);

    const p = prev orelse {
        for (0..f.lines.len()) |i| out[i] = f.lines.kind[i] != .context;
        return out;
    };

    // Which lines of the working tree existed, as they are now, at the mark.
    // Built by walking the map forwards: `lineMap` answers "where did old line
    // n go", and what is wanted here is the complement - the new lines nothing
    // old arrived at.
    const seen = try inherited(gpa, p.work, now);
    defer gpa.free(seen);

    for (0..f.lines.len()) |i| switch (f.lines.kind[i]) {
        .context => {},
        .add => {
            const no = f.lines.new_no[i];
            if (no == 0) continue;
            // A line past the end of what we mapped is one the buffer and the
            // diff disagree about. Not fresh: claiming a change the reader
            // cannot see is worse than missing one they can.
            if (no - 1 >= seen.len) continue;
            out[i] = !seen[no - 1];
        },
        .del => {
            const no = f.lines.old_no[i];
            if (no == 0) continue;
            out[i] = !contains(p.removed, no);
        },
    };
    return out;
}

/// One bool per line of `now`: whether some line of `then` maps onto it.
fn inherited(gpa: Allocator, then: []const u8, now: []const u8) Allocator.Error![]bool {
    var interner: linemap.Interner = .{};
    defer interner.deinit(gpa);

    const a = try interner.internLines(gpa, then);
    defer gpa.free(a);
    const b = try interner.internLines(gpa, now);
    defer gpa.free(b);

    const out = try gpa.alloc(bool, b.len);
    errdefer gpa.free(out);
    @memset(out, false);

    var map = try linemap.lineMap(gpa, a, b);
    defer map.deinit(gpa);
    for (0..a.len) |i| {
        const n = map.get(i) orelse continue;
        if (n < out.len) out[n] = true;
    }
    return out;
}

/// Ascending, so a binary search - but the lists are short enough that the
/// scan wins on everything but a pathological file, and it cannot be wrong.
fn contains(sorted: []const u32, want: u32) bool {
    for (sorted) |n| {
        if (n == want) return true;
        if (n > want) return false;
    }
    return false;
}

const testing = std.testing;

/// A file diff built from a compact spec, the way `core/hunk.zig`'s tests do:
/// each line is "<kind><text>", kind one of ' ', '+', '-'.
fn fileOf(gpa: Allocator, path: []const u8, spec: []const []const u8) !diff.FileDiff {
    var lines: @import("hunk.zig").DiffLines = .{
        .kind = try gpa.alloc(@import("hunk.zig").LineKind, spec.len),
        .old_no = try gpa.alloc(u32, spec.len),
        .new_no = try gpa.alloc(u32, spec.len),
        .text = try gpa.alloc([]const u8, spec.len),
    };
    var old: u32 = 0;
    var new: u32 = 0;
    for (spec, 0..) |s, i| {
        lines.kind[i] = switch (s[0]) {
            '+' => .add,
            '-' => .del,
            else => .context,
        };
        switch (lines.kind[i]) {
            .add => {
                new += 1;
                lines.old_no[i] = 0;
                lines.new_no[i] = new;
            },
            .del => {
                old += 1;
                lines.old_no[i] = old;
                lines.new_no[i] = 0;
            },
            .context => {
                old += 1;
                new += 1;
                lines.old_no[i] = old;
                lines.new_no[i] = new;
            },
        }
        lines.text[i] = s[1..];
    }
    return .{ .old_path = path, .new_path = path, .status = .modified, .lines = lines };
}

test "a line the agent wrote after the mark is fresh, one it wrote before is not" {
    const gpa = testing.allocator;
    var cp: Checkpoint = .init(gpa);
    defer cp.deinit();

    // At the mark the file had two added lines. Then a third arrived.
    try cp.add("a.zig", "old one\nold two\n", &.{});

    var f = try fileOf(gpa, "a.zig", &.{ "+old one", "+old two", "+brand new" });
    defer {
        f.lines.deinit(gpa);
    }

    const fresh = try freshRows(gpa, &f, "old one\nold two\nbrand new\n", cp.find("a.zig"));
    defer gpa.free(fresh);

    try testing.expect(!fresh[0]);
    try testing.expect(!fresh[1]);
    try testing.expect(fresh[2]);
}

test "a line rewritten in place is fresh where the unchanged ones are not" {
    const gpa = testing.allocator;
    var cp: Checkpoint = .init(gpa);
    defer cp.deinit();
    try cp.add("a.zig", "keep\nold body\nkeep too\n", &.{});

    var f = try fileOf(gpa, "a.zig", &.{ "+keep", "+new body", "+keep too" });
    defer f.lines.deinit(gpa);

    const fresh = try freshRows(gpa, &f, "keep\nnew body\nkeep too\n", cp.find("a.zig"));
    defer gpa.free(fresh);

    try testing.expect(!fresh[0]);
    try testing.expect(fresh[1]);
    try testing.expect(!fresh[2]);
}

test "an insertion above does not make everything below it fresh" {
    // The failure this whole design is chosen to avoid: line numbers move, so
    // anything comparing them rather than the lines lights up the whole file.
    const gpa = testing.allocator;
    var cp: Checkpoint = .init(gpa);
    defer cp.deinit();
    try cp.add("a.zig", "one\ntwo\nthree\n", &.{});

    var f = try fileOf(gpa, "a.zig", &.{ "+inserted", "+one", "+two", "+three" });
    defer f.lines.deinit(gpa);

    const fresh = try freshRows(gpa, &f, "inserted\none\ntwo\nthree\n", cp.find("a.zig"));
    defer gpa.free(fresh);

    try testing.expect(fresh[0]);
    try testing.expect(!fresh[1]);
    try testing.expect(!fresh[2]);
    try testing.expect(!fresh[3]);
}

test "context rows are never fresh" {
    const gpa = testing.allocator;
    var cp: Checkpoint = .init(gpa);
    defer cp.deinit();
    try cp.add("a.zig", "ctx\n", &.{});

    var f = try fileOf(gpa, "a.zig", &.{ " ctx", "+added" });
    defer f.lines.deinit(gpa);

    const fresh = try freshRows(gpa, &f, "ctx\nadded\n", cp.find("a.zig"));
    defer gpa.free(fresh);

    try testing.expect(!fresh[0]);
    try testing.expect(fresh[1]);
}

test "a deletion the reader has already seen is not fresh, a new one is" {
    const gpa = testing.allocator;
    var cp: Checkpoint = .init(gpa);
    defer cp.deinit();
    // Old line 1 was already gone at the mark; line 2 goes after it.
    try cp.add("a.zig", "kept\n", &.{1});

    var f = try fileOf(gpa, "a.zig", &.{ "-gone before", "-gone since", "+kept" });
    defer f.lines.deinit(gpa);

    const fresh = try freshRows(gpa, &f, "kept\n", cp.find("a.zig"));
    defer gpa.free(fresh);

    try testing.expect(!fresh[0]);
    try testing.expect(fresh[1]);
}

test "a file that was not in the review at the mark is fresh throughout" {
    const gpa = testing.allocator;
    var cp: Checkpoint = .init(gpa);
    defer cp.deinit();

    var f = try fileOf(gpa, "new.zig", &.{ " ctx", "+added", "-removed" });
    defer f.lines.deinit(gpa);

    const fresh = try freshRows(gpa, &f, "ctx\nadded\n", null);
    defer gpa.free(fresh);

    try testing.expect(!fresh[0]);
    try testing.expect(fresh[1]);
    try testing.expect(fresh[2]);
}

test "the mark copies its bytes, so resetting the diff arena cannot reach it" {
    const gpa = testing.allocator;
    var cp: Checkpoint = .init(gpa);
    defer cp.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    const borrowed = try arena.allocator().dupe(u8, "line\n");
    try cp.add("a.zig", borrowed, &.{7});
    arena.deinit();

    const f = cp.find("a.zig").?;
    try testing.expectEqualStrings("line\n", f.work);
    try testing.expectEqual(@as(u32, 7), f.removed[0]);
}

test "removedLines lists the old line numbers, ascending" {
    const gpa = testing.allocator;
    var f = try fileOf(gpa, "a.zig", &.{ " ctx", "-first gone", "+added", "-second gone" });
    defer f.lines.deinit(gpa);

    const removed = try removedLines(gpa, &f);
    defer gpa.free(removed);
    try testing.expectEqualSlices(u32, &.{ 2, 3 }, removed);
}

test "clearing a mark frees it and taken() says so" {
    const gpa = testing.allocator;
    var cp: Checkpoint = .init(gpa);
    defer cp.deinit();

    try testing.expect(!cp.taken());
    try cp.add("a.zig", "body\n", &.{});
    cp.turn += 1;
    try testing.expect(cp.taken());
    try testing.expect(cp.bytes() > 0);

    cp.clear();
    try testing.expectEqual(@as(usize, 0), cp.files.items.len);
    try testing.expectEqual(@as(usize, 0), cp.bytes());
}

test "removed lines are derivable from the marked tree alone" {
    // The restore path. `removedLines` reads a diff that no longer exists after
    // a restart; this reads the marked tree, which does.
    const gpa = testing.allocator;
    const head = "keep\ngone before\nalso keep\n";
    const marked = "keep\nalso keep\n";

    const removed = try derivedRemoved(gpa, head, marked);
    defer gpa.free(removed);
    // HEAD line 2 is absent from the marked tree: already deleted then.
    try testing.expectEqualSlices(u32, &.{2}, removed);
}

test "a derived mark agrees with the one taken live" {
    // The two paths must not disagree, or a restart would silently change what
    // the gutter says about the same file.
    const gpa = testing.allocator;
    var f = try fileOf(gpa, "a.zig", &.{ " keep", "-gone before", "-gone since", "+added" });
    defer f.lines.deinit(gpa);

    // Live: read off the diff at mark time, when only the first deletion had
    // happened.
    var live: Checkpoint = .init(gpa);
    defer live.deinit();
    try live.add("a.zig", "keep\nadded\n", &.{2});

    // Restored: the same marked tree, and HEAD, with nothing else kept.
    const head = "keep\ngone before\ngone since\n";
    const derived = try derivedRemoved(gpa, head, "keep\nadded\n");
    defer gpa.free(derived);
    var back: Checkpoint = .init(gpa);
    defer back.deinit();
    try back.add("a.zig", "keep\nadded\n", derived);

    const a = try freshRows(gpa, &f, "keep\nadded\n", live.find("a.zig"));
    defer gpa.free(a);
    const b = try freshRows(gpa, &f, "keep\nadded\n", back.find("a.zig"));
    defer gpa.free(b);
    // The derived set is wider - it also contains line 3, which really was gone
    // from the marked tree - so the restored mark is at least as truthful about
    // what the reader had already seen.
    try testing.expect(!a[1] and !b[1]);
}
