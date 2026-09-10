// SPDX-License-Identifier: Apache-2.0
//
// The list overlay: changed files, project files, comments, turns, panes and
// pull requests all draw through it. What differs is the rows it is handed and
// what `<CR>` then does.

const std = @import("std");
const Allocator = std.mem.Allocator;

const app_mod = @import("app.zig");
const App = app_mod.App;
const notes = @import("notes.zig");
const files_mod = @import("files.zig");
const keymap = @import("keymap.zig");
const keytext = @import("keytext.zig");
const frame_mod = @import("frame.zig");
const render = @import("render.zig");
const wrap_mod = @import("wrap.zig");
const compose_mod = @import("compose.zig");
const diff = @import("../core/diff.zig");
const hunk = @import("../core/hunk.zig");
const event = @import("../core/event.zig");
const git = @import("../core/git.zig");
const turns_mod = @import("turns.zig");
const pr_mod = @import("pr.zig");
const walks = @import("walks.zig");

/// One row of the pane picker, in this file's own vocabulary. The loop
/// fills these from whatever its bridge knows: `ui/app.zig` never sees a
/// multiplexer. The fields are the parts, not a finished line - ordering
/// and column widths are decisions about a list.
pub const PaneRow = struct {
    id: []const u8,
    /// Where the pane is, in whatever the multiplexer calls places.
    where: []const u8 = "",
    /// What it is running.
    command: []const u8 = "",
    /// What it calls itapp. Last, and unpadded: it is a sentence, and it
    /// is the field worth the leftover width.
    title: []const u8 = "",
    /// Which group the row belongs to. Rows sharing one stay together.
    session: []const u8 = "",
    /// That group is the one lgtm is running in.
    here: bool = false,
    /// Running something that is not a shell, an editor or a pager.
    agent: bool = false,
    /// Sends already go here.
    target: bool = false,
    /// What the pane is showing, for the panel beside the list.
    preview: []const u8 = "",
};

/// The location column's ceiling: padding to the widest made every row
/// pay for the longest session name. Fourteen holds `session:W.P` for a
/// session named after a repository.
///
/// The head goes, not the tail: `:window.pane` tells the rows of one
/// session apart, and the session repeats down the group anyway.
const pane_where_max: usize = 14;

/// What a list says when it opens. `open` resets the gutter and the width
/// ceiling, so both are set after it.
pub const Show = struct {
    title: []const u8,
    at: u32 = 0,
    totals: ?frame_mod.Totals = null,
    /// This list's own footer keys, when the shared ones say nothing here.
    keys: []const keytext.HelpEntry = &.{},
    /// False for rows that are labels rather than paths: no icon, no mark.
    gutter: bool = true,
};

pub fn show(app: *App, s: Show) void {
    app.file_list.title = s.title;
    app.file_list.totals = s.totals;
    app.file_list.extra_keys = s.keys;
    app.file_list.open(s.at);
    app.file_list.gutter = s.gutter;
    app.file_list.max_share = App.picker_share;
    app.mode = .finder;
}

/// What the picker knows that no other list does.
pub const State = struct {
    /// Parallel to the row labels, in the pick arena: the list outlives the
    /// frame that built it.
    pane_ids: std.ArrayList([]const u8) = .empty,
    /// What a send handed to the clipboard for want of a target. Picking a
    /// pane then finishes that keystroke rather than only preparing the next.
    pending_send: ?[]const u8 = null,
    /// For the loop to point the bridge at: this file does not talk to a
    /// multiplexer, it says what it wants done with one.
    want_target: ?[]const u8 = null,
    want_panes: bool = false,
    target_buf: [64]u8 = undefined,
    /// `git ls-files`, on the first `@` and kept. Not at startup: most
    /// sessions never mention a file, and cold start has a 50 ms budget.
    project_paths: [][]const u8 = &.{},
    project_loaded: bool = false,

    pub fn deinit(self: *State, gpa: Allocator) void {
        self.pane_ids.deinit(gpa);
    }
};

pub fn shortWhere(arena: Allocator, where: []const u8, ell: []const u8, ell_w: usize) Allocator.Error![]const u8 {
    // ASCII from the multiplexer, so bytes are columns.
    if (where.len <= pane_where_max) return where;
    const colon = std.mem.lastIndexOfScalar(u8, where, ':') orelse where.len;
    const tail = where[colon..];
    if (tail.len + ell_w + 1 > pane_where_max) return where[0..pane_where_max];
    return std.fmt.allocPrint(arena, "{s}{s}{s}", .{
        where[0 .. pane_where_max - tail.len - ell_w],
        ell,
        tail,
    });
}

/// Our own session first, then the others by name, then agents ahead of
/// shells inside each, then the order the multiplexer gave.
///
/// Grouping outranks agent-ness: a session is how a reader knows *which*
/// agent, and sorting every agent to the top scatters the panes of one
/// piece of work.
pub fn paneBefore(_: void, a: PaneRow, b: PaneRow) bool {
    if (a.here != b.here) return a.here;
    const by_name = std.mem.order(u8, a.session, b.session);
    if (by_name != .eq) return by_name == .lt;
    if (a.agent != b.agent) return a.agent;
    return false;
}

