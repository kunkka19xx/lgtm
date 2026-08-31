// SPDX-License-Identifier: Apache-2.0
//
// The `?` overlay: a box floating over the diff rather than a screen replacing
// it, so the review stays visible around the edges and the overlay reads as a
// layer (FEATURES.md 4.4).
//
// The geometry is separated from the drawing, because the geometry is the part
// that is easy to get wrong and impossible to see: how many columns fit, how
// many rows each holds, which slice of the list is on screen, and where the
// box sits. `fit` answers all of that as a pure function of the measurements,
// so the awkward cases - one column, a list too tall, a selection off the
// bottom - are unit tests rather than something to squint at in a terminal.

const std = @import("std");
const Allocator = std.mem.Allocator;

const frame_mod = @import("frame.zig");
const Frame = frame_mod.Frame;
const HelpView = frame_mod.HelpView;
const devicon = @import("devicon.zig");
const keytext = @import("keytext.zig");
const keymap = @import("keymap.zig");
const path_mod = @import("path.zig");
const prompt_mod = @import("prompt.zig");

/// A byte range inside a border label.
const Span = struct { start: usize, len: usize };

/// A border label, and where the key names sit inside it so they can be
/// repainted in the accent: a key is a key wherever it is drawn, and one
/// colour in the list with another in the footer makes them look like two
/// different things.
const Footer = struct {
    text: []const u8,
    keys: []const Span,
};

/// The bottom label: what the overlay's own keys are, and where the key names
/// sit inside the text so they can be repainted in the accent.
///
/// Keys sharing a description collapse into one label - four bindings become
/// `J K move  H L tab`, because four rows each saying the same word is the
/// verbose spelling of it. `max` is the widest the label may be: a group that
/// would not fit ends it, so a narrow pane loses the last hint rather than
/// the whole row. Bytes stand in for columns, which every key name and
/// description here is - and erring short only ever drops a group early. `tail` is for the keys that are not bindings:
/// `<CR>` and `<Esc>` are `prompt.zig`'s submit and cancel, the same two every
/// prompt has, so they are passed in rather than generated.
fn footerOf(
    arena: Allocator,
    keys: []const keytext.HelpEntry,
    tail: []const keytext.HelpEntry,
    max: u16,
) Allocator.Error!Footer {
    var out: std.ArrayList(u8) = .empty;
    var spans: std.ArrayList(Span) = .empty;
    try out.appendSlice(arena, " type to filter  ");

    var all: std.ArrayList(keytext.HelpEntry) = .empty;
    try all.appendSlice(arena, keys);
    try all.appendSlice(arena, tail);

    var n: usize = 0;
    while (n < all.items.len) {
        // Where this group started, to roll back to if it does not fit.
        const mark = out.items.len;
        var last = n;
        while (last + 1 < all.items.len and
            std.mem.eql(u8, all.items[last + 1].desc, all.items[n].desc)) last += 1;
        for (all.items[n .. last + 1]) |e| {
            // The first spelling only. An entry carries every alias of its
            // action - `]f / <Space>nf` - which is what the list above wants
            // and what a one-line footer inside a box cannot afford.
            const k = e.keys[0 .. std.mem.indexOf(u8, e.keys, keytext.row_keys_sep) orelse e.keys.len];
            try spans.append(arena, .{ .start = out.items.len, .len = k.len });
            try out.appendSlice(arena, k);
            try out.appendSlice(arena, " ");
        }
        try out.appendSlice(arena, all.items[n].desc);
        try out.appendSlice(arena, "  ");
        // A group that would not fit ends the label rather than overflowing
        // it. Whole groups, because half of `<Esc> close` says nothing - and
        // a footer that is dropped altogether for being one column too wide
        // is the worst of the three, which is what this used to do.
        if (out.items.len > max) {
            out.shrinkRetainingCapacity(mark);
            while (spans.items.len > 0 and spans.items[spans.items.len - 1].start >= mark) {
                _ = spans.pop();
            }
            break;
        }
        n = last + 1;
    }
    // Trailing separator trimmed: the label sits inside a border, and two
    // spaces before the corner read as a gap in it.
    return .{ .text = out.items[0 .. out.items.len - 1], .keys = spans.items };
}

