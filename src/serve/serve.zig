// SPDX-License-Identifier: Apache-2.0
//
// `lgtm serve`: the agent's pane, over a socket, to one paired device at a time.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const bridge = @import("../bridge/bridge.zig");
const fs = @import("../io/fs.zig");
const net = @import("../io/net.zig");
const agent = @import("agent.zig");
const pair = @import("pair.zig");
const qr = @import("qr.zig");
const status = @import("status.zig");
const wire = @import("wire.zig");

pub const default_port: u16 = 7777;

pub const Options = struct {
    listen: []const u8 = "127.0.0.1",
    port: u16 = default_port,
    pane: ?[]const u8 = null,
    /// Replace the saved token, unpairing every device.
    new_token: bool = false,
    /// Draw the pairing QR code; off when stdout is not a terminal.
    qr: bool = true,
};

const tick_ms = 50;
const hello_ms = 10_000;
/// Some agents read text plus an instant Enter as a paste and insert a newline.
const submit_gap_ms = 120;

/// Returns only if it could not start, with the reason printed.
pub fn run(gpa: Allocator, io: Io, environ: *const std.process.Environ.Map, w: *Io.Writer, opts: Options) !u8 {
    var br = bridge.detect(environ);
    const panes = br.panes() orelse return fail(w, "no multiplexer to reach the agent through; run it inside tmux", .{});
    var saved_buf: [bridge.max_pane_id]u8 = undefined;
    if (bridge.loadTarget(io, gpa, &saved_buf)) |p| panes.setPane(p);
    if (opts.pane) |p| panes.setPane(p);
    const found = try br.target(.{ .gpa = gpa, .io = io, .w = w }) orelse
        return fail(w, "which {s} is the agent in? pass --pane", .{br.unit()});
    // Pinned: the bridge forgets a dead target, and a replacement is a pane the phone cannot see.
    var pane_buf: [bridge.max_pane_id]u8 = undefined;
    const pane = pane_buf[0..found.len];
    @memcpy(pane, found);

    const addr = net.parseAddress(opts.listen, opts.port) catch return fail(w, "'{s}' is not an IP address", .{opts.listen});
    if (!net.private(addr)) return fail(w, "{f} is reachable from other machines; listen on 127.0.0.1 or a Tailscale address", .{addr});
    var server = net.listen(io, addr) catch |err| return switch (err) {
        error.AlreadyServing => fail(w, "something already answers on {f}; pick another --port", .{addr}),
        else => fail(w, "cannot listen on {f}: {t}", .{ addr, err }),
    };
    defer server.deinit(io);

    // herdr names its socket in every pane it runs, and pushes status on it.
    const socket = if (br == .herdr) environ.get("HERDR_SOCKET_PATH") orelse "" else "";
    var watch: status.Watch = .{ .gpa = gpa, .io = io, .path = socket, .pane = pane };
    const watching = socket.len > 0 and (if (watch.start()) |_| true else |_| false);

    var cwd_buf: [4096]u8 = undefined;
    var d: Daemon = .{
        .gpa = gpa,
        .io = io,
        .log = w,
        .br = br,
        .token = try pair.loadOrCreate(io, gpa, opts.new_token),
        .repo = std.fs.path.basename(fs.cwdPath(io, &cwd_buf) orelse ""),
        .info = agent.caps(&br, pane, watching),
        .watch = if (watching) &watch else null,
    };
    try d.banner(addr, opts);
    while (true) d.serve(server.accept(io) catch continue);
}

fn fail(w: *Io.Writer, comptime fmt: []const u8, args: anytype) Io.Writer.Error!u8 {
    try w.print("lgtm serve: " ++ fmt ++ "\n", args);
    return 1;
}

