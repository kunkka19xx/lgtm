// SPDX-License-Identifier: Apache-2.0
//
// herdr, through its CLI. The same shape as the other three: an argv, a
// subprocess, one named failure worth degrading on.
//
// It is the best fit of the four, and worth saying why. herdr is a multiplexer
// built for coding agents, so its `send-text` is a *separate* verb from
// `send-keys` and `send-input` - raw text goes in and nothing is pressed. In
// tmux the same operation is `send-keys -l` and a newline in the payload is
// Enter, which is why hard rule 1 exists and why `bridge.zig` refuses a
// multiline payload before any backend sees it. Here the rule is upheld by the
// API's own shape as well, which is the difference between an invariant that
// is guarded and one that cannot be violated.
//
// **The subcommand is spelled two ways in herdr's own documentation** - the
// CLI reference says `send-text`, the socket-API page writes `send_text` while
// naming the underlying `pane.send_text` method. The hyphen is what a CLI
// reference is authoritative about, so it is tried first and the underscore is
// the retry. Two spellings and one extra subprocess on a machine where the
// first is wrong beats a backend that silently never works.

const std = @import("std");
const Allocator = std.mem.Allocator;
const proc = @import("../io/proc.zig");

/// `w12:p34` and room to spare. Pane ids are workspace and pane, both small.
pub const max_pane_id = 24;

const send_output_max = 4 << 10;
const list_output_max = 256 << 10;

pub const SendError = error{ PaneGone, HerdrFailed } || Allocator.Error;

/// The two spellings, in the order they are tried.
pub const verbs = [_][]const u8{ "send-text", "send_text" };

pub fn sendArgv(arena: Allocator, verb: []const u8, pane: []const u8, text: []const u8) Allocator.Error![]const []const u8 {
    return arena.dupe([]const u8, &.{ "herdr", "pane", verb, pane, text });
}

pub fn listArgv(arena: Allocator) Allocator.Error![]const []const u8 {
    return arena.dupe([]const u8, &.{ "herdr", "pane", "list" });
}

pub fn send(gpa: Allocator, io: std.Io, pane: []const u8, text: []const u8) SendError!void {
    var last: SendError = error.HerdrFailed;
    for (verbs) |verb| {
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();

        const argv = try sendArgv(scratch.allocator(), verb, pane, text);
        const out = proc.run(gpa, io, argv, send_output_max) catch return error.HerdrFailed;
        defer out.deinit(gpa);
        if (out.exit_code == 0) return;

        last = classify(out.stderr);
        // Only a subcommand herdr does not know is worth trying the other
        // spelling for. A pane that has gone is gone under both.
        if (!unknownVerb(out.stderr)) return last;
    }
    return last;
}

/// Whether the failure was herdr not recognising the subcommand, rather than
/// anything about the pane. Split out so the retry has a test that spawns
/// nothing.
pub fn unknownVerb(stderr: []const u8) bool {
    return std.mem.indexOf(u8, stderr, "unrecognized") != null or
        std.mem.indexOf(u8, stderr, "unrecognised") != null or
        std.mem.indexOf(u8, stderr, "unknown subcommand") != null or
        std.mem.indexOf(u8, stderr, "unexpected argument") != null;
}

pub fn classify(stderr: []const u8) SendError {
    if (std.mem.indexOf(u8, stderr, "not found") != null or
        std.mem.indexOf(u8, stderr, "no such pane") != null or
        std.mem.indexOf(u8, stderr, "unknown pane") != null)
        return error.PaneGone;
    return error.HerdrFailed;
}

/// Every pane herdr reports.
///
/// Scraped for the id *pattern* rather than for a field name: a pane id is
/// `w<n>:p<n>`, which is distinctive enough to find on its own and survives
/// both a JSON key being renamed and the CLI printing a table instead. The
/// other backends scrape a named field because their ids are bare integers
/// with nothing to recognise; here the id recognises itself.
pub fn list(gpa: Allocator, arena: Allocator, io: std.Io) Allocator.Error![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const argv = listArgv(arena) catch return out.toOwnedSlice(arena);
    const res = proc.run(gpa, io, argv, list_output_max) catch return out.toOwnedSlice(arena);
    defer res.deinit(gpa);
    if (res.exit_code != 0) return out.toOwnedSlice(arena);
    try parseList(arena, res.stdout, &out);
    return out.toOwnedSlice(arena);
}

