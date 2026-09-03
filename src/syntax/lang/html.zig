// SPDX-License-Identifier: Apache-2.0
//
// HTML, which does not fit `LangDef` the way the others do. A programming
// language has one token vocabulary; markup has three modes - tag, attribute
// and text - and telling them apart is what a parser is for. What is here is
// the useful 80% of that without one:
//
//   - `<!-- -->` comments, which are a `block_comment` like any other;
//   - quoted attribute values, which are ordinary string specs;
//   - tag names, via `angle_tags`: the identifier after `<` or `</` is typed
//     as a tag. This is `fn_decl`'s one-token lookahead pointed at markup.
//
// What it gets wrong, in the order you will notice it:
//
//   - `a < b` in text content colours `b` as a tag. The rule cannot see that
//     it is not in markup, and adding that sight is the mode switching this
//     definition exists to avoid.
//   - `<script>` and `<style>` bodies lex as HTML, so their JavaScript and CSS
//     arrive as plain text with the strings coloured. Nothing runs away, it is
//     just flat - embedded sublanguages are the other half of what a real
//     grammar buys, and the point at which tree-sitter earns its place
//     (ARCHITECTURE.md 5).
//
// No `keywords`: attribute names would be the candidates, and `class`, `id`,
// `type` and `name` are ordinary English that appears in the prose HTML is
// mostly made of. Colouring a paragraph's words as markup looks worse than
// leaving the attributes plain.

const langdef = @import("../langdef.zig");

pub const def = langdef.define(.{
    .name = "html",
    .extensions = &.{ "html", "htm", "xhtml", "xml", "svg", "vue", "svelte" },
    .block_comment = .{ .open = "<!--", .close = "-->" },
    .strings = &.{
        .{ .open = "\"", .close = "\"", .escape = null },
        .{ .open = "'", .close = "'", .escape = null },
    },
    .angle_tags = true,
    // `<my-component>` and `<Foo.Bar>` are one tag name each.
    .ident_cont_extra = "-.:",
});
