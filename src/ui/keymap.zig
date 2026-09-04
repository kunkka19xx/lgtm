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
    /// Within the line. The cursor is a `(row, column)` pair, so these are the
    /// half of vim's motions that move the column and leave the row alone.
    char_left,
    char_right,
    word_next,
    word_prev,
    word_end,
    /// The same three over WORDs - vim's capitals, where only whitespace is a
    /// boundary, so a path or a whole call is one step.
    big_word_next,
    big_word_prev,
    big_word_end,
    line_start,
    line_end,
    first_non_blank,
    /// `f` `t` `F` `T`: each waits for the character to search for, so the key
    /// after one of these is data rather than a command (`ui/app.zig`).
    find_char,
    till_char,
    find_char_back,
    till_char_back,
    /// `;` and `,`, which repeat the last of those forwards and backwards.
    find_repeat,
    find_reverse,
    next_hunk,
    prev_hunk,
    next_file,
    prev_file,
    center,
    refresh,
    /// Enter and leave visual select. One command per kind rather than one
    /// each way, because `V` in visual mode is what leaves it - and pressing
    /// the other kind switches rather than doing nothing.
    visual_toggle,
    visual_char_toggle,
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
    clear_search,
    compose_ask,
    file_browse,
    comment_add,
    comment_list,
    comment_send,
    comment_send_one,
    comment_send_all,
    comment_drop,
    comment_view,
    comment_delete,
    next_comment,
    prev_comment,
    submit_review,
    toggle_ignored,
    /// "Since I last looked" (`core/checkpoint.zig`). `mark_here` records the
    /// working tree as the reader has now read it; the two steps walk the
    /// changes that arrived after it.
    mark_here,
    clear_mark,
    /// The timeline (SNAPSHOTS.md 5.3). Stepping is the primary way in: the
    /// common question is "what did the last turn do", and it should cost one
    /// key rather than a list that has to be opened to move one step.
    next_turn,
    prev_turn,
    /// The turn list. Stepping is the primary way in (§5.3); this is for when
    /// the target is further away than stepping.
    turn_list,
    next_fresh,
    prev_fresh,
    /// A file over `large_file_lines` renders as a summary row; these open it
    /// and fold it again. `zo` and `zc` because a deferred file is a fold in
    /// everything but name, and vim already decided what those keys mean.
    expand_file,
    collapse_file,
    copy_text,
    copy_text_lines,
    copy_ref,
    copy_ref_lines,
    /// Ask presets: one keystroke, a whole question (FEATURES.md 2.1). Each
    /// is the reference plus a template, which is why they cost four enum
    /// values and no dispatch of their own.
    /// Hide the chrome and give the body the whole pane.
    toggle_zen,
    /// Soft wrap on and off. A long line either continues on the next screen
    /// row or is cut at the edge of the pane; which one a reader wants depends
    /// on whether they are reading prose or the shape of the code.
    toggle_wrap,
    /// Open the `?` overlay, and close it again from inside.
    help,
    /// Open the file list.
    file_list,
    /// The compose box's own keys. Everything it does that is not typing or
    /// a vim motion, so a box is remappable like the rest of the tool - the
    /// motions are vim's and stay vim's, the way `hjkl` do outside the box.
    ///
    /// Bound with single chords only. A box cannot hold a prefix waiting for
    /// the key after it: the next key is usually a letter someone is typing,
    /// and swallowing it to see whether a sequence completes would make
    /// typing depend on what is bound.
    compose_submit,
    compose_cancel,
    compose_send_now,
    compose_presets,
    compose_mention,
    compose_newline,
    /// Move the selection in whichever overlay is open. Live only in the
    /// overlay modes, so these keys stay free for the review itself.
    list_down,
    list_up,
    /// Sideways: a whole column of the key grid, a whole page of the file
    /// list, which is the same movement in a list one column wide.
    list_left,
    list_right,

    /// Whether this command *jumps* - takes the reader somewhere they asked to
    /// go - as against stepping, where the view moves only because the cursor
    /// walked off the edge of it.
    ///
    /// Only a jump is worth animating. A step has to be instant: with soft
    /// wrap a single `j` crosses two or three screen rows, so animating it
    /// would start a fresh animation on every keystroke, and a held `j` would
    /// spend its life cancelling the last one - which reads as stutter, and
    /// costs a frame of input latency per key on top.
    pub fn jumps(self: Command) bool {
        return switch (self) {
            .page_down,
            .page_up,
            .top,
            .bottom,
            .center,
            .next_hunk,
            .prev_hunk,
            .search_next,
            .search_prev,
            => true,
            else => false,
        };
    }
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
    /// Inside the compose box. Only its feature keys live here; every other
    /// key is text or a motion over text.
    compose: bool = false,
    _pad: u3 = 0,

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
    /// Inside the file list only. Sideways is the one key whose meaning
    /// differs between the two overlays - a tab in `?`, a page of the grid
    /// here - so it is bound per overlay and each one says its own word.
    pub const finder_only: Modes = .{ .finder = true };
    /// Inside the compose box, and nowhere else: these keys have to stay free
    /// for the review, and the review's keys have to stay typeable in a box.
    pub const compose_only: Modes = .{ .compose = true };

    pub fn has(self: Modes, mode: event.Mode) bool {
        return switch (mode) {
            .normal => self.normal,
            .visual => self.visual,
            .help => self.help,
            .finder => self.finder,
            .note_input => self.compose,
            // The prompt modes never reach the keymap: `prompt.zig` takes the
            // keys, because they are text rather than actions.
            else => false,
        };
    }
};

