// SPDX-License-Identifier: Apache-2.0
//
// Ghostty, through AppleScript. macOS only, and Ghostty 1.3 or newer - the
// dictionary did not exist before it, which is why every earlier version of
// this file said Ghostty could not be typed into.
//
// The same shape as the other four backends, with two differences that come
// from the API rather than from choice.
//
// **The payload is an AppleScript string literal, not an argv element.** The
// other four hand git-style CLIs a separate argument and the kernel keeps the
// bytes intact; here the text is compiled as source, so a quote or a backslash
// in a review comment would end the literal and turn the rest into a syntax
// error - or, worse, into script. `quote` escapes both, and it is the only
// interesting code in this file.
//
// **A Ghostty pane cannot say which one it is.** tmux has `$TMUX_PANE`, herdr
// has `$HERDR_PANE_ID`, WezTerm and kitty likewise; Ghostty injects
// `$GHOSTTY_RESOURCES_DIR` and `$TERM_PROGRAM`, which say *that* you are in
// Ghostty and not *where*. So "our own" is the terminal that is focused when
// `lgtm` first needs to know, which is sound because that is the moment just
// after the reader typed `lgtm` into it. It is the one inference here that
// rests on a habit rather than on an identifier, and `--pane` overrides it.
//
// `input text` is a separate verb from `send key`, so nothing is submitted -
// the same property herdr has and tmux does not.

const std = @import("std");
const Allocator = std.mem.Allocator;
const proc = @import("../io/proc.zig");

/// Terminal ids are small integers.
pub const max_pane_id = 24;

const send_output_max = 4 << 10;
const list_output_max = 64 << 10;

/// A payload longer than this is not one. The cap bounds the script we build,
/// which is compiled as source by `osascript`.
const max_text = 16 << 10;

pub const SendError = error{ PaneGone, Unavailable, GhosttyFailed } || Allocator.Error;

/// `osascript -e <script>`. One `-e`, so the whole script is one argument and
/// the shell never sees it.
pub fn sendArgv(arena: Allocator, pane: []const u8, text: []const u8) Allocator.Error![]const []const u8 {
    const script = try std.fmt.allocPrint(
        arena,
        "tell application \"Ghostty\" to input text \"{s}\" to terminal id {s}",
        .{ try quote(arena, text), pane },
    );
    return arena.dupe([]const u8, &.{ "osascript", "-e", script });
}

pub fn listArgv(arena: Allocator) Allocator.Error![]const []const u8 {
    return arena.dupe([]const u8, &.{
        "osascript", "-e", "tell application \"Ghostty\" to get id of every terminal",
    });
}

/// The focused terminal, which is ours at the moment we first ask.
pub fn frontArgv(arena: Allocator) Allocator.Error![]const []const u8 {
    return arena.dupe([]const u8, &.{
        "osascript", "-e", "tell application \"Ghostty\" to get id of front terminal",
    });
}

/// An AppleScript string literal's contents. Backslash first, or escaping the
/// quotes would then escape their own escapes.
///
/// A control byte is dropped rather than encoded: AppleScript has no `\n` in a
/// literal, `bridge.zig` has already refused a newline, and a payload with a
/// stray control character in it is better one byte short than a script that
/// will not compile.
pub fn quote(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |c| {
        switch (c) {
            '\\', '"' => {
                try out.append(arena, '\\');
                try out.append(arena, c);
            },
            0x00...0x1f, 0x7f => {},
            else => try out.append(arena, c),
        }
    }
    return out.toOwnedSlice(arena);
}

pub fn send(gpa: Allocator, io: std.Io, pane: []const u8, text: []const u8) SendError!void {
    if (text.len > max_text) return error.GhosttyFailed;
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();

    const argv = try sendArgv(scratch.allocator(), pane, text);
    const out = proc.run(gpa, io, argv, send_output_max) catch return error.GhosttyFailed;
    defer out.deinit(gpa);
    if (out.exit_code != 0) return classify(out.stderr);
}

/// Which of Ghostty's three failures this is.
///
/// `Unavailable` is the one worth separating and the one a reader will meet
/// first: a Ghostty older than 1.3 has no dictionary, and macOS will not let
/// one application script another until the reader has allowed it in
/// Automation settings. Neither is a pane that died, and calling them that
/// would send someone looking at their splits.
pub fn classify(stderr: []const u8) SendError {
    if (std.mem.indexOf(u8, stderr, "Not authorized") != null or
        std.mem.indexOf(u8, stderr, "not allowed assistive") != null or
        std.mem.indexOf(u8, stderr, "-1743") != null or
        std.mem.indexOf(u8, stderr, "doesn't understand") != null or
        std.mem.indexOf(u8, stderr, "Can’t get application") != null or
        std.mem.indexOf(u8, stderr, "Can't get application") != null)
        return error.Unavailable;
    if (std.mem.indexOf(u8, stderr, "Can’t get terminal") != null or
        std.mem.indexOf(u8, stderr, "Can't get terminal") != null or
        std.mem.indexOf(u8, stderr, "-1728") != null)
        return error.PaneGone;
    return error.GhosttyFailed;
}

