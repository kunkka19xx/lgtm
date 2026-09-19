// SPDX-License-Identifier: Apache-2.0
//
// Every agent pane on the machine, listed by one poller per backend so a slow one cannot stall the rest.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const bridge = @import("../bridge/bridge.zig");
const tmux = @import("../bridge/tmux.zig");
const wezterm = @import("../bridge/wezterm.zig");
const kitty = @import("../bridge/kitty.zig");
const herdr = @import("../bridge/herdr.zig");
const proc = @import("../io/proc.zig");
const local = @import("local.zig");
const notify = @import("notify.zig");
const wire = @import("wire.zig");

pub const Kind = enum { tmux, herdr, wezterm, kitty, pty };
const kinds = @typeInfo(Kind).@"enum".fields.len;

/// A listed pane, and what reaching it takes.
pub const Entry = struct {
    pane: wire.Pane,
    kind: Kind,
    /// The backend's own id; for `pty`, the socket's path.
    native: []const u8,
    tty: []const u8 = "",
};

const period_ms: i64 = 1_000;
/// A backend that is not running is asked again this much later; WezTerm takes seconds to say it is not.
const retry_ms: i64 = 15_000;
const list_max = 1 << 20;

fn nowMs(io: Io) i64 {
    return Io.Timestamp.now(io, .awake).toMilliseconds();
}

