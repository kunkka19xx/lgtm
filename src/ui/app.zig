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
const fs_mod = @import("../io/fs.zig");
const git = @import("../core/git.zig");
const comments_mod = @import("../core/comments.zig");
const review_file = @import("../core/review.zig");
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
const compose_mod = @import("compose.zig");
const prompt_mod = @import("prompt.zig");
const render = @import("render.zig");
const gitobj = @import("../snapshot/gitobj.zig");
const snapshot = @import("../snapshot/snapshot.zig");
const timeline = @import("../snapshot/timeline.zig");
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

    /// The snapshot store, when there is an environment to run git in. Null in
    /// the fixtures, which have no environ and want none: everything it does is
    /// a subprocess, and a test that wanted one would be testing git.
    snap: ?snapshot.Store = null,
    /// Whether the mark has been looked for on disk yet. Once, after the first
    /// diff: before it there are no files to attach the marked bytes to, and
    /// after it a second look would undo whatever the reader has since marked.
    mark_restored: bool = false,

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
    /// The message being written, when one is. Seeded from the reference and
    /// whichever question opened it (`ui/compose.zig`).
    compose: compose_mod.Compose = .{},
    /// Where the composed message is going once Enter is pressed. Fixed when
    /// the box opens, because the key that opened it is what decided.
    compose_to: Delivery = .send,
    /// `[ui] compose`: where the box sits.
    compose_at: render.Placement = .bottom,
    /// Every note in the session. Session-lived and owning its own bytes, so
    /// a re-diff resetting the arena cannot take a remark with it (rule 4).
    comments: comments_mod.Store = undefined,
    /// What the compose box will do with what is typed: send it, or attach it
    /// to a line as a note. The box itself does not know or care.
    compose_comment: ?u32 = null,
    compose_is_comment: bool = false,
    /// How many reviews have been submitted this session, for the file name.
    review_n: u32 = 0,
    /// Whether the stored notes have been placed against the files as they
    /// are now. Once per session, on the first diff.
    comments_reconciled: bool = false,
    /// `[ui] notes`: whether a note's text is drawn under its line, or only
    /// its gutter marker is.
    comments_inline: bool = true,
    /// A file being read that has no diff at all. `<Space>d` on an unchanged
    /// file lands here: there is nothing for the review to show, but there is
    /// still a file to read and to write notes against, so it is rendered as
    /// every line being context. Outside the review by construction - it is
    /// not in `review.files()`, `]f` does not reach it, and the status row
    /// says so.
    preview: ?diff.FileDiff = null,
    preview_arena: std.heap.ArenaAllocator = undefined,
    /// The `Ctrl-i` list, open over the box. An index into `presets()`, or
    /// null while the box has the keyboard.
    preset_index: ?usize = null,
    /// What the file overlay is being used for. It is the same list, the same
    /// filter and the same drawing either way; only what happens on Enter
    /// differs, which is one field rather than a second overlay.
    /// Turn numbers behind the rows of the turn list, so the index the overlay
    /// hands back is the turn it names. Parallel to `pick_list` for the same
    /// reason the comment list's is: the widget lists labelled rows, and what
    /// a row *means* belongs to whoever built it.
    pick_turns: std.ArrayList(u32) = .empty,

    files_purpose: enum {
        /// `<Space>f`: the changed files, and Enter goes to one.
        jump,
        /// The timeline. `Enter` shows that turn, which is `[t` without the
        /// walking.
        turns,
        /// `@` in the box: every file, and Enter puts its path at the caret.
        mention,
        /// `<Space>d`: every file, and Enter does whichever of those two
        /// makes sense - there is nothing to show for a file with no diff, so
        /// picking one starts a message about it instead of a blank screen.
        browse,
        /// `<Space>lc`: every comment in the review, and Enter goes to one.
        comments,
    } = .jump,
    /// The list the overlay is showing: the changed files for a jump, every
    /// file git knows about for a mention. Rebuilt when the overlay opens and
    /// owned here, because `selected` is asked outside any frame.
    pick_list: std.ArrayList(render.FileEntry) = .empty,
    /// Backing store for the labels the comment overlay builds. Its own arena
    /// because the list outlives a frame: it is read by the filter on every
    /// keystroke, and the frame arena is reset between them - which made every
    /// label a slice of freed memory and every filter a miss.
    pick_arena: std.heap.ArenaAllocator = undefined,
    /// Every path in the project, from `git ls-files`, loaded the first time
    /// `@` asks and kept for the session. Not loaded at startup: most sessions
    /// never mention a file, and cold start has a 50 ms budget.
    project_paths: [][]const u8 = &.{},
    project_loaded: bool = false,
    /// Questions the box can insert, from `[presets]`. Empty falls back to the
    /// four built-in asks, so the list is never empty.
    presets_cfg: []const config.Preset = &.{},
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
            .comments = .init(gpa),
            .preview_arena = .init(gpa),
            .pick_arena = .init(gpa),
            .frame_arena = .init(gpa),
        };
    }

    pub fn deinit(self: *App) void {
        self.pick_turns.deinit(self.gpa);
        self.outgoing.deinit(self.gpa);
        self.review.deinit();
        self.pick_arena.deinit();
        self.preview_arena.deinit();
        self.comments.deinit();
        self.pick_list.deinit(self.gpa);
        if (self.project_paths.len > 0) git.freePaths(self.gpa, self.project_paths);
        self.frame_arena.deinit();
        self.* = undefined;
    }

    fn files(self: *App) []diff.FileDiff {
        return self.review.files();
    }

    fn current(self: *App) ?*diff.FileDiff {
        if (self.preview) |*p| return p;
        return self.review.fileAt(self.file_index);
    }

    /// Reads a file that is not in the review and shows it whole.
    ///
    /// Every line is context, because that is what it is: nothing changed.
    /// The body already renders a file with no hunks correctly, and a line
    /// with a `new_no` is all a note or a reference needs - so browsing,
    /// noting and pointing all work here for free. Syntax highlighting does
    /// not: the lexer runs over the review's own buffers, and this file is not
    /// one of them. The body falls back to unstyled, which is legible.
    fn openPreview(self: *App, path: []const u8) !void {
        _ = self.preview_arena.reset(.retain_capacity);
        const arena = self.preview_arena.allocator();

        const bytes = fs_mod.readFile(self.io, arena, path, 8 << 20) catch {
            // No notice here: every caller knows more about why it wanted the
            // file than "cannot read" does, and says something better.
            return;
        };

        var count: usize = 0;
        var scan = std.mem.splitScalar(u8, bytes, '\n');
        while (scan.next()) |_| count += 1;
        // A trailing newline ends the last line rather than starting an empty
        // one, the same way the diff parser counts.
        if (count > 0 and bytes.len > 0 and bytes[bytes.len - 1] == '\n') count -= 1;

        var lines: hunk.DiffLines = .{
            .kind = try arena.alloc(hunk.LineKind, count),
            .old_no = try arena.alloc(u32, count),
            .new_no = try arena.alloc(u32, count),
            .text = try arena.alloc([]const u8, count),
        };
        var it = std.mem.splitScalar(u8, bytes, '\n');
        var i: usize = 0;
        while (it.next()) |raw| {
            if (i >= count) break;
            lines.kind[i] = .context;
            lines.old_no[i] = @intCast(i + 1);
            lines.new_no[i] = @intCast(i + 1);
            lines.text[i] = std.mem.trimEnd(u8, raw, "\r");
            i += 1;
        }

        const p = try arena.dupe(u8, path);
        self.preview = .{
            .old_path = p,
            .new_path = p,
            .status = .modified,
            .hunks = &.{},
            .lines = lines,
        };
        try self.rebuildRows(.reset);
        self.cursor = 0;
        self.scroll = 0;
        self.notice.set("{s} - not in the review, {d} lines", .{ path, count });
    }

    /// Any move back into the review drops the preview: it was a detour, and
    /// leaving it visible while `]f` walks the changed files would be two
    /// different answers to "which file am I on".
    fn clearPreview(self: *App) void {
        if (self.preview == null) return;
        self.preview = null;
        self.rebuildRows(.reset) catch {};
    }

    /// A new generation, and the reader put back where they were. The work
    /// is `review.regenerate`; what is left here is the part that is about a
    /// reader rather than a diff.
    pub fn rediff(self: *App) !void {
        const span = metrics.span(.diff_parse);
        defer span.end();

        // The working-tree text of every file carrying a note, copied before
        // the arena that holds it is reset. Re-anchoring needs the old text
        // and the new one at the same moment (PERFORMANCE.md 3.1), and the old
        // one is about to stop existing.
        var before: std.ArrayList(struct { path: []u8, text: []u8 }) = .empty;
        defer {
            for (before.items) |b| {
                self.gpa.free(b.path);
                self.gpa.free(b.text);
            }
            before.deinit(self.gpa);
        }
        for (self.comments.items()) |n| {
            var seen = false;
            for (before.items) |b| {
                if (std.mem.eql(u8, b.path, n.path)) seen = true;
            }
            if (seen) continue;
            const work = self.review.buffersFor(n.path).work orelse continue;
            const p = self.gpa.dupe(u8, n.path) catch continue;
            const t = self.gpa.dupe(u8, work.bytes) catch {
                self.gpa.free(p);
                continue;
            };
            before.append(self.gpa, .{ .path = p, .text = t }) catch {
                self.gpa.free(p);
                self.gpa.free(t);
            };
        }

        self.file_index = try self.review.regenerate(.{
            .path = if (self.current()) |f| f.path() else null,
            .hunks = self.prev_hunks,
            .line = self.cursorLine(),
        });
        // The first diff of a session has no previous version to carry from:
        // the file may have been rewritten while lgtm was not running. The
        // stored anchor line is what places those notes, once.
        if (!self.comments_reconciled) {
            self.comments_reconciled = true;
            for (self.comments.items()) |n| {
                const work = self.review.buffersFor(n.path).work orelse continue;
                self.comments.reconcile(n.path, work.bytes);
            }
        }

        // Notes move with the code they were written against, or say they
        // could not (hard rule 7). Done here, on every re-diff, because that
        // is the only moment both versions of the file exist.
        for (before.items) |b| {
            const now = self.review.buffersFor(b.path).work orelse continue;
            self.comments.carry(b.path, b.text, now.bytes) catch {};
        }
        self.saveComments();

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

        // Notes are rows too, so the layout has to know about them before it
        // is built - that is what puts a remark under the line it belongs to
        // rather than over the top of it.
        var at: std.ArrayList(rows_mod.CommentAt) = .empty;
        defer at.deinit(self.gpa);
        if (self.comments_inline) {
            var i: u32 = 0;
            for (self.comments.items()) |n| {
                if (std.mem.eql(u8, n.path, f.path())) {
                    at.append(self.gpa, .{ .line = n.line, .index = i }) catch {};
                    i += 1;
                }
            }
        }
        self.rows = try rows_mod.buildWith(self.review.allocator(), f, at.items);
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
            .hidden = if (self.review.show_ignored) 0 else self.review.hidden,
            .notes = self.commentMarks(),
            .viewing = self.review.viewing,
            .newer_turns = if (self.snap) |s|
                (if (self.review.viewing) |t| s.state.latest_turn -| t else 0)
            else
                0,
            .fresh = self.review.freshFor(self.file_index),
            .fresh_total = self.review.freshCount(),
            .mark_turn = self.review.mark_at.turn,
            .preview = self.preview != null,
            .mode = self.mode,
            .zen = self.zen,
            .wrap = self.wrap,
            .selection = self.selection(),
            .prompt = if (self.prompt.open) .{
                .prefix = self.prompt.kind.prefix(),
                .text = self.prompt.text(),
            } else null,
            .notice = self.notice.text(),
            .query = self.liveQuery(),
            .compose = if (self.compose.open) self.composeView(self.frame_arena.allocator()) else null,
        };
    }

    /// The notes on the current file, for the gutter. Built into the frame
    /// arena: the body reads them this frame and nothing keeps them.
    fn commentMarks(self: *App) []const render.CommentMark {
        const f = self.current() orelse return &.{};
        var out: std.ArrayList(render.CommentMark) = .empty;
        const arena = self.frame_arena.allocator();
        for (self.comments.items()) |n| {
            if (!std.mem.eql(u8, n.path, f.path())) continue;
            out.append(arena, .{ .line = n.line, .body = n.body, .state = switch (n.state) {
                .open => .open,
                .sent => .sent,
                .stale => .stale,
            } }) catch return out.items;
        }
        return out.items;
    }

    /// The compose box as a view, for the callers that draw it without a
    /// `View` around it - the empty screen has no diff to build one from.
    pub fn composeView(self: *App, arena: Allocator) render.ComposeView {
        // The line a note is being written against, in the title. The store
        // holds it, so the body does not have to - and a note whose text
        // repeats its own line number would say it twice in `review-N.md`.
        var what: []const u8 = "compose";
        if (self.compose_is_comment) {
            what = if (self.commentLine()) |at|
                (if (at.deleted)
                    std.fmt.allocPrint(arena, "comment {s}:{d} - removed code", .{ at.path, at.line })
                else
                    std.fmt.allocPrint(arena, "comment {s}:{d}", .{ at.path, at.line })) catch "comment"
            else
                "comment";
        }
        return .{
            .what = what,
            .bindings = self.km.bindings,
            .text = self.compose.text(),
            .cursor = self.compose.cursor,
            .joins = compose_mod.hasBreak(self.compose.text()),
            .presets = if (self.preset_index != null) self.presetEntries() else &.{},
            .selected = self.preset_index,
            .to_agent = self.compose_to == .send,
            .at = self.compose_at,
            .saves = self.compose_is_comment,
            .normal = self.compose.mode == .normal,
        };
    }

    /// The presets as the popup lists them. Built into the frame arena, so
    /// the view holds no pointer that outlives the frame that drew it.
    fn presetEntries(self: *App) []const render.PresetEntry {
        const list = self.presets();
        const out = self.frame_arena.allocator().alloc(render.PresetEntry, list.len) catch return &.{};
        for (list, 0..) |p, i| out[i] = .{ .name = p.name, .text = p.text };
        return out;
    }

    /// The pattern the renderer highlights this frame.
    ///
    /// While a `/` prompt is open it is the text being typed, so matches light
    /// up as the query is built rather than only once Enter is pressed. That
    /// is vim's `incsearch`, and the reason it earns its place: you find out
    /// you have typed enough to be unambiguous *before* committing to it, and
    /// a query that matches nothing says so while there is still a keystroke
    /// left to fix it.
    ///
    /// A `:` prompt highlights nothing. Its text is a command, not a pattern,
    /// and painting `noh` across the diff while it is typed is exactly the
    /// noise this feature is supposed to reduce.
    fn liveQuery(self: *App) []const u8 {
        if (self.prompt.open and self.prompt.kind == .search_forward) {
            return self.prompt.text();
        }
        return self.finder.shown();
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
            .next_file => {
                self.clearPreview();
                try self.stepFile(1);
            },
            .prev_file => {
                self.clearPreview();
                try self.stepFile(-1);
            },
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
            .send_ref => try self.openCompose(.send, .ref),
            .comment_add => {
                if (self.readOnly()) return;
                try self.commentAdd();
            },
            .comment_view => try self.commentView(body),
            .comment_list => {
                if (self.mode == .finder) return self.closeFiles();
                if (self.comments.len() == 0) {
                    self.noComments();
                    return;
                }
                self.files_purpose = .comments;
                self.buildPickList();
                self.file_list.title = " comments ";
                // This list's own keys, and not the shared footer's: they do
                // nothing in the file or turn lists, and a footer naming a key
                // that does nothing is worse than a shorter one. Still read
                // from the keymap, so a remap moves them.
                self.file_list.extra_keys = self.commentListKeys(self.pick_arena.allocator());
                self.file_list.open(0);
                self.mode = .finder;
            },
            .comment_send => try self.commentSend(),
            .comment_send_one => try self.listSendOne(),
            .comment_send_all => {
                self.closeFiles();
                try self.submitReview();
                self.rebuildRows(.line) catch {};
            },
            .comment_drop => self.listDrop(),
            .comment_delete => self.commentDelete(),
            .next_comment => self.commentStep(1, body),
            .prev_comment => self.commentStep(-1, body),
            .submit_review => {
                if (self.readOnly()) return;
                try self.submitReview();
            },
            .compose_ask => {
                try self.openCompose(.send, .ref);
                self.preset_index = 0;
            },
            .clear_search => self.finder.hide(),
            .toggle_ignored => {
                self.review.show_ignored = !self.review.show_ignored;
                // A re-diff, not a filter: git is what applied the patterns,
                // so git is what has to be asked again without them.
                try self.rediff();
                self.clampScroll(body);
                if (self.review.show_ignored)
                    self.notice.set("showing ignored files", .{})
                else
                    self.notice.set("hiding ignored files again", .{});
            },
            // Deferring a large file was never meant to be where it stops.
            // The bytes are still in the generation's git output and
            // `core/diff.zig` can parse them; this is the key that asks.
            .expand_file => {
                const f = self.current() orelse return;
                if (!f.summarised) {
                    self.notice.set("this file is already open", .{});
                    return;
                }
                const changed = f.added + f.removed;
                if (self.review.expand(f.path()) catch false) {
                    // `.reset`: the reader was on the summary row, which was
                    // not a line, so there is no line to come back to. The top
                    // of the file is where opening one starts.
                    try self.rebuildRows(.reset);
                    self.clampScroll(body);
                    self.notice.set("opened - {d} changed lines", .{changed});
                } else {
                    self.notice.set("this file cannot be opened inline", .{});
                }
            },
            .collapse_file => {
                const f = self.current() orelse return;
                if (f.summarised) {
                    self.notice.set("this file is already folded", .{});
                    return;
                }
                if (!self.review.collapse(f.path())) {
                    self.notice.set("only a file too large to render folds", .{});
                    return;
                }
                // Forgetting it is not enough: git decided it was large, so
                // git is asked again, exactly as `zi` does with the ignore
                // patterns rather than filtering what is already parsed.
                try self.rediff();
                self.clampScroll(body);
                self.notice.set("folded", .{});
            },
            // "Since I last looked." Every re-diff after this compares the
            // working tree against what is recorded here, so the rows that
            // arrive later are the ones the reader has not read.
            .mark_here => {
                // Marking a turn as read would record a tree the reader is
                // looking at rather than the one they are responsible for.
                if (self.readOnly()) return;
                const n = self.files().len;
                try self.review.mark();
                // The same state, written down. `m` copies the working tree
                // into memory for this session and into a ref for the next
                // one; SNAPSHOTS.md 4 says the checkpoint and the snapshot are
                // one thing, so this is one keystroke doing one thing twice
                // rather than two states to keep in step.
                const kept = self.snapshotMark();
                self.notice.set("marked {d} file{s} as read{s}", .{
                    n,
                    if (n == 1) "" else "s",
                    if (kept) " - and saved, so it survives a restart" else "",
                });
            },
            // Back to reading the change as one whole thing. The mark never
            // hid anything, so this removes annotation rather than revealing
            // rows - which is why it is `M` next to `m` and not a view toggle.
            .clear_mark => {
                if (!self.review.mark_at.taken()) {
                    self.notice.set("no mark to drop", .{});
                    return;
                }
                self.review.unmark();
                self.notice.set("mark dropped - the whole change again", .{});
            },
            // Live only inside the box, which takes its keys in
            // `feedCompose` before the review's dispatch is reached.
            .compose_submit,
            .compose_cancel,
            .compose_send_now,
            .compose_presets,
            .compose_mention,
            .compose_newline,
            => {},
            .turn_list => {
                if (self.mode == .finder) return self.closeFiles();
                try self.openTurnList();
            },
            .next_turn => try self.turnStep(1, body),
            .prev_turn => try self.turnStep(-1, body),
            .next_fresh => try self.freshStep(1),
            .prev_fresh => try self.freshStep(-1),
            .copy_text => try self.yank(.selection),
            .copy_text_lines => try self.yank(.lines),
            .copy_ref => try self.buildPayload(.copy, .ref),
            .copy_ref_lines => try self.buildPayload(.copy, .ref_lines),
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
            .file_list => {
                self.clearPreview();
                self.toggleFiles();
            },
            .file_browse => {
                if (self.mode == .finder) return self.closeFiles();
                self.files_purpose = .browse;
                self.buildPickList();
                self.file_list.title = " every file ";
                self.file_list.extra_keys = &.{};
                self.file_list.open(0);
                self.mode = .finder;
            },
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
    /// Shuts the overlay and hands the keyboard back to whoever had it: the
    /// compose box when the list was opened from inside one, the diff
    /// otherwise.
    fn closeFiles(self: *App) void {
        self.file_list.close();
        self.mode = if (self.files_purpose != .jump and self.compose.open) .note_input else .normal;
        self.files_purpose = .jump;
    }

    /// The rows the overlay will show, for whichever job it was opened to do.
    ///
    /// A jump lists the changed files, because jumping to an unchanged one
    /// means nothing in a review. A mention lists every file git knows about -
    /// changed ones first, in review order, then the rest - because mentioning
    /// an unchanged file to an agent is the whole point of `@`, and the file
    /// you are looking at is the one you are most likely to name.
    fn buildPickList(self: *App) void {
        self.pick_list.clearRetainingCapacity();
        const changed = self.review.files();
        for (changed) |f| {
            self.pick_list.append(self.gpa, .{
                .path = f.path(),
                .added = f.added,
                .removed = f.removed,
                .status = f.status,
            }) catch return;
        }
        if (self.files_purpose == .comments) {
            // One row per comment, in store order, so the index the overlay
            // hands back is the comment it names. The label carries the file,
            // the line and the text, which means the filter reaches all three:
            // typing part of a remark finds it.
            self.pick_list.clearRetainingCapacity();
            _ = self.pick_arena.reset(.retain_capacity);
            const arena = self.pick_arena.allocator();
            for (self.comments.items()) |n| {
                var one: [256]u8 = undefined;
                const body = compose_mod.flatten(&one, n.body);
                // A stale or already-sent comment has no dot on screen - one
                // points at code that moved, the other has been handed over -
                // so a list showing four when two are visible has to say why.
                const label = switch (n.state) {
                    .open => std.fmt.allocPrint(arena, "{s}:{d}  {s}", .{ n.path, n.line, body }),
                    .sent => std.fmt.allocPrint(arena, "{s}:{d}  [sent] {s}", .{ n.path, n.line, body }),
                    .stale => std.fmt.allocPrint(arena, "{s}:{d}  [stale] {s}", .{ n.path, n.line, body }),
                } catch continue;
                self.pick_list.append(self.gpa, .{
                    .path = label,
                    .added = 0,
                    .removed = 0,
                    .in_review = false,
                }) catch return;
            }
            return;
        }
        if (self.files_purpose == .jump) return;

        self.loadProject();
        for (self.project_paths) |p| {
            // The changed ones are already at the top; git lists them again.
            var seen = false;
            for (changed) |f| {
                if (std.mem.eql(u8, f.path(), p)) {
                    seen = true;
                    break;
                }
            }
            if (seen) continue;
            // No counts: it is a path, not a change, and `+0 -0` beside it
            // would dress up a file that did not change as one that did.
            self.pick_list.append(self.gpa, .{ .path = p, .added = 0, .removed = 0, .in_review = false }) catch return;
        }
    }

    /// Best effort, once. A repository that cannot be listed leaves the
    /// mention list as the changed files, which is what it was before `@`
    /// reached further and is still useful.
    fn loadProject(self: *App) void {
        if (self.project_loaded) return;
        self.project_loaded = true;
        self.project_paths = git.projectFiles(self.gpa, self.io) catch &.{};
    }

    fn toggleFiles(self: *App) void {
        if (self.mode == .finder) {
            self.closeFiles();
        } else {
            self.files_purpose = .jump;
            self.buildPickList();
            self.file_list.title = " changed files ";
            self.file_list.extra_keys = &.{};
            self.file_list.open(files_mod.rowOf(self.pick_list.items, self.file_index));
            self.mode = .finder;
        }
    }

    fn moveList(self: *App, delta: i32) void {
        switch (self.mode) {
            .help => self.help.move(self.km.bindings, delta),
            .finder => self.file_list.move(self.pick_list.items, delta),
            else => {},
        }
    }

    fn pageList(self: *App, delta: i32) void {
        switch (self.mode) {
            .help => self.help.moveGroup(delta),
            .finder => self.file_list.movePage(self.pick_list.items, delta),
            else => {},
        }
    }

    /// Keys inside the file list are filter text, exactly as in the `?`
    /// overlay. `Enter` jumps to the selected file, which is the whole point
    /// of the list and the one thing it does that `?` does not.
    fn feedFiles(self: *App, key: event.Key, body: u16) !void {
        // `<C-d>` clears the highlighted comment out of the list. It has to be
        // a chord: every printable key in this overlay is a filter character,
        // and a comment on a file that no longer exists cannot be reached to
        // be deleted any other way.
        switch (self.km.feed(key, .finder)) {
            .command => |cmd| return self.run(cmd, body),
            .pending, .none => {},
        }
        switch (self.file_list.feed(key)) {
            .stay => {},
            .close => self.closeFiles(),
            .open => {
                const picked = self.file_list.selected(self.pick_list.items);
                if (self.files_purpose == .turns) {
                    const i = picked orelse {
                        self.closeFiles();
                        return;
                    };
                    const want: u32 = if (i < self.pick_turns.items.len)
                        self.pick_turns.items[i]
                    else
                        std.math.maxInt(u32);
                    self.closeFiles();
                    try self.showTurnNumber(want, body);
                    return;
                }
                if (self.files_purpose == .comments) {
                    const i = picked orelse {
                        self.closeFiles();
                        return;
                    };
                    const list = self.comments.items();
                    var want_path: [4096]u8 = undefined;
                    var want_line: u32 = 0;
                    var have = false;
                    if (i < list.len) {
                        const n = list[i];
                        @memcpy(want_path[0..n.path.len], n.path);
                        want_line = n.line;
                        have = true;
                        self.closeFiles();
                        try self.showComment(want_path[0..n.path.len], want_line, body);
                        return;
                    }
                    self.closeFiles();
                    self.clampScroll(body);
                    return;
                }
                if (self.files_purpose == .browse) {
                    const i = picked orelse {
                        self.closeFiles();
                        return;
                    };
                    const e = self.pick_list.items[i];
                    if (e.in_review) {
                        // It is in the review, so show it: that is what the
                        // reader asked for by picking a file with a diff.
                        self.clearPreview();
                        for (self.review.files(), 0..) |f, fi| {
                            if (!std.mem.eql(u8, f.path(), e.path)) continue;
                            if (fi != self.file_index) {
                                self.file_index = @intCast(fi);
                                try self.rebuildRows(.reset);
                            }
                            break;
                        }
                        self.closeFiles();
                        self.clampScroll(body);
                        return;
                    }
                    // Nothing changed in it, so the review has nothing to
                    // show - but the file is still there to read. Opened
                    // whole, every line context, outside the review.
                    var buf: [4096]u8 = undefined;
                    const p = std.fmt.bufPrint(&buf, "{s}", .{e.path}) catch e.path;
                    self.closeFiles();
                    try self.openPreview(p);
                    self.clampScroll(body);
                    return;
                }
                if (self.files_purpose == .mention) {
                    // The path lands at the caret, straight after the `@` that
                    // opened the list, and nothing else is touched.
                    if (picked) |i| self.compose.insert(self.pick_list.items[i].path);
                    self.closeFiles();
                    return;
                }
                if (picked) |i| {
                    if (i != self.file_index) {
                        self.file_index = i;
                        try self.rebuildRows(.reset);
                    }
                }
                self.closeFiles();
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
        // Every spelling vim answers to, because the muscle memory is for
        // whichever one the reader happens to have learned.
        if (std.mem.eql(u8, cmd, "noh") or std.mem.eql(u8, cmd, "nohl") or
            std.mem.eql(u8, cmd, "nohlsearch"))
        {
            self.finder.hide();
            return;
        }
        // The same shape as `:noh`, for the same reason: a reader who wants
        // the highlighting gone reaches for a colon command before they go
        // looking for which key drops it.
        if (std.mem.eql(u8, cmd, "nomark") or std.mem.eql(u8, cmd, "nom")) {
            self.review.unmark();
            self.notice.set("mark dropped - the whole change again", .{});
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
        // `n` after `:noh` paints again, which is what vim does: the reader
        // asked to be shown the next one.
        self.finder.show();

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
        // Three shapes, twice: with a change id for a file in the review, and
        // without for one being read outside it. The `#id` is a claim that
        // this hunk changed, so a file with no hunks does not get one.
        const tmpl = if (r.line == 0)
            self.templates.ref_file
        else if (r.change_id == hunk.no_id)
            (if (r.end != 0)
                self.templates.ref_file_range
            else if (r.span.len > 0)
                self.templates.ref_file_span
            else
                self.templates.ref_file_line)
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
    /// How much of the line a yank takes.
    const Extent = enum {
        /// What is actually selected: the characters under a charwise
        /// selection, the whole lines under a linewise one.
        selection,
        /// Whole lines regardless, which is what vim's `Y` does to a charwise
        /// selection.
        lines,
    };

    /// `y` and `Y`: the selected text itself, onto the clipboard.
    ///
    /// This is the vim key doing the vim thing, and it is separate from
    /// `<leader>y` on purpose. `y` used to copy a *reference* - the text
    /// wrapped in `#3 path:47` - which is what the tool is for but not what
    /// the most-known key in vim means. The surprise was silent: nothing looks
    /// wrong until the paste lands somewhere else, and by then the selection
    /// is gone. Pointing at code has its own key and always did (`Enter`), so
    /// `y` does not need to carry it too.
    ///
    /// Newlines are fine here. Hard rule 1 is about what `send-keys` does with
    /// one, and this never reaches `send-keys`: `y` is the clipboard whatever
    /// the backend is.
    fn yank(self: *App, extent: Extent) Allocator.Error!void {
        const f = self.current() orelse {
            self.notice.set("nothing here to yank", .{});
            return;
        };
        const sel = self.selection();
        const lo = if (sel) |s| s.lo else self.cursor;
        const hi = if (sel) |s| s.hi else self.cursor;

        self.outgoing.clearRetainingCapacity();
        var rows: u32 = 0;
        var row = lo;
        while (row <= hi) : (row += 1) {
            const li = self.rows.lineAt(row) orelse continue;
            if (li >= f.lines.len()) continue;
            const text = f.lines.text[li];

            // The diff's sign column is lgtm's, not the file's: a yanked line
            // pasted into an editor should compile, so the `+` goes nowhere.
            const part = if (extent == .selection and sel != null) blk: {
                const span = sel.?.span(row, @intCast(text.len)) orelse break :blk "";
                break :blk text[span.lo..span.hi];
            } else text;

            if (rows > 0) try self.outgoing.append(self.gpa, '\n');
            try self.outgoing.appendSlice(self.gpa, part);
            rows += 1;
        }

        if (self.outgoing.items.len == 0) {
            self.notice.set("nothing here to yank", .{});
            return;
        }
        self.want_send = .copy;
        if (self.mode == .visual) self.leaveVisual();
    }

    /// The four built-ins, for a config with no `[presets]` of its own. The
    /// same questions the ask keys send, because someone who liked them
    /// enough to bind a key to them will want them in the box too.
    fn presets(self: *App) []const config.Preset {
        if (self.presets_cfg.len > 0) return self.presets_cfg;
        return &.{
            .{ .name = "why", .text = "why this approach?" },
            .{ .name = "revert", .text = "revert this, keep the rest" },
            .{ .name = "test", .text = "add a test covering this" },
            .{ .name = "explain", .text = "explain what this does" },
        };
    }

    /// Opens the compose box on what `compose` would have sent outright.
    ///
    /// Every send goes through here now. A fixed string was the wrong shape
    /// for the thing being said: "why this approach?" is the first half of a
    /// sentence, and the second half - the part that says *what* looked wrong
    /// - had nowhere to go. The reference and the question are the seed, the
    /// caret is past them, and Enter is still what sends.
    fn openCompose(self: *App, how: Delivery, what: What) Allocator.Error!void {
        // With nothing to review there is nothing to point at, and the box
        // opens empty rather than refusing. A clean tree is where a pane
        // spends most of its day (`ui/splash.zig`), and "talk to the agent"
        // is a thing to want there - having to make a change first before the
        // tool would let you type is the tail wagging the dog.
        if (self.current() == null) {
            self.outgoing.clearRetainingCapacity();
            self.want_send = null;
            self.compose_to = how;
            self.compose.start("");
            self.preset_index = null;
            self.mode = .note_input;
            return;
        }
        // The seed is the reference and nothing else, whichever key opened the
        // box. A canned question typed in for you is a sentence you now have
        // to read and mostly delete - and the presets have their own key
        // (`Ctrl-i`), which puts them in when they are wanted rather than
        // before anyone has decided.
        _ = what;
        try self.buildPayload(how, .ref);
        // `compose` sets `want_send`; the box is what decides now, so take it
        // back and hold the delivery until Enter.
        self.want_send = null;
        self.compose_to = how;
        self.compose.start(self.outgoing.items);
        self.preset_index = null;
        self.mode = .note_input;
    }

    // -- notes ---------------------------------------------------------------

    /// The line the cursor points at, as the note store counts them: the new
    /// file's line, which is what survives a re-diff and what a reference
    /// names. Null on a row that is chrome, or a line that exists only in HEAD.
    const Spot2 = struct { path: []const u8, line: u32, deleted: bool = false };

    /// The text of a new-file line, for the anchor a comment carries across a
    /// restart. It has to be the line the comment *attached* to, not the one
    /// the cursor was on: a deleted line's text is not in the new file, so an
    /// anchor taken from it would find nothing and go stale immediately.
    fn textOfNewLine(self: *App, line: u32) []const u8 {
        const f = self.current() orelse return "";
        var i: u32 = 0;
        while (i < f.lines.len()) : (i += 1) {
            if (f.lines.new_no[i] == line) return f.lines.text[i];
        }
        return "";
    }

    /// Where a comment written here would attach.
    ///
    /// A deleted line has no line in the new file, and the store anchors to
    /// new-file lines - so a remark about removed code used to be refused
    /// outright. It attaches to the enclosing hunk instead, on the first line
    /// of it that still exists, and is marked as being about the removal so
    /// the review file and the box say which. Refusing was the honest answer
    /// to the wrong question: "why did you take this out" is a thing a
    /// reviewer says constantly.
    fn commentLine(self: *App) ?Spot2 {
        const f = self.current() orelse return null;
        const li = self.rows.lineAt(self.cursor) orelse return null;
        if (li >= f.lines.len()) return null;
        const no = f.lines.new_no[li];
        if (no != 0) return .{ .path = f.path(), .line = no };

        // On a deletion: the first surviving line of the hunk it sits in.
        const hi = self.rows.hunkAt(self.cursor) orelse return null;
        if (hi >= f.hunks.len) return null;
        const h = f.hunks[hi];
        var i = h.lo;
        while (i < h.hi) : (i += 1) {
            if (i < f.lines.len() and f.lines.new_no[i] != 0) {
                return .{ .path = f.path(), .line = f.lines.new_no[i], .deleted = true };
            }
        }
        // A hunk that is nothing but deletions has no surviving line at all.
        // `new_start` is where the removed code used to begin, which is the
        // only place left to point at.
        if (h.new_start == 0) return null;
        return .{ .path = f.path(), .line = h.new_start, .deleted = true };
    }

    /// `c`: the compose box, pointed at a line instead of at the agent.
    fn commentAdd(self: *App) Allocator.Error!void {
        const at = self.commentLine() orelse {
            self.notice.set("nothing here to comment on", .{});
            return;
        };
        _ = at;
        self.compose_is_comment = true;
        self.compose_comment = null;
        self.compose_to = .copy;
        self.outgoing.clearRetainingCapacity();
        self.compose.start("");
        self.preset_index = null;
        self.mode = .note_input;
    }

    /// The same box, seeded with what the comment already says.
    fn commentEdit(self: *App) Allocator.Error!void {
        const n = self.commentUnderCursor() orelse {
            self.notice.set("no comment here", .{});
            return;
        };
        self.compose_is_comment = true;
        self.compose_comment = n.id;
        self.compose_to = .copy;
        self.compose.start(n.body);
        self.preset_index = null;
        self.mode = .note_input;
    }

    /// The note the cursor is pointing at: the one on this line, or the one
    /// whose own row the cursor is sitting on. Both are "this note" to a
    /// reader looking at it, and only one of them was reachable before.
    fn commentUnderCursor(self: *App) ?*comments_mod.Comment {
        const f = self.current() orelse return null;
        if (self.cursor < self.rows.len()) {
            if (self.rows.items[self.cursor] == .note) {
                const ni = self.rows.items[self.cursor].note;
                var i: u32 = 0;
                for (self.comments.list.items) |*n| {
                    if (!std.mem.eql(u8, n.path, f.path())) continue;
                    if (i == ni) return n;
                    i += 1;
                }
                return null;
            }
        }
        const at = self.commentLine() orelse return null;
        return self.comments.at(at.path, at.line);
    }

    /// `<Space>vc`: the nearest note, opened to read and edit.
    ///
    /// Nearest rather than "the one under the cursor", because the reader
    /// asking to see a note is usually near it rather than on it - the marker
    /// caught their eye a few lines away. The one under the cursor still wins
    /// when there is one.
    fn commentView(self: *App, body: u16) !void {
        if (self.commentUnderCursor() != null) return self.commentEdit();

        const f = self.current() orelse {
            self.noComments();
            return;
        };
        const here = if (self.commentLine()) |at| at.line else 0;

        var best: ?u32 = null;
        for (self.comments.items()) |n| {
            if (!std.mem.eql(u8, n.path, f.path())) continue;
            if (best == null or dist(n.line, here) < dist(best.?, here)) best = n.line;
        }
        const line = best orelse {
            // None in this file. The review-wide walk is what reaches the
            // rest, and saying so beats silently jumping the reader elsewhere.
            if (self.comments.len() == 0)
                self.noComments()
            else
                self.notice.set("no comments in this file - `]c` finds the next one", .{});
            return;
        };
        _ = self.gotoNewLine(line);
        self.clampScroll(body);
        try self.commentEdit();
    }

    /// The comment the overlay is highlighting, or null when it is not the
    /// comment overlay that is open.
    fn listSelected(self: *App) ?*comments_mod.Comment {
        if (self.files_purpose != .comments) return null;
        const i = self.file_list.selected(self.pick_list.items) orelse return null;
        const list = self.comments.list.items;
        return if (i < list.len) &list[i] else null;
    }

    /// Send the highlighted comment straight from the list, without a detour
    /// through the box: the list is where a reader decides what still needs
    /// saying, so it is where saying it should be possible.
    fn listSendOne(self: *App) !void {
        const n = self.listSelected() orelse return;
        var buf: [compose_mod.max_bytes]u8 = undefined;
        var flat: [compose_mod.max_bytes]u8 = undefined;
        const one = compose_mod.flatten(&flat, n.body);
        const line = std.fmt.bufPrint(&buf, "{s}:{d} - {s}", .{ n.path, n.line, one }) catch one;
        n.state = .sent;
        self.comments.dirty = true;

        self.closeFiles();
        self.outgoing.clearRetainingCapacity();
        try self.outgoing.appendSlice(self.gpa, line);
        self.want_send = .send;
        self.saveComments();
        self.rebuildRows(.line) catch {};
    }

    fn listDrop(self: *App) void {
        const n = self.listSelected() orelse return;
        self.comments.remove(n.id);
        self.saveComments();
        self.buildPickList();
        self.rebuildRows(.line) catch {};
        if (self.comments.len() == 0) {
            self.closeFiles();
            self.notice.set("comment deleted - none left", .{});
            return;
        }
        self.notice.set("comment deleted", .{});
    }

    /// `<Space>sc`: this one comment, into the compose box, ready to send.
    ///
    /// `<C-s>` is the other direction - every open comment as one file, which
    /// is the batch the tool is built around. This is for the remark that
    /// cannot wait for the batch: one line, the reference and the text, into
    /// the box where it can be edited before it goes.
    fn commentSend(self: *App) !void {
        const n = self.commentUnderCursor() orelse {
            self.notice.set("no comment here", .{});
            return;
        };
        var buf: [compose_mod.max_bytes]u8 = undefined;
        var flat: [compose_mod.max_bytes]u8 = undefined;
        const body = compose_mod.flatten(&flat, n.body);
        const seed = std.fmt.bufPrint(&buf, "{s}:{d} - {s}", .{ n.path, n.line, body }) catch n.body;

        self.compose_is_comment = false;
        self.compose_comment = null;
        self.compose_to = .send;
        self.compose.start(seed);
        self.preset_index = null;
        self.mode = .note_input;
    }

    fn commentDelete(self: *App) void {
        const n = self.commentUnderCursor() orelse {
            self.notice.set("no comment here", .{});
            return;
        };
        self.comments.remove(n.id);
        self.saveComments();
        self.rebuildRows(.line) catch {};
        self.notice.set("comment deleted", .{});
    }

    fn dist(a: u32, b: u32) u32 {
        return if (a > b) a - b else b - a;
    }

    /// Puts the cursor on the row carrying a given new-file line, and says
    /// whether there was one.
    ///
    /// There often is not. The diff draws hunks, not files, so a line the
    /// reader commented on can stop being drawn when the change around it is
    /// reverted or re-shaped - the comment is still perfectly valid, and the
    /// row it used to sit on is gone.
    fn gotoNewLine(self: *App, line: u32) bool {
        const f = self.current() orelse return false;
        var row: u32 = 0;
        while (row < self.rows.len()) : (row += 1) {
            const li = self.rows.lineAt(row) orelse continue;
            if (li < f.lines.len() and f.lines.new_no[li] == line) {
                self.moveTo(row);
                return true;
            }
        }
        return false;
    }

    /// Shows a comment wherever it is: on its row in the diff when the line is
    /// still drawn, and in the file itself when it is not.
    ///
    /// Falling back to the whole file rather than reporting failure, because
    /// the reader picked a comment out of a list and "nothing happened" is the
    /// one answer that tells them nothing. `<Space>d` already reads a file
    /// outside the review; this is the same view, opened at a line.
    fn showComment(self: *App, path: []const u8, line: u32, body: u16) !void {
        for (self.review.files(), 0..) |f, fi| {
            if (!std.mem.eql(u8, f.path(), path)) continue;
            self.clearPreview();
            if (fi != self.file_index) {
                self.file_index = @intCast(fi);
                try self.rebuildRows(.reset);
            }
            if (self.gotoNewLine(line)) {
                self.clampScroll(body);
                return;
            }
            break;
        }
        // Not in the review, or in it but no longer drawn: read the file.
        var buf: [4096]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "{s}", .{path}) catch path;
        try self.openPreview(p);
        if (self.preview == null) {
            // The file itself has gone - renamed, deleted, or never on this
            // branch. That is exactly what stale means, so the comment says so
            // rather than being lost or silently pointing at nothing. It stays
            // in the list, where `<C-d>` can clear it out (rule 7: the reader
            // decides when a remark stops mattering, not the tool).
            if (self.comments.at(path, line)) |n| {
                if (n.state != .stale) {
                    n.state = .stale;
                    self.comments.dirty = true;
                    self.saveComments();
                }
            }
            var key: [32]u8 = undefined;
            self.notice.set("{s} is gone - comment marked stale, {s} in the list deletes it", .{
                path, self.keyFor(.comment_drop, .finder, &key),
            });
            return;
        }
        _ = self.gotoNewLine(line);
        self.clampScroll(body);
        self.notice.set("{s}:{d} - not in the diff, showing the file", .{ path, line });
    }

    /// `]c` / `[c`: the next note anywhere in the review, the way `]h` walks
    /// hunks. Notes are why the tool exists; stopping at a file boundary would
    /// leave the key unable to reach most of them.
    fn commentStep(self: *App, delta: i32, body: u16) void {
        if (self.comments.len() == 0) {
            self.noComments();
            return;
        }

        // Every comment, not only the ones on files the review contains. A
        // comment outlives the change it was written against - the agent
        // reverts something, the hunk goes, the remark stays - and a walk that
        // could not reach those was a walk that hid them.
        const here = self.spotHere();
        var best: ?Spot = null;
        for (self.comments.items()) |n| {
            const at = self.spotOf(n);
            const after = lessSpot(here, at);
            const before_it = lessSpot(at, here);
            if (delta > 0 and !after) continue;
            if (delta < 0 and !before_it) continue;
            if (best) |b| {
                const closer = if (delta > 0) lessSpot(at, b) else lessSpot(b, at);
                if (!closer) continue;
            }
            best = at;
        }

        // Nothing further that way, so come round - a review is a ring, and
        // `]h` and `]f` already read that way.
        const target = best orelse blk: {
            var edge: ?Spot = null;
            for (self.comments.items()) |n| {
                const at = self.spotOf(n);
                if (edge) |e| {
                    const further = if (delta > 0) lessSpot(at, e) else lessSpot(e, at);
                    if (!further) continue;
                }
                edge = at;
            }
            const e = edge orelse return;
            self.notice.set("wrapped to the {s} comment", .{if (delta > 0) "first" else "last"});
            break :blk e;
        };

        var path_buf: [4096]u8 = undefined;
        @memcpy(path_buf[0..target.path.len], target.path);
        self.showComment(path_buf[0..target.path.len], target.line, body) catch return;
    }

    /// Where a comment sits in the order `]c` walks: the review's files first,
    /// in review order, then everything else by path. `line` breaks the tie.
    const Spot = struct { bucket: u8, fi: u32, path: []const u8, line: u32 };

    fn spotOf(self: *App, n: comments_mod.Comment) Spot {
        for (self.review.files(), 0..) |f, i| {
            if (std.mem.eql(u8, f.path(), n.path)) {
                return .{ .bucket = 0, .fi = @intCast(i), .path = n.path, .line = n.line };
            }
        }
        return .{ .bucket = 1, .fi = 0, .path = n.path, .line = n.line };
    }

    /// Where the cursor is, in the same order, so "next" means next from here.
    fn spotHere(self: *App) Spot {
        const f = self.current() orelse return .{ .bucket = 0, .fi = 0, .path = "", .line = 0 };
        const line = if (self.commentLine()) |at| at.line else 0;
        if (self.preview != null) return .{ .bucket = 1, .fi = 0, .path = f.path(), .line = line };
        return .{ .bucket = 0, .fi = self.file_index, .path = f.path(), .line = line };
    }

    fn lessSpot(a: Spot, b: Spot) bool {
        if (a.bucket != b.bucket) return a.bucket < b.bucket;
        if (a.bucket == 0 and a.fi != b.fi) return a.fi < b.fi;
        if (a.bucket == 1) {
            const c = std.mem.order(u8, a.path, b.path);
            if (c != .eq) return c == .lt;
        }
        return a.line < b.line;
    }

    /// `Ctrl-s`: the review as one file, and one line telling the agent where
    /// it is. The point of collecting notes rather than sending each: a dozen
    /// remarks is a dozen interruptions, or it is one file.
    fn submitReview(self: *App) !void {
        if (self.comments.openCount() == 0) {
            self.notice.set("no open comments to submit", .{});
            return;
        }
        self.review_n += 1;

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        const written = try review_file.render(&out, self.gpa, &self.comments, self.review_n);

        var buf: [64]u8 = undefined;
        const rel = review_file.path(&buf, self.review_n);
        fs_mod.writeStateFile(self.io, rel, out.items) catch {
            self.notice.set("could not write {s}", .{rel});
            self.review_n -= 1;
            return;
        };
        self.comments.markSent();
        self.saveComments();

        // Handing the review over is the one moment the reader has
        // demonstrably read all of it, so it is where the mark belongs: what
        // the agent does next is exactly what `]n` should walk. Taken after
        // the file is written, so a failed write does not mark a review that
        // was never sent - and not on `<Space>sc`, which sends one remark and
        // claims nothing about the rest.
        if (self.nav.mark_on_submit) self.review.mark() catch {};

        // One line, no newline in it: hard rule 1, and the reason the notes
        // themselves may be as long as they like.
        self.outgoing.clearRetainingCapacity();
        var line_buf: [256]u8 = undefined;
        const one = std.fmt.bufPrint(&line_buf, "review ready: {s} ({d} comment{s})", .{
            rel, written, if (written == 1) "" else "s",
        }) catch rel;
        try self.outgoing.appendSlice(self.gpa, one);
        self.want_send = .send;
    }

    pub fn saveComments(self: *App) void {
        if (!self.comments.dirty) return;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        comments_mod.write(&out, self.gpa, &self.comments) catch return;
        fs_mod.writeStateFile(self.io, ".lgtm/comments.jsonl", out.items) catch return;
        self.comments.dirty = false;
    }

    pub fn loadComments(self: *App) void {
        // `.lgtm/notes.jsonl` is the name this file had before the feature was
        // called comments. Read once and it is written back under the new
        // name: renaming a concept should not lose a reader's remarks.
        const text = fs_mod.readFile(self.io, self.gpa, ".lgtm/comments.jsonl", 1 << 20) catch
            fs_mod.readFile(self.io, self.gpa, ".lgtm/notes.jsonl", 1 << 20) catch return;
        defer self.gpa.free(text);
        comments_mod.read(&self.comments, text) catch {};
        if (self.comments.len() > 0 and !fs_mod.fileExists(self.io, ".lgtm/comments.jsonl")) {
            self.comments.dirty = true;
            self.saveComments();
        }
    }

    fn closeCompose(self: *App) void {
        self.compose.close();
        self.preset_index = null;
        self.mode = .normal;
    }

    /// One keystroke inside the box, or inside the preset list floating over
    /// it. Text, not actions, so it never reaches the keymap.
    fn feedCompose(self: *App, key: event.Key, body: u16) !void {
        if (self.preset_index) |idx| return self.feedPresets(key, idx);

        // The box's own keys come from the keymap, like every other key in the
        // tool. Text and the motions over it do not, and cannot: in a box every
        // printable key is data, so a keymap able to bind `x` would be a keymap
        // able to take `x` away from typing.
        //
        // A pending operator outranks all of it. With `d` waiting, the next key
        // is that operator's motion and `<Esc>` cancels the operator - a
        // binding firing there would make `d<Esc>` throw away a half-written
        // message, which is the opposite of what `<Esc>` means in vim.
        if (!self.compose.hasPending()) {
            if (self.composeCommand(key)) |cmd| return self.composeDo(cmd, key, body);
        }
        _ = self.compose.feed(key);
    }

    /// The single-chord binding for `key` inside the box, if there is one.
    ///
    /// Single chords only, deliberately: a box cannot hold a prefix waiting to
    /// see whether a sequence completes, because the key after it is usually a
    /// letter someone is typing. A multi-chord binding in `compose` mode is
    /// therefore ignored rather than half-honoured.
    fn composeCommand(self: *App, key: event.Key) ?keymap.Command {
        for (self.km.bindings) |b| {
            if (!b.modes.has(.note_input) or b.chords.len != 1) continue;
            const ch = b.chords[0];
            if (ch.cp == key.codepoint and ch.ctrl == key.mods.ctrl) return b.command;
        }
        return null;
    }

    fn composeDo(self: *App, cmd: keymap.Command, key: event.Key, body: u16) !void {
        switch (cmd) {
            .compose_cancel => {
                // One level at a time: out of insert, then out of the box.
                if (self.compose.mode == .insert) {
                    self.compose.toNormal();
                    return;
                }
                self.compose_is_comment = false;
                self.compose_comment = null;
                self.closeCompose();
            },
            .compose_presets => self.preset_index = 0,
            .compose_newline => self.compose.insert("\n"),
            .compose_mention => {
                // Only while typing: in normal mode the key is a motion's, and
                // the picker would be a surprise rather than an offer.
                if (self.compose.mode != .insert) return;
                // The character goes in first, when it is one: a picker that is
                // cancelled leaves the `@` that was typed, because it was
                // typed. A binding moved onto a control key inserts nothing,
                // because there is nothing to insert.
                if (!key.mods.ctrl and key.codepoint >= 0x20) {
                    var utf8: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(key.codepoint, &utf8) catch 0;
                    if (n > 0) self.compose.insert(utf8[0..n]);
                }
                // The compose box stays open underneath: the picker is a
                // layer over it, not a place the reader has gone instead.
                self.files_purpose = .mention;
                self.buildPickList();
                self.file_list.title = " mention a file ";
                self.file_list.extra_keys = &.{};
                self.file_list.open(0);
                self.mode = .finder;
            },
            .compose_send_now => try self.composeSendNow(body),
            .compose_submit => try self.composeSubmit(body),
            else => {},
        }
    }

    /// `<C-s>` from inside a comment: save it *and* send it, so a remark
    /// that cannot wait for the batch does not have to be typed, saved,
    /// found again and sent. It is the same key that submits the whole
    /// review from normal mode, which reads as "hand this over" either way.
    fn composeSendNow(self: *App, body: u16) !void {
        if (self.compose_is_comment) {
            var raw_buf: [compose_mod.max_bytes]u8 = undefined;
            const typed = self.compose.text();
            @memcpy(raw_buf[0..typed.len], typed);
            const raw = raw_buf[0..typed.len];
            if (raw.len == 0) {
                self.notice.set("nothing to save", .{});
                return;
            }
            const editing = self.compose_comment;
            const at = self.commentLine();
            self.compose_is_comment = false;
            self.compose_comment = null;
            self.closeCompose();

            var id: u32 = 0;
            if (editing) |eid| {
                try self.comments.edit(eid, raw);
                id = eid;
            } else if (at) |spot| {
                id = try self.comments.addFull(spot.path, spot.line, raw, self.textOfNewLine(spot.line), spot.deleted);
            }
            self.saveComments();
            self.rebuildRows(.line) catch {};
            if (self.comments.find(id)) |n| {
                // Handed over, so it is sent: it drops out of the next
                // `review-N.md` rather than asking twice, and editing it
                // reopens it the way editing any sent comment does.
                n.state = .sent;
                self.comments.dirty = true;
                self.saveComments();
                var buf: [compose_mod.max_bytes]u8 = undefined;
                var flat: [compose_mod.max_bytes]u8 = undefined;
                const one = compose_mod.flatten(&flat, n.body);
                const line = std.fmt.bufPrint(&buf, "{s}:{d} - {s}", .{ n.path, n.line, one }) catch one;
                self.outgoing.clearRetainingCapacity();
                try self.outgoing.appendSlice(self.gpa, line);
                self.want_send = .send;
            }
            self.clampScroll(body);
            return;
        }
        // Not a comment: the key means the same thing the plain send does.
        try self.composeSubmit(body);
    }

    fn composeSubmit(self: *App, body: u16) !void {
        {
            {
                // Flattened here and nowhere else: hard rule 1 is about what
                // `send-keys` does with a newline, and this is the last point
                // where one can still exist.
                var flat: [compose_mod.max_bytes]u8 = undefined;
                const line = compose_mod.flatten(&flat, self.compose.text());
                // Copied out before closing, for the same reason the prompt
                // does it above: `closeCompose` declares the buffer empty, and
                // a slice of it read afterwards is a slice of nothing. A note
                // keeps its line breaks, so it needs the text rather than the
                // flattened line.
                var raw_buf: [compose_mod.max_bytes]u8 = undefined;
                const typed = self.compose.text();
                @memcpy(raw_buf[0..typed.len], typed);
                const raw = raw_buf[0..typed.len];
                const how = self.compose_to;
                self.closeCompose();
                if (line.len == 0) {
                    self.notice.set("nothing to send", .{});
                    return;
                }
                if (self.compose_is_comment) {
                    self.compose_is_comment = false;
                    if (self.compose_comment) |id| {
                        try self.comments.edit(id, raw);
                        self.notice.set("comment updated", .{});
                    } else if (self.commentLine()) |at| {
                        // The line's text goes with the note, so a restart can
                        // find it again when the file moved underneath.
                        _ = try self.comments.addFull(at.path, at.line, raw, self.textOfNewLine(at.line), at.deleted);
                        {
                            var kb: [32]u8 = undefined;
                            self.notice.set("comment added - {s} submits the review", .{
                                self.keyFor(.submit_review, .normal, &kb),
                            });
                        }
                    }
                    self.compose_comment = null;
                    self.saveComments();
                    // The note is a row now, so the layout has changed - and
                    // the reader should still be on the line they noted, not
                    // pushed off it by the row that just appeared under it.
                    const on = self.commentLine();
                    self.rebuildRows(.reset) catch {};
                    if (on) |at| _ = self.gotoNewLine(at.line);
                    self.clampScroll(body);
                    return;
                }
                self.outgoing.clearRetainingCapacity();
                try self.outgoing.appendSlice(self.gpa, line);
                self.want_send = how;
                self.clampScroll(body);
            }
        }
    }

    /// The `Ctrl-i` list. Escape closes it and gives the box back; Enter drops
    /// the question in at the caret and deletes nothing.
    fn feedPresets(self: *App, key: event.Key, idx: usize) void {
        const list = self.presets();
        const n = list.len;
        switch (key.codepoint) {
            event.code.escape => self.preset_index = null,
            event.code.enter => {
                if (idx < n) {
                    // A space in front unless the caret is already after one,
                    // so a preset dropped mid-sentence does not weld itself to
                    // the previous word.
                    const before = self.compose.text();
                    const at = self.compose.cursor;
                    if (at > 0 and before[at - 1] != ' ') self.compose.insert(" ");
                    self.compose.insert(list[idx].text);
                }
                self.preset_index = null;
            },
            event.code.up => self.preset_index = if (idx == 0) n -| 1 else idx - 1,
            event.code.down => self.preset_index = if (idx + 1 >= n) 0 else idx + 1,
            'k' => self.preset_index = if (idx == 0) n -| 1 else idx - 1,
            'j' => self.preset_index = if (idx + 1 >= n) 0 else idx + 1,
            else => {
                if (key.mods.ctrl and (key.codepoint == 'p')) {
                    self.preset_index = if (idx == 0) n -| 1 else idx - 1;
                } else if (key.mods.ctrl and (key.codepoint == 'n')) {
                    self.preset_index = if (idx + 1 >= n) 0 else idx + 1;
                }
            },
        }
    }

    fn buildPayload(self: *App, how: Delivery, what: What) Allocator.Error!void {
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
    /// Whether the reader is looking at a turn rather than the working tree,
    /// and has therefore been told why the key they pressed did nothing.
    ///
    /// A comment anchors to a line in the working tree (`core/comments.zig`).
    /// One written against a historical turn either anchors to a line that is
    /// not there any more - a comment born stale - or silently retargets to
    /// whatever now occupies that line number, which is worse. Hard rule 7 is
    /// about not losing a reader's remark, and the honest way to keep it is to
    /// not take it.
    fn readOnly(self: *App) bool {
        const turn = self.review.viewing orelse return false;
        var k: [32]u8 = undefined;
        self.notice.set("turn {d} is read only - {s} returns to the working tree", .{
            turn, self.keyFor(.next_turn, .normal, &k),
        });
        return true;
    }

    /// The turn list: what the agent has written, one row per turn.
    ///
    /// Built from the commit chain rather than from parsed diffs
    /// (SNAPSHOTS.md 5.3c), which is what keeps it two subprocesses whatever
    /// the length of the session. `Enter` shows that turn, so the list is a
    /// selector and the diff view is the viewer - there is no second display
    /// of files and hunks anywhere in this feature.
    fn openTurnList(self: *App) !void {
        const store = if (self.snap) |*s| s else {
            self.notice.set("snapshots are off here - no turns to list", .{});
            return;
        };
        if (store.state.latest_turn == 0 and !store.state.has_baseline) {
            self.notice.set("no turns yet - one is taken when the agent stops writing", .{});
            return;
        }

        const read = timeline.read(self.gpa, self.io, store.state.name(), store.state.latest_turn) catch {
            self.notice.set("could not read the timeline", .{});
            return;
        };
        defer self.gpa.free(read.text);
        defer self.gpa.free(read.turns);

        self.pick_list.clearRetainingCapacity();
        self.pick_turns.clearRetainingCapacity();
        _ = self.pick_arena.reset(.retain_capacity);
        const arena = self.pick_arena.allocator();
        const now_s: i64 = @intCast(@divFloor(
            std.Io.Timestamp.now(self.io, .real).toNanoseconds(),
            std.time.ns_per_s,
        ));

        // The working tree, pinned at the top. The way back has to be in the
        // same list as the way out, or the reader is somewhere with no visible
        // exit - the one thing a history view must never be.
        var here: u32 = 0;
        if (self.review.viewing == null) here = 0;
        self.pick_list.append(self.gpa, .{
            .path = arena.dupe(u8, "│ working tree  now") catch "working tree",
            .added = 0,
            .removed = 0,
            .in_review = false,
            .plain = true,
            .current = self.review.viewing == null,
        }) catch return;
        self.pick_turns.append(self.gpa, std.math.maxInt(u32)) catch return;

        var age_buf: [24]u8 = undefined;
        for (read.turns) |turn| {
            const shown = turnLabel(arena, turn, store, &age_buf, now_s);
            self.pick_list.append(self.gpa, .{
                .path = shown,
                // The baseline is not a change - it is what was there before
                // any were made - so it gets no counts. `+4 -0` beside it
                // would dress up "this is the starting state" as "the agent
                // added four lines", which is the same mistake `+0 -0` on an
                // unchanged file was.
                .added = if (turn.number == 0) 0 else turn.added,
                .removed = if (turn.number == 0) 0 else turn.removed,
                .in_review = turn.number != 0,
                .plain = true,
                .current = if (self.review.viewing) |v| v == turn.number else false,
            }) catch return;
            self.pick_turns.append(self.gpa, turn.number) catch return;
        }

        self.files_purpose = .turns;
        self.file_list.title = " turns ";
        self.file_list.extra_keys = &.{};
        // Opened on the row the reader is already looking at, rather than at an
        // arbitrary top.
        var at: u32 = 0;
        for (self.pick_list.items, 0..) |row, i| {
            if (row.current) at = @intCast(i);
        }
        self.file_list.open(at);
        self.mode = .finder;
    }

    /// The comment list's own footer keys, read from the keymap so a remap
    /// moves the footer with the binding.
    fn commentListKeys(self: *App, arena: Allocator) []const keytext.HelpEntry {
        var out: std.ArrayList(keytext.HelpEntry) = .empty;
        const want = [_]struct { cmd: keymap.Command, desc: []const u8 }{
            .{ .cmd = .comment_send_one, .desc = "send" },
            .{ .cmd = .comment_send_all, .desc = "send all" },
            .{ .cmd = .comment_drop, .desc = "del" },
        };
        for (want) |w| {
            var buf: [32]u8 = undefined;
            const keys = keytext.firstKeyFor(self.km.bindings, w.cmd, .finder, &buf);
            if (keys.len == 0) continue;
            out.append(arena, .{
                .keys = arena.dupe(u8, keys) catch continue,
                .desc = w.desc,
            }) catch continue;
        }
        return out.toOwnedSlice(arena) catch &.{};
    }

    /// Shows one turn by number, or the working tree for the sentinel.
    ///
    /// The same two states `]t` walks between, reached by choosing rather than
    /// by stepping - which is the whole of what the list adds. Nothing here is
    /// a third way to be looking at something.
    fn showTurnNumber(self: *App, turn: u32, body: u16) !void {
        const store = if (self.snap) |*s| s else return;
        if (turn == std.math.maxInt(u32)) {
            if (self.review.viewing == null) return;
            self.review.showWorking();
            try self.rediff();
            self.clampScroll(body);
            self.notice.set("back to the working tree", .{});
            return;
        }

        var buf: [128]u8 = undefined;
        const ref = gitobj.refFor(&buf, store.state.name(), turn) catch return;
        self.review.showTurn(turn, ref);
        try self.rediff();
        self.clampScroll(body);
        if (self.review.viewing == null) {
            self.notice.set("turn {d} is gone", .{turn});
            return;
        }
        var k: [32]u8 = undefined;
        const back = self.keyFor(.next_turn, .normal, &k);
        if (turn == 0) {
            self.notice.set("the baseline - before the agent ran, {s} returns", .{back});
            return;
        }
        self.notice.set("turn {d} - read only, {s} returns", .{ turn, back });
    }

    /// One turn's row. The rail, then which turn, what it touched, when, and
    /// how big - four columns and no more (SNAPSHOTS.md 5.3).
    fn turnLabel(
        arena: Allocator,
        turn: timeline.Turn,
        store: *const snapshot.Store,
        age_buf: []u8,
        now_s: i64,
    ) []const u8 {
        // The rail smartlog and undotree both draw, one column wide, straight
        // until a restore forks it (§5.3a). `✓` is the mark: read up to here.
        //
        // No `@` for the turn on screen, though 5.3b asked for one. The list
        // widget already marks the row the reader is on, in every list in the
        // tool, and a second indicator saying the same thing in the next column
        // is worse than either alone. Borrowing smartlog's spelling was not
        // worth contradicting the tool's own.
        const rail: []const u8 = if (turn.number == store.state.reviewed_turn and turn.number > 0) "✓" else "│";
        const when = timeline.age(age_buf, turn.when_s, now_s);

        if (turn.number == 0) {
            return std.fmt.allocPrint(arena, "{s} baseline   before the agent ran  {s}", .{ rail, when }) catch "baseline";
        }
        return std.fmt.allocPrint(arena, "{s} {d: <3} {s}  {s}  {d} file{s}", .{
            rail,
            turn.number,
            turn.path,
            when,
            turn.files,
            if (turn.files == 1) "" else "s",
        }) catch "turn";
    }

    /// Walks the timeline: one turn back, or forward to the working tree.
    ///
    /// The working tree is a position in the walk rather than a place outside
    /// it, so `]t` from the newest turn lands there and there is always a way
    /// forward. Nothing here is a jump into a different mode: it is the same
    /// review with a different right-hand side (SNAPSHOTS.md 5.3).
    fn turnStep(self: *App, delta: i32, body: u16) !void {
        const store = if (self.snap) |*s| s else {
            self.notice.set("snapshots are off here - no turns to walk", .{});
            return;
        };
        const latest = store.state.latest_turn;
        if (latest == 0) {
            self.notice.set("no turns yet - one is taken when the agent stops writing", .{});
            return;
        }

        // Null is the working tree, and it sits one past the newest turn.
        const here: i64 = if (self.review.viewing) |t| @intCast(t) else @as(i64, latest) + 1;
        const want = here + delta;

        if (want > latest) {
            if (self.review.viewing == null) {
                self.notice.set("already on the working tree", .{});
                return;
            }
            self.review.showWorking();
            try self.rediff();
            self.clampScroll(body);
            self.notice.set("back to the working tree", .{});
            return;
        }
        // The floor is the baseline when there is one and turn 1 when there is
        // not - a session that started on a clean tree has nothing before its
        // first turn, and walking to a ref that was never written would report
        // it as missing rather than as absent by design.
        const oldest = store.oldestTurn();
        if (want < oldest) {
            if (oldest == 0)
                self.notice.set("the baseline is as far back as it goes", .{})
            else
                self.notice.set("turn 1 is the oldest recorded - no baseline for this session", .{});
            return;
        }

        const turn: u32 = @intCast(want);
        var buf: [128]u8 = undefined;
        const ref = gitobj.refFor(&buf, store.state.name(), turn) catch {
            self.notice.set("cannot name that turn", .{});
            return;
        };
        self.review.showTurn(turn, ref);
        try self.rediff();
        self.clampScroll(body);
        if (self.review.viewing == null) {
            // `regenerate` gave up on the ref - pruned, or never written.
            self.notice.set("turn {d} is gone", .{turn});
            return;
        }
        var k: [32]u8 = undefined;
        const back = self.keyFor(.next_turn, .normal, &k);
        if (turn == 0) {
            // Not "turn 0". It is the tree as it was before the agent ran, and
            // that is the only thing about it worth saying.
            self.notice.set("the baseline - before the agent ran, {s} returns", .{back});
            return;
        }
        self.notice.set("turn {d} of {d} - read only, {s} returns", .{ turn, latest, back });
    }

    /// Records the working tree as a turn, because the agent has stopped.
    ///
    /// The same call `m` makes, with a different reason and without touching
    /// `reviewed_turn`: a turn nobody has read must not mark itself read, or
    /// the gutter would go blank exactly when it had something to say.
    fn snapshotTurn(self: *App) bool {
        var store = &(if (self.snap) |*s| s else return false).*;
        const fs = self.files();
        if (fs.len == 0) return false;

        var paths = self.gpa.alloc([]const u8, fs.len) catch return false;
        defer self.gpa.free(paths);
        for (fs, 0..) |*f, i| paths[i] = f.path();

        return store.take(paths, "turn") != null;
    }

    /// Writes the mark to a ref, so it outlives the process. Returns whether it
    /// stuck: snapshots are off in a directory git does not own, and the mark
    /// is still perfectly good for this session without them.
    fn snapshotMark(self: *App) bool {
        var store = &(if (self.snap) |*s| s else return false).*;
        const fs = self.files();
        if (fs.len == 0) return false;

        var paths = self.gpa.alloc([]const u8, fs.len) catch return false;
        defer self.gpa.free(paths);
        for (fs, 0..) |*f, i| paths[i] = f.path();

        if (store.take(paths, "mark") == null) return false;
        store.markReviewed();
        return true;
    }

    /// Records what was already uncommitted before the agent ran.
    ///
    /// After the first diff, because that is when the path list exists, and
    /// once - `Store.baseline` refuses a session that already has one. Silent:
    /// it is insurance, and insurance that announces itself is noise until the
    /// day it is not.
    pub fn takeBaseline(self: *App) void {
        var store = &(if (self.snap) |*s| s else return).*;
        const fs = self.files();
        if (fs.len == 0) return;

        var paths = self.gpa.alloc([]const u8, fs.len) catch return;
        defer self.gpa.free(paths);
        for (fs, 0..) |*f, i| paths[i] = f.path();
        _ = store.baseline(paths);
    }

    /// Picks the mark up again after a restart, once there are files to attach
    /// it to. Silent either way: a mark that could not be restored leaves the
    /// session in the state it would have started in regardless.
    pub fn restoreMark(self: *App) void {
        if (self.mark_restored) return;
        self.mark_restored = true;
        const store = if (self.snap) |*s| s else return;
        var buf: [128]u8 = undefined;
        const ref = store.reviewedRef(&buf) orelse return;
        self.review.restoreMark(ref, store.state.reviewed_turn);
    }

    /// What a command is bound to right now, for a message that has to name a
    /// key. Written into `buf` by the caller so this allocates nothing, and
    /// read from the keymap so `[keys]` cannot leave a notice telling the
    /// reader to press something they have remapped away.
    fn noComments(self: *App) void {
        var key: [32]u8 = undefined;
        self.notice.set("no comments yet - {s} writes one", .{
            self.keyFor(.comment_add, .normal, &key),
        });
    }

    fn keyFor(self: *App, cmd: keymap.Command, mode: event.Mode, buf: []u8) []const u8 {
        return keytext.firstKeyFor(self.km.bindings, cmd, mode, buf);
    }

    /// Walks the changes that arrived since the mark, across the whole review.
    ///
    /// By row rather than by hunk. What the reader came back for is the twelve
    /// lines that answer the last comment, and a hunk that happens to contain
    /// one of them is a coarser answer than the line itself - which is the
    /// same reason `]h` exists separately rather than this replacing it.
    fn freshStep(self: *App, delta: i32) !void {
        if (!self.review.mark_at.taken()) {
            var key: [32]u8 = undefined;
            self.notice.set("no mark yet - {s} sets one", .{
                keytext.firstKeyFor(self.km.bindings, .mark_here, .normal, &key),
            });
            return;
        }
        if (self.review.freshCount() == 0) {
            self.notice.set("nothing new since the mark", .{});
            return;
        }

        if (self.freshFrom(self.cursor, delta)) |row| {
            self.moveTo(row);
            return;
        }

        // Nothing further this way in this file. A review is a ring, and the
        // ring is the whole review: the change the reader is looking for is
        // as likely to be in the next file as in this one.
        const count = self.files().len;
        if (count > 1) {
            var tries: usize = 0;
            while (tries < count) : (tries += 1) {
                try self.stepFile(delta);
                if (self.freshEdge(delta)) |row| {
                    self.moveTo(row);
                    return;
                }
            }
            return;
        }
        if (self.freshEdge(delta)) |row| {
            self.noteWrap(delta, "change");
            self.moveTo(row);
        }
    }

    /// The next row after `from` whose line changed since the mark.
    fn freshFrom(self: *App, from: u32, delta: i32) ?u32 {
        return self.scanFresh(@as(i64, from) + delta, delta);
    }

    /// The first such row from whichever end `delta` enters the file by.
    fn freshEdge(self: *App, delta: i32) ?u32 {
        return self.scanFresh(if (delta > 0) 0 else @as(i64, self.rows.len()) - 1, delta);
    }

    fn scanFresh(self: *App, start: i64, delta: i32) ?u32 {
        const fresh = self.review.freshFor(self.file_index);
        if (fresh.len == 0) return null;
        var i = start;
        while (i >= 0 and i < self.rows.len()) : (i += delta) {
            const row: u32 = @intCast(i);
            const li = self.rows.lineAt(row) orelse continue;
            if (li < fresh.len and fresh[li]) return row;
        }
        return null;
    }

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
        // A note wraps like a line does, and the scroll maths has to agree
        // with what `body.zig` draws or the viewport drifts.
        if (row < self.rows.len()) {
            if (self.rows.items[row] == .note) return self.commentHeight(row, cap);
        }
        const li = self.rows.lineAt(row) orelse return 1;
        if (li >= f.lines.text.len) return 1;
        return wrap_mod.height(
            f.lines.text[li],
            self.cols -| rows_mod.gutter(f),
            self.width_method,
            cap,
        );
    }

    fn commentHeight(self: *App, row: u32, cap: u16) u16 {
        const ni = self.rows.items[row].note;
        const marks = self.commentMarks();
        if (ni >= marks.len) return 1;
        const col: u16 = if (self.cols > 8) 6 else 0;
        const width = self.cols -| col -| 2;
        if (width == 0) return 1;

        var rows: u16 = 0;
        var lines = std.mem.splitScalar(u8, marks[ni].body, '\n');
        while (lines.next()) |line| {
            rows +|= wrap_mod.height(line, width, self.width_method, cap);
        }
        return @max(@min(rows, cap), 1);
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
                if (self.mode == .note_input) return self.feedCompose(k, body);
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
                // A reader in the past stays there. The agent goes on writing
                // and turns go on accumulating - the mode row counts them - but
                // re-diffing under someone reading turn 4 would throw them back
                // to the present mid-sentence, which is the one thing a history
                // view must never do (SNAPSHOTS.md 5.3).
                if (self.review.viewing != null) return;
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
            // The agent stopped writing, so this is a turn. Snapshotting here
            // rather than on the watcher thread keeps the store's turn numbers
            // and its state file owned by one thread; the cost lands ten
            // seconds into silence, where a frame is worth nothing.
            //
            // Silent. The reader did not ask for it and cannot act on it, and
            // a notice every quiet period would be the tool talking about
            // itself. What it buys them is that `refs/lgtm/<session>/<n>` now
            // holds the work the agent has just done, whether or not they ever
            // press anything (SNAPSHOTS.md 2).
            .agent_quiescent => _ = self.snapshotTurn(),
            .snapshot_taken => {},
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

    /// A review with no files in it. The state a pane sits in whenever the
    /// tree is clean, which is most of the day.
    fn emptyReview(gpa: Allocator) !*Fixture {
        const self = try build(gpa, null);
        self.app.review.parsed.?.diff.files = self.files[0..0];
        try self.app.rebuildRows(.reset);
        return self;
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

    /// A review whose one file is over `large_file_lines`, parsed from real
    /// diff text: `zo` opens the bytes git actually produced, so a fixture
    /// that faked the byte range would test nothing.
    fn summarised(gpa: Allocator) !*Fixture {
        const self = try build(gpa, null);
        errdefer self.deinit();

        // Everything here goes in the review's own arena, which is where a
        // real generation lives and where `expand` allocates. Parsing it on
        // the gpa instead would leave the fixture freeing arena memory.
        const arena = self.app.review.allocator();
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(arena,
            \\diff --git a/big.zig b/big.zig
            \\--- a/big.zig
            \\+++ b/big.zig
            \\
        );
        const n = diff.large_file_lines + 10;
        var header: [64]u8 = undefined;
        try buf.appendSlice(arena, try std.fmt.bufPrint(&header, "@@ -1,{d} +1,{d} @@\n", .{ n, n }));
        for (0..n) |i| try buf.appendSlice(arena, if (i % 2 == 0) "+added\n" else "-removed\n");

        const raw = try buf.toOwnedSlice(arena);
        self.app.review.parsed = .{ .diff = try diff.parse(arena, raw), .raw = raw, .stderr = &.{} };
        self.app.file_index = 0;
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
    try fx.press("<CR>");
    try testing.expectEqualStrings("#1 a.zig:1 `alpha`", fx.app.payload());

    // Grown past one line, the text would have to carry the newline between
    // them - so it becomes the line range it always was.
    try fx.press("w");
    try fx.press("v");
    try fx.press("j");
    try fx.press("<CR>");
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
    try testing.expectEqual(@as(u32, 1), fx.app.file_list.selected(fx.app.pick_list.items).?);

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
    try testing.expectEqual(@as(usize, 1), files_mod.count(fx.app.pick_list.items, fx.app.file_list.filter.text()));
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

    // Enter opens the box seeded with the reference; nothing is sent yet.
    try fx.press("<CR>");
    try testing.expectEqual(event.Mode.note_input, fx.app.mode);
    try testing.expectEqualStrings("#1 a.zig:1", fx.app.compose.text());
    try testing.expect(fx.app.want_send == null);

    // The second Enter is the send. A request, not an action: the loop owns
    // the terminal and the subprocess.
    try fx.press("<CR>");
    try testing.expectEqual(App.Delivery.send, fx.app.want_send.?);
    try testing.expectEqualStrings("#1 a.zig:1", fx.app.payload());
    try testing.expectEqual(event.Mode.normal, fx.app.mode);
}

test "@ picks a file out of the review and puts its path at the caret" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("<CR>");
    try fx.press(" see");
    try fx.press(" @");
    // The `@` is typed, and the picker is over the box rather than instead of
    // it - the box is still open underneath.
    try testing.expectEqual(event.Mode.finder, fx.app.mode);
    try testing.expect(fx.app.compose.open);
    try testing.expectEqualStrings("#1 a.zig:1 see @", fx.app.compose.text());

    // Enter takes the highlighted file; the keyboard goes back to the box.
    try fx.press("<CR>");
    try testing.expectEqual(event.Mode.note_input, fx.app.mode);
    try testing.expectEqualStrings("#1 a.zig:1 see @a.zig", fx.app.compose.text());

    try fx.press("<CR>");
    try testing.expectEqualStrings("#1 a.zig:1 see @a.zig", fx.app.payload());
}

test "cancelling the file picker leaves the @ that was typed" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("<CR>");
    try fx.press("@");
    try fx.press("<Esc>");
    // Back in the box, not out of it, and the character stands: it was typed.
    try testing.expectEqual(event.Mode.note_input, fx.app.mode);
    try testing.expectEqualStrings("#1 a.zig:1@", fx.app.compose.text());
}

test "the file overlay still jumps when it was not opened from the box" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    // Same list, same filter, same drawing - only Enter differs, and that is
    // what `files_purpose` is for.
    try fx.press("<Space>f");
    try testing.expectEqual(event.Mode.finder, fx.app.mode);
    try fx.press("<CR>");
    try testing.expectEqual(event.Mode.normal, fx.app.mode);
    try testing.expect(!fx.app.compose.open);
}

test "with nothing to review the box still opens, empty" {
    var fx = try Fixture.emptyReview(testing.allocator);
    defer fx.deinit();

    // A clean tree is where a review pane spends most of its day, and "talk to
    // the agent" is a thing to want there. Refusing until the reader makes a
    // change first would be the tail wagging the dog.
    try fx.press("<CR>");
    try testing.expectEqual(event.Mode.note_input, fx.app.mode);
    try testing.expectEqualStrings("", fx.app.compose.text());

    try fx.press("hi");
    try fx.press("<CR>");
    try testing.expectEqualStrings("hi", fx.app.payload());
    try testing.expectEqual(App.Delivery.send, fx.app.want_send.?);
}

test "an empty message sends nothing rather than a blank line" {
    var fx = try Fixture.emptyReview(testing.allocator);
    defer fx.deinit();

    try fx.press("<CR>");
    try fx.press("<CR>");
    try testing.expect(fx.app.want_send == null);
    try testing.expectEqual(event.Mode.normal, fx.app.mode);
}

test "the box opens on the reference and nothing else" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    // No question is typed in for the reader. A canned sentence that arrives
    // uninvited is one they have to read and mostly delete; the presets have
    // their own key for when they are actually wanted.
    try fx.press("<CR>");
    try testing.expectEqualStrings("#1 a.zig:1", fx.app.compose.text());

    try fx.press(" it");
    try fx.press("s wr");
    try fx.press("ong");
    try fx.press("<CR>");
    try testing.expectEqualStrings("#1 a.zig:1 its wrong", fx.app.payload());
}

test "escape abandons the message and sends nothing" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("<CR>");
    // Two escapes: the first leaves insert, the second leaves the box.
    try fx.press("<Esc>");
    try fx.press("<Esc>");
    try testing.expectEqual(event.Mode.normal, fx.app.mode);
    try testing.expect(fx.app.want_send == null);
    try testing.expect(!fx.app.compose.open);
}

test "a selection sends a range, and using it ends the selection" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("Vj");
    try testing.expectEqual(@as(u32, 2), fx.app.selection().?.count());
    try fx.press("<CR>");
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

test "matches light up while the query is still being typed" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    // Nothing to paint before a search exists.
    try testing.expectEqualStrings("", fx.app.view(body_rows).?.query);

    // Mid-type, with no Enter yet: this is the whole feature.
    try fx.press("/co");
    try testing.expectEqualStrings("co", fx.app.view(body_rows).?.query);
    try fx.press("n");
    try testing.expectEqualStrings("con", fx.app.view(body_rows).?.query);

    // Cancelling puts the screen back the way it was, rather than leaving the
    // abandoned query painted across the diff.
    try fx.press("<Esc>");
    try testing.expectEqualStrings("", fx.app.view(body_rows).?.query);

    // Submitting hands over to the stored query, and `:noh` still clears it.
    try fx.press("/co");
    try fx.press("ns");
    try fx.press("t");
    try fx.press("<CR>");
    try testing.expectEqualStrings("const", fx.app.view(body_rows).?.query);
    try fx.press(":noh");
    try fx.press("<CR>");
    try testing.expectEqualStrings("", fx.app.view(body_rows).?.query);
}

