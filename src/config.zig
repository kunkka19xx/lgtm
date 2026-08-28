// SPDX-License-Identifier: Apache-2.0
//
// The config file. A small TOML subset, read from the global file and then the
// repo's, merged rather than replaced (FEATURES.md 4.8) - and never fatal
// (FEATURES.md 4.9). A bad line costs that one key its value, is reported with
// the file and line it came from, and everything else in the file still
// applies. A tool that refuses to start because of a typo in a config file is
// a tool people uninstall.
//
// The subset is deliberate rather than aspirational: `[table]` headers,
// `key = value`, strings, booleans, integers, and single-line arrays of
// strings. No dates, no nested tables, no multi-line strings, no inline
// tables. That is everything the v0.1 surface needs, in a parser small enough
// to read in one sitting - and a real dependency can replace it later without
// changing a single call site, because nothing outside this file knows the
// format.
//
// No vaxis in here, which is what keeps a config test from needing a terminal:
// `ui.icons` resolves to a named glyph set that `ui/app.zig` maps to
// `theme.Glyphs`, rather than this file importing the theme.

const std = @import("std");
const Allocator = std.mem.Allocator;

const fs = @import("io/fs.zig");
const keymap = @import("ui/keymap.zig");

/// A config file larger than this is not a config file. Reading it is the one
/// thing on the cold-start path that a user can make arbitrarily slow.
pub const max_bytes: usize = 256 << 10;

/// `ui.icons`. Named here rather than as a `theme.Glyphs` value so this module
/// stays free of vaxis; `ui/app.zig` does the mapping.
pub const Icons = enum { unicode, ascii };

pub const Ui = struct {
    icons: Icons = .unicode,
};

/// Navigation policy: motions that could reasonably go either way are settings
/// rather than opinions baked into dispatch (FEATURES.md 4.7b).
pub const Nav = struct {
    /// `]h` carries on into the next file at the end of this one. Default true
    /// because the status line already counts hunks across every file - "4 of
    /// 17" describes a sequence, and the primary motion should be able to walk
    /// it. False keeps hunk motions inside the current file, wrapping there.
    hunk_crosses_files: bool = true,
    /// Rows kept between the cursor and the edge of the body. Clamped to a
    /// third of the body at use, so a large value on a short pane degrades
    /// instead of pinning the cursor to the middle.
    scrolloff: u32 = 3,
};

pub const Config = struct {
    nav: Nav = .{},
    ui: Ui = .{},
    /// The keymap after any `[keys]` overrides. Points straight at the
    /// defaults until something overrides them, so the ordinary run - no
    /// config file, or one that does not touch keys - allocates nothing.
    keys: []const keymap.Binding = keymap.default_bindings,
};

/// One thing wrong with one line, in the words the user needs to fix it: which
/// file, which line, which key (FEATURES.md 4.9).
pub const Problem = struct {
    source: []const u8,
    line: u32,
    text: []const u8,
};

const Section = enum { nav, ui, keys };

const Value = union(enum) {
    string: []const u8,
    boolean: bool,
    integer: i64,
    list: []const []const u8,

    fn typeName(self: Value) []const u8 {
        return switch (self) {
            .string => "a string",
            .boolean => "a boolean",
            .integer => "an integer",
            .list => "a list",
        };
    }
};

