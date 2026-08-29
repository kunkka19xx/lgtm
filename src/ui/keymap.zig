// SPDX-License-Identifier: Apache-2.0
//
// Every action is a named command and the keymap maps sequences to names, so
// dispatch contains no hardcoded keys (FEATURES.md 4.3). Remapping and presets
// are phase 5c; the indirection is here from the start because retrofitting it
// means touching every call site.

const std = @import("std");
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
    /// The bridge. `send_ref` inserts the reference into the agent's input
    /// box; the two copies go to the clipboard whatever the backend is.
    send_ref,
    copy_ref,
    copy_ref_lines,
    /// Ask presets: one keystroke, a whole question (FEATURES.md 2.1). Each
    /// is the reference plus a template, which is why they cost four enum
    /// values and no dispatch of their own.
    ask_why,
    ask_revert,
    ask_test,
    ask_explain,
    /// Hide the chrome and give the body the whole pane.
    toggle_zen,
    /// Open the `?` overlay, and close it again from inside.
    help,
    /// Open the file list.
    file_list,
    /// Move the selection in whichever overlay is open. Live only in the
    /// overlay modes, so these keys stay free for the review itself.
    list_down,
    list_up,
    /// Sideways: a whole column of the key grid, a whole page of the file
    /// list, which is the same movement in a list one column wide.
    list_left,
    list_right,
};

