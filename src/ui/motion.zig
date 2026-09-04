// SPDX-License-Identifier: Apache-2.0
//
// Motions within one line: bytes in, a byte offset out.
//
// No terminal, no diff, no rows - which is what lets the awkward half of vim's
// word rules be pinned by tests rather than squinted at in a pane. Every
// offset is a byte offset into the line's text and always lands on a grapheme
// boundary (hard rule 3).
//
// A motion that has nowhere to go returns null rather than the offset it
// started from. The caller is what knows whether "nowhere on this line" means
// "stay put" (`h` at column zero) or "carry on into the next line" (`w` at the
// last word), and that decision does not belong to arithmetic over a string.

const std = @import("std");
const vaxis = @import("vaxis");

/// What vim divides a line into. Blank separates; the other two are words, and
/// a boundary between them is a word boundary even with no space in it, which
/// is what makes `w` step through `foo.bar(baz)` the way a reader expects.
pub const Class = enum {
    blank,
    word,
    punct,

    pub fn of(b: u8) Class {
        if (b == ' ' or b == '\t') return .blank;
        if (b == '_' or std.ascii.isAlphanumeric(b)) return .word;
        // Anything above ASCII is a letter as far as a motion is concerned:
        // stepping through an identifier should not stop inside a name.
        if (b >= 0x80) return .word;
        return .punct;
    }
};

/// How wide a word is. `word` is vim's `w`: a change of character class is a
/// boundary, so `foo.bar(baz)` is five of them. `big` is vim's `W`: only
/// whitespace separates, so the same text is one - which is what you want when
/// the thing you are pointing at is a whole path or a whole expression.
pub const Width = enum { word, big };

/// The class a byte has *for this motion*. A WORD motion cannot see the
/// difference between a letter and a bracket, which is the whole of it.
fn classIn(b: u8, width: Width) Class {
    const c = Class.of(b);
    if (width == .big and c == .punct) return .word;
    return c;
}

/// The word under `at`, or the next one on the line when `at` is not on one.
///
/// What `*` looks for. Vim's rule exactly, including the fallback: a cursor
/// resting on the `(` of `login(user)` searches `user` rather than refusing,
/// because that is plainly what the reader was pointing at.
///
/// Word class only, never punctuation. `*` on `=>` would search for an
/// operator that occurs on half the lines in the review, which is not a
/// search, it is a highlight of the language.
pub fn wordAt(text: []const u8, at: u32) ?[]const u8 {
    var i: usize = @min(at, text.len);
    while (i < text.len and Class.of(text[i]) != .word) i += 1;
    if (i == text.len) return null;

    var lo = i;
    while (lo > 0 and Class.of(text[lo - 1]) == .word) lo -= 1;
    var hi = i;
    while (hi < text.len and Class.of(text[hi]) == .word) hi += 1;
    return text[lo..hi];
}

/// Start of the grapheme after the one at `at`, or null at the end of the
/// line. Graphemes rather than bytes: `l` on a line of CJK moves one glyph,
/// and landing mid-sequence would put the cursor on a cell that is not there.
pub fn charRight(text: []const u8, at: u32) ?u32 {
    var it = vaxis.unicode.graphemeIterator(text);
    while (it.next()) |g| {
        if (g.start == at) {
            const next: u32 = @intCast(g.start + g.len);
            return if (next < text.len) next else null;
        }
    }
    return null;
}

pub fn charLeft(text: []const u8, at: u32) ?u32 {
    if (at == 0) return null;
    var prev: ?u32 = null;
    var it = vaxis.unicode.graphemeIterator(text);
    while (it.next()) |g| {
        if (g.start >= at) break;
        prev = @intCast(g.start);
    }
    return prev;
}

/// The last position a normal-mode cursor may sit on: the start of the last
/// grapheme, not the end of the line. Vim's rule, and the one that keeps `$`
/// from parking on a cell with nothing drawn in it.
pub fn lastCol(text: []const u8) u32 {
    if (text.len == 0) return 0;
    var last: u32 = 0;
    var it = vaxis.unicode.graphemeIterator(text);
    while (it.next()) |g| last = @intCast(g.start);
    return last;
}

/// Clamps an offset onto a grapheme boundary at or before `lastCol`. What
/// every caller wants after the line under the cursor has changed underneath
/// it - a re-diff, a step to a shorter line - and the one place that knows
/// a byte offset into other bytes is not a position.
pub fn clamp(text: []const u8, at: u32) u32 {
    if (text.len == 0) return 0;
    var best: u32 = 0;
    var it = vaxis.unicode.graphemeIterator(text);
    while (it.next()) |g| {
        if (g.start > at) break;
        best = @intCast(g.start);
    }
    return best;
}