test "a command being typed is not painted across the diff" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    // `:` text is a command, not a pattern. Highlighting it would paint `noh`
    // over the review while the reader types the thing that turns painting off.
    try fx.press(":noh");
    try testing.expectEqualStrings("", fx.app.view(body_rows).?.query);
    try fx.press("<Esc>");
}

test "y yanks the text, the way the key means in vim" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    // No selection: the cursor line, and without the diff's sign column -
    // yanked code should paste into an editor and still compile.
    try fx.press("y");
    try testing.expectEqual(App.Delivery.copy, fx.app.want_send.?);
    try testing.expectEqualStrings("fn alpha() {", fx.app.payload());

    // Charwise: exactly the characters under the selection, which is the case
    // that sent people a reference when they wanted a word.
    try fx.press("vll");
    try fx.press("y");
    try testing.expectEqualStrings("fn ", fx.app.payload());

    // Linewise across two rows, joined by the newline the clipboard allows.
    try fx.press("Vj");
    try fx.press("y");
    try testing.expectEqualStrings("fn alpha() {\n    const x = 1;", fx.app.payload());
}

test "Y yanks whole lines even from a charwise selection" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    // vim's `Y` is linewise whatever `v` selected.
    try fx.press("vll");
    try fx.press("Y");
    try testing.expectEqual(App.Delivery.copy, fx.app.want_send.?);
    try testing.expectEqualStrings("fn alpha() {", fx.app.payload());
}

