// SPDX-License-Identifier: Apache-2.0
//
// Change detection. A poller, and a doorbell in front of it.
//
// The poller is the answer: `git status --porcelain` is the only thing that
// knows about `.gitignore`, about a file saved with no edit in it, and about
// content that matches HEAD anyway. It is 9 ms on a repository of this size
// and it has to run for every real change regardless.
//
// The doorbell (`io/notify.zig`) only decides *when* to ask. Without it the
// poller runs twice a second forever and a write is noticed up to a poll
// interval late; with it the thread sleeps on a kqueue or an inotify
// descriptor and asks when the OS says a watched directory moved. Detection
// latency was half of the whole path from an agent's write to a drawn frame,
// and it is the only part of that path that was doing no work.
//
// The poll interval survives as the timeout on that wait, so a missed or
// unsupported event costs latency and never correctness. Everything below the
// wait - the scan, the signature, the debounce, the quiet period - is the same
// code whichever woke it.
//
// Debounce lives here, not in the main loop: the main loop must never see a
// burst. Agents write several files in quick succession and
// often leave one half-written for a few milliseconds, so re-diffing on the
// first sign of movement renders torn states and flickers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = @import("fs.zig");
const notify = @import("notify.zig");
const proc = @import("proc.zig");
const event = @import("../core/event.zig");

pub const default_poll_ms: i64 = 500;
pub const default_debounce_ms: i64 = 200;
/// Silence after the last write that reads as "the agent has stopped".
///
/// A different question from debounce, and a much longer one. Debounce asks
/// "has this write finished landing" and is measured in a fifth of a second;
/// this asks "has the *turn* finished" and is measured in ten. Both are
/// thresholds on the same clock, which is why they live in the same file and
/// why there is no second timer thread.
///
/// It is a guess, and the guess is wrong for an agent that thinks for a long
/// time in the middle of a turn. What that costs depends entirely on what
/// reads it: a snapshot taken early is an extra turn in the timeline, which is
/// harmless; a notification fired early is spent.
pub const default_quiet_ms: i64 = 10_000;