/// The tab strip, let into the *top* border with the active tab marked so it
/// can be repainted in the accent.
///
/// Into the border rather than onto a row of its own: a box already has a top
/// edge, and a popup in an 80x24 pane cannot spend one of its rows on labels
/// for its rows. Null highlights nothing, which is what a filter does - it
/// searches every tab, so none of them is the one being shown.
fn tabsOf(arena: Allocator, active: ?keymap.Group) Allocator.Error!Footer {
    var out: std.ArrayList(u8) = .empty;
    var spans: std.ArrayList(Span) = .empty;
    try out.appendSlice(arena, " ");
    for (std.enums.values(keymap.Group)) |g| {
        const label = g.label();
        if (active) |a| {
            if (g == a) try spans.append(arena, .{ .start = out.items.len, .len = label.len });
        }
        try out.appendSlice(arena, label);
        try out.appendSlice(arena, "  ");
    }
    return .{ .text = out.items[0 .. out.items.len - 1], .keys = spans.items };
}

/// What closing an overlay is bound to, in both of them.
const close_key: keytext.HelpEntry = .{ .keys = "<Esc>", .desc = "close" };

/// The prefix drawn before the filter text, from the prompt that collects it.
const prompt_filter_prefix = prompt_mod.Kind.help_filter.prefix();

/// One horizontal border of the box, with a label let into it.
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

/// Blanks the box, draws its borders and the two labels let into them, and
/// returns a run of spaces as wide as the box - which the list then uses to
/// paint a selected row. Shared by both overlays, because a box is a box: only
/// what goes inside it differs.
fn chromeOf(f: Frame, box: Box, title: Footer, foot: Footer, title_width: u16, footer_width: u16) Allocator.Error![]u8 {
    const blank = try f.arena.alloc(u8, box.width);
    @memset(blank, ' ');
    var r: u16 = 0;
    while (r < box.height) : (r += 1) f.put(box.top + r, box.col, blank, f.theme.text);

    const border = f.theme.popup_border;
    const inner = box.content + 2;
    f.put(box.top, box.col, try borderLine(f, f.glyphs.box_tl, f.glyphs.box_tr, title.text, inner), border);
    f.put(box.top + box.height - 1, box.col, try borderLine(f, f.glyphs.box_bl, f.glyphs.box_br, foot.text, inner), border);
    // `borderLine` lays the label after a corner and one rule glyph, so the
    // label starts two columns in. Key names are ASCII, so a byte offset into
    // the label is also a column offset.
    if (footer_width <= inner) {
        for (foot.keys) |sp| {
            f.put(box.top + box.height - 1, box.col + 2 + @as(u16, @intCast(sp.start)), foot.text[sp.start..][0..sp.len], f.theme.accent);
        }
    }
    if (title_width <= inner) {
        for (title.keys) |sp| {
            f.put(box.top, box.col + 2 + @as(u16, @intCast(sp.start)), title.text[sp.start..][0..sp.len], f.theme.accent);
        }
    }
    var body_row: u16 = 1;
    while (body_row < box.height - 1) : (body_row += 1) {
        f.put(box.top + body_row, box.col, f.glyphs.box_v, border);
        f.put(box.top + body_row, box.col + box.width - 1, f.glyphs.box_v, border);
    }
    return blank;
}

/// What a box is laid out from: the widest key column and description in the
/// list, how many rows there are, and the two labels let into the borders -
/// all in display columns, measured by the caller because only it has a window
/// to measure with.
pub const Metrics = struct {
    keys: u16 = 0,
    desc: u16 = 0,
    entries: usize = 0,
    title: u16 = 0,
    footer: u16 = 0,
    /// Most columns the grid may use. One everywhere now: a two-column grid
    /// made the reader scan in two directions to find a key, and the merged
    /// `]f / <Space>nf` rows are wide enough that the second column pushed the
    /// box past most panes. The grid is kept because a narrow list is the same
    /// code with `cols` of one.
    max_cols: u16 = 1,
};

/// The space the box may float in: the body, or the whole pane in zen mode.
pub const Area = struct {
    width: u16,
    top: u16,
    height: u16,
};

/// Where the box goes and what of the list it shows. Everything the drawing
/// needs and nothing it does not.
pub const Box = struct {
    /// Grid: how many columns, and how many rows in each.
    cols: u16,
    per: usize,
    /// The slice of the list on screen, and what is left below it.
    offset: usize,
    shown: usize,
    hidden: usize,
    /// The box itself, in screen coordinates.
    col: u16,
    top: u16,
    width: u16,
    height: u16,
    /// Width of the text area, and of one column of the grid inside it.
    content: u16,
    column: u16,
};

/// Columns between the key and its description, and between two columns.
pub const gap: u16 = 2;

