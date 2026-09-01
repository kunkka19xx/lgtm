// SPDX-License-Identifier: Apache-2.0
//
// What a key means. The reader's position - which file, which row, which mode
// - and the command dispatch that moves it.
//
// Three things it deliberately is not, each of which used to live here and now
// has a file of its own. `ui/loop.zig` owns the terminal, the threads and the
// frame. `ui/review.zig` owns one diff generation: git, the buffers it is an
// overlay on, the ids and the lexer cache. `ui/help.zig` owns the `?` overlay's
// filter and selection. The split is what leaves this file testable with no
// terminal at all - which every test below is.
//
// The frame arena stays here because the state is what fills it: it holds the
// strings a single frame draws and is reset *after* render and flush, because
// vaxis cells reference that text rather than copying it (ARCHITECTURE.md 4).

const std = @import("std");
const Allocator = std.mem.Allocator;

const diff = @import("../core/diff.zig");
const event = @import("../core/event.zig");
const hunk = @import("../core/hunk.zig");
const metrics = @import("../io/metrics.zig");

const template = @import("../bridge/template.zig");

const config = @import("../config.zig");
const devicon = @import("devicon.zig");
const files_mod = @import("files.zig");
const help_mod = @import("help.zig");
const keymap = @import("keymap.zig");
const keytext = @import("keytext.zig");
const anim = @import("anim.zig");
const motion = @import("motion.zig");
const prompt_mod = @import("prompt.zig");
const render = @import("render.zig");
const review_mod = @import("review.zig");
const rows_mod = @import("rows.zig");
const search = @import("search.zig");
const theme_mod = @import("theme.zig");
const wrap_mod = @import("wrap.zig");

