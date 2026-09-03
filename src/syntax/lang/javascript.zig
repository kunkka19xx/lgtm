// SPDX-License-Identifier: Apache-2.0
//
// JavaScript, and the language ARCHITECTURE.md 5 names as the one that
// exhausts a lexer. Two of its context-sensitive corners are conceded here
// rather than half-solved, both visible and both bounded:
//
// **Regex literals are not modelled.** `/` opens a regex or divides depending
// on what came before it, which needs a token of history the scanner does not
// keep. A regex therefore lexes as punctuation and identifiers, which is
// merely dull - except for `/["']/`, where the quote opens a string spec and
// paints the rest of the line. The alternative, a `/`-delimited string spec,
// makes `a / b / c` a string, which is worse and far more common.
//
// **Template interpolation is not re-entered.** `${expr}` inside a backtick
// literal stays string-coloured, the same trade Swift's `\(...)` makes. Real
// nesting would need the scanner to recurse, and `State` is one word.
//
// `fn_decl` includes `const`, `let` and `var` on purpose: most modern
// functions are `const f = () => {}`, and without the bindings an arrow
// component would never name a hunk at all. They are in `fn_decl_body` too,
// so a binding only opens a span when a block opens on its line - otherwise
// `const email = form.email;` would hold the header for every line between
// itself and the enclosing brace, which measured at about a third of the lines
// of a real React file.
//
// Two things are left. `const x = 5` still colours `x` as a function name,
// since the colour is decided a token before the block is seen. And a binding
// whose value is a multi-line object or array - `const opts = {` - passes the
// same-line test and keeps its span, so it names the hunks inside itself.
// Telling that apart from `const f = () => {` needs lookahead past the `=`,
// and naming a hunk after the literal it sits in is a fair second best.

const langdef = @import("../langdef.zig");

/// Shared with `typescript.zig`, which adds to it rather than restating it.
pub const keywords = [_][]const u8{
    "as",     "async",      "await",    "break",    "case",      "catch",
    "class",  "const",      "continue", "debugger", "default",   "delete",
    "do",     "else",       "export",   "extends",  "false",     "finally",
    "for",    "from",       "function", "get",      "if",        "import",
    "in",     "instanceof", "let",      "new",      "null",      "of",
    "return", "set",        "static",   "super",    "switch",    "this",
    "throw",  "true",       "try",      "typeof",   "undefined", "var",
    "void",   "while",      "with",     "yield",
};

/// Also shared: the globals worth colouring as types in both languages.
pub const types = [_][]const u8{
    "Array",   "BigInt", "Boolean", "Date",   "Error",  "Function",
    "JSON",    "Map",    "Math",    "Number", "Object", "Promise",
    "Proxy",   "RegExp", "Set",     "String", "Symbol", "WeakMap",
    "WeakSet",
};

pub const strings = [_]langdef.StringSpec{
    .{ .open = "\"", .close = "\"" },
    .{ .open = "'", .close = "'" },
    // Backticks cross lines; `${...}` inside stays part of the literal.
    .{ .open = "`", .close = "`", .multiline = true },
};

/// Shared with `typescript.zig`. `class` is here for the same reason it is in
/// Python's: for a method the innermost span wins, and for a line between
/// methods the class name still beats nothing.
pub const fn_decl = [_][]const u8{ "function", "const", "let", "var", "class" };

/// The bindings, which count only when a block opens on the same line - see
/// `LangDef.fn_decl_body`. `function` and `class` stay unconditional.
pub const fn_decl_body = [_][]const u8{ "const", "let", "var" };

pub const def = langdef.define(.{
    .name = "javascript",
    .extensions = &.{ "js", "mjs", "cjs", "jsx" },
    .line_comment = &.{"//"},
    .block_comment = .{ .open = "/*", .close = "*/" },
    .strings = &strings,
    .keywords = &keywords,
    .types = &types,
    .fn_decl = &fn_decl,
    .fn_decl_body = &fn_decl_body,
    // `$foo` and `foo$bar`: a start byte and a continuation byte both.
    .ident_extra = "$",
    .ident_cont_extra = "$",
});
