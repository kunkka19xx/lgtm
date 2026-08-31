// SPDX-License-Identifier: Apache-2.0
//
// Fitting a path into a column count without losing the part that identifies
// it.
//
// A terminal clips from the right for free, and for a path that removes
// exactly the wrong end. Eight rows reading
// `apps/macos/LauncherApp/look-app/Views/Launcher/LauncherVi` are the same
// row eight times: the directories they share are all that survived, and the
// name that told them apart is what fell off. The file name is the answer to
// "which file is this", so it is the last thing to go, not the first.
//
// Pure over bytes and a width method, so the awkward cases - a name longer
// than the box, a budget of two columns, a path that is nothing but a name -
// are tested without a pane to draw in.

const std = @import("std");
const Allocator = std.mem.Allocator;

const wrap = @import("wrap.zig");

/// `text` fitted into `max` display columns, keeping the file name.
///
/// The head of the path is what gets spent: `apps/macos/…/Launcher/View.swift`
/// keeps the reader oriented about where in the tree they are while still
/// answering which file it is. When even the name will not fit, the name
/// itself is elided in the middle rather than from one end, because names
/// that collide usually collide at one end - `LauncherView.swift` beside
/// `LauncherViewModel.swift` differ only in the middle.
pub fn elide(
    arena: Allocator,
    text: []const u8,
    max: u16,
    ell: []const u8,
    method: wrap.Method,
) Allocator.Error![]const u8 {
    if (wrap.columns(text, method) <= max) return text;

    const ell_w = wrap.columns(ell, method);
    // No room to say anything was left out: a bare clip is the honest answer,
    // and an ellipsis that fills the whole budget says nothing at all.
    if (max <= ell_w) return text[0..wrap.fitFront(text, max, method)];

    const keep = max - ell_w;
    const name = std.fs.path.basename(text);
    const name_w = wrap.columns(name, method);

    // The name fits with a column or more left for the head, so the head is
    // what is spent.
    if (name_w < keep) {
        const head = keep - name_w;
        const cut = wrap.fitFront(text, head, method);
        return std.mem.concat(arena, u8, &.{ text[0..cut], ell, name });
    }

    // The name alone is the whole budget or more: elide the name in the
    // middle and drop the directories entirely, since a directory the reader
    // cannot finish reading is worth less than the name they can.
    const front = keep / 2;
    const back = keep - front;
    const a = wrap.fitFront(name, front, method);
    const b = wrap.fitBack(name, back, method);
    return std.mem.concat(arena, u8, &.{ name[0..a], ell, name[b..] });
}

const testing = std.testing;
const test_method: wrap.Method = .unicode;

fn check(text: []const u8, max: u16) ![]const u8 {
    return elide(testing.allocator, text, max, "\u{2026}", test_method);
}

test "a path that fits is untouched" {
    const p = "src/ui/path.zig";
    try testing.expectEqualStrings(p, try check(p, 40));
    // Exactly the budget is still a fit: the ellipsis is for what does not.
    try testing.expectEqualStrings(p, try check(p, 15));
}

test "the file name survives and the directories are spent" {
    const p = "apps/macos/LauncherApp/look-app/Views/Launcher/LauncherView.swift";
    const out = try check(p, 40);
    defer testing.allocator.free(out);

    // The name is the answer to "which file is this", so it is intact.
    try testing.expect(std.mem.endsWith(u8, out, "LauncherView.swift"));
    // And the reader still knows roughly where in the tree they are.
    try testing.expect(std.mem.startsWith(u8, out, "apps/"));
    try testing.expectEqual(@as(u16, 40), wrap.columns(out, test_method));
}

test "two paths that differ only in the name stay different" {
    // The bug this exists for: a right-hand clip left eight rows reading the
    // same directories and nothing else.
    const a = try check("apps/macos/LauncherApp/Views/Launcher/LauncherView.swift", 36);
    defer testing.allocator.free(a);
    const b = try check("apps/macos/LauncherApp/Views/Launcher/LauncherViewModel.swift", 36);
    defer testing.allocator.free(b);
    try testing.expect(!std.mem.eql(u8, a, b));
}

test "a name too long for the budget is elided in its middle, not its end" {
    // Names that collide usually collide at one end, so keeping both ends is
    // what keeps them apart.
    const out = try check("dir/AVeryLongSwiftFileNameIndeed.swift", 20);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "AVery"));
    try testing.expect(std.mem.endsWith(u8, out, ".swift"));
    try testing.expect(wrap.columns(out, test_method) <= 20);
}

test "a budget too small for an ellipsis clips rather than saying nothing" {
    const out = try check("apps/macos/Thing.swift", 1);
    try testing.expectEqualStrings("a", out);
}

test "the result never exceeds the budget, at any width" {
    const p = "apps/macos/LauncherApp/look-app/Views/Launcher/LauncherView.swift";
    var max: u16 = 1;
    while (max < 70) : (max += 1) {
        const out = try check(p, max);
        defer if (out.ptr != p.ptr) testing.allocator.free(out);
        try testing.expect(wrap.columns(out, test_method) <= max);
    }
}

test "the ascii ellipsis is three columns and still fits" {
    const p = "apps/macos/LauncherApp/Views/LauncherView.swift";
    const out = try elide(testing.allocator, p, 30, "...", test_method);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.endsWith(u8, out, "LauncherView.swift"));
    try testing.expect(wrap.columns(out, test_method) <= 30);
}
