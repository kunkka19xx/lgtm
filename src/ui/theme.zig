// SPDX-License-Identifier: Apache-2.0
//
// Styles and glyphs, kept apart from the code that draws so a second theme is
// data rather than a branch (FEATURES.md 4.1). A theme is a `Palette` - a
// dozen colours - plus one shared mapping onto the semantic slots the
// renderer asks for, which is what stops seven bundled themes from becoming
// seven chances to get "the accent, recessed" subtly different.
//
// vaxis appears here only for its `Style` and `Color` types. Nothing in this
// file touches a terminal, which is what lets `config.zig` parse a user's
// colours without one.

const std = @import("std");
const vaxis = @import("vaxis");
const lexer = @import("../syntax/lexer.zig");
const palette = @import("palette.zig");

// Re-exported: a caller asking for a theme should not have to know that the
// colours it is built from live next door.
pub const Palette = palette.Palette;
pub const bundled = palette.bundled;

pub const Style = vaxis.Style;
pub const Color = vaxis.Color;

/// Icon set. `ascii` is the `ui.icons = "ascii"` fallback from the mockups
/// (option 1o D): nothing outside 7-bit ASCII, so a bad SSH link or a terminal
/// without the glyphs still renders something correct rather than boxes.
pub const Glyphs = struct {
    /// Vertical separator between status fields.
    sep: []const u8,
    /// Full-width horizontal rule above and below the diff body.
    rule: []const u8,
    /// Narrower rule between two hunks of the same file.
    gap: []const u8,
    add: []const u8,
    del: []const u8,
    context: []const u8,
    /// Opens and closes a hunk header.
    at: []const u8,
    /// Border of the `?` popup. Rounded in unicode, because the popup floats
    /// over the diff and a soft corner reads as "on top of" rather than "cut
    /// out of" (FEATURES.md 4.2 makes the style config later).
    box_h: []const u8,
    box_v: []const u8,
    box_tl: []const u8,
    box_tr: []const u8,
    box_bl: []const u8,
    box_br: []const u8,

    /// A heavier border, for the one overlay that takes the keyboard rather
    /// than merely showing something. The compose box is where the reader is
    /// *writing*, and a box that looks the same as the help popup does not
    /// say so.
    heavy_h: []const u8,
    heavy_v: []const u8,
    heavy_tl: []const u8,
    heavy_tr: []const u8,
    heavy_bl: []const u8,
    heavy_br: []const u8,

    /// Stands in for the part of a path there was no room to draw.
    /// The gutter mark for a line carrying a comment.
    comment_mark: []const u8,

    ellipsis: []const u8,

    /// Whether this set has per-filetype icons to go with it. Only the nerd
    /// set does, because only it can assume the font has them.
    file_icons: bool = false,

    /// The wordmark on the empty screen, one string per row, left edges
    /// aligned. It belongs to the icon set rather than to the theme for the
    /// same reason the box corners do: a terminal that cannot draw block
    /// elements needs a different picture, not a different colour.
    wordmark: []const []const u8,

    pub const unicode: Glyphs = .{
        .sep = "\u{258f}",
        .rule = "\u{2500}",
        .gap = "\u{2500}",
        // U+2212 MINUS SIGN, as drawn in the mockups: it aligns with '+' at
        // the same width where ASCII '-' reads as a hyphen.
        .add = "+",
        .del = "\u{2212}",
        .context = " ",
        .at = "@@",
        .box_h = "\u{2500}",
        .box_v = "\u{2502}",
        .box_tl = "\u{256d}",
        .box_tr = "\u{256e}",
        .box_bl = "\u{2570}",
        .box_br = "\u{256f}",
        // U+250F..U+251B, the heavy box-drawing corners. No rounded heavy
        // exists in Unicode, so the compose box has square corners and the
        // informational overlays keep their soft ones - which reads as the
        // difference it is.
        .heavy_h = "\u{2501}",
        .heavy_v = "\u{2503}",
        .heavy_tl = "\u{250f}",
        .heavy_tr = "\u{2513}",
        .heavy_bl = "\u{2517}",
        .heavy_br = "\u{251b}",
        .comment_mark = "\u{25cf}",
        .ellipsis = "\u{2026}",
        // The README's banner. The thumb overhangs the last column of the
        // `M` rather than being centred under it, which is where it sits in
        // the README and is why the rows are left-aligned to a common edge
        // instead of each being centred on its own width.
        .wordmark = &.{
            "██╗      ██████╗ ████████╗███╗   ███╗",
            "██║     ██╔════╝ ╚══██╔══╝████╗ ████║",
            "██║     ██║  ███╗   ██║   ██╔████╔██║ 👍",
            "██║     ██║   ██║   ██║   ██║╚██╔╝██║",
            "███████╗╚██████╔╝   ██║   ██║ ╚═╝ ██║",
            "╚══════╝ ╚═════╝    ╚═╝   ╚═╝     ╚═╝",
        },
    };

    /// The unicode set plus file-type icons. Everything else is identical:
    /// a Nerd Font patches glyphs *in*, it does not change what a box corner
    /// looks like, and a set that also moved the borders would make `nerd` a
    /// second theme rather than an icon switch.
    pub const nerd: Glyphs = blk: {
        var g = unicode;
        g.file_icons = true;
        break :blk g;
    };

    pub const ascii: Glyphs = .{
        .sep = "|",
        .rule = "-",
        .gap = "-",
        .add = "+",
        .del = "-",
        .context = " ",
        .at = "@@",
        .box_h = "-",
        .box_v = "|",
        .box_tl = "+",
        .box_tr = "+",
        .box_bl = "+",
        .box_br = "+",
        // No heavy glyphs without box drawing, so the weight is carried by a
        // different character instead of a thicker one.
        .heavy_h = "=",
        .heavy_v = "|",
        .heavy_tl = "+",
        .heavy_tr = "+",
        .heavy_bl = "+",
        .heavy_br = "+",
        .comment_mark = "*",
        .ellipsis = "...",
        // No block elements and no emoji: the set exists for the terminal
        // that would draw both as tofu.
        .wordmark = &.{
            " _      ____ _____ __  __ ",
            "| |    / ___|_   _|  \\/  |",
            "| |   | |  _  | | | |\\/| |",
            "| |___| |_| | | | | |  | |",
            "|_____|\\____| |_| |_|  |_|",
        },
    };
};

