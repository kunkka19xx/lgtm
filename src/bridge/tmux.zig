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
/// The window is the useful default - an agent and its reviewer sit side by
/// side - and `-a` is what the error message falls back to when the window
/// holds more than the two.
pub fn listArgv(arena: Allocator, all_sessions: bool) Allocator.Error![]const []const u8 {
    const format = "#{pane_id}\t#{pane_active}\t#{pane_current_command}";
    return if (all_sessions)
        arena.dupe([]const u8, &.{ "tmux", "list-panes", "-a", "-F", format })
    else
        arena.dupe([]const u8, &.{ "tmux", "list-panes", "-F", format });
}

/// One pane per line, three tab-separated fields. A line that does not have
/// them is skipped rather than failing the listing: a tmux old enough to not
/// know a format variable prints it back verbatim, and losing one pane from a
/// picker is better than losing the picker.
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
        try panes.append(arena, .{
            .id = id,
            .active = std.mem.eql(u8, active, "1"),
            .command = command,
        });
    }
    return panes.toOwnedSlice(arena);
}

/// The target, when there is only one it could be.
///
/// Two panes in a window - the agent and the reviewer reading it - is the
/// setup the tool is named after, and there the answer is unambiguous. Three
/// or more is a guess, and a wrong guess types into someone's editor, so it
/// declines and the caller asks (SPEC.md 6.3).
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
/// rather than treating it as fatal (ARCHITECTURE.md 6).
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
pub fn list(gpa: Allocator, arena: Allocator, io: std.Io, all_sessions: bool) SendError![]Pane {
    const argv = try listArgv(arena, all_sessions);
    const out = proc.run(gpa, io, argv, list_output_max) catch return error.TmuxFailed;
    defer out.deinit(gpa);
    if (out.exit_code != 0) return error.TmuxFailed;
    return parsePanes(arena, try arena.dupe(u8, out.stdout));
}

const testing = std.testing;

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

test "a line tmux could not format is skipped, not fatal" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();

    // A tmux too old to know a format variable prints it back verbatim.
    const panes = try parsePanes(a.allocator(), "#{pane_id}\t1\tsh\n%2\t0\tclaude\ngarbage\n");
    try testing.expectEqual(@as(usize, 1), panes.len);
    try testing.expectEqualStrings("%2", panes[0].id);
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
