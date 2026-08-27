// SPDX-License-Identifier: Apache-2.0
//
// Draws one frame of the unified diff view (mockup 2a): one status row, the
// diff body, one mode row. No persistent file list - files are reached with
// `]f`, which is what buys the body 22 of 26 rows instead of 17.
//
// Every string drawn here is allocated from the frame arena, because vaxis
// cells reference the text rather than copying it and `render()` reads it
// later. The arena is reset after render and flush, never before
// (ARCHITECTURE.md 5c). A slice that dies early renders as plausible garbage
// on one row rather than crashing, so this rule is a review item, not
// something the compiler catches.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");

const diff = @import("../core/diff.zig");
const event = @import("../core/event.zig");
const hunk = @import("../core/hunk.zig");
const buffer = @import("../text/buffer.zig");
const lexer = @import("../syntax/lexer.zig");
const rows_mod = @import("rows.zig");
const search = @import("search.zig");
const theme_mod = @import("theme.zig");

pub const Theme = theme_mod.Theme;
pub const Glyphs = theme_mod.Glyphs;

/// Rows of chrome: status, rule, rule, mode.
pub const chrome_rows = 4;

/// `Tab` hides the chrome and gives those four rows to the body - on a 26-row
/// pane that is 22 rows of diff becoming 26, which is the difference between
/// one hunk and two.
pub fn bodyHeight(win_rows: u16, zen: bool) u16 {
    if (zen) return win_rows;
    return if (win_rows > chrome_rows) win_rows - chrome_rows else 0;
}

/// An inclusive range of body rows. Normalised by the caller, so `lo <= hi`.
pub const Range = struct {
    lo: u32,
    hi: u32,

    pub fn contains(self: Range, row: u32) bool {
        return row >= self.lo and row <= self.hi;
    }

    pub fn count(self: Range) u32 {
        return self.hi - self.lo + 1;
    }
};

/// The open `/`, `?` or `:` line. Present only while one is open, which is
/// also what tells the renderer to put the terminal cursor in it.
pub const PromptView = struct {
    prefix: []const u8,
    text: []const u8,
};

/// Everything one frame needs. Assembled by the app; nothing here reaches back
/// into the diff pipeline or the terminal.
pub const View = struct {
    file: *const diff.FileDiff,
    rows: rows_mod.Rows,
    file_index: u32,
    file_count: u32,
    /// Row index of the cursor, and of the first visible row.
    cursor: u32,
    scroll: u32,
    mode: event.Mode = .normal,
    hints: []const u8 = "",
    /// Visual line select, in body-row indexes.
    selection: ?Range = null,
    prompt: ?PromptView = null,
    /// A message about the last keystroke: a search that found nothing, a
    /// command that is not one. Takes the mode row when present.
    notice: []const u8 = "",
    /// The live search query, so hits stay highlighted after `/` closes -
    /// which is what makes `n` legible without re-reading the line.
    query: []const u8 = "",
    /// Chrome hidden, body full-height.
    zen: bool = false,
    /// Enclosing function name per hunk, empty where unknown.
    fn_names: []const []const u8 = &.{},
    /// Whole-file token runs and the buffers they index. Empty when the file
    /// could not be attached - a torn read, or a language with no lexer - in
    /// which case the body renders correct but unstyled.
    work: ?buffer.Buffer = null,
    head: ?buffer.Buffer = null,
    work_runs: []const lexer.Run = &.{},
    head_runs: []const lexer.Run = &.{},
    /// Hunks across the whole review, and the 1-based position of the one the
    /// cursor is in. Position rather than the id, because ids keep climbing
    /// across re-diffs as changes come and go - "#16 of 15" is a true
    /// statement that reads like a bug.
    total_hunks: u32 = 0,
    hunk_ordinal: u32 = 0,
    /// Set when the last re-diff hit a file changing underneath it. Shown
    /// rather than swallowed: a stale frame the user knows about beats a
    /// blended one they do not (SPEC.md 9).
    torn: bool = false,
};

