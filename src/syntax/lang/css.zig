// SPDX-License-Identifier: Apache-2.0
//
// CSS, and the first language to need `ident_cont_extra`: without '-' as a
// continuation byte `grid-template-columns` lexes as three words and two
// punctuation runs, and no property name would ever match the keyword map.
// '-' starts an identifier too, for `--custom-prop` and `-webkit-` prefixes.
//
// `keywords` holds property names and `types` holds value keywords, which is
// what makes a declaration read as `property: value` rather than one flat
// colour. Neither list is exhaustive - it cannot be, CSS has hundreds of each
// and gains more every year - so an unlisted property renders as plain text
// beside its coloured neighbours. Add to it when a real diff looks wrong.
//
// No `fn_decl`: CSS has no functions to name in a hunk header. A rule is
// identified by its selector, which is not a token but a whole line, and is
// left for the header's fallback rather than modelled here.

const langdef = @import("../langdef.zig");

pub const def = langdef.define(.{
    .name = "css",
    .extensions = &.{ "css", "scss", "less" },
    // Not CSS proper, but every `.scss` and `.less` file uses it, and a `//`
    // in plain CSS is a mistake that is clearer highlighted as a comment.
    .line_comment = &.{"//"},
    .block_comment = .{ .open = "/*", .close = "*/" },
    .strings = &.{
        .{ .open = "\"", .close = "\"" },
        .{ .open = "'", .close = "'" },
    },
    .keywords = &.{
        // At-rules. '@' is an identifier start below, so these arrive whole.
        "@charset",            "@container",      "@font-face",       "@import",
        "@keyframes",          "@layer",          "@media",           "@namespace",
        "@page",               "@property",       "@supports",
        // Properties, most-used first for nothing but readability.
               "align-content",
        "align-items",         "align-self",      "animation",        "aspect-ratio",
        "backdrop-filter",     "background",      "background-color", "background-image",
        "background-position", "background-size", "border",           "border-bottom",
        "border-color",        "border-left",     "border-radius",    "border-right",
        "border-top",          "border-width",    "bottom",           "box-shadow",
        "box-sizing",          "clip-path",       "color",            "column-gap",
        "content",             "cursor",          "direction",        "display",
        "fill",                "filter",          "flex",             "flex-basis",
        "flex-direction",      "flex-grow",       "flex-shrink",      "flex-wrap",
        "font",                "font-family",     "font-size",        "font-style",
        "font-weight",         "gap",             "grid",             "grid-area",
        "grid-column",         "grid-row",        "grid-template",    "grid-template-columns",
        "grid-template-rows",  "height",          "justify-content",  "justify-items",
        "justify-self",        "left",            "letter-spacing",   "line-height",
        "list-style",          "margin",          "margin-bottom",    "margin-left",
        "margin-right",        "margin-top",      "max-height",       "max-width",
        "min-height",          "min-width",       "object-fit",       "opacity",
        "order",               "outline",         "overflow",         "overflow-x",
        "overflow-y",          "padding",         "padding-bottom",   "padding-left",
        "padding-right",       "padding-top",     "place-items",      "pointer-events",
        "position",            "resize",          "right",            "row-gap",
        "stroke",              "text-align",      "text-decoration",  "text-overflow",
        "text-transform",      "top",             "transform",        "transition",
        "translate",           "user-select",     "vertical-align",   "visibility",
        "white-space",         "width",           "word-break",       "z-index",
    },
    .types = &.{
        // Value keywords. `none`, `auto` and `inherit` are the ones a reader
        // scans for, and none of them is ever a property name.
        "absolute",  "auto",         "block",         "border-box", "center",  "column",
        "contain",   "content-box",  "cover",         "dashed",     "dotted",  "ellipsis",
        // `grid` is absent: it is a `display` value and a property prefix
        // both, and a word cannot be in `keywords` and `types` at once.
        "fixed",     "flex-end",     "flex-start",    "hidden",     "inherit", "initial",
        "inline",    "inline-block", "inline-flex",   "italic",     "none",    "normal",
        "nowrap",    "pointer",      "relative",      "revert",     "row",     "scroll",
        "solid",     "space-around", "space-between", "static",     "sticky",  "transparent",
        "underline", "unset",        "visible",       "wrap",
    },
    .ident_extra = "@-",
    .ident_cont_extra = "-",
});