/// Opens the picker over a list the loop has already gathered.
///
/// `pending` is the payload the send could not deliver. It is on the
/// clipboard by the time this is called - losing the reader's text is
/// never the price of not knowing where to put it - and it is kept here so
/// that picking a pane sends it rather than merely arranging for the next
/// one to go somewhere.
pub fn openPanePicker(app: *App, rows: []const PaneRow, pending: ?[]const u8) Allocator.Error!void {
    app.files_purpose = .panes;
    app.pick_list.clearRetainingCapacity();
    app.finder_state.pane_ids.clearRetainingCapacity();
    _ = app.pick_arena.reset(.retain_capacity);
    const arena = app.pick_arena.allocator();

    const ordered = try arena.dupe(PaneRow, rows);
    // Insertion, not pdq: the last tiebreak is the multiplexer's own
    // order, which only a stable sort keeps. Tens of rows either way.
    std.sort.insertion(PaneRow, ordered, {}, paneBefore);

    // Padded to the widest of each so the eye runs down a column. Every
    // field but the last is ASCII from a multiplexer, so bytes are
    // columns; the last is a sentence and is last so it is never measured.
    // Shortened first, then measured: the widest of what is drawn. The id
    // stands in where a backend reports nothing else - WezTerm, kitty and
    // herdr list ids, and a row built from the rest would be blank.
    const ell = app.glyphs.ellipsis;
    const ell_w = wrap_mod.columns(ell, .{ .method = .unicode });
    const wheres = try arena.alloc([]const u8, ordered.len);
    var w_where: usize = 0;
    for (ordered, wheres) |r, *w| {
        w.* = try shortWhere(arena, if (r.where.len > 0) r.where else r.id, ell, ell_w);
        w_where = @max(w_where, wrap_mod.columns(w.*, .{ .method = .unicode }));
    }

    var at: usize = 0;
    for (ordered, 0..) |r, i| {
        // Two states, two columns. Sharing one hid the agent that is
        // already the target from a `*` filter.
        const target = if (r.target) app.glyphs.target_mark else " ";
        const agent = if (r.agent) app.glyphs.agent_mark else " ";
        // One column for what the pane is, not two: on an agent row the
        // command is noise beside the mark, and on a shell row the title
        // is the terminal's default and the same on every one.
        const what = if (r.agent and r.title.len > 0) r.title else r.command;
        // No id: it names a pane to the multiplexer and to nobody else,
        // and is never typed. It survives in `detail`, for `--pane`.
        const shown_where = wheres[i];
        const where_w = wrap_mod.columns(shown_where, .{ .method = .unicode });
        const label = try std.fmt.allocPrint(arena, "{s}{s} {s}{s}  {s}", .{
            target,
            agent,
            shown_where,
            pad(arena, w_where -| where_w),
            what,
        });
        // Only what the row does not already say: a backend with nothing
        // but an id has it in the row, and would open a panel to repeat it.
        const detail = if (r.where.len > 0)
            try std.fmt.allocPrint(arena, "{s}  {s}  {s}", .{ r.id, r.where, r.command })
        else
            "";
        const id = try arena.dupe(u8, r.id);
        try app.finder_state.pane_ids.append(app.gpa, id);
        try app.pick_list.append(app.gpa, .{
            // Or the row ends in padding aligning a column nothing
            // follows.
            .path = std.mem.trimEnd(u8, label, " "),
            .added = 0,
            .removed = 0,
            .in_review = false,
            .plain = true,
            .detail = if (previews(app)) detail else "",
            .preview = if (previews(app)) try arena.dupe(u8, r.preview) else "",
            .preview_kind = .log,
        });
        if (r.target) at = i;
    }

    app.finder_state.pending_send = if (pending) |t| try arena.dupe(u8, t) else null;
    // Opened on the pane sends already go to, so reconnecting is a
    // confirmation rather than a search. Otherwise the top, which the
    // ordering has made the likeliest answer.
    show(app, .{ .title = " panes ", .at = @intCast(at), .gutter = false });
}

/// `n` spaces, from the pick arena.
pub fn pad(arena: Allocator, n: usize) []const u8 {
    const buf = arena.alloc(u8, n) catch return "";
    @memset(buf, ' ');
    return buf;
}

/// `<CR>` in the picker: connect to that pane, and send what was waiting.
pub fn pickPane(app: *App, at: ?u32) void {
    const i = at orelse {
        closeFiles(app);
        return;
    };
    if (i >= app.finder_state.pane_ids.items.len) {
        closeFiles(app);
        return;
    }
    const id = app.finder_state.pane_ids.items[i];
    const n = @min(id.len, app.finder_state.target_buf.len);
    @memcpy(app.finder_state.target_buf[0..n], id[0..n]);
    app.finder_state.want_target = app.finder_state.target_buf[0..n];

    // The payload has to leave the pick arena before `closeFiles` resets
    // it, and `outgoing` is the buffer the loop reads a send from.
    if (app.finder_state.pending_send) |text| {
        app.outgoing.clearRetainingCapacity();
        app.outgoing.appendSlice(app.gpa, text) catch {};
        app.want_send = .send;
    }
    app.finder_state.pending_send = null;
    closeFiles(app);
}

