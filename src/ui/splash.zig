// SPDX-License-Identifier: Apache-2.0
//
// The empty screen: what a review with nothing in it says.
//
// This is not a rare state. A pane running beside an agent sits here every
// time the tree is clean, which is most of the day and all of the time before
// the agent has written anything, so it is the screen the tool is looked at on
// most and it was one dim sentence in a corner. It says what the thing is,
// what it is for, which version of it is running and whose it is, and then
// how to find the keys - and nothing else, because a screen that appears
// this often earns its space by being quiet.
//
// `writeBanner` is the same block written to stdout for `-v`, so the flag and
// the pane are one identity rather than two that drift.
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
const path_mod = @import("path.zig");
const theme_mod = @import("theme.zig");
const keytext = @import("keytext.zig");
const preview = @import("preview.zig");
const wrap = @import("wrap.zig");

/// From `build.zig.zon` by way of a build option, which is the same string
/// `--version` prints: two places saying the version is one place too many.
pub const version = build_options.version;

/// The version as it is shown. Prefixed here rather than in the manifest,
/// which has to hold a bare semver for the package manager: `v0.0.0` reads as
/// a version and `0.0.0` beside a name reads as a count.
pub const version_label = "v" ++ version;

/// Whose it is. Hardcoded rather than read from `git config`: it is the
/// author of `lgtm`, not whoever happens to be running it.
pub const author = "kunkka19xx";

/// Where the name goes when it is clicked. An OSC 8 hyperlink rather than a
/// printed URL: the address is noise on a screen this small, and a terminal
/// that cannot follow it shows the name exactly as it would have anyway.
pub const author_url = "https://github.com/" ++ author;

/// Built from the author's, so a rename cannot leave one of them behind.
pub const repo_url = author_url ++ "/lgtm";

/// The same address without the scheme, for a terminal with no room for the
/// whole one. Eight columns shorter, still a link to any terminal that finds
/// them, and still the address if it is typed out by hand.
pub const repo_short = "github.com/" ++ author ++ "/lgtm";

/// What the tool is for, in the one sentence the name is a joke about. Worded
/// and punctuated as the README's subtitle: the pitch is one sentence, and two
/// copies of it that differ is two pitches.
pub const tagline = "Read what your agent wrote - before you say LGTM.";

/// Rows the block needs under the wordmark: a blank, the byline, a blank, the
/// state, and where the keys are. The tagline is the sixth when the pane is
/// wide enough to hold the sentence whole - clipped it says something else.
const under: u16 = 5;

pub const Place = struct { top: u16, left: u16 };

/// Where the block sits, or null when the pane cannot hold it and the one
/// line is all there is room for.
///
/// Pure, because this is the part that goes wrong: hard rule 9 asks for 80
/// columns, but a split pane is dragged through every width on the way there
/// and the wordmark must clip to a sentence rather than spill over the edge.
pub fn place(win_w: u16, win_h: u16, art_w: u16, art_h: u16, extra: u16) ?Place {
    const rows = art_h +| under +| extra;
    if (win_w < art_w or win_h < rows) return null;
    return .{ .top = (win_h - rows) / 2, .left = (win_w - art_w) / 2 };
}

/// What the empty screen is empty *for*. A clean tree and a directory that is
/// not a repository both draw nothing, and they are not the same thing to be
/// looking at: one means the agent has not written yet, the other means it
/// never will here.
pub const clean = "no changes against HEAD";
pub const no_repo = "not a git repository";

/// What to do about it, and deliberately not just "run git init".
///
/// Being in the wrong directory is the likelier reason to be reading this than
/// having meant to review an uninitialised one, and telling someone to `git
/// init` in the directory they landed in by accident is advice that leaves a
/// repository behind in it. The line offers both readings and presumes
/// neither; the path above it is what settles which one applies.
pub const no_repo_hint = "cd to a repository, or git init here";

