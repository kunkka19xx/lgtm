// SPDX-License-Identifier: Apache-2.0
//
// JSON, and the first language whose interesting token is a string. Everything
// in a config file is quoted, so a definition that stopped at `strings` would
// paint the whole file one colour and tell a reader nothing. `key_strings` is
// what separates `"name"` from `"lgtm"`, and it is most of the value here.
//
// Comments are not JSON, but `.jsonc` and every `tsconfig.json` in the world
// have them, and a `//` in strict JSON is a mistake that reads better
// highlighted than hidden. They cannot collide with a URL: a `//` inside
// quotes is already inside a string literal by the time the scanner sees it.
//
// No `fn_decl`: a key is not introduced by a keyword, it *is* the name, which
// is why `key_strings` opens the span rather than a word list.

const langdef = @import("../langdef.zig");

pub const def = langdef.define(.{
    .name = "json",
    .extensions = &.{ "json", "jsonc", "json5", "webmanifest", "jsonl", "ndjson" },
    .line_comment = &.{"//"},
    .block_comment = .{ .open = "/*", .close = "*/" },
    .strings = &.{
        .{ .open = "\"", .close = "\"" },
        // JSON5, and it costs nothing in strict JSON where it cannot appear.
        .{ .open = "'", .close = "'" },
    },
    .keywords = &.{ "true", "false", "null" },
    .key_strings = true,
    .block_brackets = true,
});