/// A one-line message on the mode row: a search that found nothing, a command
/// that is not one, an editor that would not start. Fixed capacity and cleared
/// by the next keystroke, which is the whole of its lifecycle - anything that
/// needs to persist is state, not a notice.
pub const Notice = struct {
    buf: [192]u8 = undefined,
    len: usize = 0,

    pub fn set(self: *Notice, comptime fmt: []const u8, args: anytype) void {
        const out = std.fmt.bufPrint(&self.buf, fmt, args) catch blk: {
            // A message too long to format is still worth showing truncated:
            // `bufPrint` leaves what it managed to write in the buffer.
            break :blk self.buf[0..self.buf.len];
        };
        self.len = out.len;
    }

    pub fn clear(self: *Notice) void {
        self.len = 0;
    }

    pub fn text(self: *const Notice) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Whether a rows rebuild starts the reader over or keeps their place. A file
/// change under the cursor should not send you back to the top of the file,
/// and moving to a different file should not leave you halfway down it.
///
/// `line` is the one a re-diff wants: it keeps the *line the reader was
/// reading*, re-anchored through `core/anchor.zig`, and falls back to `row`
/// when the line cannot be placed. `row` keeps a row index, which means the
/// same thing only until something above it changes.
const Keep = enum { reset, row, line };

pub const App = struct {
    gpa: Allocator,
    io: std.Io,

    /// One diff generation and everything derived from it. The reader's
    /// position - which file, which row - is here; what changed is there.
    review: review_mod.Review,
    /// The strings one frame draws. Reset *after* render and flush, never
    /// before: vaxis cells reference this text rather than copying it
    /// (ARCHITECTURE.md 5c).
    frame_arena: std.heap.ArenaAllocator,

    queue: *event.Queue,
    km: keymap.Keymap = .{},
    theme: theme_mod.Theme = theme_mod.default,
    glyphs: theme_mod.Glyphs = theme_mod.Glyphs.unicode,

    /// The current file, laid out. Rebuilt whenever the file or the diff
    /// changes, and owned by the review's arena.
    rows: rows_mod.Rows = rows_mod.Rows.empty,
    fn_names: [][]const u8 = &.{},
    /// Previous generation's hunks for the current file, so ids carry across.
    prev_hunks: []hunk.Hunk = &.{},

    file_index: u32 = 0,
    cursor: u32 = 0,
    scroll: u32 = 0,
    quit: bool = false,

    /// Byte offset of the cursor within its line's text, always on a grapheme
    /// boundary. Zero on a row that is chrome, which has no text to be in.
    col: u32 = 0,
    /// The column the reader last asked for, kept across `j` and `k` the way
    /// vim keeps `curswant`: stepping down through a short line and back onto
    /// a long one returns to where the eye was, not to the short line's end.
    /// `$` parks it at the maximum, which is what makes the end sticky.
    want_col: u32 = 0,

    mode: event.Mode = .normal,
    /// Row the visual selection started on. Meaningless outside `.visual`.
    anchor: u32 = 0,
    /// Its column, for a charwise selection. Meaningless for a linewise one.
    anchor_col: u32 = 0,
    /// Which of the two visual modes is running. One `Mode` with a kind rather
    /// than two: every motion is live in both, and a second mode would mean
    /// spelling that out on every binding in the table.
    visual_kind: render.Selection.Kind = .line,
    /// An `f`/`t`/`F`/`T` waiting for the character to search for. The next key
    /// is data, not a command - the same rule the prompt follows, and why this
    /// is checked before the keymap ever sees it.
    pending_find: ?motion.Find = null,
    /// The last completed one, which is what `;` and `,` repeat.
    last_find: ?motion.Find = null,
    /// The mode to return to when the prompt closes, so `/` from a selection
    /// does not silently drop it.
    prompt_return: event.Mode = .normal,
    /// The `?` overlay: filter, selection and the grid the last frame drew.
    /// See `ui/help.zig` - the rules it follows are its own.
    help: help_mod.Help = .{},
    /// The `F` overlay, which follows the same rules over a different list.
    /// Named for the command that opens it, because `files()` is already the
    /// review's own list and the two are one keystroke apart in the reader's
    /// head as it is.
    file_list: files_mod.Files = .{},
    /// Config-owned behaviour; see `Nav`.
    nav: Nav = .{},
    prompt: prompt_mod.Prompt = .{},
    finder: search.State = .{},
    notice: Notice = .{},
    /// The viewport catching up with where it has settled, in screen rows.
    /// Zero except while a jump is in flight; see `ui/anim.zig`.
    scroll_anim: anim.Scroll = .{},
    /// The cursor block travelling to where it belongs. Every motion moves it,
    /// which is the difference between this and `scroll_anim`: the viewport
    /// only animates for a jump, because it moves under a step as a side
    /// effect, but the cursor is what the reader is actually following.
    cursor_anim: anim.Cursor = .{},
    /// `Tab`: chrome hidden, the body gets the whole pane.
    zen: bool = false,
    /// Soft wrap, from `ui.wrap` and toggled by `zw`. On, a line wider than
    /// the pane continues on the next screen row; off, it is cut at the edge.
    wrap: bool = true,
    /// The pane width, from the last resize the loop reported. Scrolling has
    /// to count screen rows, and a wrapped row is more than one of them, so
    /// the state that decides where the cursor goes needs to know how wide
    /// the pane it is going onto is. Never read for anything else.
    cols: u16 = 80,
    /// How the screen counts a grapheme's columns; see `ui/wrap.zig`. Set by
    /// the loop from the terminal's answer, because vaxis only knows it after
    /// the capability query comes back.
    width_method: wrap_mod.Method = .unicode,
    /// Set by `e`. The run loop owns the terminal, so it - not `run(cmd)` -
    /// is what can hand it to a child process.
    want_editor: bool = false,
    /// Every outgoing string is a template (FEATURES.md 4.5). Config-owned in
    /// v0.2; the defaults are the internal table until then.
    templates: template.Table = .{},
    /// The composed payload, waiting for the loop to deliver it. Session
    /// allocated and reused: it must outlive the frame arena, which is reset
    /// under it, and it is one short line.
    outgoing: std.ArrayList(u8) = .empty,
    /// Set by the bridge commands, for the same reason `want_editor` is: the
    /// loop owns the terminal the clipboard sequence goes to and the process
    /// the tmux send spawns.
    want_send: ?Delivery = null,

    pub fn init(gpa: Allocator, io: std.Io, queue: *event.Queue) App {
        return .{
            .gpa = gpa,
            .io = io,
            .queue = queue,
            .review = .init(gpa, io),
            .frame_arena = .init(gpa),
        };
    }

    pub fn deinit(self: *App) void {
        self.outgoing.deinit(self.gpa);
        self.review.deinit();
        self.frame_arena.deinit();
        self.* = undefined;
    }

    fn files(self: *App) []diff.FileDiff {
        return self.review.files();
    }

    fn current(self: *App) ?*diff.FileDiff {
        return self.review.fileAt(self.file_index);
    }

    /// A new generation, and the reader put back where they were. The work
    /// is `review.regenerate`; what is left here is the part that is about a
    /// reader rather than a diff.
    pub fn rediff(self: *App) !void {
        const span = metrics.span(.diff_parse);
        defer span.end();

        self.file_index = try self.review.regenerate(.{
            .path = if (self.current()) |f| f.path() else null,
            .hunks = self.prev_hunks,
            .line = self.cursorLine(),
        });
        self.rows = rows_mod.Rows.empty;
        self.fn_names = &.{};
        self.prev_hunks = &.{};

        // The agent writing a file must not send the reader back to the top of
        // it, nor leave them on a row that now means something else. The line
        // is re-anchored through `core/anchor.zig`; the row index is only the
        // fallback for a line that is genuinely gone.
        try self.rebuildRows(.line);
    }

    fn rebuildRows(self: *App, keep: Keep) !void {
        const f = self.current() orelse {
            self.rows = rows_mod.Rows.empty;
            self.fn_names = &.{};
            self.cursor = 0;
            self.scroll = 0;
            return;
        };

        self.rows = try rows_mod.build(self.review.allocator(), f);
        self.prev_hunks = f.hunks;
        self.fn_names = try self.review.enclosingNames(f);
        var placed = false;
        if (keep == .line) {
            if (try self.review.reanchorLine(f.path())) |ln| {
                if (self.rowForFileLine(f, ln)) |r| {
                    self.cursor = r;
                    placed = true;
                }
            }
        }

        if (!placed) switch (keep) {
            .reset => {
                self.cursor = self.rows.firstLineRow();
                self.scroll = 0;
            },
            // A line that could not be placed keeps the row it had, which is
            // the old behaviour and still the least surprising answer.
            .row, .line => {
                self.cursor = @min(self.cursor, self.rows.len() -| 1);
                // Never leave the cursor on chrome. `moveTo` cannot put it
                // there, but keeping a row index across a rebuild can - and
                // the very first diff is the worst case, where there is no
                // previous position at all and row 0 is the hunk header.
                if (self.cursor < self.rows.firstLineRow()) {
                    self.cursor = self.rows.firstLineRow();
                }
            },
        };
        // The row can survive a re-diff while the text on it becomes shorter,
        // or becomes something else entirely.
        self.clampCol();

        // The rows the anchor pointed at are gone, so the selection it
        // described is gone with them. Silently keeping the range would select
        // whatever now happens to sit at those indexes.
        if (self.mode == .visual) self.leaveVisual();
    }

    /// The working-tree line under the cursor, 1-based, or 0 when there is
    /// none: chrome has no line, and a deleted line exists only in the old
    /// file, so neither has anything to carry into the next generation.
    fn cursorLine(self: *App) u32 {
        const f = self.current() orelse return 0;
        const li = self.rows.lineAt(self.cursor) orelse return 0;
        if (li >= f.lines.new_no.len) return 0;
        return f.lines.new_no[li];
    }

    /// The row drawing working-tree line `ln` of `f`, if the diff shows it.
    /// A re-anchored line often lands in unchanged context that this
    /// generation no longer renders, and that is not a failure: the caller
    /// keeps the row it had.
    fn rowForFileLine(self: *const App, f: *const diff.FileDiff, ln: u32) ?u32 {
        for (f.lines.new_no, 0..) |n, li| {
            if (n == ln) return self.rows.rowForLine(@intCast(li));
        }
        return null;
    }

    pub fn view(self: *App, body: u16) ?render.View {
        const f = self.current() orelse return null;
        const bufs = self.review.buffersFor(f.path());
        const drawn = self.drawnTop(body);
        return .{
            .file = f,
            .rows = self.rows,
            .file_index = self.file_index,
            .file_count = @intCast(self.files().len),
            .cursor = self.cursor,
            .cursor_drawn = self.drawnCursor(body),
            .cursor_cell = if (self.cursorCell(body)) |t| self.cursor_anim.cell(t) else null,
            .scroll = drawn.row,
            .skip = drawn.skip,
            .col = self.col,
            .fn_names = self.fn_names,
            .total_hunks = self.review.totalHunks(),
            .hunk_ordinal = self.hunkOrdinal(),
            .work = bufs.work,
            .head = bufs.head,
            .work_runs = self.review.runsFor(f.path(), f.new_blob, bufs.work),
            .head_runs = self.review.runsFor(f.path(), f.old_blob, bufs.head),
            .torn = self.review.torn,
            .mode = self.mode,
            .zen = self.zen,
            .wrap = self.wrap,
            .selection = self.selection(),
            .prompt = if (self.prompt.open) .{
                .prefix = self.prompt.kind.prefix(),
                .text = self.prompt.text(),
            } else null,
            .notice = self.notice.text(),
            .query = self.finder.query(),
        };
    }

    /// 1-based position of the cursor's hunk across the whole review.
    fn hunkOrdinal(self: *App) u32 {
        const local = self.rows.hunkAt(self.cursor) orelse return 0;
        return self.review.hunksBefore(self.file_index) + local + 1;
    }

    // -- commands ------------------------------------------------------------

    pub fn run(self: *App, cmd: keymap.Command, body: u16) !void {
        const was_at = self.scroll;
        const was_in = self.file_index;
        // Anything that is not itself a jump arrives at once: an animation the
        // reader has already moved past is latency, not motion. Another jump
        // is left running, because `anim.Scroll.add` makes the two travel
        // together rather than queueing - which is what holding `<C-d>` is.
        if (!cmd.jumps()) self.settleScroll();
        switch (cmd) {
            .quit => self.quit = true,
            .line_down => self.moveTo(self.cursor +| 1),
            .line_up => self.moveTo(self.cursor -| 1),
            .page_down => self.page(1, body),
            .page_up => self.page(-1, body),
            // The first *line*, which is what the key says: row 0 is the hunk
            // header, and a cursor parked on chrome points at nothing.
            .top => self.moveTo(self.rows.firstLineRow()),
            .bottom => self.moveTo(self.rows.len() -| 1),

            // Within the line. Each sets both columns: this is the reader
            // saying where they want to be, which is what `j` and `k` then
            // try to honour on the next line.
            .char_left => if (motion.charLeft(self.cursorText(), self.col)) |at| self.setCol(at),
            .char_right => if (motion.charRight(self.cursorText(), self.col)) |at| self.setCol(at),
            .word_next => self.stepWord(true, .word),
            .word_prev => self.stepWord(false, .word),
            .word_end => self.stepWordEnd(.word),
            // The same three over WORDs: whitespace to whitespace, so a path
            // or a whole call is one step rather than five.
            .big_word_next => self.stepWord(true, .big),
            .big_word_prev => self.stepWord(false, .big),
            .big_word_end => self.stepWordEnd(.big),
            .line_start => self.setCol(0),
            // The maximum rather than the offset, so the end stays sticky
            // down a column of ragged lines - vim's `$`, not "column 47".
            .line_end => {
                self.col = motion.lineEnd(self.cursorText());
                self.want_col = std.math.maxInt(u32);
            },
            .first_non_blank => self.setCol(motion.firstNonBlank(self.cursorText())),

            // Each of these needs one more keystroke before it can move.
            .find_char => self.pending_find = .{ .target = 0, .forward = true, .till = false },
            .till_char => self.pending_find = .{ .target = 0, .forward = true, .till = true },
            .find_char_back => self.pending_find = .{ .target = 0, .forward = false, .till = false },
            .till_char_back => self.pending_find = .{ .target = 0, .forward = false, .till = true },
            .find_repeat => if (self.last_find) |f| self.applyFind(f),
            .find_reverse => if (self.last_find) |f| self.applyFind(f.flip()),
            .next_hunk => try self.stepHunk(1),
            .prev_hunk => try self.stepHunk(-1),
            .next_file => try self.stepFile(1),
            .prev_file => try self.stepFile(-1),
            .center => self.centerCursor(body),
            .refresh => try self.rediff(),
            .visual_toggle => self.toggleVisual(.line),
            .visual_char_toggle => self.toggleVisual(.char),
            .visual_cancel => self.leaveVisual(),
            .search_forward => self.openPrompt(.search_forward),
            .search_next => try self.searchStep(self.finder.dir),
            .search_prev => try self.searchStep(self.finder.dir.flip()),
            .command_line => self.openPrompt(.command),
            // The run loop owns the terminal and is the only thing that can
            // lend it out, so this is a request rather than an action.
            .open_editor => self.want_editor = true,
            .send_ref => try self.compose(.send, .ref),
            .copy_ref => try self.compose(.copy, .ref),
            .copy_ref_lines => try self.compose(.copy, .ref_lines),
            .ask_why => try self.compose(.send, .{ .ask = self.templates.ask_why }),
            .ask_revert => try self.compose(.send, .{ .ask = self.templates.ask_revert }),
            .ask_test => try self.compose(.send, .{ .ask = self.templates.ask_test }),
            .ask_explain => try self.compose(.send, .{ .ask = self.templates.ask_explain }),
            // Both relay out every row under the cursor, so it is placed
            // rather than walked: zen changes the body's height and wrap
            // changes what every line is worth in screen rows. Travelling
            // across a screen that no longer exists draws a path through
            // nothing (`ui/anim.zig`).
            .toggle_zen => {
                self.zen = !self.zen;
                self.placeCursor();
            },
            .toggle_wrap => {
                self.wrap = !self.wrap;
                self.placeCursor();
                // Nothing else on screen says which it is until a line is long
                // enough to show it, and by then the reader has stopped
                // wondering whether the key did anything.
                self.notice.set("soft wrap {s}", .{if (self.wrap) "on" else "off"});
            },
            .help => self.toggleHelp(),
            .file_list => self.toggleFiles(),
            // One set of list keys, two overlays. Which one they move is the
            // mode, because only one of them can be open.
            .list_down => self.moveList(1),
            .list_up => self.moveList(-1),
            .list_right => self.pageList(1),
            .list_left => self.pageList(-1),
        }
        self.clampScroll(body);
        // A jump inside one file is motion the eye can follow, so the viewport
        // catches up rather than teleporting.
        //
        // Two things are deliberately not animated. Across files, because the
        // rows underneath are different rows and sliding between two unrelated
        // screens is an animation of nothing. And a *step* - `j`, `k`, a word
        // motion - because the view only moved there as a consequence of the
        // cursor reaching the edge, and with soft wrap one `j` can be three
        // screen rows: animating that starts a fresh animation on every
        // keystroke, and a held `j` spends its life cancelling the last one.
        if (cmd.jumps() and self.file_index == was_in) self.animateFrom(was_at, body);
        // Another file is another screen: the cursor has nowhere to travel
        // from, so it is placed rather than moved.
        if (self.file_index != was_in) self.placeCursor();
    }

    // -- visual select -------------------------------------------------------

    /// `V` and `v`. Pressing the kind you are already in leaves; pressing the
    /// other switches, which is what vim does and what stops `v` from being a
    /// dead key inside a linewise selection.
    fn toggleVisual(self: *App, kind: render.Selection.Kind) void {
        if (self.mode == .visual) {
            if (self.visual_kind == kind) return self.leaveVisual();
            self.visual_kind = kind;
            return;
        }
        self.mode = .visual;
        self.visual_kind = kind;
        self.anchor = self.cursor;
        self.anchor_col = self.col;
    }

    fn leaveVisual(self: *App) void {
        self.mode = .normal;
        self.anchor = self.cursor;
        self.anchor_col = self.col;
    }

    /// The selected row range, low to high inclusive, or null outside visual
    /// mode. Normalised here rather than at each use, because a selection made
    /// upwards has the anchor below the cursor and every consumer would
    /// otherwise have to remember that.
    pub fn selection(self: *App) ?render.Selection {
        if (self.mode != .visual) return null;
        const lo = @min(self.anchor, self.cursor);
        const hi = @max(self.anchor, self.cursor);
        if (self.visual_kind == .line) return .{ .lo = lo, .hi = hi };

        // Charwise. Which end holds which column depends on which way the
        // selection was made, and on the same row it is the columns rather
        // than the rows that say.
        const backwards = self.cursor < self.anchor or
            (self.cursor == self.anchor and self.col < self.anchor_col);
        const lo_col = if (backwards) self.col else self.anchor_col;
        const hi_col = if (backwards) self.anchor_col else self.col;

        // Vim's charwise selection includes the character under the cursor;
        // the renderer wants a half-open range, so the conversion happens
        // once, here.
        const end_text = self.textOfRow(hi);
        const end = motion.charRight(end_text, hi_col) orelse @as(u32, @intCast(end_text.len));
        return .{ .lo = lo, .hi = hi, .kind = .char, .lo_col = lo_col, .hi_col = end };
    }

    // -- prompt and search ---------------------------------------------------

    fn openPrompt(self: *App, kind: prompt_mod.Kind) void {
        self.prompt_return = self.mode;
        self.prompt.start(kind);
        self.mode = .command;
        self.notice.clear();
    }

    /// `?` from normal or visual opens the overlay; `?`, `Esc` or `q` from
    /// inside closes it. One command rather than two, for the same reason
    /// `visual_toggle` is one: the key that opens it also closes it. While
    /// `.help` is the mode, every other binding is invisible to the matcher,
    /// so nothing fires behind the overlay.
    fn toggleHelp(self: *App) void {
        if (self.mode == .help) {
            self.help.close();
            self.mode = self.help.from;
        } else {
            self.help.open(self.mode);
            self.mode = .help;
        }
    }

    /// Keys inside the popup are filter text, not commands - the same rule the
    /// bottom-line prompt follows, and why `help` is a mode the keymap ignores.
    /// `F` opens the file list; `F`, `Esc` or backspacing out of an empty
    /// filter closes it. One command for both, the way `?` and `V` are one.
    fn toggleFiles(self: *App) void {
        if (self.mode == .finder) {
            self.file_list.close();
            self.mode = .normal;
        } else {
            self.file_list.open(files_mod.rowOf(self.review.files(), self.file_index));
            self.mode = .finder;
        }
    }

    fn moveList(self: *App, delta: i32) void {
        switch (self.mode) {
            .help => self.help.move(self.km.bindings, delta),
            .finder => self.file_list.move(self.review.files(), delta),
            else => {},
        }
    }

    fn pageList(self: *App, delta: i32) void {
        switch (self.mode) {
            .help => self.help.moveGroup(delta),
            .finder => self.file_list.movePage(self.review.files(), delta),
            else => {},
        }
    }

    /// Keys inside the file list are filter text, exactly as in the `?`
    /// overlay. `Enter` jumps to the selected file, which is the whole point
    /// of the list and the one thing it does that `?` does not.
    fn feedFiles(self: *App, key: event.Key, body: u16) !void {
        switch (self.km.feed(key, .finder)) {
            .command => |cmd| return self.run(cmd, body),
            .pending, .none => {},
        }
        switch (self.file_list.feed(key)) {
            .stay => {},
            .close => self.toggleFiles(),
            .open => {
                if (self.file_list.selected(self.review.files())) |i| {
                    if (i != self.file_index) {
                        self.file_index = i;
                        try self.rebuildRows(.reset);
                    }
                }
                self.toggleFiles();
                self.clampScroll(body);
            },
        }
    }

    fn feedHelp(self: *App, key: event.Key, body: u16) !void {
        // Navigation is an action and stays in the keymap, so it is remappable
        // like everything else. Only bindings live in `.help` can match here,
        // and they are all single chords, so a miss never strands the next key.
        switch (self.km.feed(key, .help)) {
            .command => |cmd| return self.run(cmd, body),
            .pending, .none => {},
        }
        switch (self.help.feed(key)) {
            .stay => {},
            .close => self.toggleHelp(),
        }
    }

    fn closePrompt(self: *App) void {
        self.prompt.close();
        self.mode = self.prompt_return;
    }

    /// Text entry, which is why it does not go through the keymap: inside a
    /// prompt `j` is the letter j, not a motion (see prompt.zig).
    fn feedPrompt(self: *App, key: event.Key, body: u16) !void {
        switch (self.prompt.feed(key)) {
            .typing => {},
            .cancel => self.closePrompt(),
            .submit => {
                // Copied out before closing: the prompt's buffer is about to
                // be declared empty, and submitting can re-enter it.
                var buf: [prompt_mod.max_bytes]u8 = undefined;
                const text = self.prompt.text();
                @memcpy(buf[0..text.len], text);
                const kind = self.prompt.kind;
                self.closePrompt();
                try self.submitPrompt(kind, buf[0..text.len]);
                self.clampScroll(body);
            },
        }
    }

    fn submitPrompt(self: *App, kind: prompt_mod.Kind, line: []const u8) !void {
        switch (kind) {
            .search_forward => {
                // Bare Enter repeats the last query, as in vim. Every search
                // starts forward; `N` is what runs it backwards
                // (FEATURES.md 4.4).
                if (line.len != 0) self.finder.set(line, .forward);
                try self.searchStep(if (line.len == 0) self.finder.dir else .forward);
            },
            .command => self.submitCommand(line),
            // The popup's filter is its own `Prompt`, fed by `feedHelp`, so it
            // never arrives here.
            .help_filter => {},
        }
    }

    /// `:q` and nothing else. SPEC.md 6.2 rules out a command mode in v1
    /// except this one, so an unknown command says so rather than being
    /// quietly ignored - which would read as a dropped keystroke.
    fn submitCommand(self: *App, line: []const u8) void {
        const cmd = std.mem.trim(u8, line, " ");
        if (std.mem.eql(u8, cmd, "q") or std.mem.eql(u8, cmd, "q!") or
            std.mem.eql(u8, cmd, "qa") or std.mem.eql(u8, cmd, "qa!"))
        {
            self.quit = true;
            return;
        }
        self.notice.set("not an editor command: :{s}", .{cmd});
    }

    /// One search step across the whole review, not just the current file: a
    /// reviewer who types `/token` means anywhere in the change. Files other
    /// than the current one have no rows built, so the scan runs over their
    /// `DiffLines` and only the file that hits gets laid out.
    fn searchStep(self: *App, dir: search.Direction) !void {
        const q = self.finder.query();
        if (q.len == 0) {
            self.notice.set("no previous search", .{});
            return;
        }
        const fs = self.files();
        if (fs.len == 0) return;

        self.finder.wrapped = false;
        self.finder.failed = false;

        const start_file = self.file_index;
        var fi: u32 = start_file;
        var from: ?u32 = self.rows.lineAt(self.cursor);
        var wrapped = false;

        var step: usize = 0;
        while (step <= fs.len) : (step += 1) {
            if (search.findLine(fs[fi].lines, from, dir, q)) |hit| {
                if (fi != self.file_index) {
                    self.file_index = fi;
                    try self.rebuildRows(.reset);
                }
                if (self.rows.rowForLine(hit.line)) |row| {
                    self.moveTo(row);
                    // After `moveTo`, which sets the column from `want_col`:
                    // the match is where the reader is going, so it becomes
                    // the desired column too, the way vim's `n` does. Without
                    // this the cursor lands on the right line at the wrong
                    // end of it, and on a long line that reads as a miss.
                    self.setCol(motion.clamp(self.cursorText(), hit.col));
                }
                self.finder.wrapped = wrapped;
                if (wrapped) self.notice.set("search wrapped", .{});
                return;
            }
            // Step to the neighbouring file, noting when that crossed the end
            // of the review - which is the only thing that counts as a wrap.
            const next = wrapIndex(@as(i64, @intCast(fi)) + dir.delta(), fs.len);
            fi = next.index;
            wrapped = wrapped or next.wrapped;
            // A file entered from outside has no cursor to start after.
            from = null;
        }

        self.finder.failed = true;
        self.notice.set("pattern not found: {s}", .{q});
    }

    // -- the bridge ----------------------------------------------------------

    /// Where a composed payload is going. The loop performs it; this is the
    /// request, because only the loop owns the terminal and the subprocess.
    pub const Delivery = enum { send, copy };

    /// What to compose. `ask` carries its own template rather than an enum the
    /// dispatch would have to translate back into one.
    const What = union(enum) {
        ref,
        ref_lines,
        ask: []const u8,
    };

    /// A reference, before a template turns it into text.
    ///
    /// Every field resolves against the *new* file (SPEC.md 6.3): a line
    /// number from the HEAD side means nothing to an agent looking at what it
    /// just wrote.
    pub const Ref = struct {
        change_id: hunk.ChangeId = hunk.no_id,
        path: []const u8,
        /// 1-based line in the new file, or 0 when there is none to point at.
        line: u32 = 0,
        /// End of a range, or 0 when the reference is a single line.
        end: u32 = 0,
        /// The cursor covers only lines that exist in HEAD and not on disk.
        /// The reference becomes the enclosing hunk, and says why.
        deleted: bool = false,
        /// The text a charwise selection covers, when it is inside one line.
        /// Empty otherwise - across two lines it would have to carry the
        /// newline between them, and a newline is what hard rule 1 forbids.
        span: []const u8 = "",
    };

    /// What the cursor, or the selection, is pointing at.
    pub fn refAt(self: *App) ?Ref {
        const f = self.current() orelse return null;
        const path = f.path();

        const hunk_index = self.rows.hunkAt(self.cursor);
        const id = if (hunk_index) |h|
            (if (h < f.hunks.len) f.hunks[h].id else hunk.no_id)
        else
            hunk.no_id;

        // A selection resolves to the new-file lines it covers; without one
        // the range is the cursor row alone. Rows that are chrome, and lines
        // that exist only in HEAD, contribute nothing either way.
        const sel = self.selection();
        const lo_row = if (sel) |s| s.lo else self.cursor;
        const hi_row = if (sel) |s| s.hi else self.cursor;

        var first: u32 = 0;
        var last: u32 = 0;
        var row = lo_row;
        while (row <= hi_row) : (row += 1) {
            const li = self.rows.lineAt(row) orelse continue;
            if (li >= f.lines.len()) continue;
            const n = f.lines.new_no[li];
            if (n == 0) continue;
            if (first == 0) first = n;
            last = n;
        }
        if (first != 0) {
            return .{
                .change_id = id,
                .path = path,
                .line = first,
                .end = if (last > first) last else 0,
                .span = self.spanText(sel),
            };
        }

        // Nothing under the cursor survives in the new file. The enclosing
        // hunk is where the deletion happened, which is the closest thing to
        // a place the agent can look.
        if (hunk_index) |h| {
            if (h < f.hunks.len) return .{
                .change_id = id,
                .path = path,
                .line = f.hunks[h].new_start,
                .deleted = true,
            };
        }
        return .{ .change_id = id, .path = path };
    }

    /// The words a charwise selection covers, trimmed, or empty when there is
    /// no such thing to point at. Only within one line: the text of a
    /// selection spanning two would contain the newline between them.
    fn spanText(self: *App, sel: ?render.Selection) []const u8 {
        const s = sel orelse return "";
        if (s.kind != .char or s.lo != s.hi) return "";
        const text = self.textOfRow(s.lo);
        const lo = @min(s.lo_col, text.len);
        const hi = @min(s.hi_col, text.len);
        if (hi <= lo) return "";
        return std.mem.trim(u8, text[lo..hi], " \t");
    }

    /// The reference as text. Which template applies is decided here and
    /// nowhere else, so a user who replaces one of them replaces exactly the
    /// case they meant to.
    fn refText(self: *App, out: *std.ArrayList(u8), r: Ref) Allocator.Error!void {
        var id_buf: [12]u8 = undefined;
        var line_buf: [12]u8 = undefined;
        var end_buf: [12]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "{d}", .{r.change_id}) catch unreachable;
        const line = std.fmt.bufPrint(&line_buf, "{d}", .{r.line}) catch unreachable;
        const end = std.fmt.bufPrint(&end_buf, "{d}", .{r.end}) catch unreachable;

        // No hunk and no line is a file whose body was never parsed. `#0` and
        // `:0` would both be lies, so the path is the whole reference.
        const tmpl = if (r.line == 0 or r.change_id == hunk.no_id)
            self.templates.ref_file
        else if (r.deleted)
            self.templates.ref_hunk
        else if (r.end != 0)
            self.templates.ref_range
        else if (r.span.len > 0)
            self.templates.ref_span
        else
            self.templates.ref_single;

        try template.render(self.gpa, out, tmpl, &.{
            .{ .name = "change_id", .value = id },
            .{ .name = "path", .value = r.path },
            .{ .name = "line", .value = line },
            .{ .name = "start", .value = line },
            .{ .name = "end", .value = end },
            .{ .name = "span", .value = r.span },
        });
    }

    /// The lines themselves, under the reference, markers kept. `Y` exists to
    /// paste a change into a message, and `+`/`-` is what says which side of
    /// it a line is on - without them a mixed range reads as nonsense.
    fn appendLines(self: *App, out: *std.ArrayList(u8)) Allocator.Error!void {
        const f = self.current() orelse return;
        const sel = self.selection();
        const lo_row = if (sel) |s| s.lo else self.cursor;
        const hi_row = if (sel) |s| s.hi else self.cursor;

        var row = lo_row;
        while (row <= hi_row) : (row += 1) {
            const li = self.rows.lineAt(row) orelse continue;
            if (li >= f.lines.len()) continue;
            try out.append(self.gpa, '\n');
            try out.append(self.gpa, switch (f.lines.kind[li]) {
                .add => '+',
                .del => '-',
                .context => ' ',
            });
            try out.appendSlice(self.gpa, f.lines.text[li]);
        }
    }

    /// Builds the payload and hands it to the loop. Nothing here talks to a
    /// bridge: `core/` and `ui/app.zig` are both testable without one, and
    /// this is the file the tests are in.
    fn compose(self: *App, how: Delivery, what: What) Allocator.Error!void {
        const r = self.refAt() orelse {
            self.notice.set("nothing here to point at", .{});
            return;
        };

        self.outgoing.clearRetainingCapacity();
        switch (what) {
            .ref => try self.refText(&self.outgoing, r),
            .ref_lines => {
                try self.refText(&self.outgoing, r);
                try self.appendLines(&self.outgoing);
            },
            .ask => |tmpl| {
                var ref: std.ArrayList(u8) = .empty;
                defer ref.deinit(self.gpa);
                try self.refText(&ref, r);
                try template.render(self.gpa, &self.outgoing, tmpl, &.{
                    .{ .name = "ref", .value = ref.items },
                });
            },
        }
        self.want_send = how;

        // An operation on a selection ends it, the way an operator does in
        // vim: the range has been used, and leaving it highlighted invites a
        // second send of the same thing.
        if (self.mode == .visual) self.leaveVisual();
    }

    /// The composed payload, valid until the next `compose`.
    pub fn payload(self: *const App) []const u8 {
        return self.outgoing.items;
    }

    // -- $EDITOR -------------------------------------------------------------

    pub const EditTarget = struct {
        path: []const u8,
        /// 0 means "no line": open at the top rather than at a line number
        /// that does not exist in the file on disk.
        line: u32,
    };

    /// What `e` should open. References resolve against the *new* file
    /// (SPEC.md 6.3), so a cursor on a deleted line - which has no new-file
    /// line of its own - falls back to where the deletion happened.
    pub fn editTarget(self: *App) ?EditTarget {
        const f = self.current() orelse return null;
        if (f.status == .deleted) return null;
        // Every failure below means the same thing - open the file, at no
        // particular line - so it is written once and returned from.
        const top: EditTarget = .{ .path = f.path(), .line = 0 };

        const li = self.rows.lineAt(self.cursor) orelse return top;
        if (li >= f.lines.len()) return top;
        if (f.lines.kind[li] != .del) return .{ .path = f.path(), .line = f.lines.new_no[li] };

        const hi = self.rows.hunkAt(self.cursor) orelse return top;
        if (hi >= f.hunks.len) return top;
        return .{ .path = f.path(), .line = f.hunks[hi].new_start };
    }

    fn moveTo(self: *App, row: u32) void {
        const n = self.rows.len();
        if (n == 0) {
            self.cursor = 0;
            self.col = 0;
            return;
        }
        self.cursor = @min(row, n - 1);
        // The column follows what was last asked for rather than what the
        // previous line happened to allow, which is the whole point of
        // keeping the two apart.
        self.col = motion.clamp(self.cursorText(), self.want_col);
    }

    // -- the column ----------------------------------------------------------

    /// The text under the cursor, or empty on a row that is chrome. Every
    /// motion reads through this, so a header is a line of no characters
    /// rather than a special case at each call site.
    fn cursorText(self: *App) []const u8 {
        return self.textOfRow(self.cursor);
    }

    fn textOfRow(self: *App, row: u32) []const u8 {
        const f = self.current() orelse return "";
        const li = self.rows.lineAt(row) orelse return "";
        if (li >= f.lines.len()) return "";
        return f.lines.text[li];
    }

    /// Moves the cursor within its line. Both columns, because this is the
    /// reader saying where they want to be - the vertical motions are what
    /// keep `want_col` and let `col` give way.
    fn setCol(self: *App, at: u32) void {
        self.col = at;
        self.want_col = at;
    }

    /// Puts the column back on a boundary of the line it is now in. Every
    /// rebuild needs it: the row can survive a re-diff while the text on it
    /// becomes shorter, or becomes something else entirely.
    fn clampCol(self: *App) void {
        self.col = motion.clamp(self.cursorText(), self.col);
    }

    /// Applies a motion that may have nowhere to go on this line. `w` and `b`
    /// carry on into the neighbouring line the way vim does; the character
    /// motions stop, because `h` at column zero has always stopped.
    fn stepWord(self: *App, forward: bool, width: motion.Width) void {
        const text = self.cursorText();
        const found = if (forward)
            motion.wordNext(text, self.col, width)
        else
            motion.wordPrev(text, self.col, width);
        if (found) |at| return self.setCol(at);

        // Nothing left on this line: cross to the neighbouring one and take
        // its first or last word. Chrome is stepped over - a hunk header is
        // not a word - but an empty *line* is one, the way it is in vim, so a
        // blank between two paragraphs is a place the cursor can be.
        const last = self.rows.len() -| 1;
        var row = self.cursor;
        while (if (forward) row < last else row > 0) {
            row = if (forward) row + 1 else row - 1;
            if (self.rows.lineAt(row) == null) continue;
            const next = self.textOfRow(row);
            self.cursor = row;
            self.setCol(if (forward) motion.firstNonBlank(next) else motion.lastWordStart(next, width));
            return;
        }
    }

    /// `e` and `E`, which cross into the next line the way `w` does - but over
    /// an empty one rather than onto it, because an empty line has no word
    /// whose end the cursor could sit on.
    fn stepWordEnd(self: *App, width: motion.Width) void {
        if (motion.wordEnd(self.cursorText(), self.col, width)) |at| return self.setCol(at);

        const last = self.rows.len() -| 1;
        var row = self.cursor;
        while (row < last) {
            row += 1;
            if (self.rows.lineAt(row) == null) continue;
            const at = motion.firstWordEnd(self.textOfRow(row), width) orelse continue;
            self.cursor = row;
            self.setCol(at);
            return;
        }
    }

    /// `f`, `t`, `F`, `T`, and the `;`/`,` that repeat them.
    fn applyFind(self: *App, f: motion.Find) void {
        self.last_find = f;
        const text = self.cursorText();
        if (motion.find(text, self.col, f)) |at| return self.setCol(at);
        // Saying so beats a key that looks broken: `f` waited for a character
        // and then nothing moved.
        self.notice.set("no '{u}' on this line", .{f.target});
    }

    /// Wraps within the file, the way `]f` wraps within the review: at the last
    /// hunk `]h` returns to the first. Announced for the same reason - the
    /// cursor moved further than one step, and nothing else on screen says so.
    ///
    /// The wrap lives here rather than in `rows.nextHunkRow` because only here
    /// is there a status line to announce it in.
    fn stepHunk(self: *App, delta: i32) !void {
        const hs = self.rows.hunk_rows;
        if (hs.len == 0) return;

        // By hunk *index*, not by row. Stepping by row cannot go backwards at
        // all: the cursor always lands on `header + 1`, and the nearest header
        // strictly above that row is the very one it just landed on, so `[h`
        // returned to where it already was and the backward wrap was
        // unreachable.
        const n: i64 = @intCast(hs.len);
        const here: ?u32 = self.rows.hunkAt(self.cursor);
        const raw: i64 = if (here) |h|
            @as(i64, @intCast(h)) + delta
        else
            // Above the first header, `]h` means the first hunk rather than
            // the second, and `[h` means the last.
            (if (delta > 0) 0 else n - 1);

        // Still inside this file: the common case, and no file work at all.
        if (raw >= 0 and raw < n) {
            self.moveTo(hs[@intCast(raw)] + 1);
            return;
        }

        // Off the end of the file's hunks.
        if (self.nav.hunk_crosses_files and try self.crossToHunk(delta)) return;

        const target = hs[wrapIndex(raw, hs.len).index] + 1;
        // One hunk wraps onto itself; saying so every time would be noise.
        if (target != self.cursor) self.noteWrap(delta, "hunk");
        self.moveTo(target);
    }

    /// Carries `]h` into the next file's first hunk, or `[h` into the previous
    /// file's last one. Returns false when there is nowhere to go, leaving the
    /// caller to wrap inside this file instead.
    ///
    /// Skips files that contribute no hunk rows - a summarised file has none -
    /// rather than parking the cursor somewhere `]h` cannot leave. Bounded by
    /// the file count, so a review of nothing but such files terminates.
    fn crossToHunk(self: *App, delta: i32) !bool {
        const count = self.files().len;
        if (count <= 1) return false;

        var tries: usize = 0;
        while (tries < count) : (tries += 1) {
            // `stepFile` wraps across the review and announces it, which is
            // exactly the right message at the true end of the last file.
            try self.stepFile(delta);
            const hs = self.rows.hunk_rows;
            if (hs.len == 0) continue;
            self.moveTo(if (delta > 0) hs[0] + 1 else hs[hs.len - 1] + 1);
            return true;
        }
        return false;
    }

    /// Wraps: `]f` from the last file lands on the first, `[f` from the first
    /// lands on the last. A review is a ring, and stopping dead at the end
    /// reads as a dropped keystroke. Announced for the same reason the search
    /// announces its wrap - the file under you changed further than one step.
    fn stepFile(self: *App, delta: i32) !void {
        const n = self.files().len;
        if (n == 0) return;
        const step = wrapIndex(@as(i64, self.file_index) + delta, n);
        if (step.index == self.file_index) return;
        if (step.wrapped) self.noteWrap(delta, "file");
        self.file_index = step.index;
        try self.rebuildRows(.reset);
    }

    /// Both ring motions say the same thing when they come round: the cursor
    /// moved further than one step and nothing else on screen would show it.
    fn noteWrap(self: *App, delta: i32, what: []const u8) void {
        self.notice.set("wrapped to {s} {s}", .{ if (delta > 0) "first" else "last", what });
    }

    // -- screen rows ---------------------------------------------------------
    //
    // A body row is one screen row until it wraps, and everything that scrolls
    // has to count the screen it is scrolling. Measured here rather than in
    // the renderer because the position is decided before the frame is drawn -
    // and measured with `ui/wrap.zig`, which is the same code the renderer
    // draws with, so the two cannot disagree about where a line ends.

    /// Screen rows body row `row` occupies, never more than `cap`. Chrome is
    /// always one; so is every row when wrapping is off.
    fn rowHeight(self: *App, row: u32, cap: u16) u16 {
        if (!self.wrap or cap <= 1) return 1;
        const f = self.current() orelse return 1;
        const li = self.rows.lineAt(row) orelse return 1;
        if (li >= f.lines.text.len) return 1;
        return wrap_mod.height(
            f.lines.text[li],
            self.cols -| rows_mod.gutter(f),
            self.width_method,
            cap,
        );
    }

    /// `<C-d>` and `<C-u>`: half a screen, and the *screen* is what moves.
    ///
    /// Moving only the cursor is what this did before, and it made the first
    /// press of a page key do nothing visible - the cursor slid down inside a
    /// stationary view and the text only started moving once it reached the
    /// bottom margin. Vim moves both by the same amount, so the cursor keeps
    /// its place on screen and the page turns under it, which is the whole
    /// point of a page key.
    fn page(self: *App, dir: i32, body: u16) void {
        const half = @max(1, body / 2);
        if (dir > 0) {
            self.scroll = self.rowBelow(self.scroll, half, body);
            self.moveTo(self.rowBelow(self.cursor, half, body));
        } else {
            self.scroll = self.rowAbove(self.scroll, half, body);
            self.moveTo(self.rowAbove(self.cursor, half, body));
        }
    }

    /// The row `screens` screen rows below `from`, and above for the other.
    /// Both move at least one row: a page motion that cannot move because the
    /// line under the cursor fills the pane is a key that does nothing.
    fn rowBelow(self: *App, from: u32, screens: u16, body: u16) u32 {
        const last = self.rows.len() -| 1;
        var acc: u32 = 0;
        var i = from;
        while (i < last) {
            i += 1;
            acc += self.rowHeight(i, body);
            if (acc >= screens) break;
        }
        return i;
    }

    fn rowAbove(self: *App, from: u32, screens: u16, body: u16) u32 {
        var acc: u32 = 0;
        var i = from;
        while (i > 0) {
            i -= 1;
            acc += self.rowHeight(i, body);
            if (acc >= screens) break;
        }
        return i;
    }

    /// The scroll offset that puts the cursor's row half a pane down, counting
    /// the screen rows a wrapped line takes rather than the one row it is.
    fn centerCursor(self: *App, body: u16) void {
        const half = body / 2;
        var top = self.cursor;
        var acc: u32 = 0;
        while (top > 0) {
            const above = self.rowHeight(top - 1, body);
            if (acc + above > half) break;
            acc += above;
            top -= 1;
        }
        self.scroll = top;
    }

    /// Screen rows between two scroll positions, positive when `to` is below
    /// `from`. Capped, because the only caller refuses to animate past two
    /// screens and walking ten thousand rows to find that out is waste.
    fn screenRowsBetween(self: *App, from: u32, to: u32, body: u16) i32 {
        const cap: u32 = @as(u32, anim.max_screens) * @as(u32, body) + 1;
        var acc: u32 = 0;
        var i = @min(from, to);
        const end = @max(from, to);
        while (i < end and acc <= cap) : (i += 1) acc += self.rowHeight(i, body);
        const d: i32 = @intCast(@min(acc, cap));
        return if (to >= from) d else -d;
    }

    /// Starts the viewport catching up, if it moved at all.
    fn animateFrom(self: *App, was_at: u32, body: u16) void {
        if (was_at == self.scroll) return;
        self.scroll_anim.add(self.screenRowsBetween(was_at, self.scroll, body), body);
    }

    pub fn animating(self: *App, body: u16) bool {
        if (self.scroll_anim.active()) return true;
        const target = self.cursorCell(body) orelse return false;
        return self.cursor_anim.travelling(target);
    }

    /// One frame of both animations. The viewport moves first, because where
    /// the cursor belongs on screen depends on where the viewport has got to.
    pub fn stepAnim(self: *App, dt_ms: f32, body: u16) void {
        self.scroll_anim.step(dt_ms);
        if (self.cursorCell(body)) |target| self.cursor_anim.step(target, dt_ms);
    }

    /// Arrive now. What the loop does when a key arrives mid-flight: an
    /// animation the reader has already moved past is latency, not motion.
    pub fn settleScroll(self: *App) void {
        self.scroll_anim.settle();
    }

    /// The cursor is somewhere else entirely rather than somewhere further:
    /// another file, a rebuilt diff, a pane that changed size. There is no
    /// path between two unrelated screens to draw the block along.
    pub fn placeCursor(self: *App) void {
        self.cursor_anim.place();
    }

    /// A position displaced by the animation: the row `up` screen rows above
    /// `from`, and how many of that row's screen rows are above the result.
    /// Negative `up` walks the other way.
    ///
    /// A wrapped line is several screen rows, so this is a walk rather than
    /// arithmetic - and the walk is bounded by the displacement, which
    /// `anim.Scroll` has already capped at two screens.
    pub const Top = struct { row: u32, skip: u16 };

    fn displaced(self: *App, from: u32, up: i32, body: u16) Top {
        if (up == 0) return .{ .row = from, .skip = 0 };

        if (up > 0) {
            // Drawn above where it settles, which is what scrolling *down*
            // looks like while the screen catches up.
            var row = from;
            var left: u32 = @intCast(up);
            while (left > 0 and row > 0) {
                row -= 1;
                const h = self.rowHeight(row, body);
                if (h > left) return .{ .row = row, .skip = @intCast(h - left) };
                left -= h;
            }
            return .{ .row = row, .skip = 0 };
        }

        var row = from;
        var left: u32 = @intCast(-up);
        const last = self.rows.len() -| 1;
        while (left > 0 and row < last) {
            const h = self.rowHeight(row, body);
            if (h > left) return .{ .row = row, .skip = @intCast(left) };
            left -= h;
            row += 1;
        }
        return .{ .row = row, .skip = 0 };
    }

    /// Where the body is drawn from while the viewport catches up.
    fn drawnTop(self: *App, body: u16) Top {
        return self.displaced(self.scroll, self.scroll_anim.rows(), body);
    }

    /// The cell the cursor belongs on this frame, in body coordinates: the
    /// screen row it lands on once the rows above it are counted, and the
    /// column its byte offset falls at once the line is wrapped.
    ///
    /// Null when it is not on screen at all, which is the one case with no
    /// cell to travel to.
    pub fn cursorCell(self: *App, body: u16) ?anim.Cursor.Cell {
        const f = self.current() orelse return null;
        const top = self.drawnTop(body);
        const row = self.drawnCursor(body);
        if (row < top.row) return null;

        var y: i32 = -@as(i32, top.skip);
        var i = top.row;
        while (i < row) : (i += 1) y += self.rowHeight(i, body);

        const gutter = rows_mod.gutter(f);
        // A hunk header or a rule has no line to find a column in, but the
        // cursor is still on it: `j` steps through chrome like any other row.
        // Parking it at the first text column keeps it visible and keeps it
        // moving - returning null here blinks it out for a frame and then
        // teleports it, which is what a held `j` looked like.
        const li = self.rows.lineAt(row) orelse
            return .{ .row = @floatFromInt(y), .col = @floatFromInt(gutter) };
        if (li >= f.lines.len()) return .{ .row = @floatFromInt(y), .col = @floatFromInt(gutter) };

        const avail = if (self.wrap) self.cols -| gutter else 0;
        const cell = wrap_mod.locate(f.lines.text[li], avail, self.width_method, self.col);
        return .{
            .row = @floatFromInt(y + @as(i32, cell.row)),
            .col = @floatFromInt(gutter + cell.col),
        };
    }

    /// Which row the cursor is *drawn* on while the viewport catches up.
    ///
    /// Displaced by the same amount as the viewport, so the cursor holds its
    /// place on screen and the text slides underneath it - which is what a
    /// page key does, and what the eye is tracking. Left at its settled row it
    /// does the opposite: on the first frame the old screen is still showing
    /// but the cursor is already half a page further down, so it snaps away
    /// (often off the bottom edge, where it disappears altogether) and then
    /// crawls back. Text and cursor moving in opposite directions is the one
    /// thing that reads worse than not animating at all.
    fn drawnCursor(self: *App, body: u16) u32 {
        return self.displaced(self.cursor, self.scroll_anim.rows(), body).row;
    }

    /// Keeps the cursor inside the body with a margin, and never scrolls past
    /// the end of the rows.
    pub fn clampScroll(self: *App, body: u16) void {
        const h: Heights = .{ .app = self, .cap = body };
        self.scroll = scrollFor(h, self.cursor, self.scroll, self.rows.len(), body, self.nav.scrolloff);
    }

    /// What `scrollFor` asks about a row. A struct rather than a closure so
    /// the scroll arithmetic stays a pure function with a fake in its tests.
    const Heights = struct {
        app: *App,
        cap: u16,

        pub fn at(self: Heights, row: u32) u16 {
            return self.app.rowHeight(row, self.cap);
        }
    };

    pub fn handle(self: *App, ev: event.Event, body: u16) !void {
        switch (ev) {
            .quit => self.quit = true,
            .key => |k| {
                // While a prompt is open the keys are text, not actions, so
                // they never reach the keymap.
                if (self.mode == .command) return self.feedPrompt(k, body);
                if (self.mode == .help) return self.feedHelp(k, body);
                if (self.mode == .finder) return self.feedFiles(k, body);
                // A notice describes the last keystroke, so the next one
                // clears it - and clearing before dispatch means the command
                // about to run can leave one of its own.
                self.notice.clear();
                // `f` and its three siblings each take the next key as the
                // character to search for, never as a command. Escape gives up
                // on one, so a mistyped `f` is not a key that eats the next.
                if (self.pending_find) |p| {
                    self.pending_find = null;
                    if (k.codepoint != event.code.escape) {
                        self.applyFind(.{ .target = k.codepoint, .forward = p.forward, .till = p.till });
                    }
                    self.clampScroll(body);
                    return;
                }
                switch (self.km.feed(k, self.mode)) {
                    .command => |cmd| try self.run(cmd, body),
                    .pending, .none => {},
                }
            },
            // Neither of these is motion the reader asked for, so nothing
            // slides: the screen they were watching is already gone.
            .files_changed => |paths| {
                self.settleScroll();
                self.placeCursor();
                // One place knows what an event owns, so a new owning variant
                // cannot be freed here and forgotten in `Queue.deinit`.
                event.Queue.freePayload(self.gpa, .{ .files_changed = paths });
                try self.rediff();
                self.clampScroll(body);
            },
            // The size itself belongs to the run loop, which owns `ws` and is
            // what calls `vx.resize`. What is left for the app is the part
            // that is its own: the body just changed height, so the scroll
            // offset that kept the cursor on screen may no longer. Doing it
            // here rather than only at the top of the loop is what makes a
            // resize testable without a terminal.
            .resize => |size| {
                self.settleScroll();
                self.placeCursor();
                self.cols = size.cols;
                self.clampScroll(body);
            },
            .agent_quiescent, .snapshot_taken => {},
        }
    }
};

