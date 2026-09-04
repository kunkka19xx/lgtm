// SPDX-License-Identifier: Apache-2.0
//
// File-type icons for the `F` list, when `ui.icons = "nerd"`.
//
// These are Nerd Font codepoints: private-use characters that only exist in a
// patched font. That is the whole risk of the feature - in an unpatched font
// they draw as tofu, and a broken glyph looks worse than no glyph
// - which is why nothing here is reachable unless the user
// asked for it by name.
//
// Each entry names the Nerd Font class it came from, so a codepoint that turns
// out to be wrong is a one-line fix against a name rather than a hunt through
// a font table. The set is deliberately small: the languages a review is
// likely to contain, plus the handful of config and document types that show
// up beside them.

const std = @import("std");

/// Which of the palette's colours an icon is drawn in. Filetype colour, the
/// way oil.nvim and neo-tree do it - a Zig file is recognisable before the
/// name is read - but named as a hue rather than as `#f7a41d`, so a theme
/// moves the icons with everything else instead of six brand colours sitting
/// outside it.
pub const Hue = enum { red, green, yellow, blue, magenta, cyan, muted };

pub const Icon = struct {
    glyph: []const u8,
    hue: Hue,
};

const Entry = struct { ext: []const u8, glyph: []const u8, hue: Hue };

/// Longest match wins where extensions overlap, which they do not today - the
/// table is checked in order and the first hit is taken.
const by_extension: []const Entry = &.{
    .{ .ext = "zig", .glyph = "\u{e6a9}", .hue = .yellow }, // nf-seti-zig
    .{ .ext = "rs", .glyph = "\u{e7a8}", .hue = .red }, // nf-dev-rust
    .{ .ext = "go", .glyph = "\u{e627}", .hue = .cyan }, // nf-seti-go
    .{ .ext = "py", .glyph = "\u{e73c}", .hue = .blue }, // nf-dev-python
    .{ .ext = "js", .glyph = "\u{e74e}", .hue = .yellow }, // nf-dev-javascript
    .{ .ext = "mjs", .glyph = "\u{e74e}", .hue = .yellow },
    .{ .ext = "ts", .glyph = "\u{e628}", .hue = .blue }, // nf-seti-typescript
    .{ .ext = "tsx", .glyph = "\u{e628}", .hue = .blue },
    .{ .ext = "jsx", .glyph = "\u{e74e}", .hue = .yellow },
    .{ .ext = "c", .glyph = "\u{e61e}", .hue = .blue }, // nf-custom-c
    .{ .ext = "h", .glyph = "\u{e61e}", .hue = .blue },
    .{ .ext = "cpp", .glyph = "\u{e61d}", .hue = .blue }, // nf-custom-cpp
    .{ .ext = "hpp", .glyph = "\u{e61d}", .hue = .blue },
    .{ .ext = "java", .glyph = "\u{e738}", .hue = .red }, // nf-dev-java
    .{ .ext = "rb", .glyph = "\u{e739}", .hue = .red }, // nf-dev-ruby
    .{ .ext = "php", .glyph = "\u{e73d}", .hue = .magenta }, // nf-dev-php
    .{ .ext = "swift", .glyph = "\u{e755}", .hue = .red }, // nf-dev-swift
    .{ .ext = "kt", .glyph = "\u{e634}", .hue = .magenta }, // nf-custom-kotlin
    .{ .ext = "lua", .glyph = "\u{e620}", .hue = .blue }, // nf-seti-lua
    .{ .ext = "sh", .glyph = "\u{f489}", .hue = .green }, // nf-oct-terminal
    .{ .ext = "bash", .glyph = "\u{f489}", .hue = .green },
    .{ .ext = "nix", .glyph = "\u{f313}", .hue = .cyan }, // nf-linux-nixos
    .{ .ext = "md", .glyph = "\u{e73e}", .hue = .blue }, // nf-dev-markdown
    .{ .ext = "json", .glyph = "\u{e60b}", .hue = .yellow }, // nf-seti-json
    .{ .ext = "toml", .glyph = "\u{e6b2}", .hue = .magenta }, // nf-seti-toml
    .{ .ext = "yaml", .glyph = "\u{e615}", .hue = .magenta }, // nf-seti-yml
    .{ .ext = "yml", .glyph = "\u{e615}", .hue = .magenta },
    .{ .ext = "html", .glyph = "\u{e736}", .hue = .red }, // nf-dev-html5
    .{ .ext = "css", .glyph = "\u{e749}", .hue = .blue }, // nf-dev-css3
    .{ .ext = "sql", .glyph = "\u{e706}", .hue = .cyan }, // nf-dev-database
    .{ .ext = "lock", .glyph = "\u{f023}", .hue = .muted }, // nf-fa-lock
    .{ .ext = "txt", .glyph = "\u{f15c}", .hue = .muted }, // nf-fa-file_text
};

