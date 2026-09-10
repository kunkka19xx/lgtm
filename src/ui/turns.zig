// SPDX-License-Identifier: Apache-2.0
//
// The turn timeline and the restore: what the agent wrote, turn by turn, and
// putting a file back to how one of them left it. `snapshot/` is the store.

const std = @import("std");
const Allocator = std.mem.Allocator;

const App = @import("app.zig").App;
const finder_mod = @import("finder.zig");
const git = @import("../core/git.zig");
const gitobj = @import("../snapshot/gitobj.zig");
const keymap = @import("keymap.zig");
const keytext = @import("keytext.zig");
const snapshot = @import("../snapshot/snapshot.zig");
const timeline = @import("../snapshot/timeline.zig");
const walks = @import("walks.zig");
const fs_mod = @import("../io/fs.zig");
const event = @import("../core/event.zig");
const theme_mod = @import("theme.zig");

/// What `the list` holds for the `⋮` row: not a turn, and not the
/// working tree's `maxInt` either, so opening it can be told from opening
/// anything else.
pub const elided_row: u32 = std.math.maxInt(u32) - 1;

/// What `the list` holds for a folded *run*. Distinct from `elided_row`
/// only so the two can say different things if they ever need to; both
/// open by expanding.
pub const run_row: u32 = std.math.maxInt(u32) - 2;

/// How many of the newest turns are always drawn.
///
/// Enough to answer "what did it just do" without scrolling, which is what
/// the list is opened for nine times in ten. Small enough that the two
/// pinned ends and the mark are on the same screen as it.
pub const turns_shown: usize = 8;

pub const State = struct {
    /// Turn numbers behind the rows, so the index the overlay hands back is
    /// the turn it names.
    rows: std.ArrayList(u32) = .empty,
    /// Showing every turn rather than eliding the middle. Cleared when the
    /// list opens: a fold expanded once should not stay expanded all day.
    expanded: bool = false,
    /// Whether the mark has been looked for on disk yet. Once, after the
    /// first diff: before it there is nothing to attach the bytes to, after
    /// it a second look would undo whatever has since been marked.
    mark_restored: bool = false,
    /// A restore waiting for the reader to say yes. One keystroke is the
    /// right friction *because* it is undoable: the snapshot comes first.
    pending: ?Spot = null,
    /// The last restore, for `u`. Session-only: a `u` that survived a restart
    /// would undo something long since forgotten. One step, then gone.
    last: ?Done = null,

    pub fn deinit(self: *State, gpa: Allocator) void {
        self.rows.deinit(gpa);
    }
};

/// Which file, from which turn.
pub const Spot = struct {
    turn: u32,
    path: [4096]u8 = undefined,
    path_len: u16 = 0,

    pub fn name(self: *const Spot) []const u8 {
        return self.path[0..self.path_len];
    }
};

/// The same, plus what the restore wrote. A file that no longer hashes to it
/// has been changed since, and undoing would be overwriting that.
pub const Done = struct {
    turn: u32,
    path: [4096]u8 = undefined,
    path_len: u16 = 0,
    wrote: u64 = 0,

    pub fn name(self: *const Done) []const u8 {
        return self.path[0..self.path_len];
    }
};

/// The turn list: what the agent has written, one row per turn.
///
/// Built from the commit chain rather than from parsed diffs
///, which is what keeps it two subprocesses whatever
/// the length of the session. `Enter` shows that turn, so the list is a
/// selector and the diff view is the viewer - there is no second display
/// of files and hunks anywhere in this feature.
pub fn openTurnList(app: *App) !void {
    if (app.snap == null) {
        app.notice.set("snapshots are off here - no turns to list", .{});
        return;
    }
    // Folded again each time it is opened. A fold the reader expanded once
    // to find something should not still be expanded tomorrow morning,
    // which is the state the fold exists for.
    app.turns.expanded = false;
    if (!fillTurnRows(app)) return;

    app.files_purpose = .turns;
    // Opened on the row the reader is already looking at, rather than at an
    // arbitrary top.
    var at: u32 = 0;
    for (app.pick_list.items, 0..) |row, i| {
        if (row.current) at = @intCast(i);
    }
    finder_mod.show(app, .{ .title = " turns ", .at = at });
}

/// The same rows again, with the fold in whatever state it is now.
///
/// Separate from opening because expanding is not opening: the overlay
/// stays where it is, the filter keeps what has been typed, and only the
/// rows underneath change. The selection is clamped rather than reset -
/// the list only ever grows here, so the row the reader was on is still
/// there and usually still under the cursor.
pub fn rebuildTurns(app: *App) void {
    _ = fillTurnRows(app);
    // The list only ever grows here, so the row the reader was on is still
    // there; `move(0)` re-narrows the selection against the new rows
    // without moving it.
    app.file_list.move(app.pick_list.items, 0);
}

