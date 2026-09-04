// SPDX-License-Identifier: Apache-2.0
//
// Rust. The `'` spec carries a byte limit so a lifetime (`'a`) is not read as
// an unterminated char literal - see StringSpec.max_bytes.

const langdef = @import("../langdef.zig");

pub const def = langdef.define(.{
    .name = "rust",
    .extensions = &.{"rs"},
    .line_comment = &.{"//"},
    .block_comment = .{ .open = "/*", .close = "*/", .nested = true },
    .strings = &.{
        // Longest opener first: `br#"` before `r#"` before `"`.
        .{ .open = "br", .close = "\"", .escape = null, .multiline = true, .hashed = true },
        .{ .open = "r", .close = "\"", .escape = null, .multiline = true, .hashed = true },
        .{ .open = "\"", .close = "\"", .multiline = true },
        .{ .open = "'", .close = "'", .max_bytes = 12 },
    },
    .keywords = &.{
        "as",    "async",  "await", "break", "const",  "continue",
        "crate", "dyn",    "else",  "enum",  "extern", "false",
        "fn",    "for",    "if",    "impl",  "in",     "let",
        "loop",  "match",  "mod",   "move",  "mut",    "pub",
        "ref",   "return", "self",  "Self",  "static", "struct",
        "super", "trait",  "true",  "type",  "union",  "unsafe",
        "use",   "where",  "while",
    },
    .types = &.{
        "bool",  "char",   "f32", "f64",    "i8",     "i16", "i32", "i64",
        "i128",  "isize",  "str", "u8",     "u16",    "u32", "u64", "u128",
        "usize", "String", "Vec", "Option", "Result", "Box",
    },
    .fn_decl = &.{"fn"},
    .test_decl = &.{ "#[test]", "#[tokio::test]" },
    .assert_names = &.{ "assert!", "assert_eq!", "assert_ne!" },
    .skip_names = &.{"#[ignore]"},
});
