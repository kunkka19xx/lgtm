// SPDX-License-Identifier: Apache-2.0
//
// Soft wrap: which bytes of one diff line go on which screen row.
//
// A width in columns goes in, byte ranges come out. No terminal and no diff,
// so the same answer serves both `ui/body.zig`, which draws the ranges, and
// `ui/app.zig`, which needs the row heights before it can scroll. Two
// implementations of this would disagree the first time one of them met a
// double-width glyph, and the disagreement would look like a scroll bug.
//
// Greedy and whitespace-only: a row ends at the last space that fits, and a
// word longer than the pane is broken where it runs out of columns. Breaking
// on punctuation as well (vim's `breakat`) reads better for paths and worse
// for prose, and prose is what a review pane is mostly full of.

const std = @import("std");
const vaxis = @import("vaxis");

/// How a grapheme's column count is measured. The screen's own method, so a
/// row measured here is the row vaxis draws (`Screen.width_method`).
pub const Method = vaxis.gwidth.Method;

/// One screen row of a wrapped line, as a byte range of the line's text.
pub const Chunk = struct {
    start: u32,
    end: u32,

    pub fn slice(self: Chunk, text: []const u8) []const u8 {
        return text[self.start..self.end];
    }
};

pub const Iterator = struct {
    text: []const u8,
    /// Columns the text has to itself, the gutter already taken off. Zero
    /// means no room at all, which yields the line as one chunk rather than
    /// an endless sequence of empty ones.
    width: u16,
    method: Method,
    /// Every byte below 0x80, so a column is a byte and the grapheme walk can
    /// be skipped entirely. Overwhelmingly the common case for source.
    ascii: bool,
    at: u32 = 0,
    done: bool = false,

    pub fn init(text: []const u8, width: u16, method: Method) Iterator {
        return .{
            .text = text,
            .width = width,
            .method = method,
            .ascii = isAscii(text),
        };
    }

    pub fn next(self: *Iterator) ?Chunk {
        if (self.done) return null;
        var start = self.at;
        // A hard break can land on a space. Carrying it to the next row would
        // indent a continuation by a column that means nothing.
        if (start > 0) {
            while (start < self.text.len and isSpace(self.text[start])) start += 1;
            self.at = start;
        }
        if (start >= self.text.len) {
            self.done = true;
            // An empty line is one row, not none: it still has a gutter, and a
            // zero-row line would make the row model and the screen disagree.
            return if (start == 0) .{ .start = 0, .end = 0 } else null;
        }
        if (self.width == 0) {
            self.done = true;
            return .{ .start = start, .end = @intCast(self.text.len) };
        }

        var col: u16 = 0;
        var i: u32 = start;
        // Where this row ends and where the next one begins, at the last space
        // we have passed. They differ because the space itself is drawn on
        // neither: it is the seam, not content.
        var brk_end: u32 = 0;
        var brk_next: u32 = 0;
        var have_brk = false;
        var prev_space = false;

        while (i < self.text.len) {
            const step = self.stepAt(i);
            if (col + step.cols > self.width) {
                // A space at the edge is the seam itself, not content that
                // failed to fit: the row before it is full and ends there.
                if (isSpace(self.text[i])) {
                    self.at = i + step.len;
                    // Mid-run, the row ended where the run began: trailing
                    // spaces belong to the seam too.
                    return .{ .start = start, .end = if (prev_space) brk_end else i };
                }
                if (have_brk) {
                    self.at = brk_next;
                    return .{ .start = start, .end = brk_end };
                }
                // A single grapheme wider than the whole pane still has to be
                // consumed, or this loops forever on a two-column window.
                if (i == start) {
                    self.at = i + step.len;
                    return .{ .start = start, .end = self.at };
                }
                self.at = i;
                return .{ .start = start, .end = i };
            }

            const space = isSpace(self.text[i]);
            if (space) {
                if (!prev_space and i > start) {
                    brk_end = i;
                    have_brk = true;
                }
                // The next row starts after the whole run, so a double space
                // does not indent the continuation.
                if (have_brk) brk_next = i + step.len;
            }
            prev_space = space;

            col += step.cols;
            i += step.len;
        }

        self.at = i;
        self.done = true;
        return .{ .start = start, .end = i };
    }

    const Step = struct { len: u32, cols: u16 };

    fn stepAt(self: Iterator, i: u32) Step {
        if (self.ascii) {
            // Control bytes are what vaxis draws them as: nothing. A tab is
            // one of them, which is why a tab-indented line renders flush
            // left - a display decision that belongs with the renderer, not
            // here, but the two have to agree on the count.
            const b = self.text[i];
            return .{ .len = 1, .cols = if (b < 0x20 or b == 0x7f) 0 else 1 };
        }
        var it = vaxis.unicode.graphemeIterator(self.text[i..]);
        const g = it.next() orelse return .{ .len = 1, .cols = 1 };
        const bytes = self.text[i..][g.start .. g.start + g.len];
        return .{
            .len = @intCast(g.start + g.len),
            .cols = vaxis.gwidth.gwidth(bytes, self.method),
        };
    }
};

