// SPDX-License-Identifier: Apache-2.0
//
// The diff body: the rows between the two rules. One screen row at a time,
// and only the visible ones - the row model is built per diff, the strings
// per frame.
//
// Everything here draws through `Frame` and reads through `View`; neither the
// diff pipeline nor the terminal is reachable from this file.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");

const buffer = @import("../text/buffer.zig");
const lexer = @import("../syntax/lexer.zig");
const keytext = @import("keytext.zig");
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

    // Negative to begin with when the top row is only partly on screen, which
    // is how the viewport moves by a screen row rather than by a whole line of
    // the file while a jump is catching up (`ui/anim.zig`). Rows drawn above
    // zero are clipped a chunk at a time rather than by the window, because
    // the window's own clipping is against the screen and would eat the rule.
    var screen_row: i32 = -@as(i32, v.skip);
    var idx = v.scroll;
    while (screen_row < height and idx < v.rows.len()) : (idx += 1) {
        const mark: Mark = .{ .row = idx, .cursor = idx == v.cursor_drawn, .sel = v.selection };
        screen_row += try drawRow(bf, v, screen_row, v.rows.items[idx], mark);
    }

    // Last, and once for the frame rather than once for whichever row happens
    // to be the cursor's: while it is travelling it is between rows, and the
    // row it is over is not the row it belongs to.
    //
    // The terminal's own cursor rather than a drawn block: it blinks the way
    // the reader's terminal blinks and screen readers find it, which is the
    // same argument `drawPrompt` makes. A prompt draws after the body and
    // takes it back, which is what should happen while one is open.
    if (v.cursor_cell) |c| {
        const at: i32 = @intFromFloat(@round(c.row));
        if (onScreen(bf, at)) |y| {
            bf.win.setCursorShape(.block);
            bf.win.showCursor(@intFromFloat(@round(c.col)), y);
        }
    }
}