/// Reads the timeline and lays the rows out. False when there is nothing
/// to show and the caller has already been told why.
pub fn fillTurnRows(app: *App) bool {
    const store = if (app.snap) |*s| s else return false;
    if (store.state.latest_turn == 0 and !store.state.has_baseline) {
        app.notice.set("no turns yet - one is taken when the agent stops writing", .{});
        return false;
    }

    // The files carrying a comment the reader has already sent. A turn
    // that touched one of them is the agent answering them, as against
    // doing something else - which is the distinction `FEATURES.md` 1.4 is
    // entirely about, and half of `SPEC.md` open question 5.
    //
    // Distinct paths, because ten comments on one file is one file. Held
    // in the pick arena, which is reset just below and then rebuilt - so
    // this is gathered before the reset rather than after it.
    var watching: std.ArrayList([]const u8) = .empty;
    defer watching.deinit(app.gpa);
    for (app.comments.items()) |n| {
        if (n.state != .sent) continue;
        var seen = false;
        for (watching.items) |w| {
            if (std.mem.eql(u8, w, n.path)) seen = true;
        }
        if (!seen) watching.append(app.gpa, n.path) catch {};
    }

    const read = timeline.read(app.gpa, app.io, store.state.name(), store.state.latest_turn, watching.items) catch {
        app.notice.set("could not read the timeline", .{});
        return false;
    };
    defer app.gpa.free(read.text);
    defer app.gpa.free(read.turns);

    app.pick_list.clearRetainingCapacity();
    app.turns.rows.clearRetainingCapacity();
    _ = app.pick_arena.reset(.retain_capacity);
    const arena = app.pick_arena.allocator();
    const now_s: i64 = @intCast(@divFloor(
        std.Io.Timestamp.now(app.io, .real).toNanoseconds(),
        std.time.ns_per_s,
    ));

    // The working tree, pinned at the top. The way back has to be in the
    // same list as the way out, or the reader is somewhere with no visible
    // exit - the one thing a history view must never be.
    var here: u32 = 0;
    if (app.review.viewing == null) here = 0;
    app.pick_list.append(app.gpa, .{
        .path = arena.dupe(u8, "│ working tree  now") catch "working tree",
        .added = 0,
        .removed = 0,
        .in_review = false,
        .plain = true,
        .current = app.review.viewing == null,
    }) catch return false;
    app.turns.rows.append(app.gpa, std.math.maxInt(u32)) catch return false;

    var age_buf: [24]u8 = undefined;
    // One row per run of folded turns, not one per turn: the count is the
    // whole point, and a `⋮` between every pair would be longer than the
    // list it replaced.
    const marked = store.state.reviewed_turn;
    var folded: u32 = 0;
    var i: usize = 0;
    while (i < read.turns.len) : (i += 1) {
        const turn = read.turns[i];
        if (!turnKept(app, turn.number, i, store.state.latest_turn, marked)) {
            folded += 1;
            continue;
        }
        if (folded > 0) {
            app.pick_list.append(app.gpa, .{
                .path = std.fmt.allocPrint(arena, "⋮   {d} turn{s}", .{
                    folded,
                    if (folded == 1) "" else "s",
                }) catch "⋮",
                .added = 0,
                .removed = 0,
                .in_review = false,
                .plain = true,
            }) catch return false;
            app.turns.rows.append(app.gpa, elided_row) catch return false;
            folded = 0;
        }
        // A run of turns over the same file, drawn as one row. `git log`
        // gives them newest first, so the run runs forwards from here and
        // `turn` is its newest member - which is the age worth showing and
        // the state the work ended at.
        var run_end = i;
        var run_added = turn.added;
        var run_removed = turn.removed;
        while (run_end + 1 < read.turns.len and
            turnKept(app, read.turns[run_end + 1].number, run_end + 1, store.state.latest_turn, marked) and
            runsWith(app, turn, read.turns[run_end + 1], marked))
        {
            run_end += 1;
            run_added +|= read.turns[run_end].added;
            run_removed +|= read.turns[run_end].removed;
        }
        if (run_end > i) {
            app.pick_list.append(app.gpa, .{
                .path = std.fmt.allocPrint(arena, "{s} {d}-{d}  {s}  {s}  ×{d}", .{
                    app.glyphs.run_mark,
                    read.turns[run_end].number,
                    turn.number,
                    turn.path,
                    timeline.age(&age_buf, turn.when_s, now_s),
                    run_end - i + 1,
                }) catch "run",
                .added = run_added,
                .removed = run_removed,
                // The counts are the run's, summed, and they are real -
                // unlike the `⋮` row's, which stands for turns whose
                // numbers it is not adding up.
                .in_review = true,
                .icon_path = arena.dupe(u8, turn.path) catch "",
            }) catch return false;
            app.turns.rows.append(app.gpa, run_row) catch return false;
            i = run_end;
            continue;
        }

        const shown = turnLabel(arena, turn, store, &age_buf, now_s, app.glyphs);
        app.pick_list.append(app.gpa, .{
            .path = shown,
            // The baseline is not a change - it is what was there before
            // any were made - so it gets no counts. `+4 -0` beside it
            // would dress up "this is the starting state" as "the agent
            // added four lines", which is the same mistake `+0 -0` on an
            // unchanged file was.
            .added = if (turn.number == 0) 0 else turn.added,
            .removed = if (turn.number == 0) 0 else turn.removed,
            .in_review = turn.number != 0,
            // The icon comes from the file the turn mostly touched, not
            // from the composed label. A turn that changed nothing, and
            // the baseline, name no file and get none.
            // Copied, not borrowed. `turn.path` points into the `git log`
            // output that this function frees on the way out, and the row
            // outlives the call - the label survived only because
            // `allocPrint` had already copied it. A dangling path read as
            // a generic file icon instead of a Zig one, which is how it
            // was noticed rather than how it would usually show.
            .icon_path = if (turn.number == 0) "" else arena.dupe(u8, turn.path) catch "",
            // Typing a number in this list means a turn, not a digit that
            // happens to appear in an age or a count.
            .key = turn.number,
            .plain = turn.number == 0 or turn.files == 0,
            .current = if (app.review.viewing) |v| v == turn.number else false,
        }) catch return false;
        app.turns.rows.append(app.gpa, turn.number) catch return false;
    }
    // A session whose oldest turns are folded and whose baseline is gone -
    // pruned by `[snapshot] keep` - ends on the fold rather than dropping
    // the count that says how much is missing.
    if (folded > 0) {
        app.pick_list.append(app.gpa, .{
            .path = std.fmt.allocPrint(arena, "⋮   {d} turn{s}", .{
                folded,
                if (folded == 1) "" else "s",
            }) catch "⋮",
            .added = 0,
            .removed = 0,
            .in_review = false,
            .plain = true,
        }) catch return false;
        app.turns.rows.append(app.gpa, elided_row) catch return false;
    }
    return true;
}

