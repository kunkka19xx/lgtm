// SPDX-License-Identifier: Apache-2.0
//
// `lgtm serve`: every agent pane on this machine, over a socket, to one paired device at a time.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const bridge = @import("../bridge/bridge.zig");
const fs = @import("../io/fs.zig");
const net = @import("../io/net.zig");
const proc = @import("../io/proc.zig");
const agent = @import("agent.zig");
const keys = @import("keys.zig");
const local = @import("local.zig");
const pair = @import("pair.zig");
const panes = @import("panes.zig");
const spawn = @import("spawn.zig");
const qr = @import("qr.zig");
const Host = @import("host.zig").Host;
const Reviewing = @import("reviewing.zig").Reviewing;
const config = @import("../config.zig");
const wire = @import("wire.zig");

pub const default_port: u16 = 7777;

pub const Options = struct {
    listen: []const u8 = "127.0.0.1",
    port: u16 = default_port,
    /// Replace the saved token, unpairing every device.
    new_token: bool = false,
    /// Draw the pairing QR code; off when stdout is not a terminal.
    qr: bool = true,
    /// `--listen` or `--port` was given, so `lgtm agent` serves too.
    explicit: bool = false,
};

const tick_ms = 50;
const hello_ms = 10_000;
/// The first list waits this long for a backend to answer, then goes, empty or not.
const first_list_ms = 2_000;
/// Some agents read text plus an instant Enter as a paste and insert a newline.
const submit_gap_ms = 120;

/// Serves until killed. Returns only if it could not start, with the reason printed.
pub fn run(gpa: Allocator, io: Io, environ: *const std.process.Environ.Map, w: *Io.Writer, opts: Options) !u8 {
    const addr = try address(w, opts) orelse return 1;
    var server = try listen(io, w, addr) orelse return 1;
    defer server.deinit(io);

    const d = try gpa.create(Daemon);
    if (!try d.setup(gpa, io, environ, w, opts)) return fail(w, "no HOME, so there is nowhere to keep the pairing token", .{});
    try d.banner(w, "lgtm serve", addr, opts);
    d.reg.start();
    accept(d, &server);
    return 0;
}

/// `lgtm agent`: runs the agent on a pty for `lgtm serve` to find, and serves it too when asked where.
pub fn host(gpa: Allocator, io: Io, environ: *const std.process.Environ.Map, w: *Io.Writer, opts: Options, argv: []const []const u8) !u8 {
    var server: ?net.Server = null;
    defer if (server) |*s| s.deinit(io);
    // The terminal belongs to the agent from here, so the daemon's log goes nowhere.
    var quiet: Io.Writer.Discarding = .init(&.{});
    var d: ?*Daemon = null;
    if (opts.explicit) {
        const addr = try address(w, opts) orelse return 1;
        server = try listen(io, w, addr) orelse return 1;
        const dm = try gpa.create(Daemon);
        const first = opts.new_token or !tokenSaved(io, environ);
        if (!try dm.setup(gpa, io, environ, &quiet.writer, opts)) return fail(w, "no HOME, so there is nowhere to keep the pairing token", .{});
        if (first) {
            try dm.banner(w, "lgtm agent", addr, opts);
            try w.print("  press Enter to start {s}\n", .{argv[0]});
            try w.flush();
            var buf: [64]u8 = undefined;
            _ = Io.File.stdin().readStreaming(io, &.{&buf}) catch 0;
        }
        d = dm;
    }

    const h = Host.start(gpa, io, argv) catch |err| return fail(w, "cannot start {s}: {t}", .{ argv[0], err });
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sock = local.listen(h, io, local.dir(environ, &dir_buf), std.fs.path.basename(argv[0]), fs.cwdPath(io, &cwd_buf) orelse "", &path_buf) catch null;
    defer if (sock) |p| fs.deleteFile(io, p);
    if (d) |dm| {
        dm.reg.start();
        detached(accept, .{ dm, &server.? });
    }
    return h.run();
}

fn tokenSaved(io: Io, environ: *const std.process.Environ.Map) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    return fs.fileExists(io, pair.tokenPath(environ, &buf) orelse return false);
}

fn detached(comptime f: anytype, args: anytype) void {
    if (std.Thread.spawn(.{}, f, args)) |t| t.detach() else |_| {}
}

/// A thread per connection, so a newcomer is answered while a device is attached.
fn accept(d: *Daemon, server: *net.Server) void {
    while (true) {
        const conn = server.accept(d.io) catch continue;
        if (std.Thread.spawn(.{}, Daemon.serve, .{ d, conn })) |t| t.detach() else |_| conn.close(d.io);
    }
}