/// Every terminal id Ghostty reports. `get id of every terminal` prints them
/// comma-separated on one line, which is what AppleScript does with a list.
pub fn list(gpa: Allocator, arena: Allocator, io: std.Io) Allocator.Error![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const argv = listArgv(arena) catch return out.toOwnedSlice(arena);
    const res = proc.run(gpa, io, argv, list_output_max) catch return out.toOwnedSlice(arena);
    defer res.deinit(gpa);
    if (res.exit_code != 0) return out.toOwnedSlice(arena);
    try parseList(arena, res.stdout, &out);
    return out.toOwnedSlice(arena);
}

/// The focused terminal's id, copied into `buf`. Null when Ghostty will not
/// say, which leaves the caller with no way to exclude itself and therefore no
/// inference - `--pane` is the answer there.
pub fn front(gpa: Allocator, io: std.Io, buf: []u8) ?[]const u8 {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const argv = frontArgv(scratch.allocator()) catch return null;
    const res = proc.run(gpa, io, argv, send_output_max) catch return null;
    defer res.deinit(gpa);
    if (res.exit_code != 0) return null;

    const id = std.mem.trim(u8, res.stdout, " \t\r\n");
    if (id.len == 0 or id.len > buf.len) return null;
    for (id) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    @memcpy(buf[0..id.len], id);
    return buf[0..id.len];
}

/// Comma-separated integers, which is AppleScript's rendering of a list.
pub fn parseList(arena: Allocator, text: []const u8, out: *std.ArrayList([]const u8)) Allocator.Error!void {
    var it = std.mem.tokenizeAny(u8, text, ", \t\r\n");
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        var ok = true;
        for (tok) |c| {
            if (!std.ascii.isDigit(c)) ok = false;
        }
        if (ok) try out.append(arena, tok);
    }
}

/// The one terminal that is not ours, or null when there is more than one to
/// choose between - the same rule, and the same reason, as the other four.
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

test "a quote in a review comment cannot end the script" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    // The payload is compiled as source here, unlike every other backend where
    // the kernel hands it over intact. An unescaped quote would end the
    // literal and turn the rest of a reader's comment into AppleScript.
    try testing.expectEqualStrings("say \\\"hi\\\"", try quote(arena, "say \"hi\""));
    // Backslash first, or escaping the quotes escapes their own escapes.
    try testing.expectEqualStrings("a\\\\b", try quote(arena, "a\\b"));
    try testing.expectEqualStrings("\\\\\\\"", try quote(arena, "\\\""));
    // A control byte is dropped: AppleScript literals have no escape for one,
    // and one byte short beats a script that will not compile.
    try testing.expectEqualStrings("ab", try quote(arena, "a\x07b"));
}

test "the script inserts and never submits" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const argv = try sendArgv(a.allocator(), "2", "#3 src/ui/app.zig:47");

    try testing.expectEqualStrings("osascript", argv[0]);
    // One `-e`, so the whole script is one argument and no shell sees it.
    try testing.expectEqualStrings("-e", argv[1]);
    try testing.expectEqual(@as(usize, 3), argv.len);
    try testing.expect(std.mem.indexOf(u8, argv[2], "input text") != null);
    try testing.expect(std.mem.indexOf(u8, argv[2], "terminal id 2") != null);
    // `input text`, never `send key`: those press things, and the reader
    // decides when to press Enter.
    try testing.expect(std.mem.indexOf(u8, argv[2], "send key") == null);
}

test "an old Ghostty and a refused automation are not a dead pane" {
    // The two a reader will actually meet: the dictionary arrived in 1.3, and
    // macOS will not let one app script another until it is allowed. Calling
    // either "pane is gone" sends someone looking at their splits.
    try testing.expectEqual(SendError.Unavailable, classify("Not authorized to send Apple events to Ghostty. (-1743)"));
    try testing.expectEqual(SendError.Unavailable, classify("Ghostty got an error: Can't get application \"Ghostty\""));
    try testing.expectEqual(SendError.PaneGone, classify("Ghostty got an error: Can't get terminal id 9. (-1728)"));
    try testing.expectEqual(SendError.GhosttyFailed, classify("something else"));
}

test "AppleScript renders a list comma-separated" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    try parseList(a.allocator(), "1, 2, 5\n", &out);

    try testing.expectEqual(@as(usize, 3), out.items.len);
    try testing.expectEqualStrings("1", out.items[0]);
    try testing.expectEqualStrings("5", out.items[2]);

    // An error line is not a list of ids.
    var bad: std.ArrayList([]const u8) = .empty;
    try parseList(a.allocator(), "execution error: Not authorized", &bad);
    try testing.expectEqual(@as(usize, 0), bad.items.len);
}

test "two terminals infer the other, three refuse" {
    try testing.expectEqualStrings("2", soleOther(&.{ "1", "2" }, "1").?);
    try testing.expect(soleOther(&.{ "1", "2", "3" }, "1") == null);
    // Without a self id there is nothing to exclude, so two is still two and
    // the inference declines rather than guessing which one is lgtm.
    try testing.expect(soleOther(&.{ "1", "2" }, "") == null);
}