/// The whole geometry, as a pure function of the measurements. Null when there
/// is no honest box to draw - below four rows there is no room for a border, a
/// filter line, one row and a border.
///
/// Two columns where the width allows, because the default keymap is 23 rows
/// and an 80x26 pane has 22 to give. The list scrolls a whole column at a
/// time, so the columns stay aligned and the selection is always inside the
/// window.
pub fn fit(m: Metrics, selected: usize, area: Area) ?Box {
    if (area.height < 4 or area.width < 24) return null;

    const one = @max(m.keys + gap + m.desc, 12);
    const max_content = area.width -| 4;

    var cols: u16 = if (m.max_cols > 1 and one * 2 + gap <= max_content and m.entries > 6) 2 else 1;
    var content = @min(max_content, @max(one * cols + (cols - 1) * gap, @max(m.title, m.footer)));
    // A second column that does not actually fit is worse than one: the list
    // would be laid out in a grid the box cannot show.
    if (content < one and cols == 2) {
        cols = 1;
        content = @min(max_content, one);
    }

    // Rows: two borders and the filter line are chrome; the rest is the list.
    const list_max = area.height - 3;
    const per_full: usize = (m.entries + cols - 1) / cols;
    var per: usize = @max(@min(per_full, list_max), 1);
    // A row of the list is spent on the "+N more" marker when there is more.
    if (m.entries > per * cols and per > 1) per -= 1;

    const window = per * cols;
    const sel = @min(selected, m.entries -| 1);
    const offset: usize = if (window > 0 and sel >= window) ((sel - window) / per + 1) * per else 0;
    const shown = @min(m.entries -| offset, window);
    const hidden = m.entries - offset - shown;

    const list_rows: u16 = @intCast(@max(per + @intFromBool(hidden > 0), 1));
    const width = content + 4;
    const height = list_rows + 3;
    return .{
        .cols = cols,
        .per = per,
        .offset = offset,
        .shown = shown,
        .hidden = hidden,
        .col = (area.width -| width) / 2,
        .top = area.top + (area.height -| height) / 2,
        .width = width,
        .height = height,
        .content = content,
        .column = one,
    };
}

/// Draws the overlay. Sized to its contents and centred in the body; nothing
/// here is a written-out key list, because every row is rendered from the
/// bindings, so a key that moves moves here too.
pub fn draw(f: Frame, v: HelpView, top: u16, height: u16) Allocator.Error!void {
    const entries = v.entries;

    var m: Metrics = .{ .entries = entries.len };
    for (entries) |e| {
        m.keys = @max(m.keys, f.win.gwidth(e.keys));
        m.desc = @max(m.desc, f.win.gwidth(e.desc));
    }

    const title = try tabsOf(f.arena, v.group);
    // The popup's own keys, along the bottom with the filter hint. `<Esc>` is
    // `prompt.zig`'s hardcoded cancel rather than a binding, which is why that
    // one is written out and the rest are generated.
    const foot = try footerOf(f.arena, v.keys, &.{close_key}, f.width() -| 2);
    const query = try std.fmt.allocPrint(f.arena, "{s}{s}", .{ prompt_filter_prefix, v.query });
    m.title = f.win.gwidth(title.text);
    m.footer = f.win.gwidth(foot.text);

    const box = fit(m, v.index, .{ .width = f.width(), .top = top, .height = height }) orelse return;

    const text_col = box.col + 2;
    const sel = @min(v.index, entries.len -| 1);
    const blank = try chromeOf(f, box, title, foot, m.title, m.footer);

    f.put(box.top + 1, text_col, query, f.theme.prompt);

    const list_top = box.top + 2;
    var i: usize = 0;
    while (i < box.shown and box.per > 0) : (i += 1) {
        const col_index: u16 = @intCast(i / box.per);
        if (col_index >= box.cols) break;
        const row = list_top + @as(u16, @intCast(i % box.per));
        const col = text_col + col_index * (box.column + gap);
        if (col + m.keys >= box.col + box.width) break;
        const e = entries[box.offset + i];
        if (box.offset + i == sel) {
            // The selected row, marked the way the cursor line is marked in
            // the body - one idea of "you are here" across the whole app.
            const bg = f.theme.cursor_line.bg;
            f.put(row, col, blank[0..@min(box.column, blank.len)], f.theme.cursor_line);
            f.put(row, col, e.keys, frame_mod.withBg(f.theme.accent, bg));
            f.put(row, col + m.keys + gap, e.desc, frame_mod.withBg(f.theme.text, bg));
        } else {
            f.put(row, col, e.keys, f.theme.accent);
            f.put(row, col + m.keys + gap, e.desc, f.theme.text);
        }
    }

    if (box.hidden > 0) {
        // A silently short list is indistinguishable from a keymap that really
        // is that small.
        const more = try std.fmt.allocPrint(f.arena, "+{d} more", .{box.hidden});
        f.put(list_top + @as(u16, @intCast(box.per)), text_col, more, f.theme.dim);
    }
    if (entries.len == 0) {
        f.put(list_top, text_col, "no key matches", f.theme.dim);
    }
}

