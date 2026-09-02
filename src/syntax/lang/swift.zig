// SPDX-License-Identifier: Apache-2.0
//
// Swift. The first language whose raw literal has no prefix before the '#' run
// - `#"..."#` rather than Rust's `r#"..."#` - which is why StringSpec.open is
// allowed to be empty.
//
// Two deliberate omissions. `#"""..."""#`, the raw *multiline* form, is not
// modelled: the opener test looks for a single '"' after the '#' run, so a
// spec for it would also claim `#"`, and the two cannot be told apart without
// giving the scanner a second length to track. It degrades to a short string
// run rather than painting the file, which is the acceptable failure here.
// And `'` is not a delimiter at all - Swift has no character literal, so an
// apostrophe in ordinary code is just punctuation.
//
// The keyword list leaves out Swift's contextual keywords that are also
// plausible identifiers: `get`, `set`, `open`, `prefix`, `postfix`, `infix`.
// `str.prefix(3)` is far more common in real Swift than an operator
// declaration, and a lexer with no context would colour it wrongly.

const langdef = @import("../langdef.zig");

pub const def = langdef.define(.{
    .name = "swift",
    .extensions = &.{"swift"},
    // `///` and `//` alike: the prefix match takes the whole line either way.
    .line_comment = &.{"//"},
    .block_comment = .{ .open = "/*", .close = "*/", .nested = true },
    .strings = &.{
        // Raw first, then longest opener: `#"` before `"""` before `"`.
        .{ .open = "", .close = "\"", .escape = null, .hashed = true },
        .{ .open = "\"\"\"", .close = "\"\"\"", .multiline = true },
        .{ .open = "\"", .close = "\"" },
    },
    .keywords = &.{
        "any",      "as",         "associatedtype", "async",    "await",
        "break",    "case",       "catch",       "class",       "continue",
        "convenience", "default", "defer",       "deinit",      "didSet",
        "do",       "else",       "enum",        "extension",   "fallthrough",
        "false",    "fileprivate", "final",      "for",         "func",
        "guard",    "if",         "import",      "in",          "indirect",
        "init",     "inout",      "internal",    "is",          "lazy",
        "let",      "mutating",   "nil",         "nonmutating", "operator",
        "override", "precedencegroup", "private", "protocol",   "public",
        "repeat",   "required",   "rethrows",    "return",      "self",
        "Self",     "some",       "static",      "struct",      "subscript",
        "super",    "switch",     "throw",       "throws",      "true",
        "try",      "typealias",  "unowned",     "var",         "weak",
        "where",    "while",      "willSet",
    },
    .types = &.{
        "Any",    "AnyObject", "Array",  "Bool",      "Character", "Comparable",
        "Dictionary", "Double", "Equatable", "Error",  "Float",    "Hashable",
        "Int",    "Int8",   "Int16",  "Int32",  "Int64",  "Never",
        "Optional", "Result", "Set",  "String", "Substring", "UInt",
        "UInt8",  "UInt16", "UInt32", "UInt64", "Void",
    },
    .fn_decl = &.{"func"},
    // `@objc`, `@MainActor`: one identifier rather than punctuation plus a
    // word, the same reason Zig admits '@' for its builtins.
    .ident_extra = "@",
});
