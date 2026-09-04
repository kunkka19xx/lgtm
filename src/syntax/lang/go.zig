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
        "break", "case",   "chan",        "const",     "continue", "default",
        "defer", "else",   "fallthrough", "for",       "func",     "go",
        "goto",  "if",     "import",      "interface", "map",      "package",
        "range", "return", "select",      "struct",    "switch",   "type",
        "var",   "nil",    "true",        "false",     "iota",
    },
    .types = &.{
        "bool",    "byte",    "complex64", "complex128", "error",  "float32",
        "float64", "int",     "int8",      "int16",      "int32",  "int64",
        "rune",    "string",  "uint",      "uint8",      "uint16", "uint32",
        "uint64",  "uintptr", "any",
    },
    .fn_decl = &.{"func"},
    // The signature, not the name. `func Test` also matches `func
    // TestingHelper(x int)`, which is a helper and not a test - caught by the
    // false-positive test in `core/testrisk.zig`, which is what it is for.
    // Every Go test takes `*testing.T`, and nothing else does except a helper
    // written to support one, which is close enough to count.
    //
    // `t.Error` and `t.Fatal` cover their `-f` variants by prefix, which is
    // what keeps one call from counting as two.
    .test_decl = &.{ "*testing.T)", "*testing.F)" },
    .assert_names = &.{ "t.Error", "t.Fatal", "assert.", "require." },
    .skip_names = &.{ "t.Skip", "t.SkipNow" },
    .fn_receiver = true,
});