pub fn draw(
    f: Frame,
    bindings: []const keymap.Binding,
    state: []const u8,
    /// Where the reader is, when saying so helps. Null on a clean tree, where
    /// the directory is not in question and a path would be noise.
    where: ?[]const u8,
    hint: ?[]const u8,
) Allocator.Error!void {
    const art = f.glyphs.wordmark;

    // Display width, never byte length: the block-element rows are three
    // bytes a column and the thumb is one column wider than it looks.
    var art_w: u16 = 0;
    for (art) |row| art_w = @max(art_w, f.win.gwidth(row));

    // The sentence is what the name means, so it is dropped whole or not at
    // all: half of it clipped at the edge reads as a different claim.
    const tag = f.win.gwidth(tagline) <= f.width();

    // The extra rows the two optional lines need, so a short pane drops the
    // wordmark rather than drawing over its own byline.
    const extra: u16 = @intFromBool(tag) +
        @as(u16, @intFromBool(where != null)) + @as(u16, @intFromBool(hint != null));
    const at = place(f.width(), f.win.height, art_w, @intCast(art.len), extra) orelse {
        // One line is all there is room for, so it is the one that says what
        // is wrong. The path and the hint are help, and help is what a pane
        // this small has no room for.
        f.put(0, 0, try std.fmt.allocPrint(f.arena, " lgtm: {s}", .{state}), f.theme.dim);
        return;
    };

    // One left edge for every row: the wordmark is one picture, and centring
    // each row on its own width would shear the thumb off the M.
    for (art, 0..) |row, i| f.put(at.top + @as(u16, @intCast(i)), at.left, row, f.theme.accent);

    var row = at.top + @as(u16, @intCast(art.len)) + 1;
    if (tag) {
        _ = try centre(f, row, f.theme.dim, "{s}", .{tagline});
        row += 1;
    }

    // Two draws rather than one, so the name carries the link and the version
    // does not. Centred on the pair: the link is part of the line, not a
    // thing appended to it.
    const lead = try std.fmt.allocPrint(f.arena, "{s} {s} ", .{ version_label, f.glyphs.sep });
    const lead_w = f.win.gwidth(lead);
    const byline = lead_w + f.win.gwidth(author);
    const col: u16 = if (byline >= f.width()) 0 else (f.width() - byline) / 2;
    f.put(row, col, lead, f.theme.dim);
    f.putLink(row, col + lead_w, author, f.theme.accent, author_url);

    row += 2;
    _ = try centre(f, row, f.theme.text, "{s}", .{state});

    // The directory, elided from the head so the last component survives -
    // which is the part that answers "am I where I meant to be" (`ui/path.zig`
    // makes the same argument for the file list).
    if (where) |dir| {
        row += 1;
        const shown = try path_mod.elide(f.arena, dir, f.width() -| 4, f.glyphs.ellipsis, f.method());
        _ = try centre(f, row, f.theme.dim, "{s}", .{shown});
    }
    if (hint) |h| {
        row += 1;
        _ = try centre(f, row, f.theme.dim, "{s}", .{h});
    }

    // The key rather than a `?`: a remapped keymap has to document itself
    //, and this screen is the only place a reader who has
    // not opened the popup yet can learn how to.
    row += 1;
    var buf: [32]u8 = undefined;
    if (keyFor(bindings, .help, &buf)) |key| {
        _ = try centre(f, row, f.theme.dim, "{s} for keys", .{key});
    }
}

