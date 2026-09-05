// SPDX-License-Identifier: Apache-2.0
//
// Java. The first language whose functions are not introduced by a keyword:
// `public void run()` is a modifier, a type and a name, and the type is
// usually a class this file has never heard of. `fn_decl_paren` is the answer
// - the shape names the method, and a block on the same line confirms it. See
// LangDef.fn_decl_paren for what that costs.
//
// `class`, `interface`, `enum` and `record` are in `fn_decl` as well, for the
// reason Python's and JavaScript's `class` is: the innermost span wins for a
// line inside a method, and a line between two methods still reports the type
// it sits in rather than nothing.
//
// Three notes on the vocabulary.
//
// `record` is a contextual keyword, and `Record record = ...` is ordinary Java
// - it is coloured as a keyword there, which is wrong and harmless. Records
// are common enough in code written since Java 17 that naming their spans is
// worth one miscoloured identifier; the declaration path is safe either way,
// because the `=` that follows clears the lookahead before it can name
// anything. `sealed`, `permits` and `yield` are contextual too and far less
// plausible as identifiers.
//
// Text blocks (`"""`) are modelled as an ordinary multiline literal. Java
// requires a line break after the opening delimiter and strips incidental
// indentation; neither changes where the literal ends, which is all the
// scanner needs to know.
//
// Annotations lex as punctuation plus an identifier. `@` is not admitted to
// `ident_extra` the way Swift's is: nothing here classifies `@Override`, so
// making it one token would only move the boundary without adding colour.

const langdef = @import("../langdef.zig");

pub const def = langdef.define(.{
    .name = "java",
    .extensions = &.{"java"},
    // `///` and `/**` alike: the prefix match takes the whole line, and a
    // Javadoc block is an ordinary block comment.
    .line_comment = &.{"//"},
    .block_comment = .{ .open = "/*", .close = "*/" },
    .strings = &.{
        // Text block before plain, or `"""` opens and closes an empty "".
        .{ .open = "\"\"\"", .close = "\"\"\"", .multiline = true },
        .{ .open = "\"", .close = "\"" },
        // A char literal, with the byte limit that keeps an apostrophe in a
        // comment-free line from painting the rest of it.
        .{ .open = "'", .close = "'", .max_bytes = 12 },
    },
    .keywords = &.{
        "abstract",     "assert",   "break",      "case",      "catch",     "class",
        "const",        "continue", "default",    "do",        "else",      "enum",
        "extends",      "final",    "finally",    "for",       "goto",      "if",
        "implements",   "import",   "instanceof", "interface", "native",    "new",
        "package",      "permits",  "private",    "protected", "public",    "record",
        "return",       "sealed",   "static",     "strictfp",  "super",     "switch",
        "synchronized", "this",     "throw",      "throws",    "transient", "try",
        "var",          "volatile", "while",      "yield",     "true",      "false",
        "null",
    },
    .types = &.{
        "boolean",       "byte",         "char",      "double",           "float",
        "int",           "long",         "short",     "void",             "Boolean",
        "Byte",          "Character",    "Double",    "Float",            "Integer",
        "Long",          "Number",       "Object",    "Short",            "String",
        "StringBuilder", "CharSequence", "Class",     "Enum",             "Void",
        "Math",          "System",       "Thread",    "Runnable",         "Comparable",
        "Iterable",      "Iterator",     "Exception", "RuntimeException", "Throwable",
        "Error",         "Collection",   "List",      "ArrayList",        "Map",
        "HashMap",       "Set",          "HashSet",   "Optional",         "Stream",
    },
    .fn_decl = &.{ "class", "interface", "enum", "record" },
    // `@Test` is JUnit and TestNG both. The other forms are listed separately
    // because none of them contains it - `@ParameterizedTest` has no `@`
    // before its `Test` - and `@TestFactory` and `@TestTemplate` declare tests
    // as surely as `@Test` does.
    //
    // The one over-count this vocabulary can make, and the reason it is
    // written out here rather than found later: `@TestInstance(...)` and
    // `@TestMethodOrder(...)` contain `@Test`, and a substring cannot see the
    // word boundary that separates them. Both are class-level configuration,
    // at most one line each per file, and editing one is a removal and an
    // addition that net to zero - so what is left is a line deleted on its
    // own, reported as one test gone. Narrowing to `@Test ` and `@Test(`
    // would cost the form that is written far more often than either of
    // them: `@Test` alone on its line.
    .test_decl = &.{
        "@Test",        "@ParameterizedTest", "@RepeatedTest",
        "@TestFactory", "@TestTemplate",
    },
    // One entry, not one per helper: `assertEquals`, `assertThat` and
    // `assertThrows` all contain `assert`, and listing them separately would
    // count a single call several times. It matches Java's own `assert`
    // statement too, which is an assertion and should be counted, and a
    // custom `assertRowMatches` helper, which is one as well.
    //
    // The over-count it can make is the import that brings the helpers in:
    // `import static org.assertj.core.api.Assertions.assertThat;` holds
    // `assertj` and `assertThat` and counts two. Left alone deliberately -
    // the signal is `assert_gone -| assert_new`, so an import counted on the
    // added side can only make the warning quieter, and on the removed side
    // the file was losing its tests anyway. Anchoring it - `assert(`, or a
    // leading space - would cost the `assert x != null;` statement or the
    // qualified `Assertions.assertEquals(` and buy nothing.
    //
    // Mockito's `verify(` is not here. A bare `verify(` is indistinguishable
    // from `signature.verify(data)` or from a `boolean verify(byte[] sig)`
    // declaration in production code, and `fewer_asserts` fires on a file
    // with no tests in it the moment such a line is deleted. `Mockito.verify(`
    // would be safe and would miss the static-imported form everyone writes,
    // so the count leaves verifications out and rests on the assertions that
    // a Mockito test also carries.
    .assert_names = &.{"assert"},
    // `@Disabled` is JUnit 5, `@Ignore` is JUnit 4 and TestNG. `assumeTrue`
    // and its neighbours abort a test at runtime, which is a skip that leaves
    // the build green.
    //
    // The assumptions carry their `(` for the reason `t.Skip(` and `it.skip(`
    // do: `import static org.junit.Assume.assumeTrue;` holds the bare name,
    // and a change that adds one skip usually adds its import in the same
    // hunk - two skips reported for one, and the import marked as the place
    // to go and read it. A static import never has the paren. It also makes
    // `Assume.` unnecessary, since `Assume.assumeTrue(` carries the call form
    // whole; the JUnit 4 spellings that are not `assumeTrue` are listed
    // instead, which is what `Assume.` was covering.
    .skip_names = &.{
        "@Disabled",    "@Ignore",     "assumeTrue(",
        "assumeFalse(", "assumeThat(", "assumeNotNull(",
    },
    .fn_decl_paren = true,
});
