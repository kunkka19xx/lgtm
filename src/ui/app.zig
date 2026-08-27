// SPDX-License-Identifier: Apache-2.0
//
// The main loop. Drains the event queue, re-diffs only what changed, inherits
// change ids, then renders - the order is fixed by ARCHITECTURE.md 3 and not
// an implementation detail: id inheritance runs before anything that keys off
// a hunk's identity.
//
// Two arenas, per ARCHITECTURE.md 4. The diff arena holds a whole diff
// generation and is reset on every re-diff. The frame arena holds the strings
// a single frame draws and is reset *after* render and flush, because vaxis
// cells reference that text rather than copying it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");

const diff = @import("../core/diff.zig");
const event = @import("../core/event.zig");
const git = @import("../core/git.zig");
const hunk = @import("../core/hunk.zig");
const source = @import("../core/source.zig");
const highlight = @import("../syntax/highlight.zig");
const lexer = @import("../syntax/lexer.zig");
const input = @import("../io/input.zig");
const metrics = @import("../io/metrics.zig");
const tty_mod = @import("../io/tty.zig");
const watch = @import("../io/watch.zig");

const editor = @import("editor.zig");
const keymap = @import("keymap.zig");
const prompt_mod = @import("prompt.zig");
const render = @import("render.zig");
const rows_mod = @import("rows.zig");
const search = @import("search.zig");
const theme_mod = @import("theme.zig");
const proc = @import("../io/proc.zig");