/// The attached device, for the TUI; rewritten every `beat_ms` so a killed daemon's goes stale.
pub const attached_path = fs.state_dir ++ "/phone";
pub const beat_ms: i64 = 5_000;

fn address(w: *Io.Writer, opts: Options) !?net.Address {
    const addr = net.parseAddress(opts.listen, opts.port) catch {
        _ = try fail(w, "'{s}' is not an IP address", .{opts.listen});
        return null;
    };
    if (net.private(addr)) return addr;
    _ = try fail(w, "{f} is reachable from other machines; listen on 127.0.0.1 or a Tailscale address", .{addr});
    return null;
}

fn listen(io: Io, w: *Io.Writer, addr: net.Address) !?net.Server {
    return net.listen(io, addr) catch |err| {
        _ = try switch (err) {
            error.AlreadyServing => fail(w, "something already answers on {f}; pick another --port", .{addr}),
            else => fail(w, "cannot listen on {f}: {t}", .{ addr, err }),
        };
        return null;
    };
}

fn fail(w: *Io.Writer, comptime fmt: []const u8, args: anytype) Io.Writer.Error!u8 {
    try w.print("lgtm serve: " ++ fmt ++ "\n", args);
    try w.flush();
    return 1;
}

fn refuse(out: *Io.Writer, code: wire.Code, message: []const u8) Io.Writer.Error!void {
    return wire.write(out, .{ .@"error" = .{ .code = code, .message = message } });
}

fn gone(out: *Io.Writer, pane: []const u8) Io.Writer.Error!void {
    return wire.write(out, .{ .@"error" = .{ .code = .pane_gone, .message = "the pane is gone", .pane = pane } });
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, item)) return true;
    return false;
}

fn nowMs(io: Io) i64 {
    return Io.Timestamp.now(io, .awake).toMilliseconds();
}

/// Lines from the reader thread, as owned copies, and how the stream ended.
const Inbox = struct {
    gpa: Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    lines: std.ArrayList([]u8) = .empty,
    end: ?End = null,
    /// A reviewer's file views are far longer than anything a client sends.
    limit: usize = wire.max_line,

    const End = enum { closed, too_long };

    fn read(self: *Inbox, conn: net.Conn) void {
        const buf = self.gpa.alloc(u8, self.limit) catch return self.finish(.closed);
        defer self.gpa.free(buf);
        var r = conn.reader(self.io, buf);
        self.drain(&r.interface);
    }

    fn readFile(self: *Inbox, file: Io.File) void {
        const buf = self.gpa.alloc(u8, self.limit) catch return self.finish(.closed);
        defer self.gpa.free(buf);
        var r = file.readerStreaming(self.io, buf);
        self.drain(&r.interface);
    }

    fn drain(self: *Inbox, r: *Io.Reader) void {
        while (true) {
            const line = (r.takeDelimiter('\n') catch |err|
                return self.finish(if (err == error.StreamTooLong) .too_long else .closed)) orelse return self.finish(.closed);
            const copy = self.gpa.dupe(u8, line) catch return self.finish(.closed);
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.lines.append(self.gpa, copy) catch {
                self.gpa.free(copy);
                self.end = .closed;
                return;
            };
        }
    }

    fn finish(self: *Inbox, end: End) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.end = end;
    }

    fn take(self: *Inbox) Allocator.Error!struct { lines: [][]u8, end: ?End } {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{ .lines = try self.lines.toOwnedSlice(self.gpa), .end = self.end };
    }

    fn free(self: *Inbox, lines: []const []u8) void {
        for (lines) |l| self.gpa.free(l);
    }
};