pub fn buildPickList(app: *App) void {
    // The picker's rows come from the loop, not from the review, and its
    // arena holds them: rebuilding here would empty the list under the
    // reader's filter.
    if (app.files_purpose == .panes or app.files_purpose == .prs) return;
    app.pick_list.clearRetainingCapacity();
    _ = app.pick_arena.reset(.retain_capacity);
    const arena = app.pick_arena.allocator();
    const changed = app.review.files();
    for (changed) |f| {
        // Copied, not borrowed. `f.path()` lives in the review's arena,
        // which every re-diff resets - and the list outlives a re-diff,
        // because the agent goes on writing while it is open. Borrowing
        // showed as a row whose path was a fragment of whatever the arena
        // had been reused for, which is the same failure the comment
        // labels below were already copied to avoid.
        const path = arena.dupe(u8, f.path()) catch return;
        app.pick_list.append(app.gpa, .{
            .path = path,
            .added = f.added,
            .removed = f.removed,
            .status = f.status,
            .preview = if (previews(app)) diffHead(arena, f) else "",
            .preview_kind = .diff,
        }) catch return;
    }
    if (app.files_purpose == .comments) {
        // One row per comment, in store order, so the index the overlay
        // hands back is the comment it names. The label carries the file,
        // the line and the text, which means the filter reaches all three:
        // typing part of a remark finds it.
        app.pick_list.clearRetainingCapacity();
        for (app.comments.items()) |n| {
            var one: [256]u8 = undefined;
            const body = compose_mod.flatten(&one, n.body);
            // A stale or already-sent comment has no dot on screen - one
            // points at code that moved, the other has been handed over -
            // so a list showing four when two are visible has to say why.
            const mark = switch (n.state) {
                .open => "",
                .sent => "[sent] ",
                .stale => "[stale] ",
            };
            // The row is the remark's address, not the remark. It used to
            // carry the body too, flattened and cut at whatever the column
            // left, which is unreadable beside a panel showing the whole
            // thing. The filter still reaches the text; see `filter`.
            // Whose it is, or that it is posted: never both. `[posted]` on
            // somebody else's remark states the obvious and spends the
            // width the author's name needs.
            const whose = if (n.theirs())
                std.fmt.allocPrint(arena, "@{s} ", .{n.author}) catch ""
            else if (n.posted)
                "[posted] "
            else
                "";
            const label = std.fmt.allocPrint(arena, "{s}:{d}  {s}{s}", .{
                n.path, n.line, mark, whose,
            }) catch continue;
            // The author is searchable too: "what did they say" is a
            // question a reader asks of a request with several reviewers.
            const searchable = std.fmt.allocPrint(arena, "{s}:{d}  {s} {s}", .{
                n.path, n.line, n.author, body,
            }) catch label;
            app.pick_list.append(app.gpa, .{
                .path = std.mem.trimEnd(u8, label, " "),
                .filter = searchable,
                .added = 0,
                .removed = 0,
                .in_review = false,
                .icon_path = n.path,
                .detail = if (previews(app)) std.mem.trimEnd(u8, label, " ") else "",
                // The remark first, then the code it is about. Neither is
                // in the row any more, and both are what a reader opened
                // the list to see.
                .preview = if (previews(app)) notes.commentPanel(app, arena, n) else "",
                .preview_lead = notes.lineCount(n.body),
                .preview_kind = .diff,
            }) catch return;
        }
        return;
    }
    if (app.files_purpose == .jump) return;

    loadProject(app);
    for (app.finder_state.project_paths) |p| {
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
        // Borrowed on purpose: `project_paths` is session-lived and never
        // moves, and copying fifty thousand of them into the arena would
        // cost more than the bug it would be preventing.
        app.pick_list.append(app.gpa, .{ .path = p, .added = 0, .removed = 0, .in_review = false }) catch return;
    }
}

/// Best effort, once. A repository that cannot be listed leaves the
/// mention list as the changed files, which is what it was before `@`
/// reached further and is still useful.
pub fn loadProject(app: *App) void {
    if (app.finder_state.project_loaded) return;
    app.finder_state.project_loaded = true;
    app.finder_state.project_paths = git.projectFiles(app.gpa, app.io) catch &.{};
}

pub fn toggleFiles(app: *App) void {
    if (app.mode == .finder) {
        closeFiles(app);
    } else {
        app.files_purpose = .jump;
        buildPickList(app);
        show(app, .{
            .title = " changed files ",
            .at = @intCast(files_mod.rowOf(app.pick_list.items, app.file_index)),
            .totals = reviewTotals(app),
        });
    }
}

pub fn moveList(app: *App, delta: i32) void {
    switch (app.mode) {
        .help => app.help.move(app.km.bindings, delta),
        .finder => app.file_list.move(app.pick_list.items, delta),
        else => {},
    }
}

pub fn pageList(app: *App, delta: i32) void {
    switch (app.mode) {
        .help => app.help.moveGroup(delta),
        .finder => app.file_list.movePage(app.pick_list.items, delta),
        else => {},
    }
}