pub const Registry = struct {
    gpa: Allocator,
    io: Io,
    /// `[serve] panes = "all"`: list panes that are not agents too.
    all: bool,
    /// `[notify] url`; empty is off.
    url: []const u8,
    sock_dir: []const u8,
    log: *Io.Writer,
    log_mutex: Io.Mutex = .init,
    slots: [kinds]Slot = @splat(.{}),
    /// Moves whenever any backend's list changed.
    seq: std.atomic.Value(u32) = .init(0),
    /// Attached devices. Previews are only read while one is, or pushes are on.
    devices: std.atomic.Value(u32) = .init(0),

    /// Starts as an empty list's hash, so a backend with nothing to list is not a change.
    const Slot = struct { mutex: Io.Mutex = .init, batch: ?*Batch = null, hash: u64 = std.hash.Wyhash.hash(0, ""), live: bool = false };

    /// One poll's panes, alive while a reader holds it.
    pub const Batch = struct {
        arena: std.heap.ArenaAllocator,
        entries: []Entry = &.{},
        refs: std.atomic.Value(u32) = .init(1),

        fn release(b: *Batch, gpa: Allocator) void {
            if (b.refs.fetchSub(1, .acq_rel) != 1) return;
            b.arena.deinit();
            gpa.destroy(b);
        }
    };

    pub fn start(self: *Registry) void {
        inline for (0..kinds) |i| {
            if (std.Thread.spawn(.{}, poll, .{ self, @as(Kind, @enumFromInt(i)) })) |t| t.detach() else |_| {}
        }
    }

    pub const View = struct {
        gpa: Allocator,
        batches: [kinds]?*Batch,

        pub fn release(v: *View) void {
            for (v.batches) |b| if (b) |x| x.release(v.gpa);
        }

        pub fn find(v: *const View, id: []const u8) ?Entry {
            for (v.batches) |b| for (if (b) |x| x.entries else &.{}) |e| {
                if (std.mem.eql(u8, e.pane.id, id)) return e;
            };
            return null;
        }

        /// Whether some listed pane works in `repo`.
        pub fn works(v: *const View, repo: []const u8) bool {
            for (v.batches) |b| for (if (b) |x| x.entries else &.{}) |e| {
                if (e.pane.repo.len > 0 and std.mem.eql(u8, e.pane.repo, repo)) return true;
            };
            return false;
        }

        pub fn panes(v: *const View, arena: Allocator) Allocator.Error![]wire.Pane {
            var out: std.ArrayList(wire.Pane) = .empty;
            for (v.batches) |b| for (if (b) |x| x.entries else &.{}) |e| try out.append(arena, e.pane);
            return out.toOwnedSlice(arena);
        }
    };

    pub fn view(self: *Registry) View {
        var v: View = .{ .gpa = self.gpa, .batches = @splat(null) };
        for (&self.slots, &v.batches) |*s, *b| {
            s.mutex.lockUncancelable(self.io);
            defer s.mutex.unlock(self.io);
            if (s.batch) |x| _ = x.refs.fetchAdd(1, .acquire);
            b.* = s.batch;
        }
        return v;
    }

    pub fn say(self: *Registry, comptime fmt: []const u8, args: anytype) void {
        self.log_mutex.lockUncancelable(self.io);
        defer self.log_mutex.unlock(self.io);
        self.log.print("  " ++ fmt ++ "\n", args) catch {};
        self.log.flush() catch {};
    }

    /// Whether `kind` answered its last listing: it is running and reachable.
    pub fn live(self: *Registry, kind: Kind) bool {
        return self.slots[@intFromEnum(kind)].live;
    }

    fn active(self: *Registry) bool {
        return self.devices.load(.acquire) > 0 or self.url.len > 0;
    }

    fn poll(self: *Registry, kind: Kind) void {
        var mem: Memory = .{};
        var next: i64 = 0;
        while (true) {
            const now = nowMs(self.io);
            if (now >= next and self.active()) {
                const ok = self.cycle(kind, &mem, now);
                next = now + if (ok) period_ms else retry_ms;
            }
            self.io.sleep(.fromMilliseconds(250), .awake) catch return;
        }
    }

    fn cycle(self: *Registry, kind: Kind, mem: *Memory, now: i64) bool {
        const b = self.gpa.create(Batch) catch return false;
        b.* = .{ .arena = .init(self.gpa) };
        const arena = b.arena.allocator();
        const found = self.list(kind, arena) catch null;
        var keep: std.ArrayList(Entry) = .empty;
        for (found orelse &.{}) |e| {
            if (self.all or e.pane.agent.len > 0) keep.append(arena, e) catch break;
        }
        self.look(kind, arena, keep.items, mem, now) catch {};
        b.entries = keep.items;
        self.slots[@intFromEnum(kind)].live = found != null;
        self.publish(kind, b);
        return found != null;
    }

    fn publish(self: *Registry, kind: Kind, b: *Batch) void {
        var buf: std.Io.Writer.Allocating = .init(b.arena.allocator());
        for (b.entries) |e| std.json.Stringify.value(e.pane, .{}, &buf.writer) catch {};
        const hash = std.hash.Wyhash.hash(0, buf.written());
        const s = &self.slots[@intFromEnum(kind)];
        s.mutex.lockUncancelable(self.io);
        const old = s.batch;
        const changed = hash != s.hash;
        s.batch = b;
        s.hash = hash;
        s.mutex.unlock(self.io);
        if (old) |o| o.release(self.gpa);
        if (changed) _ = self.seq.fetchAdd(1, .release);
    }

    /// The listing, or an error when the backend is not there to ask.
    fn list(self: *Registry, kind: Kind, arena: Allocator) ![]Entry {
        if (kind == .pty) return fromLocal(arena, try local.list(self.gpa, arena, self.io, self.sock_dir));
        const jobs: ?[]const u8 = if (kind == .tmux or kind == .wezterm) blk: {
            const ps = proc.run(self.gpa, self.io, &.{ "ps", "-A", "-o", "pid=,tpgid=,tty=,comm=" }, list_max) catch break :blk null;
            defer ps.deinit(self.gpa);
            break :blk try arena.dupe(u8, ps.stdout);
        } else null;
        // Asked while no GUI runs, WezTerm fails slowly and leaves a log file behind each time.
        if (kind == .wezterm and !running(jobs orelse "", "wezterm-gui")) return error.Unavailable;
        const argv: []const []const u8 = switch (kind) {
            .tmux => &tmux_argv,
            .herdr => try herdr.listArgv(arena),
            .wezterm => try wezterm.listArgv(arena),
            .kitty => try kitty.listArgv(arena),
            .pty => unreachable,
        };
        const out = try proc.run(self.gpa, self.io, argv, list_max);
        defer out.deinit(self.gpa);
        if (out.exit_code != 0) return error.Unavailable;
        const text = try arena.dupe(u8, out.stdout);
        const entries = switch (kind) {
            .tmux => try parseTmux(arena, text),
            .herdr => try parseHerdr(arena, text),
            .wezterm => try parseWezterm(arena, text),
            .kitty => try parseKitty(arena, text),
            .pty => unreachable,
        };
        if (jobs) |ps| {
            const fg = try parseForeground(arena, ps);
            for (entries) |*e| {
                if (fg.get(ttyName(e.tty))) |name| e.pane.agent = name;
                if (!bridge.Bridge.looksLikeAgent(e.pane.agent)) e.pane.agent = "";
            }
        }
        return entries;
    }

    /// Repos, previews and state, and a push when an agent needs someone.
    fn look(self: *Registry, kind: Kind, arena: Allocator, entries: []Entry, mem: *Memory, now: i64) !void {
        mem.stamp +%= 1;
        const texts = try arena.alloc(?[]const u8, entries.len);
        @memset(texts, null);
        if (kind == .tmux) {
            const ids = try arena.alloc([]const u8, entries.len);
            for (entries, ids) |e, *id| id.* = e.native;
            if (tmux.capture(self.gpa, arena, self.io, ids) catch null) |caps| {
                for (caps, texts) |c, *t| t.* = c;
            }
        } else for (entries, texts) |e, *t| {
            t.* = read(self.gpa, self.io, arena, e) catch null;
        }

        for (entries, texts) |*e, text| {
            e.pane.repo = try mem.repo(self.gpa, self.io, e.pane.dir);
            const m = try mem.pane(self.gpa, e.pane.id);
            const t = text orelse continue;
            e.pane.preview = try preview(arena, t);
            const went_quiet = m.quiet.screen(std.hash.Wyhash.hash(0, t), now);
            const what: ?notify.Event = if (kind == .herdr) blk: {
                defer m.last = e.pane.state;
                break :blk notify.forStatus(m.last, e.pane.state);
            } else blk: {
                e.pane.state = m.quiet.state();
                e.pane.source = if (e.pane.state == .unknown) .none else .quiet;
                break :blk if (went_quiet) .quiet else null;
            };
            const event = what orelse continue;
            if (e.pane.agent.len == 0 or self.url.len == 0 or self.devices.load(.acquire) > 0) continue;
            if (now - m.pushed < notify.spacing_ms) continue;
            m.pushed = now;
            var buf: [256]u8 = undefined;
            const msg = notify.message(&buf, event, e.pane.agent, std.fs.path.basename(e.pane.dir));
            self.say("notified   {s}{s}", .{ msg, if (notify.post(self.gpa, self.io, self.url, msg)) "" else " (failed)" });
        }
        mem.prune(self.gpa);
    }
};

