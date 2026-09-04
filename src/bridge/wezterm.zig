// SPDX-License-Identifier: Apache-2.0
//
// WezTerm, through its own CLI. The same shape as `tmux.zig`: build an argv,
// run it, and say which of the two failures happened so the caller can decide
// whether to degrade.
//
// `wezterm cli send-text --no-paste --pane-id <id> -- <text>` is the whole of
// it. `--no-paste` matters: without it WezTerm wraps the text in bracketed
// paste, which some agents' input boxes submit on rather than insert. The
// invariants that stop this pressing Enter live in `bridge.zig`, above every
// backend, because a backend cannot be trusted to remember them.
//
// A pane id here is a plain integer, not tmux's `%3`, which is why the sigil
// check in `bridge.zig`'s saved-target parser belongs to tmux and not here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const proc = @import("../io/proc.zig");

/// Pane ids are small integers; `18446744073709551615` is twenty digits and
/// nothing real gets near it.
pub const max_pane_id = 24;

const send_output_max = 4 << 10;
const list_output_max = 64 << 10;

pub const SendError = error{ PaneGone, WeztermFailed } || Allocator.Error;

/// `--` before the text, always. A payload beginning with a dash is a payload,
/// and without the separator WezTerm reads it as a flag - the same rule
/// `gitobj.zig` follows for paths, and for the same reason.
pub fn sendArgv(arena: Allocator, pane: []const u8, text: []const u8) Allocator.Error![]const []const u8 {
    return arena.dupe([]const u8, &.{
        "wezterm", "cli", "send-text", "--no-paste", "--pane-id", pane, "--", text,
    });
}

pub fn listArgv(arena: Allocator) Allocator.Error![]const []const u8 {
    return arena.dupe([]const u8, &.{ "wezterm", "cli", "list", "--format", "json" });
}

pub fn send(gpa: Allocator, io: std.Io, pane: []const u8, text: []const u8) SendError!void {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();

    const argv = try sendArgv(scratch.allocator(), pane, text);
    const out = proc.run(gpa, io, argv, send_output_max) catch return error.WeztermFailed;
    defer out.deinit(gpa);
    if (out.exit_code != 0) {
        // WezTerm says "no such pane" for a pane that has closed. Worth
        // separating for the same reason tmux's is: it is the common failure
        // and the one the reader can act on.
        return if (std.mem.indexOf(u8, out.stderr, "no such pane") != null or
            std.mem.indexOf(u8, out.stderr, "not found") != null)
            error.PaneGone
        else
            error.WeztermFailed;
    }
}

/// Every pane WezTerm knows about, as ids. The `--format json` output is read
/// for `"pane_id":<n>` rather than parsed as JSON: one integer field out of a
/// document this program has no other use for does not justify a parser, and a
/// field that moves shows as no panes found rather than as a wrong answer.
pub fn list(gpa: Allocator, arena: Allocator, io: std.Io) Allocator.Error![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const argv = listArgv(arena) catch return out.toOwnedSlice(arena);
    const res = proc.run(gpa, io, argv, list_output_max) catch return out.toOwnedSlice(arena);
    defer res.deinit(gpa);
    if (res.exit_code != 0) return out.toOwnedSlice(arena);
    try parseList(arena, res.stdout, &out);
    return out.toOwnedSlice(arena);
}

/// Split from the subprocess so the scraping has a test that spawns nothing.
pub fn parseList(arena: Allocator, text: []const u8, out: *std.ArrayList([]const u8)) Allocator.Error!void {
    const key = "\"pane_id\":";
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, text, at, key)) |i| {
        var j = i + key.len;
        while (j < text.len and (text[j] == ' ' or text[j] == '\t')) j += 1;
        const start = j;
        while (j < text.len and std.ascii.isDigit(text[j])) j += 1;
        at = j;
        if (j == start) continue;
        try out.append(arena, text[start..j]);
    }
}

/// The one pane that is not ours, or null when there is more than one to
/// choose between.
///
/// The same rule `tmux.soleOther` follows, and it is the rule rather than a
/// heuristic: two panes means the other one is the agent, and three means
/// guessing. Guessing wrong types a review into someone's editor.
pub fn soleOther(panes: []const []const u8, self: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (panes) |p| {
        if (self.len > 0 and std.mem.eql(u8, p, self)) continue;
        if (found != null) return null;
        found = p;
    }
    return found;
}

const testing = std.testing;

test "send-text is no-paste and separates the payload from the flags" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const argv = try sendArgv(arena.allocator(), "3", "-not a flag");

    try testing.expectEqualStrings("--no-paste", argv[3]);
    // `--` before the text, so a payload that opens with a dash is a payload.
    try testing.expectEqualStrings("--", argv[6]);
    try testing.expectEqualStrings("-not a flag", argv[7]);
}

test "pane ids are scraped without parsing the whole document" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    try parseList(arena.allocator(),
        \\[{"window_id":0,"pane_id":0,"title":"zsh"},
        \\ {"window_id":0,"pane_id": 7,"title":"agent"}]
    , &out);

    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqualStrings("0", out.items[0]);
    try testing.expectEqualStrings("7", out.items[1]);
}

test "a field that moved reads as no panes rather than as a wrong one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    try parseList(arena.allocator(), "[{\"paneId\":3}]", &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "two panes infer the other one, three refuse to guess" {
    try testing.expectEqualStrings("7", soleOther(&.{ "0", "7" }, "0").?);
    // Three is a window nobody can be sure about, and guessing wrong types a
    // review into someone's editor.
    try testing.expect(soleOther(&.{ "0", "7", "9" }, "0") == null);
    // Alone in the window there is nobody to send to.
    try testing.expect(soleOther(&.{"0"}, "0") == null);
}
