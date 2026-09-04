// SPDX-License-Identifier: Apache-2.0
//
// The bundled palettes, as data. A theme is twelve colours plus the shared
// mapping in `theme.zig`, and this file is the twelve colours - seven times
// over, in the notation each palette's own documentation publishes.
//
// Kept apart from the mapping so that adding a theme is adding data, and so
// the file a contributor edits has no logic in it to break.

const vaxis = @import("vaxis");

pub const Color = vaxis.Color;

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
    ///. The `?` popup's key column and its border are both
    /// this hue, which is what makes the box and its keys read as one object.
    accent: Color,
};

/// 256-colour indexes rather than RGB: they inherit the user's terminal
/// palette, so `lgtm` looks like the rest of their setup instead of fighting
/// it - terminal-native mode. The default for exactly that
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