/// What a poller remembers between cycles, keyed by pane id.
const Memory = struct {
    stamp: u32 = 0,
    panes: std.StringHashMapUnmanaged(Seen) = .empty,
    repos: std.StringHashMapUnmanaged([]const u8) = .empty,

    const Seen = struct { stamp: u32 = 0, quiet: notify.Quiet = .{}, last: wire.AgentState = .unknown, pushed: i64 = -notify.spacing_ms };

    fn pane(m: *Memory, gpa: Allocator, id: []const u8) !*Seen {
        const got = try m.panes.getOrPut(gpa, id);
        if (!got.found_existing) {
            got.key_ptr.* = try gpa.dupe(u8, id);
            got.value_ptr.* = .{};
        }
        got.value_ptr.stamp = m.stamp;
        return got.value_ptr;
    }

    /// Drops panes that were not listed this cycle.
    fn prune(m: *Memory, gpa: Allocator) void {
        var it = m.panes.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.stamp == m.stamp) continue;
            const key = kv.key_ptr.*;
            m.panes.removeByPtr(kv.key_ptr);
            gpa.free(key);
            it = m.panes.iterator();
        }
    }

    /// The git repo holding `dir`, asked once per directory.
    /// Owned by the process: a repo string outlives every batch that names it.
    fn repo(m: *Memory, gpa: Allocator, io: Io, dir: []const u8) ![]const u8 {
        if (dir.len == 0) return "";
        if (m.repos.get(dir)) |r| return r;
        const top = blk: {
            const out = proc.run(gpa, io, &.{ "git", "-C", dir, "rev-parse", "--show-toplevel" }, 4096) catch break :blk "";
            defer out.deinit(gpa);
            break :blk if (out.exit_code == 0) try gpa.dupe(u8, std.mem.trimEnd(u8, out.stdout, "\n")) else "";
        };
        try m.repos.put(gpa, try gpa.dupe(u8, dir), top);
        return top;
    }
};

/// A pane's screen, whichever backend holds it.
pub fn read(gpa: Allocator, io: Io, arena: Allocator, e: Entry) error{ PaneGone, OutOfMemory }![]const u8 {
    if (e.kind == .pty) return local.read(arena, io, e.native);
    var br = bridgeFor(e.kind);
    var sink: Io.Writer.Discarding = .init(&.{});
    return br.read(.{ .gpa = gpa, .io = io, .w = &sink.writer }, arena, e.native) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.PaneGone,
    };
}