pub fn lineStart(_: []const u8) u32 {
    return 0;
}

pub fn lineEnd(text: []const u8) u32 {
    return lastCol(text);
}

/// `^`: the first character that is not indentation, or the last position on a
/// line that is all of it.
pub fn firstNonBlank(text: []const u8) u32 {
    var i: u32 = 0;
    while (i < text.len and Class.of(text[i]) == .blank) i += 1;
    if (i >= text.len) return lastCol(text);
    return i;
}

/// `w` and `W`: the start of the next word. Leaves the current run, then skips
/// blanks.
pub fn wordNext(text: []const u8, at: u32, width: Width) ?u32 {
    if (at >= text.len) return null;
    var i = at;
    const from = classIn(text[i], width);
    if (from != .blank) {
        while (i < text.len and classIn(text[i], width) == from) i += 1;
    }
    while (i < text.len and classIn(text[i], width) == .blank) i += 1;
    if (i >= text.len) return null;
    return i;
}

/// `b` and `B`: the start of the word before the cursor.
pub fn wordPrev(text: []const u8, at: u32, width: Width) ?u32 {
    if (at == 0) return null;
    var i = at;
    // Back off the cursor, then over any blanks between the two words.
    i -= 1;
    while (i > 0 and classIn(text[i], width) == .blank) i -= 1;
    if (classIn(text[i], width) == .blank) return null;

    const run = classIn(text[i], width);
    while (i > 0 and classIn(text[i - 1], width) == run) i -= 1;
    return i;
}

/// Where `b` lands when it crosses into the line above: the start of that
/// line's last word.
pub fn lastWordStart(text: []const u8, width: Width) u32 {
    return wordPrev(text, @intCast(text.len), width) orelse 0;
}

/// `e` and `E`: the last character of the current word, or of the next one
/// when the cursor is already on it.
pub fn wordEnd(text: []const u8, at: u32, width: Width) ?u32 {
    if (text.len == 0) return null;
    var i = at;
    if (i + 1 >= text.len) return null;
    i += 1;
    while (i < text.len and classIn(text[i], width) == .blank) i += 1;
    if (i >= text.len) return null;

    const run = classIn(text[i], width);
    while (i + 1 < text.len and classIn(text[i + 1], width) == run) i += 1;
    return i;
}

/// Characters in a run of text, as a reader counts them: graphemes, so an
/// accented letter is one and a flag is one. What the mode row reports for a
/// charwise selection, where bytes would be a number about the encoding.
pub fn graphemeCount(text: []const u8) u32 {
    var n: u32 = 0;
    var it = vaxis.unicode.graphemeIterator(text);
    while (it.next()) |_| n += 1;
    return n;
}

/// Where `e` lands when it crosses into the line below: the end of that line's
/// first word. Null when the line has none, because `e` passes over an empty
/// line rather than stopping on it - the one place it differs from `w`, and
/// vim's rule too: an empty line is a word but it has no end to land on.
pub fn firstWordEnd(text: []const u8, width: Width) ?u32 {
    var i: u32 = 0;
    while (i < text.len and classIn(text[i], width) == .blank) i += 1;
    if (i >= text.len) return null;
    const run = classIn(text[i], width);
    while (i + 1 < text.len and classIn(text[i + 1], width) == run) i += 1;
    return i;
}

/// `f` `t` `F` `T`, and what `;` and `,` repeat. `till` stops one short of the
/// target, which is the only difference between the pairs.
pub const Find = struct {
    target: u21,
    forward: bool,
    till: bool,

    pub fn flip(self: Find) Find {
        return .{ .target = self.target, .forward = !self.forward, .till = self.till };
    }
};

pub fn find(text: []const u8, at: u32, f: Find) ?u32 {
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(f.target, &buf) catch return null;
    const needle = buf[0..len];

    if (f.forward) {
        // From the grapheme after the cursor, so `;` makes progress rather
        // than finding the character it is already sitting on.
        var from: u32 = charRight(text, at) orelse return null;
        while (std.mem.indexOfPos(u8, text, from, needle)) |hit| {
            const landing: u32 = if (f.till) charLeft(text, @intCast(hit)) orelse 0 else @intCast(hit);
            // `t` twice in a row would otherwise stand still, one short of the
            // same character every time.
            if (f.till and landing <= at) {
                from = @intCast(hit + needle.len);
                continue;
            }
            return landing;
        }
        return null;
    }

    var end = at;
    while (end > 0) {
        const hit = std.mem.lastIndexOf(u8, text[0..end], needle) orelse return null;
        const landing: u32 = if (f.till) blk: {
            const after = @as(u32, @intCast(hit + needle.len));
            break :blk if (after < text.len) after else return null;
        } else @intCast(hit);
        if (f.till and landing >= at) {
            end = @intCast(hit);
            continue;
        }
        return landing;
    }
    return null;
}