pub const Chord = struct {
    cp: u21,
    ctrl: bool = false,
    /// Only ever set for a named key. `io/input.zig` strips shift from
    /// anything that types a character, so `V` is the codepoint `V` and not a
    /// shifted `v`, and this can be compared exactly without a binding
    /// matching on one terminal and missing on another.
    shift: bool = false,

    pub fn matches(self: Chord, key: event.Key) bool {
        return self.cp == key.codepoint and
            self.ctrl == key.mods.ctrl and
            self.shift == key.mods.shift;
    }
};

/// Which tab of the `?` overlay a binding is listed under.
///
/// Five, and no more, for two reasons. The strip is drawn into the top border
/// of a box that has to fit an 80-column pane, and a reader hunting for a key
/// already knows which of these five things they are trying to do - so a
/// sixth tab would cost a column and answer a question nobody asks. The
/// filter cuts across all of them, because *finding* a key must not require
/// knowing which tab it was filed under.
pub const Group = enum {
    move,
    jump,
    send,
    comment,
    find,
    view,

    pub const count = @typeInfo(Group).@"enum".fields.len;

    /// The tab label. The tag itself: a second spelling would be one more
    /// thing to keep in step for no gain.
    pub fn label(self: Group) []const u8 {
        return @tagName(self);
    }

    /// The next tab along, wrapping. `H`/`L` are a cycle, the way `]h`/`[h`
    /// already are.
    pub fn step(self: Group, delta: i32) Group {
        const n: i64 = @intCast(count);
        return @enumFromInt(@mod(@as(i64, @intFromEnum(self)) + delta, n));
    }
};

