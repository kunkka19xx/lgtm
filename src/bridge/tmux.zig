// SPDX-License-Identifier: Apache-2.0
//
// The tmux backend: argv construction and output parsing, both pure, plus the
// two calls that spawn `tmux` through the io/ quarantine.
//
// Written the way `ui/editor.zig` is written, and for the same reason: the
// part that can be wrong is the argv, so the argv is built by a function that
// spawns nothing and can be asserted on. `send-keys -l` is the whole of the
// correctness argument - without `-l` tmux resolves key *names*, so a payload
// containing the word `Enter` would press Enter, which is the failure hard
// rule 2 exists to prevent.

const std = @import("std");
const Allocator = std.mem.Allocator;

const proc = @import("../io/proc.zig");

/// Pane ids are `%` followed by a small integer. Held inline rather than
/// allocated: the target outlives every arena it could have come from, and 24
/// bytes is cheaper than a lifetime.
pub const max_pane_id = 24;

/// The sigil every pane id starts with. Both the listing parser here and the
/// saved-target validator in `bridge.zig` reject an id without it.
pub const pane_sigil = '%';

/// `send-keys` prints nothing on success and one short line on failure, so the
/// cap exists only to bound a tmux that has gone wrong.
const send_output_max = 4 << 10;

/// `list-panes` prints one short line per pane. 64 KB is thousands of them,
/// which is far past any real window.
const list_output_max = 64 << 10;

pub const Pane = struct {
    id: []const u8,
    /// `#{pane_current_command}` - what is running there, which is the only
    /// thing that tells a user which pane is their agent.
    command: []const u8,
    active: bool,
    /// `session:window.pane`, for the picker. Two agents running the same
    /// binary have the same `command` and nothing else to tell them apart;
    /// where they are is the first thing that does.
    where: []const u8 = "",
    /// The session name alone, which is `where` up to its ':'. Split here
    /// rather than by the caller because `session:window.pane` is this file's
    /// own format string, and nothing above `bridge/` should have to know it.
    /// The picker groups by it: panes of one session belong together on
    /// screen, whatever each is running.
    session: []const u8 = "",
    /// `#{pane_title}`, which is what most agents write their current task
    /// into - and so the field that makes a list of five identical commands
    /// pickable. Empty when tmux does not give one.
    title: []const u8 = "",
};

/// `tmux send-keys -t <pane> -l -- <text>`.
///
/// `-l` sends the payload literally; `--` stops a payload that begins with a
/// dash from being read as options. The caller has already checked the text
/// against the bridge invariants - nothing here can, and nothing here should
/// have to.
pub fn sendArgv(arena: Allocator, pane: []const u8, text: []const u8) Allocator.Error![]const []const u8 {
    return arena.dupe([]const u8, &.{ "tmux", "send-keys", "-t", pane, "-l", "--", text });
}

/// `-a` lists every pane of every session; without it, the current window.
///
/// Both are used, in that order. The window is the useful default - an agent
/// and its reviewer sit side by side, and widening the search there would
/// count a busy second session and refuse an answer that was next door. But an
/// agent in another *tab* is, in tmux's vocabulary, an agent in another
/// *window*: the near listing then holds only ourselves, and declining with
/// the answer one subprocess away is not declining, it is giving up.
///
/// `soleOther` still refuses past two either way, so the far listing widens
/// what can be found without widening what can be guessed.
pub fn listArgv(arena: Allocator, all_sessions: bool) Allocator.Error![]const []const u8 {
    const format = "#{pane_id}\t#{pane_active}\t#{pane_current_command}" ++
        "\t#{session_name}:#{window_index}.#{pane_index}\t#{pane_title}";
    return if (all_sessions)
        arena.dupe([]const u8, &.{ "tmux", "list-panes", "-a", "-F", format })
    else
        arena.dupe([]const u8, &.{ "tmux", "list-panes", "-F", format });
}