/// Keys inside the file list are filter text, exactly as in the `?`
/// overlay. `Enter` jumps to the selected file, which is the whole point
/// of the list and the one thing it does that `?` does not.
pub fn feedFiles(app: *App, key: event.Key, body: u16) !void {
    // `<C-d>` clears the highlighted comment out of the list. It has to be
    // a chord: every printable key in this overlay is a filter character,
    // and a comment on a file that no longer exists cannot be reached to
    // be deleted any other way.
    switch (app.km.feed(key, .finder)) {
        .command => |cmd| return app.run(cmd, body),
        .pending, .none => {},
    }
    // A filter expands the fold before it runs. A search that skipped
    // folded rows would be a search that lies, and the reader typing a
    // turn number is exactly the case the fold hid the answer to.
    const filtering = app.files_purpose == .turns and !app.turns.expanded and
        key.codepoint >= 0x20 and key.codepoint != event.code.escape;

    switch (app.file_list.feed(key)) {
        .stay => {
            // The turn list expands as it is filtered, because a search
            // that skipped folded rows would lie. Only that list: every
            // other purpose has its rows already, and the picker's are the
            // loop's - `fillTurnRows` would replace them with a timeline.
            if (filtering and app.files_purpose == .turns and
                app.file_list.filter.text().len > 0)
            {
                app.turns.expanded = true;
                turns_mod.rebuildTurns(app);
            }
        },
        .close => closeFiles(app),
        .open => {
            const picked = app.file_list.selected(app.pick_list.items);
            if (app.files_purpose == .panes) return pickPane(app, picked);
            if (app.files_purpose == .prs) return pr_mod.pickPr(app, picked);
            if (app.files_purpose == .turns) {
                const i = picked orelse {
                    closeFiles(app);
                    return;
                };
                const want: u32 = if (i < app.turns.rows.items.len)
                    app.turns.rows.items[i]
                else
                    std.math.maxInt(u32);
                // Opening the fold shows what it hid rather than opening a
                // turn: a summary that cannot be opened is a wall, and the
                // reader is still choosing.
                if (want == turns_mod.elided_row or want == turns_mod.run_row) {
                    app.turns.expanded = true;
                    turns_mod.rebuildTurns(app);
                    return;
                }
                closeFiles(app);
                try turns_mod.showTurnNumber(app, want, body);
                return;
            }
            if (app.files_purpose == .comments) {
                const i = picked orelse {
                    closeFiles(app);
                    return;
                };
                const list = app.comments.items();
                var want_path: [4096]u8 = undefined;
                var want_line: u32 = 0;
                var have = false;
                if (i < list.len) {
                    const n = list[i];
                    @memcpy(want_path[0..n.path.len], n.path);
                    want_line = n.line;
                    have = true;
                    closeFiles(app);
                    try walks.showComment(app, want_path[0..n.path.len], want_line, body);
                    return;
                }
                closeFiles(app);
                app.clampScroll(body);
                return;
            }
            if (app.files_purpose == .browse) {
                const i = picked orelse {
                    closeFiles(app);
                    return;
                };
                const e = app.pick_list.items[i];
                if (e.in_review) {
                    // It is in the review, so show it: that is what the
                    // reader asked for by picking a file with a diff.
                    app.clearPreview();
                    for (app.review.files(), 0..) |f, fi| {
                        if (!std.mem.eql(u8, f.path(), e.path)) continue;
                        if (fi != app.file_index) {
                            app.file_index = @intCast(fi);
                            try app.rebuildRows(.reset);
                        }
                        break;
                    }
                    closeFiles(app);
                    app.clampScroll(body);
                    return;
                }
                // Nothing changed in it, so the review has nothing to
                // show - but the file is still there to read. Opened
                // whole, every line context, outside the review.
                var buf: [4096]u8 = undefined;
                const p = std.fmt.bufPrint(&buf, "{s}", .{e.path}) catch e.path;
                closeFiles(app);
                try app.openPreview(p);
                app.clampScroll(body);
                return;
            }
            if (app.files_purpose == .mention) {
                // The path lands at the caret, straight after the `@` that
                // opened the list, and nothing else is touched.
                if (picked) |i| app.compose.insert(app.pick_list.items[i].path);
                closeFiles(app);
                return;
            }
            if (picked) |i| {
                if (i != app.file_index) {
                    app.file_index = i;
                    try app.rebuildRows(.reset);
                }
            }
            closeFiles(app);
            app.clampScroll(body);
        },
    }
}

/// Whether a list may draw the panel beside it at all.
pub fn previews(app: *const App) bool {
    return app.list_preview;
}

/// The head of a file's diff, as unified text for the panel.
///
/// Built from the parsed hunks rather than sliced out of the raw `git
/// diff`. Slicing was cheaper and wrong for the files a reader most wants
/// to see: an untracked file's diff is synthesised, never parsed from
/// git's output, so it has no byte range and drew no panel at all. Walking
/// `lines` costs a `memcpy` either way and works for both.
///
/// The `@@` header is rebuilt because it carries the enclosing symbol,
/// which is most of what orients a reader in a hunk they have not scrolled
/// to yet.
pub fn diffHead(arena: Allocator, f: diff.FileDiff) []const u8 {
    return diffText(arena, f, null);
}

/// As `diffHead`, from the hunk that contains `at` rather than the first.
/// What a comment is *about*, which is the one thing its row does not
/// already say.
pub fn diffText(arena: Allocator, f: diff.FileDiff, at: ?u32) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines: usize = 0;
    var started = at == null;
    for (f.hunks) |h| {
        if (!started) {
            if (h.overlapsNew(at.?, 1) == 0) continue;
            started = true;
        }
        if (lines >= App.preview_lines or out.items.len >= App.preview_bytes) break;
        out.print(arena, "@@ -{d},{d} +{d},{d} @@{s}{s}\n", .{
            h.old_start,                        h.old_count,
            h.new_start,                        h.new_count,
            if (h.section.len > 0) " " else "", h.section,
        }) catch return out.items;
        lines += 1;

        for (h.lo..h.hi) |i| {
            if (lines >= App.preview_lines or out.items.len >= App.preview_bytes) break;
            const sign: u8 = switch (f.lines.kind[i]) {
                .add => '+',
                .del => '-',
                .context => ' ',
            };
            out.append(arena, sign) catch return out.items;
            out.appendSlice(arena, f.lines.text[i]) catch return out.items;
            out.append(arena, '\n') catch return out.items;
            lines += 1;
        }
    }
    return out.items;
}

