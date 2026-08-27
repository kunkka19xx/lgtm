// SPDX-License-Identifier: Apache-2.0
//
// Every action is a named command and the keymap maps sequences to names, so
// dispatch contains no hardcoded keys (FEATURES.md 4.3). Remapping and presets
// are phase 5c; the indirection is here from the start because retrofitting it
// means touching every call site.

const std = @import("std");
const Allocator = std.mem.Allocator;
const event = @import("../core/event.zig");

pub const Command = enum {
    quit,
    line_down,
    line_up,
    page_down,
    page_up,
    top,
    bottom,
    next_hunk,
    prev_hunk,
    next_file,
    prev_file,
    center,
    refresh,
    /// Enter and leave visual line select. One command rather than two,
    /// because `V` in visual mode is what leaves it.
    visual_toggle,
    /// Escape: leave visual mode, and nothing at all in normal mode. Bound
    /// only in visual so that a stray Escape in normal mode stays inert.
    visual_cancel,
    search_forward,
    search_next,
    search_prev,
    open_editor,
    command_line,
    /// Hide the chrome and give the body the whole pane.
    toggle_zen,
    /// Open the `?` overlay, and close it again from inside.
    help,
    /// Move the popup's selection. Only live in `help`, so these keys stay
    /// free for the review itself.
    help_down,
    help_up,
    /// Sideways, by a whole column: the popup is a grid, not a list.
    help_left,
    help_right,
};

/// Which modes a binding is live in. Motions are live in both, which is what
/// makes visual select "normal mode plus an anchor" rather than a second
/// dispatch table that has to be kept in step with the first.
pub const Modes = packed struct(u8) {
    normal: bool = false,
    visual: bool = false,
    help: bool = false,
    _pad: u5 = 0,

    pub const both: Modes = .{ .normal = true, .visual = true };
    pub const normal_only: Modes = .{ .normal = true };
    pub const visual_only: Modes = .{ .visual = true };
    /// Inside the `?` popup. Only navigation lives here: every other key is
    /// filter text, so binding anything else would take a letter away from
    /// the search.
    pub const help_only: Modes = .{ .help = true };

    pub fn has(self: Modes, mode: event.Mode) bool {
        return switch (mode) {
            .normal => self.normal,
            .visual => self.visual,
            .help => self.help,
            // The prompt modes never reach the keymap: `prompt.zig` takes the
            // keys, because they are text rather than actions.
            else => false,
        };
    }
};

pub const Chord = struct {
    cp: u21,
    ctrl: bool = false,

    pub fn matches(self: Chord, key: event.Key) bool {
        return self.cp == key.codepoint and self.ctrl == key.mods.ctrl;
    }
};

pub const Binding = struct {
    chords: []const Chord,
    command: Command,
    modes: Modes = Modes.both,
    /// Shown in the status-line hint strip. Null keeps a binding working but
    /// unadvertised, which is how aliases stay out of an already tight row.
    hint: ?[]const u8 = null,
    /// One line in the `?` overlay. Null for aliases, for the same reason
    /// `hint` is: `[h` does not need its own row next to `]h`, and three ways
    /// to close the overlay do not need three rows saying "close".
    desc: ?[]const u8 = null,
};

fn c(cp: u21) Chord {
    return .{ .cp = cp };
}

fn ctrl(cp: u21) Chord {
    return .{ .cp = cp, .ctrl = true };
}

/// The leader. Named once so rebinding it is one edit rather than a sweep over
/// every sequence that starts with it. Space is unbound on its own and must
/// stay that way: `feed` resolves an exact match as soon as it finds one, so a
/// bare-Space binding would shadow every `<leader>x` sequence behind it.
pub const leader: Chord = c(' ');

