// SPDX-License-Identifier: Apache-2.0
//
// Change detection. Polling only in v0.1; native filesystem events are v0.2
// behind the same interface.
//
// Debounce lives here, not in the main loop: the main loop must never see a
// burst (ARCHITECTURE.md 3). Agents write several files in quick succession and
// often leave one half-written for a few milliseconds, so re-diffing on the
// first sign of movement renders torn states and flickers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = @import("fs.zig");
const proc = @import("proc.zig");
const event = @import("../core/event.zig");

pub const default_poll_ms: i64 = 500;
pub const default_debounce_ms: i64 = 200;

pub const Options = struct {
    poll_ms: i64 = default_poll_ms,
    debounce_ms: i64 = default_debounce_ms,
    repo: ?[]const u8 = null,
    /// Require the signature to be identical on two consecutive polls before
    /// emitting. Debounce already covers the common case; this is the extra
    /// guard from SPEC.md 9 for filesystems where writes land in pieces.
    require_stable: bool = false,
};

/// What a file looked like at one poll.
const Entry = struct {
    path: []const u8,
    size: u64,
    mtime_ns: i128,
};

/// The polling logic, with time passed in rather than read.
///
/// Separating this from the thread is what makes debounce and coalescing
/// testable without sleeping: a test drives `tick` with whatever clock it likes
/// and asserts exactly when an event comes out.
pub const Poller = struct {
    gpa: Allocator,
    io: std.Io,
    opts: Options,

    prev: std.ArrayList(Entry) = .empty,
    /// Paths seen changing since the last emit, deduplicated.
    pending: std.StringArrayHashMapUnmanaged(void) = .empty,
    last_change_ms: i64 = 0,
    dirty: bool = false,
    /// Signature of the most recent poll, for the two-tick stability check.
    last_sig: u64 = 0,
    prev_sig: u64 = 0,

    pub fn init(gpa: Allocator, io: std.Io, opts: Options) Poller {
        return .{ .gpa = gpa, .io = io, .opts = opts };
    }

    pub fn deinit(self: *Poller) void {
        self.clearPrev();
        self.prev.deinit(self.gpa);
        self.clearPending();
        self.pending.deinit(self.gpa);
        self.* = undefined;
    }

    fn clearPrev(self: *Poller) void {
        for (self.prev.items) |e| self.gpa.free(e.path);
        self.prev.clearRetainingCapacity();
    }

    fn clearPending(self: *Poller) void {
        for (self.pending.keys()) |k| self.gpa.free(k);
        self.pending.clearRetainingCapacity();
    }

    /// One poll. Returns the coalesced path list when the tree has settled,
    /// otherwise null. The caller owns the returned slice and its strings.
    pub fn tick(self: *Poller, now_ms: i64) !?[][]const u8 {
        var cur = try self.scan();
        defer {
            for (cur.items) |e| self.gpa.free(e.path);
            cur.deinit(self.gpa);
        }

        const sig = signature(cur.items);
        try self.diffAgainstPrev(cur.items);

        if (sig != self.last_sig) {
            self.dirty = true;
            self.last_change_ms = now_ms;
        }
        self.prev_sig = self.last_sig;
        self.last_sig = sig;

        try self.adoptPrev(cur.items);

        if (!self.dirty) return null;
        if (now_ms - self.last_change_ms < self.opts.debounce_ms) return null;
        if (self.opts.require_stable and self.prev_sig != self.last_sig) return null;
        if (self.pending.count() == 0) {
            self.dirty = false;
            return null;
        }

        const out = try self.gpa.alloc([]const u8, self.pending.count());
        for (self.pending.keys(), 0..) |k, i| out[i] = k;
        // Ownership of the key strings moves to the caller.
        self.pending.clearRetainingCapacity();
        self.dirty = false;
        return out;
    }

    /// Candidate paths from one `git status --porcelain`, then a stat each.
    ///
    /// One subprocess rather than walking the tree (PERFORMANCE.md 8.1). The
    /// stats are needed because status output is identical when an
    /// already-modified file is modified again, so status alone cannot see a
    /// second edit to the same file.
    fn scan(self: *Poller) !std.ArrayList(Entry) {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.gpa);
        try argv.append(self.gpa, "git");
        if (self.opts.repo) |r| try argv.appendSlice(self.gpa, &.{ "-C", r });
        try argv.appendSlice(self.gpa, &.{ "status", "--porcelain", "--untracked-files=all" });

        const out = try proc.run(self.gpa, self.io, argv.items, 16 << 20);
        defer out.deinit(self.gpa);

        var list: std.ArrayList(Entry) = .empty;
        errdefer {
            for (list.items) |e| self.gpa.free(e.path);
            list.deinit(self.gpa);
        }
        if (out.exit_code != 0) return list;

        var it = std.mem.splitScalar(u8, out.stdout, '\n');
        while (it.next()) |line| {
            if (line.len < 4) continue;
            const rel = statusPath(line);
            if (rel.len == 0) continue;

            const full = if (self.opts.repo) |r|
                try std.fs.path.join(self.gpa, &.{ r, rel })
            else
                try self.gpa.dupe(u8, rel);
            defer self.gpa.free(full);

            const meta = fs.statFile(self.io, full);
            try list.append(self.gpa, .{
                .path = try self.gpa.dupe(u8, rel),
                .size = if (meta) |m| m.size else 0,
                .mtime_ns = if (meta) |m| m.mtime_ns else 0,
            });
        }
        return list;
    }

    fn diffAgainstPrev(self: *Poller, cur: []const Entry) !void {
        for (cur) |c| {
            const before = findEntry(self.prev.items, c.path);
            const changed = before == null or
                before.?.size != c.size or
                before.?.mtime_ns != c.mtime_ns;
            if (changed) try self.note(c.path);
        }
        // A path that vanished is a change too: a deleted or reverted file.
        for (self.prev.items) |p| {
            if (findEntry(cur, p.path) == null) try self.note(p.path);
        }
    }

    fn note(self: *Poller, path: []const u8) !void {
        if (self.pending.contains(path)) return;
        const owned = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(owned);
        try self.pending.put(self.gpa, owned, {});
    }

    fn adoptPrev(self: *Poller, cur: []const Entry) !void {
        self.clearPrev();
        for (cur) |c| {
            try self.prev.append(self.gpa, .{
                .path = try self.gpa.dupe(u8, c.path),
                .size = c.size,
                .mtime_ns = c.mtime_ns,
            });
        }
    }
};