/// Added and removed across every file of the review.
///
/// Summed here rather than kept on `Review`, because it is asked for once
/// when an overlay opens and never in a frame: a field would be a number
/// to keep in step with every re-diff for a caller that appears twice.
pub fn reviewTotals(app: *App) render.Totals {
    var out: render.Totals = .{ .added = 0, .removed = 0 };
    for (app.review.files()) |*f| {
        out.added +|= f.added;
        out.removed +|= f.removed;
    }
    return out;
}

/// Which row the list marks as "you are here", or none. `file_index` is
/// a fact about a list of files; on any other list it marks whatever row
/// landed at that index, and argues with the cursor.
pub fn listCurrent(app: *const App) u32 {
    return switch (app.files_purpose) {
        .jump, .mention, .browse => app.file_index,
        .comments, .turns, .panes, .prs => std.math.maxInt(u32),
    };
}

/// Keys inside the popup are filter text, not commands - the same rule the
/// bottom-line prompt follows, and why `help` is a mode the keymap ignores.
/// `F` opens the file list; `F`, `Esc` or backspacing out of an empty
/// filter closes it. One command for both, the way `?` and `V` are one.
/// Shuts the overlay and hands the keyboard back to whoever had it: the
/// compose box when the list was opened from inside one, the diff
/// otherwise.
pub fn closeFiles(app: *App) void {
    app.file_list.close();
    app.mode = if (app.files_purpose != .jump and app.compose.open) .note_input else .normal;
    app.files_purpose = .jump;
}

/// The comment list's own footer keys, read from the keymap so a remap
/// moves the footer with the binding.
pub fn commentListKeys(app: *App, arena: Allocator) []const keytext.HelpEntry {
    var out: std.ArrayList(keytext.HelpEntry) = .empty;
    // A footer naming a key that does nothing is worse than a shorter one,
    // and posting needs a pull request to post to.
    const want = [_]struct { cmd: keymap.Command, desc: []const u8, pr_only: bool = false }{
        .{ .cmd = .comment_send_one, .desc = "send" },
        .{ .cmd = .comment_send_all, .desc = "send all" },
        .{ .cmd = .comment_post_one, .desc = "post", .pr_only = true },
        .{ .cmd = .comment_drop, .desc = "del" },
    };
    for (want) |w| {
        if (w.pr_only and app.pr.number == 0) continue;
        var buf: [32]u8 = undefined;
        const keys = keytext.firstKeyFor(app.km.bindings, w.cmd, .finder, &buf);
        if (keys.len == 0) continue;
        out.append(arena, .{
            .keys = arena.dupe(u8, keys) catch continue,
            .desc = w.desc,
        }) catch continue;
    }
    return out.toOwnedSlice(arena) catch &.{};
}

const testing = std.testing;

test "the pane picker lists what it was handed and connects to one" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    const rows = [_]PaneRow{
        .{ .id = "%1", .where = "a:1.0", .command = "zsh", .title = "shell", .session = "a" },
        .{
            .id = "%7",
            .where = "a:2.0",
            .command = "claude",
            .title = "reviewing the diff",
            .session = "a",
            .agent = true,
        },
    };
    try openPanePicker(&fx.app, &rows, "#3 src/main.zig:12");

    try testing.expectEqual(event.Mode.finder, fx.app.mode);
    try testing.expectEqual(@as(usize, 2), fx.app.pick_list.items.len);
    // The agent leads its session, and the ids move with the rows.
    try testing.expectEqualStrings("%7", fx.app.finder_state.pane_ids.items[0]);
    try testing.expectEqualStrings("%1", fx.app.finder_state.pane_ids.items[1]);
    // Rows are labels, not paths: no filetype icon is guessed from one.
    try testing.expect(fx.app.pick_list.items[1].plain);

    // Picking asks the loop for two things at once, which is the point:
    // connect, and deliver what the failed send was carrying.
    pickPane(&fx.app, 0);
    try testing.expectEqualStrings("%7", fx.app.finder_state.want_target.?);
    try testing.expectEqual(App.Delivery.send, fx.app.want_send.?);
    try testing.expectEqualStrings("#3 src/main.zig:12", fx.app.outgoing.items);
    try testing.expectEqual(event.Mode.normal, fx.app.mode);
}