pub fn bridgeFor(kind: Kind) bridge.Bridge {
    return switch (kind) {
        .tmux => .{ .tmux = .{} },
        .herdr => .{ .herdr = .{} },
        .wezterm => .{ .wezterm = .{} },
        .kitty => .{ .kitty = .{} },
        .pty => unreachable,
    };
}

/// The last three rows with anything on them.
fn preview(arena: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    var rows: [3][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitBackwardsScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const row = std.mem.trimEnd(u8, raw, " \t\r");
        if (row.len == 0) continue;
        n += 1;
        rows[rows.len - n] = row;
        if (n == rows.len) break;
    }
    return arena.dupe([]const u8, rows[rows.len - n ..]);
}

const tmux_format = "#{pid}\t#{pane_id}\t#{session_name}\t#{window_index}:#{window_name}\t#{pane_current_path}\t#{pane_tty}\t#{pane_current_command}\t#{pane_title}";
const tmux_argv = [_][]const u8{ "tmux", "list-panes", "-a", "-F", tmux_format };

/// The server's pid is in the id because tmux reuses pane numbers after a restart.
fn parseTmux(arena: Allocator, text: []const u8) Allocator.Error![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var f = std.mem.splitScalar(u8, line, '\t');
        const pid = f.next() orelse continue;
        const id = f.next() orelse continue;
        if (id.len < 2 or id[0] != tmux.pane_sigil) continue;
        const session = f.next() orelse "";
        const window = f.next() orelse "";
        const dir = f.next() orelse "";
        const tty = f.next() orelse "";
        const current = f.next() orelse "";
        try out.append(arena, .{ .kind = .tmux, .native = id, .tty = tty, .pane = .{
            .id = try std.fmt.allocPrint(arena, "tmux:{s}:{s}", .{ pid, id }),
            .backend = "tmux",
            .group = try arena.dupe([]const u8, &.{ session, window }),
            .title = f.rest(),
            .dir = dir,
            .agent = current,
        } });
    }
    return out.toOwnedSlice(arena);
}

/// herdr names the agent and its state itself. The terminal id is in the pane's because pane ids restart with the server.
fn parseHerdr(arena: Allocator, text: []const u8) ![]Entry {
    const P = struct {
        pane_id: []const u8,
        cwd: []const u8 = "",
        workspace_id: []const u8 = "",
        tab_id: []const u8 = "",
        terminal_id: ?[]const u8 = null,
        terminal_title_stripped: []const u8 = "",
        agent: ?[]const u8 = null,
        agent_status: []const u8 = "",
    };
    const L = struct { result: ?struct { panes: []const P = &.{} } = null };
    const l = try std.json.parseFromSliceLeaky(L, arena, text, .{ .ignore_unknown_fields = true });
    var out: std.ArrayList(Entry) = .empty;
    for (if (l.result) |r| r.panes else &.{}) |p| {
        const agent = p.agent orelse "";
        try out.append(arena, .{ .kind = .herdr, .native = p.pane_id, .pane = .{
            .id = try std.fmt.allocPrint(arena, "herdr:{s}", .{p.terminal_id orelse p.pane_id}),
            .backend = "herdr",
            .group = try arena.dupe([]const u8, &.{ p.workspace_id, p.tab_id }),
            .title = p.terminal_title_stripped,
            .dir = p.cwd,
            .agent = agent,
            .state = if (agent.len > 0) std.meta.stringToEnum(wire.AgentState, p.agent_status) orelse .unknown else .unknown,
            .source = if (agent.len > 0) .herdr else .none,
        } });
    }
    return out.toOwnedSlice(arena);
}

