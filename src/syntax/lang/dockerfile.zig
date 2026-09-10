// SPDX-License-Identifier: Apache-2.0
//
// Dockerfiles, matched by name rather than extension: the file is called
// `Dockerfile`, sometimes `Dockerfile.dev` or `prod.Dockerfile`, and
// `Containerfile` under Podman.
//
// Instructions are uppercase here and nowhere else. Docker's own linter warns
// on any other casing, so listing one form keeps the keyword table small and
// costs a file nobody writes.
//
// `AS` names the stage it opens, which is the only structure a Dockerfile has:
// in a multi-stage build the hunk header then says which stage a line is in.
// A stage ends where the next one begins, and `openFn` already closes a
// sibling at the same depth, which for a file with no braces is all of them.

const langdef = @import("../langdef.zig");

pub const def = langdef.define(.{
    .name = "dockerfile",
    // For `prod.Dockerfile`. The bare and suffixed spellings are `filenames`.
    .extensions = &.{"dockerfile"},
    .filenames = &.{ "dockerfile", "containerfile" },
    .line_comment = &.{"#"},
    .strings = &.{
        .{ .open = "\"", .close = "\"" },
        .{ .open = "'", .close = "'" },
    },
    .keywords = &.{
        "ADD",     "ARG",         "AS",      "CMD",
        "COPY",    "ENTRYPOINT",  "ENV",     "EXPOSE",
        "FROM",    "HEALTHCHECK", "LABEL",   "MAINTAINER",
        "ONBUILD", "RUN",         "SHELL",   "STOPSIGNAL",
        "USER",    "VOLUME",      "WORKDIR",
    },
    .fn_decl = &.{"AS"},
    // `${VAR}` in a RUN line is a shell expansion, not a scope. Counted as
    // one, it closed the stage the line belongs to.
    .blocks = .none,
});
