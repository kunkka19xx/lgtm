// SPDX-License-Identifier: Apache-2.0
//
// The config file. A small TOML subset, read from the global file and then the
// repo's, merged rather than replaced - and never fatal
//. A bad line costs that one key its value, is reported with
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
// `ui/theme.zig` is imported for `[theme]`, and it is a compile-time
// dependency on vaxis's `Style` and `Color` types only - no terminal is
// involved, so every rule below is still a unit test. `ui.icons` stays a named
// enum resolved by `ui/app.zig`, because a glyph set is not a colour and the
// mapping belongs where the drawing happens.

const std = @import("std");
const Allocator = std.mem.Allocator;

const fs = @import("io/fs.zig");
const keymap = @import("ui/keymap.zig");
const rows = @import("ui/rows.zig");
const keytext = @import("ui/keytext.zig");
const theme = @import("ui/theme.zig");
const toml = @import("toml.zig");

/// A config file larger than this is not a config file. Reading it is the one
/// thing on the cold-start path that a user can make arbitrarily slow.
pub const max_bytes: usize = 256 << 10;

/// `ui.icons`. Named here rather than as a `theme.Glyphs` value so this module
/// stays free of vaxis; `ui/app.zig` does the mapping.
/// `ui.icons`. `nerd` adds per-filetype icons to the file list and assumes a
/// patched font; the other two assume nothing, which is why one of them is the
/// default.
pub const Icons = enum { unicode, ascii, nerd };

/// Where the compose box sits, and therefore where the lists it opens go: they
/// take the room on the other side of it. Bottom by default, which is where a
/// terminal puts the thing you are typing into.
pub const ComposeAt = enum { bottom, top, centre };

/// How a comment shows in the diff.
///
/// `marker`, the default, draws only the gutter dot and leaves reading it to
/// `<Space>vc`. A diff is dense already, and a remark spliced between two
/// lines of code puts prose where the reader is scanning structure - the dot
/// says "there is something here" without taking a row to say it.
///
/// `inline` draws the text under its line for readers who would rather have
/// the remark in front of them than one keystroke away.
pub const CommentStyle = enum { inline_, marker };

/// `[diff] layout`. `auto` is responsive: side by side when the pane is wide
/// enough for two readable columns, flow when it is not. The other two are the
/// reader saying so themselves.
///
/// `flow` is the one-column diff every other tool calls unified, and
/// `"unified"` is accepted for it: that is the name of the *format*, and
/// someone will reach for it.
pub const Layout = enum { auto, flow, split };

/// `[diff] highlight`. How far a change's colour reaches: the gutter mark
/// alone, or a wash over the whole row.
pub const Highlight = enum { gutter, line };

pub const Diff = struct {
    layout: Layout = .auto,
    highlight: Highlight = .line,
    /// Below this many columns, `auto` reads flow. The number is the
    /// arithmetic: each side needs a line number, a sign, a gutter and about
    /// forty columns of code, and a divider sits between them. Under that,
    /// side by side wraps so hard it shows less than the flow view it
    /// replaced.
    split_min_width: u16 = 100,
};

pub const Ui = struct {
    icons: Icons = .unicode,
    compose: ComposeAt = .bottom,
    comments: CommentStyle = .marker,
    /// Soft wrap. On, a line wider than the pane continues on the next screen
    /// row; off, it is cut at the edge. Default on because the pane this is
    /// designed for is a split one, and a review that hides the end of a line
    /// is a review of the part that fit.
    wrap: bool = true,
    /// The longest a scroll may take to arrive, in milliseconds. A short jump
    /// finishes sooner: it travels at one screen row per frame, which is the
    /// finest a cell grid can draw, and runs out of rows. Zero is the old
    /// behaviour, where the viewport teleports. One key rather than a flag and
    /// a duration: they would be the same decision spelled twice, and `0`
    /// already says off.
    scroll_ms: u32 = 250,
    /// The longest the cursor takes to travel to where a motion put it. Every
    /// motion moves it, so this is the one the reader feels most; a short hop
    /// arrives sooner because it moves a cell a frame and runs out of cells.
    /// Zero puts it there at once.
    cursor_ms: u32 = 80,
};