/// Everything a connection needs, alive for the daemon's life.
const Daemon = struct {
    gpa: Allocator,
    io: Io,
    cfg: config.Loader,
    reg: panes.Registry,
    /// The repo `lgtm serve` runs in, the review a phone starts on; empty outside one.
    root: []const u8,
    /// `[serve] agents` by name, and `[serve] dirs` with `~` expanded: what `spawn` accepts.
    agents: []const []const u8 = &.{},
    dirs: []const []const u8 = &.{},
    /// One child per repo a phone is reviewing, owned by the attached device's loop.
    reviewers: std.ArrayList(*Reviewer) = .empty,
    token: pair.Token,
    name: []const u8,
    name_buf: [std.posix.HOST_NAME_MAX]u8,
    root_buf: [std.fs.max_path_bytes]u8,
    sock_buf: [std.fs.max_path_bytes]u8,
    /// Every send and key a device made, beside the token.
    audit_path: []const u8,
    audit_buf: [std.fs.max_path_bytes]u8,
    /// The attached device's connection; a newer one takes over from it.
    owner: std.atomic.Value(u32) = .init(0),
    next: std.atomic.Value(u32) = .init(0),
    /// Held by the attached device's loop, so two never touch a pane at once.
    slot: Io.Mutex = .init,

    /// In place: the slices point into the daemon's own buffers. False when there is nowhere to keep the token.
    fn setup(d: *Daemon, gpa: Allocator, io: Io, environ: *const std.process.Environ.Map, log: *Io.Writer, opts: Options) !bool {
        var token_buf: [std.fs.max_path_bytes]u8 = undefined;
        const token_path = pair.tokenPath(environ, &token_buf) orelse return false;
        d.* = .{
            .gpa = gpa,
            .io = io,
            .cfg = config.load(gpa, io, environ, null),
            .reg = undefined,
            .root = "",
            .token = try pair.loadOrCreate(io, gpa, token_path, opts.new_token),
            .name = "",
            .name_buf = undefined,
            .root_buf = undefined,
            .sock_buf = undefined,
            .audit_path = "",
            .audit_buf = undefined,
        };
        d.audit_path = std.fmt.bufPrint(&d.audit_buf, "{s}/serve.log", .{std.fs.path.dirname(token_path) orelse "."}) catch "";
        const host_name = std.posix.gethostname(&d.name_buf) catch "";
        d.name = if (std.mem.endsWith(u8, host_name, ".local")) host_name[0 .. host_name.len - ".local".len] else host_name;
        d.reg = .{
            .gpa = gpa,
            .io = io,
            .all = d.cfg.cfg.serve_all,
            .url = d.cfg.cfg.notify,
            .sock_dir = local.dir(environ, &d.sock_buf),
            .log = log,
        };
        const names = try gpa.alloc([]const u8, d.cfg.cfg.serve_agents.len);
        for (d.cfg.cfg.serve_agents, names) |c, *n| n.* = spawn.name(c);
        d.agents = names;
        const dirs = try gpa.alloc([]const u8, d.cfg.cfg.serve_dirs.len);
        const home = environ.get("HOME") orelse "";
        for (d.cfg.cfg.serve_dirs, dirs) |dir, *o| o.* = if (std.mem.startsWith(u8, dir, "~/")) try std.mem.concat(gpa, u8, &.{ home, dir[1..] }) else dir;
        d.dirs = dirs;
        const top = proc.run(gpa, io, &.{ "git", "rev-parse", "--show-toplevel" }, 4096) catch return true;
        defer top.deinit(gpa);
        const root = std.mem.trimEnd(u8, top.stdout, "\n");
        if (top.exit_code != 0 or root.len == 0 or root.len > d.root_buf.len) return true;
        @memcpy(d.root_buf[0..root.len], root);
        d.root = d.root_buf[0..root.len];
        return true;
    }

    fn banner(d: *Daemon, w: *Io.Writer, title: []const u8, addr: net.Address, opts: Options) !void {
        var url_buf: [256]u8 = undefined;
        var url: Io.Writer = .fixed(&url_buf);
        try pair.writeUrl(&url, opts.listen, opts.port, &d.token, d.name);

        try w.print("{s}  every agent on {s}\n  listening  {f}\n", .{ title, d.name, addr });
        if (opts.qr) {
            if (qr.encode(url.buffered())) |code| try qr.render(w, &code) else |_| {}
        }
        try w.print("  pair       {s}\n  token      {s}\n", .{ url.buffered(), &d.token.hex });
        if (net.loopback(addr)) try w.writeAll("  note       a phone cannot reach loopback; use --listen $(tailscale ip -4)\n");
        try w.flush();
    }

    fn serve(d: *Daemon, conn: net.Conn) void {
        const me = d.next.fetchAdd(1, .monotonic) + 1;
        var held = false;
        defer if (held) {
            d.reap(null, 0);
            _ = d.reg.devices.fetchSub(1, .release);
            d.slot.unlock(d.io);
        };
        var inbox: Inbox = .{ .gpa = d.gpa, .io = d.io };
        defer {
            inbox.free(inbox.lines.items);
            inbox.lines.deinit(d.gpa);
        }
        const thread = std.Thread.spawn(.{}, Inbox.read, .{ &inbox, conn }) catch return conn.close(d.io);
        defer {
            conn.shutdown(d.io);
            thread.join();
            conn.close(d.io);
        }
        var wbuf: [16 << 10]u8 = undefined;
        var cw = conn.writer(d.io, &wbuf);
        const out = &cw.interface;

        var device_buf: [64]u8 = undefined;
        var device: ?[]const u8 = null;
        const started = nowMs(d.io);
        var listed: u32 = 0;
        var sent_list = false;
        var attached_at: i64 = 0;
        var watch_buf: [128]u8 = undefined;
        var watching: []const u8 = "";
        var screen: agent.Screen = .{};
        var pacer: agent.Pacer = .{};
        var next_capture: i64 = 0;
        var pane_gone = false;
        var review: ?*Reviewer = null;
        var submit_buf: [128]u8 = undefined;
        var submit_to: []const u8 = "";
        var beat: i64 = 0;

        serving: while (true) {
            var frame: std.heap.ArenaAllocator = .init(d.gpa);
            defer frame.deinit();
            const arena = frame.allocator();
            var view = d.reg.view();
            defer view.release();

            const got = inbox.take() catch break;
            defer {
                inbox.free(got.lines);
                d.gpa.free(got.lines);
            }
            for (got.lines) |line| {
                const msg = wire.parse(arena, line) catch |err| {
                    const code: wire.Code = switch (err) {
                        error.UnknownType => .unknown_type,
                        error.MissingField => .missing_field,
                        else => .malformed,
                    };
                    refuse(out, code, "not a message this daemon reads") catch break :serving;
                    if (device != null) continue;
                    d.reg.say("refused    {t}", .{code});
                    break :serving;
                };
                if (device == null) {
                    const bad: ?struct { wire.Code, []const u8 } = switch (msg) {
                        .hello => |h| if (h.version != wire.version)
                            .{ .version, "this daemon speaks protocol version 1" }
                        else if (!d.token.matches(h.token))
                            .{ .token, "wrong token" }
                        else
                            null,
                        else => .{ .no_hello, "say hello first" },
                    };
                    if (bad) |b| {
                        refuse(out, b[0], b[1]) catch {};
                        d.reg.say("refused    {t}", .{b[0]});
                        break :serving;
                    }
                    const name = if (msg.hello.device.len > 0) msg.hello.device else "a device";
                    const n = @min(name.len, device_buf.len);
                    @memcpy(device_buf[0..n], name[0..n]);
                    device = device_buf[0..n];
                    // The newest device wins, so a phone that dropped without closing cannot lock itself out.
                    d.owner.store(me, .release);
                    d.slot.lockUncancelable(d.io);
                    held = true;
                    _ = d.reg.devices.fetchAdd(1, .release);
                    attached_at = nowMs(d.io);
                    d.reg.say("attached   {s}", .{device.?});
                    wire.write(out, .{ .session = .{ .version = wire.version, .host = d.name, .review = d.root, .agents = d.agents, .dirs = d.dirs } }) catch break :serving;
                    continue;
                }
                switch (msg) {
                    .hello => {},
                    .ping => wire.write(out, .pong) catch break :serving,
                    .watch => |wt| {
                        const n = @min(wt.pane.len, watch_buf.len);
                        @memcpy(watch_buf[0..n], wt.pane[0..n]);
                        watching = watch_buf[0..n];
                        screen = .{};
                        pacer.wake();
                        next_capture = 0;
                        pane_gone = false;
                        if (view.find(watching)) |e| if (e.kind == .pty) local.announce(arena, d.io, e.native, device.?);
                    },
                    .send => |s| {
                        const e = view.find(s.pane) orelse {
                            gone(out, s.pane) catch break :serving;
                            continue;
                        };
                        const sent = d.deliver(arena, e, s.text, s.submit);
                        d.audit(device.?, if (sent.submitted) "send+enter" else "send", s.pane, s.text);
                        d.reg.say("sent       {d} bytes to {s}{s}{s}", .{
                            s.text.len,
                            s.pane,
                            if (sent.submitted) ", submitted" else "",
                            if (sent.ok) "" else ", failed",
                        });
                        wire.write(out, .{ .sent = .{ .pane = s.pane, .ok = sent.ok, .submitted = sent.submitted, .why = sent.why } }) catch break :serving;
                        pacer.wake();
                        next_capture = 0;
                    },
                    .key => |k| {
                        const e = view.find(k.pane) orelse {
                            gone(out, k.pane) catch break :serving;
                            continue;
                        };
                        const key = std.meta.stringToEnum(keys.Key, k.key) orelse {
                            refuse(out, .unknown_key, "not a key this daemon presses") catch break :serving;
                            continue;
                        };
                        const pressed = d.press(arena, e, key);
                        d.reg.say("key        {s} to {s}{s}", .{ k.key, k.pane, if (pressed.ok) "" else ", failed" });
                        d.audit(device.?, "key", k.pane, k.key);
                        wire.write(out, .{ .sent = .{ .pane = k.pane, .ok = pressed.ok, .submitted = false, .why = pressed.why } }) catch break :serving;
                        pacer.wake();
                        next_capture = 0;
                    },
                    .review => |r| {
                        review = null;
                        if (r.repo.len == 0) continue;
                        // Only a repo an agent works in: anything else would read any repo on the machine.
                        if (!view.works(r.repo) and !std.mem.eql(u8, r.repo, d.root)) {
                            refuse(out, .no_review, "no agent works in that repo") catch break :serving;
                            continue;
                        }
                        review = d.reviewer(r.repo, device.?) catch {
                            refuse(out, .no_review, "the review could not start") catch break :serving;
                            continue;
                        };
                        review.?.send(d.io, line);
                    },
                    .spawn => |sp| {
                        const done: @FieldType(wire.Outbound, "spawned") = blk: {
                            const cmd = d.command(sp.agent) orelse break :blk .{ .ok = false, .why = "not one of [serve] agents" };
                            if (!view.works(sp.dir) and !contains(d.dirs, sp.dir)) break :blk .{ .ok = false, .why = "only a directory from [serve] dirs, or one an agent works in" };
                            const id = spawn.open(d.gpa, d.io, arena, &d.reg, cmd, sp.dir) catch |err| break :blk .{ .ok = false, .why = switch (err) {
                                error.NoMultiplexer => "tmux is not installed, and no herdr or kitty is running",
                                else => "the agent could not be opened",
                            } };
                            d.audit(device.?, "open", id orelse sp.dir, cmd);
                            break :blk .{ .ok = true, .pane = id orelse "" };
                        };
                        d.reg.say("open       {s} in {s}{s}", .{ sp.agent, sp.dir, if (done.ok) "" else ", refused" });
                        wire.write(out, .{ .spawned = done }) catch break :serving;
                    },
                    .close => |c| {
                        const e = view.find(c.pane) orelse {
                            gone(out, c.pane) catch break :serving;
                            continue;
                        };
                        const why: ?[]const u8 = if (e.pane.agent.len == 0) "only an agent's pane can be closed" else if (spawn.close(d.gpa, d.io, arena, e)) |_| null else |err| switch (err) {
                            error.NotHere => "stop it where it runs",
                            else => "the pane could not be closed",
                        };
                        if (why == null) d.audit(device.?, "close", c.pane, e.pane.agent);
                        d.reg.say("close      {s}{s}", .{ c.pane, if (why == null) "" else ", refused" });
                        wire.write(out, .{ .closed = .{ .ok = why == null, .pane = c.pane, .why = why orelse "" } }) catch break :serving;
                    },
                    .open, .comment, .uncomment => {
                        const rv = review orelse {
                            refuse(out, .no_review, "choose a repo to review first") catch break :serving;
                            continue;
                        };
                        rv.send(d.io, line);
                    },
                    .submit => |s| {
                        const rv = review orelse {
                            refuse(out, .no_review, "choose a repo to review first") catch break :serving;
                            continue;
                        };
                        const e = view.find(s.pane);
                        const why: ?[]const u8 = if (e == null) "the pane is gone" else if (!std.mem.eql(u8, e.?.pane.repo, rv.repo)) "that agent works in another repo" else null;
                        if (why) |w| {
                            wire.write(out, .{ .submitted = .{ .ok = false, .why = w } }) catch break :serving;
                            continue;
                        }
                        const n = @min(s.pane.len, submit_buf.len);
                        @memcpy(submit_buf[0..n], s.pane[0..n]);
                        submit_to = submit_buf[0..n];
                        rv.send(d.io, line);
                    },
                }
            }
            if (got.end) |end| {
                if (end == .too_long) refuse(out, .too_long, "a line longer than 64 KiB") catch {};
                break;
            }

            const now = nowMs(d.io);
            if (device) |name| {
                if (d.owner.load(.acquire) != me) {
                    refuse(out, .replaced, "another device connected") catch {};
                    break;
                }
                if (review) |rv| {
                    rv.used = now;
                    if (now - beat >= beat_ms) {
                        beat = now;
                        rv.send(d.io, "{\"type\":\"ping\"}");
                    }
                    const from = rv.inbox.take() catch break;
                    defer {
                        rv.inbox.free(from.lines);
                        d.gpa.free(from.lines);
                    }
                    for (from.lines) |l| {
                        if (!std.mem.startsWith(u8, l, "{\"type\":\"written\"")) {
                            out.writeAll(l) catch break;
                            out.writeByte('\n') catch break;
                            continue;
                        }
                        const done = d.delivered(arena, l, view.find(submit_to));
                        d.reg.say("review     {s}{s}", .{ done.path, if (done.ok) "" else ", failed" });
                        if (done.ok) d.audit(name, "review", submit_to, done.path);
                        wire.write(out, .{ .submitted = done }) catch break;
                        pacer.wake();
                        next_capture = 0;
                    }
                    if (from.end != null) {
                        rv.used = 0;
                        review = null;
                        refuse(out, .no_review, "the review stopped") catch break;
                    }
                }
                d.reap(review, now);
                const seq = d.reg.seq.load(.acquire);
                if (seq != listed or (!sent_list and now - attached_at > first_list_ms)) {
                    listed = seq;
                    sent_list = true;
                    wire.write(out, .{ .panes = .{ .panes = view.panes(arena) catch break } }) catch break;
                }
                if (watching.len > 0 and now >= next_capture) {
                    if (view.find(watching)) |e| {
                        if (panes.read(d.gpa, d.io, arena, e)) |text| {
                            pane_gone = false;
                            const rows = screen.changed(arena, text) catch break;
                            if (rows) |r| wire.write(out, .{ .screen = .{ .pane = watching, .rows = r } }) catch break;
                            next_capture = if (e.pane.stream) now else now + pacer.after(rows != null);
                        } else |err| switch (err) {
                            error.OutOfMemory => break,
                            error.PaneGone => {
                                if (!pane_gone) gone(out, watching) catch break;
                                pane_gone = true;
                                next_capture = now + pacer.after(false);
                            },
                        }
                    } else if (sent_list and !pane_gone) {
                        gone(out, watching) catch break;
                        pane_gone = true;
                    }
                }
            } else if (now - started > hello_ms) {
                refuse(out, .no_hello, "say hello first") catch {};
                break;
            }

            out.flush() catch break;
            d.io.sleep(.fromMilliseconds(tick_ms), .awake) catch break;
        }
        // Every way out of the loop may have left a reason unsent.
        out.flush() catch {};
        if (device) |name| d.reg.say("detached   {s}", .{name});
    }

    /// The configured command called `name`.
    fn command(d: *Daemon, name: []const u8) ?[]const u8 {
        for (d.agents, d.cfg.cfg.serve_agents) |n, c| if (std.mem.eql(u8, n, name)) return c;
        return null;
    }

    fn reviewer(d: *Daemon, repo: []const u8, device: []const u8) !*Reviewer {
        for (d.reviewers.items) |r| if (std.mem.eql(u8, r.repo, repo)) return r;
        const r = try Reviewer.start(d.gpa, d.io, repo, device);
        d.reviewers.append(d.gpa, r) catch |err| {
            r.stop(d.gpa, d.io);
            return err;
        };
        return r;
    }

    /// Stops reviewers nobody looked at for `idle_ms`, all but `keep`; every one when `now` is 0.
    fn reap(d: *Daemon, keep: ?*Reviewer, now: i64) void {
        var i: usize = 0;
        while (i < d.reviewers.items.len) {
            const r = d.reviewers.items[i];
            if (r == keep or (now != 0 and now - r.used < idle_ms)) {
                i += 1;
                continue;
            }
            _ = d.reviewers.swapRemove(i);
            r.stop(d.gpa, d.io);
        }
    }

    /// The reviewer wrote the review; the daemon tells the agent, with Enter.
    fn delivered(d: *Daemon, arena: Allocator, line: []const u8, to: ?panes.Entry) @FieldType(wire.Outbound, "submitted") {
        const w = std.json.parseFromSliceLeaky(Written, arena, line, .{ .ignore_unknown_fields = true }) catch return .{ .ok = false, .why = "the review could not be written" };
        if (!w.ok) return .{ .ok = false, .why = w.why };
        const e = to orelse return .{ .ok = false, .path = w.path, .count = w.count, .why = "the pane is gone" };
        const sent = d.deliver(arena, e, w.line, true);
        return .{ .ok = sent.ok, .path = w.path, .count = w.count, .why = sent.why };
    }

    const Sent = struct { ok: bool, submitted: bool = false, why: []const u8 = "" };

    fn press(d: *Daemon, arena: Allocator, e: panes.Entry, key: keys.Key) Sent {
        if (e.kind == .pty) return if (local.write(arena, d.io, e.native, keys.bytes(key))) .{ .ok = true } else .{ .ok = false, .why = "the agent has exited" };
        const argv = keys.argv(arena, e.kind, e.native, key) catch return .{ .ok = false, .why = "out of memory" };
        const res = proc.run(d.gpa, d.io, argv, 4096) catch return .{ .ok = false, .why = "the key was not pressed" };
        defer res.deinit(d.gpa);
        return if (res.exit_code == 0) .{ .ok = true } else .{ .ok = false, .why = "the key was not pressed" };
    }

    /// One line per action, in UTC: when, which device, what, where, and the text.
    fn audit(d: *Daemon, device: []const u8, what: []const u8, pane: []const u8, text: []const u8) void {
        if (d.audit_path.len == 0) return;
        const secs: u64 = @intCast(@max(0, Io.Timestamp.now(d.io, .real).toSeconds()));
        const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
        const yd = es.getEpochDay().calculateYearDay();
        const md = yd.calculateMonthDay();
        const ds = es.getDaySeconds();
        var buf: [8 << 10]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z  {s}  {s}  {s}  {f}\n", .{
            yd.year,                 md.month.numeric(),      md.day_index + 1,
            ds.getHoursIntoDay(),    ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
            device,                  what,                    pane,
            std.json.fmt(text, .{}),
        }) catch return;
        fs.appendSecretFile(d.io, d.audit_path, line) catch {};
    }

    fn deliver(d: *Daemon, arena: Allocator, e: panes.Entry, text: []const u8, submit: bool) Sent {
        var sink: Io.Writer.Discarding = .init(&.{});
        const cx: bridge.Ctx = .{ .gpa = d.gpa, .io = d.io, .w = &sink.writer };
        var br: bridge.Bridge = if (e.kind == .pty) .osc52 else panes.bridgeFor(e.kind);
        if (e.kind == .pty) {
            const payload = bridge.normalise(arena, text) catch |err| return refused(err);
            if (!local.write(arena, d.io, e.native, payload)) return .{ .ok = false, .why = "the agent has exited" };
        } else {
            br.panes().?.setPane(e.native);
            const outcome = br.sendText(cx, text) catch |err| return refused(err);
            if (outcome == .copied) return .{ .ok = false, .why = outcome.copied orelse "copied to the clipboard instead" };
        }
        if (!submit) return .{ .ok = true };
        d.io.sleep(.fromMilliseconds(submit_gap_ms), .awake) catch {};
        const why: ?[]const u8 = if (e.kind == .pty)
            (if (local.write(arena, d.io, e.native, "\r")) null else "the agent has exited")
        else
            br.submit(cx) catch "submit failed";
        return .{ .ok = true, .submitted = why == null, .why = why orelse "" };
    }

    fn refused(err: bridge.Error) Sent {
        return .{ .ok = false, .why = switch (err) {
            error.Multiline => "a newline would press Enter; send one line at a time",
            error.NoTarget => "no pane to send to",
            else => "the send failed",
        } };
    }
};