/// One pane per line, tab-separated. A line that does not have the first
/// three fields is skipped rather than failing the listing: a tmux old enough
/// to not know a format variable prints it back verbatim, and losing one pane
/// from a picker is better than losing the picker.
///
/// The last two are optional for the same reason, and they are last so that
/// they can be: a tmux that answers three fields still drives inference, which
/// only ever needed the id. The title takes everything remaining, tabs
/// included, because it is a user's sentence and not a field this wrote.
pub fn parsePanes(arena: Allocator, out: []const u8) Allocator.Error![]Pane {
    var panes: std.ArrayList(Pane) = .empty;
    var lines = std.mem.tokenizeScalar(u8, out, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        var fields = std.mem.splitScalar(u8, line, '\t');
        const id = fields.next() orelse continue;
        const active = fields.next() orelse continue;
        const command = fields.next() orelse continue;
        if (id.len == 0 or id[0] != pane_sigil) continue;
        const where = fields.next() orelse "";
        const title = fields.rest();
        const colon = std.mem.indexOfScalar(u8, where, ':');
        try panes.append(arena, .{
            .id = id,
            .active = std.mem.eql(u8, active, "1"),
            .command = command,
            .where = where,
            .session = if (colon) |n| where[0..n] else where,
            .title = std.mem.trimEnd(u8, title, "\r"),
        });
    }
    return panes.toOwnedSlice(arena);
}

/// A capture of every listed pane, in one subprocess.
///
/// The picker's rows say `%604`, which identifies a pane to tmux and to nobody
/// else. What a reader recognises is what the pane is *showing* - a splash
/// screen, a prompt, an agent halfway through a sentence - so the picker shows
/// them that and the id stops having to carry the whole job.
///
/// One process for all of them, not one each: tmux takes a command sequence,
/// so fifteen panes cost a single fork. Measured at 7 ms for the whole batch,
/// which is why this happens when the picker opens rather than on every
/// keystroke, with no debounce and no second event to wire.
const capture_output_max = 1 << 20;

/// Sections are split on a line the panes cannot be showing. A pane can
/// display any fixed string - including one out of this file, if what it is
/// running is an agent editing this file - so the marker carries a nonce and
/// the split is checked against the number of panes asked for. A capture that
/// does not divide cleanly is dropped whole: a preview of the wrong pane is
/// worse than no preview.
pub fn captureMarker(buf: []u8, io: std.Io) []const u8 {
    const ts = std.Io.Timestamp.now(io, .real).toNanoseconds();
    const nonce: u64 = @truncate(@as(u96, @bitCast(ts)));
    return std.fmt.bufPrint(buf, "@@lgtm-{x}@@", .{nonce}) catch "@@lgtm@@";
}

/// `capture-pane -p -t %A ; display-message -p <marker> ; capture-pane ...`
///
/// A bare `;` is tmux's own command separator, and in an argv there is no
/// shell to quote it away from. The marker follows each capture rather than
/// preceding it, so the split is on what closes a section and the first
/// section needs no special case.
pub fn captureArgv(
    arena: Allocator,
    ids: []const []const u8,
    marker: []const u8,
) Allocator.Error![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, "tmux");
    for (ids, 0..) |id, i| {
        if (i > 0) try argv.append(arena, ";");
        try argv.appendSlice(arena, &.{ "capture-pane", "-p", "-t", id, ";", "display-message", "-p", marker });
    }
    return argv.toOwnedSlice(arena);
}

/// The captured text, one slice per id, or null when the output did not split
/// into exactly that many sections.
///
/// Trailing blank lines go: tmux drops the ones at the very bottom of a pane
/// and keeps the ones above them, so a pane whose last output is halfway up
/// arrives with a tail of nothing. The reader wants the last thing that was
/// said, not the empty rows under it.
pub fn parseCaptures(
    arena: Allocator,
    out: []const u8,
    marker: []const u8,
    n: usize,
) Allocator.Error!?[][]const u8 {
    if (n == 0) return null;
    var caps: std.ArrayList([]const u8) = .empty;
    // Where the current section began, and where the search is - two cursors,
    // because a marker that turned out to be part of a line advances only the
    // second. One cursor let a rejected marker eat the section's own head.
    var at: usize = 0;
    var scan: usize = 0;
    while (std.mem.indexOfPos(u8, out, scan, marker)) |hit| {
        // The marker owns its whole line, so a pane showing it inside another
        // line does not split the capture there.
        const line_start = if (std.mem.lastIndexOfScalar(u8, out[0..hit], '\n')) |nl| nl + 1 else 0;
        const line_end = hit + marker.len;
        scan = line_end;
        if (line_start != hit or (line_end < out.len and out[line_end] != '\n')) continue;
        try caps.append(arena, trimBlankTail(out[at..line_start]));
        at = @min(line_end + 1, out.len);
        scan = at;
    }
    if (caps.items.len != n) return null;
    return try caps.toOwnedSlice(arena);
}