/// Byte length of the longest prefix of `text` that fits in `cols` display
/// columns. A grapheme that would straddle the edge is left out entirely: half
/// a character is not a character.
pub fn fitFront(text: []const u8, cols: u16, method: Method) usize {
    if (cols == 0) return 0;
    const it: Iterator = .init(text, cols, method);
    var col: u16 = 0;
    var i: u32 = 0;
    while (i < text.len) {
        const step = it.stepAt(i);
        if (col + step.cols > cols) break;
        col += step.cols;
        i += step.len;
    }
    return i;
}

/// Byte offset where the longest *suffix* of `text` that fits in `cols`
/// begins.
///
/// One forward pass rather than a backwards walk: vaxis iterates graphemes in
/// one direction only, and the strings this is asked about are paths, which
/// are short enough that measuring twice costs nothing.
pub fn fitBack(text: []const u8, cols: u16, method: Method) usize {
    const total = columns(text, method);
    if (total <= cols) return 0;
    const drop = total - cols;
    const it: Iterator = .init(text, cols, method);
    var col: u16 = 0;
    var i: u32 = 0;
    while (i < text.len) {
        const step = it.stepAt(i);
        col += step.cols;
        i += step.len;
        if (col >= drop) return i;
    }
    return text.len;
}

/// Screen rows `text` occupies in `width` columns, never more than `cap` and
/// never fewer than one. The cap is the body height: nothing taller than the
/// pane can be scrolled past, so counting further is work with no reader.
pub fn height(text: []const u8, width: u16, method: Method, cap: u16) u16 {
    if (width == 0 or cap <= 1) return 1;
    // The line that fits, which is almost all of them.
    if (text.len <= width and isAscii(text)) return 1;

    var it: Iterator = .init(text, width, method);
    var n: u16 = 0;
    while (it.next()) |_| {
        n += 1;
        if (n >= cap) break;
    }
    return @max(n, 1);
}

/// Where one byte offset of a line is drawn: which of the line's screen rows,
/// and how many columns into it. Relative to the line, so the caller adds its
/// own row and gutter.
pub const Cell = struct {
    row: u16 = 0,
    col: u16 = 0,
};

/// Locates `offset` in the wrapped line. A `width` of zero measures the line
/// unwrapped, which is what a caller with wrapping off wants: one row, and a
/// column that may run past the pane for it to clamp.
///
/// An offset inside a seam - a space the wrap dropped - belongs to the end of
/// the row before it, which is where a cursor sitting on that space is drawn.
pub fn locate(text: []const u8, width: u16, method: Method, offset: u32) Cell {
    var it: Iterator = .init(text, width, method);
    var row: u16 = 0;
    var prev: Chunk = .{ .start = 0, .end = 0 };
    while (it.next()) |chunk| {
        // Skipped over: the offset is a space this row dropped, so it is drawn
        // at the end of the row before it.
        if (offset < chunk.start) {
            return .{ .row = row -| 1, .col = columns(prev.slice(text), method) };
        }
        if (offset < chunk.end) {
            return .{ .row = row, .col = columns(text[chunk.start..offset], method) };
        }
        prev = chunk;
        row += 1;
    }
    // Past the last byte: the cell just after the final row's text, which is
    // where an offset at the end of the line belongs.
    return .{ .row = row -| 1, .col = columns(prev.slice(text), method) };
}