const testing = std.testing;

test "the popup footer marks exactly its key names, and no other text" {
    // The spans are what get repainted in the accent. An offset off by one
    // paints the space beside a key, or eats the first letter of a word, and
    // nothing else in the file would say so.
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const nav: []const keytext.HelpEntry = &.{
        .{ .keys = "H", .desc = "move" },
        .{ .keys = "J", .desc = "move" },
        .{ .keys = "<Right>", .desc = "column" },
    };
    const foot = try footerOf(arena, nav, &.{close_key}, 200);

    // Same description, so `H` and `J` collapse under one label.
    try testing.expectEqualStrings(" type to filter  H J move  <Right> column  <Esc> close ", foot.text);

    const want = [_][]const u8{ "H", "J", "<Right>", "<Esc>" };
    try testing.expectEqual(want.len, foot.keys.len);
    for (foot.keys, want) |sp, expected| {
        try testing.expectEqualStrings(expected, foot.text[sp.start..][0..sp.len]);
    }
}

test "a footer too wide for the box sheds whole groups, and never all of them" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const nav: []const keytext.HelpEntry = &.{
        .{ .keys = "J", .desc = "move" },
        .{ .keys = "H", .desc = "tab" },
    };
    // Wide: everything is there.
    const full = try footerOf(arena, nav, &.{close_key}, 200);
    try std.testing.expect(std.mem.indexOf(u8, full.text, "close") != null);

    // Narrow: the last group goes rather than the whole row. A footer that
    // vanishes for being one column too wide is the bug this replaced - it is
    // the only thing on screen saying what the keys are.
    const cut = try footerOf(arena, nav, &.{close_key}, 30);
    try std.testing.expect(cut.text.len <= 30);
    try std.testing.expect(std.mem.indexOf(u8, cut.text, "move") != null);
    try std.testing.expect(std.mem.indexOf(u8, cut.text, "close") == null);

    // Every span still points inside the text it was trimmed with, or the
    // accent repaint would read past the end of it.
    for (cut.keys) |sp| try std.testing.expect(sp.start + sp.len <= cut.text.len);

    // Even a budget of nothing leaves the hint rather than an empty border.
    const tiny = try footerOf(arena, nav, &.{close_key}, 1);
    try std.testing.expect(tiny.text.len > 0);
}

test "one column by default, and the grid still fits two when asked" {
    const m: Metrics = .{ .keys = 10, .desc = 22, .entries = 23, .title = 6, .footer = 40 };

    // A wide pane no longer buys a second column: every list is one column and
    // scrolls, because a grid is read in two directions to find one key.
    const wide = fit(m, 0, .{ .width = 100, .top = 2, .height = 22 }).?;
    try testing.expectEqual(@as(u16, 1), wide.cols);

    // The grid is still there for a caller that wants it, and still refuses
    // when the width cannot hold two columns.
    var grid = m;
    grid.max_cols = 2;
    try testing.expectEqual(@as(u16, 2), fit(grid, 0, .{ .width = 100, .top = 2, .height = 22 }).?.cols);
    try testing.expectEqual(@as(u16, 1), fit(grid, 0, .{ .width = 46, .top = 2, .height = 22 }).?.cols);

    const narrow = fit(m, 0, .{ .width = 46, .top = 2, .height = 22 }).?;
    try testing.expectEqual(@as(u16, 1), narrow.cols);

    // Too small for a border, a filter line, a row and a border.
    try testing.expect(fit(m, 0, .{ .width = 100, .top = 0, .height = 3 }) == null);
    try testing.expect(fit(m, 0, .{ .width = 20, .top = 0, .height = 22 }) == null);
}