/// The v0.1 set. Only bindings that do something are listed: a hint strip that
/// advertises keys the build does not implement is worse than a shorter one.
pub const default_bindings: []const Binding = &.{
    .{ .chords = &.{c('j')}, .command = .line_down, .hint = "j k move", .desc = "down a line" },
    .{ .chords = &.{c('k')}, .command = .line_up, .desc = "up a line" },
    .{ .chords = &.{ctrl('d')}, .command = .page_down, .desc = "down half a page" },
    .{ .chords = &.{ctrl('u')}, .command = .page_up, .desc = "up half a page" },
    .{ .chords = &.{ c('g'), c('g') }, .command = .top, .desc = "first line" },
    .{ .chords = &.{c('G')}, .command = .bottom, .desc = "last line" },
    .{ .chords = &.{ c(']'), c('h') }, .command = .next_hunk, .hint = "]h [h hunk", .desc = "next hunk" },
    .{ .chords = &.{ c('['), c('h') }, .command = .prev_hunk, .desc = "previous hunk" },
    .{ .chords = &.{ c(']'), c('f') }, .command = .next_file, .hint = "]f [f file", .desc = "next file (wraps)" },
    .{ .chords = &.{ c('['), c('f') }, .command = .prev_file, .desc = "previous file (wraps)" },
    .{ .chords = &.{ leader, c('n'), c('f') }, .command = .next_file, .desc = "next file" },
    .{ .chords = &.{ leader, c('p'), c('f') }, .command = .prev_file, .desc = "previous file" },
    .{ .chords = &.{ c('z'), c('z') }, .command = .center, .desc = "centre cursor line" },
    .{ .chords = &.{c('/')}, .command = .search_forward, .hint = "/ search", .desc = "search the review" },
    .{ .chords = &.{c('n')}, .command = .search_next, .desc = "next match" },
    .{ .chords = &.{c('N')}, .command = .search_prev, .desc = "previous match" },
    .{ .chords = &.{c('V')}, .command = .visual_toggle, .hint = "V select", .desc = "visual line select" },
    .{ .chords = &.{c(event.code.escape)}, .command = .visual_cancel, .modes = Modes.visual_only, .hint = "Esc cancel", .desc = "leave visual select" },
    .{ .chords = &.{c('e')}, .command = .open_editor, .hint = "e edit", .desc = "open line in $EDITOR" },
    .{ .chords = &.{c(event.code.tab)}, .command = .toggle_zen, .desc = "zen: hide the chrome" },
    .{ .chords = &.{c(':')}, .command = .command_line, .desc = "command line (:q)" },
    .{ .chords = &.{ctrl('l')}, .command = .refresh, .desc = "re-run the diff" },
    .{ .chords = &.{c('q')}, .command = .quit, .modes = Modes.normal_only, .hint = "q quit", .desc = "quit" },
    // `?` opens the overlay. Closing it is `prompt.zig`'s Escape, because
    // inside the overlay the keys are a filter query rather than commands.
    .{ .chords = &.{c('?')}, .command = .help, .desc = "this help" },
    // Inside the popup, and arrows first: a Ctrl chord is the one thing a
    // multiplexer takes before the application sees it. vim-tmux-navigator
    // binds C-h/C-j/C-k/C-l at the tmux *root* table and forwards them only to
    // processes matching its vim pattern, which `lgtm` does not - so `<C-j>`
    // there switches panes and never arrives. Nothing intercepts an arrow key,
    // so the arrows are what the popup advertises. `<C-n>`/`<C-p>` stay as
    // unadvertised aliases for the hands that learned them from other finders.
    // Shifted `HJKL`: vim's own motions, and the shifted pair is free where the
    // Ctrl one is not - a multiplexer binds `C-hjkl`, not `H`. Losing capitals
    // from the filter costs nothing, because matching is case-insensitive.
    // One shared description, which is what collapses them to `H J K L move`
    // in the footer instead of four rows of chrome.
    .{ .chords = &.{c('H')}, .command = .help_left, .modes = Modes.help_only, .desc = "move" },
    .{ .chords = &.{c('J')}, .command = .help_down, .modes = Modes.help_only, .desc = "move" },
    .{ .chords = &.{c('K')}, .command = .help_up, .modes = Modes.help_only, .desc = "move" },
    .{ .chords = &.{c('L')}, .command = .help_right, .modes = Modes.help_only, .desc = "move" },
    // Unadvertised aliases: arrows for hands that reach for them, `<C-n>`/
    // `<C-p>` for hands that learned other finders.
    .{ .chords = &.{c(event.code.down)}, .command = .help_down, .modes = Modes.help_only },
    .{ .chords = &.{c(event.code.up)}, .command = .help_up, .modes = Modes.help_only },
    .{ .chords = &.{c(event.code.right)}, .command = .help_right, .modes = Modes.help_only },
    .{ .chords = &.{c(event.code.left)}, .command = .help_left, .modes = Modes.help_only },
    .{ .chords = &.{ctrl('n')}, .command = .help_down, .modes = Modes.help_only },
    .{ .chords = &.{ctrl('p')}, .command = .help_up, .modes = Modes.help_only },
};