fn trimBlankTail(text: []const u8) []const u8 {
    var end = text.len;
    while (end > 0) {
        const line_start = if (std.mem.lastIndexOfScalar(u8, text[0 .. end - 1], '\n')) |nl| nl + 1 else 0;
        const line = std.mem.trimEnd(u8, text[line_start .. end - 1], " \t\r");
        if (line.len > 0) break;
        end = line_start;
    }
    return text[0..end];
}

pub fn capture(
    gpa: Allocator,
    arena: Allocator,
    io: std.Io,
    ids: []const []const u8,
) SendError!?[][]const u8 {
    if (ids.len == 0) return null;
    var buf: [48]u8 = undefined;
    const marker = captureMarker(&buf, io);
    const argv = try captureArgv(arena, ids, marker);
    const out = proc.run(gpa, io, argv, capture_output_max) catch return error.TmuxFailed;
    defer out.deinit(gpa);
    if (out.exit_code != 0) return error.TmuxFailed;
    return parseCaptures(arena, try arena.dupe(u8, out.stdout), marker, ids.len);
}

/// The target, when there is only one it could be.
///
/// Two panes in a window - the agent and the reviewer reading it - is the
/// setup the tool is named after, and there the answer is unambiguous. Three
/// or more is a guess, and a wrong guess types into someone's editor, so it
/// declines and the caller asks.
pub fn soleOther(panes: []const Pane, self_pane: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (panes) |p| {
        if (self_pane.len > 0 and std.mem.eql(u8, p.id, self_pane)) continue;
        if (found != null) return null;
        found = p.id;
    }
    return found;
}

pub const SendError = error{ PaneGone, TmuxFailed } || Allocator.Error;

/// Runs `send-keys`. A dead pane is the failure worth naming: tmux exits
/// non-zero with "can't find pane", and the caller degrades to the clipboard
/// rather than treating it as fatal.
pub fn send(gpa: Allocator, io: std.Io, pane: []const u8, text: []const u8) SendError!void {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();

    const argv = try sendArgv(scratch.allocator(), pane, text);
    const out = proc.run(gpa, io, argv, send_output_max) catch return error.TmuxFailed;
    defer out.deinit(gpa);
    if (out.exit_code != 0) {
        return if (std.mem.indexOf(u8, out.stderr, "find pane") != null)
            error.PaneGone
        else
            error.TmuxFailed;
    }
}

/// The panes of the current window, or of every session. Caller owns nothing:
/// the panes point into `arena`.
/// `load-buffer -w -`: fills the tmux paste buffer and asks tmux to put the
/// text on the system clipboard as well.
///
/// This exists because the bare OSC 52 does not work under tmux's defaults.
/// `set-clipboard` defaults to `external`, which means tmux will set the
/// terminal clipboard *itself* but ignores an application that tries - and
/// lgtm is the application. Asking tmux to do it is the same operation from
/// the side tmux permits. Measured on tmux 3.7b with the default setting: the
/// escape from a pane sets nothing, this sets both the clipboard and the
/// buffer.
///
/// Two things come free. `prefix + ]` pastes it, which the escape never gave.
/// And this is a command with an exit code, so a failure is knowable rather
/// than reported as a success nobody can check.
///
/// Stdin rather than `set-buffer <data>`, so the payload is never an argv:
/// `Y` copies the lines under a reference and has no business meeting ARG_MAX.
pub fn copyArgv(arena: Allocator) Allocator.Error![]const []const u8 {
    return arena.dupe([]const u8, &.{ "tmux", "load-buffer", "-w", "-" });
}

pub fn copy(gpa: Allocator, io: std.Io, text: []const u8) SendError!void {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();

    const argv = try copyArgv(scratch.allocator());
    const out = proc.runWithInput(gpa, io, argv, text, send_output_max) catch
        return error.TmuxFailed;
    defer out.deinit(gpa);
    // A tmux older than 3.2 has no `-w` and says so. The caller falls back to
    // the escape, which is what that tmux was going to need anyway.
    if (out.exit_code != 0) return error.TmuxFailed;
}