/// Asks whether to overwrite a file with the version in the turn on screen.
///
/// Every refusal here is a case where writing would be wrong rather than
/// merely unwanted: no turn to restore from, no file under the cursor, a
/// turn that never contained it, a file already identical, a path that
/// could reach outside the repository, or a store that cannot take the
/// snapshot this is only safe because of.
pub fn restoreAsk(app: *App) !void {
    const turn = app.review.viewing orelse {
        var k: [32]u8 = undefined;
        app.notice.set("nothing to restore from - {s} walks back to a turn", .{
            app.keyFor(.prev_turn, .normal, &k),
        });
        return;
    };
    const f = app.current() orelse return;
    const path = f.path();
    if (!snapshot.writablePath(path)) {
        app.notice.set("refusing to write {s}", .{path});
        return;
    }

    const ref = app.review.viewRef() orelse return;
    const blobs = snapshot.readPaths(app.gpa, app.io, ref, &.{path}) catch {
        app.notice.set("could not read {s} from turn {d}", .{ path, turn });
        return;
    };
    defer {
        for (blobs) |b| app.gpa.free(b);
        app.gpa.free(blobs);
    }
    if (blobs.len == 0 or blobs[0].len == 0) {
        app.notice.set("turn {d} had no {s}", .{ turn, path });
        return;
    }

    // Already identical is not a no-op worth performing: it would take a
    // snapshot and rewrite a file to the bytes already in it, and then
    // report success for having done nothing.
    const on_disk = fs_mod.readFile(app.io, app.gpa, path, 1 << 24) catch &.{};
    defer if (on_disk.len > 0) app.gpa.free(on_disk);
    if (std.mem.eql(u8, on_disk, blobs[0])) {
        app.notice.set("{s} is already what turn {d} had", .{ path, turn });
        return;
    }

    var pending: @TypeOf(app.turns.pending.?) = .{ .turn = turn };
    const n = @min(path.len, pending.path.len);
    @memcpy(pending.path[0..n], path[0..n]);
    pending.path_len = @intCast(n);
    app.turns.pending = pending;
    app.notice.set("overwrite {s} with turn {d}? y to confirm, any other key cancels", .{ path, turn });
}

/// The answer. Anything but `y` is no, because the safe reading of an
/// ambiguous keystroke is the one that does not write.
pub fn restoreAnswer(app: *App, key: event.Key, body: u16) !void {
    const ask = app.turns.pending.?;
    app.turns.pending = null;
    if (key.codepoint != 'y' or key.mods.ctrl) {
        app.notice.set("restore cancelled - nothing was written", .{});
        return;
    }

    // Snapshot first, always. Without one this would be
    // the only unrecoverable action in the tool, so a store that cannot
    // take it is a reason to refuse rather than to proceed carefully.
    if (!snapshotTurn(app)) {
        app.notice.set("refusing: could not snapshot first, so this could not be undone", .{});
        return;
    }
    const undo_turn = if (app.snap) |s| s.state.latest_turn else 0;

    const ref_turn = ask.turn;
    var ref_buf: [128]u8 = undefined;
    const store = if (app.snap) |*s| s else return;
    const ref = gitobj.refFor(&ref_buf, store.state.name(), ref_turn) catch return;

    const blobs = snapshot.readPaths(app.gpa, app.io, ref, &.{ask.name()}) catch {
        app.notice.set("could not read turn {d}", .{ref_turn});
        return;
    };
    defer {
        for (blobs) |b| app.gpa.free(b);
        app.gpa.free(blobs);
    }
    if (blobs.len == 0) return;

    fs_mod.writeFile(app.io, ask.name(), blobs[0]) catch {
        app.notice.set("could not write {s}", .{ask.name()});
        return;
    };

    // What `u` will need: the turn holding the state this just replaced,
    // and a hash of what was written, so undoing can tell "put back what
    // I replaced" from "overwrite whatever has happened since".
    var mem: @TypeOf(app.turns.last.?) = .{
        .turn = undo_turn,
        .wrote = std.hash.Wyhash.hash(0, blobs[0]),
    };
    const nm = @min(ask.path_len, mem.path.len);
    @memcpy(mem.path[0..nm], ask.name()[0..nm]);
    mem.path_len = @intCast(nm);
    app.turns.last = mem;

    // Back to the working tree, because that is what just changed and it
    // is the only place the reader can act on it.
    app.review.showWorking();
    try app.rediff();
    app.clampScroll(body);
    var k: [32]u8 = undefined;
    app.notice.set("restored {s} from turn {d} - {s} to turn {d} undoes it", .{
        ask.name(), ref_turn, app.keyFor(.prev_turn, .normal, &k), undo_turn,
    });
}