test "the reference moved to <leader>y rather than being lost" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("<Space>y");
    try testing.expectEqual(App.Delivery.copy, fx.app.want_send.?);
    try testing.expectEqualStrings("#1 a.zig:1", fx.app.payload());
}

test "<leader>Y puts the lines under the reference, markers kept" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    // The marker is what says which side of the change a line is on; a mixed
    // range pasted without them reads as nonsense.
    try fx.press("Vj");
    try fx.press("<Space>Y");
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

test "every opener seeds the same thing: the reference" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    // One opener, because there is only one thing to open. The four ask keys
    // that used to sit beside it are gone: once the box stopped typing a
    // question in for you, they did exactly what Enter does.
    for ([_][]const u8{"<CR>"}) |keys| {
        try fx.press(keys);
        try testing.expectEqual(event.Mode.note_input, fx.app.mode);
        try testing.expectEqualStrings("#1 a.zig:1", fx.app.compose.text());
        try fx.press("<CR>");
        try testing.expectEqualStrings("#1 a.zig:1", fx.app.payload());
        try testing.expectEqual(App.Delivery.send, fx.app.want_send.?);
    }
}

test "nothing sent to the agent ever contains a newline" {
    // Hard rule 1, checked where the payload is built as well as where it is
    // sent: in `tmux send-keys` a newline is Enter, and Enter submits the
    // user's half-written message. The yanks and `<leader>Y` are exempt by
    // design - they are the clipboard, which no send-keys ever sees.
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    for ([_][]const u8{ "<CR>", "<Space>y" }) |keys| {
        try fx.press("Vj");
        try fx.press(keys);
        // Everything but the yank now goes through the compose box, and the
        // flattening on submit is the last place a newline could survive.
        if (fx.app.mode == .note_input) try fx.press("<CR>");
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
    try fx.press("<CR>");
    try fx.press("j");
    try fx.press("<CR>");
    try fx.press("<CR>");
    try testing.expectEqualStrings("#1 a.zig:2", fx.app.payload());
}

// -- large files -----------------------------------------------------------

test "a file too large to render inline opens on zo" {
    var fx = try Fixture.summarised(testing.allocator);
    defer fx.deinit();

    // One row, and it is the summary: this is where a large file used to stop,
    // because nothing called `materialise`.
    try testing.expectEqual(@as(u32, 1), fx.app.rows.len());
    try testing.expect(fx.app.rows.items[0] == .summarised);

    try fx.press("zo");
    try testing.expect(!fx.app.current().?.summarised);
    try testing.expect(fx.app.rows.len() > diff.large_file_lines);
    try fx.expectNotice("opened");
    // On a line, not on chrome, and at the top: the summary row it was on is
    // not a line, so there is nowhere else honest to land.
    try testing.expect(fx.app.rows.items[fx.app.cursor] == .line);
}

test "opening a large file gives its hunks change ids" {
    // Ids are inherited during a re-diff, which skips a summarised file
    // entirely. Without assigning them on open, every hunk in the file would
    // render as the same id and `#N` would name nothing.
    var fx = try Fixture.summarised(testing.allocator);
    defer fx.deinit();

    try fx.press("zo");
    const f = fx.app.current().?;
    try testing.expect(f.hunks.len > 0);
    for (f.hunks) |h| try testing.expect(h.id != hunk.no_id);
}

test "zo on a file that is already open says so rather than doing nothing" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("zo");
    try fx.expectNotice("already open");
}

