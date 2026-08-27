// SPDX-License-Identifier: Apache-2.0
//
// `/`, `?`, `n`, `N`. Pure functions over `DiffLines`, deliberately not over
// `Rows`: rows exist only for the file currently on screen, and a reviewer who
// types `/token` means "anywhere in this review", not "anywhere in this file".
// Scanning lines lets the app find a hit in a file it has not laid out yet and
// only then build that file's rows.
//
// Substring match, not regex. A regex engine is a dependency and a class of
// user-visible failure (a bad pattern) for a feature whose whole job is to
// find an identifier. Regex is a v0.2 question, behind `\v` or a config flag.

const std = @import("std");
const hunk = @import("../core/hunk.zig");

pub const max_bytes = 256;

pub const Direction = enum {
    forward,
    backward,

    pub fn flip(self: Direction) Direction {
        return switch (self) {
            .forward => .backward,
            .backward => .forward,
        };
    }
};

/// Vim's smart case: an all-lowercase query matches either case, and the
/// moment the user types a capital they get exactly what they typed. Chosen
/// over a toggle because the query itself carries the intent.
pub fn caseSensitive(query: []const u8) bool {
    for (query) |ch| {
        if (ch >= 'A' and ch <= 'Z') return true;
    }
    return false;
}

pub fn contains(haystack: []const u8, needle: []const u8, sensitive: bool) bool {
    if (needle.len == 0) return false;
    if (sensitive) return std.mem.indexOf(u8, haystack, needle) != null;
    if (needle.len > haystack.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) break;
        } else return true;
    }
    return false;
}

/// The first line index matching `query`, scanning from `from`.
///
/// `from` null means "start at the edge": the top going forward, the bottom
/// going backward. That is how a search continues into the *next* file, where
/// there is no cursor to start after. A non-null `from` is exclusive, so `n`
/// advances instead of finding the line it is already sitting on.
pub fn findLine(lines: hunk.DiffLines, from: ?u32, dir: Direction, query: []const u8) ?u32 {
    const n: u32 = @intCast(lines.len());
    if (n == 0 or query.len == 0) return null;
    const sensitive = caseSensitive(query);

    switch (dir) {
        .forward => {
            var i: u32 = if (from) |f| f + 1 else 0;
            while (i < n) : (i += 1) {
                if (contains(lines.text[i], query, sensitive)) return i;
            }
        },
        .backward => {
            var i: u32 = if (from) |f| f else n;
            while (i > 0) {
                i -= 1;
                if (contains(lines.text[i], query, sensitive)) return i;
            }
        },
    }
    return null;
}

/// The last query, kept across frames so `n` has something to repeat. Fixed
/// capacity for the same reason as the prompt: a search that can fail to
/// allocate is a search that can lose the query mid-review.
pub const State = struct {
    buf: [max_bytes]u8 = undefined,
    len: usize = 0,
    /// The direction `/` or `?` established. `n` repeats it, `N` flips it.
    dir: Direction = .forward,
    /// Set when the last search wrapped past the end of the review. Shown once
    /// and cleared on the next motion - the same contract as vim's message.
    wrapped: bool = false,
    /// Set when the last search found nothing, so the status line can say so
    /// rather than leaving the cursor mysteriously still.
    failed: bool = false,

    pub fn set(self: *State, text: []const u8, dir: Direction) void {
        self.len = @min(text.len, self.buf.len);
        @memcpy(self.buf[0..self.len], text[0..self.len]);
        self.dir = dir;
        self.wrapped = false;
        self.failed = false;
    }

    pub fn query(self: *const State) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn active(self: *const State) bool {
        return self.len != 0;
    }
};

const testing = std.testing;

fn linesOf(gpa: std.mem.Allocator, texts: []const []const u8) !hunk.DiffLines {
    var l: hunk.DiffLines = .{
        .kind = try gpa.alloc(hunk.LineKind, texts.len),
        .old_no = try gpa.alloc(u32, texts.len),
        .new_no = try gpa.alloc(u32, texts.len),
        .text = try gpa.alloc([]const u8, texts.len),
    };
    for (texts, 0..) |t, i| {
        l.kind[i] = .context;
        l.old_no[i] = @intCast(i + 1);
        l.new_no[i] = @intCast(i + 1);
        l.text[i] = t;
    }
    return l;
}

test "smart case: lowercase matches either, a capital pins it" {
    try testing.expect(!caseSensitive("token"));
    try testing.expect(caseSensitive("Token"));

    try testing.expect(contains("validateToken", "token", false));
    try testing.expect(!contains("validateToken", "token", true));
    try testing.expect(contains("validateToken", "Token", true));
}

test "matching handles the edges without reading past the end" {
    try testing.expect(!contains("ab", "abc", false));
    try testing.expect(!contains("", "a", false));
    try testing.expect(!contains("abc", "", false));
    try testing.expect(contains("abc", "abc", false));
    try testing.expect(contains("abc", "c", false));
}

test "forward search starts after the cursor, and from the top when there is none" {
    const gpa = testing.allocator;
    var lines = try linesOf(gpa, &.{ "let a = 1;", "let b = 2;", "let a = 3;" });
    defer lines.deinit(gpa);

    // No cursor: a file the search has just entered starts at its first line.
    try testing.expectEqual(@as(u32, 0), findLine(lines, null, .forward, "let a").?);
    // With a cursor, `n` must advance rather than re-find the current line.
    try testing.expectEqual(@as(u32, 2), findLine(lines, 0, .forward, "let a").?);
    try testing.expect(findLine(lines, 2, .forward, "let a") == null);
}

test "backward search starts before the cursor, and from the bottom when there is none" {
    const gpa = testing.allocator;
    var lines = try linesOf(gpa, &.{ "one", "two", "one" });
    defer lines.deinit(gpa);

    try testing.expectEqual(@as(u32, 2), findLine(lines, null, .backward, "one").?);
    try testing.expectEqual(@as(u32, 0), findLine(lines, 2, .backward, "one").?);
    try testing.expect(findLine(lines, 0, .backward, "one") == null);
}

test "an empty file or an empty query finds nothing rather than trapping" {
    const gpa = testing.allocator;
    var empty = try linesOf(gpa, &.{});
    defer empty.deinit(gpa);
    try testing.expect(findLine(empty, null, .forward, "x") == null);
    try testing.expect(findLine(empty, null, .backward, "x") == null);

    var some = try linesOf(gpa, &.{"x"});
    defer some.deinit(gpa);
    try testing.expect(findLine(some, null, .forward, "") == null);
}

test "state keeps the query and truncates rather than overrunning" {
    var s: State = .{};
    try testing.expect(!s.active());
    s.set("fn main", .backward);
    try testing.expectEqualStrings("fn main", s.query());
    try testing.expectEqual(Direction.backward, s.dir);
    try testing.expect(s.active());

    var long: [max_bytes * 2]u8 = undefined;
    @memset(&long, 'a');
    s.set(&long, .forward);
    try testing.expectEqual(@as(usize, max_bytes), s.query().len);
}

test "N flips the direction without losing it" {
    try testing.expectEqual(Direction.backward, Direction.forward.flip());
    try testing.expectEqual(Direction.forward, Direction.backward.flip());
}