fn findEntry(list: []const Entry, path: []const u8) ?Entry {
    for (list) |e| {
        if (std.mem.eql(u8, e.path, path)) return e;
    }
    return null;
}

fn signature(entries: []const Entry) u64 {
    var h: std.hash.Wyhash = .init(0);
    for (entries) |e| {
        h.update(e.path);
        h.update(std.mem.asBytes(&e.size));
        h.update(std.mem.asBytes(&e.mtime_ns));
    }
    return h.final();
}

/// `XY path` or `XY old -> new` for a rename. The new path is the one that
/// exists on disk, so it is the one worth watching.
fn statusPath(line: []const u8) []const u8 {
    if (line.len < 4) return "";
    var rest = std.mem.trim(u8, line[3..], " ");
    if (std.mem.indexOf(u8, rest, " -> ")) |i| rest = rest[i + 4 ..];
    if (rest.len >= 2 and rest[0] == '"' and rest[rest.len - 1] == '"') rest = rest[1 .. rest.len - 1];
    return rest;
}

/// Runs a `Poller` on its own thread and posts to the event queue.
pub const Watcher = struct {
    poller: Poller,
    queue: *event.Queue,
    thread: ?std.Thread = null,
    stop_flag: std.atomic.Value(bool) = .init(false),

    pub fn init(gpa: Allocator, io: std.Io, queue: *event.Queue, opts: Options) Watcher {
        return .{ .poller = Poller.init(gpa, io, opts), .queue = queue };
    }

    pub fn start(self: *Watcher) !void {
        self.stop_flag.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, loop, .{self});
    }

    pub fn stop(self: *Watcher) void {
        self.stop_flag.store(true, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    pub fn deinit(self: *Watcher) void {
        self.stop();
        self.poller.deinit();
        self.* = undefined;
    }

    fn loop(self: *Watcher) void {
        const io = self.poller.io;
        const poll = self.poller.opts.poll_ms;
        var elapsed: i64 = 0;
        while (!self.stop_flag.load(.acquire)) {
            std.Io.sleep(io, .fromMilliseconds(poll), .awake) catch break;
            elapsed += poll;
            const paths = self.poller.tick(elapsed) catch continue orelse continue;
            self.queue.push(.{ .files_changed = paths }) catch {
                event.Queue.freePayload(self.poller.gpa, .{ .files_changed = paths });
            };
        }
    }
};

const testing = std.testing;

test "status lines yield the path" {
    try testing.expectEqualStrings("src/a.zig", statusPath(" M src/a.zig"));
    try testing.expectEqualStrings("src/a.zig", statusPath("?? src/a.zig"));
    try testing.expectEqualStrings("b.txt", statusPath("R  a.txt -> b.txt"));
    try testing.expectEqualStrings("with space.txt", statusPath(" M \"with space.txt\""));
    try testing.expectEqualStrings("", statusPath(""));
}

test "signature changes with size or mtime, not just with the path set" {
    const a = [_]Entry{.{ .path = "x", .size = 10, .mtime_ns = 1 }};
    const b = [_]Entry{.{ .path = "x", .size = 11, .mtime_ns = 1 }};
    const c = [_]Entry{.{ .path = "x", .size = 10, .mtime_ns = 2 }};

    try testing.expect(signature(&a) != signature(&b));
    try testing.expect(signature(&a) != signature(&c));
    try testing.expectEqual(signature(&a), signature(&a));
}

/// Drives a Poller over a scratch repo with a clock the test controls, so
/// debounce behaviour is asserted rather than slept through.
const Harness = struct {
    dir: []const u8,
    gpa: Allocator,
    io: std.Io,
    poller: Poller,

    fn init(gpa: Allocator, io: std.Io, dir: []const u8) !Harness {
        _ = try proc.run(gpa, io, &.{ "git", "init", "-q", dir }, 1 << 20);
        inline for (.{
            .{ "user.email", "t@t" },
            .{ "user.name", "t" },
        }) |kv| {
            const r = try proc.run(gpa, io, &.{ "git", "-C", dir, "config", kv[0], kv[1] }, 1 << 20);
            r.deinit(gpa);
        }
        return .{
            .dir = dir,
            .gpa = gpa,
            .io = io,
            .poller = Poller.init(gpa, io, .{ .repo = dir, .debounce_ms = 200 }),
        };
    }

    fn deinit(self: *Harness) void {
        self.poller.deinit();
    }

    fn write(self: *Harness, name: []const u8, body: []const u8) !void {
        const path = try std.fs.path.join(self.gpa, &.{ self.dir, name });
        defer self.gpa.free(path);
        const f = try std.Io.Dir.cwd().createFile(self.io, path, .{});
        defer f.close(self.io);
        var buf: [4096]u8 = undefined;
        var w = f.writer(self.io, &buf);
        try w.interface.writeAll(body);
        try w.interface.flush();
    }

    fn tick(self: *Harness, now_ms: i64) !?[][]const u8 {
        return self.poller.tick(now_ms);
    }

    fn free(self: *Harness, paths: [][]const u8) void {
        for (paths) |p| self.gpa.free(p);
        self.gpa.free(paths);
    }
};

fn scratchDir(gpa: Allocator, name: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ "/tmp", name });
}

