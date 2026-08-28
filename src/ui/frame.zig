// SPDX-License-Identifier: Apache-2.0
//
// What a frame is made of: the surface drawn onto, and the data drawn from.
//
// Shared by everything that draws - `render.zig` for the chrome, `body.zig`
// for the diff, `popup.zig` for the `?` overlay - and importing nothing back
// from them, which is what keeps those three independent of each other rather
// than a knot of mutual imports.
//
// Every string a frame draws is allocated from `Frame.arena`, because vaxis
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
const buffer = @import("../text/buffer.zig");
const lexer = @import("../syntax/lexer.zig");
const keytext = @import("keytext.zig");
const rows_mod = @import("rows.zig");
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
    /// The `F` popup, the same way. Only one overlay is ever open, because
    /// each is its own mode.
    files: ?FilesView = null,
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

    pub fn width(self: Frame) u16 {
        return self.win.width;
    }

    /// A rule spanning `cols` columns, built from a possibly multi-byte glyph.
    pub fn rule(self: Frame, glyph: []const u8, cols: u16) Allocator.Error![]const u8 {
        const out = try self.arena.alloc(u8, @as(usize, cols) * glyph.len);
        var i: usize = 0;
        while (i < cols) : (i += 1) {
            @memcpy(out[i * glyph.len ..][0..glyph.len], glyph);
        }
        return out;
    }

    pub fn put(self: Frame, row: u16, col: u16, text: []const u8, style: vaxis.Style) void {
        _ = self.win.printSegment(
            .{ .text = text, .style = style },
            .{ .row_offset = row, .col_offset = col, .wrap = .none },
        );
    }

    /// Right-aligns using display width, never byte length: the status fields
    /// are full of multi-byte glyphs and `─` is three bytes wide and one
    /// column.
    /// Formats into the frame arena, draws it, and returns its display width -
    /// which is what the caller wants next in every case but one, because the
    /// status and mode rows are laid out left to right. Display width, never
    /// byte length: these rows are full of multi-byte glyphs.
    pub fn print(
        self: Frame,
        row: u16,
        col: u16,
        style: vaxis.Style,
        comptime fmt: []const u8,
        args: anytype,
    ) Allocator.Error!u16 {
        const text = try std.fmt.allocPrint(self.arena, fmt, args);
        self.put(row, col, text, style);
        return self.win.gwidth(text);
    }

    pub fn putRight(self: Frame, row: u16, text: []const u8, style: vaxis.Style) void {
        const w = self.win.gwidth(text);
        if (w >= self.width()) return self.put(row, 0, text, style);
        self.put(row, self.width() - w, text, style);
    }
};

/// Everything the `?` popup draws. Separate from `View` because the popup has
/// to be drawable over the empty screen too, where there is no file to review
/// and so no `View` to put it in.
pub const HelpView = struct {
    /// Rows for the mode the popup was opened from, already narrowed by
    /// `query`. From the bindings, so a remapped keymap documents itself
    /// rather than the defaults (FEATURES.md 4.4).
    entries: []const keytext.HelpEntry,
    query: []const u8 = "",
    /// Selected row, an index into `entries` after filtering.
    index: usize = 0,
    /// The popup's own keys, drawn along its bottom border. Generated like
    /// every other row, so remapping the navigation relabels the box.
    keys: []const keytext.HelpEntry = &.{},
    /// Written by the renderer with the grid it laid out, so the app can move
    /// the selection by a whole column without duplicating the layout maths.
    layout: ?*HelpLayout = null,
};

/// One row of the `F` overlay: a changed file, as the reader picks it out.
pub const FileEntry = struct {
    path: []const u8,
    added: u32,
    removed: u32,
    /// The file the review is currently on, marked so the list opens showing
    /// the reader where they already are rather than at an arbitrary top.
    current: bool = false,
};

/// Everything the `F` overlay draws. Its own view for the same reason
/// `HelpView` is: it floats over the body and has to be drawable when there is
/// no body at all.
pub const FilesView = struct {
    entries: []const FileEntry,
    query: []const u8 = "",
    /// Selected row, an index into `entries` after filtering.
    index: usize = 0,
    /// The popup's own keys, along its bottom border.
    keys: []const keytext.HelpEntry = &.{},
    layout: ?*HelpLayout = null,
};

/// The grid the popup last drew: how many columns, and how tall each is.
pub const HelpLayout = struct {
    cols: u16 = 1,
    per: usize = 1,
};

/// A style with `bg` forced, for a row that is highlighted underneath.
pub fn withBg(style: vaxis.Style, bg: ?vaxis.Color) vaxis.Style {
    var out = style;
    if (bg) |b| out.bg = b;
    return out;
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