/// Navigation behaviour, owned by `config.zig` and filled from `[nav]`. The
/// alias is kept because the docs and dispatch both call it `app.Nav`: the
/// point of declaring it before the config file existed was that landing the
/// file would be a parse plus an assignment, and this is that assignment.
pub const Nav = config.Nav;

/// Scroll offset that keeps `cursor` visible with a margin, given the current
/// offset and the body height. Pure, so the awkward cases - a body shorter
/// than twice the margin, a cursor past the end, a resize to one row - are
/// testable without a terminal.
///
/// `scrolloff` is `nav.scrolloff`, clamped here to a third of the body rather
/// than at the point it is read: a reader who sets 20 on a laptop should get a
/// degraded margin in a four-row split, not a cursor welded to the middle.
/// One step around a ring, and whether that step came round the end. `@mod`
/// rather than `@rem`: a negative step has to land at the far end rather than
/// staying negative. Three motions - files, hunks and the search's file walk -
/// each spelled this out before, and each spelled it slightly differently.
pub fn wrapIndex(raw: i64, len: usize) struct { index: u32, wrapped: bool } {
    if (len == 0) return .{ .index = 0, .wrapped = false };
    const n: i64 = @intCast(len);
    const i = @mod(raw, n);
    return .{ .index = @intCast(i), .wrapped = i != raw };
}