/// The styles the renderer draws with. Built from a `Palette` rather than
/// written out per theme; the slots are what `[theme]` overrides by name.
pub const Theme = struct {
    /// The palette this theme was built from, kept so that something wanting a
    /// raw hue - a file icon, which is coloured by filetype rather than by any
    /// meaning this file knows about - can ask for one without a slot per
    /// language. Slot overrides do not change it: it is the theme's colours,
    /// not its decisions.
    hues: palette.Palette,

    text: Style,
    comment: Style,
    string: Style,
    number: Style,
    keyword: Style,
    type_name: Style,
    fn_name: Style,
    punct: Style,

    /// The theme's primary. One named slot rather than a colour picked per
    /// call site, so a config file can move every accented thing at once
    /// (FEATURES.md 4.1). Used for the key column of the `?` popup, which read
    /// as commented-out code while it shared `hint`'s grey with `comment`.
    accent: Style,

    /// The `?` popup's box: the accent hue so the border and the key column
    /// read as one object, dimmed so it frames the list instead of competing
    /// with it. A terminal has no opacity; `dim` is the nearest thing to it.
    popup_border: Style,

    /// What happened to a file, in the `F` list. Colour rather than a letter
    /// column: the list is paths, and a second alphabet beside them is one
    /// more thing to learn and one less column for the path. Slots rather than
    /// borrowed styles, so a theme moves them together with everything else.
    /// A file with no status at all: one the review does not contain, listed
    /// by `<Space>d` or opened for reading. Its own slot rather than a status
    /// colour, because it has no status - and rather than `dim`, because a
    /// list of four hundred greys is a list nobody reads.
    file_plain: Style,
    file_added: Style,
    file_deleted: Style,
    file_modified: Style,
    file_renamed: Style,
    file_binary: Style,

    /// Chrome.
    rule: Style,
    dim: Style,
    line_no: Style,
    add_sign: Style,
    del_sign: Style,
    hunk_id: Style,
    /// A comment in the gutter. Three states, three colours: still meant, already
    /// sent, and pointing at code that moved out from under it.
    comment_open: Style,
    comment_sent: Style,
    comment_stale: Style,
    path: Style,
    added_count: Style,
    removed_count: Style,
    mode_badge: Style,
    hint: Style,
    cursor_line: Style,
    /// Visual line select. Distinct from `cursor_line` and drawn under it, so
    /// the cursor stays findable inside its own selection.
    selection: Style,
    /// A `/` hit. Inverted rather than tinted: it has to survive being drawn
    /// over an add row, a del row and a selection.
    search_match: Style,
    /// The `/`, `?` and `:` input line.
    prompt: Style,
    notice: Style,

    /// Style for one token kind. The lexer's `Kind` is the only thing `ui/`
    /// needs to know about `syntax/`.
    pub fn forKind(self: Theme, kind: lexer.Kind) Style {
        return switch (kind) {
            .text => self.text,
            .comment => self.comment,
            .string => self.string,
            .number => self.number,
            .keyword => self.keyword,
            .type_name => self.type_name,
            .fn_name => self.fn_name,
            .punct => self.punct,
        };
    }
};