/// Navigation policy: motions that could reasonably go either way are settings
/// rather than opinions baked into dispatch.
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
    /// Submitting a review takes the mark (`m`) as well as sending the file.
    /// Default true: handing the agent a review is the one moment the reader
    /// has demonstrably read everything, which is the whole definition of the
    /// mark - and a feature that needs remembering to press a key first is one
    /// that will be remembered after it was needed. False for the reader whose
    /// mark spans more than one round and should not be moved under them.
    mark_on_submit: bool = true,
};

pub const Config = struct {
    nav: Nav = .{},
    ui: Ui = .{},
    diff: Diff = .{},
    /// The resolved theme: a bundled palette, then whatever slots the file
    /// overrode. Resolved here rather than carried as a name, so the app is
    /// handed styles and never has to know a theme could have failed to load.
    theme: theme.Theme = theme.default,
    /// The keymap after any `[keys]` overrides. Points straight at the
    /// defaults until something overrides them, so the ordinary run - no
    /// config file, or one that does not touch keys - allocates nothing.
    keys: []const keymap.Binding = keymap.default_bindings,
    /// Questions the compose box can drop in at the caret, in file order.
    /// Empty until a `[presets]` table names some, and the four built-in asks
    /// stand in for it - so the list is never empty and never a surprise.
    presets: []const Preset = &.{},
    /// `[review] ignore`: glob patterns for files kept out of the review.
    /// Empty means everything git reports, which is the behaviour that was
    /// there before this existed.
    ignore: []const []const u8 = &.{},
};

/// One insertable question. The name is what the picker lists; the text is
/// what lands in the message.
pub const Preset = struct {
    name: []const u8,
    text: []const u8,
};

/// One thing wrong with one line, in the words the user needs to fix it: which
/// file, which line, which key.
pub const Problem = struct {
    source: []const u8,
    line: u32,
    text: []const u8,
};

const Section = enum { nav, ui, diff, keys, theme, presets, review };

