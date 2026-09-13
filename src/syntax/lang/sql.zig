// SPDX-License-Identifier: Apache-2.0
//
// SQL, specifically the Oracle/PL-SQL dialect (AUTHID, BULK, PRAGMA, ROWTYPE,
// VARCHAR2, ...) rather than generic ANSI - PL/SQL is a superset of the
// statement/clause vocabulary any dialect needs, so a Postgres or MySQL file
// still highlights correctly; it is only PL/SQL's own procedural keywords that
// would go uncoloured elsewhere.
//
// Keywords are listed in both cases because SQL is conventionally
// case-insensitive - `select` and `SELECT` are both idiomatic - and `LangDef`
// has no case-folding option: `words` is an exact-match table, keyed on
// whatever bytes a language spells its keywords with. Doubling the list is
// the workaround that costs nothing at the schema level.
//
// A string closes on the next unescaped `'`, never on a doubled `''`: SQL's
// own escape for an embedded quote is `'it''s'`, not a backslash, and
// `StringSpec` only knows a single escape byte before a character. Left as
// `escape = null` rather than reached for with `\`, which is not what SQL
// uses. The cost is `'it''s'` lexing as two adjacent strings instead of one -
// wrong colour, never a wrong parse.

const langdef = @import("../langdef.zig");

pub const def = langdef.define(.{
    .name = "sql",
    .extensions = &.{"sql"},
    .line_comment = &.{"--"},
    .block_comment = .{ .open = "/*", .close = "*/" },
    .strings = &.{
        .{ .open = "'", .close = "'", .escape = null },
    },
    .keywords = &.{
        "ADD",        "ALL",       "ALTER",      "AND",      "ANY",        "ARRAY",
        "AS",         "ASC",       "AT",         "AUTHID",   "AVG",        "BEGIN",
        "BETWEEN",    "BODY",      "BULK",       "BY",       "CASE",       "CHECK",
        "CLOSE",      "CLUSTER",   "COLLECT",    "COMMIT",   "CONSTANT",   "CREATE",
        "CURSOR",     "DECLARE",   "DEFAULT",    "DELETE",   "DESC",       "DISTINCT",
        "DROP",       "ELSE",      "ELSIF",      "END",      "EXCEPTION",  "EXECUTE",
        "EXISTS",     "EXIT",      "FETCH",      "FOR",      "FORALL",     "FOREIGN",
        "FROM",       "FUNCTION",  "GOTO",       "GRANT",    "GROUP",      "HAVING",
        "IDENTIFIED", "IF",        "IN",         "INDEX",    "INNER",      "INSERT",
        "INTERSECT",  "INTO",      "IS",         "JOIN",     "LEFT",       "LIKE",
        "LIMIT",      "LOCAL",     "LOCK",       "LOOP",     "MAX",        "MERGE",
        "MIN",        "MINUS",     "MODE",       "NOT",      "NOWAIT",     "NULL",
        "OF",         "ON",        "OPEN",       "OPTION",   "OR",         "ORDER",
        "OUTER",      "OVER",      "PACKAGE",    "PRAGMA",   "PRIMARY",    "PRIOR",
        "PROCEDURE",  "PUBLIC",    "RAISE",      "RANGE",    "REFERENCES", "REPLACE",
        "RETURN",     "RETURNING", "REVOKE",     "ROLLBACK", "ROWNUM",     "ROWTYPE",
        "SAVEPOINT",  "SELECT",    "SET",        "SHARE",    "SQL",        "SQLCODE",
        "SQLERRM",    "START",     "SUBTYPE",    "SUM",      "TABLE",      "THEN",
        "TIME",       "TO",        "TRIGGER",    "TRUNCATE", "TYPE",       "UNION",
        "UNIQUE",     "UPDATE",    "USE",        "USING",    "VALUES",     "VIEW",
        "WHEN",       "WHERE",     "WHILE",      "WITH",     "add",        "all",
        "alter",      "and",       "any",        "array",    "as",         "asc",
        "at",         "authid",    "avg",        "begin",    "between",    "body",
        "bulk",       "by",        "case",       "check",    "close",      "cluster",
        "collect",    "commit",    "constant",   "create",   "cursor",     "declare",
        "default",    "delete",    "desc",       "distinct", "drop",       "else",
        "elsif",      "end",       "exception",  "execute",  "exists",     "exit",
        "fetch",      "for",       "forall",     "foreign",  "from",       "function",
        "goto",       "grant",     "group",      "having",   "identified", "if",
        "in",         "index",     "inner",      "insert",   "intersect",  "into",
        "is",         "join",      "left",       "like",     "limit",      "local",
        "lock",       "loop",      "max",        "merge",    "min",        "minus",
        "mode",       "not",       "nowait",     "null",     "of",         "on",
        "open",       "option",    "or",         "order",    "outer",      "over",
        "package",    "pragma",    "primary",    "prior",    "procedure",  "public",
        "raise",      "range",     "references", "replace",  "return",     "returning",
        "revoke",     "rollback",  "rownum",     "rowtype",  "savepoint",  "select",
        "set",        "share",     "sql",        "sqlcode",  "sqlerrm",    "start",
        "subtype",    "sum",       "table",      "then",     "time",       "to",
        "trigger",    "truncate",  "type",       "union",    "unique",     "update",
        "use",        "using",     "values",     "view",     "when",       "where",
        "while",      "with",
    },
    .types = &.{
        "ANYDATA",      "ANYDATASET",     "ANYTYPE",      "BFILE",          "BINARY_DOUBLE",
        "BINARY_FLOAT", "BINARY_INTEGER", "BLOB",         "BOOLEAN",        "CHAR",
        "CHARACTER",    "CLOB",           "DATE",         "DEC",            "DECIMAL",
        "FLOAT",        "INT",            "INTEGER",      "LONG",           "MLSLABEL",
        "NCHAR",        "NCLOB",          "NUMBER",       "NUMERIC",        "NVARCHAR2",
        "PLS_INTEGER",  "RAW",            "RECORD",       "REAL",           "ROWID",
        "SMALLINT",     "TIMESTAMP",      "UROWID",       "VARCHAR",        "VARCHAR2",
        "VARRAY",       "XMLTYPE",        "anydata",      "anydataset",     "anytype",
        "bfile",        "binary_double",  "binary_float", "binary_integer", "blob",
        "boolean",      "char",           "character",    "clob",           "date",
        "dec",          "decimal",        "float",        "int",            "integer",
        "long",         "mlslabel",       "nchar",        "nclob",          "number",
        "numeric",      "nvarchar2",      "pls_integer",  "raw",            "record",
        "real",         "rowid",          "smallint",     "timestamp",      "urowid",
        "varchar",      "varchar2",       "varray",       "xmltype",
    },
    .blocks = .none,
});