/// The one mapping from colours to meanings. Written once and shared by every
/// bundled theme, so "the accent, recessed" or "green, emphasised" means the
/// same thing in all of them.
pub fn fromPalette(p: Palette) Theme {
    return .{
        .hues = p,
        .text = .{ .fg = p.fg },
        .comment = .{ .fg = p.muted },
        .string = .{ .fg = p.green },
        .number = .{ .fg = p.yellow },
        .keyword = .{ .fg = p.magenta },
        .type_name = .{ .fg = p.cyan },
        .fn_name = .{ .fg = p.blue },
        .punct = .{ .fg = p.muted },

        .accent = .{ .fg = p.accent, .bold = true },
        .popup_border = .{ .fg = p.accent, .dim = true },

        .file_plain = .{ .fg = p.fg },
        .file_added = .{ .fg = p.green },
        .file_deleted = .{ .fg = p.red },
        // Amber, which is what "orange" is in a palette that has yellow: the
        // file changed rather than arrived or left.
        .file_modified = .{ .fg = p.yellow },
        // A move is neither a gain nor a loss, so it takes neither colour.
        .file_renamed = .{ .fg = p.blue },
        // Nothing to read, so it recedes.
        .file_binary = .{ .fg = p.muted },

        .rule = .{ .fg = p.muted },
        .dim = .{ .fg = p.muted },
        .line_no = .{ .fg = p.muted },
        .add_sign = .{ .fg = p.green, .bold = true },
        .del_sign = .{ .fg = p.red, .bold = true },
        .hunk_id = .{ .fg = p.yellow, .bold = true },
        .comment_open = .{ .fg = p.cyan, .bold = true },
        .comment_sent = .{ .fg = p.muted },
        .comment_stale = .{ .fg = p.red },
        .path = .{ .fg = p.fg, .bold = true },
        .added_count = .{ .fg = p.green },
        .removed_count = .{ .fg = p.red },
        .mode_badge = .{ .fg = p.on_fill, .bg = p.green, .bold = true },
        .hint = .{ .fg = p.muted },
        .cursor_line = .{ .bg = p.cursor_bg },
        .selection = .{ .bg = p.select_bg },
        .search_match = .{ .fg = p.on_fill, .bg = p.yellow },
        .prompt = .{ .fg = p.fg, .bold = true },
        .notice = .{ .fg = p.yellow },
    };
}