/// Accumulates one config across however many files it came from. Merging is
/// per key, not per file: a repo file that sets one binding leaves the global
/// file's theme and navigation exactly as they were.
pub const Loader = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    cfg: Config = .{},
    problems: std.ArrayList(Problem) = .empty,
    /// Grown as `[presets]` is parsed; `cfg.presets` points at its items.
    preset_list: std.ArrayList(Preset) = .empty,

    pub fn init(gpa: Allocator) Loader {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    /// Frees everything the config points at, so it must outlive the app that
    /// is using it - `cfg.keys` and every problem string live in the arena.
    pub fn deinit(self: *Loader) void {
        self.preset_list.deinit(self.gpa);
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

    /// Merges one document. Pure: no file, no terminal, no allocation the
    /// caller has to think about - which is what lets every rule below be a
    /// test. The reading is `toml.zig`'s; what happens here is deciding what
    /// each setting means and saying so when it means nothing.
    pub fn merge(self: *Loader, source: []const u8, text: []const u8) void {
        const arena = self.arena.allocator();
        const src = arena.dupe(u8, source) catch return;
        var parser: toml.Parser = .init(arena, text);

        var section: ?Section = null;
        // Inside a section this build does not know. Its keys are skipped
        // without a word each: the unknown header is already reported, and a
        // future `[templates]` block read by an older binary should cost one
        // line of complaint, not one per setting.
        var in_unknown = false;

        while (parser.next()) |ev| switch (ev) {
            .table => |t| {
                section = std.meta.stringToEnum(Section, t.name) orelse {
                    self.note(src, t.line, "unknown section '[{s}]'", .{t.name});
                    // Not merely "unknown": its keys must not land in whatever
                    // table came before it.
                    section = null;
                    in_unknown = true;
                    continue;
                };
                in_unknown = false;
            },
            .item => |it| {
                const sect = section orelse {
                    if (!in_unknown) self.note(src, it.line, "'{s}' is outside any section", .{it.key});
                    continue;
                };
                self.apply(src, it.line, sect, it.key, it.value);
            },
            .problem => |p| self.noteFault(src, p),
        };
    }

    /// A parser fault, in words. The parser reports what it found; this is
    /// where it becomes something a user can act on, because the sentence
    /// depends on what the line was trying to say.
    fn noteFault(self: *Loader, src: []const u8, p: toml.Problem) void {
        switch (p.fault) {
            .unterminated_table => self.note(src, p.line, "unterminated table header", .{}),
            .expected_assignment => self.note(src, p.line, "expected 'key = value'", .{}),
            .missing_key => self.note(src, p.line, "missing key before '='", .{}),
            .missing_value => self.note(src, p.line, "missing value after '='", .{}),
            .unreadable_value => self.note(src, p.line, "cannot read value '{s}'", .{p.text}),
            .unterminated_string => self.note(src, p.line, "unterminated string", .{}),
            .trailing_text => self.note(src, p.line, "trailing text after the value", .{}),
            .bad_escape => self.note(src, p.line, "unknown escape '\\{s}'", .{p.text}),
            .unterminated_list => self.note(src, p.line, "unterminated list", .{}),
            .list_wants_strings => self.note(src, p.line, "a list holds strings, and that is not one", .{}),
        }
    }

    fn apply(self: *Loader, src: []const u8, line: u32, section: Section, key: []const u8, value: toml.Value) void {
        switch (section) {
            .nav => {
                if (std.mem.eql(u8, key, "hunk_crosses_files")) {
                    self.cfg.nav.hunk_crosses_files = self.wantBool(src, line, key, value) orelse return;
                } else if (std.mem.eql(u8, key, "mark_on_submit")) {
                    self.cfg.nav.mark_on_submit = self.wantBool(src, line, key, value) orelse return;
                } else if (std.mem.eql(u8, key, "scrolloff")) {
                    const n = self.wantInt(src, line, key, value) orelse return;
                    if (n < 0 or n > 64) {
                        self.note(src, line, "nav.scrolloff must be between 0 and 64", .{});
                        return;
                    }
                    self.cfg.nav.scrolloff = @intCast(n);
                } else self.unknownKey(src, line, section, key);
            },
            .diff => {
                if (std.mem.eql(u8, key, "layout")) {
                    const t = self.wantString(src, line, key, value) orelse return;
                    self.cfg.diff.layout = if (std.mem.eql(u8, t, "unified"))
                        .flow
                    else
                        std.meta.stringToEnum(Layout, t) orelse {
                            self.note(src, line, "diff.layout must be \"auto\", \"flow\" or \"split\", not \"{s}\"", .{t});
                            return;
                        };
                } else if (std.mem.eql(u8, key, "highlight")) {
                    const t = self.wantString(src, line, key, value) orelse return;
                    self.cfg.diff.highlight = std.meta.stringToEnum(Highlight, t) orelse {
                        self.note(src, line, "diff.highlight must be \"gutter\" or \"line\", not \"{s}\"", .{t});
                        return;
                    };
                } else if (std.mem.eql(u8, key, "split_min_width")) {
                    const n = self.wantInt(src, line, key, value) orelse return;
                    // The floor is `rows.min_split_width`, where two columns
                    // stop holding a line of code at all: a threshold below it
                    // could never be reached. Above 400 the setting has
                    // stopped meaning anything, because no pane is that wide.
                    if (n < rows.min_split_width or n > 400) {
                        self.note(src, line, "diff.split_min_width must be between {d} and 400", .{rows.min_split_width});
                        return;
                    }
                    self.cfg.diff.split_min_width = @intCast(n);
                } else self.unknownKey(src, line, section, key);
            },
            .ui => {
                if (std.mem.eql(u8, key, "wrap")) {
                    self.cfg.ui.wrap = self.wantBool(src, line, key, value) orelse return;
                } else if (std.mem.eql(u8, key, "scroll_ms")) {
                    const n = self.wantInt(src, line, key, value) orelse return;
                    if (n < 0 or n > 1000) {
                        self.note(src, line, "ui.scroll_ms must be between 0 and 1000", .{});
                        return;
                    }
                    self.cfg.ui.scroll_ms = @intCast(n);
                } else if (std.mem.eql(u8, key, "cursor_ms")) {
                    const n = self.wantInt(src, line, key, value) orelse return;
                    if (n < 0 or n > 1000) {
                        self.note(src, line, "ui.cursor_ms must be between 0 and 1000", .{});
                        return;
                    }
                    self.cfg.ui.cursor_ms = @intCast(n);
                } else if (std.mem.eql(u8, key, "compose")) {
                    const t = self.wantString(src, line, key, value) orelse return;
                    self.cfg.ui.compose = std.meta.stringToEnum(ComposeAt, t) orelse {
                        self.note(src, line, "ui.compose must be \"bottom\", \"top\" or \"centre\", not \"{s}\"", .{t});
                        return;
                    };
                } else if (std.mem.eql(u8, key, "comments")) {
                    const t = self.wantString(src, line, key, value) orelse return;
                    self.cfg.ui.comments = if (std.mem.eql(u8, t, "inline"))
                        .inline_
                    else if (std.mem.eql(u8, t, "marker"))
                        .marker
                    else {
                        self.note(src, line, "ui.comments must be \"inline\" or \"marker\", not \"{s}\"", .{t});
                        return;
                    };
                } else if (std.mem.eql(u8, key, "icons")) {
                    const s = self.wantString(src, line, key, value) orelse return;
                    self.cfg.ui.icons = std.meta.stringToEnum(Icons, s) orelse {
                        self.note(src, line, "ui.icons must be \"unicode\", \"ascii\" or \"nerd\", not \"{s}\"", .{s});
                        return;
                    };
                } else self.unknownKey(src, line, section, key);
            },
            // `[keys]` keys are command names, so there is no fixed list to
            // check against - the `Command` enum is the list.
            .keys => self.applyKeys(src, line, key, value),
            // Every key is a preset name, so there is no fixed list to check
            // against - what the user writes is what the picker offers.
            .presets => self.applyPreset(src, line, key, value),
            .review => {
                if (std.mem.eql(u8, key, "ignore")) {
                    self.applyIgnore(src, line, value);
                } else self.unknownKey(src, line, section, key);
            },
            .theme => self.applyTheme(src, line, key, value),
        }
    }

    /// `ignore = ["package-lock.json", "**/*.pb.go"]`, replacing rather than
    /// appending: a repo that lists its own generated files means those, not
    /// those plus whatever the global file happened to name.
    ///
    /// The patterns are not validated here, because git owns their meaning.
    /// A pattern that matches nothing hides nothing, which is the same thing
    /// a typo in a `.gitignore` does, and reporting it would mean
    /// reimplementing the matcher to find out.
    fn applyIgnore(self: *Loader, src: []const u8, line: u32, value: toml.Value) void {
        const arena = self.arena.allocator();
        var one: [1][]const u8 = undefined;
        const items: []const []const u8 = switch (value) {
            .list => |l| l,
            .string => |t| blk: {
                one[0] = t;
                break :blk one[0..1];
            },
            else => {
                self.note(src, line, "review.ignore wants a string or a list, not {s}", .{value.typeName()});
                return;
            },
        };

        const out = arena.alloc([]const u8, items.len) catch return;
        var n: usize = 0;
        for (items) |pat| {
            if (pat.len == 0) continue;
            out[n] = arena.dupe(u8, pat) catch return;
            n += 1;
        }
        self.cfg.ignore = out[0..n];
    }

    /// `name = "the question"`, appended in file order so the picker lists
    /// them the way they were written rather than in some internal order.
    ///
    /// A later file overrides a name it repeats rather than listing it twice:
    /// a repo config refining one of the global questions should leave one
    /// entry, and `[presets]` is merged per key like everything else.
    fn applyPreset(self: *Loader, src: []const u8, line: u32, key: []const u8, value: toml.Value) void {
        const arena = self.arena.allocator();
        const text = self.wantString(src, line, key, value) orelse return;
        if (text.len == 0) {
            self.note(src, line, "presets.{s} is empty", .{key});
            return;
        }

        const name = arena.dupe(u8, key) catch return;
        const body = arena.dupe(u8, text) catch return;
        for (self.preset_list.items) |*p| {
            if (std.mem.eql(u8, p.name, name)) {
                p.text = body;
                return;
            }
        }
        self.preset_list.append(self.gpa, .{ .name = name, .text = body }) catch return;
        self.cfg.presets = self.preset_list.items;
    }

    /// `command = "<seq>"` or `command = ["<seq>", "<seq>"]`, replacing every
    /// binding of that command. An empty list unbinds it: the hint strip and
    /// the `?` popup are both generated from the bindings, so a command with
    /// no keys simply stops being advertised rather than lying about itself.
    fn applyKeys(self: *Loader, src: []const u8, line: u32, key: []const u8, value: toml.Value) void {
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
            const chords = keytext.parseChords(seq, &buf) catch |err| {
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
        // previous keymap is the rule: fall back for
        // that key only, and say why.
        if (keymap.shadowed(next.items)) |hit| {
            var fbuf: [keytext.max_keys_bytes]u8 = undefined;
            var sbuf: [keytext.max_keys_bytes]u8 = undefined;
            const first = keytext.bufWriteChords(hit.first.chords, &fbuf);
            const second = keytext.bufWriteChords(hit.second.chords, &sbuf);
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

    /// `name` picks a bundled palette; every other key is a slot, overriding
    /// whatever the palette put there. In file order, so `name` after a slot
    /// override discards it - which is the only reading that stays
    /// predictable when two files each set both.
    fn applyTheme(self: *Loader, src: []const u8, line: u32, key: []const u8, value: toml.Value) void {
        const spec = self.wantString(src, line, key, value) orelse return;
        if (std.mem.eql(u8, key, "name")) {
            self.cfg.theme = theme.byName(spec) orelse {
                var buf: [256]u8 = undefined;
                self.note(src, line, "no theme called \"{s}\" - try {s}", .{ spec, themeNames(&buf) });
                return;
            };
            return;
        }
        const style = theme.parseStyle(spec) catch |err| {
            self.note(src, line, "theme.{s}: cannot read \"{s}\" ({t})", .{ key, spec, err });
            return;
        };
        if (!theme.setSlot(&self.cfg.theme, key, style)) {
            self.note(src, line, "theme has no slot called '{s}'", .{key});
        }
    }

    fn wantBool(self: *Loader, src: []const u8, line: u32, key: []const u8, v: toml.Value) ?bool {
        return switch (v) {
            .boolean => |b| b,
            else => {
                self.note(src, line, "{s} wants true or false, not {s}", .{ key, v.typeName() });
                return null;
            },
        };
    }

    fn wantInt(self: *Loader, src: []const u8, line: u32, key: []const u8, v: toml.Value) ?i64 {
        return switch (v) {
            .integer => |n| n,
            else => {
                self.note(src, line, "{s} wants a number, not {s}", .{ key, v.typeName() });
                return null;
            },
        };
    }

    fn wantString(self: *Loader, src: []const u8, line: u32, key: []const u8, v: toml.Value) ?[]const u8 {
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

/// The bundled names, for the message a wrong one gets. A list of what does
/// work beats "unknown theme" by exactly the amount of searching it saves.
/// Public because `--theme` needs the same sentence.
pub fn themeNames(buf: []u8) []const u8 {
    var n: usize = 0;
    for (theme.bundled) |b| {
        const sep: usize = if (n == 0) 0 else 2;
        if (n + sep + b.name.len > buf.len) break;
        if (sep != 0) {
            buf[n] = ',';
            buf[n + 1] = ' ';
            n += 2;
        }
        @memcpy(buf[n..][0..b.name.len], b.name);
        n += b.name.len;
    }
    return buf[0..n];
}

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

/// Where the config lives. `$XDG_CONFIG_HOME` first, as every other tool on
/// the user's machine does, `~/.config` after it, and the repo's own file
/// last so that it wins.
pub const repo_path = fs.state_dir ++ "/config.toml";

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

// The parser this file reads its documents with; see the note in `ui/app.zig`.
test {
    _ = toml;
}

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
    // The rule, and the whole reason this parser reports
    // rather than returns an error: the typo on line 3 must not take line 4
    // down with it.
    var l = loadText(
        \\[nav]
        \\hunk_crosses_files = maybe
        \\scrolloff = 5
        \\[ui]
        \\icons = "emoji"
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

test "review.ignore takes one pattern or a list, and replaces rather than adds" {
    var l = loadText(
        \\[review]
        \\ignore = ["package-lock.json", "**/*.pb.go", ""]
    );
    defer l.deinit();
    try testing.expectEqual(@as(usize, 0), l.problems.items.len);
    // The empty entry is dropped: it would exclude nothing and git would take
    // it as a pathspec matching everything.
    try testing.expectEqual(@as(usize, 2), l.cfg.ignore.len);
    try testing.expectEqualStrings("package-lock.json", l.cfg.ignore[0]);

    // A repo file naming its own generated files means those, not those plus
    // whatever the global file happened to list.
    l.merge(".lgtm/config.toml",
        \\[review]
        \\ignore = "dist/**"
    );
    try testing.expectEqual(@as(usize, 1), l.cfg.ignore.len);
    try testing.expectEqualStrings("dist/**", l.cfg.ignore[0]);
}

test "a bad review.ignore is reported and the review still starts" {
    // Hard rule 8: a config error is a status-line notice, never a refusal.
    var l = loadText(
        \\[review]
        \\ignore = 42
    );
    defer l.deinit();
    try testing.expectEqual(@as(usize, 1), l.problems.items.len);
    try testing.expectEqual(@as(usize, 0), l.cfg.ignore.len);
}

test "keys are remapped by the spelling the popup shows" {
    var l = loadText(
        \\[keys]
        \\refresh = ["<C-l>", "<Space>R"]
        \\quit = "Q"
    );
    defer l.deinit();
    try testing.expectEqual(@as(usize, 0), l.problems.items.len);

    var km: keymap.Keymap = .{ .bindings = l.cfg.keys };
    // The new spelling fires.
    try testing.expect(km.feed(.{ .codepoint = ' ', .mods = .{} }, .normal) == .pending);
    try testing.expectEqual(keymap.Command.refresh, km.feed(.{ .codepoint = 'R', .mods = .{} }, .normal).command);
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
    // `<Space>e` is what opens the editor; with it unbound the leader is a
    // prefix of nothing that leads there.
    try testing.expect(km.feed(.{ .codepoint = ' ', .mods = .{} }, .normal) == .pending);
    try testing.expect(km.feed(.{ .codepoint = 'e', .mods = .{} }, .normal) == .none);

    // The hint strip is generated from the bindings, so an unbound command
    // simply stops being offered rather than advertising a dead key.
    var buf: [256]u8 = undefined;
    const strip = keytext.hints(l.cfg.keys, .normal, &buf);
    try testing.expect(std.mem.indexOf(u8, strip, "e edit") == null);
}

test "a remap that would shadow another binding is refused, not accepted" {
    // `<Space>` on its own is a prefix of every leader sequence, so binding it
    // makes them all unreachable while leaving them listed in the popup. The
    // config keeps its previous keymap and says why.
    var l = loadText(
        \\[keys]
        \\refresh = "<Space>"
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
        \\refresh = "e"
    );
    defer l3.deinit();
    try testing.expectEqual(@as(usize, 1), l3.problems.items.len);
    try testing.expect(std.mem.indexOf(u8, l3.problems.items[0].text, "already bound to word_end") != null);
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
}

test "a bad escape names the escape, not the line" {
    // The parser reports the fault; the sentence is this file's. Both halves
    // have to line up, and this is the seam where they meet.
    var l = loadText(
        \\[theme]
        \\name = "a\qb"
    );
    defer l.deinit();
    try testing.expectEqual(@as(usize, 1), l.problems.items.len);
    try testing.expect(std.mem.indexOf(u8, l.problems.items[0].text, "unknown escape") != null);
    try testing.expect(std.mem.indexOf(u8, l.problems.items[0].text, "q") != null);
    // And the theme it had is the theme it keeps.
    try testing.expectEqual(theme.default.accent, l.cfg.theme.accent);
}

test "the later file wins, key by key" {
    // Merge, do not replace: the repo file overrides the one
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

test "a theme is picked by name and then adjusted by slot" {
    var l = loadText(
        \\[theme]
        \\name = "gruvbox"
        \\add_sign = "#00ff00 bold"
        \\cursor_line = "on 236"
    );
    defer l.deinit();

    try testing.expectEqual(@as(usize, 0), l.problems.items.len);
    // The palette came from the named theme...
    try testing.expectEqual(theme.byName("gruvbox").?.keyword, l.cfg.theme.keyword);
    // ...and the two slots the file names came from the file.
    try testing.expectEqual(theme.Color{ .rgb = .{ 0, 0xff, 0 } }, l.cfg.theme.add_sign.fg);
    try testing.expect(l.cfg.theme.add_sign.bold);
    try testing.expectEqual(theme.Color{ .index = 236 }, l.cfg.theme.cursor_line.bg);
}

test "a theme nobody has lists the ones that exist" {
    var l = loadText(
        \\[theme]
        \\name = "solarized"
    );
    defer l.deinit();
    try testing.expectEqual(@as(usize, 1), l.problems.items.len);
    // "unknown theme" sends the user to the documentation; naming them saves
    // the trip.
    try testing.expect(std.mem.indexOf(u8, l.problems.items[0].text, "catppuccin") != null);
    // And the theme they had is the one they keep.
    try testing.expectEqual(theme.default.accent, l.cfg.theme.accent);
}

test "a slot or a colour that cannot be read keeps the rest of the theme" {
    var l = loadText(
        \\[theme]
        \\name = "dracula"
        \\risk_high = "#ff0000"
        \\add_sign = "chartreuse"
    );
    defer l.deinit();

    try testing.expectEqual(@as(usize, 2), l.problems.items.len);
    try testing.expect(std.mem.indexOf(u8, l.problems.items[0].text, "risk_high") != null);
    try testing.expect(std.mem.indexOf(u8, l.problems.items[1].text, "chartreuse") != null);
    // Everything the file got right still applied, including the slot the bad
    // line was trying to change.
    try testing.expectEqual(theme.byName("dracula").?.add_sign, l.cfg.theme.add_sign);
    try testing.expectEqual(theme.byName("dracula").?.keyword, l.cfg.theme.keyword);
}

test "diff.layout takes flow, split, and the format's own name for flow" {
    var d = loadText("");
    defer d.deinit();
    try testing.expectEqual(Layout.auto, d.cfg.diff.layout);
    try testing.expectEqual(@as(u16, 100), d.cfg.diff.split_min_width);

    var f = loadText(
        \\[diff]
        \\layout = "flow"
        \\split_min_width = 120
    );
    defer f.deinit();
    try testing.expectEqual(Layout.flow, f.cfg.diff.layout);
    try testing.expectEqual(@as(u16, 120), f.cfg.diff.split_min_width);
    try testing.expectEqual(@as(usize, 0), f.problems.items.len);

    // "unified" is the name of the format and the name every other tool uses,
    // so it reads as flow rather than as a typo.
    var u = loadText(
        \\[diff]
        \\layout = "unified"
    );
    defer u.deinit();
    try testing.expectEqual(Layout.flow, u.cfg.diff.layout);
    try testing.expectEqual(@as(usize, 0), u.problems.items.len);

    // A name that is neither costs that one key its value and nothing else.
    var bad = loadText(
        \\[diff]
        \\layout = "sideways"
        \\split_min_width = 9
    );
    defer bad.deinit();
    try testing.expectEqual(Layout.auto, bad.cfg.diff.layout);
    try testing.expectEqual(@as(u16, 100), bad.cfg.diff.split_min_width);
    try testing.expectEqual(@as(usize, 2), bad.problems.items.len);
}

test "nav.mark_on_submit is on by default and can be turned off" {
    var l = loadText(
        \\[nav]
        \\mark_on_submit = false
    );
    defer l.deinit();
    try testing.expect(!l.cfg.nav.mark_on_submit);
    try testing.expectEqual(@as(usize, 0), l.problems.items.len);

    var d = loadText("");
    defer d.deinit();
    try testing.expect(d.cfg.nav.mark_on_submit);
}
