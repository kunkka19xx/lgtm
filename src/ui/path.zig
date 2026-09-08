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

/// A move, written the way `git diff --stat` writes one:
/// `src/{old => new}/thing.zig` rather than the two paths in full.
///
/// The common head and tail are what the reader already knows - they are
/// looking at one file that went somewhere - so spending the pane on them
/// twice says nothing. The braces hold what actually changed, which for the
/// overwhelmingly common case is one directory name.
///
/// Both ends are cut at a '/', which is what makes the four shapes come out
/// the way git's do, checked against git rather than guessed at:
///
///   src/old/thing.zig  -> src/new/thing.zig  ->  src/{old => new}/thing.zig
///   src/ui/app.zig     -> src/app.zig        ->  src/{ui => }/app.zig
///   src/thing.zig      -> src/other.zig      ->  src/{thing.zig => other.zig}
///   a.txt              -> b.md               ->  a.txt => b.md
///
/// The third is why the tail is cut at a separator and not merely at the last
/// matching byte: `thing.zig` and `other.zig` share `.zig`, and
/// `src/{thing => other}.zig` claims a rename of the stem when what changed is
/// the name. The fourth is why nothing shared means no braces - `{a => b}`
/// around whole paths is the same two paths with punctuation added.
/// `text` fitted into `max` columns by dropping whole segments off the
/// *front*, the way `git diff --stat` shortens a move.
///
/// The opposite end from `elide`, and for a different job. A path is elided
/// towards its name because the name answers "which file"; a move is elided
/// towards its braces because the braces are the only part that is not already
/// in the header above it - and a `{` with its `}` cut off reads as a bug
/// rather than as a shortening.
///
/// Cut at separators so a directory name is never half shown. When even the
/// last segment will not fit there is nothing structural left to protect, so
/// it defers to `elide`.
pub fn elideFront(
    arena: Allocator,
    text: []const u8,
    max: u16,
    ell: []const u8,
    method: wrap.Metrics,
) Allocator.Error![]const u8 {
    if (wrap.columns(text, method) <= max) return text;
    const ell_w = wrap.columns(ell, method);
    if (max <= ell_w) return elide(arena, text, max, ell, method);

    var at: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, at, '/')) |slash| {
        at = slash + 1;
        if (ell_w + wrap.columns(text[at..], method) <= max) {
            return std.fmt.allocPrint(arena, "{s}{s}", .{ ell, text[at..] });
        }
    }
    return elide(arena, text, max, ell, method);
}

/// `text` fitted into `max` columns by dropping the *tail*, which is what a
/// terminal would have done anyway.
///
/// For a row that is not a path. `elide` protects the file name by eating the
/// middle, and a composed row - `%604  lgtm:1.0  claude  fixing the parser` -
/// has no file name to protect: eating its middle takes the columns that made
/// it a table and leaves `%604  lgtm:1.0…fixing the parser`, which is worse
/// than a clean cut. The front is where the identity is, so the front stays.
pub fn clip(
    arena: Allocator,
    text: []const u8,
    max: u16,
    ell: []const u8,
    method: wrap.Metrics,
) Allocator.Error![]const u8 {
    if (wrap.columns(text, method) <= max) return text;
    const ell_w = wrap.columns(ell, method);
    if (max <= ell_w) return text[0..wrap.fitFront(text, max, method)];
    const keep = wrap.fitFront(text, max - ell_w, method);
    return std.fmt.allocPrint(arena, "{s}{s}", .{ text[0..keep], ell });
}

pub fn moved(arena: Allocator, old: []const u8, new: []const u8) Allocator.Error![]const u8 {
    const head = commonHead(old, new);
    const tail = commonTail(old, new);
    if (head == 0 and tail == 0) {
        return std.fmt.allocPrint(arena, "{s} => {s}", .{ old, new });
    }
    // The two ends can reach past each other when one path is a prefix of the
    // other's directories - `src/ui/app.zig` against `src/app.zig` shares
    // `src/` at the front and `/app.zig` at the back, which is more than the
    // shorter path has. The middle is then empty on that side, which is
    // exactly what git prints.
    const old_mid = old[head..@max(head, old.len - tail)];
    const new_mid = new[head..@max(head, new.len - tail)];
    return std.fmt.allocPrint(arena, "{s}{{{s} => {s}}}{s}", .{
        old[0..head],
        old_mid,
        new_mid,
        old[old.len - tail ..],
    });
}