/// Accumulates one config across however many files it came from. Merging is
/// per key, not per file: a repo file that sets one binding leaves the global
/// file's theme and navigation exactly as they were.
pub const Loader = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    cfg: Config = .{},
    problems: std.ArrayList(Problem) = .empty,

    pub fn init(gpa: Allocator) Loader {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    /// Frees everything the config points at, so it must outlive the app that
    /// is using it - `cfg.keys` and every problem string live in the arena.
    pub fn deinit(self: *Loader) void {
        self.problems.deinit(self.gpa);
        self.arena.deinit();
        self.* = undefined;
    }

    /// Reads one file and merges it. A file that is not there is not a
    /// problem: neither config file is required to exist, and reporting the
    /// absence of the one nobody wrote is noise. Anything else - a directory,
    /// a permission error - is worth saying out loud, because the user did
    /// write that file and it is being ignored.
    pub fn mergeFile(self: *Loader, io: std.Io, path: []const u8) void {
        const text = fs.readFile(io, self.gpa, path, max_bytes) catch |err| {
            if (err != error.FileNotFound) self.note(path, 0, "cannot read: {t}", .{err});
            return;
        };
        defer self.gpa.free(text);
        self.merge(path, text);
    }

    /// The whole parser. Pure: no file, no terminal, no allocation the caller
    /// has to think about - which is what lets every rule below be a test.
    pub fn merge(self: *Loader, source: []const u8, text: []const u8) void {
        const src = self.arena.allocator().dupe(u8, source) catch return;
        var section: ?Section = null;
        // Inside a section this build does not know. Its keys are skipped
        // without a word each: the unknown header is already reported, and a
        // future `[templates]` block read by an older binary should cost one
        // line of complaint, not one per setting.
        var in_unknown = false;
        var line_no: u32 = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            line_no += 1;
            const line = trim(stripComment(raw));
            if (line.len == 0) continue;

            if (line[0] == '[') {
                if (line[line.len - 1] != ']') {
                    self.note(src, line_no, "unterminated table header", .{});
                    continue;
                }
                const name = trim(line[1 .. line.len - 1]);
                section = std.meta.stringToEnum(Section, name) orelse {
                    self.note(src, line_no, "unknown section '[{s}]'", .{name});
                    section = null;
                    in_unknown = true;
                    continue;
                };
                in_unknown = false;
                continue;
            }

            const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
                self.note(src, line_no, "expected 'key = value'", .{});
                continue;
            };
            const key = trim(line[0..eq]);
            const rest = trim(line[eq + 1 ..]);
            if (key.len == 0) {
                self.note(src, line_no, "missing key before '='", .{});
                continue;
            }
            const sect = section orelse {
                if (!in_unknown) self.note(src, line_no, "'{s}' is outside any section", .{key});
                continue;
            };
            const value = self.parseValue(src, line_no, rest) orelse continue;
            self.apply(src, line_no, sect, key, value);
        }
    }

    fn apply(self: *Loader, src: []const u8, line: u32, section: Section, key: []const u8, value: Value) void {
        switch (section) {
            .nav => {
                if (std.mem.eql(u8, key, "hunk_crosses_files")) {
                    self.cfg.nav.hunk_crosses_files = self.wantBool(src, line, key, value) orelse return;
                } else if (std.mem.eql(u8, key, "scrolloff")) {
                    const n = self.wantInt(src, line, key, value) orelse return;
                    if (n < 0 or n > 64) {
                        self.note(src, line, "nav.scrolloff must be between 0 and 64", .{});
                        return;
                    }
                    self.cfg.nav.scrolloff = @intCast(n);
                } else self.unknownKey(src, line, section, key);
            },
            .ui => {
                if (std.mem.eql(u8, key, "icons")) {
                    const s = self.wantString(src, line, key, value) orelse return;
                    self.cfg.ui.icons = std.meta.stringToEnum(Icons, s) orelse {
                        self.note(src, line, "ui.icons must be \"unicode\" or \"ascii\", not \"{s}\"", .{s});
                        return;
                    };
                } else self.unknownKey(src, line, section, key);
            },
            // `[keys]` keys are command names, so there is no fixed list to
            // check against - the `Command` enum is the list.
            .keys => self.applyKeys(src, line, key, value),
        }
    }

    /// `command = "<seq>"` or `command = ["<seq>", "<seq>"]`, replacing every
    /// binding of that command. An empty list unbinds it: the hint strip and
    /// the `?` popup are both generated from the bindings, so a command with
    /// no keys simply stops being advertised rather than lying about itself.
    fn applyKeys(self: *Loader, src: []const u8, line: u32, key: []const u8, value: Value) void {
        const cmd = std.meta.stringToEnum(keymap.Command, key) orelse {
            self.note(src, line, "unknown command '{s}'", .{key});
            return;
        };
        var one: [1][]const u8 = undefined;
        const seqs: []const []const u8 = switch (value) {
            .string => |s| blk: {
                one[0] = s;
                break :blk one[0..1];
            },
            .list => |l| l,
            else => {
                self.note(src, line, "keys.{s} wants a string or a list, not {s}", .{ key, value.typeName() });
                return;
            },
        };

        const a = self.arena.allocator();
        var built: std.ArrayList(keymap.Binding) = .empty;
        const proto = protoFor(cmd);
        for (seqs, 0..) |seq, i| {
            var buf: [keymap.Keymap.max_sequence]keymap.Chord = undefined;
            const chords = keymap.parseChords(seq, &buf) catch |err| {
                self.note(src, line, "keys.{s}: cannot read \"{s}\" ({t})", .{ key, seq, err });
                return;
            };
            if (chords.len == 0) {
                self.note(src, line, "keys.{s}: \"\" is not a key; use [] to unbind", .{key});
                return;
            }
            built.append(a, .{
                .chords = a.dupe(keymap.Chord, chords) catch return,
                .command = cmd,
                .modes = proto.modes,
                // Only the first spelling is advertised. The rest are aliases,
                // exactly as the default table treats `<Space>nf` next to
                // `]f`: a hint strip with two entries for one action is how a
                // 80-column status row runs out of room.
                .hint = if (i == 0) proto.hint else null,
                .desc = if (i == 0) proto.desc else null,
            }) catch return;
        }

        // Spliced in at the position of the first binding it replaces, so a
        // remap keeps its place in the hint strip and the help popup rather
        // than jumping to the end of the list.
        var next: std.ArrayList(keymap.Binding) = .empty;
        var placed = false;
        for (self.cfg.keys) |b| {
            if (b.command != cmd) {
                next.append(a, b) catch return;
                continue;
            }
            if (!placed) {
                placed = true;
                next.appendSlice(a, built.items) catch return;
            }
        }
        if (!placed) next.appendSlice(a, built.items) catch return;

        // A sequence that is a prefix of another fires first and makes the
        // longer one unreachable. Refusing the override and keeping the
        // previous keymap is what FEATURES.md 4.9 asks for: fall back for
        // that key only, and say why.
        if (keymap.shadowed(next.items)) |hit| {
            var fbuf: [keymap.max_keys_bytes]u8 = undefined;
            var sbuf: [keymap.max_keys_bytes]u8 = undefined;
            const first = keymap.bufWriteChords(hit.first.chords, &fbuf);
            const second = keymap.bufWriteChords(hit.second.chords, &sbuf);
            switch (hit.kind) {
                .prefix => self.note(src, line, "keys.{s}: {s} shadows {s} ({s}), which could then never fire", .{
                    key, first, second, @tagName(hit.second.command),
                }),
                // Name the *other* command, whichever side of the pair it
                // landed on: "q is already bound to quit" is the sentence the
                // user needs, and "bound to refresh" - the command they are
                // editing - is the one that explains nothing.
                .duplicate => self.note(src, line, "keys.{s}: {s} is already bound to {s}", .{
                    key,
                    second,
                    @tagName(if (hit.first.command == cmd) hit.second.command else hit.first.command),
                }),
            }
            return;
        }
        self.cfg.keys = next.items;
    }

    fn parseValue(self: *Loader, src: []const u8, line: u32, text: []const u8) ?Value {
        if (text.len == 0) {
            self.note(src, line, "missing value after '='", .{});
            return null;
        }
        if (text[0] == '"') return .{ .string = self.parseString(src, line, text) orelse return null };
        if (text[0] == '[') return self.parseList(src, line, text);
        if (std.mem.eql(u8, text, "true")) return .{ .boolean = true };
        if (std.mem.eql(u8, text, "false")) return .{ .boolean = false };
        if (std.fmt.parseInt(i64, text, 10)) |n| {
            return .{ .integer = n };
        } else |_| {}
        self.note(src, line, "cannot read value '{s}'", .{text});
        return null;
    }

    /// A basic TOML string: quotes, and the four escapes anything here could
    /// want. `\n` matters because a template string will want one long before
    /// dates or unicode escapes do.
    fn parseString(self: *Loader, src: []const u8, line: u32, text: []const u8) ?[]const u8 {
        const end = stringEnd(text) orelse {
            self.note(src, line, "unterminated string", .{});
            return null;
        };
        if (end != text.len - 1) {
            self.note(src, line, "trailing text after the value", .{});
            return null;
        }
        var out: std.ArrayList(u8) = .empty;
        const a = self.arena.allocator();
        var i: usize = 1;
        while (i < end) : (i += 1) {
            if (text[i] != '\\') {
                out.append(a, text[i]) catch return null;
                continue;
            }
            i += 1;
            if (i >= end) break;
            const ch: u8 = switch (text[i]) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '"' => '"',
                '\\' => '\\',
                else => {
                    self.note(src, line, "unknown escape '\\{c}'", .{text[i]});
                    return null;
                },
            };
            out.append(a, ch) catch return null;
        }
        return out.items;
    }

    fn parseList(self: *Loader, src: []const u8, line: u32, text: []const u8) ?Value {
        if (text[text.len - 1] != ']') {
            self.note(src, line, "unterminated list", .{});
            return null;
        }
        const a = self.arena.allocator();
        var items: std.ArrayList([]const u8) = .empty;
        var i: usize = 1;
        while (i < text.len - 1) {
            while (i < text.len - 1 and (text[i] == ' ' or text[i] == '\t' or text[i] == ',')) i += 1;
            if (i >= text.len - 1) break;
            if (text[i] != '"') {
                self.note(src, line, "a list holds strings; '{c}' is not one", .{text[i]});
                return null;
            }
            const end = stringEnd(text[i..]) orelse {
                self.note(src, line, "unterminated string in list", .{});
                return null;
            };
            const piece = self.parseString(src, line, text[i .. i + end + 1]) orelse return null;
            items.append(a, piece) catch return null;
            i += end + 1;
        }
        return .{ .list = items.items };
    }

    fn wantBool(self: *Loader, src: []const u8, line: u32, key: []const u8, v: Value) ?bool {
        return switch (v) {
            .boolean => |b| b,
            else => {
                self.note(src, line, "{s} wants true or false, not {s}", .{ key, v.typeName() });
                return null;
            },
        };
    }

    fn wantInt(self: *Loader, src: []const u8, line: u32, key: []const u8, v: Value) ?i64 {
        return switch (v) {
            .integer => |n| n,
            else => {
                self.note(src, line, "{s} wants a number, not {s}", .{ key, v.typeName() });
                return null;
            },
        };
    }

    fn wantString(self: *Loader, src: []const u8, line: u32, key: []const u8, v: Value) ?[]const u8 {
        return switch (v) {
            .string => |s| s,
            else => {
                self.note(src, line, "{s} wants a string, not {s}", .{ key, v.typeName() });
                return null;
            },
        };
    }

    fn unknownKey(self: *Loader, src: []const u8, line: u32, section: Section, key: []const u8) void {
        self.note(src, line, "unknown key '{s}.{s}'", .{ @tagName(section), key });
    }

    fn note(self: *Loader, src: []const u8, line: u32, comptime fmt: []const u8, args: anytype) void {
        const a = self.arena.allocator();
        const text = std.fmt.allocPrint(a, fmt, args) catch return;
        self.problems.append(self.gpa, .{ .source = src, .line = line, .text = text }) catch {};
    }

    /// The one line the status row has room for: the first problem, and how
    /// many others there are. Written into `buf`, which the caller owns.
    /// Null when the config was clean, which is the overwhelmingly common
    /// case and must cost the user no screen space at all.
    pub fn summary(self: *const Loader, buf: []u8) ?[]const u8 {
        if (self.problems.items.len == 0) return null;
        const first = self.problems.items[0];
        const more = self.problems.items.len - 1;
        const name = std.fs.path.basename(first.source);
        // Line 0 means the file as a whole - it could not be read at all - and
        // "config.toml:0" reads like a line number that does not exist.
        var head: [128]u8 = undefined;
        const where = if (first.line == 0)
            std.fmt.bufPrint(&head, "{s}", .{name}) catch name
        else
            std.fmt.bufPrint(&head, "{s}:{d}", .{ name, first.line }) catch name;
        const out = if (more == 0)
            std.fmt.bufPrint(buf, "{s}: {s}", .{ where, first.text })
        else
            std.fmt.bufPrint(buf, "{s}: {s} (+{d} more)", .{ where, first.text, more });
        return out catch buf[0..0];
    }
};