test "an opened file is remembered, so a re-diff does not fold it again" {
    // The list is what `regenerate` reads to materialise it again. Asserted
    // here rather than through a re-diff because a re-diff needs git; what
    // this owns is the remembering.
    var fx = try Fixture.summarised(testing.allocator);
    defer fx.deinit();

    try testing.expectEqual(@as(usize, 0), fx.app.review.expanded.items.len);
    try fx.press("zo");
    try testing.expectEqual(@as(usize, 1), fx.app.review.expanded.items.len);
    try testing.expectEqualStrings("big.zig", fx.app.review.expanded.items[0]);

    // And opening it twice remembers it once.
    _ = try fx.app.review.expand("big.zig");
    try testing.expectEqual(@as(usize, 1), fx.app.review.expanded.items.len);
}

test "folding forgets the file, and folding an ordinary one says it cannot" {
    var fx = try Fixture.summarised(testing.allocator);
    defer fx.deinit();

    try fx.press("zo");
    try testing.expect(fx.app.review.collapse("big.zig"));
    try testing.expectEqual(@as(usize, 0), fx.app.review.expanded.items.len);
    // A second fold has nothing left to forget.
    try testing.expect(!fx.app.review.collapse("big.zig"));
}

test "zc on a file that was never folded says so instead of re-diffing" {
    // The dispatch must not reach `rediff` here: an ordinary file has nothing
    // to fold, and running git to discover that would be a keystroke that
    // costs a subprocess and changes nothing.
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("zc");
    try fx.expectNotice("too large");
}

