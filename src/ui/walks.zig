// SPDX-License-Identifier: Apache-2.0
//
// Every `]x` / `[x` pair. One shape repeated: take the cursor and the rows,
// return a row to land on. Only the predicate differs.

const std = @import("std");

const app_mod = @import("app.zig");
const App = app_mod.App;
const notes = @import("notes.zig");
const motion = @import("motion.zig");
const search = @import("search.zig");

/// One search step across the whole review, not just the current file: a
/// reviewer who types `/token` means anywhere in the change. Files other
/// than the current one have no rows built, so the scan runs over their
/// `DiffLines` and only the file that hits gets laid out.
pub fn searchStep(app: *App, dir: search.Direction) !void {
    const pat = app.finder.pattern();
    if (pat.empty()) {
        app.notice.set("no previous search", .{});
        return;
    }
    const fs = app.files();
    if (fs.len == 0) return;

    app.finder.wrapped = false;
    app.finder.failed = false;
    // `n` after `:noh` paints again, which is what vim does: the reader
    // asked to be shown the next one.
    app.finder.show();

    const start_file = app.file_index;
    var fi: u32 = start_file;
    var from: ?u32 = app.lineAt(app.vp.cursor);
    var wrapped = false;

    var step: usize = 0;
    while (step <= fs.len) : (step += 1) {
        if (search.findLine(fs[fi].lines, from, dir, pat)) |hit| {
            if (fi != app.file_index) {
                app.file_index = fi;
                try app.rebuildRows(.reset);
            }
            if (app.rows.rowForLine(hit.line)) |row| {
                app.moveTo(row);
                // After `moveTo`, which sets the column from `want_col`:
                // the match is where the reader is going, so it becomes
                // the desired column too, the way vim's `n` does. Without
                // this the cursor lands on the right line at the wrong
                // end of it, and on a long line that reads as a miss.
                app.setCol(motion.clamp(app.cursorText(), hit.col));
            }
            app.finder.wrapped = wrapped;
            if (wrapped) app.notice.set("search wrapped", .{});
            return;
        }
        // Step to the neighbouring file, noting when that crossed the end
        // of the review - which is the only thing that counts as a wrap.
        const next = app_mod.wrapIndex(@as(i64, @intCast(fi)) + dir.delta(), fs.len);
        fi = next.index;
        wrapped = wrapped or next.wrapped;
        // A file entered from outside has no cursor to start after.
        from = null;
    }

    app.finder.failed = true;
    app.notice.set("pattern not found: {s}", .{pat.text});
}

/// `]c` / `[c`: the next note anywhere in the review, the way `]h` walks
/// hunks. Notes are why the tool exists; stopping at a file boundary would
/// leave the key unable to reach most of them.
pub fn commentStep(app: *App, delta: i32, body: u16) void {
    if (app.comments.len() == 0) {
        notes.noComments(app);
        return;
    }

    // Every comment, not only the ones on files the review contains. A
    // comment outlives the change it was written against - the agent
    // reverts something, the hunk goes, the remark stays - and a walk that
    // could not reach those was a walk that hid them.
    const here = notes.spotHere(app);
    var best: ?App.Spot = null;
    for (app.comments.items()) |n| {
        const at = notes.spotOf(app, n);
        const after = notes.lessSpot(here, at);
        const before_it = notes.lessSpot(at, here);
        if (delta > 0 and !after) continue;
        if (delta < 0 and !before_it) continue;
        if (best) |b| {
            const closer = if (delta > 0) notes.lessSpot(at, b) else notes.lessSpot(b, at);
            if (!closer) continue;
        }
        best = at;
    }

    // Nothing further that way, so come round - a review is a ring, and
    // `]h` and `]f` already read that way.
    const target = best orelse blk: {
        var edge: ?App.Spot = null;
        for (app.comments.items()) |n| {
            const at = notes.spotOf(app, n);
            if (edge) |e| {
                const further = if (delta > 0) notes.lessSpot(at, e) else notes.lessSpot(e, at);
                if (!further) continue;
            }
            edge = at;
        }
        const e = edge orelse return;
        app.notice.set("wrapped to the {s} comment", .{if (delta > 0) "first" else "last"});
        break :blk e;
    };

    var path_buf: [4096]u8 = undefined;
    @memcpy(path_buf[0..target.path.len], target.path);
    showComment(app, path_buf[0..target.path.len], target.line, body) catch return;
}

