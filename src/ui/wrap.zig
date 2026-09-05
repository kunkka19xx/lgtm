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

/// `[ui] tab_width` when the file says nothing. Four rather than eight: the
/// pane this is built for is a split one, and Go indented at eight loses a
/// third of it before the code starts.
pub const default_tab: u16 = 4;

/// The widest tab the config accepts, and the length of the run of spaces the
/// renderer draws one from.
pub const max_tab: u16 = 16;

/// How wide text is on this screen: the grapheme method, and the tab stop.
///
/// One value rather than two parameters because every caller that measures a
/// line has to agree with the renderer about both, and a tab counted here as
/// one width and drawn as another is a cursor in the wrong column.
pub const Metrics = struct {
    method: Method,
    /// Columns between tab stops. A tab advances to the next multiple of it,
    /// which is what every editor does and what keeps gofmt's alignment
    /// aligned.
    tab: u16 = default_tab,
};

/// Whether a continuation row starts under the line's own indentation or at
/// the left edge of the text area.
///
/// `follow` is vim's `breakindent`, and it is for code: indentation there is
/// structure, and a continuation thrown back to column zero reads as the start
/// of a new statement. `flush` is for prose - a review note, the compose box -
/// where leading spaces are whatever the writer happened to type.
pub const Indent = enum { flush, follow };