// -- since I last looked ---------------------------------------------------

/// Marks rows of the fixture's two files as changed since the mark, the way a
/// re-diff would. Set directly rather than through `Review.mark`, which needs
/// git and real buffers: what these tests own is the walking, and
/// `core/checkpoint.zig` owns deciding what is fresh.
fn markFresh(fx: *Fixture, first: []const bool, second: []const bool) !void {
    const arena = fx.app.review.allocator();
    const out = try arena.alloc([]bool, 2);
    out[0] = try arena.dupe(bool, first);
    out[1] = try arena.dupe(bool, second);
    fx.app.review.fresh = out;
    fx.app.review.mark_at.turn = 1;
}

test "walking the changes since the mark needs a mark first" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("]m");
    try fx.expectNotice("no mark");
    try fx.expectCursor(1);
}

test "a mark with nothing after it says so rather than moving" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("m");
    try fx.expectNotice("marked");
    try fx.press("]m");
    try fx.expectNotice("nothing new");
}

test "]n walks to the changed line, not to its hunk" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    // Row 0 is the hunk header; rows 1..3 are the three lines.
    try markFresh(fx, &.{ false, true, false }, &.{ false, false, false });

    try fx.expectCursor(1);
    try fx.press("]m");
    try fx.expectCursor(2);
}