/// Puts back what the last restore replaced.
///
/// No confirmation, unlike `R`: the reader is undoing something they chose
/// a moment ago, and this snapshots first like every other write, so it is
/// as reversible as the thing it reverses. What it does check is that the
/// file is still what the restore left there - if something has changed it
/// since, this would not be an undo, and the reader should be told rather
/// than have the change taken from under them.
pub fn undoRestore(app: *App, body: u16) !void {
    const last = app.turns.last orelse {
        var k: [32]u8 = undefined;
        app.notice.set("nothing to undo - {s} restores a file from a turn", .{
            app.keyFor(.restore_file, .normal, &k),
        });
        return;
    };
    if (app.readOnly()) return;

    const on_disk = fs_mod.readFile(app.io, app.gpa, last.name(), 1 << 24) catch &.{};
    defer if (on_disk.len > 0) app.gpa.free(on_disk);
    if (std.hash.Wyhash.hash(0, on_disk) != last.wrote) {
        app.turns.last = null;
        app.notice.set("{s} has changed since - undoing would overwrite that, not the restore", .{last.name()});
        return;
    }

    const store = if (app.snap) |*s| s else return;
    var ref_buf: [128]u8 = undefined;
    const ref = gitobj.refFor(&ref_buf, store.state.name(), last.turn) catch return;
    const blobs = snapshot.readPaths(app.gpa, app.io, ref, &.{last.name()}) catch {
        app.notice.set("turn {d} is gone - nothing to put back", .{last.turn});
        app.turns.last = null;
        return;
    };
    defer {
        for (blobs) |b| app.gpa.free(b);
        app.gpa.free(blobs);
    }
    if (blobs.len == 0) {
        app.turns.last = null;
        return;
    }

    // Snapshot first, the same rule every write here obeys - which is also
    // what makes the *other* direction available afterwards.
    if (!snapshotTurn(app)) {
        app.notice.set("refusing: could not snapshot first, so this could not be undone", .{});
        return;
    }
    const back_turn = store.state.latest_turn;

    fs_mod.writeFile(app.io, last.name(), blobs[0]) catch {
        app.notice.set("could not write {s}", .{last.name()});
        return;
    };
    const name = last.name();
    var name_buf: [4096]u8 = undefined;
    @memcpy(name_buf[0..name.len], name);
    const shown = name_buf[0..name.len];

    // One step. A second `u` has nothing to undo; going forward again is
    // the move the notice names, which is the mechanism this shortcuts.
    app.turns.last = null;
    try app.rediff();
    app.clampScroll(body);
    var k: [32]u8 = undefined;
    app.notice.set("undid the restore of {s} - {s} to turn {d} puts it back", .{
        shown, app.keyFor(.prev_turn, .normal, &k), back_turn,
    });
}

/// The ref a turn is diffed against: the turn before it, or HEAD for the
/// baseline, which has nothing before it and whose meaning is exactly "what
/// was uncommitted before the agent ran".
pub fn baseRefFor(app: *App, turn: u32, buf: []u8) []const u8 {
    if (turn == 0) return "HEAD";
    const store = if (app.snap) |*s| s else return "HEAD";
    const ref = gitobj.refFor(buf[0 .. buf.len - 1], store.state.name(), turn) catch return "HEAD";
    // `^` rather than turn - 1: git knows what this commit's parent is, and
    // asking it avoids assuming the numbering is dense. A session whose
    // first turn has no baseline before it has no parent at all, and
    // `regenerate` falls back to HEAD when the diff refuses.
    buf[ref.len] = '^';
    return buf[0 .. ref.len + 1];
}

/// Shows one turn by number, or the working tree for the sentinel.
///
/// The same two states `]t` walks between, reached by choosing rather than
/// by stepping - which is the whole of what the list adds. Nothing here is
/// a third way to be looking at something.
pub fn showTurnNumber(app: *App, turn: u32, body: u16) !void {
    const store = if (app.snap) |*s| s else return;
    if (turn == std.math.maxInt(u32)) {
        if (app.review.viewing == null) return;
        app.review.showWorking();
        try app.rediff();
        app.clampScroll(body);
        app.notice.set("back to the working tree", .{});
        return;
    }

    var buf: [128]u8 = undefined;
    const ref = gitobj.refFor(&buf, store.state.name(), turn) catch return;
    var base_buf: [128]u8 = undefined;
    app.review.showTurn(turn, ref, baseRefFor(app, turn, &base_buf));
    try app.rediff();
    app.clampScroll(body);
    if (app.review.viewing == null) {
        app.notice.set("turn {d} is gone", .{turn});
        return;
    }
    var k: [32]u8 = undefined;
    const back = app.keyFor(.next_turn, .normal, &k);
    if (turn == 0) {
        app.notice.set("the baseline - before the agent ran, {s} returns", .{back});
        return;
    }
    app.notice.set("turn {d} - read only, {s} returns", .{ turn, back });
}

/// Whether two adjacent turns are one piece of work.
///
/// Four turns in a row on `app.zig` is one thing that took four tries, and
/// drawing it as four rows spends four lines saying one thing. smartlog
/// does not fold adjacent commits because a commit is individually
/// meaningful; an agent's turn is not, which is the whole difference this
/// list has to work with.
///
/// Never across a turn that has something of its own to say: the mark, the
/// turn on screen, the baseline, a self-revert, a reply, or a turn that
/// changed nothing. Folding one of those away would hide the very thing
/// the row was worth drawing for.
pub fn runsWith(app: *const App, a: timeline.Turn, b: timeline.Turn, marked: u32) bool {
    if (app.turns.expanded) return false;
    if (a.files == 0 or b.files == 0) return false;
    if (a.number == 0 or b.number == 0) return false;
    if (a.reverted or b.reverted or a.answered or b.answered) return false;
    if (marked > 0 and (a.number == marked or b.number == marked)) return false;
    if (app.review.viewing) |v| {
        if (v == a.number or v == b.number) return false;
    }
    return a.path.len > 0 and std.mem.eql(u8, a.path, b.path);
}

