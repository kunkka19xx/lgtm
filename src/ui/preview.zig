// SPDX-License-Identifier: Apache-2.0
//
// `--theme-preview`: every bundled theme drawn as a few rows of diff, so a
// theme can be chosen without restarting the tool once per candidate
// (FEATURES.md 4.1).
//
// Written straight to stdout as SGR rather than through vaxis: this runs
// before any terminal setup, and a preview that needed the alt screen would
// have to tear it down between themes. It is also the only place in the code
// that emits an escape sequence by hand, which is why the encoder below is
// the whole of it - the renderer proper never sees one.

const std = @import("std");
const theme_mod = @import("theme.zig");
const Style = theme_mod.Style;
const Theme = theme_mod.Theme;

/// One sample line of "source", styled the way the lexer would have styled it.
/// Hand-composed rather than lexed: the point is to show the slots, and a
/// preview that depended on the lexer would show whatever it happened to do
/// with the sample rather than what the theme does with a token kind.
const Piece = struct {
    text: []const u8,
    slot: enum { text, keyword, type_name, fn_name, string, number, comment, punct },
};

const sample: []const []const Piece = &.{
    &.{
        .{ .text = "pub fn ", .slot = .keyword },
        .{ .text = "validate", .slot = .fn_name },
        .{ .text = "(token: ", .slot = .punct },
        .{ .text = "[]const u8", .slot = .type_name },
        .{ .text = ") ", .slot = .punct },
        .{ .text = "bool", .slot = .type_name },
        .{ .text = " {", .slot = .punct },
    },
    &.{
        .{ .text = "    // the old check, kept for now", .slot = .comment },
    },
    &.{
        .{ .text = "    ", .slot = .text },
        .{ .text = "if", .slot = .keyword },
        .{ .text = " (token.len < ", .slot = .punct },
        .{ .text = "32", .slot = .number },
        .{ .text = ") ", .slot = .punct },
        .{ .text = "return ", .slot = .keyword },
        .{ .text = "false", .slot = .keyword },
        .{ .text = ";", .slot = .punct },
    },
    &.{
        .{ .text = "    ", .slot = .text },
        .{ .text = "return ", .slot = .keyword },
        .{ .text = "std.mem.startsWith(u8, token, ", .slot = .text },
        .{ .text = "\"lgtm_\"", .slot = .string },
        .{ .text = ");", .slot = .punct },
    },
};

/// Which sample rows are added, removed, or context - one of each, plus the
/// cursor sitting on the added line, because that is the combination a reader
/// actually looks at.
const marks: []const enum { context, del, add, cursor_add } = &.{ .context, .del, .cursor_add, .add };

pub fn write(w: *std.Io.Writer, glyphs: theme_mod.Glyphs) std.Io.Writer.Error!void {
    for (theme_mod.bundled) |b| {
        const t = theme_mod.fromPalette(b.palette);
        try w.writeByte('\n');
        try w.writeAll("  ");
        try styled(w, t.accent, b.name);
        try w.writeByte('\n');
        try block(w, t, glyphs);
    }
    try w.writeAll(
        \\
        \\Set one with `[theme] name = "..."` in ~/.config/lgtm/config.toml,
        \\or try one now with `lgtm --theme <name>`.
        \\
    );
}

fn block(w: *std.Io.Writer, t: Theme, g: theme_mod.Glyphs) std.Io.Writer.Error!void {
    // Status row: the path, the counts, the hunk id - every slot the top line
    // of the real screen uses.
    try w.writeAll("  ");
    try styled(w, t.path, "src/auth.zig");
    try styled(w, t.dim, " ");
    try styled(w, t.rule, g.sep);
    try styled(w, t.dim, " 1/3 ");
    try styled(w, t.rule, g.sep);
    try styled(w, t.added_count, " +12 ");
    try sgr(w, t.removed_count);
    try w.print("{s}4", .{g.del});
    try w.writeAll("\x1b[0m");
    try w.writeByte('\n');

    try w.writeAll("  ");
    try styled(w, t.hunk_id, "@@ #2 ");
    try styled(w, t.rule, g.sep);
    try styled(w, t.dim, " validate ");
    try styled(w, t.rule, g.sep);
    try styled(w, t.dim, " 41-48 @@");
    try w.writeByte('\n');

    for (sample, marks, 41..) |pieces, mark, no| {
        const bg: ?theme_mod.Color = switch (mark) {
            .cursor_add => t.cursor_line.bg,
            else => null,
        };
        const sign = switch (mark) {
            .context => g.context,
            .del => g.del,
            else => g.add,
        };
        const sign_style = switch (mark) {
            .context => t.dim,
            .del => t.del_sign,
            else => t.add_sign,
        };
        try w.writeAll("  ");
        try styled(w, on(sign_style, bg), sign);
        try sgr(w, on(t.line_no, bg));
        try w.print(" {d} ", .{no});
        try w.writeAll("\x1b[0m");
        for (pieces) |p| {
            try styled(w, on(slotStyle(t, p.slot), bg), p.text);
        }
        // The cursor line is a full-width fill on the real screen, so the
        // preview pads it out rather than ending the highlight at the text.
        if (bg != null) try styled(w, on(t.text, bg), "                    ");
        try w.writeByte('\n');
    }

    // Mode row: the badge, a hint, and the search hit that has to survive
    // being drawn over any of the above.
    try w.writeAll("  ");
    try styled(w, t.mode_badge, " NORMAL ");
    try styled(w, t.hint, "  j k move  ]h [h hunk  ");
    try styled(w, t.search_match, "match");
    try styled(w, t.hint, "  ");
    try styled(w, t.notice, "wrapped to first file");
    try w.writeByte('\n');
}