/// `heights.at(row)` is the screen rows that row occupies, which is one for
/// every row until a line wraps. Passed in rather than computed here so this
/// stays arithmetic: `App.Heights` measures the real thing, and the tests
/// below hand it a table.
pub fn scrollFor(
    heights: anytype,
    cursor: u32,
    scroll: u32,
    rows_len: u32,
    body: u16,
    scrolloff: u32,
) u32 {
    if (body == 0 or rows_len == 0) return 0;
    const last = rows_len - 1;
    const margin: u32 = @min(scrolloff, body / 3);
    var out = scroll;

    // The row a margin above the cursor has to be on screen.
    const want_top = cursor -| margin;
    if (want_top < out) out = want_top;

    // So does the one a margin below it - but never at the cursor's expense.
    // Walking up from there is what makes the margin a number of *rows* while
    // the room it needs is a number of screen rows.
    const target = @min(cursor +| margin, last);
    var lo = target;
    var acc: u32 = heights.at(target);
    while (lo > 0) {
        const above = heights.at(lo - 1);
        if (acc + above > body) break;
        acc += above;
        lo -= 1;
    }
    if (out < lo) out = @min(lo, cursor);

    // And never blank rows below the last one: the largest offset that still
    // fills the body, found by walking back from the end for the same reason.
    var max_scroll = rows_len;
    var tail: u32 = 0;
    while (max_scroll > 0) {
        const h = heights.at(max_scroll - 1);
        if (tail + h > body) break;
        tail += h;
        max_scroll -= 1;
    }
    if (max_scroll > last) max_scroll = last;
    if (out > max_scroll) out = max_scroll;
    return out;
}