/// Whether turn `n` survives the fold.
///
/// Four kinds of row do. The **newest few**, because that is the question
/// being asked. The **mark**, because it is where the reader stopped and
/// `✓` is meaningless if the row it sits on is gone. The **baseline**,
/// because it is one of the two ends and the one snapshot nothing else can
/// reconstruct. And the **turn on screen**, because eliding the row the
/// reader is standing on is the one thing a history view must never do.
///
/// Everything else is the middle of a long session, which is what the
/// count replaces.
///
/// This is elision by *distance*, not by read state. `SNAPSHOTS.md` 5.3b
/// folds the turns before the mark on the grounds that they have been
/// dealt with, and that is right for the nineteen-turn session it draws
/// and wrong for a real one: a mark that has stood since the morning
/// leaves every turn unread, and the fold fires on nothing at all. The two
/// ends are what a reader navigates from, which is what smartlog actually
/// elides around.
pub fn turnKept(app: *const App, n: u32, index: usize, newest: u32, marked: u32) bool {
    _ = newest;
    if (app.turns.expanded) return true;
    if (index < turns_shown) return true;
    if (n == 0) return true;
    if (marked > 0 and n == marked) return true;
    if (app.review.viewing) |v| {
        if (v == n) return true;
    }
    return false;
}

pub fn turnLabel(
    arena: Allocator,
    turn: timeline.Turn,
    store: *const snapshot.Store,
    age_buf: []u8,
    now_s: i64,
    glyphs: theme_mod.Glyphs,
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
    // A turn that changed nothing still happened - the snapshot restore
    // takes before it writes is one, and so is any quiet period the agent
    // spent thinking. It gets a word rather than a blank path and "0
    // files", which reads as a row that failed to load.
    if (turn.files == 0) {
        return std.fmt.allocPrint(arena, "{s} {d: <3} no change  {s}", .{ rail, turn.number, when }) catch "turn";
    }
    // Appended rather than given a column of its own. A column would cost
    // one everywhere to say something on the rare row, and this is rare by
    // nature - an agent walking its own work back is the exception the
    // marker exists to catch, not the rule.
    const undone = if (turn.reverted)
        std.fmt.allocPrint(arena, "  {s} {d}", .{ glyphs.revert_mark, turn.reverted_to }) catch ""
    else
        "";
    // The pair `SNAPSHOTS.md` 5.3c asks for: one says the agent went
    // backwards, the other says it was listening.
    const replied = if (turn.answered) glyphs.answer_mark else "";
    return std.fmt.allocPrint(arena, "{s} {d: <3} {s}  {s}  {d} file{s}{s}{s}", .{
        rail,
        turn.number,
        turn.path,
        when,
        turn.files,
        if (turn.files == 1) "" else "s",
        undone,
        replied,
    }) catch "turn";
}

/// Walks the timeline: one turn back, or forward to the working tree.
///
/// The working tree is a position in the walk rather than a place outside
/// it, so `]t` from the newest turn lands there and there is always a way
/// forward. Nothing here is a jump into a different mode: it is the same
/// review with a different right-hand side.
pub fn turnStep(app: *App, delta: i32, body: u16) !void {
    const store = if (app.snap) |*s| s else {
        app.notice.set("snapshots are off here - no turns to walk", .{});
        return;
    };
    const latest = store.state.latest_turn;
    if (latest == 0) {
        app.notice.set("no turns yet - one is taken when the agent stops writing", .{});
        return;
    }

    // Null is the working tree, and it sits one past the newest turn.
    const here: i64 = if (app.review.viewing) |t| @intCast(t) else @as(i64, latest) + 1;
    const want = here + delta;

    if (want > latest) {
        if (app.review.viewing == null) {
            app.notice.set("already on the working tree", .{});
            return;
        }
        app.review.showWorking();
        try app.rediff();
        app.clampScroll(body);
        app.notice.set("back to the working tree", .{});
        return;
    }
    // The floor is the baseline when there is one and turn 1 when there is
    // not - a session that started on a clean tree has nothing before its
    // first turn, and walking to a ref that was never written would report
    // it as missing rather than as absent by design.
    const oldest = store.oldestTurn();
    if (want < oldest) {
        if (oldest == 0)
            app.notice.set("the baseline is as far back as it goes", .{})
        else
            app.notice.set("turn 1 is the oldest recorded - no baseline for this session", .{});
        return;
    }

    const turn: u32 = @intCast(want);
    var buf: [128]u8 = undefined;
    const ref = gitobj.refFor(&buf, store.state.name(), turn) catch {
        app.notice.set("cannot name that turn", .{});
        return;
    };
    var base_buf: [128]u8 = undefined;
    app.review.showTurn(turn, ref, baseRefFor(app, turn, &base_buf));
    try app.rediff();
    app.clampScroll(body);
    if (app.review.viewing == null) {
        // `regenerate` gave up on the ref - pruned, or never written.
        app.notice.set("turn {d} is gone", .{turn});
        return;
    }
    var k: [32]u8 = undefined;
    const back = app.keyFor(.next_turn, .normal, &k);
    // "returns" only when there is nothing between here and the present. A
    // turn taken while the reader was parked puts one there, and the
    // message then promised something the key would not do.
    const forward: []const u8 = if (turn >= latest) "returns to the working tree" else "goes forward";
    if (turn == 0) {
        // Not "turn 0". It is the tree as it was before the agent ran, and
        // that is the only thing about it worth saying.
        app.notice.set("the baseline - before the agent ran, {s} {s}", .{ back, forward });
        return;
    }
    app.notice.set("turn {d} of {d} - read only, {s} {s}", .{ turn, latest, back, forward });
}

/// Records the working tree as a turn, because the agent has stopped.
///
/// The same call `m` makes, with a different reason and without touching
/// `reviewed_turn`: a turn nobody has read must not mark itself read, or
/// the gutter would go blank exactly when it had something to say.
/// Every path the snapshot has to carry, which is not the review's list.
///
/// `[review] ignore` keeps a file off the screen; it must never keep one
/// out of the safety net. Staging only what the review shows wrote HEAD's
/// copy of an ignored file into the turn - or nothing at all, for an
/// untracked one - so a restore silently reverted or deleted work the
/// reader had never been shown. Ask git, which cannot drift from the
/// filter because it has never heard of it.
///
/// Caller frees with `git.freePaths`.
pub fn snapshotPaths(app: *App) ?[][]const u8 {
    return git.snapshotPaths(app.gpa, app.io) catch null;
}