pub const Match = union(enum) {
    /// The sequence is complete.
    command: Command,
    /// A prefix of at least one binding: keep collecting.
    pending,
    /// Nothing can match. The caller drops the sequence.
    none,
};

/// Sequence matcher. Holds the keys typed so far towards a binding.
pub const Keymap = struct {
    bindings: []const Binding = default_bindings,
    pending: [max_sequence]event.Key = undefined,
    len: usize = 0,

    pub const max_sequence = 4;

    pub fn reset(self: *Keymap) void {
        self.len = 0;
    }

    /// Feeds one key for `mode`. Resolving or failing both clear the pending
    /// sequence, so a mistyped prefix never leaves the next keystroke
    /// stranded. Bindings not live in `mode` are invisible to the match,
    /// including as prefixes - otherwise a key bound only in visual mode would
    /// swallow the next keystroke in normal mode.
    pub fn feed(self: *Keymap, key: event.Key, mode: event.Mode) Match {
        if (self.len == max_sequence) self.len = 0;
        self.pending[self.len] = key;
        self.len += 1;
        const typed = self.pending[0..self.len];

        var prefix = false;
        for (self.bindings) |b| {
            if (!b.modes.has(mode)) continue;
            if (b.chords.len < typed.len) continue;
            var i: usize = 0;
            while (i < typed.len) : (i += 1) {
                if (!b.chords[i].matches(typed[i])) break;
            } else {
                if (b.chords.len == typed.len) {
                    self.len = 0;
                    return .{ .command = b.command };
                }
                prefix = true;
            }
        }
        if (prefix) return .pending;
        self.len = 0;
        return .none;
    }
};

/// The hint strip, built from the bindings themselves so it cannot drift from
/// what the keys actually do. Written into `buf`, which the caller owns - in
/// practice the frame arena.
pub fn hints(bindings: []const Binding, mode: event.Mode, buf: []u8) []const u8 {
    var n: usize = 0;
    for (bindings) |b| {
        if (!b.modes.has(mode)) continue;
        const h = b.hint orelse continue;
        const sep: usize = if (n == 0) 0 else 2;
        if (n + sep + h.len > buf.len) break;
        if (sep != 0) {
            buf[n] = ' ';
            buf[n + 1] = ' ';
            n += 2;
        }
        @memcpy(buf[n .. n + h.len], h);
        n += h.len;
    }
    return buf[0..n];
}

/// One row of the `?` overlay: the keys as the user would type them, and what
/// they do.
pub const HelpEntry = struct {
    keys: []const u8,
    desc: []const u8,
};

/// Renders a chord sequence the way a user would type it - `gg`, `<C-d>`,
/// `<Space>nf` - into `arena`, in practice the frame arena. Built from the
/// chords rather than written out beside them, so a remapped keymap describes
/// its own keys instead of the defaults (FEATURES.md 4.4).
pub fn writeChords(chords: []const Chord, arena: Allocator) Allocator.Error![]const u8 {
    var buf: [max_keys_bytes]u8 = undefined;
    return arena.dupe(u8, bufWriteChords(chords, &buf));
}

/// Longest a rendered sequence can be: `max_sequence` chords of `<Space>`.
pub const max_keys_bytes = max_sequence_bytes * Keymap.max_sequence;
const max_sequence_bytes = 8;

/// The allocation-free core of `writeChords`, so the same rendering feeds both
/// the drawn list and the filter that narrows it.
pub fn bufWriteChords(chords: []const Chord, buf: []u8) []const u8 {
    var n: usize = 0;
    for (chords) |ch| {
        var tmp: [max_sequence_bytes]u8 = undefined;
        const piece: []const u8 = if (ch.ctrl)
            std.fmt.bufPrint(&tmp, "<C-{u}>", .{ch.cp}) catch "<C-?>"
        else switch (ch.cp) {
            event.code.escape => "<Esc>",
            event.code.tab => "<Tab>",
            event.code.enter => "<CR>",
            event.code.backspace => "<BS>",
            // The arrows are kitty functional keycodes in a private-use area:
            // encoded as UTF-8 they render as nothing at all, so a name is the
            // only thing that shows up in the popup's own header.
            event.code.up => "<Up>",
            event.code.down => "<Down>",
            event.code.left => "<Left>",
            event.code.right => "<Right>",
            ' ' => "<Space>",
            else => tmp[0 .. std.unicode.utf8Encode(ch.cp, &tmp) catch 0],
        };
        if (n + piece.len > buf.len) break;
        @memcpy(buf[n..][0..piece.len], piece);
        n += piece.len;
    }
    return buf[0..n];
}