fn slotStyle(t: Theme, slot: anytype) Style {
    return switch (slot) {
        .text => t.text,
        .keyword => t.keyword,
        .type_name => t.type_name,
        .fn_name => t.fn_name,
        .string => t.string,
        .number => t.number,
        .comment => t.comment,
        .punct => t.punct,
    };
}

fn on(style: Style, bg: ?theme_mod.Color) Style {
    var out = style;
    if (bg) |b| out.bg = b;
    return out;
}

/// `text` in `style`, as one SGR run. Public because `ui/splash.zig` writes
/// the `-v` banner to the same stdout by the same rule: this file is the only
/// one that encodes an escape sequence by hand.
pub fn styled(w: *std.Io.Writer, style: Style, text: []const u8) std.Io.Writer.Error!void {
    try sgr(w, style);
    try w.writeAll(text);
    try w.writeAll("\x1b[0m");
}

/// A `Style` as one SGR sequence. Resets first, so no row inherits the
/// previous one's attributes - a preview whose colours depend on what was
/// printed above it is not a preview.
fn sgr(w: *std.Io.Writer, style: Style) std.Io.Writer.Error!void {
    try w.writeAll("\x1b[0");
    if (style.bold) try w.writeAll(";1");
    if (style.dim) try w.writeAll(";2");
    if (style.italic) try w.writeAll(";3");
    if (style.ul_style != .off) try w.writeAll(";4");
    if (style.reverse) try w.writeAll(";7");
    try colour(w, style.fg, false);
    try colour(w, style.bg, true);
    try w.writeAll("m");
}

fn colour(w: *std.Io.Writer, c: theme_mod.Color, bg: bool) std.Io.Writer.Error!void {
    const base: u8 = if (bg) 40 else 30;
    switch (c) {
        .default => {},
        .index => |i| switch (i) {
            0...7 => try w.print(";{d}", .{base + i}),
            // The bright eight are 90-97 and 100-107, not 38;5;n - terminals
            // that remap their palette expect the short form for those.
            8...15 => try w.print(";{d}", .{base + 60 + (i - 8)}),
            else => try w.print(";{d};5;{d}", .{ base + 8, i }),
        },
        .rgb => |v| try w.print(";{d};2;{d};{d};{d}", .{ base + 8, v[0], v[1], v[2] }),
    }
}

const testing = std.testing;

test "a style comes out as one escape sequence" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try sgr(&w, .{ .fg = .{ .rgb = .{ 0xa6, 0xe3, 0xa1 } }, .bold = true });
    try testing.expectEqualStrings("\x1b[0;1;38;2;166;227;161m", w.buffered());
}

test "indexed colours use the short forms a terminal palette applies to" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // 0-7 and 8-15 must not go out as 38;5;n: a terminal remapping its own
    // sixteen colours - which is the whole point of the terminal-native
    // theme - applies that remapping to the short forms.
    try sgr(&w, .{ .fg = .{ .index = 2 }, .bg = .{ .index = 9 } });
    try testing.expectEqualStrings("\x1b[0;32;101m", w.buffered());

    var buf2: [128]u8 = undefined;
    var w2: std.Io.Writer = .fixed(&buf2);
    try sgr(&w2, .{ .bg = .{ .index = 236 } });
    try testing.expectEqualStrings("\x1b[0;48;5;236m", w2.buffered());
}

test "every bundled theme draws without running out of buffer" {
    var buf: [64 << 10]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try write(&w, theme_mod.Glyphs.unicode);
    // Each theme names itself, which is what the reader picks from.
    for (theme_mod.bundled) |b| {
        try testing.expect(std.mem.indexOf(u8, w.buffered(), b.name) != null);
    }
}
