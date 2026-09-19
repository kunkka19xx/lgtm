// SPDX-License-Identifier: Apache-2.0
//
// The `lgtm serve` protocol: one JSON object per line, tagged by `type`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const hunk = @import("../core/hunk.zig");

/// A client speaking any other version is refused.
pub const version: u32 = 1;

/// The longest line either side may send. Bounds the reader's buffer.
pub const max_line = 64 << 10;

pub const Inbound = union(enum) {
    hello: struct { token: []const u8, version: u32, device: []const u8 },
    /// The pane whose screens to send; empty stops.
    watch: struct { pane: []const u8 },
    /// `submit` presses Enter after the text, and only a person's tap sets it.
    send: struct { pane: []const u8, text: []const u8, submit: bool },
    /// A key a text box cannot type; `keys.zig` has the names.
    key: struct { pane: []const u8, key: []const u8 },
    ping,
    review: struct { repo: []const u8 },
    open: struct { path: []const u8 },
    /// `new` is the row's working-tree line; 0 on a removed line, which `old` names instead.
    comment: struct { path: []const u8, new: u32, old: u32, text: []const u8 },
    uncomment: struct { id: u32 },
    submit: struct { pane: []const u8 },
    /// `agent` is a name from `session.agents`, `dir` one from `session.dirs` or a pane's `repo`.
    spawn: struct { agent: []const u8, dir: []const u8 },
    close: struct { pane: []const u8 },
};

pub const ParseError = error{ Malformed, UnknownType, MissingField } || Allocator.Error;

const Raw = struct {
    type: []const u8,
    token: ?[]const u8 = null,
    version: ?u32 = null,
    device: ?[]const u8 = null,
    pane: ?[]const u8 = null,
    repo: ?[]const u8 = null,
    key: ?[]const u8 = null,
    agent: ?[]const u8 = null,
    dir: ?[]const u8 = null,
    text: ?[]const u8 = null,
    submit: bool = false,
    path: ?[]const u8 = null,
    new: u32 = 0,
    old: u32 = 0,
    id: ?u32 = null,
};

/// The strings point into `arena`.
pub fn parse(arena: Allocator, line: []const u8) ParseError!Inbound {
    const raw = std.json.parseFromSliceLeaky(Raw, arena, line, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Malformed,
    };
    const kind = std.meta.stringToEnum(std.meta.Tag(Inbound), raw.type) orelse return error.UnknownType;
    return switch (kind) {
        .hello => .{ .hello = .{
            .token = raw.token orelse return error.MissingField,
            .version = raw.version orelse return error.MissingField,
            .device = raw.device orelse "",
        } },
        .watch => .{ .watch = .{ .pane = raw.pane orelse return error.MissingField } },
        .send => .{ .send = .{
            .pane = raw.pane orelse return error.MissingField,
            .text = raw.text orelse return error.MissingField,
            .submit = raw.submit,
        } },
        .key => .{ .key = .{
            .pane = raw.pane orelse return error.MissingField,
            .key = raw.key orelse return error.MissingField,
        } },
        .ping => .ping,
        .review => .{ .review = .{ .repo = raw.repo orelse return error.MissingField } },
        .open => .{ .open = .{ .path = raw.path orelse return error.MissingField } },
        .comment => .{ .comment = .{
            .path = raw.path orelse return error.MissingField,
            .new = raw.new,
            .old = raw.old,
            .text = raw.text orelse return error.MissingField,
        } },
        .uncomment => .{ .uncomment = .{ .id = raw.id orelse return error.MissingField } },
        .submit => .{ .submit = .{ .pane = raw.pane orelse return error.MissingField } },
        .spawn => .{ .spawn = .{
            .agent = raw.agent orelse return error.MissingField,
            .dir = raw.dir orelse return error.MissingField,
        } },
        .close => .{ .close = .{ .pane = raw.pane orelse return error.MissingField } },
    };
}

pub const AgentState = enum { unknown, working, blocked, idle, done };

/// Where `state` came from: herdr's own detection, or the screen moving and going still.
pub const StateSource = enum { none, herdr, quiet };

pub const Pane = struct {
    /// Stable for the pane's life and never reused, so a send cannot reach a pane that replaced it.
    id: []const u8,
    backend: []const u8,
    /// The pane's parents, outermost first.
    group: []const []const u8 = &.{},
    title: []const u8 = "",
    dir: []const u8 = "",
    repo: []const u8 = "",
    /// Empty for a pane that is not an agent.
    agent: []const u8 = "",
    state: AgentState = .unknown,
    source: StateSource = .none,
    read: bool = true,
    submit: bool = true,
    stream: bool = false,
    /// Why `read` or `submit` is false, in words a person can act on.
    why: []const u8 = "",
    preview: []const []const u8 = &.{},
};

