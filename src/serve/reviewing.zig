// SPDX-License-Identifier: Apache-2.0
//
// The review for the phone: the TUI's diff, and comments only this daemon writes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const template = @import("../bridge/template.zig");
const comments = @import("../core/comments.zig");
const diff = @import("../core/diff.zig");
const event = @import("../core/event.zig");
const git = @import("../core/git.zig");
const report = @import("../core/review.zig");
const fs = @import("../io/fs.zig");
const watch = @import("../io/watch.zig");
const lexer = @import("../syntax/lexer.zig");
const Review = @import("../ui/review.zig").Review;
const wire = @import("wire.zig");

/// Not `comments.jsonl`, which the TUI rewrites whole and would drop these from.
pub const notes_path = fs.state_dir ++ "/phone.jsonl";

pub const Reviewing = struct {
    gpa: Allocator,
    io: Io,
    review: Review,
    notes: comments.Store,
    queue: event.Queue,
    watcher: watch.Watcher,
    templates: template.Table,
    diffed: bool = false,

    /// Heap-allocated: the watcher holds a pointer to the queue.
    pub fn start(gpa: Allocator, io: Io, ignore: []const []const u8, templates: template.Table) !*Reviewing {
        fs.ensureSelfIgnore(io);
        const self = try gpa.create(Reviewing);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .review = .init(gpa, io),
            .notes = .init(gpa),
            .queue = .init(gpa, io),
            .watcher = undefined,
            .templates = templates,
        };
        self.review.ignore = ignore;
        if (fs.readFile(io, gpa, notes_path, 4 << 20)) |bytes| {
            defer gpa.free(bytes);
            try comments.read(&self.notes, bytes);
        } else |_| {}
        const dirs = git.trackedDirs(gpa, io) catch &.{};
        self.watcher = .init(gpa, io, &self.queue, .{ .watch_dirs = dirs });
        try self.watcher.start();
        return self;
    }

    /// Diffs the first time and whenever the tree moved. True when it did.
    pub fn refresh(self: *Reviewing) !bool {
        var moved = !self.diffed;
        const events = try self.queue.tryDrain(self.gpa);
        defer {
            for (events) |ev| event.Queue.freePayload(self.gpa, ev);
            self.gpa.free(events);
        }
        for (events) |ev| moved = moved or ev == .files_changed;
        if (!moved) return false;

        // Each commented file's text before the diff, so its comments can follow the edit.
        var before: std.StringHashMapUnmanaged([]u8) = .empty;
        defer {
            var it = before.valueIterator();
            while (it.next()) |v| self.gpa.free(v.*);
            before.deinit(self.gpa);
        }
        for (self.notes.items()) |c| {
            if (before.contains(c.path)) continue;
            const work = self.review.buffersFor(c.path).work;
            try before.put(self.gpa, c.path, try self.gpa.dupe(u8, if (work) |b| b.bytes else ""));
        }

        _ = try self.review.regenerate(.{});
        var it = before.iterator();
        while (it.next()) |e| {
            const now = self.review.buffersFor(e.key_ptr.*).work orelse continue;
            if (self.diffed) try self.notes.carry(e.key_ptr.*, e.value_ptr.*, now.bytes) else self.notes.reconcile(e.key_ptr.*, now.bytes);
        }
        self.diffed = true;
        if (self.notes.dirty) self.save();
        return true;
    }

    pub fn files(self: *Reviewing, arena: Allocator) Allocator.Error![]const wire.FileEntry {
        const all = self.review.files();
        const out = try arena.alloc(wire.FileEntry, all.len);
        for (all, out) |f, *e| e.* = .{
            .path = f.path(),
            .status = @tagName(f.status),
            .added = f.added,
            .removed = f.removed,
            .comments = self.countAt(f.path()),
        };
        return out;
    }

    pub fn file(self: *Reviewing, arena: Allocator, path: []const u8) !?wire.FileView {
        const f = self.find(path) orelse return null;
        if (f.summarised) _ = try self.review.expand(path);
        const bufs = self.review.buffersFor(path);
        const work_runs = self.review.runsFor(path, f.new_blob, bufs.work);
        const head_runs = self.review.runsFor(path, f.old_blob, bufs.head);

        const n = f.lines.len();
        const lines = try arena.alloc(wire.Line, n);
        for (lines, 0..) |*l, i| {
            const kind = f.lines.kind[i];
            const old = kind == .del;
            const no = if (old) f.lines.old_no[i] else f.lines.new_no[i];
            l.* = .{ .kind = kind, .old = f.lines.old_no[i], .new = f.lines.new_no[i], .text = f.lines.text[i], .runs = &.{} };
            const buf = (if (old) bufs.head else bufs.work) orelse continue;
            if (no == 0 or no > buf.lineCount()) continue;
            const lo = buf.starts[no - 1];
            const hi: u32 = lo + @as(u32, @intCast(l.text.len));
            var runs: std.ArrayList([3]u32) = .empty;
            for (lexer.runsIn(if (old) head_runs else work_runs, lo, hi)) |r| {
                const s = @max(r.start, lo);
                const e = @min(r.end(), hi);
                if (e > s and r.kind != .text) try runs.append(arena, .{ s - lo, e - s, @intFromEnum(r.kind) });
            }
            l.runs = runs.items;
        }

        const hunks = try arena.alloc(wire.HunkHead, f.hunks.len);
        for (f.hunks, hunks) |h, *out| out.* = .{ .at = h.lo, .section = h.section };

        var notes: std.ArrayList(wire.Note) = .empty;
        for (self.notes.items()) |c| {
            if (!std.mem.eql(u8, c.path, path)) continue;
            try notes.append(arena, .{ .id = c.id, .line = c.line, .body = c.body, .state = c.state.name(), .removed = c.about_removed });
        }
        return .{ .path = path, .status = @tagName(f.status), .lines = lines, .hunks = hunks, .notes = notes.items };
    }

    /// `new` is 0 on a removed line, which lands where the TUI puts one: the hunk's first surviving line.
    pub fn comment(self: *Reviewing, path: []const u8, new: u32, old: u32, body: []const u8) !u32 {
        if (std.mem.trim(u8, body, " \t\r\n").len == 0) return error.Empty;
        const f = self.find(path) orelse return error.NoSuchFile;
        const L = f.lines;
        var line = new;
        if (line == 0) {
            const i = for (0..L.len()) |i| {
                if (L.kind[i] == .del and L.old_no[i] == old) break i;
            } else return error.NoSuchLine;
            const h = for (f.hunks) |h| {
                if (i >= h.lo and i < h.hi) break h;
            } else return error.NoSuchLine;
            line = h.new_start;
            for (h.lo..h.hi) |j| if (L.new_no[j] != 0) {
                line = L.new_no[j];
                break;
            };
        }
        const anchor = for (0..L.len()) |i| {
            if (L.new_no[i] == line) break L.text[i];
        } else "";
        const id = try self.notes.addFull(path, line, body, anchor, new == 0, 1);
        self.save();
        return id;
    }

    /// Marks a comment sent, as the TUI's send-now does, and gives the one line that tells the agent.
    pub fn say(self: *Reviewing, arena: Allocator, id: u32) ![]const u8 {
        const n = self.notes.find(id) orelse return error.NoSuchLine;
        n.state = .sent;
        self.notes.dirty = true;
        self.save();
        const body = try arena.dupe(u8, std.mem.trim(u8, n.body, " \t\r\n"));
        for (body) |*c| if (c.* == '\n' or c.* == '\r') {
            c.* = ' ';
        };
        return std.fmt.allocPrint(arena, "{s}:{d} - {s}", .{ n.path, n.line, body });
    }

    pub fn uncomment(self: *Reviewing, id: u32) void {
        self.notes.remove(id);
        self.save();
    }

    pub const Submitted = struct { path: []const u8, count: u32, line: []const u8 };

    /// Writes `phone-review-N.md`, a name the TUI never writes, and returns the line that tells the agent.
    pub fn submit(self: *Reviewing, arena: Allocator) !Submitted {
        if (self.notes.openCount() == 0) return error.NothingToSend;
        var n: u32 = 1;
        var name_buf: [64]u8 = undefined;
        var path: []const u8 = undefined;
        while (true) : (n += 1) {
            path = try std.fmt.bufPrint(&name_buf, fs.state_dir ++ "/phone-review-{d}.md", .{n});
            if (!fs.fileExists(self.io, path)) break;
        }
        var md: std.ArrayList(u8) = .empty;
        const written = try report.render(&md, arena, &self.notes, n, "");
        try fs.writeStateFile(self.io, path, md.items);
        self.notes.markSent();
        self.save();

        const count = try std.fmt.allocPrint(arena, "{d}", .{written.total()});
        var line: std.ArrayList(u8) = .empty;
        try template.render(arena, &line, self.templates.submit_review, &.{
            .{ .name = "path", .value = path },
            .{ .name = "count", .value = count },
            .{ .name = "s", .value = if (written.total() == 1) "" else "s" },
        });
        return .{ .path = try arena.dupe(u8, path), .count = written.total(), .line = line.items };
    }

    fn find(self: *Reviewing, path: []const u8) ?*diff.FileDiff {
        for (self.review.files()) |*f| if (std.mem.eql(u8, f.path(), path)) return f;
        return null;
    }

    fn countAt(self: *const Reviewing, path: []const u8) u32 {
        var n: u32 = 0;
        for (self.notes.items()) |c| n += @intFromBool(c.state != .sent and std.mem.eql(u8, c.path, path));
        return n;
    }

    fn save(self: *Reviewing) void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.gpa);
        comments.write(&buf, self.gpa, &self.notes) catch return;
        fs.writeStateFile(self.io, notes_path, buf.items) catch return;
        self.notes.dirty = false;
    }
};