/// The binding a `[keys]` override inherits its mode, hint and description
/// from - always the shipped default for that command, never whatever the
/// last override left behind, so remapping twice cannot lose the description
/// the `?` popup shows.
fn protoFor(cmd: keymap.Command) keymap.Binding {
    for (keymap.default_bindings) |b| {
        if (b.command == cmd) return b;
    }
    return .{ .chords = &.{}, .command = cmd };
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

/// Everything before an unquoted `#`. Quoted, because `"#{change_id}"` is a
/// template string that FEATURES.md 4.5 puts in this file, and truncating it
/// at the `#` would be a silent corruption rather than an error.
fn stripComment(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        switch (line[i]) {
            '#' => return line[0..i],
            '"' => {
                const end = stringEnd(line[i..]) orelse return line;
                i += end;
            },
            else => {},
        }
    }
    return line;
}

/// Index of the closing quote of the string starting at index 0, or null when
/// there is not one. Escapes are honoured, so `"\""` closes at the last quote.
fn stringEnd(text: []const u8) ?usize {
    var i: usize = 1;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\') {
            i += 1;
            continue;
        }
        if (text[i] == '"') return i;
    }
    return null;
}

/// Where the config lives. `$XDG_CONFIG_HOME` first, as every other tool on
/// the user's machine does, `~/.config` after it, and the repo's own file
/// last so that it wins (FEATURES.md 4.8).
pub const repo_path = ".lgtm/config.toml";

