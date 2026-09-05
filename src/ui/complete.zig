// SPDX-License-Identifier: Apache-2.0
//
// `<Tab>` in the `:` prompt: names in, candidates out.
//
// Names, not commands, because the line has two things to complete: the
// command itself, and the value of the one command that takes a value
// (`:theme`). Both are lists of strings by the time they get here.
//
// Pure and headless, for the same reason `motion.zig` is. What a reader gets
// for a keystroke is decided here, and it is decided by a table, so it can be
// checked without a terminal to press Tab in.
//
// Fixed capacity, no allocator. There are 87 commands; a completion that can
// fail to allocate is a completion that can eat a keystroke.

const std = @import("std");
const keymap = @import("keymap.zig");
const fuzzy = @import("fuzzy.zig");

/// More than the longest prefix group, and far more than fits on a row.
pub const max = 48;

pub const Set = struct {
    items: [max][]const u8 = undefined,
    len: usize = 0,
    /// How many bytes every candidate shares from the start. `<Tab>` extends
    /// the line to this before it begins cycling, which is vim's `longest`:
    /// typing `n` and pressing Tab should get to `next_` without committing
    /// to which `next_` it is.
    ///
    /// Zero when the candidates came from a subsequence match, because then
    /// they share no prefix with what was typed and extending would be a lie.
    common: usize = 0,

    pub fn slice(self: *const Set) []const []const u8 {
        return self.items[0..self.len];
    }

    fn push(self: *Set, name: []const u8) bool {
        if (self.len == max) return false;
        self.items[self.len] = name;
        self.len += 1;
        return true;
    }

    pub fn empty(self: *const Set) bool {
        return self.len == 0;
    }
};

/// Candidates for `typed`, in enum order.
///
/// Prefix first, because a command line has to be predictable: what `<Tab>`
/// offers should be what a reader would have guessed. Subsequence only when
/// nothing matches by prefix, so `nf` still reaches `next_file` rather than
/// the key doing nothing.
///
/// Only commands `:` would run. Offering one and then refusing it is worse
/// than offering nothing.
pub fn candidates(bindings: []const keymap.Binding, typed: []const u8) Set {
    var set: Set = .{};

    for (std.enums.values(keymap.Command)) |cmd| {
        if (!keymap.typeable(bindings, cmd)) continue;
        if (!std.mem.startsWith(u8, @tagName(cmd), typed)) continue;
        if (!set.push(@tagName(cmd))) break;
    }
    if (set.len > 0) {
        set.common = commonPrefix(set.slice());
        return set;
    }

    if (typed.len == 0) return set;
    for (std.enums.values(keymap.Command)) |cmd| {
        if (!keymap.typeable(bindings, cmd)) continue;
        if (!fuzzy.subsequence(@tagName(cmd), typed)) continue;
        if (!set.push(@tagName(cmd))) break;
    }
    return set;
}

/// The same two rules over a fixed list: what `:theme` completes its argument
/// with. A value has no `typeable` to filter on - every name in the list is
/// one the command accepts - so this is the shorter half of `candidates`.
pub fn fromNames(list: []const []const u8, typed: []const u8) Set {
    var set: Set = .{};

    for (list) |name| {
        if (!std.mem.startsWith(u8, name, typed)) continue;
        if (!set.push(name)) break;
    }
    if (set.len > 0) {
        set.common = commonPrefix(set.slice());
        return set;
    }

    if (typed.len == 0) return set;
    for (list) |name| {
        if (!fuzzy.subsequence(name, typed)) continue;
        if (!set.push(name)) break;
    }
    return set;
}

/// Bytes shared by the start of every candidate's name.
fn commonPrefix(items: []const []const u8) usize {
    if (items.len == 0) return 0;
    const first = items[0];
    var n = first.len;
    for (items[1..]) |name| {
        var i: usize = 0;
        while (i < n and i < name.len and name[i] == first[i]) i += 1;
        n = i;
    }
    return n;
}