/// Whether `b` belongs in the popup for `mode` under `filter`, and how well it
/// matched. One predicate, used by both `helpEntries` and `helpCount`.
fn ranked(b: Binding, mode: event.Mode, filter: []const u8, kbuf: []u8) ?struct { keys: []const u8, desc: []const u8, run: bool } {
    if (!b.modes.has(mode)) return null;
    const d = b.desc orelse return null;
    const keys = bufWriteChords(b.chords, kbuf);
    if (filter.len == 0) return .{ .keys = keys, .desc = d, .run = true };

    var hay: [max_keys_bytes + 128]u8 = undefined;
    const text = std.fmt.bufPrint(&hay, "{s} {s}", .{ keys, d }) catch keys;
    if (containsIgnoreCase(text, filter)) return .{ .keys = keys, .desc = d, .run = true };
    if (fuzzyMatch(text, filter)) return .{ .keys = keys, .desc = d, .run = false };
    return null;
}

/// How many rows the popup will have. Lets the selection be clamped without
/// laying the list out first.
pub fn helpCount(bindings: []const Binding, mode: event.Mode, filter: []const u8) usize {
    var n: usize = 0;
    var kbuf: [max_keys_bytes]u8 = undefined;
    for (bindings) |b| {
        if (ranked(b, mode, filter, &kbuf) != null) n += 1;
    }
    return n;
}

/// Subsequence match, case-insensitive: `nfl` finds "next file". The same
/// shape of matching as every fuzzy finder the user already has, and enough
/// for a list of two dozen rows - there is no ranking, because with a list
/// this short the original order is more useful than a score.
pub fn fuzzyMatch(text: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    var qi: usize = 0;
    for (text) |ch| {
        if (std.ascii.toLower(ch) == std.ascii.toLower(query[qi])) {
            qi += 1;
            if (qi == query.len) return true;
        }
    }
    return false;
}

/// The `?` overlay's contents for `mode`, narrowed by `filter`. Bindings with
/// no `desc` are aliases and stay out, exactly as they stay out of the hint
/// strip. The filter runs over the keys as well as the description, so `spc`
/// finds the leader bindings and `ctrl` does not have to be spelled `<C-`.
pub fn helpEntries(
    bindings: []const Binding,
    mode: event.Mode,
    filter: []const u8,
    arena: Allocator,
) Allocator.Error![]const HelpEntry {
    var solid: std.ArrayList(HelpEntry) = .empty;
    var loose: std.ArrayList(HelpEntry) = .empty;
    var kbuf: [max_keys_bytes]u8 = undefined;
    for (bindings) |b| {
        const r = ranked(b, mode, filter, &kbuf) orelse continue;
        const entry: HelpEntry = .{ .keys = try arena.dupe(u8, r.keys), .desc = r.desc };
        // Two tiers rather than a score: a run of the query as typed comes
        // first, scattered letters after. Without this, "file" pulls up
        // "gg first line" alongside "next file" and the list reads as noise.
        if (r.run) try solid.append(arena, entry) else try loose.append(arena, entry);
    }
    try solid.appendSlice(arena, loose.items);
    return solid.toOwnedSlice(arena);
}

/// Case-insensitive substring, the stronger half of the match.
pub fn containsIgnoreCase(text: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > text.len) return false;
    var i: usize = 0;
    outer: while (i + needle.len <= text.len) : (i += 1) {
        for (needle, 0..) |ch, j| {
            if (std.ascii.toLower(text[i + j]) != std.ascii.toLower(ch)) continue :outer;
        }
        return true;
    }
    return false;
}

const testing = std.testing;

fn tap(cp: u21) event.Key {
    return .{ .codepoint = cp, .mods = .{} };
}

fn ctrlTap(cp: u21) event.Key {
    return .{ .codepoint = cp, .mods = .{ .ctrl = true } };
}

test "a single-key binding resolves immediately" {
    var km: Keymap = .{};
    try testing.expectEqual(Command.line_down, km.feed(tap('j'), .normal).command);
    try testing.expectEqual(@as(usize, 0), km.len);
}