fn refuse(out: *Io.Writer, code: wire.Code, message: []const u8) Io.Writer.Error!void {
    return wire.write(out, .{ .@"error" = .{ .code = code, .message = message } });
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

    const End = enum { closed, too_long };

    fn read(self: *Inbox, conn: net.Conn) void {
        const buf = self.gpa.alloc(u8, wire.max_line) catch return self.finish(.closed);
        defer self.gpa.free(buf);
        var r = conn.reader(self.io, buf);
        while (true) {
            const line = (r.interface.takeDelimiter('\n') catch |err|
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
    log: *Io.Writer,
    br: bridge.Bridge,
    token: pair.Token,
    repo: []const u8,
    info: wire.Agent,
    watch: ?*status.Watch,

    fn say(d: *Daemon, comptime fmt: []const u8, args: anytype) void {
        d.log.print("  " ++ fmt ++ "\n", args) catch {};
        d.log.flush() catch {};
    }

    fn banner(d: *Daemon, addr: net.Address, opts: Options) !void {
        const w = d.log;
        var url_buf: [256]u8 = undefined;
        var url: Io.Writer = .fixed(&url_buf);
        try pair.writeUrl(&url, opts.listen, opts.port, &d.token, d.repo);

        try w.print("lgtm serve  {s} {s}\n  listening  {f}\n", .{ d.info.backend, d.info.pane, addr });
        if (opts.qr) {
            if (qr.encode(url.buffered())) |code| try qr.render(w, &code) else |_| {}
        }
        try w.print("  pair       {s}\n  token      {s}\n", .{ url.buffered(), &d.token.hex });
        if (net.loopback(addr)) try w.writeAll("  note       a phone cannot reach loopback; use --listen $(tailscale ip -4)\n");
        if (!d.info.read) try w.print("  send only  {s}\n", .{d.info.why});
        if (d.watch != null) try w.writeAll("  status     herdr events\n");
        var scratch: std.heap.ArenaAllocator = .init(d.gpa);
        defer scratch.deinit();
        if (agent.command(d.gpa, scratch.allocator(), d.io, &d.br, d.info.pane)) |c| {
            if (!bridge.Bridge.looksLikeAgent(c)) try w.print("  warning    {s} runs {s}, not an agent\n", .{ d.info.pane, c });
        }
        try w.flush();
    }

    fn serve(d: *Daemon, conn: net.Conn) void {
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
        var screen: agent.Screen = .{};
        var pacer: agent.Pacer = .{};
        var next_capture: i64 = 0;
        var pane_gone = false;
        var status_seq: u32 = 0;

        serving: while (true) {
            var frame: std.heap.ArenaAllocator = .init(d.gpa);
            defer frame.deinit();
            const arena = frame.allocator();

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
                    d.say("refused    {t}", .{code});
                    break :serving;
                };
                if (device == null) {
                    const bad: ?struct { wire.Code, []const u8 } = switch (msg) {
                        .hello => |h| if (h.version != wire.version)
                            .{ .version, "this daemon speaks protocol version 0" }
                        else if (!d.token.matches(h.token))
                            .{ .token, "wrong token" }
                        else
                            null,
                        else => .{ .no_hello, "say hello first" },
                    };
                    if (bad) |b| {
                        refuse(out, b[0], b[1]) catch {};
                        d.say("refused    {t}", .{b[0]});
                        break :serving;
                    }
                    const name = if (msg.hello.device.len > 0) msg.hello.device else "a device";
                    const n = @min(name.len, device_buf.len);
                    @memcpy(device_buf[0..n], name[0..n]);
                    device = device_buf[0..n];
                    d.say("attached   {s}", .{device.?});
                    wire.write(out, .{ .session = .{ .version = wire.version, .repo = d.repo, .agent = d.info } }) catch break :serving;
                    continue;
                }
                switch (msg) {
                    .hello => {},
                    .ping => wire.write(out, .pong) catch break :serving,
                    .send => |s| {
                        const sent = d.deliver(s.text, s.submit and d.info.submit);
                        d.say("sent       {d} bytes{s}{s}", .{
                            s.text.len,
                            if (sent.submitted) ", submitted" else "",
                            if (sent.ok) "" else ", failed",
                        });
                        wire.write(out, .{ .sent = sent }) catch break :serving;
                        pacer.wake();
                        next_capture = 0;
                    },
                }
            }
            if (got.end) |end| {
                if (end == .too_long) refuse(out, .too_long, "a line longer than 64 KiB") catch {};
                break;
            }

            const now = nowMs(d.io);
            if (device == null and now - started > hello_ms) {
                refuse(out, .no_hello, "say hello first") catch {};
                break;
            }

            if (device != null and d.info.read and now >= next_capture) {
                if (screen.poll(&d.br, .{ .gpa = d.gpa, .io = d.io, .w = d.log }, arena, d.info.pane)) |rows| {
                    pane_gone = false;
                    if (rows) |r| wire.write(out, .{ .screen = .{ .pane = d.info.pane, .rows = r } }) catch break;
                    next_capture = now + pacer.after(rows != null);
                } else |err| switch (err) {
                    error.OutOfMemory => break,
                    error.PaneGone => {
                        if (!pane_gone) refuse(out, .pane_gone, "the agent's pane is gone") catch break;
                        pane_gone = true;
                        next_capture = now + pacer.after(false);
                    },
                }
            }

            if (device != null) if (d.watch) |wt| {
                var agent_buf: [64]u8 = undefined;
                const snap = wt.snapshot(&agent_buf);
                if (snap.seq != status_seq) {
                    status_seq = snap.seq;
                    wire.write(out, .{ .status = .{ .state = snap.state, .agent = snap.agent } }) catch break;
                }
            };

            out.flush() catch break;
            d.io.sleep(.fromMilliseconds(tick_ms), .awake) catch break;
        }
        // Every way out of the loop may have left a reason unsent.
        out.flush() catch {};
        if (device) |name| d.say("detached   {s}", .{name});
    }

    fn deliver(d: *Daemon, text: []const u8, submit: bool) @FieldType(wire.Outbound, "sent") {
        const cx: bridge.Ctx = .{ .gpa = d.gpa, .io = d.io, .w = d.log };
        d.br.panes().?.setPane(d.info.pane);
        const outcome = d.br.sendText(cx, text) catch |err| return .{ .ok = false, .submitted = false, .why = switch (err) {
            error.Multiline => "a newline would press Enter; send one line at a time",
            error.NoTarget => "no pane to send to",
            else => "the send failed",
        } };
        if (outcome == .copied) return .{ .ok = false, .submitted = false, .why = outcome.copied orelse "copied to the clipboard instead" };
        if (!submit) return .{ .ok = true, .submitted = false };
        d.io.sleep(.fromMilliseconds(submit_gap_ms), .awake) catch {};
        const why = d.br.submit(cx) catch return .{ .ok = true, .submitted = false, .why = "submit failed" };
        return .{ .ok = true, .submitted = why == null, .why = why orelse "" };
    }
};

test {
    _ = net;
    _ = agent;
    _ = pair;
    _ = qr;
    _ = status;
    _ = wire;
}
