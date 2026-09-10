// SPDX-License-Identifier: Apache-2.0
//
// YAML, where the interesting token is a bare word. JSON's keys are quoted and
// `key_strings` finds them inside the literal; here `runs-on` is an identifier
// like any other and only its position says what it is.
//
// That position is the head of the line. A colon is ordinary punctuation in a
// YAML value - `image: nginx:alpine`, `at: 09:30`, a URL - so a rule that
// looked for one anywhere would paint half of every file as keys. `key_words`
// asks for the first word on the line instead, past an optional `- `.
//
// A block scalar (`run: |`) is one string per line, not YAML: its body is
// somebody else's language, and a `#` or a `key:` in a shell script is not a
// comment or a key. The body is every line indented past the marker.

const langdef = @import("../langdef.zig");

pub const def = langdef.define(.{
    .name = "yaml",
    .extensions = &.{ "yaml", "yml" },
    .line_comment = &.{"#"},
    .strings = &.{
        .{ .open = "\"", .close = "\"" },
        // A single-quoted scalar escapes a quote by doubling it, so a
        // backslash in one is content. `''` closes and reopens, which lands
        // in the same place.
        .{ .open = "'", .close = "'", .escape = null },
    },
    // Every casing YAML 1.1 accepts. `on` and `off` are among them, which is
    // why the key test overrides the keyword lookup: `on:` heads half the
    // workflows ever written and is a key, not a boolean.
    .keywords = &.{
        "true",  "True",  "TRUE",
        "false", "False", "FALSE",
        "null",  "Null",  "NULL",
        "yes",   "Yes",   "YES",
        "no",    "No",    "NO",
        "on",    "On",    "ON",
        "off",   "Off",   "OFF",
    },
    // `runs-on` and `x.y` are one word each. Not identifier *starts*: a
    // leading `-` is a sequence marker and a leading `.` is nothing.
    .ident_cont_extra = "-.",
    .key_words = .line_head,
    .key_sep_spaced = true,
    .block_scalars = true,
    .blocks = .indent,
});