test "a list too tall keeps a row for the count of what is left" {
    // The marker is not decoration: a silently short list is indistinguishable
    // from a keymap that really is that small.
    const m: Metrics = .{ .keys = 10, .desc = 22, .entries = 30, .title = 6, .footer = 40 };
    const box = fit(m, 0, .{ .width = 46, .top = 2, .height = 10 }).?;

    try testing.expectEqual(@as(u16, 1), box.cols);
    try testing.expect(box.hidden > 0);
    // Every entry is accounted for: shown, hidden, or scrolled above.
    try testing.expectEqual(m.entries, box.offset + box.shown + box.hidden);
    // Chrome is two borders and the filter line, plus a row for the marker.
    try testing.expectEqual(@as(u16, @intCast(box.per + 1 + 3)), box.height);
}

test "the window follows the selection, a whole column at a time" {
    const m: Metrics = .{ .keys = 10, .desc = 22, .entries = 30, .title = 6, .footer = 40 };
    const area: Area = .{ .width = 100, .top = 2, .height = 12 };

    // A selection inside the first window does not scroll it at all.
    const first = fit(m, 3, area).?;
    try testing.expectEqual(@as(usize, 0), first.offset);

    // One past the end of the window scrolls by exactly one column, so the
    // columns stay aligned rather than sliding row by row.
    const window = first.per * first.cols;
    const next = fit(m, window, area).?;
    try testing.expectEqual(first.per, next.offset);
    try testing.expect(next.offset + next.shown > window);

    // The last row is always inside the window it scrolled to.
    const last = fit(m, m.entries - 1, area).?;
    try testing.expect(m.entries - 1 >= last.offset);
    try testing.expect(m.entries - 1 < last.offset + last.shown);
}

test "the box is centred in the area it floats over" {
    const m: Metrics = .{ .keys = 10, .desc = 22, .entries = 8, .title = 6, .footer = 40 };
    const box = fit(m, 0, .{ .width = 100, .top = 2, .height = 22 }).?;

    try testing.expectEqual((100 - box.width) / 2, box.col);
    try testing.expectEqual(2 + (22 - box.height) / 2, box.top);
    try testing.expect(box.col + box.width <= 100);
    try testing.expect(box.top + box.height <= 2 + 22);
}

test "an empty list still draws a box to say so in" {
    const box = fit(.{ .entries = 0, .title = 6, .footer = 40 }, 0, .{ .width = 60, .top = 0, .height = 20 }).?;
    try testing.expectEqual(@as(usize, 0), box.shown);
    try testing.expectEqual(@as(usize, 0), box.hidden);
    try testing.expect(box.height >= 4);
}