pub fn snapshotTurn(app: *App) bool {
    var store = &(if (app.snap) |*s| s else return false).*;
    const paths = snapshotPaths(app) orelse return false;
    defer git.freePaths(app.gpa, paths);
    if (paths.len == 0) return false;

    return store.take(paths, "turn") != null;
}

/// Writes the mark to a ref, so it outlives the process. Returns whether it
/// stuck: snapshots are off in a directory git does not own, and the mark
/// is still perfectly good for this session without them.
pub fn snapshotMark(app: *App) bool {
    var store = &(if (app.snap) |*s| s else return false).*;
    const paths = snapshotPaths(app) orelse return false;
    defer git.freePaths(app.gpa, paths);
    if (paths.len == 0) return false;

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
pub fn takeBaseline(app: *App) void {
    var store = &(if (app.snap) |*s| s else return).*;
    // No early return on a clean tree. The baseline is what gives the
    // first turn a parent to be diffed from, and without one it opens
    // empty - which is what a clean start used to do.
    const paths = snapshotPaths(app) orelse return;
    defer git.freePaths(app.gpa, paths);
    _ = store.baseline(paths);
}

/// Picks the mark up again after a restart, once there are files to attach
/// it to. Silent either way: a mark that could not be restored leaves the
/// session in the state it would have started in regardless.
pub fn restoreMark(app: *App) void {
    if (app.turns.mark_restored) return;
    app.turns.mark_restored = true;
    const store = if (app.snap) |*s| s else return;
    var buf: [128]u8 = undefined;
    const ref = store.reviewedRef(&buf) orelse return;
    app.review.restoreMark(ref, store.state.reviewed_turn);
}

/// Walks the changes that arrived since the mark, across the whole review.
///
/// By row rather than by hunk. What the reader came back for is the twelve
/// lines that answer the last comment, and a hunk that happens to contain
/// one of them is a coarser answer than the line itself - which is the
/// same reason `]h` exists separately rather than this replacing it.
pub fn freshStep(app: *App, delta: i32) !void {
    if (!app.review.mark_at.taken()) {
        var key: [32]u8 = undefined;
        app.notice.set("no mark yet - {s} sets one", .{
            keytext.firstKeyFor(app.km.bindings, .mark_here, .normal, &key),
        });
        return;
    }
    if (app.review.freshCount() == 0) {
        app.notice.set("nothing new since the mark", .{});
        return;
    }

    if (freshFrom(app, app.vp.cursor, delta)) |row| {
        app.moveTo(row);
        return;
    }

    // Nothing further this way in this file. A review is a ring, and the
    // ring is the whole review: the change the reader is looking for is
    // as likely to be in the next file as in this one.
    const count = app.files().len;
    if (count > 1) {
        var tries: usize = 0;
        while (tries < count) : (tries += 1) {
            try walks.stepFile(app, delta);
            if (freshEdge(app, delta)) |row| {
                app.moveTo(row);
                return;
            }
        }
        return;
    }
    if (freshEdge(app, delta)) |row| {
        walks.noteWrap(app, delta, "change");
        app.moveTo(row);
    }
}

/// Remembers what `;` should repeat.
///
/// Set here, on the key the reader actually pressed, and not inside `run`:
/// `,` dispatches the opposite command, and updating the memory there would
/// make a second `,` turn round and come back. `,` means "again, the other
/// way", not "reverse each time".
///
/// A fresh `f` or `t` clears it, so `;` goes back to meaning what vim
/// readers expect the moment they use the motion vim attaches it to.
pub fn rememberWalk(app: *App, cmd: keymap.Command) void {
    switch (cmd) {
        .find_repeat, .find_reverse => {},
        // `*` establishes a search; what `;` repeats is stepping it, not
        // picking up whatever word the cursor has since landed on.
        .search_word => app.last_walk = .search_next,
        .search_word_back => app.last_walk = .search_prev,
        .find_char, .till_char, .find_char_back, .till_char_back => app.last_walk = null,
        else => if (cmd.opposite() != null) {
            app.last_walk = cmd;
        },
    }
}

/// The next row after `from` whose line changed since the mark.
pub fn freshFrom(app: *App, from: u32, delta: i32) ?u32 {
    return scanFresh(app, @as(i64, from) + delta, delta);
}

/// The first such row from whichever end `delta` enters the file by.
pub fn freshEdge(app: *App, delta: i32) ?u32 {
    return scanFresh(app, if (delta > 0) 0 else @as(i64, app.rows.len()) - 1, delta);
}

pub fn scanFresh(app: *App, start: i64, delta: i32) ?u32 {
    const fresh = app.review.freshFor(app.file_index);
    if (fresh.len == 0) return null;
    var i = start;
    while (i >= 0 and i < app.rows.len()) : (i += delta) {
        const row: u32 = @intCast(i);
        const li = app.lineAt(row) orelse continue;
        if (li < fresh.len and fresh[li]) return row;
    }
    return null;
}

/// Marks rows of the fixture's two files as changed since the mark, the way a
/// re-diff would. Set directly rather than through `Review.mark`, which needs
/// git and real buffers: what these tests own is the walking, and
/// `core/checkpoint.zig` owns deciding what is fresh.
fn markFresh(fx: *app_mod.Fixture, first: []const bool, second: []const bool) !void {
    const arena = fx.app.review.allocator();
    const out = try arena.alloc([]bool, 2);
    out[0] = try arena.dupe(bool, first);
    out[1] = try arena.dupe(bool, second);
    fx.app.review.fresh = out;
    fx.app.review.mark_at.turn = 1;
}

const testing = std.testing;
const app_mod = @import("app.zig");

test "the fold keeps the newest, the mark, the baseline and where you are" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    // A long session: turn 40 is newest, the mark has stood since turn 3, and
    // the reader is parked in turn 17.
    fx.app.review.viewing = 17;
    const marked: u32 = 3;

    // Index 0 is the newest turn, so the first `turns_shown` survive on
    // distance alone.
    try testing.expect(turnKept(&fx.app, 40, 0, 40, marked));
    try testing.expect(turnKept(&fx.app, 33, 7, 40, marked));
    try testing.expect(!turnKept(&fx.app, 32, 8, 40, marked));

    // The three that survive wherever they fall.
    try testing.expect(turnKept(&fx.app, marked, 37, 40, marked));
    try testing.expect(turnKept(&fx.app, 0, 40, 40, marked));
    try testing.expect(turnKept(&fx.app, 17, 23, 40, marked));

    // And an ordinary middle turn does not.
    try testing.expect(!turnKept(&fx.app, 18, 22, 40, marked));
}

