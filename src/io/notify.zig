// SPDX-License-Identifier: Apache-2.0
//
// The doorbell: the OS saying a watched directory moved, so the watcher can
// stop asking twice a second whether anything has.
//
// A fourth quarantine file beside `fs.zig`, `proc.zig` and `tty.zig`, and for
// the same reason they exist: the raw syscalls live in exactly one place and
// nothing above `io/` knows they were made. Hard rule 5 names three files
// because there were three OS concerns when it was written; change
// notification is a fourth of the same shape, not an exception to it.
//
// **It is a doorbell and not an answer.** kqueue says "something in `src/ui`
// changed"; it does not say what, and it cannot say whether the change is one
// git would report. `io/watch.zig` still runs `git status` afterwards, which
// is the only thing that knows about `.gitignore`, about content that matched
// HEAD anyway, and about a file saved with no edit in it. All this removes is
// the *asking when nothing happened*, which is almost all of the asking.
//
// **What is watched is the directories that contain tracked files**, which the
// caller supplies. That set is what makes this cheap and correct at once: it
// is about two dozen entries in a repository of this size, and it excludes
// build output by construction rather than by matching patterns. Pointing a
// watcher at the repository root instead would mean an event per file of a
// 6 GB `.zig-cache` on every build, and a `git status` storm behind it - worse
// than the polling it replaced, and the reason a naive version of this is a
// trap rather than an improvement.
//
// **Unsupported is a normal state.** No backend for this OS, a failed
// `kqueue`, a directory that will not open, a filesystem with no notification
// at all: every one of them returns null and `io/watch.zig` sleeps out its
// poll interval exactly as it did before. The poller is never removed, because
// network mounts, containers and `inotify.max_user_watches` all need it.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// Whether this build has a backend at all. Checked by the caller only to
/// decide what to say about itself; `open` returning null is the real answer.
pub const supported = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .openbsd, .dragonfly => true,
    .linux => true,
    else => false,
};

/// The most directories one process will watch.
///
/// A repository with more distinct directories of tracked files than this is
/// one where the poller's `git status` is the cheaper answer anyway, so the
/// cap degrades to polling rather than to a partial watch that would miss
/// changes and never say so.
pub const max_dirs: usize = 4096;

pub const Notify = struct {
    /// The queue or inotify descriptor.
    fd: std.posix.fd_t,
    /// Directory descriptors, kqueue only: the queue holds a reference to each
    /// and they have to outlive it. Empty on inotify, where the watch is a
    /// number owned by the queue itself.
    dirs: []std.posix.fd_t,
    gpa: Allocator,

    pub fn deinit(self: *Notify) void {
        for (self.dirs) |fd| closeFd(fd);
        self.gpa.free(self.dirs);
        closeFd(self.fd);
        self.* = undefined;
    }

    /// Blocks until a watched directory changes or `timeout_ms` passes.
    /// True means something fired; false means the timeout did.
    ///
    /// False is not an error and not "nothing changed" either - it is only
    /// "nothing was reported in this window". The caller polls on the timeout
    /// regardless, which is what keeps a missed event costing latency rather
    /// than correctness.
    pub fn wait(self: *Notify, timeout_ms: i64) bool {
        return backend.wait(self, timeout_ms);
    }
};

/// Watches every directory in `dirs`. Null when this OS has no backend, when
/// the queue cannot be created, or when nothing in `dirs` could be opened -
/// all of which mean the caller polls.
///
/// A directory that will not open is skipped rather than fatal: a permission
/// error on one path is not a reason to give up notification for the rest.
pub fn open(gpa: Allocator, dirs: []const []const u8) ?Notify {
    if (!supported or dirs.len == 0 or dirs.len > max_dirs) return null;
    return backend.open(gpa, dirs);
}

const backend = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .openbsd, .dragonfly => Kqueue,
    .linux => Inotify,
    else => Unsupported,
};

/// `std.posix` in 0.16 has no `close`: descriptors are `std.Io.File` there,
/// and these are raw queue and directory descriptors that never become one.
///
/// Per OS, because `std.c.close` is only reachable where libc is linked -
/// which macOS and the BSDs always do and Linux does not. Going through
/// `std.os.linux` there is the same syscall without the dependency, and a
/// switch on `builtin.os.tag` analyses only the arm it takes.
fn closeFd(fd: std.posix.fd_t) void {
    switch (builtin.os.tag) {
        .linux => _ = std.os.linux.close(fd),
        .macos, .ios, .tvos, .watchos, .visionos, .driverkit, .maccatalyst => _ = std.c.close(fd),
        .freebsd, .netbsd, .openbsd, .dragonfly => _ = std.c.close(fd),
        // No backend, so nothing was ever opened to close.
        else => {},
    }
}

const Unsupported = struct {
    fn open(_: Allocator, _: []const []const u8) ?Notify {
        return null;
    }
    fn wait(_: *Notify, _: i64) bool {
        return false;
    }
};