/// Scroll margin kept between the cursor and the edge of the body.
const scrolloff = 3;

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

    diff_arena: std.heap.ArenaAllocator,
    frame_arena: std.heap.ArenaAllocator,

    queue: *event.Queue,
    ids: hunk.IdTable = .{},
    cache: highlight.Cache = .{},
    km: keymap.Keymap = .{},
    theme: theme_mod.Theme = theme_mod.default,
    glyphs: theme_mod.Glyphs = theme_mod.Glyphs.unicode,

    /// Current diff generation. Everything in here belongs to `diff_arena`.
    parsed: ?git.Parsed = null,
    sources: ?source.Sources = null,
    rows: rows_mod.Rows = .{ .items = &.{}, .hunk_rows = &.{} },
    fn_names: [][]const u8 = &.{},
    /// Previous generation's hunks for the current file, so ids carry across.
    prev_hunks: []hunk.Hunk = &.{},

    file_index: u32 = 0,
    cursor: u32 = 0,
    scroll: u32 = 0,
    torn: bool = false,
    quit: bool = false,

    mode: event.Mode = .normal,
    /// Row the visual selection started on. Meaningless outside `.visual`.
    anchor: u32 = 0,
    /// The mode to return to when the prompt closes, so `/` from a selection
    /// does not silently drop it.
    prompt_return: event.Mode = .normal,
    prompt: prompt_mod.Prompt = .{},
    finder: search.State = .{},
    notice: Notice = .{},
    /// `Tab`: chrome hidden, the body gets the whole pane.
    zen: bool = false,
    /// Set by `e`. The run loop owns the terminal, so it - not `run(cmd)` -
    /// is what can hand it to a child process.
    want_editor: bool = false,

    pub fn init(gpa: Allocator, io: std.Io, queue: *event.Queue) App {
        return .{
            .gpa = gpa,
            .io = io,
            .queue = queue,
            .diff_arena = .init(gpa),
            .frame_arena = .init(gpa),
        };
    }

    pub fn deinit(self: *App) void {
        self.ids.deinit(self.gpa);
        self.cache.deinit(self.gpa);
        self.diff_arena.deinit();
        self.frame_arena.deinit();
        self.* = undefined;
    }

    fn files(self: *App) []diff.FileDiff {
        const p = self.parsed orelse return &.{};
        return p.diff.files;
    }

    fn current(self: *App) ?*diff.FileDiff {
        const fs = self.files();
        if (self.file_index >= fs.len) return null;
        return &fs[self.file_index];
    }

    /// One diff generation: git, buffers, ids, rows. Everything allocated here
    /// dies at the next reset, which is the whole point of the arena.
    pub fn rediff(self: *App) !void {
        const span = metrics.span(.diff_parse);
        defer span.end();

        // Carry the current file's hunks across so ids survive. They live in
        // the arena about to be reset, so copy them to the gpa first.
        const carried = try self.gpa.alloc(hunk.Hunk, self.prev_hunks.len);
        defer self.gpa.free(carried);
        @memcpy(carried, self.prev_hunks);

        const keep_path = if (self.current()) |f| try self.gpa.dupe(u8, f.path()) else null;
        defer if (keep_path) |p| self.gpa.free(p);

        _ = self.diff_arena.reset(.retain_capacity);
        const arena = self.diff_arena.allocator();
        self.parsed = null;
        self.sources = null;
        self.rows = .{ .items = &.{}, .hunk_rows = &.{} };
        self.fn_names = &.{};
        self.prev_hunks = &.{};

        const git_span = metrics.span(.git_subprocess);
        const parsed = try git.diffPathsIn(arena, self.io, null, &.{});
        git_span.end();
        self.parsed = parsed;

        // Buffers are the source of truth; the diff is an overlay on them.
        self.sources = source.load(arena, self.io, null, parsed.diff) catch null;
        self.torn = false;
        if (self.sources) |srcs| {
            for (parsed.diff.files) |*f| {
                const s = srcs.find(f.path()) orelse continue;
                source.attach(f, s.*) catch |err| switch (err) {
                    // The file changed between git running and our read. Say
                    // so and re-diff, rather than render a blend of two states
                    // (SPEC.md 9).
                    error.ContentMismatch => self.torn = true,
                    else => return err,
                };
            }
        }

        // Keep looking at the same file across a re-diff where possible.
        if (keep_path) |p| {
            for (parsed.diff.files, 0..) |*f, i| {
                if (std.mem.eql(u8, f.path(), p)) self.file_index = @intCast(i);
            }
        }
        if (self.file_index >= parsed.diff.files.len) self.file_index = 0;

        // Ids before anything that reads them (ARCHITECTURE.md 3, rule 3).
        for (parsed.diff.files, 0..) |*f, i| {
            const prev: []const hunk.Hunk = if (i == self.file_index) carried else &.{};
            try self.ids.inherit(arena, prev, f.hunks);
        }

        // The agent writing a file must not send the reader back to the top of
        // it, so the row index survives a re-diff. This is a stopgap, not the
        // answer: the row that *means* the same thing after an edit is what
        // `core/anchor.zig` computes, and wiring that in is what turns "the
        // same row number" into "the same line". Tracked in PLAN.md 5c.
        try self.rebuildRows(.row);
    }

    fn rebuildRows(self: *App, keep: Keep) !void {
        const arena = self.diff_arena.allocator();
        const f = self.current() orelse {
            self.rows = .{ .items = &.{}, .hunk_rows = &.{} };
            self.fn_names = &.{};
            self.cursor = 0;
            self.scroll = 0;
            return;
        };

        self.rows = try rows_mod.build(arena, f);
        self.prev_hunks = f.hunks;
        self.fn_names = try self.enclosingNames(arena, f);
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

    /// Enclosing function name per hunk, from the lexer's whole-file scan.
    /// Names are copied into the arena: the cache owns its own copies and may
    /// evict them, and a dangling name renders as garbage rather than failing.
    fn enclosingNames(self: *App, arena: Allocator, f: *diff.FileDiff) ![][]const u8 {
        const out = try arena.alloc([]const u8, f.hunks.len);
        @memset(out, "");

        const srcs = self.sources orelse return out;
        const s = srcs.find(f.path()) orelse return out;
        const work = s.work orelse return out;

        const hl = highlight.Highlighter.choose(f.path(), work.bytes.len, work.lineCount());
        const key = self.blobKey(f.new_blob, work.bytes);
        const st = self.cache.structureFor(self.gpa, hl, key, work.bytes) catch return out;

        for (f.hunks, 0..) |h, i| {
            const at = anchorLine(f, h);
            if (at == 0) continue;
            if (st.enclosingFn(at - 1)) |fd| {
                out[i] = arena.dupe(u8, fd.name) catch "";
            }
        }
        return out;
    }

    /// git already hashed this content; re-hashing the file on every lookup
    /// costs more than the miss it avoids (PERFORMANCE.md 7.2).
    fn blobKey(self: *App, blob: []const u8, bytes: []const u8) u64 {
        _ = self;
        if (blob.len == 0) return highlight.hashContent(bytes);
        return std.hash.Wyhash.hash(0, blob);
    }

    fn runsFor(self: *App, blob: []const u8, buf: anytype) []const lexer.Run {
        const b = buf orelse return &.{};
        const hl = highlight.Highlighter.choose(
            if (self.current()) |f| f.path() else "",
            b.bytes.len,
            b.lineCount(),
        );
        if (hl == .plain) return &.{};
        const key = self.blobKey(blob, b.bytes);
        return self.cache.runsFor(self.gpa, hl, key, b.bytes) catch &.{};
    }

    pub fn view(self: *App) ?render.View {
        const f = self.current() orelse return null;
        var work: ?@TypeOf((self.sources.?.files[0]).work.?) = null;
        var head = work;
        if (self.sources) |srcs| {
            if (srcs.find(f.path())) |s| {
                work = s.work;
                head = s.head;
            }
        }
        return .{
            .file = f,
            .rows = self.rows,
            .file_index = self.file_index,
            .file_count = @intCast(self.files().len),
            .cursor = self.cursor,
            .scroll = self.scroll,
            .fn_names = self.fn_names,
            .total_hunks = self.totalHunks(),
            .hunk_ordinal = self.hunkOrdinal(),
            .work = work,
            .head = head,
            .work_runs = self.runsFor(f.new_blob, work),
            .head_runs = self.runsFor(f.old_blob, head),
            .torn = self.torn,
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
        var before: u32 = 0;
        for (self.files(), 0..) |f, i| {
            if (i >= self.file_index) break;
            before += @intCast(f.hunks.len);
        }
        const local = self.rows.hunkAt(self.cursor) orelse return 0;
        return before + local + 1;
    }

    fn totalHunks(self: *App) u32 {
        var n: u32 = 0;
        for (self.files()) |f| n += @intCast(f.hunks.len);
        return n;
    }

    // -- commands ----------------------------------------------------------

    pub fn run(self: *App, cmd: keymap.Command, body: u16) !void {
        switch (cmd) {
            .quit => self.quit = true,
            .line_down => self.moveTo(self.cursor +| 1),
            .line_up => self.moveTo(self.cursor -| 1),
            .page_down => self.moveTo(self.cursor +| @max(1, body / 2)),
            .page_up => self.moveTo(self.cursor -| @max(1, body / 2)),
            .top => self.moveTo(0),
            .bottom => self.moveTo(self.rows.len() -| 1),
            .next_hunk => if (self.rows.nextHunkRow(self.cursor)) |r| self.moveTo(r + 1),
            .prev_hunk => if (self.rows.prevHunkRow(self.cursor)) |r| self.moveTo(r + 1),
            .next_file => try self.stepFile(1),
            .prev_file => try self.stepFile(-1),
            .center => self.centerCursor(body),
            .refresh => try self.rediff(),
            .visual_toggle => if (self.mode == .visual) self.leaveVisual() else self.enterVisual(),
            .visual_cancel => self.leaveVisual(),
            .search_forward => self.openPrompt(.search_forward),
            .search_backward => self.openPrompt(.search_backward),
            .search_next => try self.searchStep(self.finder.dir),
            .search_prev => try self.searchStep(self.finder.dir.flip()),
            .command_line => self.openPrompt(.command),
            // The run loop owns the terminal and is the only thing that can
            // lend it out, so this is a request rather than an action.
            .open_editor => self.want_editor = true,
            .toggle_zen => self.zen = !self.zen,
        }
        self.clampScroll(body);
    }

    // -- visual select -----------------------------------------------------

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

    // -- prompt and search -------------------------------------------------

    fn openPrompt(self: *App, kind: prompt_mod.Kind) void {
        self.prompt_return = self.mode;
        self.prompt.start(kind);
        self.mode = .command;
        self.notice.clear();
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
                // be declared empty, and `submitCommand` can re-enter it.
                var buf: [prompt_mod.max_bytes]u8 = undefined;
                const text = self.prompt.text();
                @memcpy(buf[0..text.len], text);
                const line = buf[0..text.len];
                const kind = self.prompt.kind;
                self.closePrompt();

                switch (kind) {
                    .search_forward, .search_backward => {
                        if (line.len == 0) {
                            // Bare Enter repeats the last query, as in vim.
                            try self.searchStep(self.finder.dir);
                        } else {
                            const dir: search.Direction =
                                if (kind == .search_forward) .forward else .backward;
                            self.finder.set(line, dir);
                            try self.searchStep(dir);
                        }
                    },
                    .command => self.submitCommand(line),
                }
                self.clampScroll(body);
            },
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
        var fi: usize = start_file;
        var from: ?u32 = self.rows.lineAt(self.cursor);
        var wrapped = false;

        var step: usize = 0;
        while (step <= fs.len) : (step += 1) {
            if (search.findLine(fs[fi].lines, from, dir, q)) |li| {
                if (fi != self.file_index) {
                    self.file_index = @intCast(fi);
                    try self.rebuildRows(.reset);
                }
                if (self.rows.rowForLine(li)) |row| self.moveTo(row);
                self.finder.wrapped = wrapped;
                if (wrapped) self.notice.set("search wrapped", .{});
                return;
            }
            // Step to the neighbouring file, noting when that crossed the end
            // of the review - which is the only thing that counts as a wrap.
            switch (dir) {
                .forward => {
                    fi += 1;
                    if (fi >= fs.len) {
                        fi = 0;
                        wrapped = true;
                    }
                },
                .backward => {
                    if (fi == 0) {
                        fi = fs.len - 1;
                        wrapped = true;
                    } else fi -= 1;
                },
            }
            // A file entered from outside has no cursor to start after.
            from = null;
        }

        self.finder.failed = true;
        self.notice.set("pattern not found: {s}", .{q});
    }

    // -- $EDITOR -----------------------------------------------------------

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
        const li = self.rows.lineAt(self.cursor) orelse
            return .{ .path = f.path(), .line = 0 };
        if (li >= f.lines.len()) return .{ .path = f.path(), .line = 0 };
        if (f.lines.kind[li] != .del) {
            return .{ .path = f.path(), .line = f.lines.new_no[li] };
        }
        const hi = self.rows.hunkAt(self.cursor) orelse return .{ .path = f.path(), .line = 0 };
        if (hi >= f.hunks.len) return .{ .path = f.path(), .line = 0 };
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

    /// Wraps: `]f` from the last file lands on the first, `[f` from the first
    /// lands on the last. A review is a ring, and stopping dead at the end
    /// reads as a dropped keystroke. Announced for the same reason the search
    /// announces its wrap - the file under you changed further than one step.
    fn stepFile(self: *App, delta: i32) !void {
        const n: i64 = @intCast(self.files().len);
        if (n == 0) return;
        const raw: i64 = @as(i64, self.file_index) + delta;
        // `@mod`, not `@rem`: a negative step has to land at the far end
        // rather than staying negative.
        const i = @mod(raw, n);
        if (i == self.file_index) return;
        if (raw != i) self.notice.set("wrapped to {s} file", .{if (delta > 0) "first" else "last"});
        self.file_index = @intCast(i);
        try self.rebuildRows(.reset);
    }

    fn centerCursor(self: *App, body: u16) void {
        const half = body / 2;
        self.scroll = self.cursor -| half;
    }

    /// Keeps the cursor inside the body with a margin, and never scrolls past
    /// the end of the rows.
    pub fn clampScroll(self: *App, body: u16) void {
        self.scroll = scrollFor(self.cursor, self.scroll, self.rows.len(), body);
    }

    pub fn handle(self: *App, ev: event.Event, body: u16) !void {
        switch (ev) {
            .quit => self.quit = true,
            .key => |k| {
                // While a prompt is open the keys are text, not actions, so
                // they never reach the keymap.
                if (self.mode == .command) return self.feedPrompt(k, body);
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
                for (paths) |p| self.gpa.free(p);
                self.gpa.free(paths);
                try self.rediff();
                self.clampScroll(body);
            },
            .resize => {},
            .agent_quiescent, .snapshot_taken => {},
        }
    }
};