/// Walks the weakened tests, across the whole review.
///
/// The same walk `]m` does over a different set of rows. It exists because
/// the status line can say "1 test removed" and then leave the reader to
/// find it, which on a large change is the difference between a warning
/// and a rumour.
pub fn riskStep(app: *App, delta: i32) !void {
    if (!app.review.risk_total.any()) {
        app.notice.set("no weakened tests in this change", .{});
        return;
    }
    if (!app.review.risk_total.certain()) {
        // Only `fewer_asserts`, which is a property of a file rather than
        // a place: there is no row that *is* the finding.
        app.notice.set("fewer assertions than before, but no test removed or skipped", .{});
        return;
    }

    if (riskFrom(app, app.vp.cursor, delta)) |row| {
        app.moveTo(row);
        return;
    }
    const count = app.files().len;
    if (count > 1) {
        var tries: usize = 0;
        while (tries < count) : (tries += 1) {
            try stepFile(app, delta);
            if (riskEdge(app, delta)) |row| {
                app.moveTo(row);
                return;
            }
        }
        return;
    }
    if (riskEdge(app, delta)) |row| {
        noteWrap(app, delta, "weakened test");
        app.moveTo(row);
    }
}

pub fn riskFrom(app: *App, from: u32, delta: i32) ?u32 {
    return scanRiskRows(app, @as(i64, from) + delta, delta);
}

pub fn riskEdge(app: *App, delta: i32) ?u32 {
    return scanRiskRows(app, if (delta > 0) 0 else @as(i64, app.rows.len()) - 1, delta);
}

pub fn scanRiskRows(app: *App, start: i64, delta: i32) ?u32 {
    const marks = app.review.riskRowsFor(app.file_index);
    if (marks.len == 0) return null;
    var i = start;
    while (i >= 0 and i < app.rows.len()) : (i += delta) {
        const row: u32 = @intCast(i);
        const li = app.lineAt(row) orelse continue;
        if (li < marks.len and marks[li]) return row;
    }
    return null;
}

/// Whether a row is a break: `{` and `}` land on these.
///
/// Two kinds, and the pair is the point. A **blank line of code**, which is
/// what `{` and `}` mean everywhere else and what a reader reaches for
/// without thinking. And **chrome** - a hunk header, the rule between two
/// hunks, a summarised file - because those are gaps the eye already stops
/// at, and a paragraph motion that walked straight past a visible break in
/// the page would read as broken.
///
/// A note is not one. It hangs *under* the line it belongs to and is part
/// of reading that line, not a gap between two.
pub fn isBreak(app: *App, row: u32) bool {
    if (row >= app.rows.len()) return false;
    if (app.rows.items[row] == .note) return false;
    const li = app.lineAt(row) orelse return true;
    const f = app.current() orelse return false;
    if (li >= f.lines.text.len) return false;
    return std.mem.trim(u8, f.lines.text[li], " \t\r").len == 0;
}

/// `}` and `{`.
///
/// **A run of breaks is one break.** Two blank lines between functions is
/// one gap, not two, and a hunk header sitting against the rule above it
/// is one edge - vim separates paragraphs by "one or more" blank lines for
/// the same reason, and a motion that stopped twice in the same gap would
/// need pressing twice to cross it.
///
/// No wrap, unlike `]h` and `]f`. vim's paragraph motions stop at the ends
/// of the buffer and a reader who knows them knows that; one that silently
/// returned to the top would be a different key wearing the same glyph.
/// Stopping means landing on the last row rather than refusing, which is
/// also what vim does.
pub fn stepBreak(app: *App, delta: i32) void {
    const n = app.rows.len();
    if (n == 0) return;
    const last = n - 1;
    const back = delta < 0;

    var row = app.vp.cursor;
    // Out of the gap the cursor is already standing in, so `}` pressed
    // twice crosses two gaps rather than the two halves of one.
    while (isBreak(app, row)) {
        if (back) {
            if (row == 0) return landOn(app, app.rows.firstLineRow());
            row -= 1;
        } else {
            if (row >= last) return landOn(app, last);
            row += 1;
        }
    }
    // Then to the near edge of the next one.
    while (true) {
        if (back) {
            if (row == 0) return landOn(app, app.rows.firstLineRow());
            row -= 1;
        } else {
            if (row >= last) return landOn(app, last);
            row += 1;
        }
        if (isBreak(app, row)) return landOn(app, row);
    }
}

