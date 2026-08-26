// SPDX-License-Identifier: Apache-2.0
//
// Zig. First because it is what this repository is written in, so every
// fixture and every real recorded session exercises it (docs/PLAN.md phase 4).

const lexer = @import("../lexer.zig");

pub const def = lexer.define(.{
    .name = "zig",
    .extensions = &.{ "zig", "zon" },
    .line_comment = &.{"//"},
    // Zig has no block comments; `\\` runs a string literal to end of line.
    .line_string = &.{"\\\\"},
    .strings = &.{
        .{ .open = "\"", .close = "\"" },
        .{ .open = "'", .close = "'", .max_bytes = 12 },
    },
    .keywords = &.{
        "addrspace",   "align",     "allowzero", "and",         "anyframe",
        "anytype",     "asm",       "async",     "await",       "break",
        "callconv",    "catch",     "comptime",  "const",       "continue",
        "defer",       "else",      "enum",      "errdefer",    "error",
        "export",      "extern",    "fn",        "for",         "if",
        "inline",      "linksection", "noalias", "noinline",    "nosuspend",
        "opaque",      "or",        "orelse",    "packed",      "pub",
        "resume",      "return",    "struct",    "suspend",     "switch",
        "test",        "threadlocal", "try",     "union",       "unreachable",
        "usingnamespace", "var",    "volatile",  "while",       "null",
        "true",        "false",     "undefined",
    },
    .types = &.{
        "bool",  "void",  "noreturn", "type",   "anyerror", "anyopaque",
        "comptime_int", "comptime_float",
        "i8",    "i16",   "i32",   "i64",   "i128",  "isize",
        "u8",    "u16",   "u32",   "u64",   "u128",  "usize",
        "f16",   "f32",   "f64",   "f80",   "f128",
        "c_int", "c_uint", "c_char", "c_long", "c_ulong",
    },
    .fn_decl = &.{"fn"},
    .ident_extra = "@",
});
