// SPDX-License-Identifier: Apache-2.0
//
// The diff body: the rows between the two rules. One screen row at a time,
// and only the visible ones - the row model is built per diff, the strings
// per frame (PERFORMANCE.md 7.5).
//
// Everything here draws through `Frame` and reads through `View`; neither the
// diff pipeline nor the terminal is reachable from this file.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");

const hunk = @import("../core/hunk.zig");
const buffer = @import("../text/buffer.zig");
const lexer = @import("../syntax/lexer.zig");
const search = @import("search.zig");
const rows_mod = @import("rows.zig");
const wrap = @import("wrap.zig");

const frame_mod = @import("frame.zig");
const Frame = frame_mod.Frame;
const View = frame_mod.View;
const Theme = frame_mod.Theme;
const withBg = frame_mod.withBg;

/// Draws the rows from `v.scroll` down, one body row at a time - which is one
/// screen row only when the row is not wrapped.
///
/// Everything is drawn into a child window covering exactly the body, so a
/// wrapped line at the bottom is clipped by the window rather than spilling
/// over the rule beneath it.
pub fn draw(f: Frame, v: View, top: u16, height: u16) Allocator.Error!void {
    if (height == 0) return;
    const bf: Frame = .{
        .win = f.win.child(.{ .y_off = top, .height = height }),
        .arena = f.arena,
        .theme = f.theme,
        .glyphs = f.glyphs,
    };

    var screen_row: u16 = 0;
    var idx = v.scroll;
    while (screen_row < height and idx < v.rows.len()) : (idx += 1) {
        const mark: Mark = .{ .row = idx, .cursor = idx == v.cursor, .sel = v.selection };
        screen_row += try drawRow(bf, v, screen_row, v.rows.items[idx], mark);
    }
}

/// How a body row is standing out, if it is. The cursor and the selection are
/// independent, not one enum: the cursor is *inside* a selection for all but
/// the first row of it, and both have to be visible at once or the reader
/// loses the cursor.
///
/// The selection is carried whole rather than reduced to a bool, because a
/// charwise one covers part of a row and only the line's own length says
/// which part.
const Mark = struct {
    row: u32,
    cursor: bool = false,
    sel: ?frame_mod.Selection = null,

    /// A whole-row wash. The cursor line always has one; a selection only
    /// when it is linewise, because a charwise one is drawn on the characters
    /// it actually covers.
    fn background(self: Mark, t: Theme) ?vaxis.Color {
        if (self.cursor) return t.cursor_line.bg;
        if (self.sel) |sel| {
            if (sel.kind == .line and sel.contains(self.row)) return t.selection.bg;
        }
        return null;
    }

    /// The bytes a charwise selection covers on this row, if any.
    fn span(self: Mark, len: u32) ?frame_mod.Selection.Span {
        const sel = self.sel orelse return null;
        if (sel.kind != .char) return null;
        return sel.span(self.row, len);
    }
};

/// Returns the screen rows the row took: one for chrome, and for a line as
/// many as its text wrapped onto.
fn drawRow(f: Frame, v: View, row: u16, r: rows_mod.Row, mark: Mark) Allocator.Error!u16 {
    switch (r) {
        .gap => {
            const cols = if (f.width() > 6) f.width() - 6 else f.width();
            f.put(row, 3, try f.rule(f.glyphs.gap, cols), f.theme.rule);
        },
        .summarised => _ = try f.print(
            row,
            0,
            f.theme.dim,
            "  {d} lines changed - too large to render inline, not discarded",
            .{v.file.added + v.file.removed},
        ),
        .hunk_header => |hi| try drawHunkHeader(f, v, row, hi),
        .line => |li| return drawLine(f, v, row, li, mark),
    }
    return 1;
}