pub const Binding = struct {
    chords: []const Chord,
    command: Command,
    modes: Modes = Modes.both,
    /// Which `?` tab it appears under. The overlay's own navigation keys are
    /// drawn in the footer rather than the list, so their group is never read
    /// and the default costs nothing.
    group: Group = .view,
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

fn shift(cp: u21) Chord {
    return .{ .cp = cp, .shift = true };
}

/// The leader. Named once so rebinding it is one edit rather than a sweep over
/// every sequence that starts with it. Space is unbound on its own and must
/// stay that way: `feed` resolves an exact match as soon as it finds one, so a
/// bare-Space binding would shadow every `<leader>x` sequence behind it.
pub const leader: Chord = c(' ');

/// The v0.1 set. Only bindings that do something are listed: a hint strip that
/// advertises keys the build does not implement is worse than a shorter one.
pub const default_bindings: []const Binding = &.{
    .{ .chords = &.{c('j')}, .command = .line_down, .desc = "down and up a line", .group = .move },
    .{ .chords = &.{c('k')}, .command = .line_up, .desc = "down and up a line", .group = .move },
    .{ .chords = &.{ctrl('d')}, .command = .page_down, .desc = "half a page, down and up", .group = .move },
    .{ .chords = &.{ctrl('u')}, .command = .page_up, .desc = "half a page, down and up", .group = .move },
    .{ .chords = &.{ c('g'), c('g') }, .command = .top, .desc = "first and last line", .group = .move },
    .{ .chords = &.{c('G')}, .command = .bottom, .desc = "first and last line", .group = .move },
    .{ .chords = &.{c('h')}, .command = .char_left, .desc = "left and right a character", .group = .move },
    .{ .chords = &.{c('l')}, .command = .char_right, .desc = "left and right a character", .group = .move },
    .{ .chords = &.{c('w')}, .command = .word_next, .desc = "next, previous, end of word", .group = .move },
    .{ .chords = &.{c('b')}, .command = .word_prev, .desc = "next, previous, end of word", .group = .move },
    .{ .chords = &.{c('e')}, .command = .word_end, .desc = "next, previous, end of word", .group = .move },
    .{ .chords = &.{c('W')}, .command = .big_word_next, .desc = "the same for WORDs - only blanks separate", .group = .move },
    .{ .chords = &.{c('B')}, .command = .big_word_prev, .desc = "the same for WORDs - only blanks separate", .group = .move },
    .{ .chords = &.{c('E')}, .command = .big_word_end, .desc = "the same for WORDs - only blanks separate", .group = .move },
    .{ .chords = &.{c('0')}, .command = .line_start, .desc = "first, last, first non-blank column", .group = .move },
    .{ .chords = &.{c('$')}, .command = .line_end, .desc = "first, last, first non-blank column", .group = .move },
    .{ .chords = &.{c('^')}, .command = .first_non_blank, .desc = "first, last, first non-blank column", .group = .move },
    .{ .chords = &.{c('f')}, .command = .find_char, .desc = "to or before <char>, forwards and back", .group = .move },
    .{ .chords = &.{c('t')}, .command = .till_char, .desc = "to or before <char>, forwards and back", .group = .move },
    .{ .chords = &.{c('F')}, .command = .find_char_back, .desc = "to or before <char>, forwards and back", .group = .move },
    .{ .chords = &.{c('T')}, .command = .till_char_back, .desc = "to or before <char>, forwards and back", .group = .move },
    .{ .chords = &.{c(';')}, .command = .find_repeat, .desc = "repeat the last f/t/F/T, either way", .group = .move },
    .{ .chords = &.{c(',')}, .command = .find_reverse, .desc = "repeat the last f/t/F/T, either way", .group = .move },
    .{ .chords = &.{ c(']'), c('h') }, .command = .next_hunk, .desc = "next hunk (wraps)", .group = .jump },
    .{ .chords = &.{ c('['), c('h') }, .command = .prev_hunk, .desc = "previous hunk (wraps)", .group = .jump },
    .{ .chords = &.{ leader, c('n'), c('h') }, .command = .next_hunk, .group = .jump },
    .{ .chords = &.{ leader, c('p'), c('h') }, .command = .prev_hunk, .group = .jump },

    .{ .chords = &.{ c(']'), c('f') }, .command = .next_file, .desc = "next file (wraps)", .group = .jump },
    .{ .chords = &.{ c('['), c('f') }, .command = .prev_file, .desc = "previous file (wraps)", .group = .jump },
    .{ .chords = &.{ leader, c('n'), c('f') }, .command = .next_file, .group = .jump },
    .{ .chords = &.{ leader, c('p'), c('f') }, .command = .prev_file, .group = .jump },

    .{ .chords = &.{ c('z'), c('z') }, .command = .center, .desc = "centre cursor line", .group = .move },
    .{ .chords = &.{c(event.code.enter)}, .command = .send_ref, .desc = "compose a message to the agent", .group = .send },
    .{ .chords = &.{c('y')}, .command = .copy_text, .desc = "yank the selection, or whole lines", .group = .send },
    .{ .chords = &.{c('Y')}, .command = .copy_text_lines, .desc = "yank the selection, or whole lines", .group = .send },
    .{ .chords = &.{ leader, c('y') }, .command = .copy_ref, .desc = "copy the reference", .group = .send },
    .{ .chords = &.{ leader, c('Y') }, .command = .copy_ref_lines, .desc = "copy the reference and the lines", .group = .send },
    // `<Space>a` is the ask shortcut: the box *and* the question list, in one
    // keystroke. It used to be four keys carrying four fixed questions; the
    // questions moved into `[presets]`, where they are the user's own and
    // there can be any number of them, so one key that opens the list beats
    // four that each hard-code a row of it. Nothing is inserted until a
    // question is chosen - summoning the box never types into it.
    .{ .chords = &.{ leader, c('a') }, .command = .compose_ask, .desc = "compose, with the question list open", .group = .send },
    // Notes are the second half of the loop: collect while reading, submit
    // once. `c` for comment, the letter every review tool uses; `]c`/`[c`
    // walk them the way `]h` walks hunks.
    // Behind the leader, every one of them. `c` is vim's change operator and
    // `C` is change-to-end-of-line - the two most-used keys after `d` - and
    // `dc` is `d` waiting for a motion. Editing is designed for rather than
    // out (ARCHITECTURE.md 11), so taking them was borrowing against a debt
    // that comes due the day insert mode lands. This is the same argument
    // that moved the ask presets off `a`, `x` and `!`.
    .{ .chords = &.{ leader, c('c') }, .command = .comment_add, .desc = "write a comment on this line", .group = .comment },
    .{ .chords = &.{ leader, c('d'), c('c') }, .command = .comment_delete, .desc = "delete the comment here", .group = .comment },
    .{ .chords = &.{ c(']'), c('c') }, .command = .next_comment, .desc = "next comment (wraps)", .group = .comment },
    .{ .chords = &.{ c('['), c('c') }, .command = .prev_comment, .desc = "previous comment (wraps)", .group = .comment },
    .{ .chords = &.{ leader, c('n'), c('c') }, .command = .next_comment, .group = .comment },
    .{ .chords = &.{ leader, c('p'), c('c') }, .command = .prev_comment, .group = .comment },
    .{ .chords = &.{ leader, c('v'), c('c') }, .command = .comment_view, .desc = "open the nearest comment to read or edit", .group = .comment },
    .{ .chords = &.{ leader, c('l'), c('c') }, .command = .comment_list, .desc = "list every comment in the review", .group = .comment },
    .{ .chords = &.{ leader, c('s'), c('c') }, .command = .comment_send, .desc = "send this comment to the agent on its own", .group = .comment },
    .{ .chords = &.{ctrl('s')}, .command = .submit_review, .desc = "write the review file and tell the agent", .group = .comment },
    .{ .chords = &.{c('/')}, .command = .search_forward, .desc = "search the review", .group = .find },
    .{ .chords = &.{c('n')}, .command = .search_next, .desc = "next and previous match", .group = .find },
    .{ .chords = &.{c('N')}, .command = .search_prev, .desc = "next and previous match", .group = .find },
    .{ .chords = &.{c(event.code.escape)}, .command = .clear_search, .modes = Modes.normal_only, .desc = "clear the search highlight (:noh)", .group = .find },
    .{ .chords = &.{c('v')}, .command = .visual_char_toggle, .desc = "visual select, characters or lines", .group = .send },
    .{ .chords = &.{c('V')}, .command = .visual_toggle, .desc = "visual select, characters or lines", .group = .send },
    .{ .chords = &.{c(event.code.escape)}, .command = .visual_cancel, .modes = Modes.visual_only, .hint = "cancel", .desc = "leave visual select", .group = .send },
    .{ .chords = &.{ leader, c('e') }, .command = .open_editor, .desc = "open line in $EDITOR", .group = .view },
    .{ .chords = &.{c(event.code.tab)}, .command = .toggle_zen, .desc = "zen: hide the chrome", .group = .view },
    .{ .chords = &.{ c('z'), c('w') }, .command = .toggle_wrap, .hint = null, .desc = "soft wrap long lines", .group = .view },
    .{ .chords = &.{c('m')}, .command = .mark_here, .desc = "mark: everything after this is new", .hint = null, .group = .jump },
    .{ .chords = &.{ c(']'), c('t') }, .command = .next_turn, .desc = "next turn, ending at the working tree", .hint = null, .group = .jump },
    .{ .chords = &.{ c('['), c('t') }, .command = .prev_turn, .desc = "previous turn - what the agent had written by then", .hint = null, .group = .jump },
    .{ .chords = &.{ leader, c('l'), c('t') }, .command = .turn_list, .desc = "list the turns the agent has written", .group = .jump },
    .{ .chords = &.{ leader, c('n'), c('t') }, .command = .next_turn, .group = .jump },
    .{ .chords = &.{ leader, c('p'), c('t') }, .command = .prev_turn, .group = .jump },
    .{ .chords = &.{c('M')}, .command = .clear_mark, .desc = "drop the mark; the review reads as one whole change again", .hint = null, .group = .jump },
    .{ .chords = &.{ c(']'), c('m') }, .command = .next_fresh, .desc = "next change since the mark (wraps)", .hint = null, .group = .jump },
    .{ .chords = &.{ c('['), c('m') }, .command = .prev_fresh, .desc = "previous change since the mark (wraps)", .hint = null, .group = .jump },
    .{ .chords = &.{ leader, c('n'), c('m') }, .command = .next_fresh, .group = .jump },
    .{ .chords = &.{ leader, c('p'), c('m') }, .command = .prev_fresh, .group = .jump },
    .{ .chords = &.{ c('z'), c('i') }, .command = .toggle_ignored, .desc = "show the files [review] ignore hides", .group = .view },
    .{ .chords = &.{ c('z'), c('o') }, .command = .expand_file, .desc = "open a file too large to render inline, or fold it again", .group = .view },
    .{ .chords = &.{ c('z'), c('c') }, .command = .collapse_file, .desc = "open a file too large to render inline, or fold it again", .hint = null, .group = .view },
    .{ .chords = &.{c(':')}, .command = .command_line, .hint = "quit", .hint_keys = ":q", .desc = "command line (:q)", .group = .view },
    // `<C-r>` and not `<C-l>`: vim-tmux-navigator binds C-h/C-j/C-k/C-l at the
    // tmux *root* table and forwards them only to processes matching its vim
    // pattern, which `lgtm` does not match - so under a very common config
    // `<C-l>` never arrived and reloading was unreachable. `<C-r>` is the
    // redo/reload key everywhere else and nothing takes it.
    .{ .chords = &.{ctrl('r')}, .command = .refresh, .desc = "reload the diff", .group = .view },
    .{ .chords = &.{ leader, c('f') }, .command = .file_list, .desc = "list the changed files", .group = .find },
    .{ .chords = &.{ leader, c('F') }, .command = .file_browse, .desc = "list every file in the project", .group = .find },
    // `?` opens the overlay. Closing it is `prompt.zig`'s Escape, because
    // inside the overlay the keys are a filter query rather than commands.
    .{ .chords = &.{c('?')}, .command = .help, .hint = "help", .desc = "this help", .group = .view },
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
    // A shared description collapses keys into one footer label, which is what
    // turns four rows of chrome into `J K move  H L tab`. Sideways is listed
    // after, and separately, because it no longer does the same thing as up
    // and down: in the `?` overlay it changes tab, and in the file list it is
    // still a page of the grid. One word for both - the file list has one tab
    // and so never moves, which is the honest way to say "nothing here".
    .{ .chords = &.{c('J')}, .command = .list_down, .modes = Modes.lists, .desc = "move" },
    .{ .chords = &.{c('K')}, .command = .list_up, .modes = Modes.lists, .desc = "move" },
    .{ .chords = &.{c('H')}, .command = .list_left, .modes = Modes.help_only, .desc = "tab" },
    .{ .chords = &.{c('L')}, .command = .list_right, .modes = Modes.help_only, .desc = "tab" },
    .{ .chords = &.{c('H')}, .command = .list_left, .modes = Modes.finder_only, .desc = "page" },
    .{ .chords = &.{c('L')}, .command = .list_right, .modes = Modes.finder_only, .desc = "page" },
    // The comment list's own actions. Chords, because every printable key in
    // that overlay is a filter character - and commands rather than keys
    // wired into dispatch, so `[keys]` can move them.
    //
    // Not `<C-a>`, however well it reads as "all": it is the most common tmux
    // prefix after `C-b` and never reaches an application that runs under one.
    // A default nobody can press is not a default.
    .{ .chords = &.{ctrl('s')}, .command = .comment_send_one, .modes = Modes.finder_only },
    .{ .chords = &.{ctrl('x')}, .command = .comment_send_all, .modes = Modes.finder_only },
    .{ .chords = &.{ctrl('d')}, .command = .comment_drop, .modes = Modes.finder_only },
    // Unadvertised aliases: arrows for hands that reach for them, `<C-n>`/
    // `<C-p>` for hands that learned other finders.
    .{ .chords = &.{c(event.code.down)}, .command = .list_down, .modes = Modes.lists },
    .{ .chords = &.{c(event.code.up)}, .command = .list_up, .modes = Modes.lists },
    .{ .chords = &.{c(event.code.right)}, .command = .list_right, .modes = Modes.lists },
    .{ .chords = &.{c(event.code.left)}, .command = .list_left, .modes = Modes.lists },
    .{ .chords = &.{ctrl('n')}, .command = .list_down, .modes = Modes.lists },
    .{ .chords = &.{ctrl('p')}, .command = .list_up, .modes = Modes.lists },
    // Tab cycles either list, the way it cycles a completion menu everywhere
    // else. It is `toggle_zen` in the review, which is a different mode, so
    // the two never compete. Shift-Tab arrives as Tab with the shift bit -
    // the only key in the table where shift is part of the chord rather than
    // part of the character.
    // The compose box. Single chords, and `<Esc>` before the ways out that
    // commit, so a footer with room for three still shows the way back.
    .{ .chords = &.{c(event.code.enter)}, .command = .compose_submit, .modes = Modes.compose_only, .desc = "send what is in the box" },
    .{ .chords = &.{c(event.code.escape)}, .command = .compose_cancel, .modes = Modes.compose_only, .desc = "leave insert, then leave the box" },
    .{ .chords = &.{ctrl('s')}, .command = .compose_send_now, .modes = Modes.compose_only, .desc = "save a comment and send it now" },
    .{ .chords = &.{ctrl('i')}, .command = .compose_presets, .modes = Modes.compose_only, .desc = "insert a [presets] question at the caret" },
    // Terminals send 0x09 for both Tab and Ctrl-i, so this is the same
    // keystroke arriving under its other name rather than a second binding.
    .{ .chords = &.{c(event.code.tab)}, .command = .compose_presets, .modes = Modes.compose_only },
    .{ .chords = &.{c('@')}, .command = .compose_mention, .modes = Modes.compose_only, .desc = "insert a file path at the caret" },
    .{ .chords = &.{ctrl('j')}, .command = .compose_newline, .modes = Modes.compose_only, .desc = "a line break (Shift-Enter where the terminal sends it)" },

    .{ .chords = &.{c(event.code.tab)}, .command = .list_down, .modes = Modes.lists },
    .{ .chords = &.{shift(event.code.tab)}, .command = .list_up, .modes = Modes.lists },
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
        if (!sameChord(a, b)) return false;
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
        if (!sameChord(x, y)) return false;
    }
    return true;
}

