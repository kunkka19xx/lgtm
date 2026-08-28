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
const keytext = @import("keytext.zig");
const prompt_mod = @import("prompt.zig");

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
fn helpFooter(arena: Allocator, keys: []const keytext.HelpEntry) Allocator.Error!struct {
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

    var cols: u16 = if (one * 2 + gap <= max_content and m.entries > 6) 2 else 1;
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

    const title = " keys ";
    // The popup's own keys, along the bottom with the filter hint. `<Esc>` is
    // `prompt.zig`'s hardcoded cancel rather than a binding, which is why that
    // one is written out and the rest are generated.
    const foot = try helpFooter(f.arena, v.keys);
    const query = try std.fmt.allocPrint(f.arena, "{s}{s}", .{ prompt_filter_prefix, v.query });
    m.title = f.win.gwidth(title);
    m.footer = f.win.gwidth(foot.text);

    const box = fit(m, v.index, .{ .width = f.width(), .top = top, .height = height }) orelse return;
    if (v.layout) |hl| hl.* = .{ .cols = box.cols, .per = box.per };

    const text_col = box.col + 2;
    const sel = @min(v.index, entries.len -| 1);

    // Blank the box first: the diff is underneath it, not behind it.
    const blank = try f.arena.alloc(u8, box.width);
    @memset(blank, ' ');
    var r: u16 = 0;
    while (r < box.height) : (r += 1) f.put(box.top + r, box.col, blank, f.theme.text);

    const border = f.theme.popup_border;
    const inner = box.content + 2;
    f.put(box.top, box.col, try borderLine(f, f.glyphs.box_tl, f.glyphs.box_tr, title, inner), border);
    f.put(box.top + box.height - 1, box.col, try borderLine(f, f.glyphs.box_bl, f.glyphs.box_br, foot.text, inner), border);
    // `borderLine` lays the label after a corner and one rule glyph, so the
    // label starts two columns in. Key names are ASCII, so a byte offset into
    // the label is also a column offset.
    if (m.footer <= inner) {
        for (foot.keys) |sp| {
            f.put(box.top + box.height - 1, box.col + 2 + @as(u16, @intCast(sp.start)), foot.text[sp.start..][0..sp.len], f.theme.accent);
        }
    }
    var body_row: u16 = 1;
    while (body_row < box.height - 1) : (body_row += 1) {
        f.put(box.top + body_row, box.col, f.glyphs.box_v, border);
        f.put(box.top + body_row, box.col + box.width - 1, f.glyphs.box_v, border);
    }

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
    const foot = try helpFooter(arena, nav);

    // Same description, so `H` and `J` collapse under one label.
    try testing.expectEqualStrings(" type to filter  H J move  <Right> column  <Esc> close ", foot.text);

    const want = [_][]const u8{ "H", "J", "<Right>", "<Esc>" };
    try testing.expectEqual(want.len, foot.keys.len);
    for (foot.keys, want) |sp, expected| {
        try testing.expectEqualStrings(expected, foot.text[sp.start..][0..sp.len]);
    }
}

test "a narrow pane gets one column, a wide one gets two" {
    // 23 rows of keys against an 80x26 pane is the case the two-column layout
    // exists for; at 60 columns the same list has to fall back to one.
    const m: Metrics = .{ .keys = 10, .desc = 22, .entries = 23, .title = 6, .footer = 40 };

    const wide = fit(m, 0, .{ .width = 100, .top = 2, .height = 22 }).?;
    try testing.expectEqual(@as(u16, 2), wide.cols);

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
