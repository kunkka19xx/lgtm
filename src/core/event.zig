// SPDX-License-Identifier: Apache-2.0
//
// All modes and event variants are declared now and populated later
// (ARCHITECTURE.md 11.4). Declaring them costs nothing; retrofitting a
// dispatch refactor does not.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Mode = enum {
    normal,
    visual,
    note_input,
    finder,
    /// The `?` overlay. Its own mode so that the keys which close it are rows
    /// in the keymap like everything else, and so every other binding is
    /// invisible while it is up rather than firing behind it.
    help,
    // Not reachable in v0.1. Present so dispatch never grows an `if (in_visual)`.
    insert,
    command,
};

pub const Size = struct { cols: u16, rows: u16 };

pub const Key = struct {
    codepoint: u21,
    mods: Mods,

    pub const Mods = packed struct(u8) {
        shift: bool = false,
        ctrl: bool = false,
        alt: bool = false,
        super: bool = false,
        _pad: u4 = 0,
    };
};

/// Codepoints for the keys that are not characters. These are the C0 controls
/// a terminal actually sends, which is also what vaxis reports, so `io/input`
/// stays a copy rather than a translation table - and `io/input.zig` has a
/// test that pins them to vaxis's own constants so a library change is a
/// failing test rather than a dead keybinding.
pub const code = struct {
    pub const tab: u21 = 0x09;
    pub const enter: u21 = 0x0d;
    pub const escape: u21 = 0x1b;
    pub const backspace: u21 = 0x7f;
    /// Kitty functional keycodes, well outside anything a keyboard types as
    /// text. Bound as aliases where a Ctrl chord might be eaten by whatever
    /// multiplexer the user runs under.
    pub const left: u21 = 57350;
    pub const right: u21 = 57351;
    pub const up: u21 = 57352;
    pub const down: u21 = 57353;
};

pub const Event = union(enum) {
    key: Key,
    /// Owned by the queue until drained; paths are freed by the consumer.
    files_changed: []const []const u8,
    resize: Size,
    quit,
    /// Not produced in v0.1. The agent stopped writing and left changes behind
    /// (docs/NOTIFICATIONS.md 3.1). Declared now because phase 5 writes the
    /// dispatch switch, and this is what `task_done` was always going to be.
    agent_quiescent: struct { files: u32, added: u32, removed: u32 },
    /// Not produced in v0.1 (docs/SNAPSHOTS.md 7). `ref` is owned by the queue
    /// until drained and freed by the consumer, like `files_changed`.
    snapshot_taken: struct { turn: u32, ref: []const u8 },
    // Later: lsp_response, agent_edit (ACP).
};

/// The single meeting point between the watch thread and the main loop
/// (ARCHITECTURE.md 3, PERFORMANCE.md 9). Mutex and condvar, not lock-free:
/// event rates are tens per second.
pub const Queue = struct {
    items: std.ArrayList(Event),
    mutex: std.Io.Mutex,
    cond: std.Io.Condition,
    closed: bool,
    gpa: Allocator,
    io: std.Io,

    pub fn init(gpa: Allocator, io: std.Io) Queue {
        return .{
            .items = .empty,
            .mutex = .init,
            .cond = .init,
            .closed = false,
            .gpa = gpa,
            .io = io,
        };
    }

    pub fn deinit(self: *Queue) void {
        // Undrained events still own their payloads - the contract above says
        // the queue holds them until a consumer takes them. Quitting with a
        // `files_changed` still queued is ordinary, not exceptional: the
        // watch thread pushes on its own clock.
        for (self.items.items) |ev| freePayload(self.gpa, ev);
        self.items.deinit(self.gpa);
        self.* = undefined;
    }

    /// Frees whatever an event owns. Consumers that drain call this too.
    pub fn freePayload(gpa: Allocator, ev: Event) void {
        switch (ev) {
            .files_changed => |paths| {
                for (paths) |p| gpa.free(p);
                gpa.free(paths);
            },
            .snapshot_taken => |s| gpa.free(s.ref),
            else => {},
        }
    }

    pub fn push(self: *Queue, ev: Event) Allocator.Error!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.items.append(self.gpa, ev);
        self.cond.signal(self.io);
    }

    pub fn close(self: *Queue) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.closed = true;
        self.cond.broadcast(self.io);
    }

    /// Blocks until at least one event is available, then moves all of them out
    /// in one lock acquisition. Returns an empty slice only once closed.
    /// Caller owns the returned slice.
    pub fn drain(self: *Queue, gpa: Allocator) Allocator.Error![]Event {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.items.items.len == 0 and !self.closed) {
            self.cond.waitUncancelable(self.io, &self.mutex);
        }
        const out = try gpa.dupe(Event, self.items.items);
        self.items.clearRetainingCapacity();
        return out;
    }

    /// Whether anything is waiting, without taking it. What a paced loop asks
    /// between the slices of one frame's sleep, so a keystroke arriving
    /// mid-animation waits a slice rather than a whole frame.
    pub fn pending(self: *Queue) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.items.items.len > 0 or self.closed;
    }

    /// Non-blocking variant for the render loop.
    pub fn tryDrain(self: *Queue, gpa: Allocator) Allocator.Error![]Event {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const out = try gpa.dupe(Event, self.items.items);
        self.items.clearRetainingCapacity();
        return out;
    }
};