test "a burst of writes produces exactly one event after settling" {
    const gpa = testing.allocator;
    // Without the real environ the child has no PATH and `git` never resolves;
    // see the note in proc.zig.
    var threaded: std.Io.Threaded = .init(gpa, .{ .environ = testing.environ });
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try scratchDir(gpa, "lgtm-watch-burst");
    defer gpa.free(dir);
    _ = try proc.run(gpa, io, &.{ "rm", "-rf", dir }, 1 << 20);

    var h = try Harness.init(gpa, io, dir);
    defer h.deinit();

    // Settle: first tick establishes the baseline.
    if (try h.tick(0)) |p| h.free(p);
    if (try h.tick(500)) |p| h.free(p);

    // The agent writes three files in one burst, polled at 500 ms intervals.
    try h.write("a.txt", "one\n");
    try h.write("b.txt", "two\n");
    try testing.expect(try h.tick(1000) == null); // changed, debounce running

    try h.write("c.txt", "three\n");
    try testing.expect(try h.tick(1100) == null); // still moving, debounce restarts

    // Nothing changes; once the debounce window passes, one event arrives.
    const paths = (try h.tick(1400)).?;
    defer h.free(paths);
    try testing.expectEqual(@as(usize, 3), paths.len);

    // And exactly one: the next quiet tick yields nothing.
    try testing.expect(try h.tick(1900) == null);
    try testing.expect(try h.tick(2400) == null);

    _ = try proc.run(gpa, io, &.{ "rm", "-rf", dir }, 1 << 20);
}

test "a second edit to the same file is detected" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{ .environ = testing.environ });
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try scratchDir(gpa, "lgtm-watch-repeat");
    defer gpa.free(dir);
    _ = try proc.run(gpa, io, &.{ "rm", "-rf", dir }, 1 << 20);

    var h = try Harness.init(gpa, io, dir);
    defer h.deinit();

    try h.write("f.txt", "first\n");
    if (try h.tick(0)) |p| h.free(p);
    const first = (try h.tick(500)).?;
    h.free(first);

    // `git status --porcelain` prints the same line for an already-modified
    // file, so only the stat catches this. Different length, so size moves even
    // if the clock is coarse.
    try h.write("f.txt", "second edit, longer\n");
    try testing.expect(try h.tick(1000) == null);
    const second = (try h.tick(1300)).?;
    defer h.free(second);
    try testing.expectEqual(@as(usize, 1), second.len);
    try testing.expectEqualStrings("f.txt", second[0]);

    _ = try proc.run(gpa, io, &.{ "rm", "-rf", dir }, 1 << 20);
}

test "a quiet tree never emits" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{ .environ = testing.environ });
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try scratchDir(gpa, "lgtm-watch-quiet");
    defer gpa.free(dir);
    _ = try proc.run(gpa, io, &.{ "rm", "-rf", dir }, 1 << 20);

    var h = try Harness.init(gpa, io, dir);
    defer h.deinit();

    var t: i64 = 0;
    while (t < 3000) : (t += 500) {
        if (try h.tick(t)) |p| {
            h.free(p);
            try testing.expect(false); // nothing changed, nothing may be emitted
        }
    }

    _ = try proc.run(gpa, io, &.{ "rm", "-rf", dir }, 1 << 20);
}
