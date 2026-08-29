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
const prompt_mod = @import("prompt.zig");
const render = @import("render.zig");
const review_mod = @import("review.zig");
const rows_mod = @import("rows.zig");
const search = @import("search.zig");
const theme_mod = @import("theme.zig");

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
const Keep = enum { reset, row };

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

    mode: event.Mode = .normal,
    /// Row the visual selection started on. Meaningless outside `.visual`.
    anchor: u32 = 0,
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
    /// `Tab`: chrome hidden, the body gets the whole pane.
    zen: bool = false,
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
        });
        self.rows = rows_mod.Rows.empty;
        self.fn_names = &.{};
        self.prev_hunks = &.{};

        // The agent writing a file must not send the reader back to the top of
        // it, so the row index survives a re-diff. This is a stopgap, not the
        // answer: the row that *means* the same thing after an edit is what
        // `core/anchor.zig` computes, and wiring that in is what turns "the
        // same row number" into "the same line". Tracked in PLAN.md 5c.
        try self.rebuildRows(.row);
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
        switch (keep) {
            .reset => {
                self.cursor = self.rows.firstLineRow();
                self.scroll = 0;
            },
            .row => {
                self.cursor = @min(self.cursor, self.rows.len() -| 1);
                // Never leave the cursor on chrome. `moveTo` cannot put it
                // there, but keeping a row index across a rebuild can - and
                // the very first diff is the worst case, where there is no
                // previous position at all and row 0 is the hunk header.
                if (self.cursor < self.rows.firstLineRow()) {
                    self.cursor = self.rows.firstLineRow();
                }
            },
        }
        // The rows the anchor pointed at are gone, so the selection it
        // described is gone with them. Silently keeping the range would select
        // whatever now happens to sit at those indexes.
        if (self.mode == .visual) self.leaveVisual();
    }

    pub fn view(self: *App) ?render.View {
        const f = self.current() orelse return null;
        const bufs = self.review.buffersFor(f.path());
        return .{
            .file = f,
            .rows = self.rows,
            .file_index = self.file_index,
            .file_count = @intCast(self.files().len),
            .cursor = self.cursor,
            .scroll = self.scroll,
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
        switch (cmd) {
            .quit => self.quit = true,
            .line_down => self.moveTo(self.cursor +| 1),
            .line_up => self.moveTo(self.cursor -| 1),
            .page_down => self.moveTo(self.cursor +| @max(1, body / 2)),
            .page_up => self.moveTo(self.cursor -| @max(1, body / 2)),
            .top => self.moveTo(0),
            .bottom => self.moveTo(self.rows.len() -| 1),
            .next_hunk => try self.stepHunk(1),
            .prev_hunk => try self.stepHunk(-1),
            .next_file => try self.stepFile(1),
            .prev_file => try self.stepFile(-1),
            .center => self.centerCursor(body),
            .refresh => try self.rediff(),
            .visual_toggle => if (self.mode == .visual) self.leaveVisual() else self.enterVisual(),
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
            .toggle_zen => self.zen = !self.zen,
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
    }

    // -- visual select -------------------------------------------------------

    fn enterVisual(self: *App) void {
        self.mode = .visual;
        self.anchor = self.cursor;
    }

    fn leaveVisual(self: *App) void {
        self.mode = .normal;
        self.anchor = self.cursor;
    }

    /// The selected row range, low to high inclusive, or null outside visual
    /// mode. Normalised here rather than at each use, because a selection made
    /// upwards has the anchor below the cursor and every consumer would
    /// otherwise have to remember that.
    pub fn selection(self: *const App) ?render.Range {
        if (self.mode != .visual) return null;
        return .{
            .lo = @min(self.anchor, self.cursor),
            .hi = @max(self.anchor, self.cursor),
        };
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
            .help => self.help.moveColumn(self.km.bindings, delta),
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
            if (search.findLine(fs[fi].lines, from, dir, q)) |li| {
                if (fi != self.file_index) {
                    self.file_index = fi;
                    try self.rebuildRows(.reset);
                }
                if (self.rows.rowForLine(li)) |row| self.moveTo(row);
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
        else
            self.templates.ref_single;

        try template.render(self.gpa, out, tmpl, &.{
            .{ .name = "change_id", .value = id },
            .{ .name = "path", .value = r.path },
            .{ .name = "line", .value = line },
            .{ .name = "start", .value = line },
            .{ .name = "end", .value = end },
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
            return;
        }
        self.cursor = @min(row, n - 1);
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

    fn centerCursor(self: *App, body: u16) void {
        const half = body / 2;
        self.scroll = self.cursor -| half;
    }

    /// Keeps the cursor inside the body with a margin, and never scrolls past
    /// the end of the rows.
    pub fn clampScroll(self: *App, body: u16) void {
        self.scroll = scrollFor(self.cursor, self.scroll, self.rows.len(), body, self.nav.scrolloff);
    }

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
                switch (self.km.feed(k, self.mode)) {
                    .command => |cmd| try self.run(cmd, body),
                    .pending, .none => {},
                }
            },
            .files_changed => |paths| {
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
            .resize => self.clampScroll(body),
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

pub fn scrollFor(cursor: u32, scroll: u32, rows_len: u32, body: u16, scrolloff: u32) u32 {
    if (body == 0 or rows_len == 0) return 0;
    const margin: u32 = @min(scrolloff, body / 3);
    var out = scroll;

    if (cursor < out + margin) out = cursor -| margin;
    if (cursor + margin >= out + body) out = cursor + margin + 1 -| body;

    const max_scroll = rows_len -| body;
    if (out > max_scroll) out = max_scroll;
    return out;
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
    _ = devicon;
    _ = files_mod;
    _ = help_mod;
    _ = keymap;
    _ = keytext;
    _ = prompt_mod;
    _ = render;
    _ = review_mod;
    _ = rows_mod;
    _ = search;
    _ = theme_mod;
}

// -- pure arithmetic: no fixture, no rows, no terminal -------------------

test "scrolling keeps the cursor inside the body with a margin" {
    // Cursor near the top pins the view to the top rather than showing rows
    // that do not exist above it.
    try testing.expectEqual(@as(u32, 0), scrollFor(0, 0, 100, 22, 3));
    try testing.expectEqual(@as(u32, 0), scrollFor(2, 0, 100, 22, 3));

    // Moving down past the bottom margin scrolls by exactly what is needed:
    // cursor 20 with a 3-row margin needs rows 21-23 visible, and 2+22-1 = 23.
    try testing.expectEqual(@as(u32, 2), scrollFor(20, 0, 100, 22, 3));
    // Moving back up above the top margin scrolls back.
    try testing.expectEqual(@as(u32, 7), scrollFor(10, 20, 100, 22, 3));
}

test "scrolling never runs past the last row" {
    // A cursor at the end still leaves a full body on screen, not a screen
    // half full of blanks.
    try testing.expectEqual(@as(u32, 78), scrollFor(99, 90, 100, 22, 3));
    // Fewer rows than the body means no scrolling at all.
    try testing.expectEqual(@as(u32, 0), scrollFor(3, 0, 5, 22, 3));
    try testing.expectEqual(@as(u32, 0), scrollFor(4, 3, 5, 22, 3));
}

test "degenerate sizes do not underflow" {
    // A one-row body has no room for a margin; the arithmetic must still hold.
    try testing.expectEqual(@as(u32, 0), scrollFor(0, 0, 0, 22, 3));
    try testing.expectEqual(@as(u32, 0), scrollFor(5, 0, 10, 0, 3));
    _ = scrollFor(0, 0, 1, 1, 3);
    _ = scrollFor(9, 0, 10, 1, 3);
    _ = scrollFor(0, 9, 10, 2, 3);
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

    // Sideways moves by a whole column of the grid the last frame drew, which
    // the app knows only because the renderer wrote it back.
    fx.app.help.layout = .{ .cols = 2, .per = 11 };
    fx.app.help.index = 0;
    for ([_][]const u8{ "<Right>", "L" }) |k| {
        fx.app.help.index = 0;
        try fx.press(k);
        try testing.expectEqual(@as(usize, 11), fx.app.help.index);
    }
    for ([_][]const u8{ "<Left>", "H" }) |k| {
        fx.app.help.index = 11;
        try fx.press(k);
        try testing.expectEqual(@as(usize, 0), fx.app.help.index);
    }
}

test "typing narrows the list the popup is showing" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("?");
    const all = keytext.helpCount(fx.app.km.bindings, .normal, "");
    try fx.press("<Down>");
    try testing.expect(fx.app.help.index > 0);

    // The keys went into the filter rather than to dispatch, so the list is
    // shorter and the selection is back at the top of the new one.
    try fx.typeIn("file");
    const narrowed = keytext.helpCount(fx.app.km.bindings, .normal, fx.app.help.filter.text());
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
    try testing.expect(fx.app.view() == null);

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
    try fx.press("F");
    try fx.expectMode(.finder);
    // Opened on the current file, so the list says where the reader is before
    // it offers to move them.
    try testing.expectEqual(@as(u32, 1), fx.app.file_list.selected(fx.app.files()).?);

    // `F` does *not* close it: inside the overlay a keystroke is filter text,
    // and `F` is a letter that appears in paths. Escape closes, the way it
    // does in the `?` overlay and in every prompt.
    try fx.press("F");
    try fx.expectMode(.finder);
    try testing.expectEqualStrings("F", fx.app.file_list.filter.text());
    try fx.press("<Esc>");
    try fx.expectMode(.normal);
    try fx.expectFile(1);
}

test "Enter jumps to the selected file, Escape leaves the review alone" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("F");
    try fx.press("J");
    try fx.press("<CR>");
    try fx.expectMode(.normal);
    try fx.expectFile(1);
    // A jump is a move to a different file, so the cursor starts at the top of
    // it rather than wherever the last file's cursor happened to be.
    try fx.expectCursor(fx.app.rows.firstLineRow());

    // Escape closes without moving.
    try fx.press("F");
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
    try fx.press("F");

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

    try fx.press("F");
    try fx.typeIn("b.z");
    try testing.expectEqual(@as(usize, 1), files_mod.count(fx.app.files(), fx.app.file_list.filter.text()));
    try fx.press("<CR>");
    try fx.expectFile(1);

    // Closing cleared the query, so `F` never reopens onto a stale filter.
    try fx.press("F");
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
    try fx.press("e");
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

    try fx.press("t");
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