test "queue drains in one acquisition" {
    const testing = std.testing;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var q = Queue.init(testing.allocator, threaded.io());
    defer q.deinit();

    try q.push(.{ .resize = .{ .cols = 80, .rows = 24 } });
    try q.push(.quit);

    const events = try q.drain(testing.allocator);
    defer testing.allocator.free(events);

    try testing.expectEqual(@as(usize, 2), events.len);
    try testing.expectEqual(@as(u16, 80), events[0].resize.cols);
    try testing.expectEqual(Event.quit, events[1]);
}

test "pending reports what is waiting without taking it" {
    const testing = std.testing;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var q = Queue.init(testing.allocator, threaded.io());
    defer q.deinit();

    try testing.expect(!q.pending());
    try q.push(.{ .resize = .{ .cols = 80, .rows = 24 } });
    try testing.expect(q.pending());
    // Reporting is not taking: the event is still there to drain.
    try testing.expect(q.pending());
    const events = try q.tryDrain(testing.allocator);
    defer testing.allocator.free(events);
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expect(!q.pending());

    // A closed queue is always ready: the waiter has to wake up and see it.
    q.close();
    try testing.expect(q.pending());
}

test "tryDrain returns empty without blocking" {
    const testing = std.testing;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var q = Queue.init(testing.allocator, threaded.io());
    defer q.deinit();

    const events = try q.tryDrain(testing.allocator);
    defer testing.allocator.free(events);
    try testing.expectEqual(@as(usize, 0), events.len);
}

test "drain unblocks on close" {
    const testing = std.testing;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var q = Queue.init(testing.allocator, threaded.io());
    defer q.deinit();

    q.close();
    const events = try q.drain(testing.allocator);
    defer testing.allocator.free(events);
    try testing.expectEqual(@as(usize, 0), events.len);
}

test "deinit frees the payloads of events nobody drained" {
    // Quitting with a `files_changed` still queued is ordinary rather than
    // exceptional: the watch thread pushes on its own clock, and the main loop
    // stops the moment `q` is pressed. The testing allocator is the assertion.
    const testing = std.testing;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var q = Queue.init(testing.allocator, threaded.io());

    const paths = try testing.allocator.alloc([]const u8, 2);
    paths[0] = try testing.allocator.dupe(u8, "src/a.zig");
    paths[1] = try testing.allocator.dupe(u8, "src/b.zig");
    try q.push(.{ .files_changed = paths });
    try q.push(.{ .snapshot_taken = .{ .turn = 3, .ref = try testing.allocator.dupe(u8, "HEAD~1") } });
    // An event that owns nothing must survive the same pass untouched.
    try q.push(.quit);

    q.deinit();
}

test "all seven modes are declared" {
    // Six from the original set, plus `help` - added when `?` gained an
    // overlay whose close keys had to be keymap rows like any other.
    try std.testing.expectEqual(@as(usize, 7), @typeInfo(Mode).@"enum".fields.len);
}

test "unreachable event variants are declared, not retrofitted" {
    // Same reasoning as the modes above: two of these six are unproducible in
    // v0.1, and declaring them costs nothing next to revisiting every dispatch
    // site later (ARCHITECTURE.md 11.4).
    try std.testing.expectEqual(@as(usize, 6), @typeInfo(Event).@"union".fields.len);
}