/// One screen row of a wrapped line, as a byte range of the line's text.
pub const Chunk = struct {
    start: u32,
    end: u32,
    /// Columns into the text area this row is drawn at: zero for the first,
    /// the line's indent for the rest under `follow`.
    col: u16 = 0,

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
    m: Metrics,
    /// Every byte below 0x80, so a column is a byte and the grapheme walk can
    /// be skipped entirely. Overwhelmingly the common case for source.
    ascii: bool,
    /// Columns a continuation row is indented by. Zero under `flush`, and
    /// zero anyway for a line that starts at the left edge.
    indent: u16 = 0,
    at: u32 = 0,
    done: bool = false,

    pub fn init(text: []const u8, width: u16, m: Metrics, indent: Indent) Iterator {
        var it: Iterator = .{
            .text = text,
            .width = width,
            .m = m,
            .ascii = isAscii(text),
        };
        if (indent == .follow) it.indent = it.leadingColumns();
        return it;
    }

    /// Columns of leading whitespace, capped at a third of the width so a
    /// deeply nested line still has most of the pane to wrap into.
    ///
    /// Measured with the same step the wrap itself uses, so a tab indents a
    /// continuation by the columns it is drawn as and the two cannot disagree.
    /// A line that is *nothing but* whitespace has no continuation to indent.
    fn leadingColumns(self: Iterator) u16 {
        if (self.width == 0) return 0;
        var col: u16 = 0;
        var i: u32 = 0;
        while (i < self.text.len and isSpace(self.text[i])) {
            const step = self.stepAt(i, col);
            col += step.cols;
            i += step.len;
        }
        if (i >= self.text.len) return 0;
        return @min(col, self.width / 3);
    }

    pub fn next(self: *Iterator) ?Chunk {
        if (self.done) return null;
        // The first chunk is the one that has not consumed anything yet, and
        // it is the only row drawn flush against the text area's own edge.
        const first = self.at == 0;
        const room = if (first) self.width else self.width -| self.indent;
        const at_col: u16 = if (first) 0 else self.indent;
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
        if (room == 0) {
            self.done = true;
            return .{ .start = start, .end = @intCast(self.text.len), .col = at_col };
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
            const step = self.stepAt(i, at_col + col);
            if (col + step.cols > room) {
                // A space at the edge is the seam itself, not content that
                // failed to fit: the row before it is full and ends there.
                if (isSpace(self.text[i])) {
                    self.at = i + step.len;
                    // Mid-run, the row ended where the run began: trailing
                    // spaces belong to the seam too.
                    return .{ .start = start, .end = if (prev_space) brk_end else i, .col = at_col };
                }
                if (have_brk) {
                    self.at = brk_next;
                    return .{ .start = start, .end = brk_end, .col = at_col };
                }
                // A single grapheme wider than the whole pane still has to be
                // consumed, or this loops forever on a two-column window.
                if (i == start) {
                    self.at = i + step.len;
                    return .{ .start = start, .end = self.at, .col = at_col };
                }
                self.at = i;
                return .{ .start = start, .end = i, .col = at_col };
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
        return .{ .start = start, .end = i, .col = at_col };
    }

    const Step = struct { len: u32, cols: u16 };

    /// `col` is where the byte lands in the text area, which only a tab cares
    /// about: it advances to the next stop rather than by a fixed width, so
    /// the columns a run of them takes depends on where the run began.
    fn stepAt(self: Iterator, i: u32, col: u16) Step {
        if (self.ascii) {
            const b = self.text[i];
            if (b == '\t') return .{ .len = 1, .cols = tabCols(col, self.m.tab) };
            // Every other control byte is what vaxis draws it as: nothing.
            return .{ .len = 1, .cols = if (b < 0x20 or b == 0x7f) 0 else 1 };
        }
        if (self.text[i] == '\t') return .{ .len = 1, .cols = tabCols(col, self.m.tab) };
        var it = vaxis.unicode.graphemeIterator(self.text[i..]);
        const g = it.next() orelse return .{ .len = 1, .cols = 1 };
        const bytes = self.text[i..][g.start .. g.start + g.len];
        return .{
            .len = @intCast(g.start + g.len),
            .cols = vaxis.gwidth.gwidth(bytes, self.m.method),
        };
    }
};

/// Byte length of the longest prefix of `text` that fits in `cols` display
/// columns. A grapheme that would straddle the edge is left out entirely: half
/// a character is not a character.
pub fn fitFront(text: []const u8, cols: u16, m: Metrics) usize {
    if (cols == 0) return 0;
    const it: Iterator = .init(text, cols, m, .flush);
    var col: u16 = 0;
    var i: u32 = 0;
    while (i < text.len) {
        const step = it.stepAt(i, col);
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
pub fn fitBack(text: []const u8, cols: u16, m: Metrics) usize {
    const total = columns(text, m);
    if (total <= cols) return 0;
    const drop = total - cols;
    const it: Iterator = .init(text, cols, m, .flush);
    var col: u16 = 0;
    var i: u32 = 0;
    while (i < text.len) {
        const step = it.stepAt(i, col);
        col += step.cols;
        i += step.len;
        if (col >= drop) return i;
    }
    return text.len;
}

/// Screen rows `text` occupies in `width` columns, never more than `cap` and
/// never fewer than one. The cap is the body height: nothing taller than the
/// pane can be scrolled past, so counting further is work with no reader.
pub fn height(text: []const u8, width: u16, m: Metrics, cap: u16, indent: Indent) u16 {
    if (width == 0 or cap <= 1) return 1;
    // The line that fits, which is almost all of them. A tab is not one byte
    // wide on screen, so a line carrying one is measured properly.
    if (text.len <= width and isPlain(text)) return 1;

    var it: Iterator = .init(text, width, m, indent);
    var n: u16 = 0;
    while (it.next()) |_| {
        n += 1;
        if (n >= cap) break;
    }
    return @max(n, 1);
}

/// Screen rows two texts drawn side by side occupy: the taller of them.
///
/// Both columns get the same number of rows so they stay aligned, with the
/// shorter one leaving the rest blank - which is the whole reason a split view
/// can wrap at all. An absent side is no rows, and a row with neither is still
/// one, because the row model and the screen have to agree about where
/// everything below it is.
pub fn pairHeight(
    left: ?[]const u8,
    left_width: u16,
    right: ?[]const u8,
    right_width: u16,
    m: Metrics,
    cap: u16,
) u16 {
    const l = if (left) |t| height(t, left_width, m, cap, .follow) else 0;
    const r = if (right) |t| height(t, right_width, m, cap, .follow) else 0;
    return @max(@max(l, r), 1);
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
pub fn locate(text: []const u8, width: u16, m: Metrics, offset: u32) Cell {
    var it: Iterator = .init(text, width, m, .follow);
    var row: u16 = 0;
    var prev: Chunk = .{ .start = 0, .end = 0 };
    while (it.next()) |chunk| {
        // Skipped over: the offset is a space this row dropped, so it is drawn
        // at the end of the row before it.
        if (offset < chunk.start) {
            return .{ .row = row -| 1, .col = prev.col + columnsFrom(prev.slice(text), m, prev.col) };
        }
        if (offset < chunk.end) {
            return .{ .row = row, .col = chunk.col + columnsFrom(text[chunk.start..offset], m, chunk.col) };
        }
        prev = chunk;
        row += 1;
    }
    // Past the last byte: the cell just after the final row's text, which is
    // where an offset at the end of the line belongs.
    return .{ .row = row -| 1, .col = prev.col + columnsFrom(prev.slice(text), m, prev.col) };
}

/// Display columns of a run of text starting at column zero. The common call:
/// a path, a label, the whole of a line.
pub fn columns(text: []const u8, m: Metrics) u16 {
    return columnsFrom(text, m, 0);
}

/// The same, for a run that starts `at` columns into the text area. Only a tab
/// reads the offset - it advances to the next stop, so the same run is a
/// different width in a different place.
pub fn columnsFrom(text: []const u8, m: Metrics, at: u16) u16 {
    if (isPlain(text)) {
        var n: u16 = 0;
        for (text) |b| {
            if (b >= 0x20 and b != 0x7f) n += 1;
        }
        return n;
    }
    var col = at;
    const it: Iterator = .init(text, 0, m, .flush);
    var i: u32 = 0;
    while (i < text.len) {
        const step = it.stepAt(i, col);
        col += step.cols;
        i += step.len;
    }
    return col - at;
}

/// Columns a tab at `col` takes: the distance to the next stop, never zero.
pub fn tabCols(col: u16, tab: u16) u16 {
    const stop = if (tab == 0) default_tab else tab;
    return stop - (col % stop);
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

/// ASCII and tab-free: one byte, one column, no measuring needed.
fn isPlain(text: []const u8) bool {
    for (text) |b| {
        if (b >= 0x80 or b == '\t') return false;
    }
    return true;
}

const testing = std.testing;

/// The screen the tests measure against: unicode widths and the default tab.
const tm: Metrics = .{ .method = .unicode };

test "a continuation row starts under the line's own indentation" {
    const gpa = testing.allocator;
    const line = "    const value = compute(a, b, c, d, e, f, g, h);";

    const got = try chunksIn(gpa, line, 24, .follow);
    defer gpa.free(got);
    try testing.expect(got.len > 1);

    // The first row is flush against the text area; every row after it sits
    // under the four spaces the line opened with.
    try testing.expectEqual(@as(u16, 0), got[0].col);
    for (got[1..]) |c| try testing.expectEqual(@as(u16, 4), c.col);

    // And it is a real indent, not a label: the continuation rows have four
    // columns less to wrap into, so there are more of them than flush would
    // have produced.
    const flat = try chunksIn(gpa, line, 24, .flush);
    defer gpa.free(flat);
    for (flat) |c| try testing.expectEqual(@as(u16, 0), c.col);
    try testing.expect(got.len >= flat.len);
    try testing.expectEqual(got.len, height(line, 24, tm, 40, .follow));
}

test "the indent is capped, and costs nothing where it means nothing" {
    const gpa = testing.allocator;

    // A deeply nested line keeps two thirds of the pane: an indent that ate
    // the width would wrap the code into a column and read worse than the
    // flush rows it was meant to improve on.
    const deep = "                              x = one(two, three, four, five);";
    const got = try chunksIn(gpa, deep, 30, .follow);
    defer gpa.free(got);
    try testing.expectEqual(@as(u16, 10), got[1].col);

    // A line with no indent has no indent to follow.
    const flat = try chunksIn(gpa, "aaaa bbbb cccc dddd eeee ffff", 10, .follow);
    defer gpa.free(flat);
    for (flat) |c| try testing.expectEqual(@as(u16, 0), c.col);

    // A tab is drawn as the columns to its next stop, so two of them indent a
    // continuation by two stops - the wrap and the renderer have to agree
    // about that or the rows drift.
    const tabbed = try chunksIn(gpa, "\t\tcall(one, two, three, four, five);", 30, .follow);
    defer gpa.free(tabbed);
    try testing.expect(tabbed.len > 1);
    for (tabbed[1..]) |c| try testing.expectEqual(2 * tm.tab, c.col);

    // A line that is nothing but whitespace has no continuation at all.
    const blank = try chunksIn(gpa, "        ", 10, .follow);
    defer gpa.free(blank);
    try testing.expectEqual(@as(usize, 1), blank.len);
}

test "the cursor lands on the indented column, not the one behind it" {
    const line = "    value(a, b, c, d, e, f, g, h, i, j, k);";
    const w: u16 = 20;

    // The first byte of the second row: its column includes the indent the
    // row is drawn at, or the cursor sits four columns left of its own text.
    const gpa = testing.allocator;
    const got = try chunksIn(gpa, line, w, .follow);
    defer gpa.free(got);
    try testing.expect(got.len > 1);

    const cell = locate(line, w, tm, got[1].start);
    try testing.expectEqual(@as(u16, 1), cell.row);
    try testing.expectEqual(@as(u16, 4), cell.col);
}

test "a split row is as tall as its taller side" {
    const m = tm;
    const short = "fn one() void {}";
    const long = "const long = \"" ++ "y" ** 60 ++ "\";";

    // Twenty columns: the short line fits, the long one does not, and the row
    // takes the taller answer so the two columns stay aligned.
    const tall = height(long, 20, m, 40, .follow);
    try testing.expect(tall > 1);
    try testing.expectEqual(tall, pairHeight(short, 20, long, 20, m, 40));
    try testing.expectEqual(tall, pairHeight(long, 20, short, 20, m, 40));

    // A side that is not there contributes no rows, and a row with neither
    // side is still one row.
    try testing.expectEqual(tall, pairHeight(null, 20, long, 20, m, 40));
    try testing.expectEqual(@as(u16, 1), pairHeight(short, 20, null, 20, m, 40));
    try testing.expectEqual(@as(u16, 1), pairHeight(null, 20, null, 20, m, 40));

    // The cap is the body: nothing taller than the pane can be scrolled past.
    try testing.expectEqual(@as(u16, 3), pairHeight(long, 20, long, 20, m, 3));
}

fn chunksOf(gpa: std.mem.Allocator, text: []const u8, width: u16) ![]Chunk {
    return chunksIn(gpa, text, width, .flush);
}

fn chunksIn(gpa: std.mem.Allocator, text: []const u8, width: u16, indent: Indent) ![]Chunk {
    var out: std.ArrayList(Chunk) = .empty;
    var it: Iterator = .init(text, width, tm, indent);
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
    try testing.expectEqual(@as(u16, 1), height("const x = 1;", 40, tm, 20, .flush));
}

test "wrapping breaks at the last space that fits and drops it" {
    const gpa = testing.allocator;
    const got = try rowsOf(gpa, "the block is a different thing", 14);
    defer gpa.free(got);

    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqualStrings("the block is a", got[0]);
    try testing.expectEqualStrings("different", got[1]);
    try testing.expectEqualStrings("thing", got[2]);
    try testing.expectEqual(@as(u16, 3), height("the block is a different thing", 14, tm, 20, .flush));
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
    try testing.expectEqual(@as(u16, 1), height("", 20, tm, 20, .flush));
}

test "no room at all yields the line once rather than forever" {
    const gpa = testing.allocator;
    const got = try rowsOf(gpa, "something", 0);
    defer gpa.free(got);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqual(@as(u16, 1), height("something", 0, tm, 20, .flush));
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
    try testing.expectEqual(@as(u16, 0), locate(text, 0, tm, 10).row);
    try testing.expectEqual(@as(u16, 10), locate(text, 0, tm, 10).col);

    // Wrapped at 14: "the block is a" / "different" / "thing".
    try testing.expectEqual(Cell{ .row = 0, .col = 4 }, locate(text, 14, tm, 4));
    // "different" starts at byte 15, the first column of the second row.
    try testing.expectEqual(Cell{ .row = 1, .col = 0 }, locate(text, 14, tm, 15));
    try testing.expectEqual(Cell{ .row = 1, .col = 3 }, locate(text, 14, tm, 18));
    // "thing" starts at byte 25.
    try testing.expectEqual(Cell{ .row = 2, .col = 0 }, locate(text, 14, tm, 25));

    // Byte 14 is the seam - a space no row draws - so it belongs to the end of
    // the row before it rather than to the start of the next.
    try testing.expectEqual(Cell{ .row = 0, .col = 14 }, locate(text, 14, tm, 14));

    // Past the end is the cell after the last character, not a trap.
    try testing.expectEqual(Cell{ .row = 2, .col = 5 }, locate(text, 14, tm, 99));
    // An empty line has one cell, at the origin.
    try testing.expectEqual(Cell{ .row = 0, .col = 0 }, locate("", 14, tm, 0));
}

test "a wide glyph is measured in columns, not bytes" {
    const text = "a\u{4f60}b";
    // The glyph at byte 1 is two columns, so `b` at byte 4 sits at column 3.
    try testing.expectEqual(@as(u16, 1), locate(text, 0, tm, 1).col);
    try testing.expectEqual(@as(u16, 3), locate(text, 0, tm, 4).col);
    try testing.expectEqual(@as(u16, 4), columns(text, tm));
}

test "the height cap stops counting rather than walking a generated line" {
    var buf: [4000]u8 = undefined;
    @memset(&buf, 'x');
    try testing.expectEqual(@as(u16, 5), height(&buf, 40, tm, 5, .flush));
}

test "a tab advances to its next stop, wherever it starts" {
    // From the left edge it is a full stop wide; from one column in, the rest
    // of that stop. Alignment is what tabs are for, and a fixed width loses it.
    try testing.expectEqual(tm.tab, tabCols(0, tm.tab));
    try testing.expectEqual(@as(u16, 1), tabCols(tm.tab - 1, tm.tab));
    try testing.expectEqual(tm.tab, tabCols(tm.tab, tm.tab));

    // Two leading tabs are two stops, which is what indented code looks like.
    try testing.expectEqual(2 * tm.tab, columns("\t\t", tm));
    try testing.expectEqual(2 * tm.tab + 1, columns("\t\tx", tm));

    // The same run measured from further along the row is narrower, because
    // the first tab has less of its stop left to give.
    try testing.expectEqual(tm.tab - 1, columnsFrom("\t", tm, 1));

    // And the cursor follows: the byte after a leading tab is drawn one stop in.
    try testing.expectEqual(@as(u16, 0), locate("\tx", 0, tm, 0).col);
    try testing.expectEqual(tm.tab, locate("\tx", 0, tm, 1).col);
}

test "a tab-indented line wraps by the columns it is drawn as" {
    const gpa = testing.allocator;
    // Eight columns of indent at the default stop, so 20 columns of pane leave
    // twelve for the code and the line needs more than one row.
    const line = "\t\tcall(one, two, three);";
    try testing.expect(height(line, 20, tm, 40, .follow) > 1);

    // With the tabs counted as nothing it fit in one row, which is the bug
    // this measures: the byte length is under the width and the drawn one is not.
    try testing.expect(line.len <= 24);
    try testing.expect(height(line, 24, tm, 40, .follow) > 1);

    const got = try chunksIn(gpa, line, 20, .follow);
    defer gpa.free(got);
    try testing.expect(got.len > 1);
}