test "a run is folded only when every turn in it is unremarkable" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    fx.app.review.viewing = null;

    const a: timeline.Turn = .{ .number = 4, .files = 1, .path = "src/ui/app.zig" };
    const b: timeline.Turn = .{ .number = 3, .files = 1, .path = "src/ui/app.zig" };
    try testing.expect(runsWith(&fx.app, a, b, 0));

    // A different file is a different piece of work.
    const other: timeline.Turn = .{ .number = 3, .files = 1, .path = "src/ui/body.zig" };
    try testing.expect(!runsWith(&fx.app, a, other, 0));

    // Six things stop a fold, each because the row has something of its own
    // to say and folding it away would hide exactly what it was drawn for.
    const marked: timeline.Turn = .{ .number = 3, .files = 1, .path = "src/ui/app.zig" };
    try testing.expect(!runsWith(&fx.app, a, marked, 3));

    var reverted = b;
    reverted.reverted = true;
    try testing.expect(!runsWith(&fx.app, a, reverted, 0));

    var answered = b;
    answered.answered = true;
    try testing.expect(!runsWith(&fx.app, a, answered, 0));

    var quiet = b;
    quiet.files = 0;
    try testing.expect(!runsWith(&fx.app, a, quiet, 0));

    var baseline = b;
    baseline.number = 0;
    try testing.expect(!runsWith(&fx.app, a, baseline, 0));

    fx.app.review.viewing = 3;
    try testing.expect(!runsWith(&fx.app, a, b, 0));
    fx.app.review.viewing = null;

    // And expanding stops every fold, which is what opening one means.
    fx.app.turns.expanded = true;
    try testing.expect(!runsWith(&fx.app, a, b, 0));
}

test "elision is by distance, not by read state" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    fx.app.review.viewing = null;

    // The failure `SNAPSHOTS.md` 5.3b's own rule has: a mark that has stood
    // all morning leaves every turn unread, so a fold keyed on read state
    // fires on nothing at all. Distance folds the middle regardless.
    try testing.expect(!turnKept(&fx.app, 20, 20, 900, 1));

    // Expanding shows everything, which is what opening the `⋮` row does.
    fx.app.turns.expanded = true;
    try testing.expect(turnKept(&fx.app, 20, 20, 900, 1));
}

test "restore refuses when there is no turn to restore from" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    // The working tree is not a version of anything: there is nothing to
    // restore *from*, and the message says which key finds one.
    try fx.press("R");
    try fx.expectNotice("nothing to restore from");
    try testing.expect(fx.app.turns.pending == null);
}

test "an unconfirmed restore writes nothing, and any key but y is no" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    // Set up the question directly: reaching it needs a snapshot store, and
    // what is asserted here is the answer, not how it was asked.
    var ask: @TypeOf(fx.app.turns.pending.?) = .{ .turn = 2 };
    const path = "a.zig";
    @memcpy(ask.path[0..path.len], path);
    ask.path_len = path.len;
    fx.app.turns.pending = ask;

    // `n`, but the rule is broader: the safe reading of an ambiguous key is
    // the one that does not write, so only `y` proceeds.
    try fx.app.handle(.{ .key = .{ .codepoint = 'n', .mods = .{} } }, app_mod.body_rows);
    try fx.expectNotice("cancelled");
    try testing.expect(fx.app.turns.pending == null);

    // And a pending question owns the next key outright - `j` answers it
    // rather than moving the cursor.
    fx.app.turns.pending = ask;
    const before = fx.app.vp.cursor;
    try fx.app.handle(.{ .key = .{ .codepoint = 'j', .mods = .{} } }, app_mod.body_rows);
    try testing.expectEqual(before, fx.app.vp.cursor);
    try testing.expect(fx.app.turns.pending == null);
}

test "confirming without a store refuses rather than writing unrecoverably" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    var ask: @TypeOf(fx.app.turns.pending.?) = .{ .turn = 1 };
    const path = "a.zig";
    @memcpy(ask.path[0..path.len], path);
    ask.path_len = path.len;
    fx.app.turns.pending = ask;

    // No snapshot store, so the pre-restore state could not be recorded. That
    // is a reason to refuse: without it this would be the only unrecoverable
    // action in the tool.
    try fx.app.handle(.{ .key = .{ .codepoint = 'y', .mods = .{} } }, app_mod.body_rows);
    try fx.expectNotice("could not snapshot first");
    try testing.expect(fx.app.turns.pending == null);
}