test "]n crosses into the next file when this one has nothing left" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try markFresh(fx, &.{ false, false, false }, &.{ true, false, false });

    try fx.expectFile(0);
    try fx.press("]m");
    try fx.expectFile(1);
    try fx.expectCursor(1);
}

test "[n walks backwards and reaches the same rows" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try markFresh(fx, &.{ true, false, false }, &.{ false, false, true });

    // From the top of the first file, backwards crosses into the last file.
    try fx.press("[m");
    try fx.expectFile(1);
    try fx.expectCursor(3);
    try fx.press("[m");
    try fx.expectFile(0);
    try fx.expectCursor(1);
}

test "the mark clears what came before it" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try markFresh(fx, &.{ false, true, false }, &.{ false, false, false });
    try testing.expectEqual(@as(u32, 1), fx.app.review.freshCount());

    // Marking again with no buffers behind the fixture's files records them as
    // empty, which is the honest answer: nothing is newer than now.
    try fx.press("m");
    try testing.expectEqual(@as(u32, 0), fx.app.review.freshCount());
}

test "M drops the mark and the whole change reads as one again" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try markFresh(fx, &.{ false, true, false }, &.{ false, false, false });
    try testing.expectEqual(@as(u32, 1), fx.app.review.freshCount());

    try fx.press("M");
    try fx.expectNotice("dropped");
    try testing.expectEqual(@as(u32, 0), fx.app.review.freshCount());
    try testing.expect(!fx.app.review.mark_at.taken());

    // And walking says there is no mark rather than "nothing new", which are
    // different answers to different situations.
    try fx.press("]m");
    try fx.expectNotice("no mark");
}

