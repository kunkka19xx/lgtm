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

pub const Event = union(enum) {
    key: Key,
    /// Owned by the queue until drained; paths are freed by the consumer.
    files_changed: []const []const u8,
    resize: Size,
    quit,
    // Later: lsp_response, agent_edit (ACP), task_done.
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
        self.items.deinit(self.gpa);
        self.* = undefined;
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

test "all six modes are declared" {
    try std.testing.expectEqual(@as(usize, 6), @typeInfo(Mode).@"enum".fields.len);
}
