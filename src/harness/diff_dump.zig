// SPDX-License-Identifier: Apache-2.0
//
// Runs the real git pipeline against a repository and prints what the parser
// made of it. `zig build diff -- [repo]`. Useful for pointing the parser at an
// unfamiliar repo before trusting it there.

const std = @import("std");
const lgtm = @import("lgtm");
const git = lgtm.git;
const hunk = lgtm.hunk;

pub fn main(init: std.process.Init) !u8 {
    var buf: [64 << 10]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &buf);
    const w = &fw.interface;

    var args = init.minimal.args.iterate();
    _ = args.next();
    const repo = args.next();

    var parsed = git.diffPathsIn(init.gpa, init.io, repo, &.{}) catch |err| {
        try w.print("git failed: {t}\n", .{err});
        try w.flush();
        return 1;
    };
    defer parsed.deinit(init.gpa);

    var table: hunk.IdTable = .{};
    defer table.deinit(init.gpa);

    try w.print("{d} file(s), {d} bytes of git output\n\n", .{ parsed.diff.files.len, parsed.raw.len });
    for (parsed.diff.files) |*f| {
        try table.inherit(init.gpa, &.{}, f.hunks);
        try w.print("{s: <34} {t: <9} +{d} -{d}", .{ f.path(), f.status, f.added, f.removed });
        if (f.summarised) try w.writeAll("  [summarised]");
        try w.writeAll("\n");
        for (f.hunks) |h| {
            try w.print("   #{d: <3} @@ -{d},{d} +{d},{d} @@ {s}\n", .{
                h.id, h.old_start, h.old_count, h.new_start, h.new_count, h.section,
            });
        }
    }
    try w.flush();
    return 0;
}