/// Bytes the two share from the front, cut at the last '/' so a partial
/// directory name is never left inside the braces: `src/older` and `src/old`
/// share `src/o`, and `src/o{lder => ld}` reads as a typo.
fn commonHead(a: []const u8, b: []const u8) usize {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    var cut: usize = 0;
    while (i < n and a[i] == b[i]) : (i += 1) {
        if (a[i] == '/') cut = i + 1;
    }
    return cut;
}

/// The same from the back, and zero when the shared tail holds no separator at
/// all - two names in one directory differ over the whole name, extension
/// included.
fn commonTail(a: []const u8, b: []const u8) usize {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    var cut: usize = 0;
    while (i < n and a[a.len - 1 - i] == b[b.len - 1 - i]) : (i += 1) {
        if (a[a.len - 1 - i] == '/') cut = i + 1;
    }
    return cut;
}

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
    method: wrap.Metrics,
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
const test_method: wrap.Metrics = .{ .method = .unicode };

fn check(text: []const u8, max: u16) ![]const u8 {
    return elide(testing.allocator, text, max, "\u{2026}", test_method);
}

test "a composed row loses its tail, not the columns that made it a table" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const row = "%604  lgtm:1.0  fixing the json lexer";

    // Fits: returned untouched, and the same bytes rather than a copy.
    const whole = try clip(arena, row, 40, "...", test_method);
    try std.testing.expectEqualStrings(row, whole);

    // Does not fit: the front - which is what identifies the pane - survives.
    const cut = try clip(arena, row, 20, "...", test_method);
    try std.testing.expectEqualStrings("%604  lgtm:1.0  f...", cut);

    // `elide` would have eaten the middle instead, taking the columns with
    // it, which is the bug this exists to avoid.
    const wrong = try elide(arena, row, 20, "...", test_method);
    try std.testing.expect(!std.mem.eql(u8, cut, wrong));

    // No room even to say something was left out: a bare clip, no ellipsis.
    const tiny = try clip(arena, row, 2, "...", test_method);
    try std.testing.expectEqualStrings("%6", tiny);
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

test "a move reads the way git writes one" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    // The common case: one directory changed.
    try std.testing.expectEqualStrings(
        "src/{old => new}/thing.zig",
        try moved(arena, "src/old/thing.zig", "src/new/thing.zig"),
    );
    // Renamed in place. The shared `.zig` stays inside the braces: what
    // changed is the name, not the stem, and git writes it this way too.
    try std.testing.expectEqualStrings(
        "src/{thing.zig => other.zig}",
        try moved(arena, "src/thing.zig", "src/other.zig"),
    );
    // Moved up a level: the braces hold a directory on one side and nothing
    // on the other, which is git's own answer for it.
    try std.testing.expectEqualStrings(
        "src/{ui => }/app.zig",
        try moved(arena, "src/ui/app.zig", "src/app.zig"),
    );
    // Nothing shared: braces would only add punctuation.
    try std.testing.expectEqualStrings(
        "a.txt => b.md",
        try moved(arena, "a.txt", "b.md"),
    );
    // A shared prefix that is not a whole directory name must not be split:
    // `older` and `old` share `old`, and `src/o{lder => ld}/x` is nonsense.
    try std.testing.expectEqualStrings(
        "src/{older => old}/x.zig",
        try moved(arena, "src/older/x.zig", "src/old/x.zig"),
    );
}

test "a move too wide for the pane keeps its braces" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const text = "packages/frontend/src/{components/widgets => features/launcher}/View.tsx";
    const cut = try elideFront(arena, text, 60, "…", test_method);

    // Whole segments off the front, and both braces still there - which is
    // what `elide` could not promise, because it protects the name instead.
    try std.testing.expectEqualStrings(
        "…src/{components/widgets => features/launcher}/View.tsx",
        cut,
    );
    try std.testing.expect(std.mem.indexOfScalar(u8, cut, '}') != null);

    // Already short enough: returned untouched, not copied and shortened.
    try std.testing.expectEqualStrings(text, try elideFront(arena, text, 200, "…", test_method));
}
