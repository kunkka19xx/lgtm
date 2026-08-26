// SPDX-License-Identifier: Apache-2.0
//
// Styles and glyphs, kept apart from the code that draws so a second theme is
// data rather than a branch (FEATURES.md 4.9). One built-in theme in v0.1;
// bundled themes and user TOML are phase 5c.

const std = @import("std");
const vaxis = @import("vaxis");
const lexer = @import("../syntax/lexer.zig");

pub const Style = vaxis.Style;

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
    };

    pub const ascii: Glyphs = .{
        .sep = "|",
        .rule = "-",
        .gap = "-",
        .add = "+",
        .del = "-",
        .context = " ",
        .at = "@@",
    };
};

/// 256-colour indexes rather than RGB: they inherit the user's terminal
/// palette, so `lgtm` looks like the rest of their setup instead of fighting
/// it. True-colour themes are phase 5c.
pub const Theme = struct {
    text: Style,
    comment: Style,
    string: Style,
    number: Style,
    keyword: Style,
    type_name: Style,
    fn_name: Style,
    punct: Style,

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

pub const default: Theme = .{
    .text = .{},
    .comment = .{ .fg = .{ .index = 8 } },
    .string = .{ .fg = .{ .index = 2 } },
    .number = .{ .fg = .{ .index = 3 } },
    .keyword = .{ .fg = .{ .index = 5 } },
    .type_name = .{ .fg = .{ .index = 6 } },
    .fn_name = .{ .fg = .{ .index = 4 } },
    .punct = .{ .fg = .{ .index = 8 } },

    .rule = .{ .fg = .{ .index = 8 } },
    .dim = .{ .fg = .{ .index = 8 } },
    .line_no = .{ .fg = .{ .index = 8 } },
    .add_sign = .{ .fg = .{ .index = 2 }, .bold = true },
    .del_sign = .{ .fg = .{ .index = 1 }, .bold = true },
    .hunk_id = .{ .fg = .{ .index = 3 }, .bold = true },
    .path = .{ .bold = true },
    .added_count = .{ .fg = .{ .index = 2 } },
    .removed_count = .{ .fg = .{ .index = 1 } },
    .mode_badge = .{ .fg = .{ .index = 0 }, .bg = .{ .index = 2 }, .bold = true },
    .hint = .{ .fg = .{ .index = 8 } },
    .cursor_line = .{ .bg = .{ .index = 236 } },
};

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