/// Display columns of a run of text, with the same ASCII shortcut the wrap
/// itself takes.
pub fn columns(text: []const u8, method: Method) u16 {
    if (isAscii(text)) {
        var n: u16 = 0;
        for (text) |b| {
            if (b >= 0x20 and b != 0x7f) n += 1;
        }
        return n;
    }
    return vaxis.gwidth.gwidth(text, method);
}

fn isSpace(b: u8) bool {
    return b == ' ' or b == '\t';
}

fn isAscii(text: []const u8) bool {
    for (text) |b| {
        if (b >= 0x80) return false;
    }
    return true;
}

const testing = std.testing;

fn chunksOf(gpa: std.mem.Allocator, text: []const u8, width: u16) ![]Chunk {
    var out: std.ArrayList(Chunk) = .empty;
    var it: Iterator = .init(text, width, .unicode);
    while (it.next()) |ch| try out.append(gpa, ch);
    return out.toOwnedSlice(gpa);
}

fn rowsOf(gpa: std.mem.Allocator, text: []const u8, width: u16) ![][]const u8 {
    const chunks = try chunksOf(gpa, text, width);
    defer gpa.free(chunks);
    const out = try gpa.alloc([]const u8, chunks.len);
    for (chunks, 0..) |ch, i| out[i] = ch.slice(text);
    return out;
}

test "a line that fits is one row" {
    const gpa = testing.allocator;
    const got = try rowsOf(gpa, "const x = 1;", 40);
    defer gpa.free(got);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("const x = 1;", got[0]);
    try testing.expectEqual(@as(u16, 1), height("const x = 1;", 40, .unicode, 20));
}

test "wrapping breaks at the last space that fits and drops it" {
    const gpa = testing.allocator;
    const got = try rowsOf(gpa, "the block is a different thing", 14);
    defer gpa.free(got);

    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqualStrings("the block is a", got[0]);
    try testing.expectEqualStrings("different", got[1]);
    try testing.expectEqualStrings("thing", got[2]);
    try testing.expectEqual(@as(u16, 3), height("the block is a different thing", 14, .unicode, 20));
}

test "a run of spaces is one seam, not an indent on the next row" {
    const gpa = testing.allocator;
    const got = try rowsOf(gpa, "alpha beta   gamma delta", 12);
    defer gpa.free(got);

    try testing.expectEqualStrings("alpha beta", got[0]);
    try testing.expectEqualStrings("gamma delta", got[1]);
}

test "a word longer than the pane is broken where the columns run out" {
    const gpa = testing.allocator;
    const got = try rowsOf(gpa, "src/verylongpathname/file.zig", 10);
    defer gpa.free(got);

    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqualStrings("src/verylo", got[0]);
    try testing.expectEqualStrings("ngpathname", got[1]);
    try testing.expectEqualStrings("/file.zig", got[2]);
}

test "leading indentation survives, and is not mistaken for a seam" {
    const gpa = testing.allocator;
    const got = try rowsOf(gpa, "    const value = compute();", 20);
    defer gpa.free(got);

    try testing.expectEqualStrings("    const value =", got[0]);
    try testing.expectEqualStrings("compute();", got[1]);
}