const testing = std.testing;

test "character motions step graphemes and stop at both ends" {
    const line = "ab";
    try testing.expectEqual(@as(u32, 1), charRight(line, 0).?);
    try testing.expect(charRight(line, 1) == null);
    try testing.expectEqual(@as(u32, 0), charLeft(line, 1).?);
    try testing.expect(charLeft(line, 0) == null);

    // Three bytes to the glyph, so a byte step would land inside it.
    const wide = "\u{4f60}\u{597d}";
    try testing.expectEqual(@as(u32, 3), charRight(wide, 0).?);
    try testing.expect(charRight(wide, 3) == null);
    try testing.expectEqual(@as(u32, 0), charLeft(wide, 3).?);
    try testing.expectEqual(@as(u32, 3), lastCol(wide));
}

test "the last column is the last grapheme, never the end of the line" {
    try testing.expectEqual(@as(u32, 0), lastCol(""));
    try testing.expectEqual(@as(u32, 0), lastCol("x"));
    try testing.expectEqual(@as(u32, 4), lastCol("hello"));
    try testing.expectEqual(@as(u32, 4), lineEnd("hello"));
}

test "clamping lands on a boundary at or before the offset" {
    const wide = "a\u{4f60}b";
    // Byte 2 is inside the glyph that starts at 1.
    try testing.expectEqual(@as(u32, 1), clamp(wide, 2));
    try testing.expectEqual(@as(u32, 4), clamp(wide, 9));
    try testing.expectEqual(@as(u32, 0), clamp("", 7));
}

test "word motions treat a class change as a boundary" {
    //          0         1         2
    //          0123456789012345678901
    const line = "if (verify_token(req))";

    // `w` from the start: `if` -> `(` -> `verify_token` -> `(` -> `req` -> `))`
    try testing.expectEqual(@as(u32, 3), wordNext(line, 0, .word).?);
    try testing.expectEqual(@as(u32, 4), wordNext(line, 3, .word).?);
    try testing.expectEqual(@as(u32, 16), wordNext(line, 4, .word).?);
    try testing.expectEqual(@as(u32, 17), wordNext(line, 16, .word).?);
    try testing.expectEqual(@as(u32, 20), wordNext(line, 17, .word).?);
    // Nothing after the last run: the caller decides what that means.
    try testing.expect(wordNext(line, 20, .word) == null);

    // `b` retraces it.
    try testing.expectEqual(@as(u32, 17), wordPrev(line, 20, .word).?);
    try testing.expectEqual(@as(u32, 16), wordPrev(line, 17, .word).?);
    try testing.expectEqual(@as(u32, 4), wordPrev(line, 16, .word).?);
    try testing.expectEqual(@as(u32, 0), wordPrev(line, 3, .word).?);
    try testing.expect(wordPrev(line, 0, .word) == null);

    // `E` lands on the last character of a word, not the one after it.
    try testing.expectEqual(@as(u32, 1), wordEnd(line, 0, .word).?);
    try testing.expectEqual(@as(u32, 15), wordEnd(line, 4, .word).?);
}

test "a WORD is whitespace to whitespace, punctuation and all" {
    //          0         1         2
    //          0123456789012345678901
    const line = "if (verify_token(req))";

    // `w` sees five words in `(verify_token(req))`; `W` sees one blob.
    try testing.expectEqual(@as(u32, 3), wordNext(line, 0, .big).?);
    try testing.expect(wordNext(line, 3, .big) == null);
    try testing.expectEqual(@as(u32, 3), wordPrev(line, 21, .big).?);
    try testing.expectEqual(@as(u32, 0), wordPrev(line, 3, .big).?);

    // `E` runs to the end of the blob rather than to the end of `if`.
    try testing.expectEqual(@as(u32, 1), wordEnd(line, 0, .big).?);
    try testing.expectEqual(@as(u32, 21), wordEnd(line, 3, .big).?);
    // Where `e` stops five times over.
    try testing.expectEqual(@as(u32, 3), wordEnd(line, 2, .word).?);

    // A path is one WORD and four words.
    const path = "src/auth.rs and more";
    try testing.expectEqual(@as(u32, 12), wordNext(path, 0, .big).?);
    try testing.expectEqual(@as(u32, 3), wordNext(path, 0, .word).?);
    try testing.expectEqual(@as(u32, 16), lastWordStart(path, .big));
}