/// The `F` overlay: every changed file, filtered as you type, `Enter` to jump.
/// One column always - a row is a path, and splitting paths across two columns
/// costs each of them the width it needs.
pub fn drawFiles(f: Frame, v: frame_mod.FilesView, top: u16, height: u16) Allocator.Error!void {
    const entries = v.entries;

    // Fixed cells before the path: the "you are here" mark and a space, plus
    // the icon and another space when the glyph set has icons. Fixed, because
    // a slot that is only sometimes there steps every path beside it one
    // column sideways.
    const icons = f.glyphs.file_icons;
    const lead: u16 = 2 + @as(u16, if (icons) 2 else 0);

    var m: Metrics = .{ .entries = entries.len, .max_cols = 1 };
    for (entries) |e| {
        m.keys = @max(m.keys, lead + f.win.gwidth(e.path));
        m.desc = @max(m.desc, countsWidth(e));
    }

    // No tabs: the file list is one list. A `Footer` with no marked span
    // is a plain label, which is what the shared chrome wants.
    const title: Footer = .{ .text = " files ", .keys = &.{} };
    const foot = try footerOf(f.arena, v.keys, &.{
        .{ .keys = "<CR>", .desc = "open" },
        close_key,
    }, f.width() -| 2);
    const query = try std.fmt.allocPrint(f.arena, "{s}{s}", .{ prompt_filter_prefix, v.query });
    m.title = f.win.gwidth(title.text);
    m.footer = f.win.gwidth(foot.text);

    const box = fit(m, v.index, .{ .width = f.width(), .top = top, .height = height }) orelse return;
    if (v.layout) |hl| hl.* = .{ .cols = box.cols, .per = box.per };

    const text_col = box.col + 2;
    const sel = @min(v.index, entries.len -| 1);
    const blank = try chromeOf(f, box, title, foot, m.title, m.footer);

    f.put(box.top + 1, text_col, query, f.theme.prompt);

    const list_top = box.top + 2;
    var i: usize = 0;
    while (i < box.shown) : (i += 1) {
        const row = list_top + @as(u16, @intCast(i));
        const e = entries[box.offset + i];
        const on = box.offset + i == sel;
        const bg = if (on) f.theme.cursor_line.bg else null;
        if (on) f.put(row, text_col - 1, blank[0 .. box.content + 2], f.theme.cursor_line);

        // The file the review is on is marked rather than merely selected:
        // "where I am" and "what I am pointing at" are different questions,
        // and the list is opened to answer the first.
        const here = if (e.current) f.glyphs.sep else " ";
        f.put(row, text_col, here, frame_mod.withBg(f.theme.accent, bg));

        // The row carries its status in one colour: green arrived, red left,
        // amber changed, blue moved, grey cannot be read. One colour and not
        // two, so a row reads as one thing rather than as an icon and a path
        // that happen to be adjacent. The current file is bold on top of
        // whichever colour it is, so "where I am" survives.
        var style = switch (e.status) {
            .added => f.theme.file_added,
            .deleted => f.theme.file_deleted,
            .modified => f.theme.file_modified,
            .renamed => f.theme.file_renamed,
            .binary => f.theme.file_binary,
        };
        style.bold = e.current;
        const on_row = frame_mod.withBg(style, bg);

        // The icon takes its filetype colour, the way oil.nvim and neo-tree
        // draw it: the shape and the hue together are what let a reader find
        // the Zig file without reading a name. The path keeps the status
        // colour, so the row still says what happened to it.
        if (devicon.forPath(e.path, icons)) |icon| {
            const hue = switch (icon.hue) {
                .red => f.theme.hues.red,
                .green => f.theme.hues.green,
                .yellow => f.theme.hues.yellow,
                .blue => f.theme.hues.blue,
                .magenta => f.theme.hues.magenta,
                .cyan => f.theme.hues.cyan,
                .muted => f.theme.hues.muted,
            };
            f.put(row, text_col + 2, icon.glyph, frame_mod.withBg(.{ .fg = hue }, bg));
        }
        // The counts keep their column and the path takes what is left, then
        // loses its middle rather than its tail: a terminal clips from the
        // right, and for a path that removes the file name - the one part
        // that says which file this is (`ui/path.zig`).
        const budget = box.content -| (lead + m.desc + gap);
        const shown = try path_mod.elide(f.arena, e.path, budget, f.glyphs.ellipsis, f.method());
        f.put(row, text_col + lead, shown, on_row);

        // Counts right-aligned inside the box, so the paths stay readable as a
        // column even when one of them is very long.
        const counts_col = text_col + box.content - countsWidth(e);
        if (counts_col > text_col + lead + f.win.gwidth(shown)) {
            var col = counts_col;
            col += try f.print(row, col, frame_mod.withBg(f.theme.added_count, bg), "+{d}", .{e.added}) + 1;
            _ = try f.print(row, col, frame_mod.withBg(f.theme.removed_count, bg), "{s}{d}", .{ f.glyphs.del, e.removed });
        }
    }

    if (box.hidden > 0) {
        const more = try std.fmt.allocPrint(f.arena, "+{d} more", .{box.hidden});
        f.put(list_top + @as(u16, @intCast(box.per)), text_col, more, f.theme.dim);
    }
    if (entries.len == 0) {
        f.put(list_top, text_col, "no file matches", f.theme.dim);
    }
}

/// Width of `+12 −4`, which the layout needs before anything is drawn.
fn countsWidth(e: frame_mod.FileEntry) u16 {
    return @intCast(2 + digits(e.added) + digits(e.removed) + 1);
}

fn digits(n: u32) usize {
    var w: usize = 1;
    var v = n;
    while (v >= 10) : (v /= 10) w += 1;
    return w;
}

test "a file list is one column, however wide the pane" {
    // Two columns of paths would give each of them half the width it needs,
    // and a path truncated in the middle is not a path.
    const m: Metrics = .{ .keys = 20, .desc = 8, .entries = 20, .title = 7, .footer = 50, .max_cols = 1 };
    const wide = fit(m, 0, .{ .width = 200, .top = 0, .height = 30 }).?;
    try testing.expectEqual(@as(u16, 1), wide.cols);

    // The key list, with the same measurements, does take the second column.
    var keys = m;
    keys.max_cols = 2;
    try testing.expectEqual(@as(u16, 2), fit(keys, 0, .{ .width = 200, .top = 0, .height = 30 }).?.cols);
}