/// Every row one screen row tall: what `scrollFor` sees with wrapping off, and
/// what its arithmetic tests measure against.
pub const flat_heights = struct {
    pub fn at(_: @This(), _: u32) u16 {
        return 1;
    }
}{};

const testing = std.testing;

// Zig collects tests from a file only when a `test` block references it.
// Without a list like this one, every test under `ui/` compiled into the
// binary but ran nowhere - which is how a render test with the wrong arity sat
// green through a whole phase. Each module lists what it imports, so a new
// module joins `zig build check` where it is used: the ones the run loop pulls
// in are listed in `loop.zig`, and `main.zig` covers the rest.
test {
    _ = template;
    _ = devicon;
    _ = files_mod;
    _ = help_mod;
    _ = keymap;
    _ = keytext;
    _ = prompt_mod;
    _ = render;
    _ = review_mod;
    _ = anim;
    _ = motion;
    _ = rows_mod;
    _ = search;
    _ = theme_mod;
}

// -- pure arithmetic: no fixture, no rows, no terminal -------------------

test "scrolling keeps the cursor inside the body with a margin" {
    // Cursor near the top pins the view to the top rather than showing rows
    // that do not exist above it.
    try testing.expectEqual(@as(u32, 0), scrollFor(flat_heights, 0, 0, 100, 22, 3));
    try testing.expectEqual(@as(u32, 0), scrollFor(flat_heights, 2, 0, 100, 22, 3));

    // Moving down past the bottom margin scrolls by exactly what is needed:
    // cursor 20 with a 3-row margin needs rows 21-23 visible, and 2+22-1 = 23.
    try testing.expectEqual(@as(u32, 2), scrollFor(flat_heights, 20, 0, 100, 22, 3));
    // Moving back up above the top margin scrolls back.
    try testing.expectEqual(@as(u32, 7), scrollFor(flat_heights, 10, 20, 100, 22, 3));
}

test "scrolling never runs past the last row" {
    // A cursor at the end still leaves a full body on screen, not a screen
    // half full of blanks.
    try testing.expectEqual(@as(u32, 78), scrollFor(flat_heights, 99, 90, 100, 22, 3));
    // Fewer rows than the body means no scrolling at all.
    try testing.expectEqual(@as(u32, 0), scrollFor(flat_heights, 3, 0, 5, 22, 3));
    try testing.expectEqual(@as(u32, 0), scrollFor(flat_heights, 4, 3, 5, 22, 3));
}

test "a tall row costs the screen rows it takes, not the one row it is" {
    // Row 3 wraps onto five screen rows; everything else is one.
    const Table = struct {
        hs: []const u16,
        pub fn at(self: @This(), row: u32) u16 {
            return if (row < self.hs.len) self.hs[row] else 1;
        }
    };
    const t: Table = .{ .hs = &.{ 1, 1, 1, 5, 1, 1, 1, 1, 1, 1 } };

    // Rows 0-9 are exactly ten screen rows, so a ten-row body shows them all.
    try testing.expectEqual(@as(u32, 0), scrollFor(t, 5, 0, 10, 10, 0));

    // The last row cannot be reached without scrolling the tall one off:
    // rows 4-9 are six screen rows, rows 3-9 are eleven.
    try testing.expectEqual(@as(u32, 4), scrollFor(t, 9, 0, 10, 10, 0));

    // Flat rows in the same shape need no scroll at all, which is the whole
    // difference this arithmetic exists to make.
    try testing.expectEqual(@as(u32, 0), scrollFor(flat_heights, 9, 0, 10, 10, 0));
}

test "a row taller than the body is shown from its top rather than skipped" {
    const Table = struct {
        hs: []const u16,
        pub fn at(self: @This(), row: u32) u16 {
            return if (row < self.hs.len) self.hs[row] else 1;
        }
    };
    // Row 2 is a generated line: twenty screen rows in a body of ten.
    const t: Table = .{ .hs = &.{ 1, 1, 20, 1, 1, 1 } };
    try testing.expectEqual(@as(u32, 2), scrollFor(t, 2, 0, 6, 10, 3));
}

test "degenerate sizes do not underflow" {
    // A one-row body has no room for a margin; the arithmetic must still hold.
    try testing.expectEqual(@as(u32, 0), scrollFor(flat_heights, 0, 0, 0, 22, 3));
    try testing.expectEqual(@as(u32, 0), scrollFor(flat_heights, 5, 0, 10, 0, 3));
    _ = scrollFor(flat_heights, 0, 0, 1, 1, 3);
    _ = scrollFor(flat_heights, 9, 0, 10, 1, 3);
    _ = scrollFor(flat_heights, 0, 9, 10, 2, 3);
}

test "a ring step wraps at both ends and reports only the wrap" {
    // The shared arithmetic behind `]f`, `]h` and the search's walk across
    // files. Each of the three had its own copy, and the backward one is the
    // half that is easy to get wrong: `@rem` leaves it negative.
    try testing.expectEqual(@as(u32, 1), wrapIndex(1, 3).index);
    try testing.expect(!wrapIndex(1, 3).wrapped);

    try testing.expectEqual(@as(u32, 0), wrapIndex(3, 3).index);
    try testing.expect(wrapIndex(3, 3).wrapped);

    try testing.expectEqual(@as(u32, 2), wrapIndex(-1, 3).index);
    try testing.expect(wrapIndex(-1, 3).wrapped);

    // An empty ring has nowhere to step to, and must not divide by zero.
    try testing.expectEqual(@as(u32, 0), wrapIndex(-1, 0).index);
    try testing.expect(!wrapIndex(-1, 0).wrapped);
}

// -- the fixture ---------------------------------------------------------

/// A two-file review built in memory: enough for the command layer without a
/// repository, a terminal or a subprocess. The lines are chosen so each token
/// appears in exactly one file, which is what makes the cross-file search
/// assertions unambiguous.
const Fixture = struct {
    threaded: std.Io.Threaded,
    queue: event.Queue,
    app: App,
    files: []diff.FileDiff,
    gpa: Allocator,

    const a_text = [_][]const u8{ "fn alpha() {", "    const x = 1;", "}" };
    const b_text = [_][]const u8{ "fn beta() {", "    const token = 2;", "}" };

    fn linesOf(gpa: Allocator, texts: []const []const u8, deleted_at: ?usize) !hunk.DiffLines {
        var l: hunk.DiffLines = .{
            .kind = try gpa.alloc(hunk.LineKind, texts.len),
            .old_no = try gpa.alloc(u32, texts.len),
            .new_no = try gpa.alloc(u32, texts.len),
            .text = try gpa.alloc([]const u8, texts.len),
        };
        for (texts, 0..) |t, i| {
            const del = deleted_at != null and deleted_at.? == i;
            l.kind[i] = if (del) .del else .context;
            l.old_no[i] = @intCast(i + 1);
            // A deleted line has no line in the new file, which is the case
            // `e` and the bridge both have to handle.
            l.new_no[i] = if (del) 0 else @intCast(i + 1);
            l.text[i] = t;
        }
        return l;
    }

    /// The ordinary review: two files, three lines each, nothing deleted.
    fn init(gpa: Allocator) !*Fixture {
        return build(gpa, null);
    }

    /// The same, with one line of the first file deleted - the case `e` and
    /// the bridge both have to handle, because a deleted line has no line in
    /// the new file to point at.
    fn withDeletion(gpa: Allocator, at: usize) !*Fixture {
        return build(gpa, at);
    }

    fn build(gpa: Allocator, deleted_at: ?usize) !*Fixture {
        const self = try gpa.create(Fixture);
        self.* = .{
            .threaded = .init(gpa, .{}),
            .queue = undefined,
            .app = undefined,
            .files = try gpa.alloc(diff.FileDiff, 2),
            .gpa = gpa,
        };
        const io = self.threaded.io();
        self.queue = event.Queue.init(gpa, io);
        self.app = App.init(gpa, io, &self.queue);

        const hunks_a = try gpa.alloc(hunk.Hunk, 1);
        hunks_a[0] = .{ .old_start = 1, .old_count = 3, .new_start = 1, .new_count = 3, .lo = 0, .hi = 3, .id = 1 };
        const hunks_b = try gpa.alloc(hunk.Hunk, 1);
        hunks_b[0] = .{ .old_start = 1, .old_count = 3, .new_start = 40, .new_count = 3, .lo = 0, .hi = 3, .id = 2 };

        self.files[0] = .{
            .old_path = "a.zig",
            .new_path = "a.zig",
            .status = .modified,
            .hunks = hunks_a,
            .lines = try linesOf(gpa, &a_text, deleted_at),
        };
        self.files[1] = .{
            .old_path = "b.zig",
            .new_path = "b.zig",
            .status = .modified,
            .hunks = hunks_b,
            .lines = try linesOf(gpa, &b_text, null),
        };
        self.app.review.parsed = .{ .diff = .{ .files = self.files }, .raw = &.{}, .stderr = &.{} };
        try self.app.rebuildRows(.reset);
        return self;
    }

    fn deinit(self: *Fixture) void {
        const gpa = self.gpa;
        for (self.files) |*f| {
            gpa.free(f.hunks);
            f.lines.deinit(gpa);
        }
        gpa.free(self.files);
        self.app.review.parsed = null;
        self.app.deinit();
        self.queue.deinit();
        self.threaded.deinit();
        gpa.destroy(self);
    }

    /// A sequence, spelled the way the `?` popup prints it and the way a
    /// config file writes it: `press("]f")`, `press("<Space>nf")`,
    /// `press("<C-d>")`. Going through the same parser as `[keys]` is the
    /// point - a test and a user's config cannot disagree about what `<Esc>`
    /// means.
    fn press(self: *Fixture, sequence: []const u8) !void {
        var buf: [keymap.Keymap.max_sequence]keymap.Chord = undefined;
        for (try keytext.parseChords(sequence, &buf)) |ch| {
            try self.app.handle(.{ .key = .{
                .codepoint = ch.cp,
                .mods = .{ .ctrl = ch.ctrl },
            } }, body_rows);
        }
    }

    /// Literal text, for a prompt that is collecting some. Spelled out rather
    /// than routed through `press`, because inside a prompt these are letters
    /// and not keys - which is the distinction half of these tests are about.
    fn typeIn(self: *Fixture, text: []const u8) !void {
        for (text) |ch| {
            try self.app.handle(.{ .key = .{ .codepoint = ch, .mods = .{} } }, body_rows);
        }
    }

    fn expectCursor(self: *Fixture, row: u32) !void {
        try testing.expectEqual(row, self.app.cursor);
    }

    fn expectFile(self: *Fixture, index: u32) !void {
        try testing.expectEqual(index, self.app.file_index);
    }

    fn expectMode(self: *Fixture, mode: event.Mode) !void {
        try testing.expectEqual(mode, self.app.mode);
    }

    /// The notice says what it should, without pinning the exact wording: the
    /// assertion is that the reader was told, not how it was phrased.
    fn expectNotice(self: *Fixture, needle: []const u8) !void {
        const text = self.app.notice.text();
        if (std.mem.indexOf(u8, text, needle) == null) {
            std.debug.print("notice was \"{s}\", expected it to mention \"{s}\"\n", .{ text, needle });
            return error.TestExpectedNotice;
        }
    }

    fn expectNoNotice(self: *Fixture) !void {
        try testing.expectEqual(@as(usize, 0), self.app.notice.text().len);
    }
};

/// The body height every fixture test drives with: a 26-row pane, less chrome.
const body_rows: u16 = 22;

// -- the column ------------------------------------------------------------

test "the column moves within the line and stops at both ends" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    // Row 1 is `fn alpha() {`.
    try fx.expectCursor(1);
    try testing.expectEqual(@as(u32, 0), fx.app.col);

    try fx.press("l");
    try fx.press("l");
    try testing.expectEqual(@as(u32, 2), fx.app.col);
    try fx.press("h");
    try testing.expectEqual(@as(u32, 1), fx.app.col);

    // `h` at the first column is a key that does nothing, not an underflow.
    try fx.press("h");
    try fx.press("h");
    try testing.expectEqual(@as(u32, 0), fx.app.col);

    // `$` is the last character, never the position after it.
    try fx.press("$");
    try testing.expectEqual(@as(u32, 11), fx.app.col);
    try fx.press("l");
    try testing.expectEqual(@as(u32, 11), fx.app.col);
    try fx.press("0");
    try testing.expectEqual(@as(u32, 0), fx.app.col);
}