test "the picker groups by session, ours first, agents leading each" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    // Handed in the order tmux lists them, which is by session name: the
    // one we are in is in the middle of it.
    const rows = [_]PaneRow{
        .{ .id = "%566", .where = "look:1.0", .command = "2.1.261", .session = "look", .agent = true },
        .{ .id = "%665", .where = "look:4.0", .command = "zsh", .session = "look" },
        .{ .id = "%645", .where = "lgtm:2.0", .command = "zsh", .session = "lgtm", .here = true },
        .{ .id = "%667", .where = "lgtm:4.0", .command = "zsh", .session = "lgtm", .here = true },
        .{ .id = "%604", .where = "lgtm:1.0", .command = "2.1.263", .session = "lgtm", .here = true, .agent = true },
        .{ .id = "%540", .where = "setting:1.0", .command = "zsh", .session = "setting" },
    };
    try openPanePicker(&fx.app, &rows, null);

    const want = [_][]const u8{ "%604", "%645", "%667", "%566", "%665", "%540" };
    for (want, 0..) |id, i| try testing.expectEqualStrings(id, fx.app.finder_state.pane_ids.items[i]);
}

test "a pane row is padded into columns and marked" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    const rows = [_]PaneRow{
        .{ .id = "%604", .where = "lgtm:1.0", .command = "2.1.263", .session = "lgtm", .agent = true, .title = "JSON highlighting" },
        .{ .id = "%7", .where = "lgtm:12.0", .command = "zsh", .title = "kunkka07xx", .session = "lgtm" },
    };
    try openPanePicker(&fx.app, &rows, null);

    // Padded, so the last column starts in the same place on every row:
    // the agent's title, the shell's command. No id - it moved to
    // `detail`.
    const first = try std.fmt.allocPrint(
        testing.allocator,
        " {s} lgtm:1.0   JSON highlighting",
        .{fx.app.glyphs.agent_mark},
    );
    defer testing.allocator.free(first);
    try testing.expectEqualStrings(first, fx.app.pick_list.items[0].path);
    try testing.expectEqualStrings("   lgtm:12.0  zsh", fx.app.pick_list.items[1].path);
    try testing.expectEqualStrings("%604  lgtm:1.0  2.1.263", fx.app.pick_list.items[0].detail);
}

test "what a pane is showing reaches the row that draws it" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    const rows = [_]PaneRow{.{
        .id = "%604",
        .where = "lgtm:1.0",
        .command = "2.1.263",
        .title = "JSON highlighting",
        .session = "lgtm",
        .agent = true,
        .preview = "> waiting\n$ zig build test\n",
    }};
    try openPanePicker(&fx.app, &rows, null);

    // Owned by the pick arena, like the labels.
    try testing.expectEqualStrings("> waiting\n$ zig build test\n", fx.app.pick_list.items[0].preview);
    try testing.expectEqualStrings("%604  lgtm:1.0  2.1.263", fx.app.pick_list.items[0].detail);

    // Empty by default, so every other list draws no panel.
    const plain: render.FileEntry = .{ .path = "src/main.zig", .added = 0, .removed = 0 };
    try testing.expectEqualStrings("", plain.preview);
    try testing.expectEqualStrings("", plain.detail);
}

test "only a list of files marks a row as the one you are on" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    fx.app.files_purpose = .jump;
    try testing.expectEqual(fx.app.file_index, listCurrent(&fx.app));

    // On a list of panes `file_index` names a file, and the row at that
    // index is whichever pane landed there.
    fx.app.files_purpose = .panes;
    try testing.expectEqual(std.math.maxInt(u32), listCurrent(&fx.app));
}

test "a long session name loses its head, not the pane it names" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    const rows = [_]PaneRow{
        .{ .id = "%1", .where = "noah-tech-cl-v2:1.0", .command = "zsh", .session = "noah-tech-cl-v2" },
        .{ .id = "%2", .where = "noah-tech-cl-v2:2.0", .command = "zsh", .session = "noah-tech-cl-v2" },
    };
    try openPanePicker(&fx.app, &rows, null);

    // Capped, and `:1.0` survives: it is what tells the two rows apart.
    const e = fx.app.glyphs.ellipsis;
    const want = try std.fmt.allocPrint(testing.allocator, "   noah-tech{s}:1.0  zsh", .{e});
    defer testing.allocator.free(want);
    try testing.expectEqualStrings(want, fx.app.pick_list.items[0].path);
    // The whole of it is still one keystroke away, beside the list.
    try testing.expectEqualStrings("%1  noah-tech-cl-v2:1.0  zsh", fx.app.pick_list.items[0].detail);
}

test "the agent mark survives being the target, so the filter still finds it" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    const rows = [_]PaneRow{
        .{ .id = "%1", .where = "a:1.0", .command = "claude", .session = "a", .agent = true, .target = true },
        .{ .id = "%2", .where = "a:2.0", .command = "claude", .session = "a", .agent = true },
        .{ .id = "%3", .where = "a:3.0", .command = "zsh", .session = "a" },
    };
    try openPanePicker(&fx.app, &rows, null);

    const g = fx.app.glyphs;
    // Two columns: where sends go, and whether it is an agent. Sharing
    // one hid this row from a `*` filter.
    try testing.expect(std.mem.startsWith(u8, fx.app.pick_list.items[0].path, g.target_mark));
    for (fx.app.pick_list.items[0..2]) |row| {
        try testing.expect(std.mem.indexOf(u8, row.path, g.agent_mark) != null);
    }
    try testing.expect(std.mem.indexOf(u8, fx.app.pick_list.items[2].path, g.agent_mark) == null);
}