pub fn globalPath(arena: Allocator, environ: *const std.process.Environ.Map) ?[]const u8 {
    if (environ.get("XDG_CONFIG_HOME")) |xdg| {
        if (xdg.len != 0) return std.fs.path.join(arena, &.{ xdg, "lgtm", "config.toml" }) catch null;
    }
    const home = environ.get("HOME") orelse return null;
    if (home.len == 0) return null;
    return std.fs.path.join(arena, &.{ home, ".config", "lgtm", "config.toml" }) catch null;
}

/// Global then repo, merged in that order. `explicit` is `--config <path>`,
/// which replaces both: a user asking for one file means that file, and a
/// missing one is then worth reporting.
pub fn load(
    gpa: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    explicit: ?[]const u8,
) Loader {
    var loader = Loader.init(gpa);
    if (explicit) |path| {
        const text = fs.readFile(io, gpa, path, max_bytes) catch |err| {
            loader.note(path, 0, "cannot read: {t}", .{err});
            return loader;
        };
        defer gpa.free(text);
        loader.merge(path, text);
        return loader;
    }
    if (globalPath(loader.arena.allocator(), environ)) |path| loader.mergeFile(io, path);
    loader.mergeFile(io, repo_path);
    return loader;
}

const testing = std.testing;

/// Parses one document into a loader the caller deinits. Every test below is
/// this plus assertions, because the parser is pure by construction.
fn loadText(text: []const u8) Loader {
    var loader = Loader.init(testing.allocator);
    loader.merge("config.toml", text);
    return loader;
}