pub const Options = struct {
    /// Render one frame and exit. What CI and a screenshot need, and the only
    /// way to exercise the render path without a human at a keyboard.
    once: bool = false,
};

/// Scroll offset that keeps `cursor` visible with a margin, given the current
/// offset and the body height. Pure, so the awkward cases - a body shorter
/// than twice the margin, a cursor past the end, a resize to one row - are
/// testable without a terminal.
pub fn scrollFor(cursor: u32, scroll: u32, rows_len: u32, body: u16) u32 {
    if (body == 0 or rows_len == 0) return 0;
    const margin: u32 = @min(scrolloff, body / 3);
    var out = scroll;

    if (cursor < out + margin) out = cursor -| margin;
    if (cursor + margin >= out + body) out = cursor + margin + 1 -| body;

    const max_scroll = rows_len -| body;
    if (out > max_scroll) out = max_scroll;
    return out;
}

/// The line a hunk's header should name: its first changed line, not its first
/// line. A hunk opens on context, and for a change near the top of a function
/// that context sits above the declaration - which is how a hunk squarely
/// inside `hashHunk` came out with no name at all.
pub fn anchorLine(f: *const diff.FileDiff, h: hunk.Hunk) u32 {
    var i = h.lo;
    while (i < h.hi and i < f.lines.len()) : (i += 1) {
        if (f.lines.kind[i] == .context) continue;
        const n = f.lines.new_no[i];
        if (n != 0) return n;
    }
    // A pure deletion has no new-file line of its own; the hunk's position in
    // the new file is the closest honest answer.
    return h.new_start;
}