/// The `terminal` palette, resolved. Named `default` because that is what
/// every caller means by it.
pub const default: Theme = fromPalette(palette.terminal);

pub const StyleParseError = error{
    /// Not `#rrggbb`, not 0-255, and not a colour name.
    BadColour,
    /// A word that is neither a colour nor an attribute.
    BadAttribute,
    /// `on` with nothing after it.
    MissingColour,
};

/// One slot's style, written the way a config file writes it:
///
///     "#a6e3a1"                  foreground
///     "3"                        a 256-colour index
///     "bright-blue bold"         a name plus attributes
///     "#1e1e2e on #a6e3a1 bold"  foreground, background, attributes
///
/// Deliberately positional-free: words in any order, `on` marking the one
/// colour that is a background. A config file is written by hand, and the
/// order in which someone types "bold" should not matter.
pub fn parseStyle(text: []const u8) StyleParseError!Style {
    var out: Style = .{};
    var want_bg = false;
    var words = std.mem.tokenizeAny(u8, text, " \t");
    while (words.next()) |word| {
        if (std.mem.eql(u8, word, "on")) {
            if (want_bg) return error.MissingColour;
            want_bg = true;
            continue;
        }
        if (parseColour(word)) |col| {
            if (want_bg) {
                out.bg = col;
                want_bg = false;
            } else out.fg = col;
            continue;
        }
        // A word after `on` has to be a colour, and so does anything that was
        // clearly meant as one - `#12345` and `300` are wrong colours, not
        // unknown attributes, and the message has to point at the right half
        // of the line.
        if (want_bg or word[0] == '#' or std.ascii.isDigit(word[0])) return error.BadColour;
        if (std.mem.eql(u8, word, "bold")) {
            out.bold = true;
        } else if (std.mem.eql(u8, word, "dim")) {
            out.dim = true;
        } else if (std.mem.eql(u8, word, "italic")) {
            out.italic = true;
        } else if (std.mem.eql(u8, word, "reverse")) {
            out.reverse = true;
        } else if (std.mem.eql(u8, word, "underline")) {
            out.ul_style = .single;
        } else if (std.mem.eql(u8, word, "strikethrough")) {
            out.strikethrough = true;
        } else return error.BadAttribute;
    }
    if (want_bg) return error.MissingColour;
    return out;
}

const names: []const struct { name: []const u8, index: u8 } = &.{
    .{ .name = "black", .index = 0 },
    .{ .name = "red", .index = 1 },
    .{ .name = "green", .index = 2 },
    .{ .name = "yellow", .index = 3 },
    .{ .name = "blue", .index = 4 },
    .{ .name = "magenta", .index = 5 },
    .{ .name = "cyan", .index = 6 },
    .{ .name = "white", .index = 7 },
};

fn parseColour(word: []const u8) ?Color {
    if (std.mem.eql(u8, word, "default")) return .default;
    if (word.len == 7 and word[0] == '#') {
        var out: [3]u8 = undefined;
        for (&out, 0..) |*byte, i| {
            byte.* = std.fmt.parseInt(u8, word[1 + i * 2 ..][0..2], 16) catch return null;
        }
        return .{ .rgb = out };
    }
    if (std.fmt.parseInt(u8, word, 10)) |n| {
        return .{ .index = n };
    } else |_| {}
    const bright = std.mem.startsWith(u8, word, "bright-");
    const bare = if (bright) word["bright-".len..] else word;
    for (names) |n| {
        if (std.mem.eql(u8, bare, n.name)) return .{ .index = if (bright) n.index + 8 else n.index };
    }
    return null;
}