test "M with no mark says so instead of pretending to do something" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try fx.press("M");
    try fx.expectNotice("no mark to drop");
}

test ":nomark drops it too, the way :noh drops the search" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try markFresh(fx, &.{ false, true, false }, &.{ false, false, false });

    try fx.press(":");
    try fx.typeIn("nomark");
    try fx.press("<CR>");
    try testing.expect(!fx.app.review.mark_at.taken());
}

test "every mark command can be remapped, and the screen says the new key" {
    // `[keys]` resolves command names straight off the enum, so a new command
    // is remappable the moment it exists. What is worth testing is the other
    // half: that the messages naming a key read the keymap rather than a
    // string literal, or a remap turns them into instructions for a key the
    // reader does not have.
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    var chords: [keymap.Keymap.max_sequence]keymap.Chord = undefined;
    const moved = [_]keymap.Binding{
        .{ .chords = try keytext.parseChords("gm", &chords), .command = .mark_here },
    };
    fx.app.km.bindings = &moved;

    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("gm", keytext.firstKeyFor(fx.app.km.bindings, .mark_here, .normal, &buf));

    try fx.app.handle(.{ .key = .{ .codepoint = 'g', .mods = .{} } }, body_rows);
    try fx.app.handle(.{ .key = .{ .codepoint = 'm', .mods = .{} } }, body_rows);
    try fx.expectNotice("marked");
}