pub fn parseList(arena: Allocator, text: []const u8, out: *std.ArrayList([]const u8)) Allocator.Error!void {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != 'w' or (i > 0 and isIdent(text[i - 1]))) {
            i += 1;
            continue;
        }
        const start = i;
        var j = i + 1;
        const w_digits = j;
        while (j < text.len and std.ascii.isDigit(text[j])) j += 1;
        if (j == w_digits or j >= text.len or text[j] != ':' or j + 1 >= text.len or text[j + 1] != 'p') {
            i += 1;
            continue;
        }
        j += 2;
        const p_digits = j;
        while (j < text.len and std.ascii.isDigit(text[j])) j += 1;
        if (j == p_digits) {
            i += 1;
            continue;
        }
        const id = text[start..j];
        i = j;
        // The listing repeats an id wherever it names one - a pane's own entry
        // and a layout that mentions it - and a duplicate would make
        // `soleOther` refuse a window that holds exactly two.
        var seen = false;
        for (out.items) |had| {
            if (std.mem.eql(u8, had, id)) seen = true;
        }
        if (!seen) try out.append(arena, id);
    }
}

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// The one pane that is not ours, or null when there is more than one to
/// choose between - the same rule, and the same reason, as the other three.
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

test "send-text is the documented spelling and the payload is its own argument" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const argv = try sendArgv(arena.allocator(), verbs[0], "w1:p1", "#3 src/ui/app.zig:47");

    try testing.expectEqualStrings("herdr", argv[0]);
    try testing.expectEqualStrings("pane", argv[1]);
    try testing.expectEqualStrings("send-text", argv[2]);
    try testing.expectEqualStrings("w1:p1", argv[3]);
    try testing.expectEqualStrings("#3 src/ui/app.zig:47", argv[4]);
    // `send-text`, never `send-keys` or `send-input`: those press things, and
    // the reader decides when to press Enter.
    try testing.expect(std.mem.indexOf(u8, argv[2], "keys") == null);
}

test "only an unknown subcommand earns the second spelling" {
    // herdr's own docs disagree about the hyphen. Retrying costs one
    // subprocess on a machine where the first guess is wrong; not retrying
    // costs a backend that silently never works.
    try testing.expect(unknownVerb("error: unrecognized subcommand 'send-text'"));
    try testing.expect(unknownVerb("error: unexpected argument 'send-text' found"));
    // A pane that has gone is gone under either spelling, so it is answered
    // rather than retried.
    try testing.expect(!unknownVerb("error: pane w1:p9 not found"));
    try testing.expectEqual(SendError.PaneGone, classify("error: pane w1:p9 not found"));
    try testing.expectEqual(SendError.HerdrFailed, classify("socket closed"));
}

test "pane ids are found by their own shape, whatever the listing looks like" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // JSON today.
    var a: std.ArrayList([]const u8) = .empty;
    try parseList(arena.allocator(),
        \\[{"pane_id":"w1:p1","cmd":"zsh"},{"pane_id":"w1:p2","cmd":"claude"}]
    , &a);
    try testing.expectEqual(@as(usize, 2), a.items.len);
    try testing.expectEqualStrings("w1:p1", a.items[0]);
    try testing.expectEqualStrings("w1:p2", a.items[1]);

    // A table tomorrow, and the same answer: the id recognises itself, so a
    // renamed field or a dropped `--json` does not silently return nothing.
    var b: std.ArrayList([]const u8) = .empty;
    try parseList(arena.allocator(), "w1:p1  zsh\nw1:p2  claude\n", &b);
    try testing.expectEqual(@as(usize, 2), b.items.len);
    try testing.expectEqualStrings("w1:p2", b.items[1]);
}

test "an id named twice is one pane" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    // A listing that also prints a layout names the same pane again. Counting
    // it twice would make `soleOther` refuse a window holding exactly two,
    // which is the one shape the inference exists for.
    try parseList(arena.allocator(),
        \\{"panes":["w1:p1","w1:p2"],"layout":"w1:p1|w1:p2"}
    , &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
}

test "words that merely start with w are not pane ids" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    try parseList(arena.allocator(), "workspace:primary  wp1  w:p1  w1:p  raw1:p1", &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "two panes infer the other one, three refuse to guess" {
    try testing.expectEqualStrings("w1:p2", soleOther(&.{ "w1:p1", "w1:p2" }, "w1:p1").?);
    try testing.expect(soleOther(&.{ "w1:p1", "w1:p2", "w1:p3" }, "w1:p1") == null);
}