const idle_ms: i64 = 60_000;

/// What a reviewer answers a `submit` with: the review is written, and `line` is what the agent is told.
const Written = struct { type: []const u8 = "written", ok: bool, line: []const u8 = "", path: []const u8 = "", count: u32 = 0, why: []const u8 = "" };

/// A `lgtm __review` child for one repo, and the lines it has sent.
const Reviewer = struct {
    repo: []u8,
    child: std.process.Child,
    inbox: Inbox,
    thread: std.Thread,
    used: i64,

    fn start(gpa: Allocator, io: Io, repo: []const u8, device: []const u8) !*Reviewer {
        var a: std.heap.ArenaAllocator = .init(gpa);
        defer a.deinit();
        const r = try gpa.create(Reviewer);
        errdefer gpa.destroy(r);
        r.* = .{
            .repo = try gpa.dupe(u8, repo),
            .child = undefined,
            .inbox = .{ .gpa = gpa, .io = io, .limit = 32 << 20 },
            .thread = undefined,
            .used = nowMs(io),
        };
        errdefer gpa.free(r.repo);
        r.child = try proc.spawnSelf(io, a.allocator(), repo, &.{ review_verb, device });
        r.thread = std.Thread.spawn(.{}, Inbox.readFile, .{ &r.inbox, r.child.stdout.? }) catch |err| {
            r.child.kill(io);
            return err;
        };
        return r;
    }

    fn send(r: *Reviewer, io: Io, line: []const u8) void {
        const in = r.child.stdin orelse return;
        in.writeStreamingAll(io, line) catch {};
        in.writeStreamingAll(io, "\n") catch {};
    }

    /// Closing its stdin ends the child; `wait` closes the rest.
    fn stop(r: *Reviewer, gpa: Allocator, io: Io) void {
        if (r.child.stdin) |f| f.close(io);
        r.child.stdin = null;
        r.thread.join();
        _ = r.child.wait(io) catch {};
        r.inbox.free(r.inbox.lines.items);
        r.inbox.lines.deinit(gpa);
        gpa.free(r.repo);
        gpa.destroy(r);
    }
};

