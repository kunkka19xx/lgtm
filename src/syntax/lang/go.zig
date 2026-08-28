// SPDX-License-Identifier: Apache-2.0
//
// Go. `fn_receiver` is what lets `func (r *T) Name()` still report Name as the
// enclosing function rather than stopping at the receiver.

const langdef = @import("../langdef.zig");

pub const def = langdef.define(.{
    .name = "go",
    .extensions = &.{"go"},
    .line_comment = &.{"//"},
    .block_comment = .{ .open = "/*", .close = "*/" },
    .strings = &.{
        .{ .open = "\"", .close = "\"" },
        .{ .open = "`", .close = "`", .escape = null, .multiline = true },
        .{ .open = "'", .close = "'", .max_bytes = 12 },
    },
    .keywords = &.{
        "break",   "case",   "chan",   "const",     "continue", "default",
        "defer",   "else",   "fallthrough", "for",  "func",     "go",
        "goto",    "if",     "import", "interface", "map",      "package",
        "range",   "return", "select", "struct",    "switch",   "type",
        "var",     "nil",    "true",   "false",     "iota",
    },
    .types = &.{
        "bool",  "byte",  "complex64", "complex128", "error", "float32",
        "float64", "int", "int8",  "int16", "int32", "int64", "rune",
        "string", "uint", "uint8", "uint16", "uint32", "uint64", "uintptr",
        "any",
    },
    .fn_decl = &.{"func"},
    .fn_receiver = true,
});
