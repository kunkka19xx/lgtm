// SPDX-License-Identifier: Apache-2.0
//
// Markdown, which has no keywords, no types and no functions - and still has
// more structure worth drawing than most of the languages here. A `#` run is
// the document's outline, so a hunk header can say which section a change is
// in, which is the whole reason this file exists: a diff of a README otherwise
// tells you a line number and nothing else.
//
// Inline code is a string in everything but name. `max_bytes` is what stops a
// lone backtick in prose from painting the rest of the paragraph, the same
// guard a Rust lifetime needed.
//
// Emphasis is a branch rather than a string spec, and every rule in it is
// there to refuse a false positive: `some_flag and other_flag` is two
// identifiers, `2 * 3 * 4` is arithmetic, and `* item` is a bullet. What is
// left over really is emphasis.

const langdef = @import("../langdef.zig");

pub const def = langdef.define(.{
    .name = "markdown",
    .extensions = &.{ "md", "markdown", "mdown", "mkd" },
    // Legal in markdown, and free: the comment machinery is already here.
    .block_comment = .{ .open = "<!--", .close = "-->" },
    .strings = &.{
        // The double form first, or its opener reads as an empty literal.
        .{ .open = "``", .close = "``", .escape = null, .max_bytes = 200 },
        .{ .open = "`", .close = "`", .escape = null, .max_bytes = 200 },
    },
    .list_marks = true,
    .fences = true,
    .tables = true,
    .links = true,
    .emphasis = true,
    .prose = true,
    .blocks = .headings,
});