test "the settings that exist can be set" {
    var l = loadText(
        \\# lgtm
        \\[nav]
        \\hunk_crosses_files = false
        \\scrolloff = 8
        \\
        \\[ui]
        \\icons = "ascii"
    );
    defer l.deinit();

    try testing.expectEqual(@as(usize, 0), l.problems.items.len);
    try testing.expect(!l.cfg.nav.hunk_crosses_files);
    try testing.expectEqual(@as(u32, 8), l.cfg.nav.scrolloff);
    try testing.expectEqual(Icons.ascii, l.cfg.ui.icons);
}

test "a bad line costs one key its value and nothing else" {
    // The rule from FEATURES.md 4.9, and the whole reason this parser reports
    // rather than returns an error: the typo on line 3 must not take line 4
    // down with it.
    var l = loadText(
        \\[nav]
        \\hunk_crosses_files = maybe
        \\scrolloff = 5
        \\[ui]
        \\icons = "nerd"
        \\[bogus]
        \\anything = 1
    );
    defer l.deinit();

    try testing.expectEqual(@as(usize, 3), l.problems.items.len);
    // The good line either side of the bad one still applied.
    try testing.expectEqual(@as(u32, 5), l.cfg.nav.scrolloff);
    // And the key that failed kept its default rather than a half-read value.
    try testing.expect(l.cfg.nav.hunk_crosses_files);
    try testing.expectEqual(Icons.unicode, l.cfg.ui.icons);

    // Which line, and what was wrong with it.
    try testing.expectEqual(@as(u32, 2), l.problems.items[0].line);
    try testing.expectEqual(@as(u32, 5), l.problems.items[1].line);
    try testing.expect(std.mem.indexOf(u8, l.problems.items[1].text, "unicode") != null);

    // A section nobody knows is reported once, at its header, and its keys
    // are skipped rather than each earning a complaint of its own.
    try testing.expectEqual(@as(u32, 6), l.problems.items[2].line);
    try testing.expect(std.mem.indexOf(u8, l.problems.items[2].text, "bogus") != null);
}