/// The tty is in the id because WezTerm's pane numbers restart with the GUI.
fn parseWezterm(arena: Allocator, text: []const u8) ![]Entry {
    const P = struct { pane_id: u64, tab_id: u64 = 0, workspace: []const u8 = "", title: []const u8 = "", cwd: []const u8 = "", tty_name: []const u8 = "" };
    const list = try std.json.parseFromSliceLeaky([]const P, arena, text, .{ .ignore_unknown_fields = true });
    var out: std.ArrayList(Entry) = .empty;
    for (list) |p| {
        try out.append(arena, .{ .kind = .wezterm, .native = try std.fmt.allocPrint(arena, "{d}", .{p.pane_id}), .tty = p.tty_name, .pane = .{
            .id = try std.fmt.allocPrint(arena, "wezterm:{d}:{s}", .{ p.pane_id, ttyName(p.tty_name) }),
            .backend = "wezterm",
            .group = try arena.dupe([]const u8, &.{ p.workspace, try std.fmt.allocPrint(arena, "tab {d}", .{p.tab_id}) }),
            .title = p.title,
            .dir = urlPath(p.cwd),
        } });
    }
    return out.toOwnedSlice(arena);
}

/// The shell's pid is in the id because kitty's window numbers restart with kitty.
fn parseKitty(arena: Allocator, text: []const u8) ![]Entry {
    const Proc = struct { cmdline: []const []const u8 = &.{} };
    const W = struct { id: u64, title: []const u8 = "", cwd: []const u8 = "", pid: u64 = 0, foreground_processes: []const Proc = &.{} };
    const T = struct { title: []const u8 = "", windows: []const W = &.{} };
    const O = struct { id: u64 = 0, tabs: []const T = &.{} };
    const list = try std.json.parseFromSliceLeaky([]const O, arena, text, .{ .ignore_unknown_fields = true });
    var out: std.ArrayList(Entry) = .empty;
    for (list) |o| for (o.tabs) |t| for (t.windows) |w| {
        var agent: []const u8 = "";
        for (w.foreground_processes) |p| if (p.cmdline.len > 0) {
            agent = command(p.cmdline[0]);
            if (bridge.Bridge.looksLikeAgent(agent)) break;
        };
        try out.append(arena, .{ .kind = .kitty, .native = try std.fmt.allocPrint(arena, "{d}", .{w.id}), .pane = .{
            .id = try std.fmt.allocPrint(arena, "kitty:{d}:{d}", .{ w.id, w.pid }),
            .backend = "kitty",
            .group = try arena.dupe([]const u8, &.{ try std.fmt.allocPrint(arena, "window {d}", .{o.id}), t.title }),
            .title = w.title,
            .dir = w.cwd,
            .agent = if (bridge.Bridge.looksLikeAgent(agent)) agent else "",
        } });
    };
    return out.toOwnedSlice(arena);
}

fn fromLocal(arena: Allocator, agents: []const local.Agent) Allocator.Error![]Entry {
    const out = try arena.alloc(Entry, agents.len);
    for (agents, out) |a, *e| e.* = .{ .kind = .pty, .native = a.path, .pane = .{
        .id = try std.fmt.allocPrint(arena, "pty:{s}", .{a.pid}),
        .backend = "pty",
        .title = a.name,
        .dir = a.dir,
        .agent = a.name,
        .stream = true,
    } };
    return out;
}

/// Each terminal's foreground job, by tty name, from `ps -o pid=,tpgid=,tty=,comm=`.
fn parseForeground(arena: Allocator, text: []const u8) Allocator.Error!std.StringHashMapUnmanaged([]const u8) {
    var map: std.StringHashMapUnmanaged([]const u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        const pid = f.next() orelse continue;
        const tpgid = f.next() orelse continue;
        const tty = f.next() orelse continue;
        // The group leader is the job; its children, like a `caffeinate` an agent starts, are not.
        if (!std.mem.eql(u8, pid, tpgid)) continue;
        try map.put(arena, tty, command(lineCommand(line)));
    }
    return map;
}

/// Whether `ps` lists a process called `name`.
fn running(ps: []const u8, name: []const u8) bool {
    var lines = std.mem.tokenizeScalar(u8, ps, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, command(lineCommand(line)), name)) return true;
    }
    return false;
}

/// The `comm` column, which may hold spaces.
fn lineCommand(line: []const u8) []const u8 {
    var f = std.mem.tokenizeScalar(u8, line, ' ');
    for (0..3) |_| _ = f.next() orelse return "";
    return std.mem.trim(u8, f.rest(), " ");
}

/// `/usr/bin/zsh` and a login shell's `-zsh` are both `zsh`.
fn command(path: []const u8) []const u8 {
    return std.mem.trimStart(u8, std.fs.path.basename(path), "-");
}

fn ttyName(tty: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, tty, "/dev/")) tty["/dev/".len..] else tty;
}

