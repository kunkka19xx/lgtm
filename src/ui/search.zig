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
const motion = @import("motion.zig");

pub const max_bytes = 256;

/// What to look for, and how strictly.
///
/// `whole` is `*`'s rule: the match must have a non-word byte on each side, so
/// `*` on `id` does not stop on every `width` in the review. `/` leaves it
/// false, because a reader typing a fragment means the fragment.
pub const Pattern = struct {
    text: []const u8 = "",
    whole: bool = false,

    pub fn empty(self: Pattern) bool {
        return self.text.len == 0;
    }
};

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

/// Whether `needle` sits at `at`, without allocating a lowercased copy.
fn matchAt(line: []const u8, at: usize, needle: []const u8, sensitive: bool) bool {
    if (at + needle.len > line.len) return false;
    if (sensitive) return std.mem.eql(u8, line[at..][0..needle.len], needle);
    for (needle, 0..) |c, j| {
        if (std.ascii.toLower(line[at + j]) != std.ascii.toLower(c)) return false;
    }
    return true;
}

/// Whether a match of `n` bytes at `at` has a non-word byte on each side.
///
/// The end of the line counts as a boundary; the end of a *slice* of one does
/// not, which is why every caller passes the whole line.
fn bounded(line: []const u8, at: usize, n: usize) bool {
    if (at > 0 and motion.Class.of(line[at - 1]) == .word) return false;
    const end = at + n;
    return end >= line.len or motion.Class.of(line[end]) != .word;
}

/// Where `pat` next occurs in `line`, at or after `from`.
///
/// The whole line and an offset, rather than a slice starting at the offset,
/// because a whole-word match is defined by the bytes *around* it: handing
/// this a slice would make the cut itself look like a word boundary and match
/// `id` inside `width`.
///
/// The offset comes back rather than a bool, because every caller wants it:
/// `n` puts the cursor on the match, and the renderer highlights it.
pub fn indexOfIn(line: []const u8, from: usize, pat: Pattern, sensitive: bool) ?u32 {
    if (pat.text.len == 0 or from > line.len) return null;
    var i: usize = from;
    while (i + pat.text.len <= line.len) : (i += 1) {
        if (!matchAt(line, i, pat.text, sensitive)) continue;
        if (pat.whole and !bounded(line, i, pat.text.len)) continue;
        return @intCast(i);
    }
    return null;
}

