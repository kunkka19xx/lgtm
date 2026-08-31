// SPDX-License-Identifier: Apache-2.0
//
// The empty screen: what a review with nothing in it says.
//
// This is not a rare state. A pane running beside an agent sits here every
// time the tree is clean, which is most of the day and all of the time before
// the agent has written anything, so it is the screen the tool is looked at on
// most and it was one dim sentence in a corner. It says what the thing is,
// which version of it is running and whose it is, and then how to find the
// keys - and nothing else, because a screen that appears this often earns
// its space by being quiet.
//
// No state and no input of its own: the wordmark comes from the icon set
// (`ui/theme.zig`), the key comes from the keymap, and the geometry is a pure
// function so the awkward pane sizes are testable without a terminal.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");
const build_options = @import("build_options");

const frame_mod = @import("frame.zig");
const Frame = frame_mod.Frame;
const keymap = @import("keymap.zig");
const theme_mod = @import("theme.zig");
const keytext = @import("keytext.zig");

/// From `build.zig.zon` by way of a build option, which is the same string
/// `--version` prints: two places saying the version is one place too many.
pub const version = build_options.version;

/// Whose it is. Hardcoded rather than read from `git config`: it is the
/// author of `lgtm`, not whoever happens to be running it.
pub const author = "kunkka19xx";

/// Where the name goes when it is clicked. An OSC 8 hyperlink rather than a
/// printed URL: the address is noise on a screen this small, and a terminal
/// that cannot follow it shows the name exactly as it would have anyway.
pub const author_url = "https://github.com/" ++ author;

/// Rows the block needs under the wordmark: a blank, the byline, a blank, the
/// state, and where the keys are.
const under: u16 = 5;

pub const Place = struct { top: u16, left: u16 };

/// Where the block sits, or null when the pane cannot hold it and the one
/// line is all there is room for.
///
/// Pure, because this is the part that goes wrong: hard rule 9 asks for 80
/// columns, but a split pane is dragged through every width on the way there
/// and the wordmark must clip to a sentence rather than spill over the edge.
pub fn place(win_w: u16, win_h: u16, art_w: u16, art_h: u16) ?Place {
    const rows = art_h +| under;
    if (win_w < art_w or win_h < rows) return null;
    return .{ .top = (win_h - rows) / 2, .left = (win_w - art_w) / 2 };
}

pub fn draw(f: Frame, bindings: []const keymap.Binding) Allocator.Error!void {
    const art = f.glyphs.wordmark;

    // Display width, never byte length: the block-element rows are three
    // bytes a column and the thumb is one column wider than it looks.
    var art_w: u16 = 0;
    for (art) |row| art_w = @max(art_w, f.win.gwidth(row));

    const at = place(f.width(), f.win.height, art_w, @intCast(art.len)) orelse {
        f.put(0, 0, " lgtm: no changes against HEAD", f.theme.dim);
        return;
    };

    // One left edge for every row: the wordmark is one picture, and centring
    // each row on its own width would shear the thumb off the M.
    for (art, 0..) |row, i| f.put(at.top + @as(u16, @intCast(i)), at.left, row, f.theme.accent);

    // Two draws rather than one, so the name carries the link and the version
    // does not. Centred on the pair: the link is part of the line, not a
    // thing appended to it.
    var row = at.top + @as(u16, @intCast(art.len)) + 1;
    const lead = try std.fmt.allocPrint(f.arena, "{s} {s} ", .{ version, f.glyphs.sep });
    const lead_w = f.win.gwidth(lead);
    const byline = lead_w + f.win.gwidth(author);
    const col: u16 = if (byline >= f.width()) 0 else (f.width() - byline) / 2;
    f.put(row, col, lead, f.theme.dim);
    f.putLink(row, col + lead_w, author, f.theme.accent, author_url);

    row += 2;
    _ = try centre(f, row, f.theme.text, "no changes against HEAD", .{});

    // The key rather than a `?`: a remapped keymap has to document itself
    // (FEATURES.md 4.7), and this screen is the only place a reader who has
    // not opened the popup yet can learn how to.
    row += 1;
    var buf: [32]u8 = undefined;
    if (keyFor(bindings, .help, &buf)) |key| {
        _ = try centre(f, row, f.theme.dim, "{s} for keys", .{key});
    }
}