test "a file row previews the head of its diff, header and all" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    const arena = fx.app.pick_arena.allocator();

    var kinds = [_]hunk.LineKind{ .context, .del, .add };
    var olds = [_]u32{ 1, 2, 0 };
    var news = [_]u32{ 1, 0, 2 };
    var texts = [_][]const u8{ "const std = @import(\"std\");", "const old = 1;", "const new = 2;" };
    var hunks = [_]hunk.Hunk{.{
        .old_start = 1,
        .old_count = 2,
        .new_start = 1,
        .new_count = 2,
        .section = "pub fn main()",
        .lo = 0,
        .hi = 3,
    }};
    const f: diff.FileDiff = .{
        .old_path = "a.zig",
        .new_path = "a.zig",
        .status = .modified,
        .hunks = &hunks,
        .lines = .{ .kind = &kinds, .old_no = &olds, .new_no = &news, .text = &texts },
    };

    const head = diffHead(arena, f);
    // The header is rebuilt rather than sliced, because it carries the
    // enclosing symbol and that is most of what orients a reader.
    try testing.expect(std.mem.startsWith(u8, head, "@@ -1,2 +1,2 @@ pub fn main()\n"));
    try testing.expect(std.mem.indexOf(u8, head, "\n-const old = 1;\n") != null);
    try testing.expect(std.mem.indexOf(u8, head, "\n+const new = 2;\n") != null);
    try testing.expect(std.mem.indexOf(u8, head, "\n const std") != null);
}

test "a file git never diffed still gets a preview" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    const arena = fx.app.pick_arena.allocator();

    // An untracked file's diff is synthesised rather than parsed, so it
    // has no byte range in git's output. Slicing that range drew no panel
    // at all for exactly the files a reader most wants to look at.
    var kinds = [_]hunk.LineKind{ .add, .add };
    var olds = [_]u32{ 0, 0 };
    var news = [_]u32{ 1, 2 };
    var texts = [_][]const u8{ "// SPDX-License-Identifier: Apache-2.0", "const std = @import(\"std\");" };
    var hunks = [_]hunk.Hunk{.{
        .old_start = 0,
        .old_count = 0,
        .new_start = 1,
        .new_count = 2,
        .lo = 0,
        .hi = 2,
    }};
    const f: diff.FileDiff = .{
        .old_path = "/dev/null",
        .new_path = "src/core/gh.zig",
        .status = .added,
        .added = 2,
        .hunks = &hunks,
        .lines = .{ .kind = &kinds, .old_no = &olds, .new_no = &news, .text = &texts },
        // No raw section, which is the whole point of the case.
        .raw_lo = 0,
        .raw_hi = 0,
    };

    const head = diffHead(arena, f);
    try testing.expect(head.len > 0);
    try testing.expect(std.mem.indexOf(u8, head, "+// SPDX-License-Identifier") != null);
    // A hunk with no enclosing symbol closes its header rather than
    // trailing a space.
    try testing.expect(std.mem.startsWith(u8, head, "@@ -0,0 +1,2 @@\n"));
}

test "a file with nothing parsed previews nothing rather than a blank panel" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    const arena = fx.app.pick_arena.allocator();

    // A file past `large_file_lines` keeps its counts and no hunks until
    // `zo` opens it. Empty is honest: there is nothing to show yet.
    try testing.expectEqualStrings("", diffHead(arena, .{
        .old_path = "big.json",
        .new_path = "big.json",
        .status = .modified,
        .summarised = true,
        .added = 9000,
    }));
}

test "previews can be turned off, and then no list builds one" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    _ = try fx.app.comments.add("src/net.zig", 47, "a remark");
    fx.app.list_preview = false;
    fx.app.files_purpose = .comments;
    buildPickList(&fx.app);

    // Not merely hidden at draw time: nothing is copied into the arena
    // either, which is the point of a setting rather than a branch in the
    // renderer.
    try testing.expectEqualStrings("", fx.app.pick_list.items[0].preview);
    try testing.expectEqualStrings("", fx.app.pick_list.items[0].detail);
    // The row itself is untouched: the label is what the filter reads.
    try testing.expect(std.mem.indexOf(u8, fx.app.pick_list.items[0].filter, "a remark") != null);
}

test "a comment's panel starts at the hunk it sits in" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    const arena = fx.app.pick_arena.allocator();

    var kinds = [_]hunk.LineKind{ .context, .add, .context, .add };
    var olds = [_]u32{ 1, 0, 90, 0 };
    var news = [_]u32{ 1, 2, 90, 91 };
    var texts = [_][]const u8{ "top of file", "first change", "further down", "second change" };
    var hunks = [_]hunk.Hunk{
        .{ .old_start = 1, .old_count = 1, .new_start = 1, .new_count = 2, .lo = 0, .hi = 2 },
        .{ .old_start = 90, .old_count = 1, .new_start = 90, .new_count = 2, .lo = 2, .hi = 4 },
    };
    const f: diff.FileDiff = .{
        .old_path = "a.zig",
        .new_path = "a.zig",
        .status = .modified,
        .hunks = &hunks,
        .lines = .{ .kind = &kinds, .old_no = &olds, .new_no = &news, .text = &texts },
    };

    // A remark on line 91 is about the second hunk, and showing the first
    // would be showing the wrong code with total confidence.
    const at = diffText(arena, f, 91);
    try testing.expect(std.mem.startsWith(u8, at, "@@ -90,1 +90,2 @@"));
    try testing.expect(std.mem.indexOf(u8, at, "second change") != null);
    try testing.expect(std.mem.indexOf(u8, at, "first change") == null);

    // The file list wants the head instead, which is the same walk from
    // the first hunk.
    try testing.expect(std.mem.startsWith(u8, diffText(arena, f, null), "@@ -1,1 +1,2 @@"));

    // A line in no hunk at all shows nothing rather than the nearest thing.
    try testing.expectEqualStrings("", diffText(arena, f, 5000));
}

