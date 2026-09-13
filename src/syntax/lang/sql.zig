// SPDX-License-Identifier: Apache-2.0
//
// SQL: Oracle's PL/SQL plus the everyday Postgres and MySQL vocabulary. Case
// is not significant, so the lists are spelled once, lower-case.
//
// `''` inside a string is SQL's escaped quote, and needs no escape byte: it
// lexes as two adjacent strings, which paint the same. `"` and backtick quote
// identifiers, and are strings here so a `--` inside one is not a comment.
//
// A span is named by the table, view or routine a statement creates. `type`
// does not open one, so `TYPE t IS RECORD` inside a procedure keeps the
// procedure's name.

const langdef = @import("../langdef.zig");

pub const def = langdef.define(.{
    .name = "sql",
    .extensions = &.{"sql"},
    .line_comment = &.{"--"},
    .block_comment = .{ .open = "/*", .close = "*/" },
    .strings = &.{
        .{ .open = "'", .close = "'", .escape = null, .multiline = true },
        .{ .open = "\"", .close = "\"", .escape = null },
        .{ .open = "`", .close = "`", .escape = null },
    },
    .case_insensitive = true,
    .keywords = &.{
        "add",       "after",     "all",       "alter",         "and",       "any",
        "array",     "as",        "asc",       "at",            "authid",    "auto_increment",
        "avg",       "before",    "begin",     "between",       "body",      "bulk",
        "by",        "cascade",   "case",      "check",         "close",     "cluster",
        "collect",   "commit",    "conflict",  "connect",       "constant",  "constraint",
        "count",     "create",    "cross",     "cursor",        "database",  "declare",
        "default",   "delete",    "desc",      "deterministic", "distinct",  "do",
        "drop",      "each",      "else",      "elseif",        "elsif",     "end",
        "exception", "execute",   "exists",    "exit",          "false",     "fetch",
        "first",     "for",       "forall",    "foreign",       "from",      "full",
        "function",  "goto",      "grant",     "group",         "having",    "identified",
        "if",        "ilike",     "immediate", "in",            "index",     "inner",
        "insert",    "intersect", "into",      "is",            "join",      "key",
        "language",  "last",      "lateral",   "left",          "like",      "limit",
        "local",     "lock",      "loop",      "matched",       "max",       "merge",
        "min",       "minus",     "mode",      "natural",       "nocopy",    "not",
        "nothing",   "nowait",    "null",      "nulls",         "of",        "offset",
        "on",        "only",      "open",      "option",        "or",        "order",
        "others",    "out",       "outer",     "over",          "package",   "partition",
        "pipelined", "pragma",    "primary",   "prior",         "procedure", "public",
        "raise",     "range",     "recursive", "references",    "replace",   "restrict",
        "return",    "returning", "returns",   "revoke",        "right",     "rollback",
        "row",       "rownum",    "rows",      "rowtype",       "savepoint", "schema",
        "select",    "set",       "share",     "sql",           "sqlcode",   "sqlerrm",
        "start",     "subtype",   "sum",       "table",         "then",      "to",
        "trigger",   "true",      "truncate",  "type",          "union",     "unique",
        "update",    "use",       "using",     "values",        "view",      "when",
        "where",     "while",     "window",    "with",
    },
    .types = &.{
        "anydata",     "anydataset",    "anytype",      "bfile",          "bigint",
        "bigserial",   "binary_double", "binary_float", "binary_integer", "bit",
        "blob",        "bool",          "boolean",      "bytea",          "char",
        "character",   "clob",          "date",         "datetime",       "dec",
        "decimal",     "double",        "enum",         "float",          "int",
        "integer",     "interval",      "json",         "jsonb",          "long",
        "longtext",    "mediumint",     "mediumtext",   "mlslabel",       "nchar",
        "nclob",       "number",        "numeric",      "nvarchar2",      "pls_integer",
        "precision",   "raw",           "real",         "record",         "rowid",
        "serial",      "smallint",      "text",         "time",           "timestamp",
        "timestamptz", "tinyint",       "urowid",       "uuid",           "varbinary",
        "varchar",     "varchar2",      "varray",       "xmltype",
    },
    // `package body pkg`: `body` keeps the lookahead open to reach the name.
    .fn_decl = &.{ "body", "function", "package", "procedure", "table", "trigger", "view" },
    .blocks = .none,
});
