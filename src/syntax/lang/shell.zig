// SPDX-License-Identifier: Apache-2.0
//
// Shell scripts. One definition for sh, bash, zsh and the rest: the dialects
// differ in what they add, not in what `if`, `case` or a pipeline mean.

const langdef = @import("../langdef.zig");

pub const def = langdef.define(.{
    .name = "shell",
    .extensions = &.{ "sh", "bash", "zsh", "ksh", "mksh", "ash", "zshrc", "bashrc" },
    .filenames = &.{
        "bashrc",       "zshrc",        "zshenv",      "zprofile", "zlogin",
        "bash_profile", "bash_aliases", "bash_logout", "profile",  "pkgbuild",
        "apkbuild",
    },
    .line_comment = &.{"#"},
    .comment_word = true,
    .strings = &.{
        .{ .open = "\"", .close = "\"" },
        // Single quotes take no escape: `'it\'` ends at that quote.
        .{ .open = "'", .close = "'", .escape = null },
    },
    .keywords = &.{
        "alias",  "break", "case",    "continue", "coproc",   "declare",
        "do",     "done",  "elif",    "else",     "esac",     "eval",
        "exec",   "exit",  "export",  "fi",       "for",      "function",
        "if",     "in",    "let",     "local",    "readonly", "return",
        "select", "set",   "shift",   "shopt",    "source",   "then",
        "time",   "trap",  "typeset", "unset",    "until",    "while",
    },
    // Builtins, so a reader tells them from the commands a script calls.
    .types = &.{
        "builtin", "cd",   "command", "echo",   "getopts", "hash",
        "jobs",    "kill", "mapfile", "printf", "pwd",     "read",
        "test",    "type", "ulimit",  "umask",  "wait",
    },
    // Both shapes: `function name` and `name() {`.
    .fn_decl = &.{"function"},
    .fn_decl_paren = true,
    // `deploy-app`.
    .ident_cont_extra = "-",
    .test_decl = &.{"@test "},
    .assert_names = &.{ "assert_", "refute_" },
    .skip_names = &.{"skip "},
});
