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
const keymap = @import("keymap.zig");
const prompt_mod = @import("prompt.zig");
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
    /// The `?` popup. Non-null floats a box over the body.
    help: ?HelpView = null,
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
        if (v.help) |hv| try drawHelpPopup(f, hv, 0, h);
        return;
    }
    if (h < chrome_rows + 1) return drawTooSmall(f);

    try drawStatus(f, v, 0);
    f.put(1, 0, try f.rule(f.glyphs.rule, f.width()), f.theme.rule);
    try drawBody(f, v, 2, bodyHeight(h, false));
    f.put(h - 2, 0, try f.rule(f.glyphs.rule, f.width()), f.theme.rule);
    if (v.prompt) |p| drawPrompt(f, p, h - 1) else try drawMode(f, v, h - 1);

    // Last, and over everything: it is a layer, not a pane.
    if (v.help) |hv| try drawHelpPopup(f, hv, 2, bodyHeight(h, false));
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
        .help => "HELP",
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

/// A byte range inside a border label.
const Span = struct { start: usize, len: usize };

/// The popup's bottom label, and where the key names sit inside it so they can
/// be repainted in the accent: a key is a key wherever it is drawn, and one
/// colour in the list with another in the footer makes them look like two
/// different things.
///
/// Keys sharing a description collapse into one label - four bindings become
/// `H J K L move`, because four rows each saying "move" is the verbose
/// spelling of the same thing. `<Esc>` is written rather than generated
/// because closing is `prompt.zig`'s hardcoded cancel, not a binding.
fn helpFooter(arena: Allocator, keys: []const keymap.HelpEntry) Allocator.Error!struct {
    text: []const u8,
    keys: []const Span,
} {
    var out: std.ArrayList(u8) = .empty;
    var spans: std.ArrayList(Span) = .empty;
    try out.appendSlice(arena, " type to filter  ");
    var n: usize = 0;
    while (n < keys.len) {
        var last = n;
        while (last + 1 < keys.len and std.mem.eql(u8, keys[last + 1].desc, keys[n].desc)) last += 1;
        for (keys[n .. last + 1]) |e| {
            try spans.append(arena, .{ .start = out.items.len, .len = e.keys.len });
            try out.appendSlice(arena, e.keys);
            try out.appendSlice(arena, " ");
        }
        try out.appendSlice(arena, keys[n].desc);
        try out.appendSlice(arena, "  ");
        n = last + 1;
    }
    try spans.append(arena, .{ .start = out.items.len, .len = "<Esc>".len });
    try out.appendSlice(arena, "<Esc> close ");
    return .{ .text = out.items, .keys = spans.items };
}

/// Everything the `?` popup draws. Separate from `View` because the popup has
/// to be drawable over the empty screen too, where there is no file to review
/// and so no `View` to put it in.
pub const HelpView = struct {
    /// Rows for the mode the popup was opened from, already narrowed by
    /// `query`. From the bindings, so a remapped keymap documents itself
    /// rather than the defaults (FEATURES.md 4.4).
    entries: []const keymap.HelpEntry,
    query: []const u8 = "",
    /// Selected row, an index into `entries` after filtering.
    index: usize = 0,
    /// The popup's own keys, drawn along its bottom border. Generated like
    /// every other row, so remapping the navigation relabels the box.
    keys: []const keymap.HelpEntry = &.{},
    /// Written by the renderer with the grid it laid out, so the app can move
    /// the selection by a whole column without duplicating the layout maths.
    layout: ?*HelpLayout = null,
};

/// The grid the popup last drew: how many columns, and how tall each is.
pub const HelpLayout = struct {
    cols: u16 = 1,
    per: usize = 1,
};

/// One horizontal border of the popup, with a label let into it.
const prompt_filter_prefix = prompt_mod.Kind.help_filter.prefix();

fn borderLine(f: Frame, corner_l: []const u8, corner_r: []const u8, label: []const u8, inner: u16) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(f.arena, corner_l);
    const lw = f.win.gwidth(label);
    const lead: u16 = if (lw == 0) 0 else 1;
    if (lead > 0) try out.appendSlice(f.arena, try f.rule(f.glyphs.box_h, lead));
    if (lw <= inner) try out.appendSlice(f.arena, label);
    const used = if (lw <= inner) lead + lw else 0;
    try out.appendSlice(f.arena, try f.rule(f.glyphs.box_h, inner -| used));
    try out.appendSlice(f.arena, corner_r);
    return out.toOwnedSlice(f.arena);
}