test "the remark leads its panel and is coloured as one" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    _ = try fx.app.comments.add("a.zig", 1, "one line\ntwo lines\nthree");
    fx.app.files_purpose = .comments;
    buildPickList(&fx.app);

    // The lead is the remark's own lines, so the renderer knows how much
    // of the panel is the reader's words and how much is the code.
    try testing.expectEqual(@as(u16, 3), fx.app.pick_list.items[0].preview_lead);
    try testing.expectEqual(@as(u16, 1), notes.lineCount("just one"));
    // A trailing newline does not invent a line.
    try testing.expectEqual(@as(u16, 2), notes.lineCount("a\nb\n"));
}

test "a comment row is its address; the remark is in the panel and the filter" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    const body = "the retry loop here\nnever backs off";
    _ = try fx.app.comments.add("src/net.zig", 47, body);
    fx.app.files_purpose = .comments;
    buildPickList(&fx.app);

    const row = fx.app.pick_list.items[0];
    // Drawn: where it is. The remark used to be here too, flattened and
    // cut at whatever the column left, beside a panel showing it whole.
    try testing.expectEqualStrings("src/net.zig:47", row.path);
    // Matched: the remark as well, so typing part of one still finds it.
    try testing.expect(std.mem.indexOf(u8, row.filter, "retry loop") != null);
    // Shown: the remark as written, unflattened.
    try testing.expect(std.mem.indexOf(u8, row.preview, "the retry loop here\nnever backs off") != null);
}

test "a backend that reports only ids still gets a list worth reading" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    // WezTerm, kitty and herdr answer ids and nothing else. Built from
    // the fields they leave empty, every row was a blank line you could
    // still press Enter on.
    const rows = [_]PaneRow{ .{ .id = "1" }, .{ .id = "12" } };
    try openPanePicker(&fx.app, &rows, null);

    try testing.expectEqualStrings("   1", fx.app.pick_list.items[0].path);
    try testing.expectEqualStrings("   12", fx.app.pick_list.items[1].path);
    // And no panel: the id is already in the row, so one saying it again
    // would be a panel opened to repeat the list.
    try testing.expectEqualStrings("", fx.app.pick_list.items[0].detail);
    try testing.expectEqualStrings("", fx.app.pick_list.items[0].preview);
}

test "the picker opens on the pane sends already go to" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    const rows = [_]PaneRow{
        .{ .id = "%1", .command = "zsh", .session = "a" },
        .{ .id = "%2", .command = "zsh", .session = "a", .target = true },
    };
    try openPanePicker(&fx.app, &rows, null);

    // The marker takes the column an agent dot would have had, and the
    // cursor starts there rather than at the top.
    try testing.expect(std.mem.startsWith(u8, fx.app.pick_list.items[1].path, fx.app.glyphs.target_mark));
    pickPane(&fx.app, @intCast(fx.app.file_list.index));
    try testing.expectEqualStrings("%2", fx.app.finder_state.want_target.?);
}

test "the picker opened by hand sends nothing" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    const rows = [_]PaneRow{.{ .id = "%2", .where = "b:1.0", .command = "bash", .session = "b" }};
    try openPanePicker(&fx.app, &rows, null);
    pickPane(&fx.app, 0);

    // `<Space>t` is "point sends there", not "send now": there is nothing
    // waiting, so nothing goes.
    try testing.expectEqualStrings("%2", fx.app.finder_state.want_target.?);
    try testing.expect(fx.app.want_send == null);
}

test "leaving the picker connects to nothing" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    const rows = [_]PaneRow{.{ .id = "%2", .where = "b:1.0", .command = "bash", .session = "b" }};
    try openPanePicker(&fx.app, &rows, "text");
    pickPane(&fx.app, null);

    try testing.expect(fx.app.finder_state.want_target == null);
    try testing.expect(fx.app.want_send == null);
    try testing.expectEqual(event.Mode.normal, fx.app.mode);
}

test "F opens the file list on the file the review is showing" {
    var fx = try app_mod.Fixture.init(testing.allocator);
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
    var fx = try app_mod.Fixture.init(testing.allocator);
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
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("j");
    const moved = fx.app.vp.cursor;
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
    var fx = try app_mod.Fixture.init(testing.allocator);
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

test "cancelling the file picker leaves the @ that was typed" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("<CR>");
    try fx.press("@");
    try fx.press("<Esc>");
    // Back in the box, not out of it, and the character stands: it was typed.
    try testing.expectEqual(event.Mode.note_input, fx.app.mode);
    try testing.expectEqualStrings("#1 a.zig:1@", fx.app.compose.text());
}

test "the file overlay still jumps when it was not opened from the box" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    // Same list, same filter, same drawing - only Enter differs, and that is
    // what `files_purpose` is for.
    try fx.press("<Space>f");
    try testing.expectEqual(event.Mode.finder, fx.app.mode);
    try fx.press("<CR>");
    try testing.expectEqual(event.Mode.normal, fx.app.mode);
    try testing.expect(!fx.app.compose.open);
}