test "a two-key sequence waits for its second key" {
    var km: Keymap = .{};
    try testing.expect(km.feed(tap(']'), .normal) == .pending);
    try testing.expectEqual(Command.next_hunk, km.feed(tap('h'), .normal).command);
}

test "an unknown second key drops the sequence without stranding the next" {
    var km: Keymap = .{};
    try testing.expect(km.feed(tap(']'), .normal) == .pending);
    try testing.expect(km.feed(tap('x'), .normal) == .none);
    // The dropped prefix must not swallow what follows.
    try testing.expectEqual(Command.line_down, km.feed(tap('j'), .normal).command);
}

test "a leader sequence resolves on its last key" {
    var km: Keymap = .{};
    try testing.expect(km.feed(tap(' '), .normal) == .pending);
    try testing.expect(km.feed(tap('n'), .normal) == .pending);
    try testing.expectEqual(Command.next_file, km.feed(tap('f'), .normal).command);

    try testing.expect(km.feed(tap(' '), .normal) == .pending);
    try testing.expect(km.feed(tap('p'), .normal) == .pending);
    try testing.expectEqual(Command.prev_file, km.feed(tap('f'), .normal).command);
}

test "the leader is never bound on its own" {
    // `feed` returns the first exact match it finds, so a bare-leader binding
    // would shadow every sequence behind it. Pending is what proves it is a
    // prefix and nothing else.
    var km: Keymap = .{};
    try testing.expect(km.feed(tap(' '), .normal) == .pending);
    km.reset();
    try testing.expect(km.feed(tap(' '), .visual) == .pending);
}

test "a key under the leader keeps its own meaning outside it" {
    // `n` is search_next; it must not be eaten by `<leader>nf`.
    var km: Keymap = .{};
    try testing.expectEqual(Command.search_next, km.feed(tap('n'), .normal).command);
    // And an unknown key after the leader drops without stranding the next.
    try testing.expect(km.feed(tap(' '), .normal) == .pending);
    try testing.expect(km.feed(tap('x'), .normal) == .none);
    try testing.expectEqual(Command.line_down, km.feed(tap('j'), .normal).command);
}

test "leader motions are live in visual mode like the bracket forms" {
    var km: Keymap = .{};
    try testing.expect(km.feed(tap(' '), .visual) == .pending);
    try testing.expect(km.feed(tap('n'), .visual) == .pending);
    try testing.expectEqual(Command.next_file, km.feed(tap('f'), .visual).command);
}

test "ctrl is part of the match, not ignored" {
    var km: Keymap = .{};
    try testing.expectEqual(Command.page_down, km.feed(ctrlTap('d'), .normal).command);
    // Plain 'd' is not bound, and must not fall through to Ctrl-d.
    try testing.expect(km.feed(tap('d'), .normal) == .none);
}

test "case is significant" {
    var km: Keymap = .{};
    try testing.expectEqual(Command.bottom, km.feed(tap('G'), .normal).command);
    try testing.expect(km.feed(tap('g'), .normal) == .pending);
    try testing.expectEqual(Command.top, km.feed(tap('g'), .normal).command);
    // And it separates `n` from `N`, which search relies on.
    try testing.expectEqual(Command.search_next, km.feed(tap('n'), .normal).command);
    try testing.expectEqual(Command.search_prev, km.feed(tap('N'), .normal).command);
}

test "every command is reachable from the default bindings" {
    // A command with no binding is dead code that looks alive.
    inline for (@typeInfo(Command).@"enum".fields) |f| {
        const want: Command = @enumFromInt(f.value);
        var found = false;
        for (default_bindings) |b| {
            if (b.command == want) found = true;
        }
        try testing.expect(found);
    }
}

test "every binding is live in at least one mode" {
    // An empty mode set is a binding that can never fire, and nothing else in
    // the file would ever say so.
    for (default_bindings) |b| {
        try testing.expect(b.modes.normal or b.modes.visual or b.modes.help);
    }
}

test "motions work in visual mode, so selecting is moving with an anchor" {
    var km: Keymap = .{};
    try testing.expectEqual(Command.line_down, km.feed(tap('j'), .visual).command);
    try testing.expect(km.feed(tap(']'), .visual) == .pending);
    try testing.expectEqual(Command.next_hunk, km.feed(tap('h'), .visual).command);
}