test "word motions step by class and carry into the next line" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    // `fn alpha() {` - a class change is a boundary, so `(` is its own word.
    try fx.press("w");
    try testing.expectEqual(@as(u32, 3), fx.app.col);
    try fx.press("w");
    try testing.expectEqual(@as(u32, 8), fx.app.col);
    try fx.press("e");
    try testing.expectEqual(@as(u32, 9), fx.app.col);

    // Off the end of the line, `w` carries into the next one rather than
    // stopping - and lands on its first non-blank, past the indentation.
    try fx.press("$");
    try fx.press("w");
    try fx.expectCursor(2);
    try testing.expectEqual(@as(u32, 4), fx.app.col);

    // And `b` comes back to the last word of the line above.
    try fx.press("0");
    try fx.press("b");
    try fx.expectCursor(1);
    try testing.expectEqual(@as(u32, 11), fx.app.col);
}

test "an empty line is a word, and a hunk header is not" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();

    // Blank out the middle line: `w` off the end of the first should stop on
    // it, the way it does in vim, rather than skipping to the third.
    fx.files[0].lines.text[1] = "";
    try fx.press("$");
    try fx.press("w");
    try fx.expectCursor(2);
    try testing.expectEqual(@as(u32, 0), fx.app.col);

    // And from the blank line, on to the next line that has something.
    try fx.press("w");
    try fx.expectCursor(3);

    // `e` passes *over* the blank rather than stopping on it: an empty line is
    // a word, but it has no end for the cursor to sit on.
    try fx.press("gg");
    try fx.press("$");
    try fx.expectCursor(1);
    try fx.press("e");
    try fx.expectCursor(3);

    // Backwards over the blank, and then to the last word of the line above -
    // never onto row 0, which is the hunk header.
    try fx.press("b");
    try fx.expectCursor(2);
    try fx.press("b");
    try fx.expectCursor(1);
    try fx.press("0");
    try fx.press("b");
    try fx.expectCursor(1);
}

test "W steps over punctuation that w stops at" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    // Row 1 is `fn alpha() {`. `w` stops at the paren; `W` does not see it.
    try fx.press("w");
    try fx.press("w");
    try testing.expectEqual(@as(u32, 8), fx.app.col);

    try fx.press("0");
    try fx.press("W");
    try testing.expectEqual(@as(u32, 3), fx.app.col);
    try fx.press("W");
    try testing.expectEqual(@as(u32, 11), fx.app.col);

    // `E` runs to the end of the blob rather than to the end of `alpha`.
    try fx.press("0");
    try fx.press("E");
    try testing.expectEqual(@as(u32, 1), fx.app.col);
    try fx.press("E");
    try testing.expectEqual(@as(u32, 9), fx.app.col);

    // And `B` comes back over the whole of it.
    try fx.press("$");
    try fx.press("B");
    try testing.expectEqual(@as(u32, 3), fx.app.col);
}

test "the wanted column survives a short line and comes back on a long one" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    // Column 10 of `fn alpha() {`, then down onto `}`, which has one column.
    try fx.press("$");
    try fx.press("j");
    try fx.press("j");
    try fx.expectCursor(3);
    try testing.expectEqual(@as(u32, 0), fx.app.col);

    // Back up, and the column the reader asked for is where they land - the
    // short line clamped the cursor without forgetting what was wanted.
    try fx.press("k");
    try testing.expectEqual(@as(u32, 15), fx.app.col);
    try fx.press("k");
    try testing.expectEqual(@as(u32, 11), fx.app.col);
}

test "f waits for a character, and Escape gives up on it" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    // `fn alpha() {`: `f(` lands on the paren, `t(` one short of it.
    try fx.press("f");
    try testing.expect(fx.app.pending_find != null);
    try fx.press("(");
    try testing.expectEqual(@as(u32, 8), fx.app.col);
    try testing.expect(fx.app.pending_find == null);

    try fx.press("0");
    try fx.press("t");
    try fx.press("(");
    try testing.expectEqual(@as(u32, 7), fx.app.col);

    // `;` repeats it and `,` reverses it.
    try fx.press("0");
    try fx.press("f");
    try fx.press("a");
    try testing.expectEqual(@as(u32, 3), fx.app.col);
    try fx.press(";");
    try testing.expectEqual(@as(u32, 7), fx.app.col);
    try fx.press(",");
    try testing.expectEqual(@as(u32, 3), fx.app.col);

    // A character that is not on the line says so rather than moving.
    try fx.press("f");
    try fx.press("z");
    try fx.expectNotice("no 'z'");
    try testing.expectEqual(@as(u32, 3), fx.app.col);

    // Escape abandons a pending find, so a mistyped `f` does not eat the key
    // after it.
    try fx.press("f");
    try fx.press("<Esc>");
    try testing.expect(fx.app.pending_find == null);
    try fx.press("0");
    try testing.expectEqual(@as(u32, 0), fx.app.col);
}

test "v selects characters, V selects lines, and each toggles the other" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("v");
    try fx.expectMode(.visual);
    try testing.expectEqual(render.Selection.Kind.char, fx.app.selection().?.kind);
    // One character to start with, inclusive of the one under the cursor.
    try testing.expectEqual(@as(u32, 0), fx.app.selection().?.lo_col);
    try testing.expectEqual(@as(u32, 1), fx.app.selection().?.hi_col);

    try fx.press("l");
    try fx.press("l");
    try testing.expectEqual(@as(u32, 3), fx.app.selection().?.hi_col);

    // `V` switches rather than doing nothing, and the range becomes lines.
    try fx.press("V");
    try fx.expectMode(.visual);
    try testing.expectEqual(render.Selection.Kind.line, fx.app.selection().?.kind);
    // The same key again leaves.
    try fx.press("V");
    try fx.expectMode(.normal);

    // Selecting leftwards puts the anchor on the right; the range comes back
    // normalised rather than inverted.
    try fx.press("$");
    try fx.press("v");
    try fx.press("h");
    try fx.press("h");
    const sel = fx.app.selection().?;
    try testing.expect(sel.lo_col < sel.hi_col);
    try testing.expectEqual(@as(u32, 9), sel.lo_col);
    try testing.expectEqual(@as(u32, 12), sel.hi_col);
}

test "a charwise selection points the agent at the words, not at a column" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    // Select `alpha` on `fn alpha() {`.
    try fx.press("w");
    try fx.press("v");
    try fx.press("e");
    try fx.press("<CR>");
    try testing.expectEqualStrings("#1 a.zig:1 `alpha`", fx.app.payload());

    // Grown past one line, the text would have to carry the newline between
    // them - so it becomes the line range it always was.
    try fx.press("w");
    try fx.press("v");
    try fx.press("j");
    try fx.press("<CR>");
    try testing.expectEqualStrings("#1 a.zig:1-2", fx.app.payload());
}

// -- the viewport catching up ---------------------------------------------

test "a jump animates and a single row does not" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    fx.app.scroll_anim.budget_ms = 250;

    // Nothing to animate: the fixture is four rows in a 22-row body, so no
    // motion in it scrolls at all.
    try fx.press("j");
    try testing.expect(!fx.app.animating(body_rows));

    // A jump that does scroll starts the viewport catching up, displaced by
    // the screen rows it travelled.
    fx.app.scroll = 0;
    fx.app.cursor = 3;
    fx.app.animateFrom(2, body_rows);
    try testing.expect(fx.app.animating(body_rows));
    try testing.expectEqual(@as(i32, -2), fx.app.scroll_anim.rows());

    // And it settles on its own.
    var guard: u32 = 0;
    while (fx.app.animating(body_rows) and guard < 100) : (guard += 1) fx.app.stepAnim(16, body_rows);
    try testing.expect(!fx.app.animating(body_rows));
}

test "stepping is instant and only a jump is animated" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    fx.app.scroll_anim.budget_ms = 250;

    // A wrapped line makes one `j` worth three screen rows, which is exactly
    // the case that used to start an animation per keystroke: a held `j` then
    // spends its life cancelling the last one, which reads as stutter and
    // costs a frame of input latency per key.
    fx.files[0].lines.text[1] = "a line long enough that a narrow pane has to break it more than once";
    fx.app.cols = 30;
    fx.app.scroll = 0;
    fx.app.cursor = 1;
    try fx.app.run(.line_down, 4);
    try testing.expect(!fx.app.animating(body_rows));

    // The same movement asked for as a jump does animate.
    fx.app.scroll = 0;
    fx.app.cursor = 1;
    try fx.app.run(.page_down, 4);
    try testing.expect(fx.app.animating(body_rows));
}

test "the cursor travels for every motion, not only for a jump" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    // Placed where it belongs the first time it is drawn: there is nowhere to
    // travel from yet.
    const first = fx.app.cursorCell(body_rows).?;
    _ = fx.app.cursor_anim.cell(first);
    try testing.expect(!fx.app.animating(body_rows));

    // A column motion is a motion: the cursor has ground to cover, and the
    // viewport - which only animates for a jump - has none.
    try fx.press("$");
    try testing.expect(fx.app.animating(body_rows));
    try testing.expect(!fx.app.scroll_anim.active());

    // And it gets there, a cell at a time.
    var guard: u32 = 0;
    while (fx.app.animating(body_rows) and guard < 200) : (guard += 1) fx.app.stepAnim(16, body_rows);
    try testing.expect(guard > 1);
    try testing.expectEqual(fx.app.cursorCell(body_rows).?, fx.app.cursor_anim.at.?);
}

test "a row with no line still has a cell for the cursor to be on" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    // Row 0 is the hunk header. `j` steps through chrome like any other row,
    // and a cursor with nowhere to be blinks out for a frame and then
    // teleports - which is what a held `j` used to look like.
    fx.app.cursor = 0;
    const cell = fx.app.cursorCell(body_rows).?;
    try testing.expectEqual(@as(f32, 0), cell.row);
    try testing.expectEqual(@as(f32, @floatFromInt(rows_mod.gutter(&fx.files[0]))), cell.col);
}

test "the cursor keeps its place on screen while the text slides under it" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    fx.app.scroll_anim.budget_ms = 250;

    // Settled, the drawn cursor is the cursor. Far enough from the top that
    // the walk has room: displaced past the first row it clamps there, and the
    // gap closes because the screen has run out of file rather than because
    // anything moved wrongly.
    fx.app.scroll = 2;
    fx.app.cursor = 3;
    try testing.expectEqual(@as(u32, 3), fx.app.drawnCursor(body_rows));

    // Mid-flight, both are displaced by the same amount, so the cursor's
    // screen position - the gap between them - does not change. Left at its
    // settled row it would snap half a page away on the first frame and crawl
    // back, which is the text and the cursor moving opposite ways.
    fx.app.scroll_anim.offset = 2;
    const top = fx.app.drawnTop(body_rows);
    const cur = fx.app.drawnCursor(body_rows);
    try testing.expectEqual(@as(u32, 0), top.row);
    try testing.expectEqual(@as(u32, 1), cur);
    try testing.expectEqual(fx.app.cursor - fx.app.scroll, cur - top.row);
}

test "a second jump joins the first rather than cancelling it" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    fx.app.scroll_anim.budget_ms = 250;
    // Tall enough to have somewhere to scroll to: three of the four rows wrap
    // onto three screen rows each in a narrow pane.
    for (0..3) |i| fx.files[0].lines.text[i] = "a line long enough that a narrow pane has to break it more than once";
    fx.app.cols = 30;

    fx.app.scroll = 0;
    fx.app.cursor = 1;
    try fx.app.run(.page_down, 4);
    try testing.expect(fx.app.animating(body_rows));
    const first = fx.app.scroll_anim.offset;

    // Another jump arriving mid-flight adds to what is left: the reader asked
    // to be further away, not to wait twice as long.
    fx.app.scroll = 0;
    fx.app.cursor = 1;
    try fx.app.run(.page_down, 4);
    try testing.expect(fx.app.scroll_anim.offset > first);

    // Anything that is not a jump arrives at once instead.
    try fx.app.run(.line_down, 4);
    try testing.expect(!fx.app.animating(body_rows));
}

test "only the commands that take you somewhere count as jumps" {
    // Stepping never does, whatever it moves underneath.
    try testing.expect(!keymap.Command.line_down.jumps());
    try testing.expect(!keymap.Command.line_up.jumps());
    try testing.expect(!keymap.Command.word_next.jumps());
    try testing.expect(!keymap.Command.char_right.jumps());
    // Nor does anything that is not a motion at all.
    try testing.expect(!keymap.Command.send_ref.jumps());
    try testing.expect(!keymap.Command.toggle_wrap.jumps());

    // Asking to be somewhere does.
    try testing.expect(keymap.Command.page_down.jumps());
    try testing.expect(keymap.Command.bottom.jumps());
    try testing.expect(keymap.Command.next_hunk.jumps());
    try testing.expect(keymap.Command.center.jumps());
    try testing.expect(keymap.Command.search_next.jumps());
}

test "the drawn viewport is where the settled one is, once it arrives" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    // Settled: the row drawn first is the row scrolled to, with nothing of it
    // above the top of the pane.
    fx.app.scroll = 2;
    const settled = fx.app.drawnTop(body_rows);
    try testing.expectEqual(@as(u32, 2), settled.row);
    try testing.expectEqual(@as(u16, 0), settled.skip);

    // Mid-flight, drawn two screen rows above it - which on unwrapped lines is
    // two rows earlier and no partial row.
    fx.app.scroll_anim.budget_ms = 250;
    fx.app.scroll_anim.offset = 2;
    const flying = fx.app.drawnTop(body_rows);
    try testing.expectEqual(@as(u32, 0), flying.row);
    try testing.expectEqual(@as(u16, 0), flying.skip);

    // It never walks off the top: displaced further than there are rows above
    // it, the first row is as far as it goes.
    fx.app.scroll_anim.offset = 20;
    try testing.expectEqual(@as(u32, 0), fx.app.drawnTop(body_rows).row);
}