/// Runs the review UI until the user quits.
pub fn run(gpa: Allocator, io: std.Io, environ: *std.process.Environ.Map, opts: Options) !void {
    var term = try tty_mod.Tty.init(gpa, io, tty_mod.default_buffer_bytes);
    defer term.deinit();
    const w = term.writer();

    var vx = try vaxis.Vaxis.init(io, gpa, environ, .{ .kitty_keyboard_flags = .{} });
    defer vx.deinit(gpa, w);

    try vx.enterAltScreen(w);
    try w.flush();
    defer {
        vx.exitAltScreen(w) catch {};
        w.flush() catch {};
    }

    var queue = event.Queue.init(gpa, io);
    defer queue.deinit();

    var app = App.init(gpa, io, &queue);
    defer app.deinit();

    var reader = input.Reader.init(&term, &queue);
    var winsize: input.WinsizeNotifier = .{ .tty = &term, .queue = &queue };
    var watcher = watch.Watcher.init(gpa, io, &queue, .{});
    if (!opts.once) {
        try reader.start();
        winsize.register() catch {};
        watcher.start() catch {};
    }
    defer if (!opts.once) {
        reader.stop();
        watcher.stop();
    };

    // Sized once here and again only when a resize event says so. Calling
    // `vx.resize` per frame reallocates both screen buffers and throws away
    // `screen_last` - which is the damage-tracking baseline - so every
    // keystroke repainted every cell. That is what a flickering terminal is.
    var ws = term.winsize() catch tty_mod.Winsize{ .cols = 80, .rows = 26, .x_pixel = 0, .y_pixel = 0 };
    try vx.resize(gpa, w, ws);

    try app.rediff();

    while (!app.quit) {
        app.clampScroll(render.bodyHeight(ws.rows, app.zen));

        try drawFrame(&app, &vx, w);
        if (opts.once) break;

        const events = try queue.drain(gpa);
        defer gpa.free(events);
        if (events.len == 0) break; // queue closed

        for (events) |ev| {
            if (ev == .resize) {
                ws = .{ .cols = ev.resize.cols, .rows = ev.resize.rows, .x_pixel = 0, .y_pixel = 0 };
                try vx.resize(gpa, w, ws);
            }
            try app.handle(ev, render.bodyHeight(ws.rows, app.zen));
        }

        if (app.want_editor) {
            app.want_editor = false;
            try openEditor(&app, &vx, &term, w, environ, &reader, opts);
            // The screen belongs to the editor until it exits; nothing vaxis
            // drew is still on it, so the damage baseline is a lie.
            vx.queueRefresh();
        }
    }
}