pub const Frame = struct {
    win: vaxis.Window,
    arena: Allocator,
    theme: Theme,
    glyphs: Glyphs,

    fn width(self: Frame) u16 {
        return self.win.width;
    }

    /// A rule spanning `cols` columns, built from a possibly multi-byte glyph.
    fn rule(self: Frame, glyph: []const u8, cols: u16) Allocator.Error![]const u8 {
        const out = try self.arena.alloc(u8, @as(usize, cols) * glyph.len);
        var i: usize = 0;
        while (i < cols) : (i += 1) {
            @memcpy(out[i * glyph.len ..][0..glyph.len], glyph);
        }
        return out;
    }

    fn put(self: Frame, row: u16, col: u16, text: []const u8, style: vaxis.Style) void {
        _ = self.win.printSegment(
            .{ .text = text, .style = style },
            .{ .row_offset = row, .col_offset = col, .wrap = .none },
        );
    }

    /// Right-aligns using display width, never byte length: the status fields
    /// are full of multi-byte glyphs and `─` is three bytes wide and one
    /// column.
    fn putRight(self: Frame, row: u16, text: []const u8, style: vaxis.Style) void {
        const w = self.win.gwidth(text);
        if (w >= self.width()) return self.put(row, 0, text, style);
        self.put(row, self.width() - w, text, style);
    }
};

pub fn draw(f: Frame, v: View) Allocator.Error!void {
    f.win.clear();
    f.win.hideCursor();
    const h = f.win.height;
    if (h == 0 or f.width() < 20) return drawTooSmall(f);

    if (v.zen) {
        // No chrome at all, and no prompt either: `/` leaves zen rather than
        // drawing an input line with nothing to anchor it.
        try drawBody(f, v, 0, h);
        return;
    }
    if (h < chrome_rows + 1) return drawTooSmall(f);

    try drawStatus(f, v, 0);
    f.put(1, 0, try f.rule(f.glyphs.rule, f.width()), f.theme.rule);
    try drawBody(f, v, 2, bodyHeight(h, false));
    f.put(h - 2, 0, try f.rule(f.glyphs.rule, f.width()), f.theme.rule);
    if (v.prompt) |p| drawPrompt(f, p, h - 1) else try drawMode(f, v, h - 1);
}

/// The `/`, `?` or `:` line, with the terminal's own cursor parked at its end.
/// A real cursor rather than a drawn block: it blinks the way the user's
/// terminal blinks, and screen readers find it.
fn drawPrompt(f: Frame, p: PromptView, row: u16) void {
    f.put(row, 0, p.prefix, f.theme.prompt);
    const at = f.win.gwidth(p.prefix);
    f.put(row, at, p.text, f.theme.prompt);
    const col = at + f.win.gwidth(p.text);
    if (col < f.width()) f.win.showCursor(col, row);
}

fn modeLabel(mode: event.Mode) []const u8 {
    return switch (mode) {
        .normal => "NORMAL",
        .visual => "VISUAL",
        .command => "COMMAND",
        .note_input => "NOTE",
        .finder => "FIND",
        .insert => "INSERT",
    };
}

/// Below this there is no honest layout, so say so instead of drawing a
/// corrupted one.
fn drawTooSmall(f: Frame) void {
    f.put(0, 0, "lgtm: window too small", f.theme.dim);
}

fn drawStatus(f: Frame, v: View, row: u16) Allocator.Error!void {
    const t = f.theme;
    const g = f.glyphs;

    var col: u16 = 1;
    const path = v.file.path();
    f.put(row, col, path, t.path);
    col += f.win.gwidth(path);

    const counts = try std.fmt.allocPrint(f.arena, " {s} {d}/{d} {s} ", .{
        g.sep, v.file_index + 1, v.file_count, g.sep,
    });
    f.put(row, col, counts, t.dim);
    col += f.win.gwidth(counts);

    const plus = try std.fmt.allocPrint(f.arena, "+{d}", .{v.file.added});
    f.put(row, col, plus, t.added_count);
    col += f.win.gwidth(plus) + 1;

    const minus = try std.fmt.allocPrint(f.arena, "{s}{d}", .{ g.del, v.file.removed });
    f.put(row, col, minus, t.removed_count);

    // Right side: which hunk the cursor is in, out of how many in this file.
    if (v.rows.hunkAt(v.cursor)) |hi| {
        if (hi < v.file.hunks.len) {
            const right = try std.fmt.allocPrint(f.arena, "#{d} {s} {d}/{d} ", .{
                v.file.hunks[hi].id, g.sep, v.hunk_ordinal, v.total_hunks,
            });
            f.putRight(row, right, t.hunk_id);
        }
    }
}