pub fn list(gpa: Allocator, arena: Allocator, io: std.Io, all_sessions: bool) SendError![]Pane {
    const argv = try listArgv(arena, all_sessions);
    const out = proc.run(gpa, io, argv, list_output_max) catch return error.TmuxFailed;
    defer out.deinit(gpa);
    if (out.exit_code != 0) return error.TmuxFailed;
    return parsePanes(arena, try arena.dupe(u8, out.stdout));
}

const testing = std.testing;

test "an agent in another tab is found only by the wider listing" {
    // tmux calls a tab a window. Side by side, the near listing answers.
    const near = [_]Pane{
        .{ .id = "%1", .command = "lgtm", .active = true },
        .{ .id = "%2", .command = "claude", .active = false },
    };
    try testing.expectEqualStrings("%2", soleOther(&near, "%1").?);

    // In another tab, the near listing holds only ourselves and has nothing
    // to offer - which is what makes the second listing worth a subprocess.
    const alone = [_]Pane{.{ .id = "%1", .command = "lgtm", .active = true }};
    try testing.expect(soleOther(&alone, "%1") == null);

    const far = [_]Pane{
        .{ .id = "%1", .command = "lgtm", .active = true },
        .{ .id = "%7", .command = "claude", .active = false },
    };
    try testing.expectEqualStrings("%7", soleOther(&far, "%1").?);

    // And the wider listing is wider, not looser: a machine full of panes is
    // still a machine nobody can guess about.
    const busy = [_]Pane{
        .{ .id = "%1", .command = "lgtm", .active = true },
        .{ .id = "%7", .command = "claude", .active = false },
        .{ .id = "%9", .command = "vim", .active = false },
    };
    try testing.expect(soleOther(&busy, "%1") == null);
}

test "send-keys is literal, and options stop before the payload" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();

    const argv = try sendArgv(a.allocator(), "%3", "#3 src/auth.rs:47 ");
    try testing.expectEqual(@as(usize, 7), argv.len);
    try testing.expectEqualStrings("tmux", argv[0]);
    try testing.expectEqualStrings("send-keys", argv[1]);
    try testing.expectEqualStrings("-t", argv[2]);
    try testing.expectEqualStrings("%3", argv[3]);
    // Without this the word "Enter" in a payload would press Enter.
    try testing.expectEqualStrings("-l", argv[4]);
    try testing.expectEqualStrings("--", argv[5]);
    try testing.expectEqualStrings("#3 src/auth.rs:47 ", argv[6]);
}

test "the clipboard copy asks tmux to do it, and takes the payload on stdin" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();

    const argv = try copyArgv(a.allocator());
    try testing.expectEqualSlices([]const u8, &.{ "tmux", "load-buffer", "-w", "-" }, argv);

    // `-w` is the whole point: without it the text reaches the tmux paste
    // buffer and never the system clipboard, which is the bug this replaced.
    try testing.expect(std.mem.eql(u8, argv[2], "-w"));
    // And `-`, so the payload arrives on stdin rather than as an argv that
    // `Y` could grow past ARG_MAX.
    try testing.expectEqualStrings("-", argv[argv.len - 1]);
}

test "a payload that looks like an option is still the payload" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const argv = try sendArgv(a.allocator(), "%3", "-N");
    try testing.expectEqualStrings("--", argv[argv.len - 2]);
    try testing.expectEqualStrings("-N", argv[argv.len - 1]);
}

test "panes parse into id, command and which one is active" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();

    const panes = try parsePanes(a.allocator(), "%0\t0\tclaude\n%1\t1\tlgtm\n");
    try testing.expectEqual(@as(usize, 2), panes.len);
    try testing.expectEqualStrings("%0", panes[0].id);
    try testing.expectEqualStrings("claude", panes[0].command);
    try testing.expect(!panes[0].active);
    try testing.expect(panes[1].active);
}

test "a pane listing carries where it is and what it calls itself" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();

    const panes = try parsePanes(
        a.allocator(),
        "%604\t1\t2.1.261\tlgtm:3.0\tlgtm#1 language support\n",
    );
    try testing.expectEqual(@as(usize, 1), panes.len);
    try testing.expectEqualStrings("%604", panes[0].id);
    try testing.expectEqualStrings("2.1.261", panes[0].command);
    try testing.expectEqualStrings("lgtm:3.0", panes[0].where);
    // The session alone, for the picker's grouping.
    try testing.expectEqualStrings("lgtm", panes[0].session);
    // The title is a person's sentence, so it takes the rest of the line -
    // tabs in it are the title's, not a field boundary.
    try testing.expectEqualStrings("lgtm#1 language support", panes[0].title);
}