test "a wrap covers the whole line and drops nothing but spaces" {
    const gpa = testing.allocator;
    const text = "a bb ccc dddd eeeee ffffff ggggggg hhhhhhhh";
    for ([_]u16{ 1, 2, 3, 5, 8, 13, 21, 34 }) |w| {
        const got = try chunksOf(gpa, text, w);
        defer gpa.free(got);

        try testing.expectEqual(@as(u32, 0), got[0].start);
        try testing.expectEqual(@as(u32, text.len), got[got.len - 1].end);
        for (got, 0..) |ch, i| {
            // An empty row would be a row the reader cannot account for, and
            // an iterator that could emit one could emit them forever.
            try testing.expect(ch.end > ch.start);
            if (i == 0) continue;
            // Only the seam is skipped, and a seam is only ever whitespace.
            const gap = text[got[i - 1].end..ch.start];
            for (gap) |b| try testing.expect(b == ' ' or b == '\t');
        }
    }
}

test "an empty line is one row and terminates" {
    const gpa = testing.allocator;
    const got = try rowsOf(gpa, "", 20);
    defer gpa.free(got);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("", got[0]);
    try testing.expectEqual(@as(u16, 1), height("", 20, .unicode, 20));
}

test "no room at all yields the line once rather than forever" {
    const gpa = testing.allocator;
    const got = try rowsOf(gpa, "something", 0);
    defer gpa.free(got);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqual(@as(u16, 1), height("something", 0, .unicode, 20));
}

test "a wide glyph counts two columns and never stalls in a one-column pane" {
    const gpa = testing.allocator;
    // Each of these is two columns wide, so two of them fill a four-column pane.
    const got = try rowsOf(gpa, "\u{4f60}\u{597d}\u{4e16}\u{754c}", 4);
    defer gpa.free(got);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("\u{4f60}\u{597d}", got[0]);

    // One column cannot hold a two-column glyph; it takes the row anyway.
    const narrow = try rowsOf(gpa, "\u{4f60}\u{597d}", 1);
    defer gpa.free(narrow);
    try testing.expectEqual(@as(usize, 2), narrow.len);
}

test "an offset is located on the row and column it is drawn at" {
    const text = "the block is a different thing";

    // Unwrapped: one row, and the column is the display width before it.
    try testing.expectEqual(@as(u16, 0), locate(text, 0, .unicode, 10).row);
    try testing.expectEqual(@as(u16, 10), locate(text, 0, .unicode, 10).col);

    // Wrapped at 14: "the block is a" / "different" / "thing".
    try testing.expectEqual(Cell{ .row = 0, .col = 4 }, locate(text, 14, .unicode, 4));
    // "different" starts at byte 15, the first column of the second row.
    try testing.expectEqual(Cell{ .row = 1, .col = 0 }, locate(text, 14, .unicode, 15));
    try testing.expectEqual(Cell{ .row = 1, .col = 3 }, locate(text, 14, .unicode, 18));
    // "thing" starts at byte 25.
    try testing.expectEqual(Cell{ .row = 2, .col = 0 }, locate(text, 14, .unicode, 25));

    // Byte 14 is the seam - a space no row draws - so it belongs to the end of
    // the row before it rather than to the start of the next.
    try testing.expectEqual(Cell{ .row = 0, .col = 14 }, locate(text, 14, .unicode, 14));

    // Past the end is the cell after the last character, not a trap.
    try testing.expectEqual(Cell{ .row = 2, .col = 5 }, locate(text, 14, .unicode, 99));
    // An empty line has one cell, at the origin.
    try testing.expectEqual(Cell{ .row = 0, .col = 0 }, locate("", 14, .unicode, 0));
}

test "a wide glyph is measured in columns, not bytes" {
    const text = "a\u{4f60}b";
    // The glyph at byte 1 is two columns, so `b` at byte 4 sits at column 3.
    try testing.expectEqual(@as(u16, 1), locate(text, 0, .unicode, 1).col);
    try testing.expectEqual(@as(u16, 3), locate(text, 0, .unicode, 4).col);
    try testing.expectEqual(@as(u16, 4), columns(text, .unicode));
}

test "the height cap stops counting rather than walking a generated line" {
    var buf: [4000]u8 = undefined;
    @memset(&buf, 'x');
    try testing.expectEqual(@as(u16, 5), height(&buf, 40, .unicode, 5));
}