fn drawMode(f: Frame, v: View, row: u16) Allocator.Error!void {
    const t = f.theme;

    const badge = try std.fmt.allocPrint(f.arena, " {s} ", .{modeLabel(v.mode)});
    f.put(row, 1, badge, t.mode_badge);
    var col: u16 = 1 + f.win.gwidth(badge) + 2;

    // One slot, three claimants, in order of how much the reader needs it: a
    // torn read is a correctness warning, a notice answers the keystroke just
    // typed, and the row count is what fills the space when neither applies.
    const left: []const u8, const style = if (v.torn)
        .{ "file changed while reading, re-diffing", t.removed_count }
    else if (v.notice.len > 0)
        .{ v.notice, t.notice }
    else if (v.selection) |sel|
        .{ try std.fmt.allocPrint(f.arena, "{d} lines selected", .{sel.count()}), t.dim }
    else
        .{ try std.fmt.allocPrint(f.arena, "{d} rows", .{v.rows.len()}), t.dim };

    f.put(row, col, left, style);
    col += f.win.gwidth(left) + 2;

    const room = f.width() -| col -| 1;
    const fitted = fitHints(f, v.hints, room);
    if (fitted.len > 0) f.putRight(row, fitted, t.hint);
}

/// The longest prefix of the hint strip that fits `cols`.
///
/// Cut on the double space between hints, never mid-hint: "]f [f fi" advertises
/// a key that does not exist. Truncating rather than dropping the whole strip
/// is what keeps it visible at 80 columns, which is the width the layout is
/// designed for - and the strip outgrew that width the moment 5b added keys.
fn fitHints(f: Frame, hints: []const u8, cols: u16) []const u8 {
    if (hints.len == 0 or cols == 0) return "";
    if (f.win.gwidth(hints) <= cols) return hints;

    var cut: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, hints, at, "  ")) |sep| {
        if (f.win.gwidth(hints[0..sep]) > cols) break;
        cut = sep;
        at = sep + 2;
    }
    return hints[0..cut];
}

fn drawBody(f: Frame, v: View, top: u16, height: u16) Allocator.Error!void {
    var screen_row: u16 = 0;
    while (screen_row < height) : (screen_row += 1) {
        const idx = v.scroll + screen_row;
        if (idx >= v.rows.len()) break;
        const mark: Mark = .{
            .cursor = idx == v.cursor,
            .selected = if (v.selection) |sel| sel.contains(idx) else false,
        };
        try drawRow(f, v, top + screen_row, v.rows.items[idx], mark);
    }
}

/// How a body row is standing out, if it is. Two independent bits rather than
/// one enum: the cursor is *inside* a selection for all but the first row of
/// it, and both have to be visible at once or the reader loses the cursor.
const Mark = struct {
    cursor: bool = false,
    selected: bool = false,

    fn background(self: Mark, t: Theme) ?vaxis.Color {
        if (self.cursor) return t.cursor_line.bg;
        if (self.selected) return t.selection.bg;
        return null;
    }
};

