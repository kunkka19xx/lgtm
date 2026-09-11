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
// vaxis cells reference that text rather than copying it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const diff = @import("../core/diff.zig");
const expand = @import("../core/expand.zig");
const event = @import("../core/event.zig");
const fs_mod = @import("../io/fs.zig");
const git = @import("../core/git.zig");
const comments_mod = @import("../core/comments.zig");
const hunk = @import("../core/hunk.zig");
const buffer = @import("../text/buffer.zig");
const binary = @import("../core/binary.zig");
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
const pr_mod = @import("pr.zig");
const turns_mod = @import("turns.zig");
const walks = @import("walks.zig");
const finder_mod = @import("finder.zig");
const notes = @import("notes.zig");
const cmdline = @import("cmdline.zig");
const outgoing = @import("outgoing.zig");
const render = @import("render.zig");
const snapshot = @import("../snapshot/snapshot.zig");
const timeline = @import("../snapshot/timeline.zig");
const review_mod = @import("review.zig");
const rows_mod = @import("rows.zig");
const viewport = @import("viewport.zig");
const search = @import("search.zig");
const complete = @import("complete.zig");
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

    /// One diff generation and everything derived from it. The reader's
    /// position - which file, which row - is here; what changed is there.
    review: review_mod.Review,
    /// The strings one frame draws. Reset *after* render and flush, never
    /// before: vaxis cells reference this text rather than copying it.
    frame_arena: std.heap.ArenaAllocator,

    queue: *event.Queue,
    km: keymap.Keymap = .{},
    theme: theme_mod.Theme = theme_mod.default,
    /// Which bundled theme `theme` came from, for `:theme` to report and for
    /// the config file to be told to write. Static storage, so it outlives the
    /// prompt line that set it.
    theme_name: []const u8 = "terminal",
    glyphs: theme_mod.Glyphs = theme_mod.Glyphs.unicode,

    /// The current file, laid out. Rebuilt whenever the file or the diff
    /// changes, and owned by the review's arena.
    rows: rows_mod.Rows = rows_mod.Rows.empty,
    fn_names: [][]const u8 = &.{},
    /// Previous generation's hunks for the current file, so ids carry across.
    prev_hunks: []hunk.Hunk = &.{},

    file_index: u32 = 0,
    quit: bool = false,

    /// Where the reader is and where the screen has got to catching up: the
    /// cursor and its column, the scroll offset, the pane width, and the two
    /// animations. Grouped because they are the one set of fields in this
    /// struct that answer to each other and to nothing else, and because
    /// `ui/viewport.zig` can then do the arithmetic over them against a table
    /// of row heights rather than against a diff.
    vp: viewport.Viewport = .{},
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
    /// `<Tab>` candidates for the open `:` line. Empty when not completing,
    /// which is also what tells the renderer whether to draw the strip.
    comp: complete.Set = .{},
    /// Which candidate is currently in the line, or null while the line is
    /// still the reader's own text.
    comp_at: ?usize = null,

    /// The last walk `;` should repeat: `]h`, `]w`, `]c`, `/`'s `n`, any of
    /// them. Null until one has been used, and then never null again - `;`
    /// with nothing behind it is the only case where it falls back to `f`.
    ///
    /// Set for the *whole* family rather than for one direction, so `[h` then
    /// `;` walks backwards: `;` means "that again", and the last thing done
    /// was a backwards step.
    last_walk: ?keymap.Command = null,
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
    /// Where the comment being written belongs, captured when the box opened.
    /// Opening it clears the selection, so asking again at save time would
    /// give a range of one line.
    compose_spot: ?notes.Spot2 = null,
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
    /// The previewed file as a Buffer, which is what the renderer highlights
    /// from: it wants a line index and byte offsets, not the diff's per-line
    /// slices. Arena-allocated with the rest of the preview, so it dies when
    /// the preview does.
    preview_buf: ?buffer.Buffer = null,
    preview_arena: std.heap.ArenaAllocator = undefined,
    /// The `Ctrl-i` list, open over the box. An index into `presets()`, or
    /// null while the box has the keyboard.
    preset_index: ?usize = null,
    /// What the file overlay is being used for. It is the same list, the same
    /// filter and the same drawing either way; only what happens on Enter
    /// differs, which is one field rather than a second overlay.
    /// The timeline, the mark walk and the restore, in `ui/turns.zig`.
    turns: turns_mod.State = .{},

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
        /// The panes a send could go to, and Enter connects to one.
        ///
        /// Opened by hand, and opened for the reader when a send found no
        /// target: inference refuses past two panes because a wrong guess
        /// types into somebody's editor, and refusing is the right answer for
        /// a machine and the wrong one for a person who can see their own
        /// screen.
        panes,
        /// `<Space>lp`: the open pull requests, and Enter reviews one.
        prs,
    } = .jump,
    /// The picker overlay, in `ui/finder.zig`.
    finder_state: finder_mod.State = .{},
    /// The list the overlay is showing: the changed files for a jump, every
    /// file git knows about for a mention. Rebuilt when the overlay opens and
    /// owned here, because `selected` is asked outside any frame.
    pick_list: std.ArrayList(render.FileEntry) = .empty,
    /// Backing store for the labels the comment overlay builds. Its own arena
    /// because the list outlives a frame: it is read by the filter on every
    /// keystroke, and the frame arena is reset between them - which made every
    /// label a slice of freed memory and every filter a miss.
    pick_arena: std.heap.ArenaAllocator = undefined,
    /// Everything true only while a pull request is on screen, in `ui/pr.zig`.
    pr: pr_mod.State = .{},
    /// A network call the loop is making off this thread, with a spinner.
    busy: ?Busy = null,
    /// Questions the box can insert, from `[presets]`. Empty falls back to the
    /// four built-in asks, so the list is never empty.
    presets_cfg: []const config.Preset = &.{},
    finder: search.State = .{},
    notice: Notice = .{},
    /// Soft wrap, from `ui.wrap` and toggled by `zw`. On, a line wider than
    /// the pane continues on the next screen row; off, it is cut at the edge.
    wrap: bool = true,
    /// `[ui] preview`. Held here for the reason `wrap` is: this is the value
    /// in force, not the one on disk. Named for the panel, not for `preview`
    /// above it, which is a file read outside the review.
    list_preview: bool = true,
    /// `[diff] layout`. `|` overrides it for the session by writing an
    /// explicit value here, which is what "manual wins over auto" is.
    layout: config.Layout = .auto,
    /// `[diff] split_min_width`. Below it, `auto` reads flow: two columns
    /// in a pane this narrow are each narrower than the code in them, and the
    /// mode that is worse in the home environment must not appear there.
    split_min_width: u16 = 100,
    /// `[diff] expand_lines`. How much of the file `K` and `J` pull in around
    /// a hunk each press.
    expand_lines: u16 = 10,
    /// Which column of a split row the cursor is in, moved by `H` and `L`.
    /// The new file by default: it is the code that is there now, and it is
    /// what a reference, a comment and a yank are almost always about.
    /// Meaningless in the flow view, where it is still remembered, so
    /// switching back to side by side puts the reader where they left off.
    side: rows_mod.Side = .new,
    /// `[diff] highlight`. It changes no part of the row model and not a
    /// single column of layout, which is why it is the renderer's business and
    /// lives here only to be handed to it.
    highlight: render.Highlight = .line,
    /// The layout `rows` was actually built for. A resize can change what
    /// `auto` resolves to, and the rows are a different list when it does -
    /// so this is what says whether they still match.
    split: bool = false,
    /// Set by `e`. The run loop owns the terminal, so it - not `run(cmd)` -
    /// is what can hand it to a child process.
    want_editor: bool = false,
    /// A review the loop should hand to the forge. Armed rather than done on
    /// the spot: the call takes a second on the network, and the loop draws at
    /// the top of its iteration, so going through here is what puts a
    /// Every outgoing string is a template. Config-owned in
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
    /// `:tired`. The loop owns the screen the glyphs fall off, so this is a
    /// request like `want_editor`.
    want_tired: bool = false,

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
        self.turns.deinit(self.gpa);
        self.outgoing.deinit(self.gpa);
        self.review.deinit();
        self.pick_arena.deinit();
        self.preview_arena.deinit();
        self.comments.deinit();
        self.pick_list.deinit(self.gpa);
        self.finder_state.deinit(self.gpa);
        self.pr.deinit(self.gpa);
        if (self.finder_state.project_paths.len > 0) git.freePaths(self.gpa, self.finder_state.project_paths);
        self.frame_arena.deinit();
        self.* = undefined;
    }

    pub fn files(self: *App) []diff.FileDiff {
        return self.review.files();
    }

    pub fn current(self: *App) ?*diff.FileDiff {
        if (self.preview) |*p| return p;
        return self.review.fileAt(self.file_index);
    }

    /// Reads a file that is not in the review and shows it whole.
    ///
    /// Every line is context, because that is what it is: nothing changed.
    /// The body already renders a file with no hunks correctly, and a line
    /// with a `new_no` is all a note or a reference needs - so browsing,
    /// noting and pointing all work here for free. Highlighting needs one
    /// thing more: the runs index a Buffer, and this file is not one of the
    /// review's, so it gets its own out of the same arena.
    pub fn openPreview(self: *App, path: []const u8) !void {
        _ = self.preview_arena.reset(.retain_capacity);
        self.preview_buf = null;
        const arena = self.preview_arena.allocator();

        // Sniffed before it is read: a video opened by mistake should cost one
        // header read and a row saying what it is, not eight megabytes and a
        // screen of noise.
        var head_buf: [binary.sniff_bytes]u8 = undefined;
        if (fs_mod.readHead(self.io, path, &head_buf)) |head| {
            if (binary.isBinary(head)) {
                const size = if (fs_mod.statFile(self.io, path)) |m| m.size else head.len;
                const bp = try arena.dupe(u8, path);
                self.preview = .{
                    .old_path = bp,
                    .new_path = bp,
                    .status = .binary,
                    .bin = binary.describe(bp, head, size),
                };
                try self.rebuildRows(.reset);
                self.vp.cursor = 0;
                self.vp.scroll = 0;
                self.notice.set("{s} - not text", .{path});
                return;
            }
        }

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
        // Highlighted like any other file. A whole-file lex is around a tenth
        // of a millisecond per thousand lines and the result is cached, so the
        // reason this file used to render plain was never the cost - it was
        // that nothing had built it a Buffer for the runs to index.
        self.preview_buf = buffer.Buffer.initOwned(arena, bytes) catch null;
        try self.rebuildRows(.reset);
        self.vp.cursor = 0;
        self.vp.scroll = 0;
        self.notice.set("{s} - not in the review, {d} lines", .{ path, count });
    }

    /// Any move back into the review drops the preview: it was a detour, and
    /// leaving it visible while `]f` walks the changed files would be two
    /// different answers to "which file am I on".
    pub fn clearPreview(self: *App) void {
        if (self.preview == null) return;
        self.preview = null;
        self.preview_buf = null;
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
        // and the new one at the same moment, and the old
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
        notes.saveComments(self);

        self.rows = rows_mod.Rows.empty;
        self.fn_names = &.{};
        self.prev_hunks = &.{};

        // The agent writing a file must not send the reader back to the top of
        // it, nor leave them on a row that now means something else. The line
        // is re-anchored through `core/anchor.zig`; the row index is only the
        // fallback for a line that is genuinely gone.
        try self.rebuildRows(.line);
    }

    /// `K` and `J`: more of the file around the hunk the cursor is on.
    ///
    /// The cursor holds its *line*, not its row. Growing upwards inserts rows
    /// above it, so keeping the row index would slide the cursor onto whatever
    /// text moved under it - and the scroll offset is left alone on purpose,
    /// which is what makes the new lines appear where the reader was looking
    /// rather than off the top of the pane.
    fn growContext(self: *App, body: u16, dir: expand.Dir) !void {
        const f = self.current() orelse return;
        if (f.summarised or f.status == .binary) return;
        const hi = self.rows.hunkAt(self.vp.cursor) orelse {
            self.notice.set("no hunk here to open out", .{});
            return;
        };
        const line = self.cursorLine();
        const want = self.expand_lines;
        const got = self.review.growContext(f.path(), hi, dir, want) catch 0;
        if (got == 0) {
            self.notice.set("nothing left to show {s} this hunk", .{
                if (dir == .up) "above" else "below",
            });
            return;
        }

        // `current()` is re-read: the file lives in the diff arena and the
        // grow replaced its line arrays.
        try self.rebuildRows(.row);
        if (self.current()) |g| {
            if (line != 0) {
                if (self.rowForFileLine(g, line)) |r| self.vp.cursor = r;
            }
        }
        self.clampScroll(body);
        self.placeCursor();
        self.notice.set("{d} more line{s}", .{ got, if (got == 1) "" else "s" });
    }

    pub fn rebuildRows(self: *App, keep: Keep) !void {
        const f = self.current() orelse {
            self.rows = rows_mod.Rows.empty;
            self.fn_names = &.{};
            self.vp.cursor = 0;
            self.vp.scroll = 0;
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
        self.split = self.effectiveSplit();
        self.rows = try rows_mod.buildWith(
            self.review.allocator(),
            f,
            at.items,
            if (self.split) .split else .flow,
        );
        self.prev_hunks = f.hunks;
        self.fn_names = try self.review.enclosingNames(f);
        var placed = false;
        if (keep == .line) {
            if (try self.review.reanchorLine(f.path())) |ln| {
                if (self.rowForFileLine(f, ln)) |r| {
                    self.vp.cursor = r;
                    placed = true;
                }
            }
        }

        if (!placed) switch (keep) {
            .reset => {
                self.vp.cursor = self.rows.firstLineRow();
                self.vp.scroll = 0;
            },
            // A line that could not be placed keeps the row it had, which is
            // the old behaviour and still the least surprising answer.
            .row, .line => {
                self.vp.cursor = @min(self.vp.cursor, self.rows.len() -| 1);
                // Never leave the cursor on chrome. `moveTo` cannot put it
                // there, but keeping a row index across a rebuild can - and
                // the very first diff is the worst case, where there is no
                // previous position at all and row 0 is the hunk header.
                if (self.vp.cursor < self.rows.firstLineRow()) {
                    self.vp.cursor = self.rows.firstLineRow();
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

    /// Which column of `p` the reader is actually in: the one they asked for,
    /// or the other when the one they asked for is a padding row. A side with
    /// nothing on it is not somewhere the cursor can stand.
    fn sideOn(self: *const App, p: rows_mod.Pair) rows_mod.Side {
        return switch (self.side) {
            .new => if (p.right != null) .new else .old,
            .old => if (p.left != null) .old else .new,
        };
    }

    /// The line on body row `row`, from the column the reader is in.
    ///
    /// `Rows.lineAt` answers structurally - the new side whenever there is one
    /// - because a search, a re-anchor and a row lookup all want the row back
    /// and none of them has a cursor. This is the reader's answer, and it is
    /// what a reference, a yank and a comment are about.
    pub fn lineAt(self: *const App, row: u32) ?u32 {
        const p = self.rows.pairAt(row) orelse return self.rows.lineAt(row);
        return switch (self.sideOn(p)) {
            .old => p.left,
            .new => p.right,
        };
    }

    /// `H` and `L`: the other column of a split row.
    ///
    /// Silent in the flow view rather than refused. There is one column there
    /// and nothing to say about it, and the preference is still worth keeping:
    /// it is where the reader will be when they switch back.
    fn focusSide(self: *App, side: rows_mod.Side) void {
        if (self.side == side) return;
        self.side = side;
        // The column opposite is a different line of a different length.
        self.clampCol();
        self.placeCursor();
    }

    /// The working-tree line under the cursor, 1-based, or 0 when there is
    /// none: chrome has no line, and a deleted line exists only in the old
    /// file, so neither has anything to carry into the next generation.
    pub fn cursorLine(self: *App) u32 {
        const f = self.current() orelse return 0;
        const li = self.lineAt(self.vp.cursor) orelse return 0;
        if (li >= f.lines.new_no.len) return 0;
        return f.lines.new_no[li];
    }

    /// The row drawing working-tree line `ln` of `f`, if the diff shows it.
    /// A re-anchored line often lands in unchanged context that this
    /// generation no longer renders, and that is not a failure: the caller
    /// keeps the row it had.
    pub fn rowForFileLine(self: *const App, f: *const diff.FileDiff, ln: u32) ?u32 {
        for (f.lines.new_no, 0..) |n, li| {
            if (n == ln) return self.rows.rowForLine(@intCast(li));
        }
        return null;
    }

    pub fn view(self: *App, body: u16) ?render.View {
        const f = self.current() orelse return null;
        // A previewed file is not in the review, so it has no buffers there.
        // Its own is the whole file, and the head side of a file nothing
        // changed is the same text - there is nothing to draw as removed.
        const bufs: review_mod.Buffers = if (self.preview_buf) |b|
            .{ .work = b }
        else
            self.review.buffersFor(f.path());
        const drawn = self.drawnTop(body);
        return .{
            .file = f,
            .rows = self.rows,
            .file_index = self.file_index,
            .file_count = @intCast(self.files().len),
            .cursor = self.vp.cursor,
            .cursor_drawn = self.drawnCursor(body),
            .cursor_cell = if (self.cursorCell(body)) |t| self.vp.cursor_anim.cell(t) else null,
            .scroll = drawn.row,
            .skip = drawn.skip,
            .col = self.vp.col,
            .fn_names = self.fn_names,
            .total_hunks = self.review.totalHunks(),
            .hunk_ordinal = self.hunkOrdinal(),
            .work = bufs.work,
            .head = bufs.head,
            .work_runs = self.review.runsFor(f.path(), f.new_blob, bufs.work),
            .head_runs = self.review.runsFor(f.path(), f.old_blob, bufs.head),
            .torn = self.review.torn,
            .hidden = if (self.review.show_ignored) 0 else self.review.hidden,
            .notes = notes.commentMarks(self),
            // Empty unless `--base` or `--target` moved them, so the badge
            // stays `NORMAL` for every ordinary session.
            .base = if (std.mem.eql(u8, self.review.base, "HEAD")) "" else self.review.base,
            .target = self.review.target orelse "",
            .label = self.review.label(),
            .viewing = self.review.viewing,
            .tree_moved = self.review.moved,
            .risk = self.review.risk_total,
            .newer_turns = if (self.snap) |s|
                (if (self.review.viewing) |t| s.state.latest_turn -| t else 0)
            else
                0,
            .fresh = self.review.freshFor(self.file_index),
            .fresh_total = self.review.freshCount(),
            .mark_turn = self.review.mark_at.turn,
            .preview = self.preview != null,
            .mode = self.mode,
            .zen = self.vp.zen,
            .wrap = self.wrap,
            .split = self.split,
            .side = self.side,
            .highlight = self.highlight,
            .selection = self.selection(),
            .prompt = if (self.prompt.open) .{
                .prefix = self.prompt.kind.prefix(),
                .text = self.prompt.text(),
                .completions = self.comp.slice(),
                .completion_at = self.comp_at,
            } else null,
            .notice = self.notice.text(),
            .busy = if (self.busy) |*b| .{ .label = b.label(), .frame = b.spin.frame(self.glyphs.spinner.len) } else null,
            .query = cmdline.liveQuery(self),
            .compose = if (self.compose.open) outgoing.composeView(self, self.frame_arena.allocator()) else null,
        };
    }

    /// 1-based position of the cursor's hunk across the whole review.
    fn hunkOrdinal(self: *App) u32 {
        const local = self.rows.hunkAt(self.vp.cursor) orelse return 0;
        return self.review.hunksBefore(self.file_index) + local + 1;
    }

    // -- commands ------------------------------------------------------------

    pub fn run(self: *App, cmd: keymap.Command, body: u16) !void {
        const was_at = self.vp.scroll;
        const was_in = self.file_index;
        // Anything that is not itself a jump arrives at once: an animation the
        // reader has already moved past is latency, not motion. Another jump
        // is left running, because `anim.Scroll.add` makes the two travel
        // together rather than queueing - which is what holding `<C-d>` is.
        if (!cmd.jumps()) self.settleScroll();
        switch (cmd) {
            .quit => self.quit = true,
            .line_down => self.moveTo(self.vp.cursor +| 1),
            .line_up => self.moveTo(self.vp.cursor -| 1),
            .page_down => self.page(1, body),
            .page_up => self.page(-1, body),
            // The first *line*, which is what the key says: row 0 is the hunk
            // header, and a cursor parked on chrome points at nothing.
            .top => self.moveTo(self.rows.firstLineRow()),
            .bottom => self.moveTo(self.rows.len() -| 1),

            // Within the line. Each sets both columns: this is the reader
            // saying where they want to be, which is what `j` and `k` then
            // try to honour on the next line.
            .char_left => if (motion.charLeft(self.cursorText(), self.vp.col)) |at| self.setCol(at),
            .char_right => if (motion.charRight(self.cursorText(), self.vp.col)) |at| self.setCol(at),
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
                self.vp.col = motion.lineEnd(self.cursorText());
                self.want_col = std.math.maxInt(u32);
            },
            .first_non_blank => self.setCol(motion.firstNonBlank(self.cursorText())),

            // Each of these needs one more keystroke before it can move.
            .find_char => self.pending_find = .{ .target = 0, .forward = true, .till = false },
            .till_char => self.pending_find = .{ .target = 0, .forward = true, .till = true },
            .find_char_back => self.pending_find = .{ .target = 0, .forward = false, .till = false },
            .till_char_back => self.pending_find = .{ .target = 0, .forward = false, .till = true },
            // `;` and `,` repeat whichever walk was last used. A char search
            // is one of them, so after `f(` they behave exactly as vim's do;
            // after `]h` they walk hunks, which is the keystroke this tool
            // spends most and the reason the pair was widened.
            .find_repeat => if (self.last_walk) |w| {
                return self.run(w, body);
            } else if (self.last_find) |f| self.applyFind(f),
            .find_reverse => if (self.last_walk) |w| {
                if (w.opposite()) |back| return self.run(back, body);
            } else if (self.last_find) |f| self.applyFind(f.flip()),
            .next_hunk => try walks.stepHunk(self, 1),
            .prev_hunk => try walks.stepHunk(self, -1),
            .next_break => walks.stepBreak(self, 1),
            .prev_break => walks.stepBreak(self, -1),
            .next_file => {
                self.clearPreview();
                try walks.stepFile(self, 1);
            },
            .prev_file => {
                self.clearPreview();
                try walks.stepFile(self, -1);
            },
            .center => self.centerCursor(body),
            .refresh => try self.rediff(),
            .visual_toggle => self.toggleVisual(.line),
            .visual_char_toggle => self.toggleVisual(.char),
            .visual_cancel => self.leaveVisual(),
            .search_forward => cmdline.openPrompt(self, .search_forward),
            .search_next => try walks.searchStep(self, self.finder.dir),
            .search_prev => try walks.searchStep(self, self.finder.dir.flip()),
            .search_word => try cmdline.searchWord(self, .forward),
            .search_word_back => try cmdline.searchWord(self, .backward),
            .command_line => cmdline.openPrompt(self, .command),
            // The run loop owns the terminal and is the only thing that can
            // lend it out, so this is a request rather than an action.
            .open_editor => self.want_editor = true,
            .tired => self.want_tired = true,
            .send_ref => try outgoing.openCompose(self, .send, .ref),
            .comment_add => {
                if (self.readOnly()) return;
                try notes.commentAdd(self);
            },
            .comment_suggest => try notes.commentSuggest(self),
            .comment_view => try notes.commentView(self, body),
            .comment_list => {
                if (self.mode == .finder) return finder_mod.closeFiles(self);
                if (self.comments.len() == 0) {
                    notes.noComments(self);
                    return;
                }
                self.files_purpose = .comments;
                finder_mod.buildPickList(self);
                finder_mod.show(self, .{
                    .title = " comments ",
                    .keys = finder_mod.commentListKeys(self, self.pick_arena.allocator()),
                });
            },
            .comment_send => try notes.commentSend(self),
            .comment_send_one => try notes.listSendOne(self),
            .comment_post_one => pr_mod.postOne(self),
            .comment_send_all => {
                finder_mod.closeFiles(self);
                try notes.submitReview(self);
                self.rebuildRows(.line) catch {};
            },
            .comment_drop => notes.listDrop(self),
            .comment_delete => notes.commentDelete(self),
            .next_comment => walks.commentStep(self, 1, body),
            .prev_comment => walks.commentStep(self, -1, body),
            .submit_review => {
                if (self.readOnly()) return;
                try notes.submitReview(self);
            },
            .compose_ask => {
                try outgoing.openCompose(self, .send, .ref);
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
            // Git shows three lines either side of a change and forgets the
            // rest; the buffers held the whole file all along. These are the
            // keys that ask for it.
            // The loop owns the bridge, so this only says it wants the list;
            // `want_panes` is the same channel `want_send` is.
            .pick_pane => self.finder_state.want_panes = true,
            .expand_up, .expand_down => try self.growContext(
                body,
                if (cmd == .expand_up) .up else .down,
            ),
            // `zf`: every window in the file, not just the one at the cursor.
            .collapse_context => {
                const f = self.current() orelse return;
                const hi = self.rows.hunkAt(self.vp.cursor) orelse 0;
                if (self.review.foldAllContext(f.path()) catch false) {
                    try walks.foldedTo(self, hi, body);
                    self.notice.set("context folded in this file", .{});
                } else {
                    self.notice.set("no context to fold here", .{});
                }
            },
            .collapse_file => {
                const f = self.current() orelse return;
                // Context the reader pulled in folds before the file does:
                // `zc` closes the innermost thing open at the cursor, which is
                // what it means in vim and what it should mean here. One hunk,
                // because `K` and `J` open one - closing the file's other
                // windows from a hunk the reader is standing nowhere near
                // would be a fold key with a blast radius.
                if (!f.summarised) {
                    if (self.rows.hunkAt(self.vp.cursor)) |hi| {
                        if (self.review.foldContext(f.path(), hi) catch false) {
                            try walks.foldedTo(self, hi, body);
                            self.notice.set("context folded", .{});
                            return;
                        }
                    }
                }
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
                // one; the checkpoint and the snapshot are
                // one thing, so this is one keystroke doing one thing twice
                // rather than two states to keep in step.
                const kept = turns_mod.snapshotMark(self);
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
            .compose_post_now,
            .compose_presets,
            .compose_mention,
            .compose_newline,
            => {},
            .restore_file => try turns_mod.restoreAsk(self),
            .undo_restore => try turns_mod.undoRestore(self, body),
            .turn_list => {
                if (self.mode == .finder) return finder_mod.closeFiles(self);
                try turns_mod.openTurnList(self);
            },
            .next_turn => try turns_mod.turnStep(self, 1, body),
            .prev_turn => try turns_mod.turnStep(self, -1, body),
            .next_risk => try walks.riskStep(self, 1),
            .prev_risk => try walks.riskStep(self, -1),
            .next_fresh => try turns_mod.freshStep(self, 1),
            .prev_fresh => try turns_mod.freshStep(self, -1),
            .copy_text => try outgoing.yank(self, .selection),
            .copy_text_lines => try outgoing.yank(self, .lines),
            .copy_ref => try outgoing.buildPayload(self, .copy, .ref),
            .copy_ref_lines => try outgoing.buildPayload(self, .copy, .ref_lines),
            // Both relay out every row under the cursor, so it is placed
            // rather than walked: zen changes the body's height and wrap
            // changes what every line is worth in screen rows. Travelling
            // across a screen that no longer exists draws a path through
            // nothing (`ui/anim.zig`).
            .toggle_zen => {
                self.vp.zen = !self.vp.zen;
                self.placeCursor();
            },
            // Writes an explicit layout rather than flipping a bool: `auto`
            // is a default, and a reader who has said which one they want has
            // stopped wanting the pane to decide.
            .toggle_split => {
                self.layout = if (self.splitView()) .flow else .split;
                self.relayout(body);
                // What the reader asked for, plus why it did not happen when
                // it did not: a key that reports "off" after being pressed to
                // turn something on reads as a key that failed.
                const on = self.layout == .split;
                const why: []const u8 = if (!on or self.split)
                    ""
                else if (self.vp.cols < rows_mod.min_split_width)
                    " - this pane is too narrow for it"
                else
                    " - this file has nothing to put beside it";
                self.notice.set("side by side {s}{s}", .{ if (on) "on" else "off", why });
            },
            .focus_left => self.focusSide(.old),
            .focus_right => self.focusSide(.new),
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
                finder_mod.toggleFiles(self);
            },
            .pr_list => try pr_mod.openPrList(self, false),
            .file_browse => {
                if (self.mode == .finder) return finder_mod.closeFiles(self);
                self.files_purpose = .browse;
                finder_mod.buildPickList(self);
                finder_mod.show(self, .{ .title = " every file " });
            },
            // One set of list keys, two overlays. Which one they move is the
            // mode, because only one of them can be open.
            .list_down => finder_mod.moveList(self, 1),
            .list_up => finder_mod.moveList(self, -1),
            .list_right => finder_mod.pageList(self, 1),
            .list_left => finder_mod.pageList(self, -1),
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
        self.anchor = self.vp.cursor;
        self.anchor_col = self.vp.col;
    }

    pub fn leaveVisual(self: *App) void {
        self.mode = .normal;
        self.anchor = self.vp.cursor;
        self.anchor_col = self.vp.col;
    }

    /// The selected row range, low to high inclusive, or null outside visual
    /// mode. Normalised here rather than at each use, because a selection made
    /// upwards has the anchor below the cursor and every consumer would
    /// otherwise have to remember that.
    pub fn selection(self: *App) ?render.Selection {
        if (self.mode != .visual) return null;
        const lo = @min(self.anchor, self.vp.cursor);
        const hi = @max(self.anchor, self.vp.cursor);
        if (self.visual_kind == .line) return .{ .lo = lo, .hi = hi };

        // Charwise. Which end holds which column depends on which way the
        // selection was made, and on the same row it is the columns rather
        // than the rows that say.
        const backwards = self.vp.cursor < self.anchor or
            (self.vp.cursor == self.anchor and self.vp.col < self.anchor_col);
        const lo_col = if (backwards) self.vp.col else self.anchor_col;
        const hi_col = if (backwards) self.anchor_col else self.vp.col;

        // Vim's charwise selection includes the character under the cursor;
        // the renderer wants a half-open range, so the conversion happens
        // once, here.
        const end_text = self.textOfRow(hi);
        const end = motion.charRight(end_text, hi_col) orelse @as(u32, @intCast(end_text.len));
        return .{ .lo = lo, .hi = hi, .kind = .char, .lo_col = lo_col, .hi_col = end };
    }

    // -- prompt and search ---------------------------------------------------

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

    /// The rows the overlay will show, for whichever job it was opened to do.
    ///
    /// A jump lists the changed files, because jumping to an unchanged one
    /// means nothing in a review. A mention lists every file git knows about -
    /// changed ones first, in review order, then the rest - because mentioning
    /// an unchanged file to an agent is the whole point of `@`, and the file
    /// you are looking at is the one you are most likely to name.
    /// Lines of a file's diff kept for its panel, and the bytes they may not
    /// exceed. Twenty is what `popup.preview_rows_beside` draws, as a number
    /// rather than an import: `ui/app.zig` must not reach into the renderer.
    /// Every file gets one, so the two together bound a large review.
    pub const preview_lines: usize = 20;
    pub const preview_bytes: usize = 1536;

    /// The most of the pane a box with a panel in it may take. These lists
    /// are opened from the middle of a hunk to answer something about that
    /// hunk, and a box covering the hunk hides it. What does not fit scrolls.
    ///
    /// Eighty and not seventy: a stacked panel spends nine rows before the
    /// list gets any, and seventy left six of sixteen panes on screen.
    pub const picker_share: u8 = 80;

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

    test "a break is a blank line or a piece of chrome, and a note is neither" {
        var fx = try Fixture.init(testing.allocator);
        defer fx.deinit();

        // Row 0 is the hunk header: chrome, and a gap the eye already stops at.
        try testing.expect(walks.isBreak(&fx.app, 0));
        // Rows 1..3 are the file's lines, none of them blank.
        try testing.expect(!walks.isBreak(&fx.app, 1));
        try testing.expect(!walks.isBreak(&fx.app, 2));

        // A line that is nothing but whitespace is blank: it renders as a gap, so
        // it has to behave as one.
        fx.files[0].lines.text[1] = "   \t ";
        try testing.expect(walks.isBreak(&fx.app, 2));
    }

    test "the paragraph motions cross a run of blanks as one gap" {
        var fx = try Fixture.init(testing.allocator);
        defer fx.deinit();

        // Rows: 0 header, 1 code, 2 blank, 3 blank. Two blank lines between two
        // functions is one gap, not two - which is why vim separates paragraphs
        // by "one or more" blank lines, and why pressing `}` twice should cross
        // two gaps rather than the two halves of one.
        fx.files[0].lines.text[1] = "";
        fx.files[0].lines.text[2] = "";
        fx.app.vp.cursor = 1;

        walks.stepBreak(&fx.app, 1);
        try testing.expectEqual(@as(u32, 2), fx.app.vp.cursor);
        // Already inside the run: the next `}` steps out of it, finds no further
        // break, and stops at the end rather than refusing.
        walks.stepBreak(&fx.app, 1);
        try testing.expectEqual(fx.app.rows.len() - 1, fx.app.vp.cursor);
    }

    test "the paragraph motions stop at the ends rather than wrapping" {
        var fx = try Fixture.init(testing.allocator);
        defer fx.deinit();

        // `]h` and `]f` wrap and say so; these do not. vim's paragraph motions
        // stop at the ends of the buffer, and one that silently returned to the
        // top would be a different key wearing the same glyph.
        fx.app.vp.cursor = fx.app.rows.len() - 1;
        walks.stepBreak(&fx.app, 1);
        try testing.expectEqual(fx.app.rows.len() - 1, fx.app.vp.cursor);

        // Backwards, the header is the first break there is; past it the motion
        // lands on the first row that holds a line rather than on chrome.
        fx.app.vp.cursor = 1;
        walks.stepBreak(&fx.app, -1);
        try testing.expectEqual(@as(u32, 0), fx.app.vp.cursor);
        walks.stepBreak(&fx.app, -1);
        try testing.expectEqual(fx.app.rows.firstLineRow(), fx.app.vp.cursor);
    }

    test "auto splits when the pane is wide enough and folds back when it is not" {
        var fx = try Fixture.init(testing.allocator);
        defer fx.deinit();

        // 80 columns is the home environment: a split pane beside an agent, and
        // the layout that is worse there must not appear there.
        try testing.expect(!fx.app.splitView());
        try testing.expect(!fx.app.split);

        try fx.app.handle(.{ .resize = .{ .cols = 140, .rows = 40 } }, 36);
        try testing.expect(fx.app.split);
        try testing.expect(fx.app.rows.pairAt(fx.app.vp.cursor) != null);

        try fx.app.handle(.{ .resize = .{ .cols = 80, .rows = 40 } }, 36);
        try testing.expect(!fx.app.split);
        try testing.expect(fx.app.rows.pairAt(fx.app.vp.cursor) == null);
    }

    test "a re-layout keeps the reader on the line they were reading" {
        var fx = try Fixture.init(testing.allocator);
        defer fx.deinit();

        // The last line of the file rather than the first, so a row index carried
        // across unchanged would be a different line if the models disagreed.
        fx.app.vp.cursor = 3;
        const line = fx.app.rows.lineAt(3).?;

        try fx.app.handle(.{ .resize = .{ .cols = 140, .rows = 40 } }, 36);
        try testing.expectEqual(line, fx.app.rows.lineAt(fx.app.vp.cursor).?);

        try fx.app.handle(.{ .resize = .{ .cols = 80, .rows = 40 } }, 36);
        try testing.expectEqual(line, fx.app.rows.lineAt(fx.app.vp.cursor).?);
    }

    /// The fixture's file is all context, which pairs each line against itself
    /// and so cannot tell the two columns apart. This makes its middle line a
    /// replacement - one removed, one added, in the shape git emits - and lays it
    /// out side by side.
    pub fn splitReplacement(fx: *Fixture) !void {
        const l = &fx.files[0].lines;
        l.kind[1] = .del;
        l.kind[2] = .add;
        l.old_no[1] = 2;
        l.old_no[2] = 0;
        l.new_no[1] = 0;
        l.new_no[2] = 2;

        fx.app.vp.cols = 120;
        fx.app.layout = .split;
        fx.app.relayout(20);
        try testing.expect(fx.app.split);
    }

    test "a hunk header does not send the cursor back across the pane" {
        var fx = try Fixture.init(testing.allocator);
        defer fx.deinit();
        try splitReplacement(fx);

        const halves = rows_mod.Split.of(fx.app.vp.cols);
        const gutter = rows_mod.gutter(&fx.files[0], .split);

        // Row 0 is the hunk header: chrome, drawn across the whole pane, with
        // no pair to take a side from. It takes the reader's side instead, or
        // every `j` over a header would cross the pane and come back.
        fx.app.side = .new;
        fx.app.vp.cursor = 0;
        const right = fx.app.cursorCell(body_rows).?;
        try testing.expectEqual(
            @as(f32, @floatFromInt(halves.column(.new).at + gutter)),
            right.col,
        );

        fx.app.side = .old;
        const left = fx.app.cursorCell(body_rows).?;
        try testing.expectEqual(@as(f32, @floatFromInt(gutter)), left.col);
    }

    test "a label longer than the row still fits the buffer that holds it" {
        var fx = try Fixture.init(testing.allocator);
        defer fx.deinit();

        const long = "#1 " ++ ("a title that runs on and on " ** 12);
        fx.app.review.setLabel(long);
        try testing.expect(fx.app.review.label().len <= 160);
        try testing.expect(std.mem.startsWith(u8, long, fx.app.review.label()));
    }

    test "a comment is a row under the line it is about" {
        var fx = try Fixture.init(testing.allocator);
        defer fx.deinit();
        const f = fx.app.current().?;
        const line = f.lines.new_no[0];

        _ = try fx.app.comments.add(f.path(), line, "mine");
        _ = try fx.app.comments.adopt(f.path(), line, 1, "theirs", "someone", false);
        try fx.app.rebuildRows(.line);

        var seen: usize = 0;
        for (fx.app.rows.items) |r| {
            if (r == .note) seen += 1;
        }
        // Two remarks on one line are two rows under it. Without this the
        // gutter says a remark is there and the screen never shows it.
        try testing.expectEqual(@as(usize, 2), seen);
    }

    test "a charwise selection across lines still covers those lines" {
        // `v` is what a reader reaches for as often as `V`, and a comment
        // anchors to whole lines either way: there is no half a line to
        // suggest a replacement for. Refusing charwise here fell back to the
        // cursor's line, which is the *last* of the selection, so choosing
        // three lines quietly commented on one.
        var fx = try Fixture.init(testing.allocator);
        defer fx.deinit();

        try testing.expect(notes.Range.covers(.{ .lo = 5, .hi = 7, .rows = 3, .skipped = 0 }) == 3);
        try testing.expect(notes.Range.covers(.{ .lo = 5, .hi = 5, .rows = 1, .skipped = 0 }) == 1);
    }

    test "H and L put the cursor in the other column of a split row" {
        var fx = try Fixture.init(testing.allocator);
        defer fx.deinit();
        try splitReplacement(fx);

        // Row 0 is the header, row 1 the context line, row 2 the replacement -
        // the one row where the two columns are different lines.
        const p = fx.app.rows.pairAt(2).?;
        try testing.expectEqual(@as(u32, 1), p.left.?);
        try testing.expectEqual(@as(u32, 2), p.right.?);

        fx.app.vp.cursor = 2;
        // The new file to begin with: it is the code that is there now, and it is
        // what a reference and a comment are almost always about.
        try testing.expectEqual(@as(u32, 2), fx.app.lineAt(2).?);
        try fx.press("H");
        try testing.expectEqual(@as(u32, 1), fx.app.lineAt(2).?);
        try fx.press("L");
        try testing.expectEqual(@as(u32, 2), fx.app.lineAt(2).?);

        // A context row is the same line on both sides, so neither key moves it.
        fx.app.vp.cursor = 1;
        try fx.press("H");
        try testing.expectEqual(@as(u32, 0), fx.app.lineAt(1).?);
    }

    test "a padding row keeps the cursor on the side that has a line" {
        var fx = try Fixture.init(testing.allocator);
        defer fx.deinit();

        // One line removed and nothing put in its place, so the new side of that
        // row is blank. `L` cannot stand there, and must not blank the cursor.
        var del = try Fixture.withDeletion(testing.allocator, 1);
        defer del.deinit();
        del.app.vp.cols = 120;
        del.app.layout = .split;
        del.app.relayout(20);

        const p = del.app.rows.pairAt(2).?;
        try testing.expectEqual(@as(u32, 1), p.left.?);
        try testing.expect(p.right == null);

        del.app.vp.cursor = 2;
        try testing.expectEqual(@as(u32, 1), del.app.lineAt(2).?);
        try del.press("L");
        try testing.expectEqual(@as(u32, 1), del.app.lineAt(2).?);
    }

    test "the split key overrides auto, but not a pane too small to hold it" {
        var fx = try Fixture.init(testing.allocator);
        defer fx.deinit();

        // 80 columns is under `auto`'s threshold and over the floor, so asking
        // for it is granted: the reader has stopped wanting the pane to decide.
        try fx.press("|");
        try testing.expect(fx.app.split);
        try testing.expectEqual(config.Layout.split, fx.app.layout);

        // Widening past the threshold does not undo what they asked for.
        try fx.app.handle(.{ .resize = .{ .cols = 140, .rows = 40 } }, 36);
        try testing.expect(fx.app.split);

        // Below the floor it is suspended rather than forgotten. Two columns of
        // twenty-odd are not a layout, and the reader who shrank the pane wants
        // the view that still works - but the one they named is still on record,
        // so widening it again brings the split straight back.
        try fx.app.handle(.{ .resize = .{ .cols = 48, .rows = 40 } }, 36);
        try testing.expect(!fx.app.split);
        try testing.expectEqual(config.Layout.split, fx.app.layout);
        try fx.app.handle(.{ .resize = .{ .cols = 100, .rows = 40 } }, 36);
        try testing.expect(fx.app.split);

        try fx.press("|");
        try testing.expect(!fx.app.split);
        try testing.expectEqual(config.Layout.flow, fx.app.layout);
    }

    test "a split row is as tall as its taller column, and one when wrap is off" {
        var fx = try Fixture.init(testing.allocator);
        defer fx.deinit();

        // A line far wider than a column of a sixty-four-column pane, which is
        // over the floor and so actually splits.
        fx.files[0].lines.text[1] = "    const value = compute(alpha, beta, gamma, delta, epsilon);";
        fx.app.vp.cols = 64;
        fx.app.layout = .split;
        fx.app.relayout(8);
        try testing.expect(fx.app.split);
        try testing.expect(fx.app.wrap);

        const sp = rows_mod.Split.of(fx.app.vp.cols);
        const col = rows_mod.gutter(fx.app.current().?, .split);
        const lines = fx.app.current().?.lines;

        var wrapped: u32 = 0;
        var row: u32 = 0;
        while (row < fx.app.rows.len()) : (row += 1) {
            const p = fx.app.rows.pairAt(row) orelse continue;
            const want = wrap_mod.pairHeight(
                if (p.left) |li| lines.text[li] else null,
                sp.left -| col,
                if (p.right) |li| lines.text[li] else null,
                sp.right_width -| col,
                fx.app.vp.metrics,
                8,
            );
            // Both columns are given the same rows, so neither slides past the
            // other - that is what makes a wrapped split readable at all.
            try testing.expectEqual(want, fx.app.rowHeight(row, 8));
            if (want > 1) wrapped += 1;
        }
        try testing.expect(wrapped > 0);

        // `zw` still turns it off, and then a split row is one row like any other.
        fx.app.wrap = false;
        row = 0;
        while (row < fx.app.rows.len()) : (row += 1) {
            try testing.expectEqual(@as(u16, 1), fx.app.rowHeight(row, 8));
        }
    }

    // -- the bridge ----------------------------------------------------------

    /// Where a composed payload is going. The loop performs it; this is the
    /// request, because only the loop owns the terminal and the subprocess.
    pub const Delivery = enum { send, copy };

    /// What the tool is waiting on. The label is owned inline: it outlives the
    /// keystroke that set it by a second, which is long enough for whatever
    /// arena it came from to have gone.
    pub const Busy = struct {
        buf: [64]u8 = undefined,
        len: u8 = 0,
        spin: anim.Spinner = .{},

        pub fn label(self: *const Busy) []const u8 {
            return self.buf[0..self.len];
        }
    };

    /// Says what is happening and starts the spinner. The caller returns, and
    /// the loop draws this frame before anything blocks.
    pub fn startBusy(self: *App, comptime fmt: []const u8, args: anytype) void {
        var b: Busy = .{};
        const text = std.fmt.bufPrint(&b.buf, fmt, args) catch b.buf[0..0];
        b.len = @intCast(text.len);
        self.busy = b;
    }

    /// What to compose. `ask` carries its own template rather than an enum the
    /// dispatch would have to translate back into one.
    pub const What = union(enum) {
        ref,
        ref_lines,
        ask: []const u8,
    };

    /// A reference, before a template turns it into text.
    ///
    /// Every field resolves against the *new* file: a line
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

    /// Builds the payload and hands it to the loop. Nothing here talks to a
    /// bridge: `core/` and `ui/app.zig` are both testable without one, and
    /// this is the file the tests are in.
    /// How much of the line a yank takes.
    pub const Extent = enum {
        /// What is actually selected: the characters under a charwise
        /// selection, the whole lines under a linewise one.
        selection,
        /// Whole lines regardless, which is what vim's `Y` does to a charwise
        /// selection.
        lines,
    };

    // -- notes ---------------------------------------------------------------

    pub const Spot = struct { bucket: u8, fi: u32, path: []const u8, line: u32 };

    // -- $EDITOR -------------------------------------------------------------

    pub const EditTarget = struct {
        path: []const u8,
        /// 0 means "no line": open at the top rather than at a line number
        /// that does not exist in the file on disk.
        line: u32,
    };

    /// What `e` should open. References resolve against the *new* file
    ///, so a cursor on a deleted line - which has no new-file
    /// line of its own - falls back to where the deletion happened.
    pub fn editTarget(self: *App) ?EditTarget {
        const f = self.current() orelse return null;
        if (f.status == .deleted) return null;
        // Every failure below means the same thing - open the file, at no
        // particular line - so it is written once and returned from.
        const top: EditTarget = .{ .path = f.path(), .line = 0 };

        const li = self.lineAt(self.vp.cursor) orelse return top;
        if (li >= f.lines.len()) return top;
        if (f.lines.kind[li] != .del) return .{ .path = f.path(), .line = f.lines.new_no[li] };

        const hi = self.rows.hunkAt(self.vp.cursor) orelse return top;
        if (hi >= f.hunks.len) return top;
        return .{ .path = f.path(), .line = f.hunks[hi].new_start };
    }

    pub fn moveTo(self: *App, row: u32) void {
        const n = self.rows.len();
        if (n == 0) {
            self.vp.cursor = 0;
            self.vp.col = 0;
            return;
        }
        self.vp.cursor = @min(row, n - 1);
        // The column follows what was last asked for rather than what the
        // previous line happened to allow, which is the whole point of
        // keeping the two apart.
        self.vp.col = motion.clamp(self.cursorText(), self.want_col);
    }

    // -- the column ----------------------------------------------------------

    /// The text under the cursor, or empty on a row that is chrome. Every
    /// motion reads through this, so a header is a line of no characters
    /// rather than a special case at each call site.
    pub fn cursorText(self: *App) []const u8 {
        return self.textOfRow(self.vp.cursor);
    }

    pub fn textOfRow(self: *App, row: u32) []const u8 {
        const f = self.current() orelse return "";
        const li = self.lineAt(row) orelse return "";
        if (li >= f.lines.len()) return "";
        return f.lines.text[li];
    }

    /// Moves the cursor within its line. Both columns, because this is the
    /// reader saying where they want to be - the vertical motions are what
    /// keep `want_col` and let `col` give way.
    pub fn setCol(self: *App, at: u32) void {
        self.vp.col = at;
        self.want_col = at;
    }

    /// Puts the column back on a boundary of the line it is now in. Every
    /// rebuild needs it: the row can survive a re-diff while the text on it
    /// becomes shorter, or becomes something else entirely.
    fn clampCol(self: *App) void {
        self.vp.col = motion.clamp(self.cursorText(), self.vp.col);
    }

    /// Applies a motion that may have nowhere to go on this line. `w` and `b`
    /// carry on into the neighbouring line the way vim does; the character
    /// motions stop, because `h` at column zero has always stopped.
    fn stepWord(self: *App, forward: bool, width: motion.Width) void {
        const text = self.cursorText();
        const found = if (forward)
            motion.wordNext(text, self.vp.col, width)
        else
            motion.wordPrev(text, self.vp.col, width);
        if (found) |at| return self.setCol(at);

        // Nothing left on this line: cross to the neighbouring one and take
        // its first or last word. Chrome is stepped over - a hunk header is
        // not a word - but an empty *line* is one, the way it is in vim, so a
        // blank between two paragraphs is a place the cursor can be.
        const last = self.rows.len() -| 1;
        var row = self.vp.cursor;
        while (if (forward) row < last else row > 0) {
            row = if (forward) row + 1 else row - 1;
            if (self.lineAt(row) == null) continue;
            const next = self.textOfRow(row);
            self.vp.cursor = row;
            self.setCol(if (forward) motion.firstNonBlank(next) else motion.lastWordStart(next, width));
            return;
        }
    }

    /// `e` and `E`, which cross into the next line the way `w` does - but over
    /// an empty one rather than onto it, because an empty line has no word
    /// whose end the cursor could sit on.
    fn stepWordEnd(self: *App, width: motion.Width) void {
        if (motion.wordEnd(self.cursorText(), self.vp.col, width)) |at| return self.setCol(at);

        const last = self.rows.len() -| 1;
        var row = self.vp.cursor;
        while (row < last) {
            row += 1;
            if (self.lineAt(row) == null) continue;
            const at = motion.firstWordEnd(self.textOfRow(row), width) orelse continue;
            self.vp.cursor = row;
            self.setCol(at);
            return;
        }
    }

    /// `f`, `t`, `F`, `T`, and the `;`/`,` that repeat them.
    fn applyFind(self: *App, f: motion.Find) void {
        self.last_find = f;
        const text = self.cursorText();
        if (motion.find(text, self.vp.col, f)) |at| return self.setCol(at);
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
    pub fn readOnly(self: *App) bool {
        const turn = self.review.viewing orelse return false;
        var k: [32]u8 = undefined;
        self.notice.set("turn {d} is read only - {s} returns to the working tree", .{
            turn, self.keyFor(.next_turn, .normal, &k),
        });
        return true;
    }

    pub fn keyFor(self: *App, cmd: keymap.Command, mode: event.Mode, buf: []u8) []const u8 {
        return keytext.firstKeyFor(self.km.bindings, cmd, mode, buf);
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
            // A split row is as tall as its taller column, so the two stay
            // aligned and neither is cut off at the divider.
            if (self.rows.pairAt(row)) |p| {
                const sp = rows_mod.Split.of(self.vp.cols);
                const col = rows_mod.gutter(f, .split);
                return wrap_mod.pairHeight(
                    if (p.left) |li| f.lines.text[li] else null,
                    sp.left -| col,
                    if (p.right) |li| f.lines.text[li] else null,
                    sp.right_width -| col,
                    self.vp.metrics,
                    cap,
                );
            }
        }
        const li = self.lineAt(row) orelse return 1;
        if (li >= f.lines.text.len) return 1;
        return wrap_mod.height(
            f.lines.text[li],
            self.vp.cols -| rows_mod.gutter(f, .flow),
            self.vp.metrics,
            cap,
            .follow,
        );
    }

    /// The body as `ui/viewport.zig` needs to see it. One adapter rather than
    /// a row count and a height callback threaded through every call: the
    /// viewport asks three questions about numbers, and this is where the
    /// numbers come from.
    const Body = struct {
        app: *App,
        rows_tall: u16,

        pub fn count(self: Body) u32 {
            return self.app.rows.len();
        }
        pub fn at(self: Body, row: u32) u16 {
            return self.app.rowHeight(row, self.rows_tall);
        }
        pub fn body(self: Body) u16 {
            return self.rows_tall;
        }
    };

    fn bodyOf(self: *App, rows_tall: u16) Body {
        return .{ .app = self, .rows_tall = rows_tall };
    }

    fn commentHeight(self: *App, row: u32, cap: u16) u16 {
        const ni = self.rows.items[row].note;
        const marks = notes.commentMarks(self);
        if (ni >= marks.len) return 1;
        const col: u16 = if (self.vp.cols > 8) 6 else 0;
        const width = self.vp.cols -| col -| 2;
        if (width == 0) return 1;

        var rows: u16 = 0;
        var lines = std.mem.splitScalar(u8, marks[ni].body, '\n');
        while (lines.next()) |line| {
            rows +|= wrap_mod.height(line, width, self.vp.metrics, cap, .flush);
        }
        return @max(@min(rows, cap), 1);
    }

    /// Arrive now, and put the cursor rather than travel it. Kept as methods
    /// on `App` because the run loop calls them and has no viewport of its
    /// own; each is the one line it looks like.
    pub fn settleScroll(self: *App) void {
        self.vp.settle();
    }

    pub fn placeCursor(self: *App) void {
        self.vp.place();
    }

    pub fn clampScroll(self: *App, body: u16) void {
        self.vp.clampScroll(self.bodyOf(body), self.nav.scrolloff);
    }

    fn drawnTop(self: *App, body: u16) viewport.Top {
        return self.vp.drawnTop(self.bodyOf(body));
    }

    fn drawnCursor(self: *App, body: u16) u32 {
        return self.vp.drawnCursor(self.bodyOf(body));
    }

    fn page(self: *App, dir: i32, body: u16) void {
        self.moveTo(self.vp.pageTo(self.bodyOf(body), dir));
    }

    fn centerCursor(self: *App, body: u16) void {
        self.vp.centre(self.bodyOf(body));
    }

    pub fn animateFrom(self: *App, was_at: u32, body: u16) void {
        self.vp.animateFrom(self.bodyOf(body), was_at);
    }

    fn rowBelow(self: *App, from: u32, screens: u16, body: u16) u32 {
        return self.vp.rowBelow(self.bodyOf(body), from, screens);
    }

    fn rowAbove(self: *App, from: u32, screens: u16, body: u16) u32 {
        return self.vp.rowAbove(self.bodyOf(body), from, screens);
    }

    fn screenRowsBetween(self: *App, from: u32, to: u32, body: u16) i32 {
        return self.vp.screenRowsBetween(self.bodyOf(body), from, to);
    }

    pub fn animating(self: *App, body: u16) bool {
        // The one animation with nothing to arrive at: it paces frames so the
        // spinner turns.
        if (self.busy != null) return true;
        if (self.vp.scroll_anim.active()) return true;
        const target = self.cursorCell(body) orelse return false;
        return self.vp.cursor_anim.travelling(target);
    }

    /// One frame of both animations. The viewport moves first, because where
    /// the cursor belongs on screen depends on where the viewport has got to.
    pub fn stepAnim(self: *App, dt_ms: f32, body: u16) void {
        if (self.busy) |*b| b.spin.step(dt_ms);
        self.vp.scroll_anim.step(dt_ms);
        if (self.cursorCell(body)) |target| self.vp.cursor_anim.step(target, dt_ms);
    }

    /// Whether the reader has two columns, as far as the pane and the config
    /// are concerned. A question and not a field because `auto` asks the pane,
    /// which changes under a resize.
    pub fn splitView(self: *const App) bool {
        // The floor first, and it applies to a layout that was asked for as
        // much as to one that was inferred. Below it there is no split to be
        // had - only two columns too narrow to hold a line of code - and a
        // reader who pressed `|` in a wide pane and then shrank it wants the
        // view that still works, not the one they last named.
        if (self.vp.cols < rows_mod.min_split_width) return false;
        return switch (self.layout) {
            .flow => false,
            .split => true,
            .auto => self.vp.cols >= self.split_min_width,
        };
    }

    /// The same, once the file on screen has had its say.
    ///
    /// A file with no hunks is one being *read* rather than reviewed - a whole
    /// file opened with `<Space>F`. Both of its sides are the same text, so
    /// splitting would draw it twice and halve the code on screen to say
    /// nothing.
    fn effectiveSplit(self: *App) bool {
        if (!self.splitView()) return false;
        const f = self.current() orelse return false;
        return f.hunks.len > 0;
    }

    /// Rebuilds the rows when the effective layout has changed, keeping the
    /// reader where they were. The line under the cursor is the anchor, not
    /// the row index: the two layouts number the same file differently, so a
    /// preserved row number is a different line.
    ///
    /// The scroll offset follows the cursor rather than being carried on its
    /// own, so the row the reader was looking at stays the same distance down
    /// the pane instead of the viewport landing somewhere near it.
    fn relayout(self: *App, body: u16) void {
        if (self.effectiveSplit() == self.split) return;
        const line = self.lineAt(self.vp.cursor);
        const offset = self.vp.cursor -| self.vp.scroll;
        self.rebuildRows(.row) catch return;
        if (line) |li| {
            if (self.rows.rowForLine(li)) |r| self.vp.cursor = r;
        }
        self.vp.scroll = self.vp.cursor -| offset;
        self.clampCol();
        self.clampScroll(body);
        self.placeCursor();
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

        // Whichever column `lineAt` chose, and never outside it: a cursor
        // standing in the other half would say the reader is pointing at a
        // line they are not.
        //
        // Chrome has no pair to take a side from, so it takes the reader's.
        // A hunk header is drawn across the whole pane and is shorter than the
        // code either side of it, so the column that fits it is the one the
        // cursor is already in - and crossing the pane to sit on a header and
        // crossing back on the next `j` reads as the view losing the reader's
        // place. A row that genuinely has nothing on one side is a different
        // case and still moves the cursor, which is `sideOn`'s answer.
        const halves = rows_mod.Split.of(self.vp.cols);
        const half: ?rows_mod.Split.Column = if (self.rows.pairAt(row)) |p|
            halves.column(self.sideOn(p))
        else if (self.split)
            halves.column(self.side)
        else
            null;
        const base: u16 = if (half) |h| h.at else 0;
        const column: u16 = if (half) |h| h.width else self.vp.cols;
        const gutter = rows_mod.gutter(f, if (half == null) .flow else .split);

        // A hunk header or a rule has no line to find a column in, but the
        // cursor is still on it: `j` steps through chrome like any other row.
        // Parking it at the first text column keeps it visible and keeps it
        // moving - returning null here blinks it out for a frame and then
        // teleports it, which is what a held `j` looked like.
        const parked: anim.Cursor.Cell = .{
            .row = @floatFromInt(y),
            .col = @floatFromInt(base + gutter),
        };
        const li = self.lineAt(row) orelse return parked;
        if (li >= f.lines.len()) return parked;

        const avail = if (self.wrap) column -| gutter else 0;
        const cell = wrap_mod.locate(f.lines.text[li], avail, self.vp.metrics, self.vp.col);
        return .{
            .row = @floatFromInt(y + @as(i32, cell.row)),
            .col = @floatFromInt(base + @min(gutter + cell.col, column -| 1)),
        };
    }

    pub fn handle(self: *App, ev: event.Event, body: u16) !void {
        switch (ev) {
            .quit => self.quit = true,
            .key => |k| {
                // While a prompt is open the keys are text, not actions, so
                // they never reach the keymap.
                if (self.mode == .command) return cmdline.feedPrompt(self, k, body);
                if (self.mode == .help) return self.feedHelp(k, body);
                if (self.mode == .finder) return finder_mod.feedFiles(self, k, body);
                if (self.mode == .note_input) return outgoing.feedCompose(self, k, body);
                // A notice describes the last keystroke, so the next one
                // clears it - and clearing before dispatch means the command
                // about to run can leave one of its own.
                self.notice.clear();
                // `f` and its three siblings each take the next key as the
                // character to search for, never as a command. Escape gives up
                // on one, so a mistyped `f` is not a key that eats the next.
                // A restore waiting on its answer takes the next key, and
                // takes it before anything else can claim it: while this is
                // pending there is no command the reader could mean.
                if (self.turns.pending != null) {
                    try turns_mod.restoreAnswer(self, k, body);
                    self.clampScroll(body);
                    return;
                }
                if (self.pending_find) |p| {
                    self.pending_find = null;
                    if (k.codepoint != event.code.escape) {
                        self.applyFind(.{ .target = k.codepoint, .forward = p.forward, .till = p.till });
                    }
                    self.clampScroll(body);
                    return;
                }
                switch (self.km.feed(k, self.mode)) {
                    .command => |cmd| {
                        turns_mod.rememberWalk(self, cmd);
                        try self.run(cmd, body);
                    },
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
                // view must never do.
                if (self.review.viewing != null) {
                    self.review.moved = true;
                    return;
                }
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
                self.vp.cols = size.cols;
                // Before the clamp, because a `layout = "auto"` crossing its
                // threshold changes how many rows there are to clamp against.
                self.relayout(body);
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
            // press anything.
            .agent_quiescent => _ = turns_mod.snapshotTurn(self),
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

const testing = std.testing;

// Zig collects tests from a file only when a `test` block references it.
// Without a list like this one, every test under `ui/` compiled into the
// binary but ran nowhere - which is how a render test with the wrong arity sat
// green through a whole phase. Each module lists what it imports, so a new
// module joins `zig build check` where it is used: the ones the run loop pulls
// in are listed in `loop.zig`, and `main.zig` covers the rest.
test {
    _ = template;
    _ = cmdline;
    _ = devicon;
    _ = finder_mod;
    _ = notes;
    _ = outgoing;
    _ = pr_mod;
    _ = turns_mod;
    _ = walks;
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
    _ = complete;
    _ = theme_mod;
}

// -- pure arithmetic: no fixture, no rows, no terminal -------------------

// -- the fixture ---------------------------------------------------------

/// A two-file review built in memory: enough for the command layer without a
/// repository, a terminal or a subprocess. The lines are chosen so each token
/// appears in exactly one file, which is what makes the cross-file search
/// assertions unambiguous.
pub const Fixture = struct {
    threaded: std.Io.Threaded,
    queue: event.Queue,
    app: App,
    files: []diff.FileDiff,
    gpa: Allocator,

    const a_text = [_][]const u8{ "fn alpha() {", "    const x = 1;", "}" };
    const b_text = [_][]const u8{ "fn beta() {", "    const token = 2;", "}" };

    pub fn linesOf(gpa: Allocator, texts: []const []const u8, deleted_at: ?usize) !hunk.DiffLines {
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
    pub fn init(gpa: Allocator) !*Fixture {
        return build(gpa, null);
    }

    /// A review with no files in it. The state a pane sits in whenever the
    /// tree is clean, which is most of the day.
    pub fn emptyReview(gpa: Allocator) !*Fixture {
        const self = try build(gpa, null);
        self.app.review.parsed.?.diff.files = self.files[0..0];
        try self.app.rebuildRows(.reset);
        return self;
    }

    /// The same, with one line of the first file deleted - the case `e` and
    /// the bridge both have to handle, because a deleted line has no line in
    /// the new file to point at.
    pub fn withDeletion(gpa: Allocator, at: usize) !*Fixture {
        return build(gpa, at);
    }

    pub fn build(gpa: Allocator, deleted_at: ?usize) !*Fixture {
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
    pub fn summarised(gpa: Allocator) !*Fixture {
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

    pub fn deinit(self: *Fixture) void {
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
    pub fn press(self: *Fixture, sequence: []const u8) !void {
        var buf: [keymap.Keymap.max_sequence]keymap.Chord = undefined;
        for (try keytext.parseChords(sequence, &buf)) |ch| {
            // Shift as well as ctrl: without it `<S-Tab>` arrives as `<Tab>`
            // and no test can tell a key from its reverse.
            try self.app.handle(.{ .key = .{
                .codepoint = ch.cp,
                .mods = .{ .ctrl = ch.ctrl, .shift = ch.shift },
            } }, body_rows);
        }
    }

    /// Literal text, for a prompt that is collecting some. Spelled out rather
    /// than routed through `press`, because inside a prompt these are letters
    /// and not keys - which is the distinction half of these tests are about.
    pub fn typeIn(self: *Fixture, text: []const u8) !void {
        for (text) |ch| {
            try self.app.handle(.{ .key = .{ .codepoint = ch, .mods = .{} } }, body_rows);
        }
    }

    pub fn expectCursor(self: *Fixture, row: u32) !void {
        try testing.expectEqual(row, self.app.vp.cursor);
    }

    pub fn expectFile(self: *Fixture, index: u32) !void {
        try testing.expectEqual(index, self.app.file_index);
    }

    pub fn expectMode(self: *Fixture, mode: event.Mode) !void {
        try testing.expectEqual(mode, self.app.mode);
    }

    /// The notice says what it should, without pinning the exact wording: the
    /// assertion is that the reader was told, not how it was phrased.
    pub fn expectNotice(self: *Fixture, needle: []const u8) !void {
        const text = self.app.notice.text();
        if (std.mem.indexOf(u8, text, needle) == null) {
            std.debug.print("notice was \"{s}\", expected it to mention \"{s}\"\n", .{ text, needle });
            return error.TestExpectedNotice;
        }
    }

    pub fn expectNoNotice(self: *Fixture) !void {
        try testing.expectEqual(@as(usize, 0), self.app.notice.text().len);
    }
};

/// The body height every fixture test drives with: a 26-row pane, less chrome.
pub const body_rows: u16 = 22;

// -- the column ------------------------------------------------------------

test "the column moves within the line and stops at both ends" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    // Row 1 is `fn alpha() {`.
    try fx.expectCursor(1);
    try testing.expectEqual(@as(u32, 0), fx.app.vp.col);

    try fx.press("l");
    try fx.press("l");
    try testing.expectEqual(@as(u32, 2), fx.app.vp.col);
    try fx.press("h");
    try testing.expectEqual(@as(u32, 1), fx.app.vp.col);

    // `h` at the first column is a key that does nothing, not an underflow.
    try fx.press("h");
    try fx.press("h");
    try testing.expectEqual(@as(u32, 0), fx.app.vp.col);

    // `$` is the last character, never the position after it.
    try fx.press("$");
    try testing.expectEqual(@as(u32, 11), fx.app.vp.col);
    try fx.press("l");
    try testing.expectEqual(@as(u32, 11), fx.app.vp.col);
    try fx.press("0");
    try testing.expectEqual(@as(u32, 0), fx.app.vp.col);
}

test "word motions step by class and carry into the next line" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    // `fn alpha() {` - a class change is a boundary, so `(` is its own word.
    try fx.press("w");
    try testing.expectEqual(@as(u32, 3), fx.app.vp.col);
    try fx.press("w");
    try testing.expectEqual(@as(u32, 8), fx.app.vp.col);
    try fx.press("e");
    try testing.expectEqual(@as(u32, 9), fx.app.vp.col);

    // Off the end of the line, `w` carries into the next one rather than
    // stopping - and lands on its first non-blank, past the indentation.
    try fx.press("$");
    try fx.press("w");
    try fx.expectCursor(2);
    try testing.expectEqual(@as(u32, 4), fx.app.vp.col);

    // And `b` comes back to the last word of the line above.
    try fx.press("0");
    try fx.press("b");
    try fx.expectCursor(1);
    try testing.expectEqual(@as(u32, 11), fx.app.vp.col);
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
    try testing.expectEqual(@as(u32, 0), fx.app.vp.col);

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
    try testing.expectEqual(@as(u32, 8), fx.app.vp.col);

    try fx.press("0");
    try fx.press("W");
    try testing.expectEqual(@as(u32, 3), fx.app.vp.col);
    try fx.press("W");
    try testing.expectEqual(@as(u32, 11), fx.app.vp.col);

    // `E` runs to the end of the blob rather than to the end of `alpha`.
    try fx.press("0");
    try fx.press("E");
    try testing.expectEqual(@as(u32, 1), fx.app.vp.col);
    try fx.press("E");
    try testing.expectEqual(@as(u32, 9), fx.app.vp.col);

    // And `B` comes back over the whole of it.
    try fx.press("$");
    try fx.press("B");
    try testing.expectEqual(@as(u32, 3), fx.app.vp.col);
}

test "the wanted column survives a short line and comes back on a long one" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    // Column 10 of `fn alpha() {`, then down onto `}`, which has one column.
    try fx.press("$");
    try fx.press("j");
    try fx.press("j");
    try fx.expectCursor(3);
    try testing.expectEqual(@as(u32, 0), fx.app.vp.col);

    // Back up, and the column the reader asked for is where they land - the
    // short line clamped the cursor without forgetting what was wanted.
    try fx.press("k");
    try testing.expectEqual(@as(u32, 15), fx.app.vp.col);
    try fx.press("k");
    try testing.expectEqual(@as(u32, 11), fx.app.vp.col);
}

test "f waits for a character, and Escape gives up on it" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    // `fn alpha() {`: `f(` lands on the paren, `t(` one short of it.
    try fx.press("f");
    try testing.expect(fx.app.pending_find != null);
    try fx.press("(");
    try testing.expectEqual(@as(u32, 8), fx.app.vp.col);
    try testing.expect(fx.app.pending_find == null);

    try fx.press("0");
    try fx.press("t");
    try fx.press("(");
    try testing.expectEqual(@as(u32, 7), fx.app.vp.col);

    // `;` repeats it and `,` reverses it.
    try fx.press("0");
    try fx.press("f");
    try fx.press("a");
    try testing.expectEqual(@as(u32, 3), fx.app.vp.col);
    try fx.press(";");
    try testing.expectEqual(@as(u32, 7), fx.app.vp.col);
    try fx.press(",");
    try testing.expectEqual(@as(u32, 3), fx.app.vp.col);

    // A character that is not on the line says so rather than moving.
    try fx.press("f");
    try fx.press("z");
    try fx.expectNotice("no 'z'");
    try testing.expectEqual(@as(u32, 3), fx.app.vp.col);

    // Escape abandons a pending find, so a mistyped `f` does not eat the key
    // after it.
    try fx.press("f");
    try fx.press("<Esc>");
    try testing.expect(fx.app.pending_find == null);
    try fx.press("0");
    try testing.expectEqual(@as(u32, 0), fx.app.vp.col);
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

// -- the viewport catching up ---------------------------------------------

test "a jump animates and a single row does not" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    fx.app.vp.scroll_anim.budget_ms = 250;

    // Nothing to animate: the fixture is four rows in a 22-row body, so no
    // motion in it scrolls at all.
    try fx.press("j");
    try testing.expect(!fx.app.animating(body_rows));

    // A jump that does scroll starts the viewport catching up, displaced by
    // the screen rows it travelled.
    fx.app.vp.scroll = 0;
    fx.app.vp.cursor = 3;
    fx.app.animateFrom(2, body_rows);
    try testing.expect(fx.app.animating(body_rows));
    try testing.expectEqual(@as(i32, -2), fx.app.vp.scroll_anim.rows());

    // And it settles on its own.
    var guard: u32 = 0;
    while (fx.app.animating(body_rows) and guard < 100) : (guard += 1) fx.app.stepAnim(16, body_rows);
    try testing.expect(!fx.app.animating(body_rows));
}

test "stepping is instant and only a jump is animated" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    fx.app.vp.scroll_anim.budget_ms = 250;

    // A wrapped line makes one `j` worth three screen rows, which is exactly
    // the case that used to start an animation per keystroke: a held `j` then
    // spends its life cancelling the last one, which reads as stutter and
    // costs a frame of input latency per key.
    fx.files[0].lines.text[1] = "a line long enough that a narrow pane has to break it more than once";
    fx.app.vp.cols = 30;
    fx.app.vp.scroll = 0;
    fx.app.vp.cursor = 1;
    try fx.app.run(.line_down, 4);
    try testing.expect(!fx.app.animating(body_rows));

    // The same movement asked for as a jump does animate.
    fx.app.vp.scroll = 0;
    fx.app.vp.cursor = 1;
    try fx.app.run(.page_down, 4);
    try testing.expect(fx.app.animating(body_rows));
}

test "the cursor travels for every motion, not only for a jump" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    // Placed where it belongs the first time it is drawn: there is nowhere to
    // travel from yet.
    const first = fx.app.cursorCell(body_rows).?;
    _ = fx.app.vp.cursor_anim.cell(first);
    try testing.expect(!fx.app.animating(body_rows));

    // A column motion is a motion: the cursor has ground to cover, and the
    // viewport - which only animates for a jump - has none.
    try fx.press("$");
    try testing.expect(fx.app.animating(body_rows));
    try testing.expect(!fx.app.vp.scroll_anim.active());

    // And it gets there, a cell at a time.
    var guard: u32 = 0;
    while (fx.app.animating(body_rows) and guard < 200) : (guard += 1) fx.app.stepAnim(16, body_rows);
    try testing.expect(guard > 1);
    // Rounded, because that is the cell the renderer draws: the travel stops
    // when it is within a fraction of the target rather than when the float
    // lands on it exactly, so an exact comparison here was only ever passing
    // for the distances that happened to divide evenly.
    const want = fx.app.cursorCell(body_rows).?;
    const got = fx.app.vp.cursor_anim.at.?;
    try testing.expectEqual(@round(want.row), @round(got.row));
    try testing.expectEqual(@round(want.col), @round(got.col));
}

test "a row with no line still has a cell for the cursor to be on" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    // Row 0 is the hunk header. `j` steps through chrome like any other row,
    // and a cursor with nowhere to be blinks out for a frame and then
    // teleports - which is what a held `j` used to look like.
    fx.app.vp.cursor = 0;
    const cell = fx.app.cursorCell(body_rows).?;
    try testing.expectEqual(@as(f32, 0), cell.row);
    try testing.expectEqual(@as(f32, @floatFromInt(rows_mod.gutter(&fx.files[0], .flow))), cell.col);
}

test "the cursor keeps its place on screen while the text slides under it" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    fx.app.vp.scroll_anim.budget_ms = 250;

    // Settled, the drawn cursor is the cursor. Far enough from the top that
    // the walk has room: displaced past the first row it clamps there, and the
    // gap closes because the screen has run out of file rather than because
    // anything moved wrongly.
    fx.app.vp.scroll = 2;
    fx.app.vp.cursor = 3;
    try testing.expectEqual(@as(u32, 3), fx.app.drawnCursor(body_rows));

    // Mid-flight, both are displaced by the same amount, so the cursor's
    // screen position - the gap between them - does not change. Left at its
    // settled row it would snap half a page away on the first frame and crawl
    // back, which is the text and the cursor moving opposite ways.
    fx.app.vp.scroll_anim.offset = 2;
    const top = fx.app.drawnTop(body_rows);
    const cur = fx.app.drawnCursor(body_rows);
    try testing.expectEqual(@as(u32, 0), top.row);
    try testing.expectEqual(@as(u32, 1), cur);
    try testing.expectEqual(fx.app.vp.cursor - fx.app.vp.scroll, cur - top.row);
}

test "a second jump joins the first rather than cancelling it" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    fx.app.vp.scroll_anim.budget_ms = 250;
    // Tall enough to have somewhere to scroll to: three of the four rows wrap
    // onto three screen rows each in a narrow pane.
    for (0..3) |i| fx.files[0].lines.text[i] = "a line long enough that a narrow pane has to break it more than once";
    fx.app.vp.cols = 30;

    fx.app.vp.scroll = 0;
    fx.app.vp.cursor = 1;
    try fx.app.run(.page_down, 4);
    try testing.expect(fx.app.animating(body_rows));
    const first = fx.app.vp.scroll_anim.offset;

    // Another jump arriving mid-flight adds to what is left: the reader asked
    // to be further away, not to wait twice as long.
    fx.app.vp.scroll = 0;
    fx.app.vp.cursor = 1;
    try fx.app.run(.page_down, 4);
    try testing.expect(fx.app.vp.scroll_anim.offset > first);

    // Anything that is not a jump arrives at once instead.
    try fx.app.run(.line_down, 4);
    try testing.expect(!fx.app.animating(body_rows));
}

test "the drawn viewport is where the settled one is, once it arrives" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    // Settled: the row drawn first is the row scrolled to, with nothing of it
    // above the top of the pane.
    fx.app.vp.scroll = 2;
    const settled = fx.app.drawnTop(body_rows);
    try testing.expectEqual(@as(u32, 2), settled.row);
    try testing.expectEqual(@as(u16, 0), settled.skip);

    // Mid-flight, drawn two screen rows above it - which on unwrapped lines is
    // two rows earlier and no partial row.
    fx.app.vp.scroll_anim.budget_ms = 250;
    fx.app.vp.scroll_anim.offset = 2;
    const flying = fx.app.drawnTop(body_rows);
    try testing.expectEqual(@as(u32, 0), flying.row);
    try testing.expectEqual(@as(u16, 0), flying.skip);

    // It never walks off the top: displaced further than there are rows above
    // it, the first row is as far as it goes.
    fx.app.vp.scroll_anim.offset = 20;
    try testing.expectEqual(@as(u32, 0), fx.app.drawnTop(body_rows).row);
}

test "a wrapped row is crossed a screen row at a time, not all at once" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    // Make row 1 three screen rows tall in a narrow pane.
    fx.files[0].lines.text[0] = "a line long enough that a narrow pane has to break it more than once";
    fx.app.vp.cols = 30;
    try testing.expectEqual(@as(u16, 3), fx.app.rowHeight(1, body_rows));

    // Settled on row 2, displaced by one screen row: the top is still row 1,
    // with two of its three screen rows above the pane. Stepping by whole
    // rows could only ever show all of it or none of it.
    fx.app.vp.scroll = 2;
    fx.app.vp.scroll_anim.budget_ms = 250;
    fx.app.vp.scroll_anim.offset = 1;
    const one = fx.app.drawnTop(body_rows);
    try testing.expectEqual(@as(u32, 1), one.row);
    try testing.expectEqual(@as(u16, 2), one.skip);

    // Two rows up, one of them above; three, and the whole row is on screen.
    fx.app.vp.scroll_anim.offset = 2;
    try testing.expectEqual(@as(u16, 1), fx.app.drawnTop(body_rows).skip);
    fx.app.vp.scroll_anim.offset = 3;
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
    fx.app.vp.cols = 30;
    try testing.expectEqual(@as(i32, 4), fx.app.screenRowsBetween(1, 3, body_rows));
}

test "a relayout places the cursor rather than walking it across a new screen" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    // Give the cursor somewhere to have been drawn.
    _ = fx.app.vp.cursor_anim.cell(fx.app.cursorCell(body_rows).?);
    try testing.expect(fx.app.vp.cursor_anim.at != null);

    // `zw` changes what every line is worth in screen rows, so the cell the
    // cursor was on is not a cell on this screen: there is no path between
    // the two to draw a block along.
    try fx.press("zw");
    try testing.expect(fx.app.vp.cursor_anim.at == null);

    // `Tab` changes the body's height, which moves every row under it, and is
    // the same case.
    _ = fx.app.vp.cursor_anim.cell(fx.app.cursorCell(body_rows).?);
    try fx.app.run(.toggle_zen, body_rows);
    try testing.expect(fx.app.vp.cursor_anim.at == null);
}

test "crossing into another file arrives rather than sliding" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    fx.app.vp.scroll_anim.budget_ms = 250;

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

    // Rows: 0 header, 1..3 lines. The gutter is the sign, the mark's blank, a
    // two-digit number and two spaces.
    try testing.expectEqual(@as(u16, 6), rows_mod.gutter(&fx.files[0], .flow));
    fx.files[0].lines.text[0] = "a line long enough that a narrow pane has to break it more than once";
    fx.app.vp.cols = 30;

    // 24 columns of text, so a 68-character line is three rows.
    try testing.expectEqual(@as(u16, 3), fx.app.rowHeight(1, body_rows));
    // Chrome never wraps, whatever the width.
    try testing.expectEqual(@as(u16, 1), fx.app.rowHeight(0, body_rows));

    // Wide enough and it is one row again, and so is every row with wrapping
    // off - which is what makes `zw` a rendering switch and not a row model.
    fx.app.vp.cols = 200;
    try testing.expectEqual(@as(u16, 1), fx.app.rowHeight(1, body_rows));
    fx.app.vp.cols = 30;
    fx.app.wrap = false;
    try testing.expectEqual(@as(u16, 1), fx.app.rowHeight(1, body_rows));
}

test "half a page is half a screen, not half the rows on it" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    fx.files[0].lines.text[0] = "a line long enough that a narrow pane has to break it more than once";
    fx.app.vp.cols = 30;

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
    const moved = fx.app.vp.cursor;
    try testing.expect(moved > 0);

    try fx.press("?");
    try fx.press("j");
    try fx.press("j");
    try testing.expectEqual(moved, fx.app.vp.cursor);
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

// -- search and the prompt -----------------------------------------------

// -- zen, $EDITOR and notices --------------------------------------------

test "Tab toggles the chrome away and back" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    try testing.expect(!fx.app.vp.zen);
    try fx.press("<Tab>");
    try testing.expect(fx.app.vp.zen);
    try fx.press("<Tab>");
    try testing.expect(!fx.app.vp.zen);
}