test "a wrapped row is crossed a screen row at a time, not all at once" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    // Make row 1 three screen rows tall in a narrow pane.
    fx.files[0].lines.text[0] = "a line long enough that a narrow pane has to break it more than once";
    fx.app.cols = 30;
    try testing.expectEqual(@as(u16, 3), fx.app.rowHeight(1, body_rows));

    // Settled on row 2, displaced by one screen row: the top is still row 1,
    // with two of its three screen rows above the pane. Stepping by whole
    // rows could only ever show all of it or none of it.
    fx.app.scroll = 2;
    fx.app.scroll_anim.budget_ms = 250;
    fx.app.scroll_anim.offset = 1;
    const one = fx.app.drawnTop(body_rows);
    try testing.expectEqual(@as(u32, 1), one.row);
    try testing.expectEqual(@as(u16, 2), one.skip);

    // Two rows up, one of them above; three, and the whole row is on screen.
    fx.app.scroll_anim.offset = 2;
    try testing.expectEqual(@as(u16, 1), fx.app.drawnTop(body_rows).skip);
    fx.app.scroll_anim.offset = 3;
    const three = fx.app.drawnTop(body_rows);
    try testing.expectEqual(@as(u32, 1), three.row);
    try testing.expectEqual(@as(u16, 0), three.skip);
}

test "the distance between two scroll positions is measured in screen rows" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    // Unwrapped, a row is a screen row and the distance is the row count.
    try testing.expectEqual(@as(i32, 2), fx.app.screenRowsBetween(1, 3, body_rows));
    // Backwards is the same distance, the other way.
    try testing.expectEqual(@as(i32, -2), fx.app.screenRowsBetween(3, 1, body_rows));
    try testing.expectEqual(@as(i32, 0), fx.app.screenRowsBetween(2, 2, body_rows));

    // Wrapped, the tall row costs what it draws: row 1 is three screen rows.
    fx.files[0].lines.text[0] = "a line long enough that a narrow pane has to break it more than once";
    fx.app.cols = 30;
    try testing.expectEqual(@as(i32, 4), fx.app.screenRowsBetween(1, 3, body_rows));
}

test "a relayout places the cursor rather than walking it across a new screen" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    // Give the cursor somewhere to have been drawn.
    _ = fx.app.cursor_anim.cell(fx.app.cursorCell(body_rows).?);
    try testing.expect(fx.app.cursor_anim.at != null);

    // `zw` changes what every line is worth in screen rows, so the cell the
    // cursor was on is not a cell on this screen: there is no path between
    // the two to draw a block along.
    try fx.press("zw");
    try testing.expect(fx.app.cursor_anim.at == null);

    // `Tab` changes the body's height, which moves every row under it, and is
    // the same case.
    _ = fx.app.cursor_anim.cell(fx.app.cursorCell(body_rows).?);
    try fx.app.run(.toggle_zen, body_rows);
    try testing.expect(fx.app.cursor_anim.at == null);
}

test "crossing into another file arrives rather than sliding" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    fx.app.scroll_anim.budget_ms = 250;

    // The rows under a new file are different rows; sliding between two
    // unrelated screens is an animation of nothing.
    try fx.press("]f");
    try fx.expectFile(1);
    try testing.expect(!fx.app.animating(body_rows));
}

// -- soft wrap ------------------------------------------------------------

test "a line wider than the pane is as many screen rows as it needs" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    // Rows: 0 header, 1..3 lines. The gutter is the sign, a space, a
    // two-digit number and two spaces.
    try testing.expectEqual(@as(u16, 6), rows_mod.gutter(&fx.files[0]));
    fx.files[0].lines.text[0] = "a line long enough that a narrow pane has to break it more than once";
    fx.app.cols = 30;

    // 24 columns of text, so a 68-character line is three rows.
    try testing.expectEqual(@as(u16, 3), fx.app.rowHeight(1, body_rows));
    // Chrome never wraps, whatever the width.
    try testing.expectEqual(@as(u16, 1), fx.app.rowHeight(0, body_rows));

    // Wide enough and it is one row again, and so is every row with wrapping
    // off - which is what makes `zw` a rendering switch and not a row model.
    fx.app.cols = 200;
    try testing.expectEqual(@as(u16, 1), fx.app.rowHeight(1, body_rows));
    fx.app.cols = 30;
    fx.app.wrap = false;
    try testing.expectEqual(@as(u16, 1), fx.app.rowHeight(1, body_rows));
}

test "half a page is half a screen, not half the rows on it" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    fx.files[0].lines.text[0] = "a line long enough that a narrow pane has to break it more than once";
    fx.app.cols = 30;

    // Row 1 is three screen rows, so it alone is more than half of a six-row
    // body: a page down from the header lands on it rather than past it.
    try testing.expectEqual(@as(u32, 1), fx.app.rowBelow(0, 3, 6));
    // The same motion over rows that do not wrap moves by the rows it counts.
    fx.app.wrap = false;
    try testing.expectEqual(@as(u32, 3), fx.app.rowBelow(0, 3, 6));
}

test "zw toggles wrapping and says which way it went" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    try testing.expect(fx.app.wrap);
    try fx.press("zw");
    try testing.expect(!fx.app.wrap);
    try fx.expectNotice("off");

    try fx.press("zw");
    try testing.expect(fx.app.wrap);
    try fx.expectNotice("on");
}

// -- visual select -------------------------------------------------------

test "V anchors a selection and motions extend it in either direction" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    // Rows: 0 header, 1..3 lines. The cursor opens on the first line.
    try fx.expectCursor(1);
    try testing.expect(fx.app.selection() == null);

    try fx.press("V");
    try fx.expectMode(.visual);
    // A fresh selection is one row, not zero.
    try testing.expectEqual(@as(u32, 1), fx.app.selection().?.count());

    try fx.press("j");
    try fx.press("j");
    const down = fx.app.selection().?;
    try testing.expectEqual(@as(u32, 1), down.lo);
    try testing.expectEqual(@as(u32, 3), down.hi);

    // Selecting upwards puts the anchor below the cursor; the range must come
    // back normalised rather than inverted.
    try fx.press("k");
    try fx.press("k");
    try fx.press("k");
    const up = fx.app.selection().?;
    try testing.expect(up.lo <= up.hi);
    try testing.expectEqual(@as(u32, 1), up.hi);

    try fx.press("<Esc>");
    try fx.expectMode(.normal);
    try testing.expect(fx.app.selection() == null);
}

test "moving to another file drops the selection instead of re-pointing it" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("V");
    try fx.press("j");
    try testing.expect(fx.app.selection() != null);

    // The rows the anchor described no longer exist. Keeping the indexes would
    // silently select whatever now sits at them.
    try fx.press("]f");
    try fx.expectFile(1);
    try testing.expect(fx.app.selection() == null);
    try fx.expectMode(.normal);
}

// -- motions across the review -------------------------------------------

test "hunk stepping crosses into the next file by default" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try testing.expect(fx.app.nav.hunk_crosses_files);
    try testing.expect(fx.app.files().len > 1);

    // To the last hunk of the first file.
    while (fx.app.rows.hunkAt(fx.app.cursor).? + 1 < fx.app.rows.hunk_rows.len) {
        try fx.press("]h");
    }
    try fx.expectFile(0);

    // One more leaves the file rather than looping inside it.
    try fx.press("]h");
    try fx.expectFile(1);
    try testing.expectEqual(fx.app.rows.hunk_rows[0] + 1, fx.app.cursor);
    // Crossing a boundary mid-review is not a wrap and must not claim to be.
    try fx.expectNoNotice();

    // Backwards over the same boundary returns to the *last* hunk of file 0.
    try fx.press("[h");
    try fx.expectFile(0);
    const hs = fx.app.rows.hunk_rows;
    try testing.expectEqual(hs[hs.len - 1] + 1, fx.app.cursor);
}

test "the whole review wraps at its far end, and says so" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    // `[h` from the very first hunk of the first file has nowhere earlier to
    // go, so it wraps round to the last file - which `stepFile` announces.
    try fx.expectFile(0);
    try fx.press("[h");
    try testing.expectEqual(@as(u32, @intCast(fx.app.files().len - 1)), fx.app.file_index);
    try fx.expectNotice("wrapped to last file");
}

test "hunk stepping stays in the file when config says so" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    // The flag a config file will set once `config.zig` lands.
    fx.app.nav.hunk_crosses_files = false;

    const in_file = fx.app.rows.hunk_rows.len;
    while (fx.app.rows.hunkAt(fx.app.cursor).? + 1 < in_file) {
        try fx.press("]h");
    }

    try fx.press("]h");
    // Same file, back at its first hunk.
    try fx.expectFile(0);
    try testing.expectEqual(fx.app.rows.hunk_rows[0] + 1, fx.app.cursor);
    if (in_file > 1) {
        try fx.expectNotice("wrapped to first hunk");
    }
}

test "prev hunk steps back a hunk rather than to the top of this one" {
    // The regression this guards: stepping by *row* could never go backwards.
    // The cursor always lands on `header + 1`, and the nearest header strictly
    // above that row is the one it just landed on, so `[h` returned to where
    // it already was - and the backward wrap could never be reached.
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    const hunks = fx.app.rows.hunk_rows.len;
    if (hunks < 2) return; // nothing to step between

    try fx.press("]h");
    const second = fx.app.cursor;
    try testing.expectEqual(fx.app.rows.hunk_rows[1] + 1, second);

    try fx.press("[h");
    try testing.expect(fx.app.cursor != second);
    try testing.expectEqual(fx.app.rows.hunk_rows[0] + 1, fx.app.cursor);
}

test "file stepping wraps at both ends, and says so" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    // Two files in the fixture, so one step leaves us on the last. Landing on
    // the last file is not itself a wrap.
    try fx.press("]f");
    try fx.expectFile(1);
    try fx.expectNoNotice();

    // A review is a ring: stopping dead at either end reads as a dropped
    // keystroke, and moving further than one step has to be announced,
    // because nothing else on screen says the file changed twice.
    try fx.press("]f");
    try fx.expectFile(0);
    try fx.expectNotice("wrapped to first");

    try fx.press("[f");
    try fx.expectFile(1);
    try fx.expectNotice("wrapped to last");
}

test "the leader forms reach the same commands as the bracket forms" {
    // `<Space>nh` and `]h` are two rows in the table pointing at one command,
    // which is what lets a remapping user rebind either independently. The
    // assertion is that they land in the same place, not merely that they do
    // something.
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    const start = fx.app.cursor;
    for ([_][2][]const u8{
        .{ "<Space>nh", "]h" },
        .{ "<Space>ph", "[h" },
    }) |pair| {
        fx.app.cursor = start;
        try fx.press(pair[0]);
        const by_leader = fx.app.cursor;

        fx.app.cursor = start;
        try fx.press(pair[1]);
        try testing.expectEqual(by_leader, fx.app.cursor);
    }

    // The file pair moves a file rather than a row, so it is checked by where
    // it lands rather than against its bracket form.
    try fx.press("<Space>nf");
    try fx.expectFile(1);
    try fx.press("<Space>pf");
    try fx.expectFile(0);
}

// -- the `?` overlay, as the app drives it -------------------------------

test "? opens the overlay and returns to the mode it came from" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("?");
    try fx.expectMode(.help);
    try fx.press("<Esc>");
    try fx.expectMode(.normal);

    // Opened from visual, it goes back to visual rather than dumping the
    // selection the user was building.
    try fx.press("V");
    try testing.expect(fx.app.selection() != null);
    try fx.press("?");
    try fx.expectMode(.help);
    try fx.press("<Esc>");
    try fx.expectMode(.visual);
    try testing.expect(fx.app.selection() != null);
}

test "keys under the overlay do nothing while it is up" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("j");
    const moved = fx.app.cursor;
    try testing.expect(moved > 0);

    try fx.press("?");
    try fx.press("j");
    try fx.press("j");
    try testing.expectEqual(moved, fx.app.cursor);
    // Those keys went into the filter instead, which is what makes the popup
    // searchable - and `q` types rather than quitting the app.
    try fx.press("q");
    try testing.expect(!fx.app.quit);
    try testing.expectEqualStrings("jjq", fx.app.help.filter.text());

    try fx.press("<Esc>");
    try fx.expectMode(.normal);
    // Closing clears the query, so `?` never reopens onto a stale filter.
    try testing.expectEqual(@as(usize, 0), fx.app.help.filter.text().len);
}

test "every key the popup advertises reaches its command" {
    // What is being tested here is the wiring: that these keys are bindings
    // live in `.help` and nowhere else. Where the selection lands - clamped at
    // both ends, reset by a narrowing filter, a column at a time - belongs to
    // `help.zig` and is tested there, against the rules rather than through
    // three layers of dispatch.
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("?");
    try testing.expectEqual(@as(usize, 0), fx.app.help.index);

    // Down, and the two aliases for it. `J` is navigation rather than filter
    // text, which costs nothing because the filter matches case-insensitively.
    for ([_][]const u8{ "<Down>", "J", "<C-n>" }, 1..) |k, want| {
        try fx.press(k);
        try testing.expectEqual(want, fx.app.help.index);
    }
    try testing.expectEqual(@as(usize, 0), fx.app.help.filter.text().len);

    // And up.
    for ([_][]const u8{ "<Up>", "K", "<C-p>" }, 0..) |k, i| {
        try fx.press(k);
        try testing.expectEqual(2 - i, fx.app.help.index);
    }

    // Sideways is the next tab. It used to be a column of the grid, which has
    // been one column wide since the two-column layout was rejected - so both
    // keys were bound to a movement that could not happen.
    for ([_][]const u8{ "<Right>", "L" }) |k| {
        fx.app.help.group = .move;
        fx.app.help.index = 5;
        try fx.press(k);
        try testing.expectEqual(keymap.Group.jump, fx.app.help.group);
        // A different tab is a different list: start at the top of it.
        try testing.expectEqual(@as(usize, 0), fx.app.help.index);
    }
    for ([_][]const u8{ "<Left>", "H" }) |k| {
        fx.app.help.group = .jump;
        try fx.press(k);
        try testing.expectEqual(keymap.Group.move, fx.app.help.group);
    }
}

