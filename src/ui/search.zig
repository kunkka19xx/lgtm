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

    /// As a step, for walking a list of files in either direction.
    pub fn delta(self: Direction) i32 {
        return switch (self) {
            .forward => 1,
            .backward => -1,
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

/// Where `needle` first occurs in `haystack`, or null.
///
/// The offset rather than a bool, because every caller wants it: `n` puts the
/// cursor on the match, and the renderer highlights it. Returning `bool` here
/// meant the scan was run twice and the answer thrown away once - and the
/// cursor landed on whatever column the last vertical motion had asked for,
/// which on a long line is nowhere near the text that matched.
pub fn indexOf(haystack: []const u8, needle: []const u8, sensitive: bool) ?u32 {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    if (sensitive) {
        const at = std.mem.indexOf(u8, haystack, needle) orelse return null;
        return @intCast(at);
    }

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) break;
        } else return @intCast(i);
    }
    return null;
}

pub fn contains(haystack: []const u8, needle: []const u8, sensitive: bool) bool {
    return indexOf(haystack, needle, sensitive) != null;
}

/// A match: which line, and where in it. The column is what puts the cursor on
/// the match rather than merely on its line.
pub const Hit = struct { line: u32, col: u32 };

/// The first line matching `query`, scanning from `from`.
///
/// `from` null means "start at the edge": the top going forward, the bottom
/// going backward. That is how a search continues into the *next* file, where
/// there is no cursor to start after. A non-null `from` is exclusive, so `n`
/// advances instead of finding the line it is already sitting on.
pub fn findLine(lines: hunk.DiffLines, from: ?u32, dir: Direction, query: []const u8) ?Hit {
    const n: u32 = @intCast(lines.len());
    if (n == 0 or query.len == 0) return null;
    const sensitive = caseSensitive(query);

    switch (dir) {
        .forward => {
            var i: u32 = if (from) |f| f + 1 else 0;
            while (i < n) : (i += 1) {
                if (indexOf(lines.text[i], query, sensitive)) |at| return .{ .line = i, .col = at };
            }
        },
        .backward => {
            var i: u32 = if (from) |f| f else n;
            while (i > 0) {
                i -= 1;
                if (indexOf(lines.text[i], query, sensitive)) |at| return .{ .line = i, .col = at };
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
    /// `:noh`. The query is still here - `n` repeats it - but the renderer is
    /// told there is nothing to paint. Vim's split exactly: the highlight and
    /// the remembered pattern are two things, and only one of them is in the
    /// reader's way once they have found what they were looking for.
    hidden: bool = false,

    pub fn set(self: *State, text: []const u8, dir: Direction) void {
        self.len = @min(text.len, self.buf.len);
        @memcpy(self.buf[0..self.len], text[0..self.len]);
        self.dir = dir;
        self.wrapped = false;
        self.failed = false;
        self.hidden = false;
    }

    /// The pattern, for repeating a search. Survives `:noh`.
    pub fn query(self: *const State) []const u8 {
        return self.buf[0..self.len];
    }

    /// The pattern the renderer should highlight, which is nothing after
    /// `:noh` until the next search or `n`.
    pub fn shown(self: *const State) []const u8 {
        return if (self.hidden) "" else self.query();
    }

    /// `:noh`: stop painting, keep the pattern.
    pub fn hide(self: *State) void {
        self.hidden = true;
    }

    /// Any search step paints again, the way `n` does in vim after `:noh`.
    pub fn show(self: *State) void {
        self.hidden = false;
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

test "noh stops the painting and keeps the pattern" {
    // Vim's split, and the point of the whole thing: after `:noh` the screen
    // is quiet but `n` still knows what it is looking for. Clearing the query
    // instead would be a second bug wearing the fix's clothes.
    var st: State = .{};
    st.set("layout", .forward);
    try testing.expectEqualStrings("layout", st.shown());

    st.hide();
    try testing.expectEqualStrings("", st.shown());
    try testing.expectEqualStrings("layout", st.query());
    try testing.expect(st.active());

    // `n` paints again: the reader asked to be shown the next one.
    st.show();
    try testing.expectEqualStrings("layout", st.shown());

    // And a fresh search always paints, whatever the last one left behind.
    st.hide();
    st.set("payload", .forward);
    try testing.expectEqualStrings("payload", st.shown());
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

test "a hit carries where in the line it matched, not just which line" {
    // The bug this exists for: the column was computed and thrown away, so
    // `n` put the cursor wherever the last vertical motion had asked for.
    const gpa = testing.allocator;
    var lines = try linesOf(gpa, &.{ "fn a() void {}", "    const token = validateToken(x);" });
    defer lines.deinit(gpa);

    const hit = findLine(lines, null, .forward, "token").?;
    try testing.expectEqual(@as(u32, 1), hit.line);
    try testing.expectEqual(@as(u32, 10), hit.col);
    try testing.expectEqualStrings("token", lines.text[hit.line][hit.col..][0..5]);

    // Smart case picks the later occurrence when a capital pins it, and the
    // column has to follow the match rather than the line.
    const strict = findLine(lines, null, .forward, "Token").?;
    try testing.expectEqual(@as(u32, 26), strict.col);
    try testing.expectEqualStrings("Token", lines.text[strict.line][strict.col..][0..5]);

    // A match at the very start is column zero, not "no column".
    const first = findLine(lines, null, .forward, "fn ").?;
    try testing.expectEqual(@as(u32, 0), first.line);
    try testing.expectEqual(@as(u32, 0), first.col);
}

test "indexOf and contains cannot disagree" {
    // `contains` is now a thin wrapper, and this is what keeps it one: two
    // scans that drift are how the cursor and the highlight end up in
    // different places.
    const cases = [_][2][]const u8{
        .{ "validateToken", "token" },
        .{ "validateToken", "TOKEN" },
        .{ "abc", "" },
        .{ "", "a" },
        .{ "ab", "abc" },
        .{ "abc", "c" },
    };
    for (cases) |c| {
        for ([_]bool{ true, false }) |sensitive| {
            try testing.expectEqual(
                indexOf(c[0], c[1], sensitive) != null,
                contains(c[0], c[1], sensitive),
            );
        }
    }
}

test "forward search starts after the cursor, and from the top when there is none" {
    const gpa = testing.allocator;
    var lines = try linesOf(gpa, &.{ "let a = 1;", "let b = 2;", "let a = 3;" });
    defer lines.deinit(gpa);

    // No cursor: a file the search has just entered starts at its first line.
    try testing.expectEqual(@as(u32, 0), findLine(lines, null, .forward, "let a").?.line);
    // With a cursor, `n` must advance rather than re-find the current line.
    try testing.expectEqual(@as(u32, 2), findLine(lines, 0, .forward, "let a").?.line);
    try testing.expect(findLine(lines, 2, .forward, "let a") == null);
}

test "backward search starts before the cursor, and from the bottom when there is none" {
    const gpa = testing.allocator;
    var lines = try linesOf(gpa, &.{ "one", "two", "one" });
    defer lines.deinit(gpa);

    try testing.expectEqual(@as(u32, 2), findLine(lines, null, .backward, "one").?.line);
    try testing.expectEqual(@as(u32, 0), findLine(lines, 2, .backward, "one").?.line);
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