/// Arrive at a row the way a jump does: the column resets to the start of
/// the line, which is what every paragraph motion does and what makes two
/// `}` in a row read as one movement rather than two.
pub fn landOn(app: *App, row: u32) void {
    app.want_col = 0;
    app.moveTo(row);
}

pub fn stepHunk(app: *App, delta: i32) !void {
    const hs = app.rows.hunk_rows;
    if (hs.len == 0) return;

    // By hunk *index*, not by row. Stepping by row cannot go backwards at
    // all: the cursor always lands on `header + 1`, and the nearest header
    // strictly above that row is the very one it just landed on, so `[h`
    // returned to where it already was and the backward wrap was
    // unreachable.
    const n: i64 = @intCast(hs.len);
    const here: ?u32 = app.rows.hunkAt(app.vp.cursor);
    const raw: i64 = if (here) |h|
        @as(i64, @intCast(h)) + delta
    else
        // Above the first header, `]h` means the first hunk rather than
        // the second, and `[h` means the last.
        (if (delta > 0) 0 else n - 1);

    // Still inside this file: the common case, and no file work at all.
    if (raw >= 0 and raw < n) {
        app.moveTo(hs[@intCast(raw)] + 1);
        return;
    }

    // Off the end of the file's hunks.
    if (app.nav.hunk_crosses_files and try crossToHunk(app, delta)) return;

    const target = hs[app_mod.wrapIndex(raw, hs.len).index] + 1;
    // One hunk wraps onto itself; saying so every time would be noise.
    if (target != app.vp.cursor) noteWrap(app, delta, "hunk");
    app.moveTo(target);
}

/// Carries `]h` into the next file's first hunk, or `[h` into the previous
/// file's last one. Returns false when there is nowhere to go, leaving the
/// caller to wrap inside this file instead.
///
/// Skips files that contribute no hunk rows - a summarised file has none -
/// rather than parking the cursor somewhere `]h` cannot leave. Bounded by
/// the file count, so a review of nothing but such files terminates.
pub fn crossToHunk(app: *App, delta: i32) !bool {
    const count = app.files().len;
    if (count <= 1) return false;

    var tries: usize = 0;
    while (tries < count) : (tries += 1) {
        // `stepFile` wraps across the review and announces it, which is
        // exactly the right message at the true end of the last file.
        try stepFile(app, delta);
        const hs = app.rows.hunk_rows;
        if (hs.len == 0) continue;
        app.moveTo(if (delta > 0) hs[0] + 1 else hs[hs.len - 1] + 1);
        return true;
    }
    return false;
}

/// Wraps: `]f` from the last file lands on the first, `[f` from the first
/// lands on the last. A review is a ring, and stopping dead at the end
/// reads as a dropped keystroke. Announced for the same reason the search
/// announces its wrap - the file under you changed further than one step.
pub fn stepFile(app: *App, delta: i32) !void {
    const n = app.files().len;
    if (n == 0) return;
    const step = app_mod.wrapIndex(@as(i64, app.file_index) + delta, n);
    if (step.index == app.file_index) return;
    if (step.wrapped) noteWrap(app, delta, "file");
    app.file_index = step.index;
    try app.rebuildRows(.reset);
}

/// Both ring motions say the same thing when they come round: the cursor
/// moved further than one step and nothing else on screen would show it.
pub fn noteWrap(app: *App, delta: i32, what: []const u8) void {
    app.notice.set("wrapped to {s} {s}", .{ if (delta > 0) "first" else "last", what });
}

