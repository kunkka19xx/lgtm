// SPDX-License-Identifier: Apache-2.0
//
// TOML, which is the other half of YAML's problem with the other half of the
// answer. Keys are bare words here too, but the separator is '=', and an
// unquoted '=' in TOML is an assignment and nothing else - so `key_words` may
// look anywhere on the line rather than only at its head. That is what keeps
// `serde = { version = "1", features = [] }` from colouring one key of three.
//
// A line opening with '[' is a table, always. It is the only structure the
// format has, so it is what a hunk header says: `[dependencies]` beats a line
// number when you are reading someone's manifest.

const langdef = @import("../langdef.zig");

pub const def = langdef.define(.{
    .name = "toml",
    .extensions = &.{"toml"},
    .line_comment = &.{"#"},
    .strings = &.{
        // The multi-line forms first, or their opener is read as an empty
        // literal and the body lexes as code.
        .{ .open = "\"\"\"", .close = "\"\"\"", .multiline = true },
        .{ .open = "'''", .close = "'''", .escape = null, .multiline = true },
        .{ .open = "\"", .close = "\"" },
        // A literal string takes no escapes: a Windows path is its whole point.
        .{ .open = "'", .close = "'", .escape = null },
    },
    .keywords = &.{ "true", "false", "inf", "nan" },
    // `feature-flags` is one word, and so is the dotted key `a.b.c`.
    .ident_cont_extra = "-.",
    .key_sep = '=',
    .key_words = .anywhere,
    // Rare, but legal, and free once the separator is a field.
    .key_strings = true,
    .bracket_tables = true,
    // A brace here opens an inline table, not a scope. Counting it closed the
    // table span on the line that was still inside it.
    .blocks = .none,
});
