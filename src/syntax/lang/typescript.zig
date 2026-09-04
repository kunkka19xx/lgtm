// SPDX-License-Identifier: Apache-2.0
//
// TypeScript: JavaScript's definition plus the type-level vocabulary, built by
// concatenating `javascript.zig`'s lists rather than restating them, so a word
// added there reaches both.
//
// Every caveat in `javascript.zig` applies unchanged - regex literals and
// template interpolation especially. `.tsx` is listed here, but JSX inside it
// gets no tag colouring: that needs `angle_tags`, and turning it on would make
// every `a < b` and every generic `Foo<Bar>` colour its right-hand side. HTML
// can afford that rule because markup is its default mode; TSX cannot.

const langdef = @import("../langdef.zig");
const js = @import("javascript.zig");

const ts_keywords = [_][]const u8{
    "abstract",  "declare",   "enum",   "implements", "infer",
    "interface", "is",        "keyof",  "namespace",  "override",
    "private",   "protected", "public", "readonly",   "satisfies",
    "type",
};

const ts_types = [_][]const u8{
    "any",    "bigint", "boolean", "never",   "number",
    "object", "string", "symbol",  "unknown",
};

pub const def = langdef.define(.{
    .name = "typescript",
    .extensions = &.{ "ts", "tsx", "mts", "cts" },
    .line_comment = &.{"//"},
    .block_comment = .{ .open = "/*", .close = "*/" },
    .strings = &js.strings,
    .keywords = &(js.keywords ++ ts_keywords),
    .types = &(js.types ++ ts_types),
    // `interface Foo {` and `type Bar = {` name a hunk as usefully as a
    // function does, and close the same way at the next sibling.
    .fn_decl = &(js.fn_decl ++ [_][]const u8{ "interface", "type", "enum" }),
    // The same test vocabulary as JavaScript: the frameworks are the same ones.
    .test_decl = js.def.test_decl,
    .assert_names = js.def.assert_names,
    .skip_names = js.def.skip_names,
    .fn_decl_body = &js.fn_decl_body,
    .ident_extra = "$",
    .ident_cont_extra = "$",
});