/// BSD and macOS. One descriptor per directory, registered with `EV.CLEAR` so
/// each report is an edge: the queue does not keep telling us a directory that
/// changed once is still changed.
const Kqueue = struct {
    /// Every way a directory's contents can move. `WRITE` covers a file being
    /// created or removed inside it, which is the case that matters; the rest
    /// are the directory itself going away under us.
    const vnode_mask: u32 = std.c.NOTE.WRITE | std.c.NOTE.EXTEND | std.c.NOTE.DELETE |
        std.c.NOTE.RENAME | std.c.NOTE.LINK | std.c.NOTE.REVOKE;

    fn open(gpa: Allocator, dirs: []const []const u8) ?Notify {
        const kq = std.c.kqueue();
        if (kq < 0) return null;
        var ok = false;
        defer if (!ok) closeFd(kq);

        var fds: std.ArrayList(std.posix.fd_t) = .empty;
        defer fds.deinit(gpa);
        var changes: std.ArrayList(std.posix.Kevent) = .empty;
        defer changes.deinit(gpa);

        for (dirs) |path| {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            if (path.len >= buf.len) continue;
            @memcpy(buf[0..path.len], path);
            buf[path.len] = 0;
            const z: [*:0]const u8 = @ptrCast(&buf);

            const raw = std.c.open(z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true });
            if (raw < 0) continue;
            const fd: std.posix.fd_t = raw;
            fds.append(gpa, fd) catch {
                closeFd(fd);
                continue;
            };
            changes.append(gpa, .{
                .ident = @intCast(fd),
                .filter = std.c.EVFILT.VNODE,
                .flags = std.c.EV.ADD | std.c.EV.CLEAR,
                .fflags = vnode_mask,
                .data = 0,
                .udata = 0,
            }) catch {};
        }
        if (fds.items.len == 0) return null;

        // Registration only: no eventlist, no timeout, so this returns at once.
        const zero: std.c.timespec = .{ .sec = 0, .nsec = 0 };
        if (std.c.kevent(kq, changes.items.ptr, @intCast(changes.items.len), undefined, 0, &zero) < 0) {
            for (fds.items) |fd| closeFd(fd);
            return null;
        }

        const owned = fds.toOwnedSlice(gpa) catch {
            for (fds.items) |fd| closeFd(fd);
            return null;
        };
        ok = true;
        return .{ .fd = kq, .dirs = owned, .gpa = gpa };
    }

    fn wait(self: *Notify, timeout_ms: i64) bool {
        var out: [16]std.posix.Kevent = undefined;
        const ms = @max(timeout_ms, 0);
        const ts: std.c.timespec = .{
            .sec = @intCast(@divTrunc(ms, 1000)),
            .nsec = @intCast(@mod(ms, 1000) * std.time.ns_per_ms),
        };
        const n = std.c.kevent(self.fd, undefined, 0, &out, out.len, &ts);
        return n > 0;
    }
};

/// Linux. One descriptor for the whole set, and a watch number per directory
/// which the queue owns - so there is nothing to close but the queue itself.
const Inotify = struct {
    const mask: u32 = std.os.linux.IN.CREATE | std.os.linux.IN.DELETE |
        std.os.linux.IN.MODIFY | std.os.linux.IN.MOVED_TO | std.os.linux.IN.MOVED_FROM |
        std.os.linux.IN.CLOSE_WRITE | std.os.linux.IN.MOVE_SELF | std.os.linux.IN.DELETE_SELF;

    /// The raw syscalls rather than a `std.posix` wrapper: 0.16 has none for
    /// inotify, and these return a `usize` that is an errno when it is
    /// negative. A failure at any point here means the caller polls, so every
    /// one of them is a `return null` rather than an error to carry upwards.
    fn open(gpa: Allocator, dirs: []const []const u8) ?Notify {
        const rc = std.os.linux.inotify_init1(std.os.linux.IN.NONBLOCK | std.os.linux.IN.CLOEXEC);
        if (std.os.linux.errno(rc) != .SUCCESS) return null;
        const fd: std.posix.fd_t = @intCast(rc);
        var ok = false;
        defer if (!ok) closeFd(fd);

        var added: usize = 0;
        for (dirs) |path| {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            if (path.len >= buf.len) continue;
            @memcpy(buf[0..path.len], path);
            buf[path.len] = 0;
            const z: [*:0]const u8 = @ptrCast(&buf);
            const w = std.os.linux.inotify_add_watch(fd, z, mask);
            // A directory that will not open is skipped, not fatal: a
            // permission error on one path is not a reason to give up
            // notification for the rest.
            if (std.os.linux.errno(w) != .SUCCESS) continue;
            added += 1;
        }
        if (added == 0) return null;

        ok = true;
        return .{ .fd = fd, .dirs = gpa.alloc(std.posix.fd_t, 0) catch return null, .gpa = gpa };
    }

    fn wait(self: *Notify, timeout_ms: i64) bool {
        var pfd = [_]std.posix.pollfd{.{ .fd = self.fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const n = std.posix.poll(&pfd, @intCast(@max(timeout_ms, 0))) catch return false;
        if (n == 0) return false;
        // Drained, or the descriptor stays readable and every later wait
        // returns at once on an event already accounted for.
        var buf: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
        while (true) {
            const got = std.posix.read(self.fd, &buf) catch break;
            if (got < buf.len) break;
        }
        return true;
    }
};

const testing = std.testing;

test "an empty or oversized watch set has no backend to offer" {
    // Nothing to watch is not a failure, it is a repository with no tracked
    // files - and the caller has to poll either way.
    try testing.expect(open(testing.allocator, &.{}) == null);
}

test "a path that cannot be opened is skipped rather than fatal" {
    if (!supported) return error.SkipZigTest;
    // One real directory and one that does not exist: the watch is built from
    // what opened, because a permission error on one path is not a reason to
    // give up notification for the rest.
    var n = open(testing.allocator, &.{ ".", "/nonexistent-lgtm-test-path" }) orelse return error.SkipZigTest;
    defer n.deinit();
    try testing.expect(n.fd >= 0);
}

test "waiting with nothing happening times out rather than blocking" {
    if (!supported) return error.SkipZigTest;
    var n = open(testing.allocator, &.{"."}) orelse return error.SkipZigTest;
    defer n.deinit();
    // A short timeout on a quiet directory: false means "nothing reported in
    // this window", which is what makes the caller poll anyway.
    try testing.expect(!n.wait(1));
}