test "crossing into a line below lands on its first word end" {
    try testing.expectEqual(@as(u32, 2), firstWordEnd("abc def", .word).?);
    // A one-character first word is landed on, not stepped over.
    try testing.expectEqual(@as(u32, 0), firstWordEnd("a bc", .word).?);
    try testing.expectEqual(@as(u32, 8), firstWordEnd("    const x", .word).?);
    // A WORD runs through the punctuation a word would stop at.
    try testing.expectEqual(@as(u32, 10), firstWordEnd("src/auth.rs and", .big).?);
    try testing.expectEqual(@as(u32, 2), firstWordEnd("src/auth.rs and", .word).?);
    // Nothing to end: the caller keeps looking.
    try testing.expect(firstWordEnd("", .word) == null);
    try testing.expect(firstWordEnd("   ", .word) == null);
}

test "crossing into a line above lands on its last word" {
    try testing.expectEqual(@as(u32, 14), lastWordStart("const value = compute", .word));
    try testing.expectEqual(@as(u32, 0), lastWordStart("one", .word));
    try testing.expectEqual(@as(u32, 0), lastWordStart("", .word));
    try testing.expectEqual(@as(u32, 0), lastWordStart("    ", .word));
}

test "an indented line has a first non-blank and an all-blank one does not" {
    try testing.expectEqual(@as(u32, 4), firstNonBlank("    const x = 1;"));
    try testing.expectEqual(@as(u32, 0), firstNonBlank("const"));
    // All blanks: the last position, rather than one past the end.
    try testing.expectEqual(@as(u32, 3), firstNonBlank("    "));
    try testing.expectEqual(@as(u32, 0), firstNonBlank(""));

    // A blank line has one position, and `w` has nowhere to go from it.
    try testing.expect(wordNext("", 0, .word) == null);
    try testing.expect(wordPrev("", 0, .word) == null);
}

test "find lands on the target and till stops one short" {
    //          0         1
    //          012345678901234
    const line = "alpha, beta, ok";

    try testing.expectEqual(@as(u32, 5), find(line, 0, .{ .target = ',', .forward = true, .till = false }).?);
    try testing.expectEqual(@as(u32, 4), find(line, 0, .{ .target = ',', .forward = true, .till = true }).?);

    // Repeating `t` moves on rather than sticking one short of the same comma.
    try testing.expectEqual(@as(u32, 10), find(line, 4, .{ .target = ',', .forward = true, .till = true }).?);

    // Backwards, and the same distinction.
    try testing.expectEqual(@as(u32, 11), find(line, 14, .{ .target = ',', .forward = false, .till = false }).?);
    try testing.expectEqual(@as(u32, 12), find(line, 14, .{ .target = ',', .forward = false, .till = true }).?);
    try testing.expectEqual(@as(u32, 6), find(line, 12, .{ .target = ',', .forward = false, .till = true }).?);

    // A character that is not there is not a move.
    try testing.expect(find(line, 0, .{ .target = 'z', .forward = true, .till = false }) == null);
    try testing.expect(find(line, 0, .{ .target = ',', .forward = false, .till = false }) == null);
}

test "a reversed find is the same find the other way" {
    const f: Find = .{ .target = 'x', .forward = true, .till = true };
    const back = f.flip();
    try testing.expect(!back.forward);
    try testing.expect(back.till);
    try testing.expectEqual(@as(u21, 'x'), back.target);
}

test "the word under the cursor is what * would search for" {
    const line = "    const id = user_id + width;";

    // Anywhere inside a word gives the whole word, not the tail from here.
    try testing.expectEqualStrings("const", wordAt(line, 4).?);
    try testing.expectEqualStrings("const", wordAt(line, 7).?);
    try testing.expectEqualStrings("const", wordAt(line, 8).?);

    // Underscores are part of a name, or `*` on an identifier would search a
    // fragment of one.
    try testing.expectEqualStrings("user_id", wordAt(line, 15).?);
    try testing.expectEqualStrings("user_id", wordAt(line, 19).?);

    // On punctuation or a blank, take the next word rather than refusing:
    // pointing at `=` plainly means the thing after it.
    try testing.expectEqualStrings("user_id", wordAt(line, 13).?);
    try testing.expectEqualStrings("width", wordAt(line, 23).?);

    // A line with nothing left to find, and one with nothing at all.
    try testing.expect(wordAt("x = 1;", 5) == null);
    try testing.expect(wordAt("  ", 0) == null);
    try testing.expect(wordAt("", 0) == null);
    // Past the end is a miss, not a read past the buffer.
    try testing.expect(wordAt("ab", 99) == null);
}
