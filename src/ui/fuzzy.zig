// SPDX-License-Identifier: Apache-2.0
//
// Narrowing a list as someone types: the `?` overlay's key list and the `F`
// overlay's file list, which want the same two tiers for the same reason.
//
// A run of the query as typed sorts above scattered letters. Without the
// distinction, "file" surfaces "gg first line" next to "next file" and the
// list reads as noise; with it, the rows a reader meant are the rows on top.
// No score beyond those two tiers - with lists this short the original order
// carries more information than a ranking would.

const std = @import("std");

/// How well a row matched, best first. Null - no match at all - is the third
/// case, and the caller drops the row.
pub const Tier = enum { solid, loose };

pub fn match(text: []const u8, query: []const u8) ?Tier {
    if (query.len == 0) return .solid;
    if (contains(text, query)) return .solid;
    if (subsequence(text, query)) return .loose;
    return null;
}

/// Subsequence match, case-insensitive: `nfl` finds "next file". The same
/// shape of matching as every fuzzy finder the user already has, and enough
/// for a list of two dozen rows - there is no ranking, because with a list
/// this short the original order is more useful than a score.
pub fn subsequence(text: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    var qi: usize = 0;
    for (text) |ch| {
        if (std.ascii.toLower(ch) == std.ascii.toLower(query[qi])) {
            qi += 1;
            if (qi == query.len) return true;
        }
    }
    return false;
}

/// The `?` overlay's contents for `mode`, narrowed by `filter`. Bindings with
/// no `desc` are aliases and stay out, exactly as they stay out of the hint
/// strip. The filter runs over the keys as well as the description, so `spc`
/// finds the leader bindings and `ctrl` does not have to be spelled `<C-`.
/// Case-insensitive substring, the stronger half of the match.
pub fn contains(text: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > text.len) return false;
    var i: usize = 0;
    outer: while (i + needle.len <= text.len) : (i += 1) {
        for (needle, 0..) |ch, j| {
            if (std.ascii.toLower(text[i + j]) != std.ascii.toLower(ch)) continue :outer;
        }
        return true;
    }
    return false;
}

const testing = std.testing;

test "fuzzy matching is subsequence, case-insensitive" {
    try testing.expect(subsequence("next file", "nfl"));
    try testing.expect(subsequence("next file", "NEXT"));
    try testing.expect(subsequence("anything", ""));
    try testing.expect(!subsequence("next file", "xn"));

    try testing.expect(contains("next file", "T FI"));
    try testing.expect(!contains("next file", "nfl"));
    // A needle longer than the haystack must not read past the end.
    try testing.expect(!contains("ab", "abc"));
}

test "the tiers rank a run above scattered letters" {
    try testing.expectEqual(Tier.solid, match("next file", "file").?);
    try testing.expectEqual(Tier.loose, match("gg first line", "file").?);
    try testing.expect(match("next hunk", "file") == null);
    // An empty query keeps every row, in the order they came in.
    try testing.expectEqual(Tier.solid, match("anything", "").?);
}