/// Whether a screen row is inside the body, and what it is as a coordinate.
/// One place, because every draw below has to ask and getting it wrong writes
/// over the chrome.
fn onScreen(f: Frame, row: i32) ?u16 {
    if (row < 0 or row >= f.win.height) return null;
    return @intCast(row);
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

/// The wash a line earns from being a change, or null when the change colour
/// stops at the gutter. A split row's absent side has no line at all and takes
/// the neutral filler, which is what turns "nothing here" into the shape of
/// what was added or taken away.
fn tint(f: Frame, v: View, li: ?u32) ?vaxis.Color {
    if (v.highlight != .line) return null;
    const i = li orelse return f.theme.filler.bg;
    if (i >= v.file.lines.len()) return null;
    return switch (v.file.lines.kind[i]) {
        .add => f.theme.add_line.bg,
        .del => f.theme.del_line.bg,
        .context => null,
    };
}

/// Returns the screen rows the row took: one for chrome, and for a line as
/// many as its text wrapped onto.
fn drawRow(f: Frame, v: View, row: i32, r: rows_mod.Row, mark: Mark) Allocator.Error!i32 {
    switch (r) {
        .line => |li| return drawLine(f, v, row, li, mark, .{}),
        .pair => |pi| return drawPair(f, v, row, pi, mark),
        .note => |ni| return drawComment(f, v, row, ni),
        // Chrome is one screen row and never wraps, so it is drawn or it is
        // not; only a line and a note can straddle the top of the body.
        else => {},
    }
    const at = onScreen(f, row) orelse return 1;
    switch (r) {
        .gap => {
            const cols = if (f.width() > 6) f.width() - 6 else f.width();
            f.put(at, 3, try f.rule(f.glyphs.gap, cols), f.theme.rule);
        },
        .summarised => blk: {
            var key: [32]u8 = undefined;
            _ = try f.print(
                at,
                0,
                f.theme.dim,
                "  {d} lines changed - too large to render inline. {s} opens it",
                .{ v.file.added + v.file.removed, keytext.firstKeyFor(v.bindings, .expand_file, .normal, &key) },
            );
            break :blk;
        },
        .hunk_header => |hi| try drawHunkHeader(f, v, at, hi),
        .line, .pair, .note => unreachable,
    }
    return 1;
}

/// A note under the line it belongs to, indented past the gutter and wrapped
/// the way the code above it is - a review comment, in the place a review
/// comment goes.
fn drawComment(f: Frame, v: View, row: i32, ni: u32) Allocator.Error!i32 {
    if (ni >= v.notes.len) return 1;
    const n = v.notes[ni];
    const t = f.theme;
    const style = switch (n.state) {
        .open => t.comment_open,
        .sent => t.comment_sent,
        .stale => t.comment_stale,
    };

    const col = if (f.width() > 8) @as(u16, 6) else 0;
    const width = f.width() -| col -| 2;
    if (width == 0) return 1;

    // The body wrapped, and hard newlines honoured: a note written with `o`
    // has real lines in it and they are the reader's paragraphs.
    var rows: i32 = 0;
    var lines = std.mem.splitScalar(u8, n.body, '\n');
    while (lines.next()) |line| {
        var it: wrap.Iterator = .init(line, width, f.method(), .flush);
        while (it.next()) |chunk| {
            if (onScreen(f, row + rows)) |at| {
                // The marker only on the first row, so a wrapped note reads as
                // one remark rather than as several.
                if (rows == 0) f.put(at, col -| 2, f.glyphs.comment_mark, style);
                f.put(at, col + chunk.col, chunk.slice(line), style);
            }
            rows += 1;
            if (row + rows >= f.win.height) break;
        }
    }
    // A note that says nothing still takes a row, or the row model and the
    // screen disagree about where everything below it is.
    return @max(rows, 1);
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

/// One split row: the old file's line on the left, the new file's on the
/// right, a divider between them, and nothing at all on a side that has none.
///
/// Each column is drawn into a child window of its own, so a line too long for
/// its half is clipped by the window rather than running into the other one.
/// Always one screen row: the split view does not wrap, because two columns
/// wrapping independently would give one body row two heights.
fn drawPair(f: Frame, v: View, row: i32, pi: u32, mark: Mark) Allocator.Error!i32 {
    if (pi >= v.rows.pairs.len) return 1;
    const p = v.rows.pairs[pi];
    const sp = rows_mod.Split.of(f.width());
    // The cursor line and a linewise selection are facts about the whole row
    // and win over both columns. The change wash is a fact about one line, so
    // the two sides can differ - a removal beside its replacement is the
    // ordinary case, and washing both the same would say they were the same.
    const row_bg = mark.background(f.theme);
    const left_bg = row_bg orelse tint(f, v, p.left);
    const right_bg = row_bg orelse tint(f, v, p.right);
    const lines = v.file.lines;
    const col = rows_mod.gutter(v.file, .split);

    // Both columns get the rows the taller of them needs, so a wrapped line on
    // one side does not slide the other side down past it. Capped at what is
    // left of the body, and counting from `row` so a pair scrolled halfway off
    // the top still reports its whole height.
    const rest: u16 = @intCast(@max(0, @as(i32, f.win.height) - row));
    const height: i32 = if (v.wrap) wrap.pairHeight(
        if (p.left) |li| lines.text[li] else null,
        sp.left -| col,
        if (p.right) |li| lines.text[li] else null,
        sp.right_width -| col,
        f.method(),
        rest,
    ) else 1;

    // Washed first and on every row of the pair, so a wrapped one does not
    // look like the two columns have come apart - and so a side with no line
    // at all is still drawn, which is the whole point of the filler.
    var r: i32 = 0;
    while (r < height) : (r += 1) {
        const at = onScreen(f, row + r) orelse continue;
        fill(f, at, 0, sp.left, left_bg);
        fill(f, at, sp.right, f.width(), right_bg);
        f.put(at, sp.divider, f.glyphs.sep, withBg(f.theme.rule, row_bg));
    }

    // The selection and the cursor belong to the side the cursor is on, which
    // is the side `Rows.lineAt` names - marking both would say the reader has
    // selected text in a file they are not pointing at.
    // The column the reader is in, or the other one when that column is a
    // padding row: a cursor cannot stand on a side with nothing on it.
    const active: rows_mod.Side = switch (v.side) {
        .new => if (p.right != null) .new else .old,
        .old => if (p.left != null) .old else .new,
    };
    if (p.left) |li| try drawSide(f, v, row, li, .old, sp, left_bg, height, if (active == .old) mark else null);
    if (p.right) |li| try drawSide(f, v, row, li, .new, sp, right_bg, height, if (active == .new) mark else null);
    return height;
}

/// Paints `[from, to)` of one screen row. A no-op without a colour, so every
/// caller can hand it an optional and stop asking.
fn fill(f: Frame, at: u16, from: u16, to: u16, bg: ?vaxis.Color) void {
    const b = bg orelse return;
    var c = from;
    while (c < to) : (c += 1) {
        f.win.writeCell(c, at, .{ .char = .{ .grapheme = " " }, .style = .{ .bg = b } });
    }
}

/// One column of a split row. A child window that is one column wide and as
/// tall as the whole body, so the line below draws in that column's
/// coordinates and a pair straddling the top of the body is clipped the same
/// way an unwrapped one is.
fn drawSide(
    f: Frame,
    v: View,
    row: i32,
    li: u32,
    side: rows_mod.Side,
    sp: rows_mod.Split,
    bg: ?vaxis.Color,
    height: i32,
    mark: ?Mark,
) Allocator.Error!void {
    const geom = sp.column(side);
    if (geom.width == 0) return;
    const cf: Frame = .{
        .win = f.win.child(.{ .x_off = geom.at, .width = geom.width }),
        .arena = f.arena,
        .theme = f.theme,
        .glyphs = f.glyphs,
    };
    _ = try drawLine(cf, v, row, li, mark orelse .{ .row = 0 }, .{
        .side = side,
        .bg = bg,
        .height = height,
    });
}

/// What a caller that has already made some of a line's decisions is handing
/// down. All defaulted, so the flowing view passes nothing.
const LineOpts = struct {
    /// Which file the text comes from. Null in the flow view, where the
    /// line's own kind answers it; a split column is told, because a context
    /// line is drawn twice - once from each buffer, at each file's own number.
    side: ?rows_mod.Side = null,
    /// The row's background, when the caller has washed it already.
    bg: ?vaxis.Color = null,
    /// Screen rows to occupy, when the caller has decided. A split pair takes
    /// the taller of its two sides so the columns stay aligned.
    height: ?i32 = null,
};

/// Draws one diff line and returns the screen rows it took.
fn drawLine(
    f: Frame,
    v: View,
    row: i32,
    li: u32,
    mark: Mark,
    opts: LineOpts,
) Allocator.Error!i32 {
    const lines = v.file.lines;
    if (li >= lines.len()) return 1;
    const kind = lines.kind[li];
    const t = f.theme;
    const g = f.glyphs;

    // A column of a split row has already been washed across the whole width,
    // so it is handed the colour rather than deciding it: only the full row
    // knows whether the cursor is on it.
    const side = opts.side;
    const bg: ?vaxis.Color = if (side == null)
        (mark.background(t) orelse tint(f, v, li))
    else
        opts.bg;

    // Whether this line arrived after the mark. A fact about the line, so each
    // column asks about its own: a removal is drawn on the old side and is
    // just as new as the addition that replaced it.
    const fresh = li < v.fresh.len and v.fresh[li];

    // What the line is, as a colour. The number wears it in both views, and
    // in the split view it is the only glyph-free channel there is - which is
    // why the flow view keeps `+` and `-` rather than both views dropping
    // them: a terminal without colour has to be able to read one of the two.
    const kind_style = withBg(switch (kind) {
        .add => t.add_sign,
        .del => t.del_sign,
        .context => t.dim,
    }, bg);

    const old = if (side) |sd| sd == .old else kind == .del;
    const no = if (old) lines.old_no[li] else lines.new_no[li];
    const col = rows_mod.gutter(v.file, if (side == null) .flow else .split);
    // A split column narrower than its own gutter has nowhere to put the
    // line, and drawing it would spill into the divider.
    if (side != null and col >= f.width()) return 1;
    // No trailing blanks: what fills the columns after the number is the row's
    // own background, a note's dot, or nothing.
    //
    // The flow view leads with the sign and the blank the mark bar sits in;
    // the split view leads with that blank alone. Both put the number last, so
    // `col - 1` is the note's column in either.
    const num_w = rows_mod.numWidth(v.file);
    const sign: []const u8 = switch (kind) {
        .add => g.add,
        .del => g.del,
        .context => g.context,
    };
    const prefix = if (side == null)
        try std.fmt.allocPrint(f.arena, "{s} {d: >[2]}", .{ sign, no, num_w })
    else
        try std.fmt.allocPrint(f.arena, "{d: >[1]}", .{ no, num_w });

    // How many screen rows this line needs. Capped at what is left of the
    // body - and a line starting above it needs the rows above counting too,
    // or a wrapped row scrolled halfway off the top would report the height of
    // the part still showing and the rows below it would all shift up.
    const rest: u16 = @intCast(@max(0, @as(i32, f.win.height) - row));
    const height: i32 = opts.height orelse if (v.wrap)
        wrap.height(lines.text[li], f.width() -| col, f.method(), rest, .follow)
    else
        1;

    // A highlighted row is filled first so it spans the full width, not just
    // the columns that happen to carry text - and every row of a wrapped line,
    // or the cursor would look like it stopped halfway down its own line.
    if (side == null) {
        var r: i32 = 0;
        while (r < height) : (r += 1) {
            const at = onScreen(f, row + r) orelse continue;
            fill(f, at, 0, f.width(), bg);
        }
    }

    // The sign and the number go on the first row only. A continuation row
    // repeating them would read as a second line of the file - and a first row
    // scrolled off the top takes them with it.
    if (onScreen(f, row)) |at| {
        f.put(at, 0, prefix, kind_style);

        // A note is marked in the last gutter column, after the prefix has
        // been drawn over it - the column between the line number and the
        // code is the only one a marker can have without the code moving.
        var noted = false;
        const no_new = lines.new_no[li];
        if (!old and no_new != 0 and col > 0) {
            for (v.notes) |m| {
                if (m.line != no_new) continue;
                f.put(at, col - 1, g.comment_mark, withBg(switch (m.state) {
                    .open => t.comment_open,
                    .sent => t.comment_sent,
                    .stale => t.comment_stale,
                }, bg));
                noted = true;
                break;
            }
        }

        // A change newer than the mark. The flow view has a column of its own
        // for it, between the sign and the number; the split view shares the
        // note's, and a note wins there. A note is something the reader put
        // where it is on purpose, and `]m` walks them to the mark anyway.
        const mark_col: u16 = if (side == null) 1 else col -| 1;
        if (fresh and col > 1 and !(side != null and noted)) {
            f.put(at, mark_col, g.fresh_mark, withBg(t.fresh, bg));
        }
    }
    try drawCode(f, v, row, col, li, old, bg, height, mark);

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
    row: i32,
    col: u16,
    li: u32,
    old: bool,
    bg: ?vaxis.Color,
    height: i32,
    mark: Mark,
) Allocator.Error!void {
    const lines = v.file.lines;
    const text = lines.text[li];
    const plain = withBg(f.theme.text, bg);

    const src: ?buffer.Buffer = if (old) v.head else v.work;
    const runs: []const lexer.Run = if (old) v.head_runs else v.work_runs;
    const no = if (old) lines.old_no[li] else lines.new_no[li];

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
    if (!v.query.empty()) {
        segs = try markMatches(f.arena, segs, text, v.query, f.theme.search_match);
    }

    if (height <= 1) {
        const at = onScreen(f, row) orelse return;
        _ = f.win.print(segs.items, .{ .row_offset = at, .col_offset = col, .wrap = .none });
        return;
    }

    // The chunks come from the same iterator that measured the height, so the
    // rows drawn and the rows counted cannot disagree. Chunks above the body
    // are skipped rather than drawn: that is what a line scrolled halfway off
    // the top looks like.
    var it: wrap.Iterator = .init(text, f.width() -| col, f.method(), .follow);
    var r = row;
    while (it.next()) |chunk| : (r += 1) {
        if (r >= row + height) break;
        const at = onScreen(f, r) orelse {
            if (r >= f.win.height) break;
            continue;
        };
        const part = try sliceSegs(f.arena, segs.items, chunk);
        _ = f.win.print(part, .{ .row_offset = at, .col_offset = col + chunk.col, .wrap = .none });
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

/// Splits segments so every occurrence of `pat` gets `style`.
///
/// Done on the segments rather than by overwriting cells afterwards, because a
/// byte offset is not a column: a tab or a wide glyph earlier in the line
/// would put the highlight somewhere else entirely.
///
/// Matched against the whole `line` and clipped to each segment, not matched
/// inside each segment. Two reasons, and the second is the one that bites: a
/// whole-word match is decided by the bytes on either side of it, and a
/// segment boundary is not a word boundary - `*` on `id` would light up the
/// `id` in `width` the moment the lexer happened to split there. A match
/// straddling two runs still comes out as two highlighted pieces, which reads
/// the same.
fn markMatches(
    arena: Allocator,
    segs: std.ArrayList(vaxis.Segment),
    line: []const u8,
    pat: search.Pattern,
    style: vaxis.Style,
) Allocator.Error!std.ArrayList(vaxis.Segment) {
    const sensitive = search.caseSensitive(pat.text);
    var out: std.ArrayList(vaxis.Segment) = .empty;

    var base: usize = 0;
    for (segs.items) |seg| {
        const seg_end = base + seg.text.len;
        // Emitted up to here. Absolute, so a match that began in the previous
        // segment does not get painted twice.
        var cut = base;
        // Back up far enough to catch a match that starts before this segment
        // and reaches into it.
        var at = base -| (pat.text.len -| 1);

        while (search.indexOfIn(line, at, pat, sensitive)) |m| {
            const start: usize = m;
            if (start >= seg_end) break;
            const end = start + pat.text.len;
            at = end;
            if (end <= base) continue;

            const lo = @max(start, cut);
            const hi = @min(end, seg_end);
            if (lo > cut) try out.append(arena, .{ .text = line[cut..lo], .style = seg.style });
            if (hi > lo) try out.append(arena, .{ .text = line[lo..hi], .style = style });
            cut = hi;
        }
        if (seg_end > cut) try out.append(arena, .{ .text = line[cut..seg_end], .style = seg.style });
        base = seg_end;
    }
    return out;
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

    // The segments concatenate to the line, which is the invariant the
    // absolute-offset matching relies on.
    const line = "let token = tokenise();";
    var segs: std.ArrayList(vaxis.Segment) = .empty;
    try segs.append(arena, .{ .text = line[0..12], .style = plain });
    try segs.append(arena, .{ .text = line[12..], .style = plain });

    const out = try markMatches(arena, segs, line, .{ .text = "token" }, hit);

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

    const line = "TokenStore";
    var segs: std.ArrayList(vaxis.Segment) = .empty;
    try segs.append(arena, .{ .text = line, .style = .{} });

    // Lowercase query: matches either case.
    const loose = try markMatches(arena, segs, line, .{ .text = "token" }, .{ .bold = true });
    try testing.expect(loose.items[0].style.bold);

    // A capital pins it, so this one does not match at all - and an unmatched
    // line comes back as the single segment it went in as.
    const strict = try markMatches(arena, segs, line, .{ .text = "TOKEN" }, .{ .bold = true });
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

test "a whole-word highlight is not fooled by a segment boundary" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    // The lexer splitting `width` where it happens to split is not a word
    // boundary. Matching per-segment would light up the `id` inside it, and
    // the reader would see a hit that `n` then refuses to visit.
    const line = "width id";
    var segs: std.ArrayList(vaxis.Segment) = .empty;
    try segs.append(arena, .{ .text = line[0..1], .style = .{} });
    try segs.append(arena, .{ .text = line[1..5], .style = .{} });
    try segs.append(arena, .{ .text = line[5..], .style = .{} });

    const out = try markMatches(arena, segs, line, .{ .text = "id", .whole = true }, .{ .bold = true });

    var joined: std.ArrayList(u8) = .empty;
    var lit: std.ArrayList(u8) = .empty;
    for (out.items) |seg| {
        try joined.appendSlice(arena, seg.text);
        if (seg.style.bold) try lit.appendSlice(arena, seg.text);
    }
    try testing.expectEqualStrings(line, joined.items);
    try testing.expectEqualStrings("id", lit.items);
}

test "a match straddling two segments is painted whole" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    // The bytes are split mid-match; every one of them still gets the style,
    // and none of them gets it twice.
    const line = "the token here";
    var segs: std.ArrayList(vaxis.Segment) = .empty;
    try segs.append(arena, .{ .text = line[0..6], .style = .{} });
    try segs.append(arena, .{ .text = line[6..], .style = .{} });

    const out = try markMatches(arena, segs, line, .{ .text = "token" }, .{ .bold = true });

    var joined: std.ArrayList(u8) = .empty;
    var lit: std.ArrayList(u8) = .empty;
    for (out.items) |seg| {
        try joined.appendSlice(arena, seg.text);
        if (seg.style.bold) try lit.appendSlice(arena, seg.text);
    }
    try testing.expectEqualStrings(line, joined.items);
    try testing.expectEqualStrings("token", lit.items);
}