/// Plain substring, from the start: what `/` does.
pub fn indexOf(haystack: []const u8, needle: []const u8, sensitive: bool) ?u32 {
    return indexOfIn(haystack, 0, .{ .text = needle }, sensitive);
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
pub fn findLine(lines: hunk.DiffLines, from: ?u32, dir: Direction, pat: Pattern) ?Hit {
    const n: u32 = @intCast(lines.len());
    if (n == 0 or pat.empty()) return null;
    const sensitive = caseSensitive(pat.text);

    switch (dir) {
        .forward => {
            var i: u32 = if (from) |f| f + 1 else 0;
            while (i < n) : (i += 1) {
                if (indexOfIn(lines.text[i], 0, pat, sensitive)) |at| return .{ .line = i, .col = at };
            }
        },
        .backward => {
            var i: u32 = if (from) |f| f else n;
            while (i > 0) {
                i -= 1;
                if (indexOfIn(lines.text[i], 0, pat, sensitive)) |at| return .{ .line = i, .col = at };
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
    /// Set by `*`, cleared by `/`. It travels with the query because `n` and
    /// the highlight must agree with the search that set them: a strict search
    /// painting loose matches would show hits `n` refuses to visit.
    whole: bool = false,
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
        self.whole = false;
        self.wrapped = false;
        self.failed = false;
        self.hidden = false;
    }

    /// `*` and `#`: the word under the cursor, matched whole.
    pub fn setWord(self: *State, word: []const u8, dir: Direction) void {
        self.set(word, dir);
        self.whole = true;
    }

    /// The pattern, for repeating a search. Survives `:noh`.
    pub fn query(self: *const State) []const u8 {
        return self.buf[0..self.len];
    }

    /// The query and its strictness, which is what a search step needs.
    pub fn pattern(self: *const State) Pattern {
        return .{ .text = self.query(), .whole = self.whole };
    }

    /// The same for the renderer, which paints nothing after `:noh`.
    pub fn shownPattern(self: *const State) Pattern {
        return .{ .text = self.shown(), .whole = self.whole };
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

    const hit = findLine(lines, null, .forward, .{ .text = "token" }).?;
    try testing.expectEqual(@as(u32, 1), hit.line);
    try testing.expectEqual(@as(u32, 10), hit.col);
    try testing.expectEqualStrings("token", lines.text[hit.line][hit.col..][0..5]);

    // Smart case picks the later occurrence when a capital pins it, and the
    // column has to follow the match rather than the line.
    const strict = findLine(lines, null, .forward, .{ .text = "Token" }).?;
    try testing.expectEqual(@as(u32, 26), strict.col);
    try testing.expectEqualStrings("Token", lines.text[strict.line][strict.col..][0..5]);

    // A match at the very start is column zero, not "no column".
    const first = findLine(lines, null, .forward, .{ .text = "fn " }).?;
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
    try testing.expectEqual(@as(u32, 0), findLine(lines, null, .forward, .{ .text = "let a" }).?.line);
    // With a cursor, `n` must advance rather than re-find the current line.
    try testing.expectEqual(@as(u32, 2), findLine(lines, 0, .forward, .{ .text = "let a" }).?.line);
    try testing.expect(findLine(lines, 2, .forward, .{ .text = "let a" }) == null);
}

test "backward search starts before the cursor, and from the bottom when there is none" {
    const gpa = testing.allocator;
    var lines = try linesOf(gpa, &.{ "one", "two", "one" });
    defer lines.deinit(gpa);

    try testing.expectEqual(@as(u32, 2), findLine(lines, null, .backward, .{ .text = "one" }).?.line);
    try testing.expectEqual(@as(u32, 0), findLine(lines, 2, .backward, .{ .text = "one" }).?.line);
    try testing.expect(findLine(lines, 0, .backward, .{ .text = "one" }) == null);
}

test "an empty file or an empty query finds nothing rather than trapping" {
    const gpa = testing.allocator;
    var empty = try linesOf(gpa, &.{});
    defer empty.deinit(gpa);
    try testing.expect(findLine(empty, null, .forward, .{ .text = "x" }) == null);
    try testing.expect(findLine(empty, null, .backward, .{ .text = "x" }) == null);

    var some = try linesOf(gpa, &.{"x"});
    defer some.deinit(gpa);
    try testing.expect(findLine(some, null, .forward, .{ .text = "" }) == null);
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

test "whole-word matching is what makes * usable rather than noise" {
    // The case the feature exists for: `*` on `id` must not stop on `width`,
    // `valid` or `ident`, or it finds forty lines and helps with none.
    const loose: Pattern = .{ .text = "id" };
    const whole: Pattern = .{ .text = "id", .whole = true };

    try testing.expect(indexOfIn("const width = 3;", 0, loose, false) != null);
    try testing.expect(indexOfIn("const width = 3;", 0, whole, false) == null);
    try testing.expect(indexOfIn("if (!valid) return;", 0, whole, false) == null);
    try testing.expect(indexOfIn("const ident = x;", 0, whole, false) == null);
    try testing.expect(indexOfIn("user_id = 1;", 0, whole, false) == null);

    // And must still find the real ones, including at both edges of the line.
    try testing.expectEqual(@as(u32, 6), indexOfIn("const id = 1;", 0, whole, false).?);
    try testing.expectEqual(@as(u32, 0), indexOfIn("id", 0, whole, false).?);
    try testing.expectEqual(@as(u32, 4), indexOfIn("get(id)", 0, whole, false).?);
    try testing.expectEqual(@as(u32, 0), indexOfIn("id.x", 0, whole, false).?);
    try testing.expectEqual(@as(u32, 2), indexOfIn("x.id", 0, whole, false).?);
}

test "a whole-word search skips a near miss and keeps looking on the same line" {
    // The scan must not stop at the first substring hit and call the line
    // clean: `width` comes before `id` here, and both are on one line.
    const whole: Pattern = .{ .text = "id", .whole = true };
    try testing.expectEqual(@as(u32, 11), indexOfIn("width = 3; id = 4;", 0, whole, false).?);
}

test "a whole-word match is decided by the whole line, not by where the scan began" {
    // Why `indexOfIn` takes a line and an offset instead of a slice: starting
    // the scan mid-identifier must not make the cut look like a boundary.
    const whole: Pattern = .{ .text = "id", .whole = true };
    const line = "xid;";
    // Scanning from 1 lands on `id` immediately, but the `x` before it is
    // still there and still a word byte, so this is not a match.
    try testing.expect(indexOfIn(line, 1, whole, false) == null);
    // The same bytes, sliced at the same point, say yes - because the cut has
    // thrown away the only evidence. That is the bug being avoided.
    try testing.expect(indexOfIn(line[1..], 0, whole, false) != null);
}

test "* follows smart case like every other search" {
    const whole: Pattern = .{ .text = "id", .whole = true };
    const cap: Pattern = .{ .text = "ID", .whole = true };
    try testing.expect(indexOfIn("const ID = 1;", 0, whole, false) != null);
    try testing.expect(indexOfIn("const id = 1;", 0, cap, true) == null);
}

test "the strictness travels with the query, and / clears it" {
    // `n` and the highlight both read this. A `*` whose strictness was left
    // behind by a later `/` would paint matches `n` refuses to visit.
    var s: State = .{};
    s.setWord("id", .forward);
    try testing.expect(s.pattern().whole);
    try testing.expect(s.shownPattern().whole);
    try testing.expectEqualStrings("id", s.pattern().text);

    s.set("id", .forward);
    try testing.expect(!s.pattern().whole);

    // `:noh` silences the paint without loosening the pattern.
    s.setWord("id", .forward);
    s.hide();
    try testing.expectEqualStrings("", s.shownPattern().text);
    try testing.expect(s.pattern().whole);
}

test "findLine honours whole-word across lines" {
    const gpa = testing.allocator;
    var lines = try linesOf(gpa, &.{ "const width = 3;", "const valid = x;", "const id = 4;" });
    defer lines.deinit(gpa);

    const hit = findLine(lines, null, .forward, .{ .text = "id", .whole = true }).?;
    try testing.expectEqual(@as(u32, 2), hit.line);
    try testing.expectEqual(@as(u32, 6), hit.col);

    // Loose finds the first line instead, which is exactly the difference.
    try testing.expectEqual(@as(u32, 0), findLine(lines, null, .forward, .{ .text = "id" }).?.line);
}