fn drawHunkHeader(f: Frame, v: View, row: u16, hi: u32) Allocator.Error!void {
    if (hi >= v.file.hunks.len) return;
    const h = v.file.hunks[hi];
    const t = f.theme;
    const g = f.glyphs;

    const name = if (hi < v.fn_names.len) v.fn_names[hi] else "";
    const left = if (name.len > 0)
        try std.fmt.allocPrint(f.arena, " {s} #{d} {s} {s}", .{ g.at, h.id, g.sep, name })
    else
        try std.fmt.allocPrint(f.arena, " {s} #{d}", .{ g.at, h.id });
    f.put(row, 0, left, t.hunk_id);

    // A wholly deleted file has no new-file lines, so its new range is 0-0.
    // Show where the code used to be instead of printing a line number that
    // does not exist.
    const right = if (h.new_count == 0)
        try std.fmt.allocPrint(f.arena, "{s}{d}-{d} {s} ", .{
            g.del, h.old_start, h.old_start + @max(h.old_count, 1) - 1, g.at,
        })
    else if (h.new_count == 1)
        try std.fmt.allocPrint(f.arena, "{d} {s} ", .{ h.new_start, g.at })
    else
        try std.fmt.allocPrint(f.arena, "{d}-{d} {s} ", .{
            h.new_start, h.new_start + h.new_count - 1, g.at,
        });

    // Only when it does not collide with the name: a truncated function name
    // is worse than an absent line range.
    if (f.win.gwidth(left) + f.win.gwidth(right) + 2 <= f.width()) {
        f.putRight(row, right, t.dim);
    }
}

fn drawLine(f: Frame, v: View, row: u16, li: u32, mark: Mark) Allocator.Error!u16 {
    const lines = v.file.lines;
    if (li >= lines.len()) return 1;
    const kind = lines.kind[li];
    const t = f.theme;
    const g = f.glyphs;

    const bg: ?vaxis.Color = mark.background(t);

    const sign: []const u8 = switch (kind) {
        .add => g.add,
        .del => g.del,
        .context => g.context,
    };
    const sign_style = withBg(switch (kind) {
        .add => t.add_sign,
        .del => t.del_sign,
        .context => t.dim,
    }, bg);

    const no = switch (kind) {
        .del => lines.old_no[li],
        else => lines.new_no[li],
    };
    const col = rows_mod.gutter(v.file);
    const prefix = try std.fmt.allocPrint(f.arena, "{s} {d: >[2]}  ", .{ sign, no, col - 4 });

    // How many screen rows this line needs. Capped at what is left of the
    // body: a line taller than the pane is drawn until the pane runs out.
    const rest = f.win.height -| row;
    const height: u16 = if (v.wrap)
        wrap.height(lines.text[li], f.width() -| col, f.method(), rest)
    else
        1;

    // A highlighted row is filled first so it spans the full width, not just
    // the columns that happen to carry text - and every row of a wrapped line,
    // or the cursor would look like it stopped halfway down its own line.
    if (bg) |b| {
        var r: u16 = 0;
        while (r < height) : (r += 1) {
            var c: u16 = 0;
            while (c < f.width()) : (c += 1) {
                f.win.writeCell(c, row + r, .{ .char = .{ .grapheme = " " }, .style = .{ .bg = b } });
            }
        }
    }

    // The sign and the number go on the first row only. A continuation row
    // repeating them would read as a second line of the file.
    f.put(row, 0, prefix, sign_style);
    try drawCode(f, v, row, col, li, kind, bg, height, mark);

    // The terminal's own cursor rather than a drawn block: it blinks the way
    // the reader's terminal blinks and screen readers find it, which is the
    // same argument `drawPrompt` makes. A prompt draws after the body and
    // takes it back, which is what should happen while one is open.
    if (mark.cursor) {
        const avail = if (v.wrap) f.width() -| col else 0;
        const cell = wrap.locate(lines.text[li], avail, f.method(), v.col);
        f.win.setCursorShape(.block);
        f.win.showCursor(col + cell.col, row + cell.row);
    }
    return height;
}