// -- the compose box takes its keys from the keymap ------------------------

test "the box's feature keys are bindings, and a remap moves them" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    var a: [4]keymap.Chord = undefined;
    var b: [4]keymap.Chord = undefined;
    const moved = [_]keymap.Binding{
        .{ .chords = try keytext.parseChords("<C-g>", &a), .command = .compose_cancel, .modes = keymap.Modes.compose_only },
        .{ .chords = try keytext.parseChords("<CR>", &b), .command = .compose_submit, .modes = keymap.Modes.compose_only },
    };
    fx.app.km.bindings = &moved;

    try fx.app.openCompose(.send, .ref);
    try fx.expectMode(.note_input);
    try fx.typeIn("hello");

    // `<Esc>` is no longer bound, so in the box it is just a key that types
    // nothing - it must not close what the reader is writing.
    try fx.app.handle(.{ .key = .{ .codepoint = event.code.escape, .mods = .{} } }, body_rows);
    try fx.expectMode(.note_input);

    try fx.app.handle(.{ .key = .{ .codepoint = 'g', .mods = .{ .ctrl = true } } }, body_rows);
    try fx.expectMode(.note_input);
    // First press leaves insert, second leaves the box - the two levels are
    // the command's, not the key's.
    try fx.app.handle(.{ .key = .{ .codepoint = 'g', .mods = .{ .ctrl = true } } }, body_rows);
    try fx.expectMode(.normal);
}

test "a pending operator outranks the keymap, so d<Esc> cancels the operator" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.app.openCompose(.send, .ref);
    try fx.typeIn("one two");
    try fx.press("<Esc>"); // leave insert, stay in the box
    try fx.expectMode(.note_input);
    try testing.expect(fx.app.compose.mode == .normal);

    try fx.typeIn("d");
    try testing.expect(fx.app.compose.hasPending());
    try fx.press("<Esc>");
    // The operator went, the box stayed, and the text is untouched.
    try testing.expect(!fx.app.compose.hasPending());
    try fx.expectMode(.note_input);
    // The box was seeded with the reference; what matters is that the typed
    // half survived the operator being cancelled.
    try testing.expect(std.mem.endsWith(u8, fx.app.compose.text(), "one two"));
}

test "an unbound compose command drops out of the footer rather than lying" {
    var a: [4]keymap.Chord = undefined;
    const only = [_]keymap.Binding{
        .{ .chords = try keytext.parseChords("<CR>", &a), .command = .compose_submit, .modes = keymap.Modes.compose_only, .desc = "send" },
    };
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("<CR>", keytext.firstKeyFor(&only, .compose_submit, .note_input, &buf));
    try testing.expectEqualStrings("", keytext.firstKeyFor(&only, .compose_mention, .note_input, &buf));
}

// -- the timeline ----------------------------------------------------------

test "walking turns says why when there are none to walk" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    // No store: the fixture has no environment to run git in, which is the
    // same state a directory git does not own is in.
    try fx.press("[t");
    try fx.expectNotice("snapshots are off");
    try testing.expect(fx.app.review.viewing == null);
}

test "a turn is read only, and the refusal names the way back" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    fx.app.review.showTurn(4, "refs/lgtm/s1/4");

    // A comment written against a historical turn would anchor to a line that
    // may not be there any more, or silently retarget to whatever now occupies
    // that line number. Hard rule 7 says do not lose a remark; the honest way
    // to keep it is to not take it.
    try fx.press("<Space>c");
    try fx.expectNotice("read only");
    try fx.expectNotice("]t");
    try testing.expectEqual(@as(usize, 0), fx.app.comments.len());

    // Marking would record a tree the reader is looking at rather than the one
    // they are answerable for.
    try fx.press("m");
    try fx.expectNotice("read only");
    try testing.expect(!fx.app.review.mark_at.taken());
}

test "the watcher cannot drag a reader out of the past" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    fx.app.review.showTurn(2, "refs/lgtm/s1/2");

    // A re-diff here would throw the reader back to the present mid-sentence.
    // The event still has to free what it owns, which is why this is a return
    // rather than a branch around the whole arm.
    const paths = try testing.allocator.alloc([]const u8, 1);
    paths[0] = try testing.allocator.dupe(u8, "a.zig");
    try fx.app.handle(.{ .files_changed = paths }, body_rows);
    try testing.expectEqual(@as(u32, 2), fx.app.review.viewing.?);
}

test "showing a turn and returning are the two states, and nothing between" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    try testing.expect(fx.app.review.viewRef() == null);
    fx.app.review.showTurn(7, "refs/lgtm/s1/7");
    try testing.expectEqualStrings("refs/lgtm/s1/7", fx.app.review.viewRef().?);
    try testing.expectEqual(@as(u32, 7), fx.app.review.viewing.?);

    fx.app.review.showWorking();
    try testing.expect(fx.app.review.viewRef() == null);
    try testing.expect(fx.app.review.viewing == null);
}

test "the turn list says why when there is nothing to list" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    // No store, which is the state a directory git does not own is in.
    try fx.press("<Space>lt");
    try fx.expectNotice("snapshots are off");
    try fx.expectMode(.normal);
}