/// Which candidates to draw on one row, and how many did not fit.
///
/// The selected one is always inside the window, the way a list scrolls to
/// keep its cursor visible. A strip that hides the candidate it is offering
/// would be worse than no strip.
pub const Strip = struct {
    from: usize = 0,
    to: usize = 0,
    /// Candidates past `to`, for the `+N` that says the list continues.
    more: usize = 0,

    pub fn len(self: Strip) usize {
        return self.to - self.from;
    }
};

/// Two spaces between names, which reads as a gap without a separator glyph.
pub const gap = 2;

pub fn fit(items: []const []const u8, at: usize, width: usize) Strip {
    if (items.len == 0 or width == 0) return .{};

    var from: usize = 0;
    while (from <= at and from < items.len) : (from += 1) {
        var used: usize = 0;
        var to = from;
        while (to < items.len) : (to += 1) {
            const name = items[to].len;
            const step = if (to == from) name else name + gap;
            // Room for " +N" when the list will continue past here. Reserved
            // rather than measured exactly: one column of slack beats a strip
            // that overflows the row on a two-digit count.
            const tail: usize = if (to + 1 < items.len) 5 else 0;
            if (used + step + tail > width) break;
            used += step;
        }
        if (to > at) return .{ .from = from, .to = to, .more = items.len - to };
    }
    // The selected name is wider than the row on its own: show it alone and
    // let the row clip, rather than returning an empty strip.
    return .{ .from = at, .to = at + 1, .more = items.len - at - 1 };
}

const testing = std.testing;

test "prefix candidates share their prefix, and Tab can extend to it" {
    const set = candidates(keymap.default_bindings, "next_");
    try testing.expect(set.len >= 4);
    for (set.slice()) |name| {
        try testing.expect(std.mem.startsWith(u8, name, "next_"));
    }
    // Everything under `next_` shares exactly that much and no more, because
    // the group has both `next_file` and `next_hunk` in it.
    try testing.expectEqual(@as(usize, "next_".len), set.common);
}

test "a single candidate's common prefix is the whole name" {
    // Which is what lets one Tab finish a unique command outright.
    const set = candidates(keymap.default_bindings, "toggle_z");
    try testing.expectEqual(@as(usize, 1), set.len);
    try testing.expectEqualStrings("toggle_zen", set.items[0]);
    try testing.expectEqual(@as(usize, "toggle_zen".len), set.common);
}

test "an empty line offers every typeable command" {
    const set = candidates(keymap.default_bindings, "");
    try testing.expect(set.len > 20);
    try testing.expectEqual(@as(usize, 0), set.common);
    for (set.slice()) |name| {
        const cmd = std.meta.stringToEnum(keymap.Command, name).?;
        try testing.expect(keymap.typeable(keymap.default_bindings, cmd));
    }
}

test "subsequence is the fallback, and never the first answer" {
    // `nf` is not a prefix of anything, so it falls through to subsequence.
    const loose = candidates(keymap.default_bindings, "nf");
    try testing.expect(loose.len > 0);
    var found = false;
    for (loose.slice()) |name| {
        if (std.mem.eql(u8, name, "next_file")) found = true;
    }
    try testing.expect(found);
    // Nothing to extend to: these do not share the typed text at all, and
    // extending the line to a prefix they happen to share would be a lie.
    try testing.expectEqual(@as(usize, 0), loose.common);

    // But a real prefix must never be answered with a subsequence match, or
    // the offer stops being the one a reader would have guessed.
    const strict = candidates(keymap.default_bindings, "next_f");
    for (strict.slice()) |name| {
        try testing.expect(std.mem.startsWith(u8, name, "next_f"));
    }
}