pub const Options = struct {
    poll_ms: i64 = default_poll_ms,
    debounce_ms: i64 = default_debounce_ms,
    repo: ?[]const u8 = null,
    /// Require the signature to be identical on two consecutive polls before
    /// emitting. Debounce already covers the common case; this is the extra
    /// guard for filesystems where writes land in pieces.
    require_stable: bool = false,
    /// Zero turns quiet detection off, which is the state until something asks
    /// for it. Nothing polls harder to provide it: it is read off the clock
    /// `tick` already consults.
    quiet_ms: i64 = 0,
    /// Directories to hand the doorbell: the ones containing tracked files.
    /// Empty polls, which is what a caller with no git to ask should do.
    watch_dirs: []const []const u8 = &.{},
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
    /// Something has changed since the last quiet period was reported. Cleared
    /// when it fires, so one silence is one signal however long it lasts, and
    /// re-armed only by a new change - one silence is one signal, held
    /// here rather than by every caller that would otherwise have to.
    quiet_armed: bool = false,
    /// Whether a poll has happened yet. The first one is not a change, it is
    /// finding out what is there - and everything looks new against an empty
    /// baseline. Emitting treats that as a change on purpose, because a
    /// startup re-diff is right anyway; arming the quiet timer on it is not,
    /// because ten seconds later it would report a turn that never happened.
    seen_first: bool = false,

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

    /// Whether the tree has just gone quiet: something changed, and nothing has
    /// changed for `quiet_ms` since.
    ///
    /// True at most once per burst of writes. Asked after `tick` rather than
    /// returned by it, because it answers a different question about the same
    /// poll and folding the two would make every existing caller handle a case
    /// it does not care about.
    pub fn quiet(self: *Poller, now_ms: i64) bool {
        if (self.opts.quiet_ms == 0 or !self.quiet_armed) return false;
        if (now_ms - self.last_change_ms < self.opts.quiet_ms) return false;
        self.quiet_armed = false;
        return true;
    }

    /// Whether a change has been seen and is still waiting out the debounce.
    ///
    /// The thread asks so it can come back in a debounce rather than in a poll
    /// interval. Without it the doorbell made things *worse*: the bell rings,
    /// the first tick is inside the debounce window and emits nothing, and the
    /// edge that woke us has already been consumed - so the next look was a
    /// full interval away and a 200 ms debounce cost 500 ms.
    pub fn settling(self: *const Poller) bool {
        return self.dirty;
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
            if (self.seen_first) self.quiet_armed = true;
        }
        self.seen_first = true;
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
    /// One subprocess rather than walking the tree. The
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

/// How often the poll interval is interrupted to look at the stop flag. Small
/// enough that quitting is instant, large enough that an idle `lgtm` beside an
/// agent is still asleep almost all of the time.
const stop_check_ms = 25;

/// Runs a `Poller` on its own thread and posts to the event queue.
pub const Watcher = struct {
    poller: Poller,
    queue: *event.Queue,
    thread: ?std.Thread = null,
    stop_flag: std.atomic.Value(bool) = .init(false),
    /// The doorbell, when this OS has one and the directories opened. Null
    /// means every wait below is a plain sleep, which is what this did before
    /// there was a doorbell at all.
    bell: ?notify.Notify = null,

    pub fn init(gpa: Allocator, io: std.Io, queue: *event.Queue, opts: Options) Watcher {
        return .{
            .poller = Poller.init(gpa, io, opts),
            .queue = queue,
            .bell = notify.open(gpa, opts.watch_dirs),
        };
    }

    /// Whether the OS is telling us, rather than us asking. For a caller that
    /// wants to say so, and for a test that wants to know which path it took.
    pub fn native(self: *const Watcher) bool {
        return self.bell != null;
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
        if (self.bell) |*b| b.deinit();
        self.poller.deinit();
        self.* = undefined;
    }

    /// Sleeps, or waits on the doorbell, for up to `want` milliseconds. Returns
    /// how long it actually waited, so the caller's clock stays honest when the
    /// bell cuts the wait short - the debounce and the quiet period are both
    /// measured on that clock.
    ///
    /// Either way it is broken into slices, so `stop` is noticed without
    /// waiting the interval out: one long sleep made quitting take up to a poll
    /// interval *plus* a whole `git status`, which reads as a hang on the way
    /// out.
    fn waitForChange(self: *Watcher, want: i64) ?i64 {
        const io = self.poller.io;
        var waited: i64 = 0;
        while (waited < want) {
            const slice = @min(@as(i64, stop_check_ms), want - waited);
            if (self.bell) |*b| {
                const rang = b.wait(slice);
                waited += slice;
                if (self.stop_flag.load(.acquire)) return null;
                // Answered at once rather than sleeping out the rest: being
                // told is the whole point, and the debounce below still has to
                // agree the write has landed before anything is drawn.
                if (rang) return waited;
            } else {
                std.Io.sleep(io, .fromMilliseconds(slice), .awake) catch return null;
                waited += slice;
                if (self.stop_flag.load(.acquire)) return null;
            }
        }
        return waited;
    }

    fn loop(self: *Watcher) void {
        const poll = self.poller.opts.poll_ms;
        var elapsed: i64 = 0;
        while (!self.stop_flag.load(.acquire)) {
            // Advanced by what was actually waited, not by the interval that
            // was asked for. The doorbell cuts a wait short, and a clock that
            // counted the full interval anyway would run ahead of the wall -
            // which is the clock the debounce and the ten-second quiet period
            // are both measured against.
            // A settling change is come back for in a debounce, not in a poll
            // interval: the edge that woke us is spent, so waiting the long
            // interval out would charge every change the interval instead of
            // the debounce it is actually owed.
            const want = if (self.poller.settling()) self.poller.opts.debounce_ms else poll;
            const waited = self.waitForChange(want) orelse return;
            elapsed += waited;
            if (self.poller.tick(elapsed) catch null) |paths| {
                self.queue.push(.{ .files_changed = paths }) catch {
                    event.Queue.freePayload(self.poller.gpa, .{ .files_changed = paths });
                };
            }

            // The turn boundary, asked after the poll rather than folded into
            // it: a different question about the same tick.
            //
            // An event rather than the snapshot itself. This thread must not
            // write one: the store's turn numbers and its state file are also
            // touched by `m` on the main loop, and two threads numbering turns
            // is a race for the sake of moving work off a loop that is idle
            // anyway. Ten seconds into silence is by definition a moment when
            // nobody is typing, so the subprocess costs a frame nobody wanted.
            if (self.poller.quiet(elapsed)) {
                self.queue.push(.{ .agent_quiescent = .{ .files = 0, .added = 0, .removed = 0 } }) catch {};
            }
        }
    }
};

const testing = std.testing;

test "the doorbell shortens the wait but never replaces the poll" {
    // The contract the whole design rests on: an event decides *when* to ask,
    // and `git status` is still what answers. A watcher with no directories to
    // watch has no doorbell and must behave exactly as it did before there was
    // one - which is what makes an unsupported OS, a network mount and a blown
    // `inotify.max_user_watches` all degrade to latency rather than to
    // silence.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = testing.environ });
    defer threaded.deinit();
    var q = event.Queue.init(testing.allocator, threaded.io());
    defer q.deinit();

    var deaf = Watcher.init(testing.allocator, threaded.io(), &q, .{});
    defer deaf.deinit();
    try testing.expect(!deaf.native());

    var heard = Watcher.init(testing.allocator, threaded.io(), &q, .{ .watch_dirs = &.{"."} });
    defer heard.deinit();
    // Only where the OS has a backend; everywhere else the poller is the whole
    // story and that is a supported state, not a skipped test.
    if (notify.supported) try testing.expect(heard.native());
}

test "a settling change is come back for in a debounce, not a poll interval" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = testing.environ });
    defer threaded.deinit();

    var p = Poller.init(testing.allocator, threaded.io(), .{ .debounce_ms = 200 });
    defer p.deinit();

    // Nothing seen yet: the thread has a whole interval to wait.
    try testing.expect(!p.settling());

    // A change seen and not yet emitted. The edge that woke the thread is
    // spent, so a doorbell cannot ring again for it - and waiting the full
    // interval out would charge every change a poll interval instead of the
    // debounce it is owed, which would make the doorbell *worse* than polling.
    p.dirty = true;
    try testing.expect(p.settling());
}

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
            .poller = Poller.init(gpa, io, .{ .repo = dir, .debounce_ms = 200, .quiet_ms = 10_000 }),
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