/// The `-v` banner: the same picture the empty screen draws, written to
/// stdout before any terminal exists.
///
/// Not the screen itself - there is no window at this point and no reason to
/// make one - but the same wordmark, the same byline and the address they
/// belong to, so the flag and the pane look like one tool.
///
/// `cols` is what stdout has to draw in, or null when it is a pipe and there
/// is no edge to wrap at. It is the whole of the narrow-terminal behaviour:
/// the block is fitted to it rather than drawn at a fixed width and left to
/// the terminal's own wrapping, which turns the wordmark into confetti.
/// `colour` is off for a pipe too: this is the output that gets pasted into a
/// bug report.
pub fn writeBanner(
    w: *std.Io.Writer,
    t: theme_mod.Theme,
    g: theme_mod.Glyphs,
    colour: bool,
    cols: ?u16,
) std.Io.Writer.Error!void {
    const margin = 2;
    // A pipe has no width, so nothing has to be fitted to it.
    const width = cols orelse std.math.maxInt(u16);

    // The widest wordmark that fits, then the 26-column fallback, then none:
    // an `M` wrapped onto the next row is not a letter.
    const art: []const []const u8 = if (wordmarkWidth(g) + margin <= width)
        g.wordmark
    else if (wordmarkWidth(theme_mod.Glyphs.ascii) + margin <= width)
        theme_mod.Glyphs.ascii.wordmark
    else
        &.{};

    // The picture is one width, not one per row, for the reason `draw` gives:
    // centring each row on its own would shear the thumb off the M.
    var art_w: u16 = 0;
    for (art) |r| art_w = @max(art_w, wrap.columns(r, .{ .method = .unicode }));

    var buf: [64]u8 = undefined;
    const sep = std.fmt.bufPrint(&buf, " {s} ", .{g.sep}) catch " | ";
    const byline_w = wrap.columns(version_label, .{ .method = .unicode }) +
        wrap.columns(sep, .{ .method = .unicode }) + wrap.columns(author, .{ .method = .unicode });
    // The scheme goes when it is what puts the address over the edge: a
    // wrapped URL is not a link and not copyable in one gesture.
    const url = if (wrap.columns(repo_url, .{ .method = .unicode }) <= width) repo_url else repo_short;
    const url_w = wrap.columns(url, .{ .method = .unicode });

    // Dropped whole rather than wrapped, the same rule the screen follows.
    const tag_w = wrap.columns(tagline, .{ .method = .unicode });
    const tag = tag_w + margin <= width;

    // Everything centres on the widest line rather than on the wordmark: the
    // sentence is longer than the picture, and hanging it off one edge of a
    // block that is otherwise centred reads as a mistake.
    const block = @max(art_w, @max(if (tag) tag_w else 0, @max(byline_w, url_w)));
    // Both the margin and the centring go when the block is what the terminal
    // has, rather than being spent on space that pushes a line over the edge.
    const pad: u16 = if (block + margin <= width) margin else 0;
    const room = width -| pad;

    try w.writeByte('\n');
    for (art) |r| {
        try w.splatByteAll(' ', startCol(pad, block, room, art_w));
        try paint(w, colour, t.accent, r);
        try w.writeByte('\n');
    }
    if (art.len > 0) try w.writeByte('\n');

    if (tag) {
        try w.splatByteAll(' ', startCol(pad, block, room, tag_w));
        try paint(w, colour, t.text, tagline);
        try w.writeAll("\n\n");
    }

    // Three runs rather than one: this is the command someone runs to find
    // out the version, so the version is what is lit and the rest is context.
    try w.splatByteAll(' ', startCol(pad, block, room, byline_w));
    try paint(w, colour, bold(t.accent), version_label);
    try paint(w, colour, t.dim, sep);
    try paint(w, colour, t.dim, author);
    try w.writeByte('\n');

    // Printed rather than hidden behind the name: on the screen the address
    // is noise, but this is the output someone reads to find the repo.
    try w.splatByteAll(' ', startCol(pad, block, room, url_w));
    try paint(w, colour, t.dim, url);
    try w.writeAll("\n\n");
}

/// The column a line of `line_w` starts at. Flush left once the block is
/// wider than the room it has: an indent that pushes a line over the edge
/// costs a wrapped row to buy nothing.
fn startCol(pad: u16, block: u16, room: u16, line_w: u16) u16 {
    if (block > room) return 0;
    return pad + indent(block, line_w);
}

/// Columns that centre `inner` under `outer`, and none when it is the wider
/// of the two - a line pushed left is still readable, a negative one is not.
fn indent(outer: u16, inner: u16) u16 {
    return if (inner >= outer) 0 else (outer - inner) / 2;
}

fn bold(style: theme_mod.Style) theme_mod.Style {
    var out = style;
    out.bold = true;
    return out;
}

/// The wordmark's display width: one width for the picture, not one per row.
fn wordmarkWidth(g: theme_mod.Glyphs) u16 {
    var out: u16 = 0;
    for (g.wordmark) |r| out = @max(out, wrap.columns(r, .{ .method = .unicode }));
    return out;
}

fn paint(
    w: *std.Io.Writer,
    colour: bool,
    style: theme_mod.Style,
    text: []const u8,
) std.Io.Writer.Error!void {
    if (!colour) return w.writeAll(text);
    return preview.styled(w, style, text);
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
    try testing.expect(std.mem.startsWith(u8, repo_url, author_url));
}