pub const FileEntry = struct { path: []const u8, status: []const u8, added: u32, removed: u32, comments: u32 };

/// `runs` are `[start, len, kind]` in bytes of `text`, `kind` indexing `syntax/token.zig`'s `Kind`.
pub const Line = struct { kind: hunk.LineKind, old: u32, new: u32, text: []const u8, runs: []const [3]u32 };

/// `at` is the index into `lines` where the hunk starts.
pub const HunkHead = struct { at: u32, section: []const u8 };

pub const Note = struct { id: u32, line: u32, body: []const u8, state: []const u8, removed: bool };

pub const FileView = struct {
    path: []const u8,
    status: []const u8,
    lines: []const Line,
    hunks: []const HunkHead,
    notes: []const Note,
};

pub const Outbound = union(enum) {
    /// `review` is where a review starts; `agents` and `dirs` are what `spawn` accepts.
    session: struct { version: u32, host: []const u8, review: []const u8, agents: []const []const u8 = &.{}, dirs: []const []const u8 = &.{} },
    panes: struct { panes: []const Pane },
    screen: struct { pane: []const u8, rows: []const []const u8 },
    sent: struct { pane: []const u8, ok: bool, submitted: bool, why: []const u8 = "" },
    files: struct { repo: []const u8, files: []const FileEntry },
    file: FileView,
    noted: struct { ok: bool, id: u32 = 0, why: []const u8 = "" },
    submitted: struct { ok: bool, path: []const u8 = "", count: u32 = 0, why: []const u8 = "" },
    /// `pane` is the new pane's id, or empty when it only shows up in the next `panes`.
    spawned: struct { ok: bool, pane: []const u8 = "", why: []const u8 = "" },
    closed: struct { ok: bool, pane: []const u8, why: []const u8 = "" },
    @"error": struct { code: Code, message: []const u8, pane: []const u8 = "" },
    pong,
};

pub const Code = enum { malformed, unknown_type, missing_field, version, token, no_hello, too_long, pane_gone, no_review, replaced, unknown_key };

/// Field order is declaration order, so a message always encodes to the same bytes.
pub fn write(w: *Writer, msg: Outbound) Writer.Error!void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("type");
    try s.write(@tagName(msg));
    switch (msg) {
        .pong => {},
        inline else => |payload| {
            inline for (@typeInfo(@TypeOf(payload)).@"struct".fields) |f| {
                try s.objectField(f.name);
                try s.write(@field(payload, f.name));
            }
        },
    }
    try s.endObject();
    try w.writeByte('\n');
}

const testing = std.testing;

/// Every message the daemon can send, as the recorded fixture spells it.
const outbound_fixture = [_]Outbound{
    .{ .session = .{ .version = 1, .host = "mac-mini", .review = "/Users/me/code/lgtm", .agents = &.{ "claude", "codex" }, .dirs = &.{"/Users/me/code/api"} } },
    .{ .panes = .{ .panes = &.{
        .{
            .id = "herdr:term_65bca13b",
            .backend = "herdr",
            .group = &.{ "w1", "w1:t1" },
            .title = "claude",
            .dir = "/Users/me/code/api",
            .repo = "/Users/me/code/api",
            .agent = "claude",
            .state = .blocked,
            .source = .herdr,
            .preview = &.{ "Do you want to proceed?", "1. Yes", "2. No" },
        },
        .{ .id = "tmux:4182:%12", .backend = "tmux", .group = &.{ "work", "1:zsh" }, .title = "\u{2733} fix retry", .agent = "claude", .state = .working, .source = .quiet },
        .{ .id = "pty:5120", .backend = "pty", .agent = "codex", .stream = true },
    } } },
    .{ .screen = .{ .pane = "tmux:4182:%12", .rows = &.{ "> fix the retry backoff", "", "\u{25cf} Reading server.zig", "  \"quoted\" \\ tab\there" } } },
    .{ .sent = .{ .pane = "tmux:4182:%12", .ok = true, .submitted = true } },
    .{ .sent = .{ .pane = "tmux:4182:%12", .ok = false, .submitted = false, .why = "pane is gone" } },
    .{ .files = .{ .repo = "/Users/me/code/lgtm", .files = &.{.{ .path = "src/retry.zig", .status = "modified", .added = 3, .removed = 1, .comments = 1 }} } },
    .{ .file = .{
        .path = "src/retry.zig",
        .status = "modified",
        .lines = &.{
            .{ .kind = .context, .old = 1, .new = 1, .text = "const max = 3;", .runs = &.{ .{ 0, 5, 4 }, .{ 12, 1, 3 } } },
            .{ .kind = .del, .old = 2, .new = 0, .text = "fn retry() void {}", .runs = &.{} },
            .{ .kind = .add, .old = 0, .new = 2, .text = "fn retry(n: u32) void {}", .runs = &.{} },
        },
        .hunks = &.{.{ .at = 0, .section = "" }},
        .notes = &.{.{ .id = 1, .line = 2, .body = "cap this?", .state = "open", .removed = false }},
    } },
    .{ .noted = .{ .ok = true, .id = 1 } },
    .{ .submitted = .{ .ok = true, .path = ".lgtm/phone-review-1.md", .count = 1 } },
    .{ .spawned = .{ .ok = true, .pane = "tmux:4182:%31" } },
    .{ .closed = .{ .ok = false, .pane = "pty:5120", .why = "stop it where it runs" } },
    .{ .@"error" = .{ .code = .token, .message = "wrong token" } },
    .{ .@"error" = .{ .code = .pane_gone, .message = "the pane is gone", .pane = "tmux:4182:%12" } },
    .pong,
};