pub const review_verb = "__review";

/// `lgtm __review <device>`: one repo's review, run in that repo for `lgtm serve`, until stdin closes.
pub fn reviewer(gpa: Allocator, io: Io, environ: *const std.process.Environ.Map, device: []const u8) !u8 {
    const cfg = config.load(gpa, io, environ, null);
    const desk = try Reviewing.start(gpa, io, cfg.cfg.ignore, cfg.cfg.templates);
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = fs.cwdPath(io, &cwd_buf) orelse "";
    var inbox: Inbox = .{ .gpa = gpa, .io = io };
    const t = try std.Thread.spawn(.{}, Inbox.readFile, .{ &inbox, Io.File.stdin() });
    t.detach();
    var wbuf: [64 << 10]u8 = undefined;
    var fw = Io.File.stdout().writerStreaming(io, &wbuf);
    const out = &fw.interface;
    var open_buf: [4096]u8 = undefined;
    var open: ?[]const u8 = null;
    var heard: i64 = 0;
    var beat: i64 = 0;
    var asked = false;
    // The TUI in this repo shows the device while pings come, and nobody once they stop.
    defer if (beat != 0) fs.writeStateFile(io, attached_path, "") catch {};

    while (true) {
        var frame: std.heap.ArenaAllocator = .init(gpa);
        defer frame.deinit();
        const arena = frame.allocator();
        const got = try inbox.take();
        defer {
            inbox.free(got.lines);
            gpa.free(got.lines);
        }
        const now = nowMs(io);
        for (got.lines) |line| {
            const msg = wire.parse(arena, line) catch continue;
            heard = now;
            switch (msg) {
                .review => asked = true,
                .open => |o| {
                    const n = @min(o.path.len, open_buf.len);
                    @memcpy(open_buf[0..n], o.path[0..n]);
                    open = open_buf[0..n];
                    try sendFile(out, arena, desk, open.?);
                },
                .comment => |c| {
                    const id = desk.comment(c.path, c.new, c.old, c.text) catch |err| {
                        try wire.write(out, .{ .noted = .{ .ok = false, .why = switch (err) {
                            error.Empty => "nothing to say",
                            error.NoSuchFile => "that file is no longer in the review",
                            error.NoSuchLine => "that line is no longer in the diff",
                            else => "the comment could not be saved",
                        } } });
                        continue;
                    };
                    try wire.write(out, .{ .noted = .{ .ok = true, .id = id } });
                    try sendReview(out, arena, desk, repo, open);
                },
                .uncomment => |u| {
                    desk.uncomment(u.id);
                    try sendReview(out, arena, desk, repo, open);
                },
                .submit => {
                    const w: Written = if (desk.submit(arena)) |done|
                        .{ .ok = true, .line = done.line, .path = done.path, .count = done.count }
                    else |err|
                        .{ .ok = false, .why = if (err == error.NothingToSend) "no comments to send" else "the review could not be written" };
                    try std.json.Stringify.value(w, .{}, out);
                    try out.writeByte('\n');
                    try sendReview(out, arena, desk, repo, open);
                },
                else => {},
            }
        }
        if (got.end != null) return 0;
        if ((desk.refresh() catch false) or asked) {
            asked = false;
            try sendReview(out, arena, desk, repo, open);
        }
        if (now - heard < 2 * beat_ms and now - beat >= beat_ms) {
            beat = now;
            fs.writeStateFile(io, attached_path, device) catch {};
        }
        try out.flush();
        io.sleep(.fromMilliseconds(tick_ms), .awake) catch return 0;
    }
}

fn sendReview(out: *Io.Writer, arena: Allocator, desk: *Reviewing, repo: []const u8, open: ?[]const u8) !void {
    try wire.write(out, .{ .files = .{ .repo = repo, .files = try desk.files(arena) } });
    if (open) |path| try sendFile(out, arena, desk, path);
}

fn sendFile(out: *Io.Writer, arena: Allocator, desk: *Reviewing, path: []const u8) !void {
    if (try desk.file(arena, path)) |view| try wire.write(out, .{ .file = view });
}

test {
    _ = net;
    _ = @import("notify.zig");
    _ = @import("reviewing.zig");
    _ = @import("vt.zig");
    _ = agent;
    _ = keys;
    _ = spawn;
    _ = local;
    _ = pair;
    _ = panes;
    _ = qr;
    _ = wire;
}