/// Hands the terminal to `$EDITOR` and takes it back.
///
/// Order matters in both directions and every step has a failure that looks
/// like a hang if it is skipped: stop reading input (or the reader and the
/// editor race for keystrokes), leave the alt screen (or the editor draws over
/// the diff), restore the shell's termios (or the editor starts with no echo).
/// Coming back is the same list reversed, and it runs even when the spawn
/// failed - a `lgtm` that returns to a raw terminal is one the user has to
/// `reset`.
fn openEditor(
    app: *App,
    vx: *vaxis.Vaxis,
    term: *tty_mod.Tty,
    w: *std.Io.Writer,
    environ: *std.process.Environ.Map,
    reader: *input.Reader,
    opts: Options,
) !void {
    const target = app.editTarget() orelse {
        app.notice.set("nothing here to open", .{});
        return;
    };

    var scratch: std.heap.ArenaAllocator = .init(app.gpa);
    defer scratch.deinit();
    const spec = editor.specFrom(environ);
    const argv = try editor.argv(scratch.allocator(), spec, target.path, target.line) orelse {
        app.notice.set("$EDITOR is empty", .{});
        return;
    };

    // Where the read cannot be interrupted, the reader would keep the tty and
    // eat the editor's input. Refusing is the honest outcome; silently opening
    // an editor that ignores half the keystrokes is not.
    if (!opts.once and !reader.pollable) {
        app.notice.set("cannot suspend input on this terminal", .{});
        return;
    }

    if (!opts.once) reader.stop();
    vx.exitAltScreen(w) catch {};
    w.flush() catch {};
    term.suspendRaw();

    const code = proc.runInherit(app.io, argv) catch |err| blk: {
        app.notice.set("{s}: {t}", .{ spec, err });
        break :blk @as(u8, 0);
    };

    term.resumeRaw();
    vx.enterAltScreen(w) catch {};
    w.flush() catch {};
    if (!opts.once) try reader.start();

    if (code != 0 and app.notice.len == 0) {
        app.notice.set("{s} exited with {d}", .{ spec, code });
    }
    // The user very likely changed the file, and the watcher may or may not
    // have seen it while we were not draining events.
    try app.rediff();
}

fn drawFrame(app: *App, vx: *vaxis.Vaxis, w: *std.Io.Writer) !void {
    const frame = metrics.span(.frame);
    defer frame.end();

    const arena = app.frame_arena.allocator();
    const win = vx.window();

    if (app.view()) |v| {
        var shown = v;
        var hint_buf: [256]u8 = undefined;
        shown.hints = try arena.dupe(u8, keymap.hints(app.km.bindings, app.mode, &hint_buf));
        try render.draw(.{
            .win = win,
            .arena = arena,
            .theme = app.theme,
            .glyphs = app.glyphs,
        }, shown);
    } else {
        win.clear();
        _ = win.printSegment(
            .{ .text = " lgtm: no changes against HEAD", .style = app.theme.dim },
            .{ .row_offset = 0, .wrap = .none },
        );
    }

    const render_span = metrics.span(.render);
    try vx.render(w);
    render_span.end();
    try w.flush();

    // After render and flush, never before: the cells above point into this
    // arena (ARCHITECTURE.md 5c).
    _ = app.frame_arena.reset(.retain_capacity);
}

const testing = std.testing;

// `ui/` is reachable from main.zig only through this file, and Zig collects
// tests from a file only when a `test` block references it. Without this list
// every test under `ui/` compiled in the binary but ran nowhere - which is how
// a render test with the wrong arity sat green through a whole phase. Adding a
// module here is what makes its tests part of `zig build check`.
test {
    _ = editor;
    _ = keymap;
    _ = prompt_mod;
    _ = render;
    _ = rows_mod;
    _ = search;
    _ = theme_mod;
}