/// Which modes a binding is live in. Motions are live in both, which is what
/// makes visual select "normal mode plus an anchor" rather than a second
/// dispatch table that has to be kept in step with the first.
pub const Modes = packed struct(u8) {
    normal: bool = false,
    visual: bool = false,
    help: bool = false,
    /// The `F` overlay. Same rule as `help`: inside it a keystroke is filter
    /// text, so only the list's own navigation is bound.
    finder: bool = false,
    _pad: u4 = 0,

    pub const both: Modes = .{ .normal = true, .visual = true };
    pub const normal_only: Modes = .{ .normal = true };
    pub const visual_only: Modes = .{ .visual = true };
    /// Inside the `?` popup. Only navigation lives here: every other key is
    /// filter text, so binding anything else would take a letter away from
    /// the search.
    pub const help_only: Modes = .{ .help = true };
    /// Inside either overlay. The two lists move the same way on purpose -
    /// two sets of navigation keys would be two things to learn.
    pub const lists: Modes = .{ .help = true, .finder = true };

    pub fn has(self: Modes, mode: event.Mode) bool {
        return switch (mode) {
            .normal => self.normal,
            .visual => self.visual,
            .help => self.help,
            .finder => self.finder,
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
    /// The word the status-line strip puts after the keys - "move", "hunk",
    /// "quit". A label rather than the finished text, so the strip renders the
    /// keys from the chords and cannot advertise a key the user has remapped
    /// away: `next_file = "]w"` in a config file turns `]f [f file` into
    /// `]w [f file` with nothing to keep in step. Bindings sharing a label
    /// share one entry, which is what collapses `]f` and `[f` into it.
    ///
    /// Null keeps a binding working but unadvertised, which is how aliases
    /// stay out of an already tight row.
    hint: ?[]const u8 = null,
    /// What the strip prints instead of this binding's chords. For an action
    /// that is *typed* rather than chorded: `:` opens the command line and the
    /// user types `q`, so rendering the chord would advertise `:` for quit and
    /// the two-key answer would be nowhere. Null renders the chords, which is
    /// what every ordinary binding wants.
    hint_keys: ?[]const u8 = null,
    /// One line in the `?` overlay. Null for aliases, for the same reason
    /// `hint` is: `[h` does not need its own row next to `]h`, and three ways
    /// to close the overlay do not need three rows saying "close".
    desc: ?[]const u8 = null,
};

/// A plain chord. Public because `keytext.zig` builds chords when it parses a
/// sequence out of a config file, and because the tests either side of that
/// split both want the shorthand.
pub fn chord(cp: u21) Chord {
    return .{ .cp = cp };
}

/// The shorthand the table below is written in.
const c = chord;

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
    .{ .chords = &.{c('j')}, .command = .line_down, .desc = "down a line" },
    .{ .chords = &.{c('k')}, .command = .line_up, .desc = "up a line" },
    .{ .chords = &.{ctrl('d')}, .command = .page_down, .desc = "down half a page" },
    .{ .chords = &.{ctrl('u')}, .command = .page_up, .desc = "up half a page" },
    .{ .chords = &.{ c('g'), c('g') }, .command = .top, .desc = "first line" },
    .{ .chords = &.{c('G')}, .command = .bottom, .desc = "last line" },
    .{ .chords = &.{ c(']'), c('h') }, .command = .next_hunk, .desc = "next hunk (wraps)" },
    .{ .chords = &.{ c('['), c('h') }, .command = .prev_hunk, .desc = "previous hunk (wraps)" },
    .{ .chords = &.{ leader, c('n'), c('h') }, .command = .next_hunk, .desc = "next hunk" },
    .{ .chords = &.{ leader, c('p'), c('h') }, .command = .prev_hunk, .desc = "previous hunk" },
    .{ .chords = &.{ c(']'), c('f') }, .command = .next_file, .desc = "next file (wraps)" },
    .{ .chords = &.{ c('['), c('f') }, .command = .prev_file, .desc = "previous file (wraps)" },
    .{ .chords = &.{ leader, c('n'), c('f') }, .command = .next_file, .desc = "next file" },
    .{ .chords = &.{ leader, c('p'), c('f') }, .command = .prev_file, .desc = "previous file" },
    .{ .chords = &.{ c('z'), c('z') }, .command = .center, .desc = "centre cursor line" },
    .{ .chords = &.{c(event.code.enter)}, .command = .send_ref, .desc = "send the reference to the agent" },
    .{ .chords = &.{c('y')}, .command = .copy_ref, .desc = "copy the reference" },
    .{ .chords = &.{c('Y')}, .command = .copy_ref_lines, .desc = "copy the reference and the lines" },
    .{ .chords = &.{c('a')}, .command = .ask_why, .desc = "ask: why this approach?" },
    .{ .chords = &.{c('!')}, .command = .ask_revert, .desc = "ask: revert this, keep the rest" },
    .{ .chords = &.{c('t')}, .command = .ask_test, .desc = "ask: add a test covering this" },
    .{ .chords = &.{c('x')}, .command = .ask_explain, .desc = "ask: explain what this does" },
    .{ .chords = &.{c('/')}, .command = .search_forward, .desc = "search the review" },
    .{ .chords = &.{c('n')}, .command = .search_next, .desc = "next match" },
    .{ .chords = &.{c('N')}, .command = .search_prev, .desc = "previous match" },
    .{ .chords = &.{c('V')}, .command = .visual_toggle, .desc = "visual line select" },
    .{ .chords = &.{c(event.code.escape)}, .command = .visual_cancel, .modes = Modes.visual_only, .hint = "cancel", .desc = "leave visual select" },
    .{ .chords = &.{c('e')}, .command = .open_editor, .desc = "open line in $EDITOR" },
    .{ .chords = &.{c(event.code.tab)}, .command = .toggle_zen, .desc = "zen: hide the chrome" },
    .{ .chords = &.{c(':')}, .command = .command_line, .hint = "quit", .hint_keys = ":q", .desc = "command line (:q)" },
    .{ .chords = &.{ctrl('l')}, .command = .refresh, .desc = "re-run the diff" },
    .{ .chords = &.{c('F')}, .command = .file_list, .desc = "list the changed files" },
    // `?` opens the overlay. Closing it is `prompt.zig`'s Escape, because
    // inside the overlay the keys are a filter query rather than commands.
    .{ .chords = &.{c('?')}, .command = .help, .hint = "help", .desc = "this help" },
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
    .{ .chords = &.{c('H')}, .command = .list_left, .modes = Modes.lists, .desc = "move" },
    .{ .chords = &.{c('J')}, .command = .list_down, .modes = Modes.lists, .desc = "move" },
    .{ .chords = &.{c('K')}, .command = .list_up, .modes = Modes.lists, .desc = "move" },
    .{ .chords = &.{c('L')}, .command = .list_right, .modes = Modes.lists, .desc = "move" },
    // Unadvertised aliases: arrows for hands that reach for them, `<C-n>`/
    // `<C-p>` for hands that learned other finders.
    .{ .chords = &.{c(event.code.down)}, .command = .list_down, .modes = Modes.lists },
    .{ .chords = &.{c(event.code.up)}, .command = .list_up, .modes = Modes.lists },
    .{ .chords = &.{c(event.code.right)}, .command = .list_right, .modes = Modes.lists },
    .{ .chords = &.{c(event.code.left)}, .command = .list_left, .modes = Modes.lists },
    .{ .chords = &.{ctrl('n')}, .command = .list_down, .modes = Modes.lists },
    .{ .chords = &.{ctrl('p')}, .command = .list_up, .modes = Modes.lists },
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

/// True when `short` is the opening of `long`. The matcher resolves an exact
/// match as soon as it finds one, so a binding that is a prefix of another
/// fires first and the longer sequence can never be typed - which is the
/// general form of "never bind the leader on its own" (FEATURES.md 4.3).
pub fn isPrefix(short: []const Chord, long: []const Chord) bool {
    if (short.len == 0 or short.len >= long.len) return false;
    for (short, long[0..short.len]) |a, b| {
        if (a.cp != b.cp or a.ctrl != b.ctrl) return false;
    }
    return true;
}

/// Two ways a binding can be typed and never fire.
pub const Conflict = struct {
    first: Binding,
    second: Binding,
    kind: enum {
        /// `first` is the opening of `second`, so it resolves first and
        /// `second` can never be completed.
        prefix,
        /// The same sequence, twice, for different commands. `feed` returns
        /// the first, so the second is dead.
        duplicate,
    },
};

/// The first binding rendered unreachable by another that shares a live mode,
/// or null when every sequence can actually be typed. `config.zig` runs this
/// over the table a `[keys]` override *would* produce and refuses the override
/// rather than accepting a keymap with a silently dead binding in it.
pub fn shadowed(bindings: []const Binding) ?Conflict {
    for (bindings, 0..) |a, i| {
        for (bindings[i + 1 ..]) |b| {
            if (!modesOverlap(a.modes, b.modes)) continue;
            if (isPrefix(a.chords, b.chords)) return .{ .first = a, .second = b, .kind = .prefix };
            if (isPrefix(b.chords, a.chords)) return .{ .first = b, .second = a, .kind = .prefix };
            if (a.command != b.command and sameChords(a.chords, b.chords)) {
                return .{ .first = a, .second = b, .kind = .duplicate };
            }
        }
    }
    return null;
}

fn sameChords(a: []const Chord, b: []const Chord) bool {
    if (a.len != b.len or a.len == 0) return false;
    for (a, b) |x, y| {
        if (x.cp != y.cp or x.ctrl != y.ctrl) return false;
    }
    return true;
}

fn modesOverlap(a: Modes, b: Modes) bool {
    return (a.normal and b.normal) or (a.visual and b.visual) or (a.help and b.help);
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
        // `quit` is the one exception, and by design: it is typed as `:q`
        // rather than chorded, so `command_line` is the binding that reaches
        // it and `app.submitCommand` is what dispatches it.
        if (want == .quit) continue;
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

test "q does not quit; the command line does" {
    // Quitting is typed, not chorded. A stray `q` over a diff now does
    // nothing at all, which is the point: it sits one key from `j`, and the
    // cost of hitting it was losing the session.
    var km: Keymap = .{};
    try testing.expect(km.feed(tap('q'), .normal) == .none);
    try testing.expect(km.feed(tap('q'), .visual) == .none);
    try testing.expectEqual(Command.command_line, km.feed(tap(':'), .normal).command);
}

test "the prompt modes reach no binding at all" {
    // While `/foo` is being typed, `j` is the letter j.
    var km: Keymap = .{};
    try testing.expect(km.feed(tap('j'), .command) == .none);
    try testing.expect(km.feed(tap('q'), .finder) == .none);
}

test "the popup navigates with its own bindings, live only inside it" {
    var km: Keymap = .{};
    // Shifted HJKL, the advertised set: vim's motions, and free where the Ctrl
    // pair is not.
    try testing.expectEqual(Command.list_down, km.feed(tap('J'), .help).command);
    try testing.expectEqual(Command.list_up, km.feed(tap('K'), .help).command);
    try testing.expectEqual(Command.list_right, km.feed(tap('L'), .help).command);
    try testing.expectEqual(Command.list_left, km.feed(tap('H'), .help).command);
    // Arrows, which no multiplexer takes, in both axes: the popup is a grid.
    try testing.expectEqual(Command.list_down, km.feed(tap(event.code.down), .help).command);
    try testing.expectEqual(Command.list_up, km.feed(tap(event.code.up), .help).command);
    try testing.expectEqual(Command.list_right, km.feed(tap(event.code.right), .help).command);
    try testing.expectEqual(Command.list_left, km.feed(tap(event.code.left), .help).command);
    // The finder aliases, for hands that learned them elsewhere.
    try testing.expectEqual(Command.list_down, km.feed(ctrlTap('n'), .help).command);
    try testing.expectEqual(Command.list_up, km.feed(ctrlTap('p'), .help).command);

    // `<C-j>`/`<C-k>` are bound nowhere: a multiplexer eats them before the
    // popup sees them, and a footer advertising a dead key is worse than one
    // key fewer.
    try testing.expect(km.feed(ctrlTap('j'), .help) == .none);
    try testing.expect(km.feed(ctrlTap('k'), .help) == .none);
    try testing.expect(km.feed(ctrlTap('j'), .normal) == .none);
    // A plain letter inside the popup is filter text, not a command.
    try testing.expect(km.feed(tap('j'), .help) == .none);
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

test "no default binding shadows another" {
    // The general form of "never bind the leader on its own": `feed` returns
    // on the first exact match, so a sequence that is a prefix of another
    // fires first and the longer one can never be reached. Asserting it over
    // the whole table catches the next `<Space>` as well as this one.
    try testing.expect(shadowed(default_bindings) == null);

    // And the check itself has teeth: a bare leader shadows every sequence
    // behind it.
    const bad: []const Binding = &.{
        .{ .chords = &.{leader}, .command = .quit },
        .{ .chords = &.{ leader, c('n'), c('f') }, .command = .next_file },
    };
    const hit = shadowed(bad).?;
    try testing.expectEqual(Command.quit, hit.first.command);
    try testing.expectEqual(Command.next_file, hit.second.command);

    // The same sequence twice is the other way a binding dies quietly: the
    // matcher returns the first one it finds, so the second never fires.
    const dup: []const Binding = &.{
        .{ .chords = &.{c('q')}, .command = .quit },
        .{ .chords = &.{c('q')}, .command = .refresh },
    };
    try testing.expect(shadowed(dup).?.kind == .duplicate);

    // Modes that never overlap cannot shadow each other: `H` in the popup and
    // a hypothetical `Hx` in the review are different keymaps.
    const ok: []const Binding = &.{
        .{ .chords = &.{c('H')}, .command = .list_left, .modes = Modes.lists },
        .{ .chords = &.{ c('H'), c('x') }, .command = .top, .modes = Modes.normal_only },
    };
    try testing.expect(shadowed(ok) == null);
}