fn drawRow(f: Frame, v: View, row: u16, r: rows_mod.Row, mark: Mark) Allocator.Error!void {
    switch (r) {
        .gap => {
            const cols = if (f.width() > 6) f.width() - 6 else f.width();
            f.put(row, 3, try f.rule(f.glyphs.gap, cols), f.theme.rule);
        },
        .summarised => {
            const msg = try std.fmt.allocPrint(
                f.arena,
                "  {d} lines changed - too large to render inline, not discarded",
                .{v.file.added + v.file.removed},
            );
            f.put(row, 0, msg, f.theme.dim);
        },
        .hunk_header => |hi| try drawHunkHeader(f, v, row, hi),
        .line => |li| try drawLine(f, v, row, li, mark),
    }
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

/// Width of the line-number column, from the largest number this file shows.
fn numWidth(f: *const diff.FileDiff) u16 {
    var max: u32 = 1;
    for (f.hunks) |h| {
        const end = h.new_start + h.new_count;
        if (end > max) max = end;
        const old_end = h.old_start + h.old_count;
        if (old_end > max) max = old_end;
    }
    var w: u16 = 1;
    var n = max;
    while (n >= 10) : (n /= 10) w += 1;
    return @max(w, 2);
}

fn drawLine(f: Frame, v: View, row: u16, li: u32, mark: Mark) Allocator.Error!void {
    const lines = v.file.lines;
    if (li >= lines.len()) return;
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
    const nw = numWidth(v.file);
    const prefix = try std.fmt.allocPrint(f.arena, "{s} {d: >[2]}  ", .{ sign, no, nw });

    // A highlighted row is filled first so it spans the full width, not just
    // the columns that happen to carry text.
    if (bg) |b| {
        var c: u16 = 0;
        while (c < f.width()) : (c += 1) {
            f.win.writeCell(c, row, .{ .char = .{ .grapheme = " " }, .style = .{ .bg = b } });
        }
    }

    f.put(row, 0, prefix, sign_style);
    const col = f.win.gwidth(prefix);
    try drawCode(f, v, row, col, li, kind, bg);
}

fn withBg(style: vaxis.Style, bg: ?vaxis.Color) vaxis.Style {
    var out = style;
    if (bg) |b| out.bg = b;
    return out;
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

    if (v.query.len > 0) {
        segs = try markMatches(f.arena, segs, v.query, f.theme.search_match);
    }
    _ = f.win.print(segs.items, .{ .row_offset = row, .col_offset = col, .wrap = .none });
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

test "body height leaves exactly the chrome rows" {
    try testing.expectEqual(@as(u16, 22), bodyHeight(26, false));
    try testing.expectEqual(@as(u16, 0), bodyHeight(4, false));
    try testing.expectEqual(@as(u16, 0), bodyHeight(1, false));
}

test "zen mode hands the chrome rows to the body" {
    // Four rows back on a 26-row pane: one more hunk visible, which is the
    // whole reason `Tab` exists.
    try testing.expectEqual(@as(u16, 26), bodyHeight(26, true));
    try testing.expectEqual(@as(u16, 1), bodyHeight(1, true));
    try testing.expectEqual(@as(u16, 0), bodyHeight(0, true));
}

test "a selection range is inclusive at both ends" {
    const r: Range = .{ .lo = 4, .hi = 6 };
    try testing.expect(!r.contains(3));
    try testing.expect(r.contains(4));
    try testing.expect(r.contains(6));
    try testing.expect(!r.contains(7));
    try testing.expectEqual(@as(u32, 3), r.count());

    // A one-row selection is one line, not zero.
    const one: Range = .{ .lo = 2, .hi = 2 };
    try testing.expectEqual(@as(u32, 1), one.count());
}

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

test "every mode has a label, including the ones v0.1 cannot reach" {
    // A mode with no label would render as an empty badge rather than fail.
    inline for (@typeInfo(event.Mode).@"enum".fields) |f| {
        const m: event.Mode = @enumFromInt(f.value);
        try testing.expect(modeLabel(m).len > 0);
    }
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

test "line number column widens with the file" {
    var small: diff.FileDiff = .{ .old_path = "a", .new_path = "a", .status = .modified };
    var hs = [_]hunk.Hunk{.{ .old_start = 1, .old_count = 3, .new_start = 1, .new_count = 3, .lo = 0, .hi = 3 }};
    small.hunks = &hs;
    try testing.expectEqual(@as(u16, 2), numWidth(&small));

    var big: diff.FileDiff = .{ .old_path = "a", .new_path = "a", .status = .modified };
    var hb = [_]hunk.Hunk{.{ .old_start = 1, .old_count = 1, .new_start = 12000, .new_count = 40, .lo = 0, .hi = 1 }};
    big.hunks = &hb;
    try testing.expectEqual(@as(u16, 5), numWidth(&big));
}