test "typing narrows the list the popup is showing" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("?");
    const all = keytext.helpCount(fx.app.km.bindings, .normal, null, "");
    try fx.press("<Down>");
    try testing.expect(fx.app.help.index > 0);

    // The keys went into the filter rather than to dispatch, so the list is
    // shorter and the selection is back at the top of the new one.
    try fx.typeIn("file");
    const narrowed = keytext.helpCount(fx.app.km.bindings, .normal, null, fx.app.help.filter.text());
    try testing.expect(narrowed > 0);
    try testing.expect(narrowed < all);
    try testing.expectEqual(@as(usize, 0), fx.app.help.index);
}

test "the popup is available when there is nothing to review" {
    // An empty review is drawn from a different branch than a diff is, and it
    // is exactly when a reader is most likely to want the key list: there is
    // nothing on screen to learn the keys from.
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    try testing.expect(try fx.app.help.view(fx.app.mode, fx.app.km.bindings, arena) == null);

    // No current file, so `view()` is null and the review branch never runs.
    fx.app.file_index = 99;
    try testing.expect(fx.app.view(body_rows) == null);

    try fx.press("?");
    const hv = (try fx.app.help.view(fx.app.mode, fx.app.km.bindings, arena)).?;
    try testing.expect(hv.entries.len > 0);
    try testing.expect(hv.keys.len > 0);

    // And it still closes.
    try fx.press("<Esc>");
    try fx.expectMode(.normal);
    try testing.expect(try fx.app.help.view(fx.app.mode, fx.app.km.bindings, arena) == null);
}

// -- the file list, as the app drives it ---------------------------------

test "F opens the file list on the file the review is showing" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("]f");
    try fx.expectFile(1);
    try fx.press("<Space>f");
    try fx.expectMode(.finder);
    // Opened on the current file, so the list says where the reader is before
    // it offers to move them.
    try testing.expectEqual(@as(u32, 1), fx.app.file_list.selected(fx.app.files()).?);

    // The key that opened it does *not* close it: inside the overlay a
    // keystroke is filter text, letters included. Escape closes, the way it
    // does in the `?` overlay and in every prompt.
    try fx.press("b");
    try fx.expectMode(.finder);
    try testing.expectEqualStrings("b", fx.app.file_list.filter.text());
    try fx.press("<Esc>");
    try fx.expectMode(.normal);
    try fx.expectFile(1);
}

test "Enter jumps to the selected file, Escape leaves the review alone" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("<Space>f");
    try fx.press("J");
    try fx.press("<CR>");
    try fx.expectMode(.normal);
    try fx.expectFile(1);
    // A jump is a move to a different file, so the cursor starts at the top of
    // it rather than wherever the last file's cursor happened to be.
    try fx.expectCursor(fx.app.rows.firstLineRow());

    // Escape closes without moving.
    try fx.press("<Space>f");
    try fx.press("K");
    try fx.press("<Esc>");
    try fx.expectMode(.normal);
    try fx.expectFile(1);
}

test "keys under the file list filter it rather than reaching the review" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("j");
    const moved = fx.app.cursor;
    try fx.press("<Space>f");

    // `j` and `q` are a motion and a quit in the review; in here they are
    // letters, and the review must not move behind the overlay.
    try fx.typeIn("jq");
    try fx.expectCursor(moved);
    try testing.expect(!fx.app.quit);
    try testing.expectEqualStrings("jq", fx.app.file_list.filter.text());

    // The filter narrows what Enter would open, and a filter matching nothing
    // opens nothing rather than the wrong file.
    try fx.press("<CR>");
    try fx.expectFile(0);
    try fx.expectMode(.normal);
}

test "the file list filters by path and opens what it is showing" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("<Space>f");
    try fx.typeIn("b.z");
    try testing.expectEqual(@as(usize, 1), files_mod.count(fx.app.files(), fx.app.file_list.filter.text()));
    try fx.press("<CR>");
    try fx.expectFile(1);

    // Closing cleared the query, so `F` never reopens onto a stale filter.
    try fx.press("<Space>f");
    try testing.expectEqual(@as(usize, 0), fx.app.file_list.filter.text().len);
}

// -- search and the prompt -----------------------------------------------

test "search crosses into the next file and lands on the matching row" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("/");
    try fx.expectMode(.command);
    // Inside the prompt these are letters, not motions: `j` must not move.
    try fx.typeIn("token");
    try fx.expectCursor(1);
    try fx.press("<CR>");

    try fx.expectMode(.normal);
    try fx.expectFile(1);
    // Row 2 of b.zig: header, line 0, line 1.
    try fx.expectCursor(2);
    // Reaching the next file in order is not a wrap.
    try testing.expect(!fx.app.finder.wrapped);
}

test "search wraps past the end of the review and says so" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    fx.app.file_index = 1;
    try fx.app.rebuildRows(.reset);

    try fx.press("/");
    try fx.typeIn("alpha");
    try fx.press("<CR>");

    try fx.expectFile(0);
    try fx.expectCursor(1);
    try testing.expect(fx.app.finder.wrapped);
    try fx.expectNotice("wrapped");
}

test "n repeats the search and N reverses it" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    // `const` appears once per file, so stepping is observable.
    try fx.press("/");
    try fx.typeIn("const");
    try fx.press("<CR>");
    try fx.expectFile(0);
    try fx.expectCursor(2);

    try fx.press("n");
    try fx.expectFile(1);

    try fx.press("N");
    try fx.expectFile(0);
    try fx.expectCursor(2);
}

test "a search that finds nothing leaves the cursor put and says why" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    const before = fx.app.cursor;
    try fx.press("/");
    try fx.typeIn("nowhere");
    try fx.press("<CR>");

    try testing.expectEqual(before, fx.app.cursor);
    try testing.expect(fx.app.finder.failed);
    try fx.expectNotice("not found");
}

test "escaping a prompt returns to the mode it was opened from" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("V");
    try fx.press("/");
    try fx.typeIn("x");
    try fx.press("<Esc>");
    // A search abandoned mid-selection must not also abandon the selection.
    try fx.expectMode(.visual);
    try testing.expect(fx.app.selection() != null);
}

test ":q quits and anything else reports itself rather than vanishing" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press(":");
    try fx.typeIn("wq");
    try fx.press("<CR>");
    try testing.expect(!fx.app.quit);
    try fx.expectNotice(":wq");

    try fx.press(":");
    try fx.typeIn("q");
    try fx.press("<CR>");
    try testing.expect(fx.app.quit);
}

// -- zen, $EDITOR and notices --------------------------------------------

test "Tab toggles the chrome away and back" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    try testing.expect(!fx.app.zen);
    try fx.press("<Tab>");
    try testing.expect(fx.app.zen);
    try fx.press("<Tab>");
    try testing.expect(!fx.app.zen);
}

test "e targets the new-file line, and the hunk position on a deleted one" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    // Cursor on the first line of a.zig, which is new-file line 1.
    const t = fx.app.editTarget().?;
    try testing.expectEqualStrings("a.zig", t.path);
    try testing.expectEqual(@as(u32, 1), t.line);

    // A header carries no line, so there is nothing to open at.
    fx.app.cursor = 0;
    try testing.expectEqual(@as(u32, 0), fx.app.editTarget().?.line);

    var del = try Fixture.withDeletion(testing.allocator, 1);
    defer del.deinit();
    del.app.cursor = 2; // the deleted line
    // It has no line in the file on disk; the hunk's position is where the
    // deletion happened, which is the closest honest answer.
    try testing.expectEqual(@as(u32, 1), del.app.editTarget().?.line);
}

test "e sets a request rather than acting, because the loop owns the terminal" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    try testing.expect(!fx.app.want_editor);
    try fx.press("<Space>e");
    try testing.expect(fx.app.want_editor);
}

test "a notice lasts exactly one keystroke" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press(":");
    try fx.typeIn("nope");
    try fx.press("<CR>");
    try testing.expect(fx.app.notice.text().len > 0);

    try fx.press("j");
    try fx.expectNoNotice();
}

test "a notice too long to format is truncated rather than dropped" {
    var n: Notice = .{};
    var long: [512]u8 = undefined;
    @memset(&long, 'x');
    n.set("pattern not found: {s}", .{&long});
    try testing.expect(n.text().len > 0);
    try testing.expect(n.text().len <= n.buf.len);
}

// -- a new diff, and a new pane size -------------------------------------

test "keeping the row across a re-diff never parks the cursor on chrome" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    // Row 0 is the hunk header. A rebuild that keeps the row must not leave
    // the cursor there - which is exactly the first diff, where there is no
    // previous position and the kept row is 0.
    fx.app.cursor = 0;
    try fx.app.rebuildRows(.row);
    try fx.expectCursor(1);
    try testing.expect(fx.app.rows.lineAt(fx.app.cursor) != null);

    // A position further down is left exactly where it was.
    fx.app.cursor = 3;
    try fx.app.rebuildRows(.row);
    try fx.expectCursor(3);
}

test "a resize re-lays out rather than leaving the old scroll behind" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    // Four rows: header plus three lines. A pane that was tall enough to have
    // scrolled, then grew, must not keep an offset that now hangs the body
    // off the end of the review - the failure is a screen of blank rows with
    // the cursor nowhere on it.
    fx.app.cursor = 3;
    fx.app.scroll = 3;
    try fx.app.handle(.{ .resize = .{ .cols = 100, .rows = 40 } }, 22);
    try testing.expectEqual(@as(u32, 0), fx.app.scroll);

    // Shrinking to a body shorter than the review scrolls to keep the cursor
    // visible, and never past the last row.
    try fx.app.handle(.{ .resize = .{ .cols = 40, .rows = 6 } }, 2);
    try testing.expectEqual(@as(u32, 2), fx.app.scroll);
    try testing.expect(fx.app.cursor >= fx.app.scroll);
    try testing.expect(fx.app.cursor < fx.app.scroll + 2);

    // The cursor itself is the reader's place in the file and a resize is not
    // a motion: it does not move.
    try fx.expectCursor(3);
}

// -- the bridge ----------------------------------------------------------

test "Enter composes a reference to the line under the cursor" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("<CR>");
    // A request, not an action: the loop owns the terminal and the subprocess.
    try testing.expectEqual(App.Delivery.send, fx.app.want_send.?);
    try testing.expectEqualStrings("#1 a.zig:1", fx.app.payload());
}

test "a selection sends a range, and using it ends the selection" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("Vj");
    try testing.expectEqual(@as(u32, 2), fx.app.selection().?.count());
    try fx.press("<CR>");
    try testing.expectEqualStrings("#1 a.zig:1-2", fx.app.payload());

    // An operator consumes its range, the way it does in vim. Leaving the
    // rows highlighted invites sending the same lines twice.
    try testing.expect(fx.app.selection() == null);
    try testing.expectEqual(event.Mode.normal, fx.app.mode);
}

test "a one-row selection is a single line, not a range of one" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("V<CR>");
    try testing.expectEqualStrings("#1 a.zig:1", fx.app.payload());
}

test "y copies where Enter sends, and the payload is the same" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("y");
    try testing.expectEqual(App.Delivery.copy, fx.app.want_send.?);
    try testing.expectEqualStrings("#1 a.zig:1", fx.app.payload());
}

test "Y puts the lines under the reference, markers kept" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    // The marker is what says which side of the change a line is on; a mixed
    // range pasted without them reads as nonsense.
    try fx.press("Vj");
    try fx.press("Y");
    try testing.expectEqual(App.Delivery.copy, fx.app.want_send.?);
    try testing.expectEqualStrings(
        "#1 a.zig:1-2\n fn alpha() {\n     const x = 1;",
        fx.app.payload(),
    );
}

test "a deleted line points at its hunk and says why" {
    var fx = try Fixture.withDeletion(testing.allocator, 1);
    defer fx.deinit();

    // References resolve against the new file (SPEC.md 6.3). This line is not
    // in it, so the enclosing hunk is the closest honest answer - and the
    // agent is told that is what happened.
    fx.app.cursor = 2;
    try fx.press("<CR>");
    try testing.expectEqualStrings("#1 a.zig:1 (deleted lines in this hunk)", fx.app.payload());
}

test "a selection spanning a deletion keeps the lines that still exist" {
    var fx = try Fixture.withDeletion(testing.allocator, 1);
    defer fx.deinit();

    // Rows 1-3 are lines 1, deleted, 3. The range is what survives.
    fx.app.cursor = 1;
    try fx.press("Vjj");
    try fx.press("<CR>");
    try testing.expectEqualStrings("#1 a.zig:1-3", fx.app.payload());
}

test "the ask presets are the reference plus a question" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("a");
    try testing.expectEqualStrings("#1 a.zig:1 - why this approach?", fx.app.payload());
    try testing.expectEqual(App.Delivery.send, fx.app.want_send.?);

    try fx.press("<Space>t");
    try testing.expectEqualStrings("#1 a.zig:1 - add a test covering this", fx.app.payload());

    try fx.press("x");
    try testing.expectEqualStrings("#1 a.zig:1 - explain what this does", fx.app.payload());

    try fx.press("!");
    try testing.expectEqualStrings("#1 a.zig:1 - revert this, keep the rest", fx.app.payload());
}

test "nothing sent to the agent ever contains a newline" {
    // Hard rule 1, checked where the payload is built as well as where it is
    // sent: in `tmux send-keys` a newline is Enter, and Enter submits the
    // user's half-written message. `Y` is exempt by design - it is the
    // clipboard, which no send-keys ever sees.
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    for ([_][]const u8{ "<CR>", "y", "a", "!", "t", "x" }) |keys| {
        try fx.press("Vj");
        try fx.press(keys);
        try testing.expect(std.mem.indexOfScalar(u8, fx.app.payload(), '\n') == null);
    }
}

test "a change id follows the hunk, not the row" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    // The second file's hunk is #2, and its reference has to say so - the id
    // is what the user and the agent say to each other (SPEC.md 6.5).
    try fx.press("]f");
    try fx.press("<CR>");
    try testing.expectEqualStrings("#2 b.zig:1", fx.app.payload());
}

test "composing again replaces the payload rather than appending to it" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("<CR>");
    try fx.press("j");
    try fx.press("<CR>");
    try testing.expectEqualStrings("#1 a.zig:2", fx.app.payload());
}
