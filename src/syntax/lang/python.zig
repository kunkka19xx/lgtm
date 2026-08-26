// SPDX-License-Identifier: Apache-2.0
//
// Python. The only `.indent` language so far: function spans close when a line
// appears at or left of the declaration's indentation, not on a brace.

const lexer = @import("../lexer.zig");

pub const def = lexer.define(.{
    .name = "python",
    .extensions = &.{ "py", "pyi" },
    .line_comment = &.{"#"},
    .strings = &.{
        // Triple quotes before single, or `"""` opens and closes an empty "".
        .{ .open = "\"\"\"", .close = "\"\"\"", .multiline = true },
        .{ .open = "'''", .close = "'''", .multiline = true },
        .{ .open = "\"", .close = "\"" },
        .{ .open = "'", .close = "'" },
    },
    .keywords = &.{
        "and",     "as",     "assert", "async",  "await",  "break",
        "class",   "continue", "def",  "del",    "elif",   "else",
        "except",  "finally", "for",   "from",   "global", "if",
        "import",  "in",     "is",     "lambda", "nonlocal", "not",
        "or",      "pass",   "raise",  "return", "try",    "while",
        "with",    "yield",  "None",   "True",   "False",  "self",
    },
    .types = &.{
        "bool", "bytes", "complex", "dict", "float", "frozenset",
        "int",  "list",  "object",  "set",  "str",   "tuple",
    },
    // `class` opens a span too: for a method the innermost wins, and for a
    // line between methods the class name is still better than nothing.
    .fn_decl = &.{ "def", "class" },
    .blocks = .indent,
});