test "every outbound message encodes to the recorded fixture" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    for (outbound_fixture) |msg| try write(&out.writer, msg);
    try testing.expectEqualStrings(@embedFile("wire_outbound"), out.written());
}

test "every inbound message in the fixture parses" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    var lines = std.mem.tokenizeScalar(u8, @embedFile("wire_inbound"), '\n');

    const hello = try parse(a.allocator(), lines.next().?);
    try testing.expectEqualStrings("0123456789abcdef0123456789abcdef", hello.hello.token);
    try testing.expectEqual(@as(u32, 1), hello.hello.version);
    try testing.expectEqualStrings("iPhone", hello.hello.device);

    try testing.expectEqualStrings("tmux:4182:%12", (try parse(a.allocator(), lines.next().?)).watch.pane);
    const send = try parse(a.allocator(), lines.next().?);
    try testing.expectEqualStrings("tmux:4182:%12", send.send.pane);
    try testing.expectEqualStrings("run the tests again", send.send.text);
    try testing.expect(send.send.submit);

    const insert = try parse(a.allocator(), lines.next().?);
    try testing.expect(!insert.send.submit);

    try testing.expect(try parse(a.allocator(), lines.next().?) == .ping);
    try testing.expectEqualStrings("/Users/me/code/lgtm", (try parse(a.allocator(), lines.next().?)).review.repo);
    try testing.expectEqualStrings("src/retry.zig", (try parse(a.allocator(), lines.next().?)).open.path);
    const c = (try parse(a.allocator(), lines.next().?)).comment;
    try testing.expect(c.new == 0 and c.old == 2 and std.mem.eql(u8, c.text, "why remove it?"));
    try testing.expectEqual(@as(u32, 1), (try parse(a.allocator(), lines.next().?)).uncomment.id);
    try testing.expectEqualStrings("tmux:4182:%12", (try parse(a.allocator(), lines.next().?)).submit.pane);
    const k = (try parse(a.allocator(), lines.next().?)).key;
    try testing.expect(std.mem.eql(u8, k.pane, "tmux:4182:%12") and std.mem.eql(u8, k.key, "escape"));
    const sp = (try parse(a.allocator(), lines.next().?)).spawn;
    try testing.expect(std.mem.eql(u8, sp.agent, "claude") and std.mem.eql(u8, sp.dir, "/Users/me/code/api"));
    try testing.expectEqualStrings("tmux:4182:%31", (try parse(a.allocator(), lines.next().?)).close.pane);
    try testing.expect(lines.next() == null);
}

test "a message that is not one is refused, never guessed at" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    try testing.expectError(error.Malformed, parse(arena, "not json"));
    try testing.expectError(error.Malformed, parse(arena, "{\"text\":\"no type\"}"));
    try testing.expectError(error.UnknownType, parse(arena, "{\"type\":\"exec\",\"text\":\"rm -rf /\"}"));
    try testing.expectError(error.MissingField, parse(arena, "{\"type\":\"send\",\"text\":\"x\"}"));
    try testing.expectError(error.MissingField, parse(arena, "{\"type\":\"hello\",\"version\":0}"));
    // An absent submit is an insert: Enter is only ever pressed when asked for.
    try testing.expect(!(try parse(arena, "{\"type\":\"send\",\"pane\":\"p\",\"text\":\"x\"}")).send.submit);
    // A newer client's extra fields do not stop an older daemon reading it.
    _ = try parse(arena, "{\"type\":\"ping\",\"later\":true}");
}