test "the banner says what it is, whose it is and where it lives" {
    var buf: [4 << 10]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeBanner(&w, theme_mod.default, theme_mod.Glyphs.unicode, false, null);
    const out = w.buffered();

    try testing.expect(std.mem.indexOf(u8, out, version_label) != null);
    try testing.expect(std.mem.indexOf(u8, out, author) != null);
    try testing.expect(std.mem.indexOf(u8, out, repo_url) != null);
    try testing.expect(std.mem.indexOf(u8, out, tagline) != null);
    for (theme_mod.Glyphs.unicode.wordmark) |r| {
        try testing.expect(std.mem.indexOf(u8, out, r) != null);
    }

    // Piped, there is nothing to interpret the escapes: the output goes into
    // a bug report as the picture it looks like, not as SGR noise.
    try testing.expect(std.mem.indexOfScalar(u8, out, 0x1b) == null);
}

test "the banner colours only when it is going to a terminal" {
    var buf: [4 << 10]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeBanner(&w, theme_mod.default, theme_mod.Glyphs.unicode, true, 80);
    try testing.expect(std.mem.indexOfScalar(u8, w.buffered(), 0x1b) != null);

    // And the ascii set draws it without one block element or emoji, for the
    // terminal that would make tofu of both.
    var plain: [4 << 10]u8 = undefined;
    var pw: std.Io.Writer = .fixed(&plain);
    try writeBanner(&pw, theme_mod.default, theme_mod.Glyphs.ascii, false, null);
    for (pw.buffered()) |b| try testing.expect(b < 0x80);
}

test "the version is what the version command lights up" {
    var buf: [4 << 10]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeBanner(&w, theme_mod.default, theme_mod.Glyphs.unicode, true, 80);
    const out = w.buffered();

    // The run the version is printed in is bold: `-v` is asked because
    // someone wants the number, so the number is not the dim part.
    const at = std.mem.indexOf(u8, out, version_label).?;
    const esc = std.mem.lastIndexOf(u8, out[0..at], "\x1b[").?;
    try testing.expect(std.mem.indexOf(u8, out[esc..at], ";1") != null);
}

test "a narrow terminal gets a banner rather than a wrapped one" {
    // 35 columns: no room for the 38-column wordmark or the 49-column
    // sentence, and the terminal would have wrapped both into confetti.
    var buf: [4 << 10]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeBanner(&w, theme_mod.default, theme_mod.Glyphs.unicode, false, 35);
    const narrow = w.buffered();

    try testing.expect(std.mem.indexOf(u8, narrow, theme_mod.Glyphs.unicode.wordmark[0]) == null);
    try testing.expect(std.mem.indexOf(u8, narrow, theme_mod.Glyphs.ascii.wordmark[0]) != null);
    try testing.expect(std.mem.indexOf(u8, narrow, tagline) == null);
    try testing.expect(std.mem.indexOf(u8, narrow, version_label) != null);
    try noLineOver(narrow, 35);

    // 28: the address loses its scheme rather than its second half.
    var small: [4 << 10]u8 = undefined;
    var sw: std.Io.Writer = .fixed(&small);
    try writeBanner(&sw, theme_mod.default, theme_mod.Glyphs.unicode, false, 28);
    try testing.expect(std.mem.indexOf(u8, sw.buffered(), repo_short) != null);
    try testing.expect(std.mem.indexOf(u8, sw.buffered(), repo_url) == null);
    try noLineOver(sw.buffered(), 28);

    // 24: not even the fallback picture fits, so there is no picture. What
    // is left still answers the question the flag asked.
    var tiny: [4 << 10]u8 = undefined;
    var tw: std.Io.Writer = .fixed(&tiny);
    try writeBanner(&tw, theme_mod.default, theme_mod.Glyphs.unicode, false, 24);
    try testing.expect(std.mem.indexOf(u8, tw.buffered(), theme_mod.Glyphs.ascii.wordmark[0]) == null);
    try testing.expect(std.mem.indexOf(u8, tw.buffered(), version_label) != null);
    try testing.expect(std.mem.indexOf(u8, tw.buffered(), author) != null);
}

/// Every line fits, or the terminal wraps it and the layout was pointless.
/// The address is exempt: below 26 columns there is nothing left to trim.
fn noLineOver(text: []const u8, cols: u16) !void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "github.com") != null) continue;
        try testing.expect(wrap.columns(line, .{ .method = .unicode }) <= cols);
    }
}