/// `file://host/path` to `/path`.
fn urlPath(url: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, url, "file://")) return url;
    const rest = url["file://".len..];
    return rest[std.mem.indexOfScalar(u8, rest, '/') orelse rest.len ..];
}

const testing = std.testing;

test "tmux panes carry the server in their id and their session and window as the group" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const got = try parseTmux(a.allocator(), "4182\t%12\twork\t1:zsh\t/code/api\t/dev/ttys006\t2.1.274\t\xe2\x9c\xb3 fix\tretry\nbad line\n");
    try testing.expectEqual(@as(usize, 1), got.len);
    const p = got[0].pane;
    try testing.expectEqualStrings("tmux:4182:%12", p.id);
    try testing.expectEqualStrings("%12", got[0].native);
    try testing.expectEqualStrings("work", p.group[0]);
    try testing.expectEqualStrings("1:zsh", p.group[1]);
    try testing.expectEqualStrings("/code/api", p.dir);
    try testing.expectEqualStrings("\xe2\x9c\xb3 fix\tretry", p.title);
    try testing.expectEqualStrings("ttys006", ttyName(got[0].tty));
}

test "herdr's list gives the agent and its state, and the terminal makes the id" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const got = try parseHerdr(a.allocator(),
        \\{"id":"cli:pane:list","result":{"panes":[{"agent":"claude","agent_status":"blocked","cwd":"/code/api","pane_id":"w1:p1","tab_id":"w1:t1","terminal_id":"term_65bc","terminal_title_stripped":"claude","workspace_id":"w1"},{"agent_status":"unknown","cwd":"/code","pane_id":"w1:p2","tab_id":"w1:t1","workspace_id":"w1"}],"type":"pane_list"}}
    );
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("herdr:term_65bc", got[0].pane.id);
    try testing.expectEqualStrings("w1:p1", got[0].native);
    try testing.expect(got[0].pane.state == .blocked and got[0].pane.source == .herdr);
    try testing.expect(got[1].pane.agent.len == 0 and got[1].pane.source == .none);
}

test "wezterm and kitty listings parse, with the directory out of wezterm's url" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const w = try parseWezterm(a.allocator(),
        \\[{"window_id":0,"tab_id":2,"pane_id":5,"workspace":"default","title":"claude","cwd":"file://mac/Users/me/code","tty_name":"/dev/ttys004","size":{}}]
    );
    try testing.expectEqualStrings("wezterm:5:ttys004", w[0].pane.id);
    try testing.expectEqualStrings("/Users/me/code", w[0].pane.dir);

    const k = try parseKitty(a.allocator(),
        \\[{"id":1,"tabs":[{"id":1,"title":"t","windows":[{"id":3,"title":"claude","cwd":"/code","pid":900,"foreground_processes":[{"cmdline":["/usr/local/bin/claude"]}]},{"id":4,"pid":901,"foreground_processes":[{"cmdline":["-zsh"]}]}]}]}]
    );
    try testing.expectEqualStrings("kitty:3:900", k[0].pane.id);
    try testing.expectEqualStrings("claude", k[0].pane.agent);
    try testing.expectEqualStrings("", k[1].pane.agent);
}

test "the foreground job is the group leader, not its children" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const fg = try parseForeground(a.allocator(),
        \\  101   101 ttys006  claude
        \\  140   101 ttys006  caffeinate
        \\   90   200 ttys007  -zsh
        \\  200   200 ttys007  /usr/bin/less
        \\   80    -1 ??       launchd
    );
    try testing.expectEqualStrings("claude", fg.get("ttys006").?);
    try testing.expectEqualStrings("less", fg.get("ttys007").?);
    try testing.expect(fg.get("??") == null);
    try testing.expect(running("  7 1 ??  /Applications/WezTerm.app/Contents/MacOS/wezterm-gui\n", "wezterm-gui"));
    try testing.expect(!running("  7 1 ??  /usr/bin/wezterm\n", "wezterm-gui"));
}

test "a preview is the last three rows with anything on them" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const p = try preview(a.allocator(), "one\ntwo\n\nthree  \nfour\n\n  \n");
    try testing.expectEqual(@as(usize, 3), p.len);
    try testing.expectEqualStrings("two", p[0]);
    try testing.expectEqualStrings("three", p[1]);
    try testing.expectEqualStrings("four", p[2]);
    try testing.expectEqual(@as(usize, 1), (try preview(a.allocator(), "only")).len);
}