/// Puts the cursor on the row carrying a given new-file line, and says
/// whether there was one.
///
/// There often is not. The diff draws hunks, not files, so a line the
/// reader commented on can stop being drawn when the change around it is
/// reverted or re-shaped - the comment is still perfectly valid, and the
/// row it used to sit on is gone.
pub fn gotoNewLine(app: *App, line: u32) bool {
    const f = app.current() orelse return false;
    var row: u32 = 0;
    while (row < app.rows.len()) : (row += 1) {
        const li = app.lineAt(row) orelse continue;
        if (li < f.lines.len() and f.lines.new_no[li] == line) {
            app.moveTo(row);
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
pub fn showComment(app: *App, path: []const u8, line: u32, body: u16) !void {
    for (app.review.files(), 0..) |f, fi| {
        if (!std.mem.eql(u8, f.path(), path)) continue;
        app.clearPreview();
        if (fi != app.file_index) {
            app.file_index = @intCast(fi);
            try app.rebuildRows(.reset);
        }
        if (gotoNewLine(app, line)) {
            app.clampScroll(body);
            return;
        }
        break;
    }
    // Not in the review, or in it but no longer drawn: read the file.
    var buf: [4096]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}", .{path}) catch path;
    try app.openPreview(p);
    if (app.preview == null) {
        // The file itself has gone - renamed, deleted, or never on this
        // branch. That is exactly what stale means, so the comment says so
        // rather than being lost or silently pointing at nothing. It stays
        // in the list, where `<C-d>` can clear it out (rule 7: the reader
        // decides when a remark stops mattering, not the tool).
        if (app.comments.at(path, line)) |n| {
            if (n.state != .stale) {
                n.state = .stale;
                app.comments.dirty = true;
                notes.saveComments(app);
            }
        }
        var key: [32]u8 = undefined;
        app.notice.set("{s} is gone - comment marked stale, {s} in the list deletes it", .{
            path, app.keyFor(.comment_drop, .finder, &key),
        });
        return;
    }
    _ = gotoNewLine(app, line);
    app.clampScroll(body);
    app.notice.set("{s}:{d} - not in the diff, showing the file", .{ path, line });
}

/// Where the cursor goes after a hunk's context is folded away. Its line
/// is the first answer and is often gone with the fold, so the hunk it was
/// reading is the second - never the row index it happened to hold, which
/// after the fold belongs to a line further down the file.
pub fn foldedTo(app: *App, hi: u32, body: u16) !void {
    const line = app.cursorLine();
    try app.rebuildRows(.row);
    const f = app.current() orelse return;
    if (line != 0) {
        if (app.rowForFileLine(f, line)) |r| {
            app.vp.cursor = r;
            app.clampScroll(body);
            app.placeCursor();
            return;
        }
    }
    if (hi < app.rows.hunk_rows.len) {
        app.vp.cursor = @min(app.rows.hunk_rows[hi] + 1, app.rows.len() -| 1);
    }
    app.clampScroll(body);
    app.placeCursor();
}

const testing = std.testing;
const keymap = @import("keymap.zig");

test "a ring step wraps at both ends and reports only the wrap" {
    // The shared arithmetic behind `]f`, `]h` and the search's walk across
    // files. Each of the three had its own copy, and the backward one is the
    // half that is easy to get wrong: `@rem` leaves it negative.
    try testing.expectEqual(@as(u32, 1), app_mod.wrapIndex(1, 3).index);
    try testing.expect(!app_mod.wrapIndex(1, 3).wrapped);

    try testing.expectEqual(@as(u32, 0), app_mod.wrapIndex(3, 3).index);
    try testing.expect(app_mod.wrapIndex(3, 3).wrapped);

    try testing.expectEqual(@as(u32, 2), app_mod.wrapIndex(-1, 3).index);
    try testing.expect(app_mod.wrapIndex(-1, 3).wrapped);

    // An empty ring has nowhere to step to, and must not divide by zero.
    try testing.expectEqual(@as(u32, 0), app_mod.wrapIndex(-1, 0).index);
    try testing.expect(!app_mod.wrapIndex(-1, 0).wrapped);
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

test "hunk stepping crosses into the next file by default" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    try testing.expect(fx.app.nav.hunk_crosses_files);
    try testing.expect(fx.app.files().len > 1);

    // To the last hunk of the first file.
    while (fx.app.rows.hunkAt(fx.app.vp.cursor).? + 1 < fx.app.rows.hunk_rows.len) {
        try fx.press("]h");
    }
    try fx.expectFile(0);

    // One more leaves the file rather than looping inside it.
    try fx.press("]h");
    try fx.expectFile(1);
    try testing.expectEqual(fx.app.rows.hunk_rows[0] + 1, fx.app.vp.cursor);
    // Crossing a boundary mid-review is not a wrap and must not claim to be.
    try fx.expectNoNotice();

    // Backwards over the same boundary returns to the *last* hunk of file 0.
    try fx.press("[h");
    try fx.expectFile(0);
    const hs = fx.app.rows.hunk_rows;
    try testing.expectEqual(hs[hs.len - 1] + 1, fx.app.vp.cursor);
}

test "the whole review wraps at its far end, and says so" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    // `[h` from the very first hunk of the first file has nowhere earlier to
    // go, so it wraps round to the last file - which `stepFile` announces.
    try fx.expectFile(0);
    try fx.press("[h");
    try testing.expectEqual(@as(u32, @intCast(fx.app.files().len - 1)), fx.app.file_index);
    try fx.expectNotice("wrapped to last file");
}

test "hunk stepping stays in the file when config says so" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    // The flag a config file will set once `config.zig` lands.
    fx.app.nav.hunk_crosses_files = false;

    const in_file = fx.app.rows.hunk_rows.len;
    while (fx.app.rows.hunkAt(fx.app.vp.cursor).? + 1 < in_file) {
        try fx.press("]h");
    }

    try fx.press("]h");
    // Same file, back at its first hunk.
    try fx.expectFile(0);
    try testing.expectEqual(fx.app.rows.hunk_rows[0] + 1, fx.app.vp.cursor);
    if (in_file > 1) {
        try fx.expectNotice("wrapped to first hunk");
    }
}