test "a visual-only binding is invisible in normal mode, prefix included" {
    var km: Keymap = .{};
    try testing.expectEqual(Command.visual_cancel, km.feed(tap(event.code.escape), .visual).command);
    try testing.expect(km.feed(tap(event.code.escape), .normal) == .none);
    // Having been dropped, it does not strand the next keystroke either.
    try testing.expectEqual(Command.line_down, km.feed(tap('j'), .normal).command);
}

test "quit is normal-only, so q mid-selection does not exit" {
    var km: Keymap = .{};
    try testing.expectEqual(Command.quit, km.feed(tap('q'), .normal).command);
    try testing.expect(km.feed(tap('q'), .visual) == .none);
}

test "the prompt modes reach no binding at all" {
    // While `/foo` is being typed, `j` is the letter j.
    var km: Keymap = .{};
    try testing.expect(km.feed(tap('j'), .command) == .none);
    try testing.expect(km.feed(tap('q'), .finder) == .none);
}

test "chords render the way a user would type them" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    try testing.expectEqualStrings("j", try writeChords(&.{c('j')}, arena));
    try testing.expectEqualStrings("gg", try writeChords(&.{ c('g'), c('g') }, arena));
    try testing.expectEqualStrings("<C-d>", try writeChords(&.{ctrl('d')}, arena));
    try testing.expectEqualStrings("<Esc>", try writeChords(&.{c(event.code.escape)}, arena));
    try testing.expectEqualStrings("<Tab>", try writeChords(&.{c(event.code.tab)}, arena));
    // Named, not encoded: these codepoints sit in a private-use area and draw
    // as nothing, so an unnamed arrow would be an invisible row in the popup.
    try testing.expectEqualStrings("<Down>", try writeChords(&.{c(event.code.down)}, arena));
    try testing.expectEqualStrings("<Left>", try writeChords(&.{c(event.code.left)}, arena));
    try testing.expectEqualStrings("<Space>nf", try writeChords(&.{ leader, c('n'), c('f') }, arena));
}

test "the overlay lists the mode it was opened from, aliases excluded" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const normal = try helpEntries(default_bindings, .normal, "", arena);
    var saw_quit = false;
    var saw_leader = false;
    for (normal) |e| {
        // The visual-only Escape is not a normal-mode key and must not be listed.
        try testing.expect(!std.mem.eql(u8, e.desc, "leave visual select"));
        if (std.mem.eql(u8, e.keys, "q")) saw_quit = true;
        if (std.mem.eql(u8, e.keys, "<Space>nf")) saw_leader = true;
    }
    try testing.expect(saw_quit);
    try testing.expect(saw_leader);
}

test "the filter narrows the overlay, run matches before scattered ones" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const all = try helpEntries(default_bindings, .normal, "", arena);
    const some = try helpEntries(default_bindings, .normal, "file", arena);
    try testing.expect(some.len < all.len);
    try testing.expect(some.len > 0);

    // "file" is a run in "next file" and only scattered letters in "first
    // line", so the runs come first or the list reads as noise.
    try testing.expect(std.mem.indexOf(u8, some[0].desc, "file") != null);

    // The filter reaches the keys too, so the leader bindings are findable by
    // the name a user would type for them.
    const leader_hits = try helpEntries(default_bindings, .normal, "space", arena);
    try testing.expectEqual(@as(usize, 2), leader_hits.len);

    const none = try helpEntries(default_bindings, .normal, "zzzz", arena);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "the popup navigates with its own bindings, live only inside it" {
    var km: Keymap = .{};
    // Shifted HJKL, the advertised set: vim's motions, and free where the Ctrl
    // pair is not.
    try testing.expectEqual(Command.help_down, km.feed(tap('J'), .help).command);
    try testing.expectEqual(Command.help_up, km.feed(tap('K'), .help).command);
    try testing.expectEqual(Command.help_right, km.feed(tap('L'), .help).command);
    try testing.expectEqual(Command.help_left, km.feed(tap('H'), .help).command);
    // Arrows, which no multiplexer takes, in both axes: the popup is a grid.
    try testing.expectEqual(Command.help_down, km.feed(tap(event.code.down), .help).command);
    try testing.expectEqual(Command.help_up, km.feed(tap(event.code.up), .help).command);
    try testing.expectEqual(Command.help_right, km.feed(tap(event.code.right), .help).command);
    try testing.expectEqual(Command.help_left, km.feed(tap(event.code.left), .help).command);
    // The finder aliases, for hands that learned them elsewhere.
    try testing.expectEqual(Command.help_down, km.feed(ctrlTap('n'), .help).command);
    try testing.expectEqual(Command.help_up, km.feed(ctrlTap('p'), .help).command);

    // `<C-j>`/`<C-k>` are bound nowhere: a multiplexer eats them before the
    // popup sees them, and a footer advertising a dead key is worse than one
    // key fewer.
    try testing.expect(km.feed(ctrlTap('j'), .help) == .none);
    try testing.expect(km.feed(ctrlTap('k'), .help) == .none);
    try testing.expect(km.feed(ctrlTap('j'), .normal) == .none);
    // A plain letter inside the popup is filter text, not a command.
    try testing.expect(km.feed(tap('j'), .help) == .none);
}