test "scrolling keeps the cursor inside the body with a margin" {
    // Cursor near the top pins the view to the top rather than showing rows
    // that do not exist above it.
    try testing.expectEqual(@as(u32, 0), scrollFor(0, 0, 100, 22));
    try testing.expectEqual(@as(u32, 0), scrollFor(2, 0, 100, 22));

    // Moving down past the bottom margin scrolls by exactly what is needed:
    // cursor 20 with a 3-row margin needs rows 21-23 visible, and 2+22-1 = 23.
    try testing.expectEqual(@as(u32, 2), scrollFor(20, 0, 100, 22));
    // Moving back up above the top margin scrolls back.
    try testing.expectEqual(@as(u32, 7), scrollFor(10, 20, 100, 22));
}

test "scrolling never runs past the last row" {
    // A cursor at the end still leaves a full body on screen, not a screen
    // half full of blanks.
    try testing.expectEqual(@as(u32, 78), scrollFor(99, 90, 100, 22));
    // Fewer rows than the body means no scrolling at all.
    try testing.expectEqual(@as(u32, 0), scrollFor(3, 0, 5, 22));
    try testing.expectEqual(@as(u32, 0), scrollFor(4, 3, 5, 22));
}

test "degenerate sizes do not underflow" {
    // A one-row body has no room for a margin; the arithmetic must still hold.
    try testing.expectEqual(@as(u32, 0), scrollFor(0, 0, 0, 22));
    try testing.expectEqual(@as(u32, 0), scrollFor(5, 0, 10, 0));
    _ = scrollFor(0, 0, 1, 1);
    _ = scrollFor(9, 0, 10, 1);
    _ = scrollFor(0, 9, 10, 2);
}

test "a hunk header names its first changed line, not its first line" {
    const gpa = testing.allocator;
    const n = 5;
    var lines: hunk.DiffLines = .{
        .kind = try gpa.alloc(hunk.LineKind, n),
        .old_no = try gpa.alloc(u32, n),
        .new_no = try gpa.alloc(u32, n),
        .text = try gpa.alloc([]const u8, n),
    };
    defer lines.deinit(gpa);
    // Three context lines, then the change: the shape that hid `hashHunk`.
    for (0..n) |i| {
        lines.kind[i] = if (i == 3) .add else .context;
        lines.old_no[i] = @intCast(73 + i);
        lines.new_no[i] = @intCast(73 + i);
        lines.text[i] = "x";
    }
    var f: diff.FileDiff = .{
        .old_path = "a.zig",
        .new_path = "a.zig",
        .status = .modified,
        .lines = lines,
    };
    const h: hunk.Hunk = .{ .old_start = 73, .old_count = 5, .new_start = 73, .new_count = 5, .lo = 0, .hi = 5 };
    try testing.expectEqual(@as(u32, 76), anchorLine(&f, h));
}

test "a pure deletion falls back to the hunk position" {
    const gpa = testing.allocator;
    var lines: hunk.DiffLines = .{
        .kind = try gpa.alloc(hunk.LineKind, 2),
        .old_no = try gpa.alloc(u32, 2),
        .new_no = try gpa.alloc(u32, 2),
        .text = try gpa.alloc([]const u8, 2),
    };
    defer lines.deinit(gpa);
    for (0..2) |i| {
        lines.kind[i] = .del;
        lines.old_no[i] = @intCast(10 + i);
        lines.new_no[i] = 0;
        lines.text[i] = "gone";
    }
    var f: diff.FileDiff = .{ .old_path = "a", .new_path = "a", .status = .modified, .lines = lines };
    const h: hunk.Hunk = .{ .old_start = 10, .old_count = 2, .new_start = 9, .new_count = 0, .lo = 0, .hi = 2 };
    try testing.expectEqual(@as(u32, 9), anchorLine(&f, h));
}

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

    fn init(gpa: Allocator, deleted_at: ?usize) !*Fixture {
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
        self.app.parsed = .{ .diff = .{ .files = self.files }, .raw = &.{}, .stderr = &.{} };
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
        self.app.parsed = null;
        self.app.deinit();
        self.queue.deinit();
        self.threaded.deinit();
        gpa.destroy(self);
    }

    fn key(self: *Fixture, cp: u21) !void {
        try self.app.handle(.{ .key = .{ .codepoint = cp, .mods = .{} } }, 22);
    }

    fn typeIn(self: *Fixture, text: []const u8) !void {
        for (text) |ch| try self.key(ch);
    }
};