/// Files a repository has one of, recognised by name because they have no
/// extension to go on.
const by_name: []const Entry = &.{
    .{ .ext = "Makefile", .glyph = "\u{e779}", .hue = .muted }, // nf-dev-gnu
    .{ .ext = "Dockerfile", .glyph = "\u{f308}", .hue = .cyan }, // nf-linux-docker
    .{ .ext = "LICENSE", .glyph = "\u{f718}", .hue = .muted }, // nf-oct-law
    .{ .ext = ".gitignore", .glyph = "\u{e702}", .hue = .red }, // nf-dev-git
};

/// Anything unrecognised. A generic file beats a blank column: the icons are a
/// shape to scan down, and a gap in that shape reads as a missing row.
const fallback: Icon = .{ .glyph = "\u{f15b}", .hue = .muted }; // nf-fa-file

/// The icon for `path`, or null when the glyph set has none - which is every
/// set but `nerd`, so the caller draws nothing and the column disappears.
pub fn forPath(path: []const u8, enabled: bool) ?Icon {
    if (!enabled) return null;

    const name = std.fs.path.basename(path);
    for (by_name) |i| {
        if (std.mem.eql(u8, name, i.ext)) return .{ .glyph = i.glyph, .hue = i.hue };
    }
    // `basename` first, so a dot in a directory name is not read as one.
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return fallback;
    const ext = name[dot + 1 ..];
    for (by_extension) |i| {
        if (std.mem.eql(u8, ext, i.ext)) return .{ .glyph = i.glyph, .hue = i.hue };
    }
    return fallback;
}

const testing = std.testing;

test "an icon is chosen by extension, by name, or not at all" {
    try testing.expectEqualStrings("\u{e6a9}", forPath("src/ui/app.zig", true).?.glyph);
    try testing.expectEqualStrings("\u{e73e}", forPath("docs/GUIDE.md", true).?.glyph);
    try testing.expectEqualStrings("\u{f308}", forPath("build/Dockerfile", true).?.glyph);
    // And a filetype colour with it, which is what makes the column scannable
    // before any name is read.
    try testing.expectEqual(Hue.yellow, forPath("src/ui/app.zig", true).?.hue);
    try testing.expectEqual(Hue.red, forPath("src/main.rs", true).?.hue);

    // A dot in a directory name is not an extension.
    try testing.expectEqualStrings(fallback.glyph, forPath("some.dir/README", true).?.glyph);
    try testing.expectEqualStrings(fallback.glyph, forPath("Makefile.old", true).?.glyph);
    try testing.expectEqualStrings("\u{e779}", forPath("Makefile", true).?.glyph);

    // And the whole table is unreachable unless the user asked for it.
    try testing.expect(forPath("src/ui/app.zig", false) == null);
}

test "every icon is one codepoint, so the column stays a column" {
    // A two-codepoint icon would be drawn in a slot laid out for one, and the
    // paths beside it would step right by a cell each time.
    for (by_extension) |i| {
        try testing.expectEqual(@as(usize, 1), try std.unicode.utf8CountCodepoints(i.glyph));
    }
    for (by_name) |i| {
        try testing.expectEqual(@as(usize, 1), try std.unicode.utf8CountCodepoints(i.glyph));
    }
    try testing.expectEqual(@as(usize, 1), try std.unicode.utf8CountCodepoints(fallback.glyph));
}