/// Draws one line's text, split into styled segments by the lexer's runs.
///
/// The runs cover the whole buffer, so the line's byte range is found from its
/// line number rather than by pointer arithmetic on the diff's text slice -
/// which would be wrong for a file that failed to attach.
fn drawCode(
    f: Frame,
    v: View,
    row: u16,
    col: u16,
    li: u32,
    kind: hunk.LineKind,
    bg: ?vaxis.Color,
    height: u16,
    mark: Mark,
) Allocator.Error!void {
    const lines = v.file.lines;
    const text = lines.text[li];
    const plain = withBg(f.theme.text, bg);

    const src: ?buffer.Buffer = switch (kind) {
        .del => v.head,
        else => v.work,
    };
    const runs: []const lexer.Run = switch (kind) {
        .del => v.head_runs,
        else => v.work_runs,
    };
    const no = switch (kind) {
        .del => lines.old_no[li],
        else => lines.new_no[li],
    };

    var segs: std.ArrayList(vaxis.Segment) = .empty;

    build: {
        const buf = src orelse break :build;
        if (runs.len == 0 or no == 0 or no > buf.lineCount()) break :build;
        const lo = buf.starts[no - 1];
        const hi = lo + @as(u32, @intCast(text.len));

        for (runsIn(runs, lo, hi)) |r| {
            const s = @max(r.start, lo);
            const e = @min(r.end(), hi);
            if (e <= s) continue;
            try segs.append(f.arena, .{
                .text = buf.bytes[s..e],
                .style = withBg(f.theme.forKind(r.kind), bg),
            });
        }
    }
    // Unstyled is the fallback for every reason the lexer had nothing to say -
    // an unattached file, an unknown language, a line past the buffer.
    if (segs.items.len == 0) try segs.append(f.arena, .{ .text = text, .style = plain });

    // The selection first and the search after it, so a match inside a
    // selection still reads as a match rather than disappearing into it.
    if (mark.span(@intCast(text.len))) |sp| {
        segs = try shade(f.arena, segs, sp.lo, sp.hi, f.theme.selection.bg);
    }
    if (v.query.len > 0) {
        segs = try markMatches(f.arena, segs, v.query, f.theme.search_match);
    }

    if (height <= 1) {
        _ = f.win.print(segs.items, .{ .row_offset = row, .col_offset = col, .wrap = .none });
        return;
    }

    // The chunks come from the same iterator that measured the height, so the
    // rows drawn and the rows counted cannot disagree.
    var it: wrap.Iterator = .init(text, f.width() -| col, f.method());
    var r = row;
    while (it.next()) |chunk| : (r += 1) {
        if (r >= row + height) break;
        const part = try sliceSegs(f.arena, segs.items, chunk);
        _ = f.win.print(part, .{ .row_offset = r, .col_offset = col, .wrap = .none });
    }
}

/// The part of a line's styled segments covering one wrapped chunk.
///
/// Segments are contiguous and cover the line exactly, so this is a walk with
/// a running offset rather than a search - and a chunk boundary inside a
/// segment splits it, keeping the style on both halves.
fn sliceSegs(
    arena: Allocator,
    segs: []const vaxis.Segment,
    chunk: wrap.Chunk,
) Allocator.Error![]vaxis.Segment {
    var out: std.ArrayList(vaxis.Segment) = .empty;
    var at: u32 = 0;
    for (segs) |seg| {
        const lo = at;
        const hi = at + @as(u32, @intCast(seg.text.len));
        at = hi;
        if (hi <= chunk.start) continue;
        if (lo >= chunk.end) break;
        const a = @max(chunk.start, lo) - lo;
        const b = @min(chunk.end, hi) - lo;
        if (b > a) try out.append(arena, .{ .text = seg.text[a..b], .style = seg.style });
    }
    return out.items;
}

/// Puts `bg` behind the bytes in `[lo, hi)`, splitting the segments that
/// straddle either end so the rest keep the colours the lexer gave them.
///
/// A charwise selection is drawn this way rather than by filling cells,
/// because a byte offset is not a column - the same reason `markMatches`
/// works on segments - and because it then wraps for free: `sliceSegs` cuts
/// the result into screen rows afterwards.
fn shade(
    arena: Allocator,
    segs: std.ArrayList(vaxis.Segment),
    lo: u32,
    hi: u32,
    bg: vaxis.Color,
) Allocator.Error!std.ArrayList(vaxis.Segment) {
    var out: std.ArrayList(vaxis.Segment) = .empty;
    var at: u32 = 0;
    for (segs.items) |seg| {
        const start = at;
        const end = at + @as(u32, @intCast(seg.text.len));
        at = end;
        if (end <= lo or start >= hi) {
            try out.append(arena, seg);
            continue;
        }
        var style = seg.style;
        style.bg = bg;
        // Up to three pieces: before the selection, inside it, after it.
        if (start < lo) try out.append(arena, .{ .text = seg.text[0 .. lo - start], .style = seg.style });
        const a = @max(lo, start) - start;
        const b = @min(hi, end) - start;
        try out.append(arena, .{ .text = seg.text[a..b], .style = style });
        if (end > hi) try out.append(arena, .{ .text = seg.text[hi - start ..], .style = seg.style });
    }
    return out;
}

