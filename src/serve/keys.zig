// SPDX-License-Identifier: Apache-2.0
//
// The few keys a phone's text box cannot type, in each backend's own spelling.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Kind = @import("panes.zig").Kind;

/// Enter is not here: it is only ever pressed by `submit` on a send.
pub const Key = enum { escape, tab, @"shift-tab", up, down, left, right, @"ctrl-c", @"1", @"2", @"3", @"4", @"5", @"6", @"7", @"8", @"9" };

const Names = struct { tmux: []const u8, herdr: []const u8, kitty: []const u8, bytes: []const u8 };

fn names(key: Key) Names {
    return switch (key) {
        .escape => .{ .tmux = "Escape", .herdr = "esc", .kitty = "escape", .bytes = "\x1b" },
        .tab => .{ .tmux = "Tab", .herdr = "tab", .kitty = "tab", .bytes = "\t" },
        .@"shift-tab" => .{ .tmux = "BTab", .herdr = "shift+tab", .kitty = "shift+tab", .bytes = "\x1b[Z" },
        .up => .{ .tmux = "Up", .herdr = "up", .kitty = "up", .bytes = "\x1b[A" },
        .down => .{ .tmux = "Down", .herdr = "down", .kitty = "down", .bytes = "\x1b[B" },
        .right => .{ .tmux = "Right", .herdr = "right", .kitty = "right", .bytes = "\x1b[C" },
        .left => .{ .tmux = "Left", .herdr = "left", .kitty = "left", .bytes = "\x1b[D" },
        .@"ctrl-c" => .{ .tmux = "C-c", .herdr = "ctrl+c", .kitty = "ctrl+c", .bytes = "\x03" },
        inline else => |k| comptime blk: {
            const d = @tagName(k);
            break :blk .{ .tmux = d, .herdr = d, .kitty = d, .bytes = d };
        },
    };
}

pub fn bytes(key: Key) []const u8 {
    return names(key).bytes;
}

pub fn argv(arena: Allocator, kind: Kind, pane: []const u8, key: Key) Allocator.Error![]const []const u8 {
    const n = names(key);
    return switch (kind) {
        .tmux => arena.dupe([]const u8, &.{ "tmux", "send-keys", "-t", pane, n.tmux }),
        .herdr => arena.dupe([]const u8, &.{ "herdr", "pane", "send-keys", pane, n.herdr }),
        .kitty => arena.dupe([]const u8, &.{ "kitten", "@", "send-key", "--match", try std.fmt.allocPrint(arena, "id:{s}", .{pane}), n.kitty }),
        .wezterm => arena.dupe([]const u8, &.{ "wezterm", "cli", "send-text", "--no-paste", "--pane-id", pane, "--", n.bytes }),
        .pty => unreachable,
    };
}

const testing = std.testing;

test "every key has a spelling for every backend, and none of them is Enter" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    for (std.enums.values(Key)) |k| {
        const n = names(k);
        try testing.expect(n.tmux.len > 0 and n.herdr.len > 0 and n.kitty.len > 0 and n.bytes.len > 0);
        try testing.expect(std.mem.indexOfAny(u8, n.bytes, "\r\n") == null);
        for ([_][]const u8{ n.tmux, n.herdr, n.kitty }) |name| try testing.expect(!std.ascii.eqlIgnoreCase(name, "enter"));
    }
    try testing.expectEqualStrings("C-c", (try argv(a.allocator(), .tmux, "%3", .@"ctrl-c"))[4]);
    try testing.expectEqualStrings("id:7", (try argv(a.allocator(), .kitty, "7", .escape))[4]);
    try testing.expectEqualStrings("\x1b[Z", (try argv(a.allocator(), .wezterm, "2", .@"shift-tab"))[7]);
    try testing.expectEqualStrings("3", bytes(.@"3"));
}