/// The names `[theme]` accepts that are not field names, from FEATURES.md 4.1.
/// The struct fields say what the renderer draws; these say what a reader
/// reviewing a diff would call it, and both should work.
const aliases: []const struct { from: []const u8, to: []const u8 } = &.{
    .{ .from = "added", .to = "add_sign" },
    .{ .from = "removed", .to = "del_sign" },
    .{ .from = "context", .to = "text" },
    .{ .from = "line_number", .to = "line_no" },
    .{ .from = "hunk_header", .to = "hunk_id" },
};

/// Sets one slot by name, or returns false if there is no such slot - which
/// the caller reports rather than swallowing, because a theme key that does
/// nothing is indistinguishable from a theme that does not work.
pub fn setSlot(t: *Theme, slot: []const u8, style: Style) bool {
    var name = slot;
    for (aliases) |a| {
        if (std.mem.eql(u8, a.from, slot)) name = a.to;
    }
    inline for (@typeInfo(Theme).@"struct".fields) |f| {
        if (f.type == Style and std.mem.eql(u8, f.name, name)) {
            @field(t, f.name) = style;
            return true;
        }
    }
    return false;
}

// The palettes this file maps; see the note in `ui/app.zig`.
test {
    _ = palette;
}

test "the accent is legible against the greys it sits next to" {
    // The popup's key column is drawn in `accent`. While it was `hint` - index
    // 8, the same grey as `comment`, `punct` and `dim` - the keys read as
    // commented out rather than as keys.
    const eq = std.meta.eql;
    try std.testing.expect(!eq(default.accent, default.comment));
    try std.testing.expect(!eq(default.accent, default.dim));
    try std.testing.expect(!eq(default.accent, default.hint));
    try std.testing.expect(!eq(default.accent, default.text));
}

test "the popup border is the accent, recessed" {
    // Same hue as the keys, so the box reads as one object rather than a grey
    // frame round a cyan list - and dimmer, so it stays a frame.
    try std.testing.expect(std.meta.eql(default.popup_border.fg, default.accent.fg));
    try std.testing.expect(default.popup_border.dim);
    try std.testing.expect(!default.popup_border.bold);
}

test "every token kind has a style" {
    inline for (@typeInfo(lexer.Kind).@"enum".fields) |f| {
        const kind: lexer.Kind = @enumFromInt(f.value);
        _ = default.forKind(kind);
    }
}

test "the ascii glyph set stays inside 7-bit ascii" {
    // The point of the fallback is that it survives a terminal that mangles
    // anything above 0x7f, so assert it rather than trusting the literals.
    inline for (@typeInfo(Glyphs).@"struct".fields) |f| {
        // Strings and rows of strings both carry bytes a terminal can mangle;
        // the one flag does not. The wordmark is checked row by row rather
        // than skipped, which is what this test missed when it was added.
        if (f.type == []const u8) {
            const g: []const u8 = @field(Glyphs.ascii, f.name);
            for (g) |c| try std.testing.expect(c < 0x80);
        } else if (f.type == []const []const u8) {
            const rows: []const []const u8 = @field(Glyphs.ascii, f.name);
            for (rows) |g| for (g) |c| try std.testing.expect(c < 0x80);
        }
    }
}

test "every bundled theme keeps the relationships the default has" {
    // The palette mapping is shared, so this is really a test that no theme
    // was added by hand-editing slots - and that no palette leaves the accent
    // indistinguishable from the greys it sits beside, which is the bug that
    // put `accent` in the struct in the first place.
    const eq = std.meta.eql;
    for (bundled) |b| {
        const t = fromPalette(b.palette);
        try std.testing.expect(!eq(t.accent, t.comment));
        try std.testing.expect(!eq(t.accent, t.dim));
        try std.testing.expect(!eq(t.accent, t.hint));
        try std.testing.expect(eq(t.popup_border.fg, t.accent.fg));
        try std.testing.expect(t.popup_border.dim);
        // Add and delete must never be the same colour: the sign column is
        // the only thing distinguishing the two halves of a change.
        try std.testing.expect(!eq(t.add_sign.fg, t.del_sign.fg));
        // Nor may the file statuses collide, for the same reason one level up:
        // in the `F` list the colour *is* the status, so two that match are
        // two statuses a reader cannot tell apart.
        const status = [_]Style{ t.file_added, t.file_deleted, t.file_modified, t.file_renamed, t.file_binary };
        for (status, 0..) |one, i| {
            for (status[i + 1 ..]) |other| try std.testing.expect(!eq(one.fg, other.fg));
        }
        // Text has to survive being drawn on the cursor line, which covers
        // the full width of the pane.
        try std.testing.expect(!eq(t.text.fg, t.cursor_line.bg));
    }
}