test "a typo in a key name says which key" {
    var l = loadText(
        \\[nav]
        \\scroloff = 3
    );
    defer l.deinit();
    try testing.expectEqual(@as(usize, 1), l.problems.items.len);
    try testing.expect(std.mem.indexOf(u8, l.problems.items[0].text, "nav.scroloff") != null);
}

test "out of range is a problem, not a clamp" {
    // Clamping silently would leave the user reading a config that says one
    // thing and a screen that does another.
    var l = loadText(
        \\[nav]
        \\scrolloff = 900
    );
    defer l.deinit();
    try testing.expectEqual(@as(usize, 1), l.problems.items.len);
    try testing.expectEqual(@as(u32, 3), l.cfg.nav.scrolloff);
}

test "keys are remapped by the spelling the popup shows" {
    var l = loadText(
        \\[keys]
        \\refresh = ["<C-l>", "<Space>r"]
        \\quit = "Q"
    );
    defer l.deinit();
    try testing.expectEqual(@as(usize, 0), l.problems.items.len);

    var km: keymap.Keymap = .{ .bindings = l.cfg.keys };
    // The new spelling fires.
    try testing.expect(km.feed(.{ .codepoint = ' ', .mods = .{} }, .normal) == .pending);
    try testing.expectEqual(keymap.Command.refresh, km.feed(.{ .codepoint = 'r', .mods = .{} }, .normal).command);
    try testing.expectEqual(keymap.Command.quit, km.feed(.{ .codepoint = 'Q', .mods = .{} }, .normal).command);
    // And the old one does not.
    try testing.expect(km.feed(.{ .codepoint = 'q', .mods = .{} }, .normal) == .none);

    // The first spelling keeps the description, so the `?` popup documents
    // the user's keys rather than dropping the row.
    var advertised: usize = 0;
    for (l.cfg.keys) |b| {
        if (b.command == .refresh and b.desc != null) advertised += 1;
    }
    try testing.expectEqual(@as(usize, 1), advertised);
}

test "an empty list unbinds and stops advertising" {
    var l = loadText(
        \\[keys]
        \\open_editor = []
    );
    defer l.deinit();
    try testing.expectEqual(@as(usize, 0), l.problems.items.len);

    var km: keymap.Keymap = .{ .bindings = l.cfg.keys };
    try testing.expect(km.feed(.{ .codepoint = 'e', .mods = .{} }, .normal) == .none);

    // The hint strip is generated from the bindings, so an unbound command
    // simply stops being offered rather than advertising a dead key.
    var buf: [256]u8 = undefined;
    const strip = keymap.hints(l.cfg.keys, .normal, &buf);
    try testing.expect(std.mem.indexOf(u8, strip, "e edit") == null);
}

test "a remap that would shadow another binding is refused, not accepted" {
    // `<Space>` on its own is a prefix of every leader sequence, so binding it
    // makes them all unreachable while leaving them listed in the popup. The
    // config keeps its previous keymap and says why.
    var l = loadText(
        \\[keys]
        \\quit = "<Space>"
    );
    defer l.deinit();

    try testing.expectEqual(@as(usize, 1), l.problems.items.len);
    try testing.expect(std.mem.indexOf(u8, l.problems.items[0].text, "shadows") != null);
    try testing.expectEqual(keymap.default_bindings.ptr, l.cfg.keys.ptr);

    // The other direction too: a sequence that an existing binding swallows.
    var l2 = loadText(
        \\[keys]
        \\refresh = "jj"
    );
    defer l2.deinit();
    try testing.expectEqual(@as(usize, 1), l2.problems.items.len);
    try testing.expectEqual(keymap.default_bindings.ptr, l2.cfg.keys.ptr);

    // And a key that is simply already taken: not a prefix of anything, just
    // dead, because the matcher returns the first binding it finds.
    var l3 = loadText(
        \\[keys]
        \\refresh = "q"
    );
    defer l3.deinit();
    try testing.expectEqual(@as(usize, 1), l3.problems.items.len);
    try testing.expect(std.mem.indexOf(u8, l3.problems.items[0].text, "already bound to quit") != null);
    try testing.expectEqual(keymap.default_bindings.ptr, l3.cfg.keys.ptr);
}

