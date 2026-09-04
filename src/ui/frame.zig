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
//. A slice that dies early renders as plausible garbage
// on one row rather than crashing, so this rule is a review item, not
// something the compiler catches.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");

const diff = @import("../core/diff.zig");
const testrisk = @import("../core/testrisk.zig");
const event = @import("../core/event.zig");
const buffer = @import("../text/buffer.zig");
const lexer = @import("../syntax/lexer.zig");
const keytext = @import("keytext.zig");
const search = @import("search.zig");
const keymap = @import("keymap.zig");
const rows_mod = @import("rows.zig");
const theme_mod = @import("theme.zig");
const anim = @import("anim.zig");
const wrap = @import("wrap.zig");

pub const Theme = theme_mod.Theme;
pub const Side = rows_mod.Side;
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

/// What is selected: rows always, and for a charwise selection the columns
/// that bound it at either end.
///
/// One type for both kinds rather than two, because every consumer wants the
/// rows and only the renderer wants the columns - and a `?Selection` that is
/// sometimes a different shape is a switch at each of them.
pub const Selection = struct {
    pub const Kind = enum { line, char };

    /// A half-open byte range of one line's text.
    pub const Span = struct { lo: u32, hi: u32 };

    /// Inclusive row range, normalised so `lo <= hi`.
    lo: u32,
    hi: u32,
    kind: Kind = .line,
    /// First selected byte on row `lo`, and the byte *after* the last selected
    /// one on row `hi`. Half-open at the far end because that is what slicing
    /// wants; vim's inclusive end is converted once, where the selection is
    /// built. Both are meaningless when `kind` is `.line`.
    lo_col: u32 = 0,
    hi_col: u32 = 0,

    pub fn contains(self: Selection, row: u32) bool {
        return row >= self.lo and row <= self.hi;
    }

    pub fn count(self: Selection) u32 {
        return self.hi - self.lo + 1;
    }

    /// The selected byte range on `row` of a line `len` bytes long, or null
    /// when the row is outside the selection. A linewise selection takes the
    /// whole line; a charwise one takes all of it but the two ends.
    pub fn span(self: Selection, row: u32, len: u32) ?Span {
        if (!self.contains(row)) return null;
        if (self.kind == .line) return .{ .lo = 0, .hi = len };
        const lo = if (row == self.lo) @min(self.lo_col, len) else 0;
        const hi = if (row == self.hi) @min(self.hi_col, len) else len;
        return if (hi > lo) .{ .lo = lo, .hi = hi } else null;
    }
};

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
    /// `<Tab>` candidates, all of them. Empty unless
    /// the reader is completing, and drawn over the rule rather than on a row
    /// of its own: while the prompt is open that rule is decoration, so the
    /// strip costs no screen. Narrowing them to the row is the renderer's job,
    /// because only it knows how wide the row is.
    completions: []const keymap.Command = &.{},
    /// Which of `completions` is in the line, as an index into it.
    completion_at: ?usize = null,
};

