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

const keymap = @import("keymap.zig");
const render = @import("render.zig");
const rows_mod = @import("rows.zig");
const theme_mod = @import("theme.zig");

/// Scroll margin kept between the cursor and the edge of the body.
const scrolloff = 3;

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

        try self.rebuildRows();
    }

    fn rebuildRows(self: *App) !void {
        const arena = self.diff_arena.allocator();
        const f = self.current() orelse {
            self.rows = .{ .items = &.{}, .hunk_rows = &.{} };
            self.fn_names = &.{};
            return;
        };

        self.rows = try rows_mod.build(arena, f);
        self.prev_hunks = f.hunks;
        self.fn_names = try self.enclosingNames(arena, f);
        self.cursor = self.rows.firstLineRow();
        self.scroll = 0;
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
        }
        self.clampScroll(body);
    }

    fn moveTo(self: *App, row: u32) void {
        const n = self.rows.len();
        if (n == 0) {
            self.cursor = 0;
            return;
        }
        self.cursor = @min(row, n - 1);
    }

    fn stepFile(self: *App, delta: i32) !void {
        const n: i64 = @intCast(self.files().len);
        if (n == 0) return;
        var i: i64 = @as(i64, self.file_index) + delta;
        if (i < 0) i = 0;
        if (i >= n) i = n - 1;
        if (i == self.file_index) return;
        self.file_index = @intCast(i);
        try self.rebuildRows();
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
            .key => |k| switch (self.km.feed(k)) {
                .command => |cmd| try self.run(cmd, body),
                .pending, .none => {},
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
        const body = render.bodyHeight(ws.rows);
        app.clampScroll(body);

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
            try app.handle(ev, render.bodyHeight(ws.rows));
        }
    }
}

fn drawFrame(app: *App, vx: *vaxis.Vaxis, w: *std.Io.Writer) !void {
    const frame = metrics.span(.frame);
    defer frame.end();

    const arena = app.frame_arena.allocator();
    const win = vx.window();

    if (app.view()) |v| {
        var shown = v;
        var hint_buf: [256]u8 = undefined;
        shown.hints = try arena.dupe(u8, keymap.hints(app.km.bindings, &hint_buf));
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