test "undo refuses once something else has changed the file" {
    // The guard that makes `u` an undo rather than an overwrite. If the agent
    // wrote to the file after the restore, putting the old bytes back is not
    // undoing the reader's action - it is discarding the agent's.
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    var last: @TypeOf(fx.app.turns.last.?) = .{ .turn = 2 };
    const path = "docs/GUIDE.md"; // a file that exists, with content we know
    @memcpy(last.path[0..path.len], path);
    last.path_len = path.len;
    // A hash the file cannot have: whatever is on disk, it is not this.
    last.wrote = 0xdead_beef_dead_beef;
    fx.app.turns.last = last;

    try fx.press("u");
    try fx.expectNotice("has changed since");
    // And it forgets, rather than leaving a key armed that will refuse again.
    try testing.expect(fx.app.turns.last == null);
}

test "undo is one step: after it there is nothing left to undo" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    var last: @TypeOf(fx.app.turns.last.?) = .{ .turn = 1 };
    const path = "a.zig";
    @memcpy(last.path[0..path.len], path);
    last.path_len = path.len;
    fx.app.turns.last = last;

    // No store, so this cannot get as far as writing - but it must still
    // clear or keep the memory deliberately rather than by accident. Here the
    // file does not exist, so the hash check is what stops it.
    try fx.press("u");
    try testing.expect(fx.app.turns.last == null);
}

test "walking the changes since the mark needs a mark first" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("]m");
    try fx.expectNotice("no mark");
    try fx.expectCursor(1);
}

test "a mark with nothing after it says so rather than moving" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("m");
    try fx.expectNotice("marked");
    try fx.press("]m");
    try fx.expectNotice("nothing new");
}

test "]n walks to the changed line, not to its hunk" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    // Row 0 is the hunk header; rows 1..3 are the three lines.
    try markFresh(fx, &.{ false, true, false }, &.{ false, false, false });

    try fx.expectCursor(1);
    try fx.press("]m");
    try fx.expectCursor(2);
}

test "]n crosses into the next file when this one has nothing left" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    try markFresh(fx, &.{ false, false, false }, &.{ true, false, false });

    try fx.expectFile(0);
    try fx.press("]m");
    try fx.expectFile(1);
    try fx.expectCursor(1);
}

test "[n walks backwards and reaches the same rows" {
    var fx = try app_mod.Fixture.init(testing.allocator);
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
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    try markFresh(fx, &.{ false, true, false }, &.{ false, false, false });
    try testing.expectEqual(@as(u32, 1), fx.app.review.freshCount());

    // Marking again with no buffers behind the fixture's files records them as
    // empty, which is the honest answer: nothing is newer than now.
    try fx.press("m");
    try testing.expectEqual(@as(u32, 0), fx.app.review.freshCount());
}

test "M drops the mark and the whole change reads as one again" {
    var fx = try app_mod.Fixture.init(testing.allocator);
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
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    try fx.press("M");
    try fx.expectNotice("no mark to drop");
}

test ":nomark drops it too, the way :noh drops the search" {
    var fx = try app_mod.Fixture.init(testing.allocator);
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
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    var chords: [keymap.Keymap.max_sequence]keymap.Chord = undefined;
    const moved = [_]keymap.Binding{
        .{ .chords = try keytext.parseChords("gm", &chords), .command = .mark_here },
    };
    fx.app.km.bindings = &moved;

    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("gm", keytext.firstKeyFor(fx.app.km.bindings, .mark_here, .normal, &buf));

    try fx.app.handle(.{ .key = .{ .codepoint = 'g', .mods = .{} } }, app_mod.body_rows);
    try fx.app.handle(.{ .key = .{ .codepoint = 'm', .mods = .{} } }, app_mod.body_rows);
    try fx.expectNotice("marked");
}

test "walking turns says why when there are none to walk" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    // No store: the fixture has no environment to run git in, which is the
    // same state a directory git does not own is in.
    try fx.press("[t");
    try fx.expectNotice("snapshots are off");
    try testing.expect(fx.app.review.viewing == null);
}

test "a turn is read only, and the refusal names the way back" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    fx.app.review.showTurn(4, "refs/lgtm/s1/4", "refs/lgtm/s1/3");

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
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    fx.app.review.showTurn(2, "refs/lgtm/s1/2", "refs/lgtm/s1/1");

    // A re-diff here would throw the reader back to the present mid-sentence.
    // The event still has to free what it owns, which is why this is a return
    // rather than a branch around the whole arm.
    const paths = try testing.allocator.alloc([]const u8, 1);
    paths[0] = try testing.allocator.dupe(u8, "a.zig");
    try fx.app.handle(.{ .files_changed = paths }, app_mod.body_rows);
    try testing.expectEqual(@as(u32, 2), fx.app.review.viewing.?);
}

test "showing a turn and returning are the two states, and nothing between" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    try testing.expect(fx.app.review.viewRef() == null);
    fx.app.review.showTurn(7, "refs/lgtm/s1/7", "refs/lgtm/s1/6");
    try testing.expectEqualStrings("refs/lgtm/s1/7", fx.app.review.viewRef().?);
    try testing.expectEqual(@as(u32, 7), fx.app.review.viewing.?);

    fx.app.review.showWorking();
    try testing.expect(fx.app.review.viewRef() == null);
    try testing.expect(fx.app.review.viewing == null);
}

test "the turn list says why when there is nothing to list" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    // No store, which is the state a directory git does not own is in.
    try fx.press("<Space>lt");
    try fx.expectNotice("snapshots are off");
    try fx.expectMode(.normal);
}

test "undo has nothing to undo until a restore happens" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    try fx.press("u");
    try fx.expectNotice("nothing to undo");
}