test "e targets the new-file line, and the hunk position on a deleted one" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    // Cursor on the first line of a.zig, which is new-file line 1.
    const t = fx.app.editTarget().?;
    try testing.expectEqualStrings("a.zig", t.path);
    try testing.expectEqual(@as(u32, 1), t.line);

    // A header carries no line, so there is nothing to open at.
    fx.app.vp.cursor = 0;
    try testing.expectEqual(@as(u32, 0), fx.app.editTarget().?.line);

    var del = try Fixture.withDeletion(testing.allocator, 1);
    defer del.deinit();
    del.app.vp.cursor = 2; // the deleted line
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
    fx.app.vp.cursor = 0;
    try fx.app.rebuildRows(.row);
    try fx.expectCursor(1);
    try testing.expect(fx.app.rows.lineAt(fx.app.vp.cursor) != null);

    // A position further down is left exactly where it was.
    fx.app.vp.cursor = 3;
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
    fx.app.vp.cursor = 3;
    fx.app.vp.scroll = 3;
    try fx.app.handle(.{ .resize = .{ .cols = 100, .rows = 40 } }, 22);
    try testing.expectEqual(@as(u32, 0), fx.app.vp.scroll);

    // Shrinking to a body shorter than the review scrolls to keep the cursor
    // visible, and never past the last row.
    try fx.app.handle(.{ .resize = .{ .cols = 40, .rows = 6 } }, 2);
    try testing.expectEqual(@as(u32, 2), fx.app.vp.scroll);
    try testing.expect(fx.app.vp.cursor >= fx.app.vp.scroll);
    try testing.expect(fx.app.vp.cursor < fx.app.vp.scroll + 2);

    // The cursor itself is the reader's place in the file and a resize is not
    // a motion: it does not move.
    try fx.expectCursor(3);
}