/// How a command is typed, or null when nothing is bound to it.
fn keyFor(bindings: []const keymap.Binding, cmd: keymap.Command, buf: []u8) ?[]const u8 {
    for (bindings) |b| {
        if (b.command == cmd) return keytext.bufWriteChords(b.chords, buf);
    }
    return null;
}

fn centre(
    f: Frame,
    row: u16,
    style: vaxis.Style,
    comptime fmt: []const u8,
    args: anytype,
) Allocator.Error!u16 {
    const text = try std.fmt.allocPrint(f.arena, fmt, args);
    const w = f.win.gwidth(text);
    const col: u16 = if (w >= f.width()) 0 else (f.width() - w) / 2;
    f.put(row, col, text, style);
    return w;
}

const testing = std.testing;

test "the author and the link cannot be renamed apart" {
    // The url is built from the name, so this is really a test that it stays
    // built from it rather than being pasted in beside it and left behind.
    try testing.expect(std.mem.endsWith(u8, author_url, author));
    try testing.expect(std.mem.startsWith(u8, author_url, "https://"));
}

test "the block is centred when it fits" {
    // 80x24, which is the pane hard rule 9 is about.
    const at = place(80, 24, 40, 6).?;
    try testing.expectEqual(@as(u16, 20), at.left);
    try testing.expectEqual(@as(u16, 6), at.top);
    // Centred means the same margin either side, give or take the odd column.
    try testing.expectEqual(@as(u16, 80), at.left + 40 + at.left);
    try testing.expectEqual(@as(u16, 24), at.top + (6 + under) + at.top + 1);
}

test "a pane too narrow or too short gets the sentence instead" {
    // One column short of the wordmark is one column too few: it would spill.
    try testing.expect(place(39, 24, 40, 6) == null);
    try testing.expect(place(40, 24, 40, 6) != null);
    // And a pane with no room under it for the byline and the hint.
    try testing.expect(place(80, 10, 40, 6) == null);
    try testing.expect(place(80, 11, 40, 6) != null);
    // The degenerate sizes a drag passes through resolve rather than trap.
    try testing.expect(place(0, 0, 40, 6) == null);
    try testing.expect(place(1, 1, 26, 5) == null);
}

test "every wordmark row is the same width, or the picture shears" {
    // The ascii set is 7-bit, which the purity test in `theme.zig` asserts,
    // so byte length is display width and the rows can be compared directly.
    const ascii = theme_mod.Glyphs.ascii.wordmark;
    try testing.expect(ascii.len > 0);
    for (ascii) |r| try testing.expectEqual(ascii[0].len, r.len);

    // The unicode rows are not, and byte length is no proxy for them: a block
    // element is three bytes a column and a space is one, so the row with the
    // most gaps is the shortest in bytes while being the same width. Count
    // codepoints, which is display width for every glyph in the set but the
    // thumb - the one deliberate overhang.
    const uni = theme_mod.Glyphs.unicode.wordmark;
    try testing.expectEqual(@as(usize, 6), uni.len);
    for (uni, 0..) |r, i| {
        const cols = try std.unicode.utf8CountCodepoints(r);
        try testing.expectEqual(@as(usize, if (i == 2) 39 else 37), cols);
    }
}

test "the ascii wordmark fits a pane the unicode one does not" {
    // 26 columns against 40, measured in `theme.zig`: the fallback is not
    // only tofu-free, it is the one that still fits a narrow split.
    try testing.expect(place(30, 24, 40, 6) == null);
    try testing.expect(place(30, 24, 26, 5) != null);
}
