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
    };
};

/// The styles the renderer draws with. Built from a `Palette` rather than
/// written out per theme; the slots are what `[theme]` overrides by name.
pub const Theme = struct {
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

    /// Chrome.
    rule: Style,
    dim: Style,
    line_no: Style,
    add_sign: Style,
    del_sign: Style,
    hunk_id: Style,
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

/// The colours a theme is written in, before anything semantic is decided.
///
/// Every bundled theme is one of these plus the shared mapping in
/// `fromPalette`, which is what keeps them consistent with each other: a slot
/// that reads as "the accent, recessed" in one theme reads that way in all of
/// them, and adding a slot is one edit rather than seven. It is also why a
/// user theme can be a palette rather than a full set of styles.
pub const Palette = struct {
    /// Ordinary code. `.default` inherits the terminal's own foreground.
    fg: Color,
    /// Chrome that must recede: rules, line numbers, comments, the hint strip.
    muted: Color,
    /// The cursor line, and the visual selection a step above it. Backgrounds,
    /// so they have to stay dark enough for `fg` to survive being drawn on
    /// them - the cursor line covers the full width of the pane.
    cursor_bg: Color,
    select_bg: Color,
    /// Text drawn *on* a filled badge or a search hit: the theme's background,
    /// not its foreground.
    on_fill: Color,

    red: Color,
    green: Color,
    yellow: Color,
    blue: Color,
    magenta: Color,
    cyan: Color,

    /// The theme's primary, set once rather than picked per call site
    /// (FEATURES.md 4.1). The `?` popup's key column and its border are both
    /// this hue, which is what makes the box and its keys read as one object.
    accent: Color,
};

/// The one mapping from colours to meanings. Written once and shared by every
/// bundled theme, so "the accent, recessed" or "green, emphasised" means the
/// same thing in all of them.
pub fn fromPalette(p: Palette) Theme {
    return .{
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

        .rule = .{ .fg = p.muted },
        .dim = .{ .fg = p.muted },
        .line_no = .{ .fg = p.muted },
        .add_sign = .{ .fg = p.green, .bold = true },
        .del_sign = .{ .fg = p.red, .bold = true },
        .hunk_id = .{ .fg = p.yellow, .bold = true },
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

/// 256-colour indexes rather than RGB: they inherit the user's terminal
/// palette, so `lgtm` looks like the rest of their setup instead of fighting
/// it (FEATURES.md 4.1, "terminal-native mode"). The default for exactly that
/// reason - a tool that arrives already matching the terminal it opens in
/// needs no configuration at all.
pub const terminal: Palette = .{
    .fg = .default,
    .muted = .{ .index = 8 },
    // The one place this steps outside the 16 ANSI colours: a background one
    // step off the terminal's own, which the 16 do not contain.
    .cursor_bg = .{ .index = 236 },
    .select_bg = .{ .index = 238 },
    .on_fill = .{ .index = 0 },
    .red = .{ .index = 1 },
    .green = .{ .index = 2 },
    .yellow = .{ .index = 3 },
    .blue = .{ .index = 4 },
    .magenta = .{ .index = 5 },
    .cyan = .{ .index = 6 },
    .accent = .{ .index = 6 },
};

/// Catppuccin Mocha. Accent is mauve, the palette's own primary.
pub const catppuccin: Palette = .{
    .fg = rgb("cdd6f4"),
    .muted = rgb("6c7086"),
    .cursor_bg = rgb("313244"),
    .select_bg = rgb("45475a"),
    .on_fill = rgb("1e1e2e"),
    .red = rgb("f38ba8"),
    .green = rgb("a6e3a1"),
    .yellow = rgb("f9e2af"),
    .blue = rgb("89b4fa"),
    .magenta = rgb("cba6f7"),
    .cyan = rgb("89dceb"),
    .accent = rgb("cba6f7"),
};

pub const tokyo_night: Palette = .{
    .fg = rgb("c0caf5"),
    .muted = rgb("565f89"),
    .cursor_bg = rgb("292e42"),
    .select_bg = rgb("33467c"),
    .on_fill = rgb("1a1b26"),
    .red = rgb("f7768e"),
    .green = rgb("9ece6a"),
    .yellow = rgb("e0af68"),
    .blue = rgb("7aa2f7"),
    .magenta = rgb("bb9af7"),
    .cyan = rgb("7dcfff"),
    .accent = rgb("7aa2f7"),
};

pub const gruvbox: Palette = .{
    .fg = rgb("ebdbb2"),
    .muted = rgb("928374"),
    .cursor_bg = rgb("3c3836"),
    .select_bg = rgb("504945"),
    .on_fill = rgb("282828"),
    .red = rgb("fb4934"),
    .green = rgb("b8bb26"),
    .yellow = rgb("fabd2f"),
    .blue = rgb("83a598"),
    .magenta = rgb("d3869b"),
    .cyan = rgb("8ec07c"),
    .accent = rgb("fabd2f"),
};

pub const dracula: Palette = .{
    .fg = rgb("f8f8f2"),
    .muted = rgb("6272a4"),
    .cursor_bg = rgb("343746"),
    .select_bg = rgb("44475a"),
    .on_fill = rgb("282a36"),
    .red = rgb("ff5555"),
    .green = rgb("50fa7b"),
    .yellow = rgb("f1fa8c"),
    .blue = rgb("bd93f9"),
    .magenta = rgb("ff79c6"),
    .cyan = rgb("8be9fd"),
    .accent = rgb("bd93f9"),
};

/// Rosé Pine, using the palette's own published ANSI mapping rather than a
/// guess at which of its roles is "green" - the theme has no green, and
/// picking one by eye is how a port ends up with an unreadable add sign.
pub const rose_pine: Palette = .{
    .fg = rgb("e0def4"),
    .muted = rgb("6e6a86"),
    .cursor_bg = rgb("21202e"),
    .select_bg = rgb("403d52"),
    .on_fill = rgb("191724"),
    .red = rgb("eb6f92"),
    .green = rgb("31748f"),
    .yellow = rgb("f6c177"),
    .blue = rgb("9ccfd8"),
    .magenta = rgb("c4a7e7"),
    .cyan = rgb("ebbcba"),
    .accent = rgb("c4a7e7"),
};

pub const kanagawa: Palette = .{
    .fg = rgb("dcd7ba"),
    .muted = rgb("727169"),
    .cursor_bg = rgb("2a2a37"),
    .select_bg = rgb("363646"),
    .on_fill = rgb("1f1f28"),
    .red = rgb("e82424"),
    .green = rgb("98bb6c"),
    .yellow = rgb("e6c384"),
    .blue = rgb("7fb4ca"),
    .magenta = rgb("957fb8"),
    .cyan = rgb("7aa89f"),
    .accent = rgb("7e9cd8"),
};

/// What `[theme] name` accepts, and what `--theme-preview` walks. Names are
/// the ones people already say out loud, not the identifiers.
pub const Bundled = struct {
    name: []const u8,
    palette: Palette,
};

pub const bundled: []const Bundled = &.{
    .{ .name = "terminal", .palette = terminal },
    .{ .name = "catppuccin", .palette = catppuccin },
    .{ .name = "tokyo-night", .palette = tokyo_night },
    .{ .name = "gruvbox", .palette = gruvbox },
    .{ .name = "dracula", .palette = dracula },
    .{ .name = "rose-pine", .palette = rose_pine },
    .{ .name = "kanagawa", .palette = kanagawa },
};

pub fn byName(name: []const u8) ?Theme {
    for (bundled) |b| {
        if (std.mem.eql(u8, b.name, name)) return fromPalette(b.palette);
    }
    return null;
}

/// The `terminal` palette, resolved. Named `default` because that is what
/// every caller means by it.
pub const default: Theme = fromPalette(terminal);

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

/// `"a6e3a1"` as a colour, so a palette is written in the notation its
/// upstream publishes it in. Decoded by hand rather than through `parseInt`,
/// which costs more comptime branches than seven palettes are allowed.
fn rgb(comptime hex: *const [6]u8) Color {
    return .{ .rgb = .{ hexByte(hex[0..2].*), hexByte(hex[2..4].*), hexByte(hex[4..6].*) } };
}

fn hexByte(comptime pair: [2]u8) u8 {
    return nibble(pair[0]) * 16 + nibble(pair[1]);
}

fn nibble(comptime ch: u8) u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => @compileError("not a hex digit"),
    };
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
        const g: []const u8 = @field(Glyphs.ascii, f.name);
        for (g) |c| try std.testing.expect(c < 0x80);
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
        // Text has to survive being drawn on the cursor line, which covers
        // the full width of the pane.
        try std.testing.expect(!eq(t.text.fg, t.cursor_line.bg));
    }
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