test "V anchors a selection and motions extend it in either direction" {
    var fx = try Fixture.init(testing.allocator, null);
    defer fx.deinit();

    // Rows: 0 header, 1..3 lines. The cursor opens on the first line.
    try testing.expectEqual(@as(u32, 1), fx.app.cursor);
    try testing.expect(fx.app.selection() == null);

    try fx.key('V');
    try testing.expectEqual(event.Mode.visual, fx.app.mode);
    // A fresh selection is one row, not zero.
    try testing.expectEqual(@as(u32, 1), fx.app.selection().?.count());

    try fx.key('j');
    try fx.key('j');
    const down = fx.app.selection().?;
    try testing.expectEqual(@as(u32, 1), down.lo);
    try testing.expectEqual(@as(u32, 3), down.hi);

    // Selecting upwards puts the anchor below the cursor; the range must come
    // back normalised rather than inverted.
    try fx.key('k');
    try fx.key('k');
    try fx.key('k');
    const up = fx.app.selection().?;
    try testing.expect(up.lo <= up.hi);
    try testing.expectEqual(@as(u32, 1), up.hi);

    try fx.key(event.code.escape);
    try testing.expectEqual(event.Mode.normal, fx.app.mode);
    try testing.expect(fx.app.selection() == null);
}

test "moving to another file drops the selection instead of re-pointing it" {
    var fx = try Fixture.init(testing.allocator, null);
    defer fx.deinit();

    try fx.key('V');
    try fx.key('j');
    try testing.expect(fx.app.selection() != null);

    // The rows the anchor described no longer exist. Keeping the indexes would
    // silently select whatever now sits at them.
    try fx.key(']');
    try fx.key('f');
    try testing.expectEqual(@as(u32, 1), fx.app.file_index);
    try testing.expect(fx.app.selection() == null);
    try testing.expectEqual(event.Mode.normal, fx.app.mode);
}

test "search crosses into the next file and lands on the matching row" {
    var fx = try Fixture.init(testing.allocator, null);
    defer fx.deinit();

    try fx.key('/');
    try testing.expectEqual(event.Mode.command, fx.app.mode);
    // Inside the prompt these are letters, not motions: `j` must not move.
    try fx.typeIn("token");
    try testing.expectEqual(@as(u32, 1), fx.app.cursor);
    try fx.key(event.code.enter);

    try testing.expectEqual(event.Mode.normal, fx.app.mode);
    try testing.expectEqual(@as(u32, 1), fx.app.file_index);
    // Row 2 of b.zig: header, line 0, line 1.
    try testing.expectEqual(@as(u32, 2), fx.app.cursor);
    // Reaching the next file in order is not a wrap.
    try testing.expect(!fx.app.finder.wrapped);
}

test "stepping past the last file wraps to the first and says so" {
    var fx = try Fixture.init(testing.allocator, null);
    defer fx.deinit();

    // Two files in the fixture, so one step leaves us on the last.
    try fx.key(']');
    try fx.key('f');
    try testing.expectEqual(@as(u32, 1), fx.app.file_index);
    // Landing on the last file is not itself a wrap.
    try testing.expectEqual(@as(usize, 0), fx.app.notice.len);

    try fx.key(']');
    try fx.key('f');
    try testing.expectEqual(@as(u32, 0), fx.app.file_index);
    try testing.expect(std.mem.indexOf(u8, fx.app.notice.text(), "wrapped to first") != null);
}

test "stepping back from the first file wraps to the last" {
    var fx = try Fixture.init(testing.allocator, null);
    defer fx.deinit();

    try testing.expectEqual(@as(u32, 0), fx.app.file_index);
    try fx.key('[');
    try fx.key('f');
    try testing.expectEqual(@as(u32, 1), fx.app.file_index);
    try testing.expect(std.mem.indexOf(u8, fx.app.notice.text(), "wrapped to last") != null);
}

test "the leader form steps files like the bracket form" {
    var fx = try Fixture.init(testing.allocator, null);
    defer fx.deinit();

    try fx.key(' ');
    try fx.key('n');
    try fx.key('f');
    try testing.expectEqual(@as(u32, 1), fx.app.file_index);

    try fx.key(' ');
    try fx.key('p');
    try fx.key('f');
    try testing.expectEqual(@as(u32, 0), fx.app.file_index);
}

test "search wraps past the end of the review and says so" {
    var fx = try Fixture.init(testing.allocator, null);
    defer fx.deinit();

    fx.app.file_index = 1;
    try fx.app.rebuildRows(.reset);

    try fx.key('/');
    try fx.typeIn("alpha");
    try fx.key(event.code.enter);

    try testing.expectEqual(@as(u32, 0), fx.app.file_index);
    try testing.expectEqual(@as(u32, 1), fx.app.cursor);
    try testing.expect(fx.app.finder.wrapped);
    try testing.expect(std.mem.indexOf(u8, fx.app.notice.text(), "wrapped") != null);
}