/// Splits segments so every occurrence of `query` gets `style`.
///
/// Done on the segments rather than by overwriting cells afterwards, because a
/// byte offset is not a column: a tab or a wide glyph earlier in the line
/// would put the highlight somewhere else entirely. A match straddling two
/// lexer runs comes out as two highlighted pieces, which reads the same.
fn markMatches(
    arena: Allocator,
    segs: std.ArrayList(vaxis.Segment),
    query: []const u8,
    style: vaxis.Style,
) Allocator.Error!std.ArrayList(vaxis.Segment) {
    const sensitive = search.caseSensitive(query);
    var out: std.ArrayList(vaxis.Segment) = .empty;

    for (segs.items) |seg| {
        var rest = seg.text;
        while (indexOfMatch(rest, query, sensitive)) |at| {
            if (at > 0) try out.append(arena, .{ .text = rest[0..at], .style = seg.style });
            try out.append(arena, .{ .text = rest[at..][0..query.len], .style = style });
            rest = rest[at + query.len ..];
        }
        if (rest.len > 0) try out.append(arena, .{ .text = rest, .style = seg.style });
    }
    return out;
}

fn indexOfMatch(haystack: []const u8, needle: []const u8, sensitive: bool) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    if (sensitive) return std.mem.indexOf(u8, haystack, needle);

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) break;
        } else return i;
    }
    return null;
}

/// Runs overlapping `[lo, hi)`. Binary search for the first, then a walk:
/// runs are sorted and non-overlapping, so this is O(log n + k) per row rather
/// than a scan of the file's runs for every visible line.
pub fn runsIn(runs: []const lexer.Run, lo: u32, hi: u32) []const lexer.Run {
    var low: usize = 0;
    var high: usize = runs.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (runs[mid].end() <= lo) low = mid + 1 else high = mid;
    }
    const start = low;
    var end = start;
    while (end < runs.len and runs[end].start < hi) end += 1;
    return runs[start..end];
}

const testing = std.testing;

test "match highlighting splits segments without losing or duplicating bytes" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const plain: vaxis.Style = .{};
    const hit: vaxis.Style = .{ .bold = true };

    var segs: std.ArrayList(vaxis.Segment) = .empty;
    try segs.append(arena, .{ .text = "let token = ", .style = plain });
    try segs.append(arena, .{ .text = "tokenise();", .style = plain });

    const out = try markMatches(arena, segs, "token", hit);

    // Every byte survives, in order: a highlight that eats text is worse than
    // no highlight at all.
    var joined: std.ArrayList(u8) = .empty;
    var marked: usize = 0;
    for (out.items) |seg| {
        try joined.appendSlice(arena, seg.text);
        if (seg.style.bold) marked += 1;
    }
    try testing.expectEqualStrings("let token = tokenise();", joined.items);
    try testing.expectEqual(@as(usize, 2), marked);
}

test "match highlighting follows smart case and leaves a clean line alone" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    var segs: std.ArrayList(vaxis.Segment) = .empty;
    try segs.append(arena, .{ .text = "TokenStore", .style = .{} });

    // Lowercase query: matches either case.
    const loose = try markMatches(arena, segs, "token", .{ .bold = true });
    try testing.expect(loose.items[0].style.bold);

    // A capital pins it, so this one does not match at all - and an unmatched
    // line comes back as the single segment it went in as.
    const strict = try markMatches(arena, segs, "TOKEN", .{ .bold = true });
    try testing.expectEqual(@as(usize, 1), strict.items.len);
    try testing.expect(!strict.items[0].style.bold);
    try testing.expectEqualStrings("TokenStore", strict.items[0].text);
}

test "run lookup finds only the runs overlapping a line" {
    const runs = [_]lexer.Run{
        .{ .start = 0, .len = 5, .kind = .keyword },
        .{ .start = 5, .len = 5, .kind = .text },
        .{ .start = 10, .len = 5, .kind = .string },
        .{ .start = 15, .len = 5, .kind = .comment },
    };
    const got = runsIn(&runs, 5, 15);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqual(lexer.Kind.text, got[0].kind);
    try testing.expectEqual(lexer.Kind.string, got[1].kind);

    // A range inside one run still finds it.
    try testing.expectEqual(@as(usize, 1), runsIn(&runs, 11, 13).len);
    // A range past the end finds nothing rather than trapping.
    try testing.expectEqual(@as(usize, 0), runsIn(&runs, 100, 200).len);
    // The first run is found without walking off the front.
    try testing.expectEqual(@as(usize, 1), runsIn(&runs, 0, 3).len);
}
