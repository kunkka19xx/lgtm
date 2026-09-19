// SPDX-License-Identifier: Apache-2.0
//
// Opening and closing agents for the phone: commands from config only, and nothing on the desk takes focus.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const proc = @import("../io/proc.zig");
const panes = @import("panes.zig");

/// The tmux session agents are opened in, so they never land in one the reader is using.
pub const session = "agents";

pub const Error = error{ NoMultiplexer, Failed, NotHere } || Allocator.Error;

/// An agent's name: its command's first word.
pub fn name(command: []const u8) []const u8 {
    var it = std.mem.tokenizeScalar(u8, command, ' ');
    return std.fs.path.basename(it.next() orelse "");
}

/// tmux first, else herdr or kitty, else a detached tmux session; the new pane's id when the backend says it.
pub fn open(gpa: Allocator, io: Io, arena: Allocator, reg: *panes.Registry, command: []const u8, dir: []const u8) Error!?[]const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, command, ' ');
    while (it.next()) |w| try words.append(arena, w);
    if (words.items.len == 0) return error.Failed;
    const label = name(command);

    if (reg.live(.herdr) and !reg.live(.tmux)) {
        const made = try run(gpa, io, arena, &.{ "herdr", "tab", "create", "--cwd", dir, "--label", label, "--no-focus" });
        const Made = struct { result: struct { root_pane: struct { pane_id: []const u8, terminal_id: []const u8 } } };
        const pane = (std.json.parseFromSliceLeaky(Made, arena, made, .{ .ignore_unknown_fields = true }) catch return error.Failed).result.root_pane;
        _ = try run(gpa, io, arena, try std.mem.concat(arena, []const u8, &.{ &.{ "herdr", "pane", "run", pane.pane_id }, words.items }));
        return try std.fmt.allocPrint(arena, "herdr:{s}", .{pane.terminal_id});
    }
    if (reg.live(.kitty) and !reg.live(.tmux)) {
        _ = try run(gpa, io, arena, try std.mem.concat(arena, []const u8, &.{ &.{ "kitten", "@", "launch", "--type=tab", "--keep-focus", "--cwd", dir, "--tab-title", label }, words.items }));
        return null;
    }
    const has = proc.run(gpa, io, &.{ "tmux", "has-session", "-t", "=" ++ session }, 4096) catch return error.NoMultiplexer;
    defer has.deinit(gpa);
    const head: []const []const u8 = if (has.exit_code == 0)
        &.{ "tmux", "new-window", "-d", "-P", "-F", "#{pid}:#{pane_id}", "-t", "=" ++ session ++ ":", "-c", dir, "-n", label, "--" }
    else
        &.{ "tmux", "new-session", "-d", "-P", "-F", "#{pid}:#{pane_id}", "-s", session, "-c", dir, "-n", label, "--" };
    const made = try run(gpa, io, arena, try std.mem.concat(arena, []const u8, &.{ head, words.items }));
    return try std.fmt.allocPrint(arena, "tmux:{s}", .{std.mem.trim(u8, made, " \n")});
}

/// Closes an agent's pane. A `lgtm agent` is stopped where it runs.
pub fn close(gpa: Allocator, io: Io, arena: Allocator, e: panes.Entry) Error!void {
    const argv: []const []const u8 = switch (e.kind) {
        .tmux => &.{ "tmux", "kill-pane", "-t", e.native },
        .herdr => &.{ "herdr", "pane", "close", e.native },
        .kitty => &.{ "kitten", "@", "close-window", "--match", try std.fmt.allocPrint(arena, "id:{s}", .{e.native}) },
        .wezterm => &.{ "wezterm", "cli", "kill-pane", "--pane-id", e.native },
        .pty => return error.NotHere,
    };
    _ = try run(gpa, io, arena, argv);
}

/// Stdout, in `arena`, of a command that must succeed.
fn run(gpa: Allocator, io: Io, arena: Allocator, argv: []const []const u8) Error![]const u8 {
    const res = proc.run(gpa, io, argv, 64 << 10) catch return error.Failed;
    defer res.deinit(gpa);
    if (res.exit_code != 0) return error.Failed;
    return arena.dupe(u8, res.stdout);
}

test "an agent is named by its command's first word" {
    try std.testing.expectEqualStrings("codex", name("codex --full-auto"));
    try std.testing.expectEqualStrings("claude", name("  /usr/local/bin/claude"));
    try std.testing.expectEqualStrings("", name(""));
}