/// Every field that makes a chord distinct. Written once because two callers
/// compare chords and a modifier missing from one of them is a binding that
/// reports a conflict with a key it is not.
fn sameChord(a: Chord, b: Chord) bool {
    return a.cp == b.cp and a.ctrl == b.ctrl and a.shift == b.shift;
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
    try testing.expect(km.feed(tap('v'), .normal) == .pending);
    try testing.expectEqual(Command.comment_view, km.feed(tap('c'), .normal).command);
}

test "one letter, two lengths: <Space>c and <Space>dc both resolve" {
    // `c` is the comment key everywhere: bare after the leader it writes one,
    // and after a `d`/`v` verb it is the noun that verb acts on. The dispatch
    // has to tell a one-key sequence from a two-key one, which is why
    // `<Space>c` can be a command only because nothing spells `<Space>c?`.
    var km: Keymap = .{};
    try testing.expect(km.feed(tap(' '), .normal) == .pending);
    try testing.expectEqual(Command.comment_add, km.feed(tap('c'), .normal).command);

    try testing.expect(km.feed(tap(' '), .normal) == .pending);
    try testing.expect(km.feed(tap('d'), .normal) == .pending);
    try testing.expectEqual(Command.comment_delete, km.feed(tap('c'), .normal).command);
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
    try testing.expect(km.feed(tap('Z'), .normal) == .none);
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
    // Plain 'd' is not bound - it belongs to vim's change/delete operators,
    // which is why the note keys moved behind the leader - and it must not
    // fall through to Ctrl-d.
    try testing.expect(km.feed(tap('d'), .normal) == .none);
    try testing.expectEqual(Command.line_down, km.feed(tap('j'), .normal).command);
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
    // the file would ever say so. `finder` counts: it was missing here while
    // no binding was finder-only, so the check would have rejected the first
    // one that was.
    for (default_bindings) |b| {
        try testing.expect(b.modes.normal or b.modes.visual or b.modes.help or
            b.modes.finder or b.modes.compose);
    }
}

test "motions work in visual mode, so selecting is moving with an anchor" {
    var km: Keymap = .{};
    try testing.expectEqual(Command.line_down, km.feed(tap('j'), .visual).command);
    try testing.expect(km.feed(tap(']'), .visual) == .pending);
    try testing.expectEqual(Command.next_hunk, km.feed(tap('h'), .visual).command);
}

test "one key, two modes, two commands" {
    // Escape is bound in both, and the mode is the only thing that tells them
    // apart: it leaves a selection where there is one, and clears the search
    // highlight where there is not. Getting this backwards would make `<Esc>`
    // silently drop a selection the reader was still building.
    var km: Keymap = .{};
    try testing.expectEqual(Command.visual_cancel, km.feed(tap(event.code.escape), .visual).command);
    try testing.expectEqual(Command.clear_search, km.feed(tap(event.code.escape), .normal).command);
    // And neither strands the next keystroke.
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