// -- the bridge ----------------------------------------------------------

test "an empty message sends nothing rather than a blank line" {
    var fx = try Fixture.emptyReview(testing.allocator);
    defer fx.deinit();

    try fx.press("<CR>");
    try fx.press("<CR>");
    try testing.expect(fx.app.want_send == null);
    try testing.expectEqual(event.Mode.normal, fx.app.mode);
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
    try testing.expect(fx.app.rows.items[fx.app.vp.cursor] == .line);
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

// -- the compose box takes its keys from the keymap ------------------------

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

// -- `;` repeats the last walk ---------------------------------------------

test "; repeats the last walk, and , goes back without turning round" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    // Two files, one hunk each, so `]f` has somewhere to go and back.
    try fx.expectFile(0);

    try fx.press("]f");
    try fx.expectFile(1);
    // `;` is "that again", not "the next hunk" or any other family.
    try fx.press(";");
    try fx.expectFile(0);

    // `,` is "again, the other way" - and a second `,` keeps going that way
    // rather than reversing each time, which is what vim's does.
    try fx.press("]f");
    try fx.expectFile(1);
    try fx.press(",");
    try fx.expectFile(0);
    try fx.press(",");
    try fx.expectFile(1);
}

test "; still belongs to f and t the moment either is used" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("]f");
    try testing.expect(fx.app.last_walk != null);

    // A vim reader who types `f` expects `;` back. Using the motion vim
    // attaches it to takes it back, rather than the walk keeping it for the
    // rest of the session.
    try fx.press("f");
    try fx.typeIn("x");
    try testing.expect(fx.app.last_walk == null);
}

test "; with nothing behind it does nothing rather than guessing" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    const before = fx.app.vp.cursor;
    try fx.press(";");
    try testing.expectEqual(before, fx.app.vp.cursor);
    try fx.press(",");
    try testing.expectEqual(before, fx.app.vp.cursor);
}

// -- `*` and `#` -----------------------------------------------------------

// -- the command line ------------------------------------------------------

// -- <Tab> in the command line ---------------------------------------------