test "the popup's own keys collapse to one label in its footer" {
    // The footer joins runs of entries that share a description, which is what
    // turns four bindings into `H J K L move`. That only works while they are
    // adjacent in the table and their descriptions are identical.
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();

    const own = try helpEntries(default_bindings, .help, "", a.allocator());
    try testing.expectEqual(@as(usize, 4), own.len);
    for (own) |e| try testing.expectEqualStrings("move", e.desc);
    try testing.expectEqualStrings("H", own[0].keys);
    try testing.expectEqualStrings("L", own[3].keys);
}

test "the count and the list agree, whatever the filter" {
    // They are what clamps the selection and what draws it. If they can
    // disagree, the highlight can sit past the end of the visible list.
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    for ([_][]const u8{ "", "file", "next", "spc", "zzzz", "<C-" }) |q| {
        const list = try helpEntries(default_bindings, .normal, q, arena);
        try testing.expectEqual(list.len, helpCount(default_bindings, .normal, q));
    }
}

test "fuzzy matching is subsequence, case-insensitive" {
    try testing.expect(fuzzyMatch("next file", "nfl"));
    try testing.expect(fuzzyMatch("next file", "NEXT"));
    try testing.expect(fuzzyMatch("anything", ""));
    try testing.expect(!fuzzyMatch("next file", "xn"));

    try testing.expect(containsIgnoreCase("next file", "T FI"));
    try testing.expect(!containsIgnoreCase("next file", "nfl"));
    // A needle longer than the haystack must not read past the end.
    try testing.expect(!containsIgnoreCase("ab", "abc"));
}

test "every advertised key also explains itself in the overlay" {
    // A key in the hint strip with no description would appear in the status
    // line and then be missing from `?`, which is where a user goes to look
    // it up.
    for (default_bindings) |b| {
        if (b.hint != null) try testing.expect(b.desc != null);
    }
}

test "the overlay swallows the keys underneath it" {
    var km: Keymap = .{};
    try testing.expectEqual(Command.help, km.feed(tap('?'), .normal).command);
    // Inside the popup every key is filter text, so no binding is live at all
    // - `j` cannot scroll a body the user cannot see, and `q` cannot quit.
    try testing.expect(km.feed(tap('j'), .help) == .none);
    try testing.expect(km.feed(tap('q'), .help) == .none);
    try testing.expect(km.feed(tap('?'), .help) == .none);
}

test "hints come from the bindings and fit the width given" {
    var buf: [80]u8 = undefined;
    const h = hints(default_bindings, .normal, &buf);
    try testing.expect(std.mem.indexOf(u8, h, "j k move") != null);
    try testing.expect(std.mem.indexOf(u8, h, "q quit") != null);

    // A narrow strip truncates on a boundary rather than overrunning.
    var tiny: [10]u8 = undefined;
    const t = hints(default_bindings, .normal, &tiny);
    try testing.expect(t.len <= tiny.len);
    try testing.expectEqualStrings("j k move", t);
}

test "the hint strip advertises only what the current mode can do" {
    var buf: [160]u8 = undefined;
    const normal = hints(default_bindings, .normal, &buf);
    try testing.expect(std.mem.indexOf(u8, normal, "Esc cancel") == null);
    try testing.expect(std.mem.indexOf(u8, normal, "q quit") != null);

    var buf2: [160]u8 = undefined;
    const visual = hints(default_bindings, .visual, &buf2);
    try testing.expect(std.mem.indexOf(u8, visual, "Esc cancel") != null);
    // `q` does not quit from visual mode, so the strip must not claim it does.
    try testing.expect(std.mem.indexOf(u8, visual, "q quit") == null);
}
