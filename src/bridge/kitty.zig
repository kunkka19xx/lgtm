// SPDX-License-Identifier: Apache-2.0
//
// kitty, through its remote control protocol. The same shape as `tmux.zig` and
// `wezterm.zig`: an argv, a subprocess, and one named failure the caller can
// degrade on.
//
// `kitten @ send-text --match id:<n> -- <text>`. Two things about kitty are
// different from the other two and both are worth knowing before reading:
//
// **Remote control is off by default.** Without `allow_remote_control yes` in
// `kitty.conf` every call fails, and the failure is a permission refusal
// rather than a missing window. That is not a bug to work around - it is
// kitty deliberately not letting any process on the machine type into the
// user's terminal - so it degrades to the clipboard with a notice naming the
// setting, which is the only thing the reader can act on.
//
// **The window id is in `$KITTY_WINDOW_ID`**, which is how `detect` knows it
// is inside kitty at all and which window not to send to.

const std = @import("std");
const Allocator = std.mem.Allocator;
const proc = @import("../io/proc.zig");

pub const max_window_id = 24;

const send_output_max = 4 << 10;
const list_output_max = 256 << 10;

pub const SendError = error{ WindowGone, NotAllowed, KittyFailed } || Allocator.Error;

/// `--match id:<n>` rather than a bare id: kitty matches on a field, and `id`
/// is the only one that is stable while a window lives.
pub fn sendArgv(arena: Allocator, window: []const u8, text: []const u8) Allocator.Error![]const []const u8 {
    const match = try std.fmt.allocPrint(arena, "id:{s}", .{window});
    return arena.dupe([]const u8, &.{ "kitten", "@", "send-text", "--match", match, "--", text });
}

pub fn listArgv(arena: Allocator) Allocator.Error![]const []const u8 {
    return arena.dupe([]const u8, &.{ "kitten", "@", "ls" });
}

pub fn send(gpa: Allocator, io: std.Io, window: []const u8, text: []const u8) SendError!void {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();

    const argv = try sendArgv(scratch.allocator(), window, text);
    const out = proc.run(gpa, io, argv, send_output_max) catch return error.KittyFailed;
    defer out.deinit(gpa);
    if (out.exit_code != 0) return classify(out.stderr);
}

/// Which of kitty's three failures this is. Split out because it is the only
/// interesting logic in the file and it has no business needing a subprocess
/// to test.
pub fn classify(stderr: []const u8) SendError {
    if (std.mem.indexOf(u8, stderr, "allow_remote_control") != null or
        std.mem.indexOf(u8, stderr, "not allowed") != null or
        std.mem.indexOf(u8, stderr, "Remote control is disabled") != null)
        return error.NotAllowed;
    if (std.mem.indexOf(u8, stderr, "No matching window") != null or
        std.mem.indexOf(u8, stderr, "no matching") != null)
        return error.WindowGone;
    return error.KittyFailed;
}

/// Every window id kitty reports. `kitten @ ls` is JSON; the ids are scraped
/// for `"id": <n>` inside the window objects for the same reason WezTerm's are
/// - one integer field does not justify a parser, and a format change shows as
/// no windows found rather than as a wrong answer.
pub fn list(gpa: Allocator, arena: Allocator, io: std.Io) Allocator.Error![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const argv = listArgv(arena) catch return out.toOwnedSlice(arena);
    const res = proc.run(gpa, io, argv, list_output_max) catch return out.toOwnedSlice(arena);
    defer res.deinit(gpa);
    if (res.exit_code != 0) return out.toOwnedSlice(arena);
    try parseList(arena, res.stdout, &out);
    return out.toOwnedSlice(arena);
}

/// Window ids only.
///
/// `kitten @ ls` nests os-windows, tabs and windows, and every level has an
/// `"id"`. Only the innermost is a window that can be typed into, and it is
/// the one that appears beside `"pid"` - so the scrape anchors on that pair
/// rather than on `"id"` alone, which would return tab ids as though they were
/// windows and send the review into nowhere.
pub fn parseList(arena: Allocator, text: []const u8, out: *std.ArrayList([]const u8)) Allocator.Error!void {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, text, at, "\"pid\"")) |pid| {
        at = pid + 5;
        // The window's own id is the "id" nearest before its "pid", which is
        // the one in the same object.
        const before = text[0..pid];
        const id = std.mem.lastIndexOf(u8, before, "\"id\":") orelse continue;
        var j = id + 5;
        while (j < text.len and (text[j] == ' ' or text[j] == '\t')) j += 1;
        const start = j;
        while (j < text.len and std.ascii.isDigit(text[j])) j += 1;
        if (j == start) continue;
        try out.append(arena, text[start..j]);
    }
}

/// The one window that is not ours, or null when there is more than one to
/// choose between - the same rule, and the same reason, as the other two.
pub fn soleOther(windows: []const []const u8, self: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (windows) |w| {
        if (self.len > 0 and std.mem.eql(u8, w, self)) continue;
        if (found != null) return null;
        found = w;
    }
    return found;
}

const testing = std.testing;

test "send-text matches on id and separates the payload" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const argv = try sendArgv(arena.allocator(), "4", "--looks-like-a-flag");

    try testing.expectEqualStrings("--match", argv[3]);
    try testing.expectEqualStrings("id:4", argv[4]);
    try testing.expectEqualStrings("--", argv[5]);
    try testing.expectEqualStrings("--looks-like-a-flag", argv[6]);
}

test "remote control being off is its own failure, not a missing window" {
    // The one kitty failure the reader can act on, and the one they will hit
    // first: it is off by default, on purpose.
    // `classify` returns the error as a value, so these compare rather than
    // catch: it is a decision about a string, and keeping it out of the error
    // path is what lets it be tested without a subprocess.
    try testing.expectEqual(SendError.NotAllowed, classify("Remote control is disabled. Add allow_remote_control yes"));
    try testing.expectEqual(SendError.WindowGone, classify("No matching window found"));
    try testing.expectEqual(SendError.KittyFailed, classify("something else entirely"));
}

test "a tab id is not a window id" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    // Every level of `kitten @ ls` has an "id"; only the one beside a "pid" is
    // a window. Anchoring on "id" alone would return `1` and `2` here - a tab
    // and an os-window - and send the review into nowhere.
    try parseList(arena.allocator(),
        \\{"id": 1, "tabs": [{"id": 2, "windows": [
        \\  {"id": 11, "pid": 900, "title": "zsh"},
        \\  {"id": 12, "pid": 901, "title": "agent"}]}]}
    , &out);

    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqualStrings("11", out.items[0]);
    try testing.expectEqualStrings("12", out.items[1]);
}

test "two windows infer the other, three refuse" {
    try testing.expectEqualStrings("12", soleOther(&.{ "11", "12" }, "11").?);
    try testing.expect(soleOther(&.{ "11", "12", "13" }, "11") == null);
}