test "a tmux that answers only the first three fields still drives inference" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();

    // What inference has always needed is the id; the picker's two fields are
    // last so that a tmux too old to know them costs nothing else.
    const panes = try parsePanes(a.allocator(), "%1\t1\tsh\n%2\t0\tclaude\n");
    try testing.expectEqual(@as(usize, 2), panes.len);
    try testing.expectEqualStrings("", panes[0].where);
    try testing.expectEqualStrings("", panes[1].title);
    try testing.expectEqualStrings("%2", soleOther(panes, "%1").?);
}

test "a line tmux could not format is skipped, not fatal" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();

    // A tmux too old to know a format variable prints it back verbatim.
    const panes = try parsePanes(a.allocator(), "#{pane_id}\t1\tsh\n%2\t0\tclaude\ngarbage\n");
    try testing.expectEqual(@as(usize, 1), panes.len);
    try testing.expectEqualStrings("%2", panes[0].id);
}

test "a capture is one subprocess, split on a line the panes cannot show" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const argv = try captureArgv(arena, &.{ "%1", "%2" }, "@@m@@");
    try testing.expectEqualStrings("tmux", argv[0]);
    // A bare `;` is tmux's separator, and there is no shell here to quote it.
    try testing.expectEqualStrings(";", argv[5]);
    try testing.expectEqualStrings("@@m@@", argv[8]);
    try testing.expectEqualStrings(";", argv[9]);
    try testing.expectEqualStrings("%2", argv[13]);

    const caps = (try parseCaptures(arena, "one\ntwo\n@@m@@\nthree\n@@m@@\n", "@@m@@", 2)).?;
    try testing.expectEqual(@as(usize, 2), caps.len);
    try testing.expectEqualStrings("one\ntwo\n", caps[0]);
    try testing.expectEqualStrings("three\n", caps[1]);
}

test "a pane showing the marker does not split its own capture" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    // The marker inside a line is text, not a boundary: only a line that is
    // nothing but the marker ends a section.
    const caps = (try parseCaptures(arena, "grep @@m@@ file\n@@m@@\n", "@@m@@", 1)).?;
    try testing.expectEqual(@as(usize, 1), caps.len);
    try testing.expectEqualStrings("grep @@m@@ file\n", caps[0]);
}

test "a capture that does not divide cleanly is dropped whole" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    // Two panes asked for, one section back. A preview of the wrong pane is
    // worse than no preview, so nothing is returned rather than a guess.
    try testing.expect(try parseCaptures(arena, "only\n@@m@@\n", "@@m@@", 2) == null);
}

test "a pane whose last output is halfway up loses the blank rows under it" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const caps = (try parseCaptures(arena, "said\n\n   \n\n@@m@@\n", "@@m@@", 1)).?;
    try testing.expectEqualStrings("said\n", caps[0]);

    // A pane showing nothing at all is empty, not one blank line.
    const blank = (try parseCaptures(arena, "\n\n@@m@@\n", "@@m@@", 1)).?;
    try testing.expectEqualStrings("", blank[0]);
}

test "two panes name the target; three decline to guess" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();

    const pair = try parsePanes(a.allocator(), "%0\t0\tclaude\n%1\t1\tlgtm\n");
    try testing.expectEqualStrings("%0", soleOther(pair, "%1").?);

    // Three panes is a guess, and a wrong guess types into an editor.
    const three = try parsePanes(a.allocator(), "%0\t0\tclaude\n%1\t1\tlgtm\n%2\t0\tnvim\n");
    try testing.expect(soleOther(three, "%1") == null);

    // A window holding only us has nothing to send to.
    const alone = try parsePanes(a.allocator(), "%1\t1\tlgtm\n");
    try testing.expect(soleOther(alone, "%1") == null);

    // With no $TMUX_PANE to exclude, the pair is two candidates rather than
    // one, and the caller is asked instead of guessed at.
    try testing.expect(soleOther(pair, "") == null);
}
