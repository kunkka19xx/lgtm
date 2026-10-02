// SPDX-License-Identifier: Apache-2.0
//
// `.env` files: one `KEY=value` assignment per line, optionally `export`ed.
// There is no nesting and no other use of a bare '=' in the format, so -
// TOML's reasoning, not YAML's - a key may be anywhere on the line rather
// than only at its head: that is what still finds `KEY` in `export KEY=val`,
// where `export` is the word actually at the head of the line.

const langdef = @import("../langdef.zig");

pub const def = langdef.define(.{
    .name = "env",
    .extensions = &.{"env"},
    // `.env`, and every dotted variant - `.env.local`, `.env.production` - by
    // name: `forPath` takes the basename up to its first dot, so one entry
    // here covers all of them the way `dockerfile` covers `Dockerfile.dev`.
    .filenames = &.{"env"},
    .line_comment = &.{"#"},
    // A '#' glued to a value - a URL fragment, a password - is not a comment;
    // one that follows whitespace is. The same rule shell reads `.#lgtm` by.
    .comment_word = true,
    .strings = &.{
        .{ .open = "\"", .close = "\"" },
        // A literal value takes no escapes: a password is its whole point.
        .{ .open = "'", .close = "'", .escape = null },
    },
    .keywords = &.{"export"},
    .key_sep = '=',
    .key_words = .anywhere,
    // `${HOST}` inside a value is interpolation, not a scope: counted as one,
    // it would close whatever the line is in - the same reason a Dockerfile's
    // `RUN` line and a TOML inline table are both `.none`.
    .blocks = .none,
});