test "a command nobody has heard of names itself" {
    var l = loadText(
        \\[keys]
        \\yeet = "y"
    );
    defer l.deinit();
    try testing.expectEqual(@as(usize, 1), l.problems.items.len);
    try testing.expect(std.mem.indexOf(u8, l.problems.items[0].text, "yeet") != null);
    try testing.expectEqual(keymap.default_bindings.ptr, l.cfg.keys.ptr);
}

test "a key that cannot be spelled is refused with the spelling in the message" {
    var l = loadText(
        \\[keys]
        \\quit = "<Meta-q>"
    );
    defer l.deinit();
    try testing.expectEqual(@as(usize, 1), l.problems.items.len);
    try testing.expect(std.mem.indexOf(u8, l.problems.items[0].text, "<Meta-q>") != null);
}

test "comments and quoting" {
    var l = loadText(
        \\[ui] # trailing comment
        \\icons = "ascii"   # so is this
    );
    defer l.deinit();
    try testing.expectEqual(@as(usize, 0), l.problems.items.len);
    try testing.expectEqual(Icons.ascii, l.cfg.ui.icons);

    // A `#` inside a string is data. Template strings are full of them
    // (FEATURES.md 4.5: `ref_single = "#{change_id} {path}:{line}"`), and
    // truncating one at the `#` would corrupt it silently.
    try testing.expect(std.mem.eql(u8, stripComment("x = \"#{id}\" # note"), "x = \"#{id}\" "));
}

test "escapes inside a string" {
    var l = Loader.init(testing.allocator);
    defer l.deinit();
    const s = l.parseString("config.toml", 1, "\"a\\nb\\\"c\"").?;
    try testing.expectEqualStrings("a\nb\"c", s);
    try testing.expect(l.parseString("config.toml", 1, "\"unterminated") == null);
    try testing.expectEqual(@as(usize, 1), l.problems.items.len);
}

test "the later file wins, key by key" {
    // Merge, do not replace (FEATURES.md 4.8): the repo file overrides the one
    // key it names and leaves the rest of the global file standing.
    var l = Loader.init(testing.allocator);
    defer l.deinit();
    l.merge("global.toml",
        \\[nav]
        \\scrolloff = 9
        \\hunk_crosses_files = false
        \\[ui]
        \\icons = "ascii"
    );
    l.merge(".lgtm/config.toml",
        \\[nav]
        \\scrolloff = 1
    );

    try testing.expectEqual(@as(u32, 1), l.cfg.nav.scrolloff);
    try testing.expect(!l.cfg.nav.hunk_crosses_files);
    try testing.expectEqual(Icons.ascii, l.cfg.ui.icons);
}

test "the status line gets one line, with a count of the rest" {
    var l = loadText(
        \\[nav]
        \\scrolloff = "three"
        \\hunk_crosses_files = 1
    );
    defer l.deinit();

    var buf: [192]u8 = undefined;
    const line = l.summary(&buf).?;
    // The file's basename, the line number, and the first message: enough to
    // go and fix it without the path eating the status row.
    try testing.expect(std.mem.startsWith(u8, line, "config.toml:2:"));
    try testing.expect(std.mem.endsWith(u8, line, "(+1 more)"));

    // A file that could not be read at all has no line to point at, and
    // "config.toml:0" reads like a line number rather than the whole file.
    var whole = Loader.init(testing.allocator);
    defer whole.deinit();
    whole.note("missing.toml", 0, "cannot read: {t}", .{error.FileNotFound});
    try testing.expectEqualStrings("missing.toml: cannot read: FileNotFound", whole.summary(&buf).?);

    // A clean config costs the status row nothing.
    var clean = loadText("[nav]\nscrolloff = 2\n");
    defer clean.deinit();
    try testing.expect(clean.summary(&buf) == null);
}

test "a file with nothing in it is a config that changes nothing" {
    var l = loadText("");
    defer l.deinit();
    try testing.expectEqual(@as(usize, 0), l.problems.items.len);
    try testing.expectEqual(keymap.default_bindings.ptr, l.cfg.keys.ptr);
    try testing.expect(std.meta.eql(l.cfg.nav, Nav{}));
}