/// Everything one frame needs. Assembled by the app; nothing here reaches back
/// into the diff pipeline or the terminal.
pub const View = struct {
    file: *const diff.FileDiff,
    rows: rows_mod.Rows,
    file_index: u32,
    file_count: u32,
    /// Row index of the cursor, and of the first row drawn - which is where
    /// the viewport is *drawn*, not where it has settled, while a jump is
    /// still catching up.
    cursor: u32,
    scroll: u32,
    /// The row the cursor is *drawn* on. The same as `cursor` except while a
    /// jump is catching up, when it is displaced with the viewport so the
    /// cursor keeps its place on screen and the text slides under it. Only the
    /// body reads it: the status line counts hunks, which is a question about
    /// where the reader *is*, not about what is on screen this frame.
    cursor_drawn: u32 = 0,
    /// The cell the cursor block is drawn on, in body coordinates, or null
    /// when it is off screen. Fractional while it is travelling: the renderer
    /// rounds it to the cell it has reached. Computed by the app rather than
    /// here because the travel has to persist between frames, and a `View` is
    /// one frame's worth of answers.
    cursor_cell: ?anim.Cursor.Cell = null,
    /// Screen rows of the first drawn row that are above the top of the body.
    /// Non-zero only mid-animation, and only when that row is wrapped: it is
    /// what lets the viewport move by a screen row rather than by a whole
    /// line of the file (`ui/anim.zig`).
    skip: u16 = 0,
    /// Byte offset of the cursor within its line, for the cell the terminal
    /// cursor is parked on.
    col: u32 = 0,
    mode: event.Mode = .normal,
    hints: []const u8 = "",
    /// One bool per row of `file`: whether that change arrived after the mark
    /// (`core/checkpoint.zig`). Empty when there is no mark, which is most
    /// sessions and costs the body one length check.
    fresh: []const bool = &.{},
    /// How many rows across the whole review changed since the mark, and
    /// which mark it is. Zero and zero when there is none.
    fresh_total: u32 = 0,
    mark_turn: u32 = 0,
    /// What the review is against and of, when either is not the default.
    /// Empty means `HEAD` and the working tree, which is every ordinary
    /// session and costs the badge nothing.
    ///
    /// Drawn on the badge rather than in a notice for the same reason `TURN 2`
    /// is: a diff against `main` looks exactly like a diff against HEAD, and
    /// reading one as the other is the failure this view can cause. It is a
    /// *state*, not an answer to a keystroke.
    base: []const u8 = "",
    target: []const u8 = "",
    /// The turn on screen, or null for the working tree. The mode row says so
    /// on every frame it is set, and not optionally: a turn's diff looks
    /// exactly like the working tree's, and reading old code as current is the
    /// failure this view can cause.
    viewing: ?u32 = null,
    /// Turns written since the one on screen, so a reader parked in the past
    /// can see the present accumulating without being dragged into it.
    newer_turns: u32 = 0,
    /// The working tree has changed since this turn was opened. Drawn on the
    /// badge rather than only in the message slot: a notice would hide it, and
    /// what it says is a *state* rather than an answer to a keystroke.
    tree_moved: bool = false,
    /// What this change did to the tests across the whole review.
    risk: testrisk.Risk = .{},
    /// The keymap, so a message that has to name a key can ask what that key
    /// currently is. One field rather than one per message: every one of them
    /// would otherwise be a place `[keys]` could be remapped out from under,
    /// and a screen that advertises a key the reader does not have is worse
    /// than one that says nothing.
    bindings: []const keymap.Binding = &.{},
    /// What is selected, in body-row indexes, or null outside visual mode.
    selection: ?Selection = null,
    prompt: ?PromptView = null,
    /// A message about the last keystroke: a search that found nothing, a
    /// command that is not one. Takes the mode row when present.
    notice: []const u8 = "",
    /// The live search query, so hits stay highlighted after `/` closes -
    /// which is what makes `n` legible without re-reading the line.
    query: search.Pattern = .{},
    /// Chrome hidden, body full-height.
    zen: bool = false,
    /// Soft wrap: a line wider than the pane continues on the next screen row
    /// instead of being cut off at the edge. Off draws one line per row and
    /// clips, which is what a reader who wants the shape of the code back
    /// asks for with `zw`.
    wrap: bool = true,
    /// Side by side: the old file in the left column, the new in the right,
    /// with a divider between them, against the one-column flow view. The
    /// rows are a different list under it, so this is a fact about `rows` and
    /// not only about how they are drawn.
    split: bool = false,
    /// `[diff] highlight`: how far a change's colour reaches.
    /// Which column of a split row the cursor is in. The body marks that one
    /// and leaves the other alone: a cursor or a selection drawn on both would
    /// say the reader is pointing at two lines at once.
    side: rows_mod.Side = .new,
    highlight: Highlight = .line,
    /// The `?` popup. Non-null floats a box over the body.
    help: ?HelpView = null,
    /// The `F` popup, the same way. Only one overlay is ever open, because
    /// each is its own mode.
    files: ?FilesView = null,
    /// The compose box, floating over the body while a message is written.
    compose: ?ComposeView = null,
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
    /// True while a file outside the review is being read, so the status row
    /// can say the counters mean nothing here.
    preview: bool = false,
    /// New-file line numbers carrying a note, and which kind, for the gutter.
    /// A slice built per frame: the body asks per row and a scan of a handful
    /// of notes beats a map that has to be kept in step with the store.
    notes: []const CommentMark = &.{},
    /// Changed files that `[review] ignore` kept out of this review. Shown in
    /// the mode row, because a file hidden without a word is a file the reader
    /// does not know they have not looked at.
    hidden: u32 = 0,
    /// Set when the last re-diff hit a file changing underneath it. Shown
    /// rather than swallowed: a stale frame the user knows about beats a
    /// blended one they do not.
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

    /// How this screen counts a grapheme's columns. Handed to `ui/wrap.zig` so
    /// the rows it measures are the rows vaxis draws.
    pub fn method(self: Frame) wrap.Method {
        return self.win.screen.width_method;
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

    /// `put` with an OSC 8 hyperlink behind the text. A terminal without them
    /// draws the text and ignores the escape, and one behind a tmux older
    /// than 3.4 has it stripped on the way through, so no caller has to ask
    /// first: the worst case is the plain text that would have been drawn
    /// anyway. It occupies no columns, so it cannot change a layout.
    pub fn putLink(
        self: Frame,
        row: u16,
        col: u16,
        text: []const u8,
        style: vaxis.Style,
        uri: []const u8,
    ) void {
        _ = self.win.printSegment(
            .{ .text = text, .style = style, .link = .{ .uri = uri } },
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
    /// rather than the defaults.
    entries: []const keytext.HelpEntry,
    query: []const u8 = "",
    /// Selected row, an index into `entries` after filtering.
    index: usize = 0,
    /// The popup's own keys, drawn along its bottom border. Generated like
    /// every other row, so remapping the navigation relabels the box.
    keys: []const keytext.HelpEntry = &.{},
    /// The tab the list is narrowed to, drawn as a strip let into the top
    /// border. Null while a filter is being typed, which is what says the
    /// filter is searching every tab rather than this one.
    group: ?keymap.Group = null,
};

/// One row of the `F` overlay: a changed file, as the reader picks it out.
pub const FileEntry = struct {
    path: []const u8,
    added: u32,
    removed: u32,
    /// What happened to the file. Modified draws no mark: it is the majority,
    /// and what a reader looks for is the file that appeared, vanished, moved
    /// or cannot be read at all.
    status: diff.Status = .modified,
    /// The file the review is currently on, marked so the list opens showing
    /// the reader where they already are rather than at an arbitrary top.
    current: bool = false,
    /// Whether this file is part of the review. False for the ones `@` adds
    /// from the rest of the project: they have a path and nothing else, and
    /// `+0 -0` beside them would be a fact about a file that did not change
    /// dressed up as a change.
    in_review: bool = true,
    /// The row is not a file, so it gets no filetype icon: `working tree` and
    /// `baseline` are not paths, and an "unknown filetype" glyph beside them
    /// is the widget asserting something about a row that has no filetype.
    plain: bool = false,
    /// Where the icon comes from, when the label is not itself a path.
    ///
    /// A turn's row is composed - `5   docs/perf.md  1m ago  3 files` - so
    /// looking up its filetype would read the extension of the whole sentence
    /// and find `files`. The row still names a real file and the icon is still
    /// worth having: it is the same argument the file list makes, that shape
    /// and hue together find the one you want without reading a name.
    icon_path: []const u8 = "",
    /// A number this row *is*, as against a number that appears in its label.
    ///
    /// The turn list's rows carry an age and two counts, so fuzzy-matching `2`
    /// against the whole label found `27m`, `+23` and `-2` - seven rows out of
    /// eight, which is not a filter. A digits-only query means this instead.
    key: ?u32 = null,
};

/// Everything the `F` overlay draws. Its own view for the same reason
/// `HelpView` is: it floats over the body and has to be drawable when there is
/// no body at all.
pub const FilesView = struct {
    entries: []const FileEntry,
    /// Extra keys for this list, drawn in its footer beside the shared ones.
    extra_keys: []const keytext.HelpEntry = &.{},
    /// What the box is listing, drawn in its title. The same widget shows the
    /// changed files, every file in the project, and every comment; saying
    /// which spares the reader working it out from the rows.
    title: []const u8 = " files ",
    query: []const u8 = "",
    /// Selected row, an index into `entries` after filtering.
    index: usize = 0,
    /// The popup's own keys, along its bottom border.
    keys: []const keytext.HelpEntry = &.{},
    layout: ?*HelpLayout = null,
    /// The whole change, drawn at the right end of the top border. The rows
    /// each say what one file cost; a reader deciding whether to start here
    /// wants what all of them cost, and that number is nowhere else on screen
    /// while the overlay is covering the status row.
    ///
    /// Null on the lists where it would be a lie: every file in the project,
    /// where most rows changed nothing, and the comments.
    totals: ?Totals = null,
};

/// Added and removed lines across every row that is part of the review.
pub const Totals = struct { added: u32, removed: u32 };

/// The compose box: the message being written, and the preset list when it is
/// open over it. Its own view for the same reason `HelpView` is - it floats
/// over the body and the body has no say in it.
pub const ComposeView = struct {
    /// The whole message, wrapped by the box rather than by the caller.
    text: []const u8,
    /// Byte offset of the caret within `text`, for placing the terminal
    /// cursor on the character it sits before.
    cursor: usize = 0,
    /// True while the text contains a newline, so the footer can say that the
    /// payload will be joined into one line before it is sent. Said before it
    /// happens rather than discovered afterwards in the agent's input box.
    joins: bool = false,
    /// `Ctrl-i`: names and their questions, and which one is selected. Null
    /// when the box has the keyboard.
    presets: []const PresetEntry = &.{},
    selected: ?usize = null,
    /// Whether Enter sends to the agent or copies. Only the footer cares.
    to_agent: bool = true,
    /// Whether Enter saves a comment rather than sending a message. The
    /// footer said "send" for a comment because it was inferred from the
    /// delivery, which an edit forgot to set - so the box promised the wrong
    /// destination. This is the fact itself rather than a proxy for it.
    saves: bool = false,
    /// The keymap, so the footer names the keys the reader actually has. The
    /// box's feature keys are `Modes.compose_only` bindings like everything
    /// else; only its motions are fixed.
    bindings: []const keymap.Binding = &.{},
    /// Where the box sits: `[ui] compose`.
    at: Placement = .bottom,
    /// Which half of the box has the keyboard, drawn in its title. A modal
    /// box that does not say which mode it is in is a box that eats keystrokes.
    normal: bool = false,
    /// What the box is for, drawn in its title: `compose`, or `note a.zig:47`.
    /// A note's line lives here rather than in the text, because the store
    /// already knows it - typing it into the body would put it in the review
    /// file twice.
    what: []const u8 = "compose",
};

pub const Placement = enum { bottom, top, centre };

/// How far a change's colour reaches. `[diff] highlight`.
///
/// `line` washes the whole row, and is the default: it is what lets the mark
/// be one thin bar instead of a sign and a bar, and side by side needs it -
/// two columns of near-identical text with a tint on one of them is a far
/// quicker read than comparing them character by character. `gutter` keeps the
/// colour in the mark and leaves the code to the syntax highlighting.
pub const Highlight = enum { gutter, line };

/// One note, as the gutter needs it.
pub const CommentMark = struct {
    line: u32,
    /// What it says, drawn under the line. The gutter marker says a note is
    /// there; this is the note.
    body: []const u8 = "",
    /// Drawn differently, because "I still mean this" and "the code moved out
    /// from under it" are different things to know at a glance.
    state: enum { open, sent, stale },
};

pub const PresetEntry = struct {
    name: []const u8,
    text: []const u8,
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