test "a line wider than the wordmark is not indented off the left edge" {
    try testing.expectEqual(@as(u16, 0), indent(26, 34));
    try testing.expectEqual(@as(u16, 0), indent(10, 10));
    try testing.expectEqual(@as(u16, 10), indent(38, 18));
}

test "the block is centred when it fits" {
    // 80x24, which is the pane hard rule 9 is about.
    const at = place(80, 24, 40, 6, 0).?;
    try testing.expectEqual(@as(u16, 20), at.left);
    try testing.expectEqual(@as(u16, 6), at.top);
    // Centred means the same margin either side, give or take the odd column.
    try testing.expectEqual(@as(u16, 80), at.left + 40 + at.left);
    try testing.expectEqual(@as(u16, 24), at.top + (6 + under) + at.top + 1);
}

test "a pane too narrow or too short gets the sentence instead" {
    // One column short of the wordmark is one column too few: it would spill.
    try testing.expect(place(39, 24, 40, 6, 0) == null);
    try testing.expect(place(40, 24, 40, 6, 0) != null);
    // And a pane with no room under it for the byline and the hint.
    try testing.expect(place(80, 10, 40, 6, 0) == null);
    try testing.expect(place(80, 11, 40, 6, 0) != null);
    // The degenerate sizes a drag passes through resolve rather than trap.
    try testing.expect(place(0, 0, 40, 6, 0) == null);
    try testing.expect(place(1, 1, 26, 5, 0) == null);

    // The tagline is a row like any other: a pane one short of holding it
    // gets the sentence instead of a block with the bottom cut off.
    try testing.expect(place(80, 11, 40, 6, 1) == null);
    try testing.expect(place(80, 12, 40, 6, 1) != null);
}

test "the tagline is dropped whole rather than clipped" {
    // 49 columns of sentence: it fits the pane hard rule 9 is about, and it
    // does not fit the narrow split the ascii wordmark exists for. Half of
    // "before you say LGTM" is advice nobody asked for.
    const w = wordmarkWidth(theme_mod.Glyphs.unicode);
    try testing.expect(wrap.columns(tagline, .{ .method = .unicode }) > w);
    try testing.expect(wrap.columns(tagline, .{ .method = .unicode }) <= 80);
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
    try testing.expect(place(30, 24, 40, 6, 0) == null);
    try testing.expect(place(30, 24, 26, 5, 0) != null);
}

test "the extra lines are budgeted, so a short pane drops the picture not the point" {
    // `place` gets the row count including the optional lines. Passing the old
    // fixed `extra` would have drawn the path and the hint over the byline on
    // a pane one or two rows short of holding them.
    const art_h: u16 = 6;
    const art_w: u16 = 37;
    const with_two = place(80, 20, art_w, art_h, 3);
    const with_none = place(80, 20, art_w, art_h, 1);
    try testing.expect(with_two != null and with_none != null);
    // The block starts higher when it is taller, and there is a height where
    // the taller one no longer fits and the shorter one still does.
    try testing.expect(with_two.?.top < with_none.?.top);
    try testing.expect(place(80, 13, art_w, art_h, 3) == null);
    try testing.expect(place(80, 13, art_w, art_h, 1) != null);
}

test "the empty screen says which kind of empty it is" {
    // A clean tree and a directory with no repository both draw nothing, and
    // telling them apart is the whole value of the line: one means the agent
    // has not written yet, the other means it never will here. lgtm used to
    // answer the second with a Zig stack trace.
    try testing.expect(!std.mem.eql(u8, clean, no_repo));
    try testing.expect(std.mem.indexOf(u8, no_repo, "git") != null);
    // Both have to survive the one-line fallback on a pane too small for the
    // wordmark, which prefixes them with " lgtm: ".
    try testing.expect(clean.len + 8 < 80);
    try testing.expect(no_repo.len + 8 < 80);
    // The hint offers both readings rather than presuming the reader meant to
    // initialise the directory they are standing in - which, told only to run
    // `git init`, is what someone in the wrong directory would do.
    try testing.expect(std.mem.indexOf(u8, no_repo_hint, "cd") != null);
    try testing.expect(std.mem.indexOf(u8, no_repo_hint, "git init") != null);
}