test "n repeats the search and N reverses it" {
    var fx = try Fixture.init(testing.allocator, null);
    defer fx.deinit();

    // `const` appears once per file, so stepping is observable.
    try fx.key('/');
    try fx.typeIn("const");
    try fx.key(event.code.enter);
    try testing.expectEqual(@as(u32, 0), fx.app.file_index);
    try testing.expectEqual(@as(u32, 2), fx.app.cursor);

    try fx.key('n');
    try testing.expectEqual(@as(u32, 1), fx.app.file_index);

    try fx.key('N');
    try testing.expectEqual(@as(u32, 0), fx.app.file_index);
    try testing.expectEqual(@as(u32, 2), fx.app.cursor);
}

test "a search that finds nothing leaves the cursor put and says why" {
    var fx = try Fixture.init(testing.allocator, null);
    defer fx.deinit();

    const before = fx.app.cursor;
    try fx.key('/');
    try fx.typeIn("nowhere");
    try fx.key(event.code.enter);

    try testing.expectEqual(before, fx.app.cursor);
    try testing.expect(fx.app.finder.failed);
    try testing.expect(std.mem.indexOf(u8, fx.app.notice.text(), "not found") != null);
}

test "escaping a prompt returns to the mode it was opened from" {
    var fx = try Fixture.init(testing.allocator, null);
    defer fx.deinit();

    try fx.key('V');
    try fx.key('/');
    try fx.typeIn("x");
    try fx.key(event.code.escape);
    // A search abandoned mid-selection must not also abandon the selection.
    try testing.expectEqual(event.Mode.visual, fx.app.mode);
    try testing.expect(fx.app.selection() != null);
}

test ":q quits and anything else reports itself rather than vanishing" {
    var fx = try Fixture.init(testing.allocator, null);
    defer fx.deinit();

    try fx.key(':');
    try fx.typeIn("wq");
    try fx.key(event.code.enter);
    try testing.expect(!fx.app.quit);
    try testing.expect(std.mem.indexOf(u8, fx.app.notice.text(), ":wq") != null);

    try fx.key(':');
    try fx.typeIn("q");
    try fx.key(event.code.enter);
    try testing.expect(fx.app.quit);
}

test "Tab toggles the chrome away and back" {
    var fx = try Fixture.init(testing.allocator, null);
    defer fx.deinit();

    try testing.expect(!fx.app.zen);
    try fx.key(event.code.tab);
    try testing.expect(fx.app.zen);
    try fx.key(event.code.tab);
    try testing.expect(!fx.app.zen);
}

test "e targets the new-file line, and the hunk position on a deleted one" {
    var fx = try Fixture.init(testing.allocator, null);
    defer fx.deinit();

    // Cursor on the first line of a.zig, which is new-file line 1.
    const t = fx.app.editTarget().?;
    try testing.expectEqualStrings("a.zig", t.path);
    try testing.expectEqual(@as(u32, 1), t.line);

    // A header carries no line, so there is nothing to open at.
    fx.app.cursor = 0;
    try testing.expectEqual(@as(u32, 0), fx.app.editTarget().?.line);

    var del = try Fixture.init(testing.allocator, 1);
    defer del.deinit();
    del.app.cursor = 2; // the deleted line
    // It has no line in the file on disk; the hunk's position is where the
    // deletion happened, which is the closest honest answer.
    try testing.expectEqual(@as(u32, 1), del.app.editTarget().?.line);
}

test "e sets a request rather than acting, because the loop owns the terminal" {
    var fx = try Fixture.init(testing.allocator, null);
    defer fx.deinit();

    try testing.expect(!fx.app.want_editor);
    try fx.key('e');
    try testing.expect(fx.app.want_editor);
}

test "a notice lasts exactly one keystroke" {
    var fx = try Fixture.init(testing.allocator, null);
    defer fx.deinit();

    try fx.key(':');
    try fx.typeIn("nope");
    try fx.key(event.code.enter);
    try testing.expect(fx.app.notice.text().len > 0);

    try fx.key('j');
    try testing.expectEqual(@as(usize, 0), fx.app.notice.text().len);
}

test "a notice too long to format is truncated rather than dropped" {
    var n: Notice = .{};
    var long: [512]u8 = undefined;
    @memset(&long, 'x');
    n.set("pattern not found: {s}", .{&long});
    try testing.expect(n.text().len > 0);
    try testing.expect(n.text().len <= n.buf.len);
}

test "keeping the row across a re-diff never parks the cursor on chrome" {
    var fx = try Fixture.init(testing.allocator, null);
    defer fx.deinit();

    // Row 0 is the hunk header. A rebuild that keeps the row must not leave
    // the cursor there - which is exactly the first diff, where there is no
    // previous position and the kept row is 0.
    fx.app.cursor = 0;
    try fx.app.rebuildRows(.row);
    try testing.expectEqual(@as(u32, 1), fx.app.cursor);
    try testing.expect(fx.app.rows.lineAt(fx.app.cursor) != null);

    // A position further down is left exactly where it was.
    fx.app.cursor = 3;
    try fx.app.rebuildRows(.row);
    try testing.expectEqual(@as(u32, 3), fx.app.cursor);
}
