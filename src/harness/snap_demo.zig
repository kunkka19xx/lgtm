// SPDX-License-Identifier: Apache-2.0
//
// Takes a real snapshot of the current repository and prints what it wrote.
// `zig build snap -- [session] [turn] [message]`.
//
// SNAPSHOTS.md 5.6 step 1 says the check that matters is made from outside,
// with stock git: `git show refs/lgtm/<session>/<turn>:<path>` has to print the
// file, and `git status` has to be unchanged. This runs the plumbing so that
// check can be made; it deliberately proves nothing on its own, because a
// harness asserting against the code that wrote it would be testing agreement
// rather than correctness.
//
// It is also how the hard boundaries get exercised for real. The unit tests
// assert the argv; only running it can show that the user's index survived.

const std = @import("std");
const lgtm = @import("lgtm");
const gitobj = lgtm.gitobj;
const snapshot = lgtm.snapshot;
const proc = lgtm.proc;

pub fn main(init: std.process.Init) !u8 {
    var buf: [16 << 10]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &buf);
    const w = &fw.interface;
    defer w.flush() catch {};

    const gpa = init.gpa;
    const io = init.io;

    var args = init.minimal.args.iterate();
    _ = args.next();
    const message = args.next() orelse "harness snapshot";

    // Ignore-clean by construction, which is what keeps `node_modules` out:
    // `update-index --add` would stage anything it was handed.
    const status = try proc.run(gpa, io, &.{
        "git", "status", "--porcelain", "--untracked-files=all",
    }, 1 << 20);
    defer status.deinit(gpa);
    if (status.exit_code != 0) {
        try w.print("not a git repository\n", .{});
        return 1;
    }

    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(gpa);
    var lines = std.mem.splitScalar(u8, status.stdout, '\n');
    while (lines.next()) |line| {
        // `XY <path>`: two status columns, a space, then the path.
        if (line.len < 4) continue;
        const path = std.mem.trim(u8, line[3..], " ");
        if (path.len == 0) continue;
        // A rename reads `old -> new`; the new name is the one to stage.
        if (std.mem.indexOf(u8, path, " -> ")) |at| {
            try paths.append(gpa, path[at + 4 ..]);
        } else try paths.append(gpa, path);
    }

    if (paths.items.len == 0) {
        try w.print("nothing changed - snapshot would be empty\n", .{});
        return 0;
    }

    // Through the policy layer, which is what step 2 added: it decides the
    // session, numbers the turn, chains it to the last one and prunes.
    var store: snapshot.Store = .open(gpa, io, init.environ_map);
    const was = store.state.latest_turn;
    const turn = store.take(paths.items, message) orelse {
        try w.print("no snapshot taken (snapshots off, or nothing changed)\n", .{});
        return 1;
    };

    var ref_buf: [128]u8 = undefined;
    const ref = try gitobj.refFor(&ref_buf, store.state.name(), turn);
    try w.print("session {s}\n  turn {d} (was {d})\n  {s}\n  {d} path{s}\n\n", .{
        store.state.name(), turn, was, ref, paths.items.len, if (paths.items.len == 1) "" else "s",
    });

    const tree = try gitobj.readTree(gpa, io, ref);
    defer gpa.free(tree.text);
    defer gpa.free(tree.entries);
    try w.print("the snapshot contains {d} file{s}. First few:\n", .{
        tree.entries.len, if (tree.entries.len == 1) "" else "s",
    });
    for (tree.entries[0..@min(5, tree.entries.len)]) |e| {
        try w.print("  {s}  {s}\n", .{ e.oid[0..@min(12, e.oid.len)], e.path });
    }

    try w.print(
        \\
        \\Now check it from outside, which is the point:
        \\  git show {s}:{s} | head
        \\  git status                    # must be exactly as you left it
        \\  git log --oneline -1          # HEAD must not have moved
        \\  git for-each-ref refs/lgtm/   # only our namespace, chained by turn
        \\  cat .lgtm/state.json          # the session, and where the reader got to
        \\
    , .{ ref, paths.items[0] });
    return 0;
}