/// The `?` popup: a box floating over the diff rather than a screen replacing
/// it, so the review stays visible around the edges and the overlay reads as a
/// layer. Sized to its contents and centred in the body.
///
/// Two columns where the width allows, because the default keymap is 23 rows
/// and an 80x26 pane has 22 to give. Nothing here is a written-out key list:
/// every row is rendered from the bindings, so a key that moves moves here too.
pub fn drawHelpPopup(f: Frame, v: HelpView, top: u16, height: u16) Allocator.Error!void {
    const entries = v.entries;
    // Below this there is no honest box: border, filter line, one row, border.
    if (height < 4 or f.width() < 24) return;

    var keyw: u16 = 0;
    var descw: u16 = 0;
    for (entries) |e| {
        keyw = @max(keyw, f.win.gwidth(e.keys));
        descw = @max(descw, f.win.gwidth(e.desc));
    }
    const gap: u16 = 2;
    const one = @max(keyw + gap + descw, 12);

    const title = " keys ";
    // The popup's own keys, along the bottom with the filter hint. Keys that
    // share a description collapse into one label - four rows saying "move" is
    // the verbose spelling of `H J K L move`. Built from the bindings, so
    // remapping relabels the box. `<Esc>` is `prompt.zig`'s, the same
    // hardcoded cancel every prompt has, which is why it is written here
    // rather than generated.
    const foot = try helpFooter(f.arena, v.keys);
    const footer = foot.text;
    const query = try std.fmt.allocPrint(f.arena, "{s}{s}", .{ prompt_filter_prefix, v.query });

    // Content width: the columns, but never narrower than the chrome that
    // frames them, and never wider than the pane.
    const max_content = f.width() -| 4;
    var cols: u16 = if (one * 2 + gap <= max_content and entries.len > 6) 2 else 1;
    var content = @min(max_content, @max(one * cols + (cols - 1) * gap, @max(f.win.gwidth(title), f.win.gwidth(footer))));
    if (content < one and cols == 2) {
        cols = 1;
        content = @min(max_content, one);
    }

    // Rows: two borders and the filter line are chrome; the rest is the list.
    const list_max = height - 3;
    const per_full: usize = (entries.len + cols - 1) / cols;
    var per: usize = @max(@min(per_full, list_max), 1);
    const overflows = entries.len > per * cols;
    // A row of the list is spent on the "+N more" marker when there is more.
    if (overflows and per > 1) per -= 1;

    const window = per * cols;
    const sel = @min(v.index, entries.len -| 1);
    // Scroll a whole column at a time, so the columns stay aligned and the
    // selection is always inside the window.
    const offset: usize = if (window > 0 and sel >= window) ((sel - window) / per + 1) * per else 0;
    const shown = @min(entries.len -| offset, window);
    const hidden = entries.len - offset - shown;
    const list_rows: u16 = @intCast(@max(per + @intFromBool(hidden > 0), 1));
    if (v.layout) |hl| hl.* = .{ .cols = cols, .per = per };

    const box_w = content + 4;
    const box_h = list_rows + 3;
    const box_col = (f.width() -| box_w) / 2;
    const box_top = top + (height -| box_h) / 2;
    const text_col = box_col + 2;

    // Blank the box first: the diff is underneath it, not behind it.
    const blank = try f.arena.alloc(u8, box_w);
    @memset(blank, ' ');
    var r: u16 = 0;
    while (r < box_h) : (r += 1) f.put(box_top + r, box_col, blank, f.theme.text);

    const border = f.theme.popup_border;
    f.put(box_top, box_col, try borderLine(f, f.glyphs.box_tl, f.glyphs.box_tr, title, content + 2), border);
    f.put(box_top + box_h - 1, box_col, try borderLine(f, f.glyphs.box_bl, f.glyphs.box_br, footer, content + 2), border);
    // `borderLine` lays the label after a corner and one rule glyph, so the
    // label starts two columns in. Key names are ASCII, so a byte offset into
    // the label is also a column offset.
    if (f.win.gwidth(footer) <= content + 2) {
        for (foot.keys) |sp| {
            f.put(box_top + box_h - 1, box_col + 2 + @as(u16, @intCast(sp.start)), footer[sp.start..][0..sp.len], f.theme.accent);
        }
    }
    var body_row: u16 = 1;
    while (body_row < box_h - 1) : (body_row += 1) {
        f.put(box_top + body_row, box_col, f.glyphs.box_v, border);
        f.put(box_top + body_row, box_col + box_w - 1, f.glyphs.box_v, border);
    }

    f.put(box_top + 1, text_col, query, f.theme.prompt);

    const list_top = box_top + 2;
    var i: usize = 0;
    while (i < shown and per > 0) : (i += 1) {
        const col_index: u16 = @intCast(i / per);
        if (col_index >= cols) break;
        const row = list_top + @as(u16, @intCast(i % per));
        const col = text_col + col_index * (one + gap);
        if (col + keyw >= box_col + box_w) break;
        const e = entries[offset + i];
        if (offset + i == sel) {
            // The selected row, marked the way the cursor line is marked in
            // the body - one idea of "you are here" across the whole app.
            const bg = f.theme.cursor_line.bg;
            f.put(row, col, blank[0..@min(one, blank.len)], f.theme.cursor_line);
            f.put(row, col, e.keys, withBg(f.theme.accent, bg));
            f.put(row, col + keyw + gap, e.desc, withBg(f.theme.text, bg));
        } else {
            f.put(row, col, e.keys, f.theme.accent);
            f.put(row, col + keyw + gap, e.desc, f.theme.text);
        }
    }

    if (hidden > 0) {
        // A silently short list is indistinguishable from a keymap that really
        // is that small.
        const more = try std.fmt.allocPrint(f.arena, "+{d} more", .{hidden});
        f.put(list_top + @as(u16, @intCast(per)), text_col, more, f.theme.dim);
    }
    if (entries.len == 0) {
        f.put(list_top, text_col, "no key matches", f.theme.dim);
    }
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

test "the popup footer marks exactly its key names, and no other text" {
    // The spans are what get repainted in the accent. An offset off by one
    // paints the space beside a key, or eats the first letter of a word, and
    // nothing else in the file would say so.
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const nav: []const keymap.HelpEntry = &.{
        .{ .keys = "H", .desc = "move" },
        .{ .keys = "J", .desc = "move" },
        .{ .keys = "<Right>", .desc = "column" },
    };
    const foot = try helpFooter(arena, nav);

    // Same description, so `H` and `J` collapse under one label.
    try testing.expectEqualStrings(" type to filter  H J move  <Right> column  <Esc> close ", foot.text);

    const want = [_][]const u8{ "H", "J", "<Right>", "<Esc>" };
    try testing.expectEqual(want.len, foot.keys.len);
    for (foot.keys, want) |sp, expected| {
        try testing.expectEqualStrings(expected, foot.text[sp.start..][0..sp.len]);
    }
}

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