test "quiet fires once after the writing stops, and only after a new change" {
    // The turn boundary the snapshot store takes its turns from
    //. A different question from debounce and a much longer
    // one: debounce asks whether a write has landed, this asks whether the
    // agent has stopped.
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{ .environ = testing.environ });
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try scratchDir(gpa, "lgtm-watch-quiet");
    defer gpa.free(dir);
    _ = try proc.run(gpa, io, &.{ "rm", "-rf", dir }, 1 << 20);

    var h = try Harness.init(gpa, io, dir);
    defer h.deinit();
    if (try h.tick(0)) |p| h.free(p);
    if (try h.tick(500)) |p| h.free(p);

    // Nothing has happened, so there is no silence to report. An agent turn
    // that changed nothing is not an event.
    try testing.expect(!h.poller.quiet(60_000));

    try h.write("a.txt", "one\n");
    if (try h.tick(1000)) |p| h.free(p);
    if (try h.tick(1400)) |p| h.free(p);

    // Still inside the quiet window: the agent may only be thinking.
    try testing.expect(!h.poller.quiet(5_000));
    // Ten seconds after the last write, the turn is over.
    try testing.expect(h.poller.quiet(11_400));
    // Once per burst, however long the silence goes on: six changed files are
    // one signal, and a silence that lasts an hour is still one silence.
    try testing.expect(!h.poller.quiet(30_000));
    try testing.expect(!h.poller.quiet(3_600_000));

    // A new change re-arms it, and nothing before it does.
    try h.write("b.txt", "two\n");
    if (try h.tick(40_000)) |p| h.free(p);
    try testing.expect(!h.poller.quiet(45_000));
    try testing.expect(h.poller.quiet(50_500));

    _ = try proc.run(gpa, io, &.{ "rm", "-rf", dir }, 1 << 20);
}

test "quiet_ms of zero is off, and costs nothing to leave off" {
    var p: Poller = .init(testing.allocator, undefined, .{});
    defer p.deinit();
    p.quiet_armed = true;
    p.last_change_ms = 0;
    // The default. Nothing asks for quiet detection until something does, and
    // an unasked-for timer that fires is worse than one that does not exist.
    try testing.expectEqual(@as(i64, 0), p.opts.quiet_ms);
    try testing.expect(!p.quiet(1 << 30));
}

test "a change made before the first poll is baseline, not a turn" {
    // Found by testing the wiring against a real repository and getting no
    // turn: the file had been written before lgtm's watcher had established
    // what was there, so the change was part of the baseline. Correct - a
    // first poll discovers, it does not observe - but it means edits in the
    // first half-second of a session are not a turn, and something looking for
    // one will wait forever rather than briefly.
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{ .environ = testing.environ });
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try scratchDir(gpa, "lgtm-watch-baseline");
    defer gpa.free(dir);
    _ = try proc.run(gpa, io, &.{ "rm", "-rf", dir }, 1 << 20);

    var h = try Harness.init(gpa, io, dir);
    defer h.deinit();

    // Written before anything has been polled.
    try h.write("a.txt", "already here\n");
    if (try h.tick(0)) |p| h.free(p);
    if (try h.tick(500)) |p| h.free(p);

    // However long the silence, there was no change to be silent after.
    try testing.expect(!h.poller.quiet(60_000));

    // A write after the baseline is a turn, and behaves normally.
    try h.write("b.txt", "new\n");
    if (try h.tick(61_000)) |p| h.free(p);
    try testing.expect(h.poller.quiet(72_000));

    _ = try proc.run(gpa, io, &.{ "rm", "-rf", dir }, 1 << 20);
}