test "a value list completes by the same two rules as the command names" {
    const themes = [_][]const u8{ "terminal", "catppuccin", "tokyo-night", "gruvbox", "dracula", "rose-pine", "kanagawa" };

    // Prefix, and the common prefix is what Tab extends to.
    const t = fromNames(&themes, "t");
    try testing.expectEqual(@as(usize, 2), t.len);
    try testing.expectEqualStrings("terminal", t.items[0]);
    try testing.expectEqualStrings("tokyo-night", t.items[1]);
    try testing.expectEqual(@as(usize, 1), t.common);

    // Empty offers all of them, and one prefix that matches once is finished
    // outright.
    try testing.expectEqual(themes.len, fromNames(&themes, "").len);
    try testing.expectEqual(@as(usize, "kanagawa".len), fromNames(&themes, "kan").common);

    // Subsequence is the fallback, never the first answer.
    const loose = fromNames(&themes, "tkn");
    try testing.expectEqual(@as(usize, 1), loose.len);
    try testing.expectEqualStrings("tokyo-night", loose.items[0]);
    try testing.expectEqual(@as(usize, 0), loose.common);

    try testing.expect(fromNames(&themes, "zzz").empty());
}

test "nothing resembling a command offers nothing" {
    try testing.expect(candidates(keymap.default_bindings, "zzzqqq").empty());
}

test "completion never offers a command the command line would refuse" {
    // The pairing that matters: `:` refuses compose-only commands, so Tab
    // must not put one in the line and let the reader press Enter on it.
    for ([_][]const u8{ "compose", "c", "l", "" }) |typed| {
        const set = candidates(keymap.default_bindings, typed);
        for (set.slice()) |name| {
            const cmd = std.meta.stringToEnum(keymap.Command, name).?;
            try testing.expect(keymap.typeable(keymap.default_bindings, cmd));
        }
    }
}

test "the strip keeps the selected candidate on screen" {
    const set = candidates(keymap.default_bindings, "");
    const items = set.slice();

    // Narrow row, selection near the end: the window has to have moved.
    const last = items.len - 1;
    const s = fit(items, last, 40);
    try testing.expect(s.from <= last and last < s.to);
    try testing.expectEqual(@as(usize, 0), s.more);

    // And the first one needs no scrolling at all.
    const first = fit(items, 0, 40);
    try testing.expectEqual(@as(usize, 0), first.from);
    try testing.expect(first.to > 0);
    try testing.expect(first.more > 0);
}

test "the strip never draws wider than the row it is given" {
    const set = candidates(keymap.default_bindings, "");
    const items = set.slice();
    // 80 columns is the environment that has to be right; the rest guard the
    // arithmetic at sizes the window can actually be dragged to.
    for ([_]usize{ 80, 60, 40, 24, 12 }) |width| {
        for (0..items.len) |at| {
            const s = fit(items, at, width);
            var used: usize = 0;
            for (s.from..s.to) |i| {
                used += items[i].len;
                if (i != s.from) used += gap;
            }
            // One name too wide for the row is shown alone and clipped, which
            // is the one case allowed to exceed it.
            if (s.len() == 1 and items[s.from].len > width) continue;
            try testing.expect(used <= width);
        }
    }
}

test "a zero-width row and an empty list produce nothing rather than trapping" {
    const set = candidates(keymap.default_bindings, "");
    try testing.expectEqual(@as(usize, 0), fit(set.slice(), 0, 0).len());
    try testing.expectEqual(@as(usize, 0), fit(&.{}, 0, 80).len());
}

test "the strip reserves room for the +N that says the list continues" {
    // The bug this guards: measuring the names, drawing them, and then
    // discovering there is nowhere to put "+40" - which either overflows the
    // row or silently drops the only sign that there is more.
    const set = candidates(keymap.default_bindings, "");
    const items = set.slice();
    const width = 80;
    const s = fit(items, 0, width);
    try testing.expect(s.more > 0);

    var used: usize = 0;
    for (s.from..s.to) |i| {
        used += items[i].len;
        if (i != s.from) used += gap;
    }
    var buf: [8]u8 = undefined;
    const tail = try std.fmt.bufPrint(&buf, " +{d}", .{s.more});
    try testing.expect(used + tail.len <= width);
}