/// The bundled theme called `name`, resolved through the shared mapping.
pub fn byName(name: []const u8) ?Theme {
    for (palette.bundled) |b| {
        if (std.mem.eql(u8, b.name, name)) return fromPalette(b.palette);
    }
    return null;
}

test "the bundled names are the ones a config file writes" {
    try std.testing.expect(byName("catppuccin") != null);
    try std.testing.expect(byName("tokyo-night") != null);
    try std.testing.expect(byName("Catppuccin") == null); // names are literal
    try std.testing.expect(byName("solarized") == null);
    // The default is the terminal-native palette resolved, not a second
    // hand-written copy of it that could drift from it.
    try std.testing.expect(std.meta.eql(default, byName("terminal").?));
}

test "a style is written the way a config file writes it" {
    const s1 = try parseStyle("#a6e3a1");
    try std.testing.expectEqual(Color{ .rgb = .{ 0xa6, 0xe3, 0xa1 } }, s1.fg);

    const s2 = try parseStyle("bright-blue bold");
    try std.testing.expectEqual(Color{ .index = 12 }, s2.fg);
    try std.testing.expect(s2.bold);

    // Words in any order, because a config file is typed by hand.
    const s3 = try parseStyle("bold #1e1e2e on 3 underline");
    try std.testing.expectEqual(Color{ .rgb = .{ 0x1e, 0x1e, 0x2e } }, s3.fg);
    try std.testing.expectEqual(Color{ .index = 3 }, s3.bg);
    try std.testing.expect(s3.bold);
    try std.testing.expect(s3.ul_style == .single);

    try std.testing.expectEqual(Color.default, (try parseStyle("default dim")).fg);

    try std.testing.expectError(error.BadAttribute, parseStyle("chartreuse"));
    try std.testing.expectError(error.BadColour, parseStyle("#12345"));
    try std.testing.expectError(error.BadColour, parseStyle("300"));
    try std.testing.expectError(error.MissingColour, parseStyle("#ffffff on"));
    // After `on`, a word that is not a colour is a colour problem, not an
    // attribute one - the message has to point at the right half of the line.
    try std.testing.expectError(error.BadColour, parseStyle("#ffffff on bold"));
}

test "slots are set by their own name or by the name the docs use" {
    var t = default;
    try std.testing.expect(setSlot(&t, "add_sign", try parseStyle("#ff0000")));
    try std.testing.expectEqual(Color{ .rgb = .{ 0xff, 0, 0 } }, t.add_sign.fg);

    // FEATURES.md 4.1 promises `added`; the field is `add_sign`. Both work.
    try std.testing.expect(setSlot(&t, "added", try parseStyle("#00ff00")));
    try std.testing.expectEqual(Color{ .rgb = .{ 0, 0xff, 0 } }, t.add_sign.fg);

    try std.testing.expect(setSlot(&t, "cursor_line", try parseStyle("on 236")));
    try std.testing.expectEqual(Color{ .index = 236 }, t.cursor_line.bg);

    // A slot nobody has is reported, never silently dropped.
    try std.testing.expect(!setSlot(&t, "risk_high", .{}));
    try std.testing.expect(!setSlot(&t, "forKind", .{}));
}
