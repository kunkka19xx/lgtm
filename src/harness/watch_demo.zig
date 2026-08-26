// SPDX-License-Identifier: Apache-2.0
//
// Runs the real watcher thread against a repository and prints coalesced
// events as they arrive. `zig build watch -- [repo] [seconds]`.
//
// The Poller's debounce is unit-tested with an injected clock; this exercises
// the thread, the queue and real wall-clock timing, which those tests
// deliberately do not.

const std = @import("std");
const lgtm = @import("lgtm");
const watch = lgtm.watch;
const event = lgtm.event;

pub fn main(init: std.process.Init) !u8 {
    var buf: [16 << 10]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &buf);
    const w = &fw.interface;

    var args = init.minimal.args.iterate();
    _ = args.next();
    const repo = args.next();
    const seconds: i64 = if (args.next()) |s| std.fmt.parseInt(i64, s, 10) catch 10 else 10;

    var queue = event.Queue.init(init.gpa, init.io);
    defer queue.deinit();

    var watcher = watch.Watcher.init(init.gpa, init.io, &queue, .{ .repo = repo });
    defer watcher.deinit();
    try watcher.start();

    try w.print("watching {s} for {d}s (poll {d}ms, debounce {d}ms)\n", .{
        repo orelse ".", seconds, watch.default_poll_ms, watch.default_debounce_ms,
    });
    try w.flush();

    var elapsed: i64 = 0;
    var batches: usize = 0;
    while (elapsed < seconds * 1000) : (elapsed += 250) {
        std.Io.sleep(init.io, .fromMilliseconds(250), .awake) catch break;
        const events = try queue.tryDrain(init.gpa);
        defer init.gpa.free(events);
        for (events) |e| switch (e) {
            .files_changed => |paths| {
                batches += 1;
                try w.print("[{d: >5}ms] batch {d}: {d} path(s)\n", .{ elapsed, batches, paths.len });
                for (paths) |p| try w.print("           {s}\n", .{p});
                for (paths) |p| init.gpa.free(p);
                init.gpa.free(paths);
                try w.flush();
            },
            else => {},
        };
    }

    watcher.stop();
    try w.print("\n{d} batch(es) in {d}s\n", .{ batches, seconds });
    try w.flush();
    return 0;
}