test "prev hunk steps back a hunk rather than to the top of this one" {
    // The regression this guards: stepping by *row* could never go backwards.
    // The cursor always lands on `header + 1`, and the nearest header strictly
    // above that row is the one it just landed on, so `[h` returned to where
    // it already was - and the backward wrap could never be reached.
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    const hunks = fx.app.rows.hunk_rows.len;
    if (hunks < 2) return; // nothing to step between

    try fx.press("]h");
    const second = fx.app.vp.cursor;
    try testing.expectEqual(fx.app.rows.hunk_rows[1] + 1, second);

    try fx.press("[h");
    try testing.expect(fx.app.vp.cursor != second);
    try testing.expectEqual(fx.app.rows.hunk_rows[0] + 1, fx.app.vp.cursor);
}

test "file stepping wraps at both ends, and says so" {
    var fx = try app_mod.Fixture.init(testing.allocator);
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
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    const start = fx.app.vp.cursor;
    for ([_][2][]const u8{
        .{ "<Space>nh", "]h" },
        .{ "<Space>ph", "[h" },
    }) |pair| {
        fx.app.vp.cursor = start;
        try fx.press(pair[0]);
        const by_leader = fx.app.vp.cursor;

        fx.app.vp.cursor = start;
        try fx.press(pair[1]);
        try testing.expectEqual(by_leader, fx.app.vp.cursor);
    }

    try fx.press("<Space>nf");
    try fx.expectFile(1);
    try fx.press("<Space>pf");
    try fx.expectFile(0);
}

test "every walk has an opposite, or ',' would be a dead key on it" {
    // A family that answers `opposite` is one `;` will repeat, so it must also
    // be one `,` can reverse. A new `]x` added without its pair would repeat
    // forwards and do nothing backwards, which is the kind of half-binding
    // nobody notices until they press it.
    const ring = [_]keymap.Command{
        .next_hunk,    .prev_hunk,    .next_file,  .prev_file,
        .next_comment, .prev_comment, .next_fresh, .prev_fresh,
        .next_risk,    .prev_risk,    .next_turn,  .prev_turn,
        .search_next,  .search_prev,
    };
    for (ring) |w| {
        const back = w.opposite() orelse return error.TestExpectedOpposite;
        try testing.expectEqual(w, back.opposite().?);
    }
}
