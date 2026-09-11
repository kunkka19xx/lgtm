# Configuring `lgtm`

Two files, merged key by key:

```
~/.config/lgtm/config.toml     yours, everywhere
.lgtm/config.toml              this repository's
```

`lgtm --init` writes the first of these, and `lgtm --init --config
.lgtm/config.toml` the second. Every line in what it writes is commented out
and shows the default, so the file changes nothing until you uncomment
something; it never overwrites a file that already exists.

The repository's wins where they disagree. `.lgtm/` is ignored by the
`.gitignore` `lgtm` writes there, except `config.toml`, so a project can commit
its own settings without committing anyone's session state.

**A bad setting never stops `lgtm` starting.** It is reported on the status line
with the file, the line and the key, and only that one key falls back to its
default. This is a rule, not an accident: a review tool that refuses to open
because of a typo is a review tool you stop running.

String lists can span multiple lines, with comments and a trailing comma:

```toml
[keys]
next_hunk = [
    "]h",
    "<Space>nh", # alternative binding
]
```

---

## `[nav]`

| Key | Default | |
|---|---|---|
| `hunk_crosses_files` | `true` | `]h` carries into the next file at the end of one. False keeps hunk motions inside the current file, wrapping there |
| `scrolloff` | `3` | Rows kept between the cursor and the edge. Clamped to a third of the body, so a large value on a short pane degrades instead of pinning the cursor to the middle |
| `mark_on_submit` | `true` | `<C-s>` takes the mark as well as sending the review. False for a mark you want to span several rounds |

```toml
[nav]
hunk_crosses_files = true
scrolloff = 3
mark_on_submit = true
```

## `[diff]`

| Key | Default | |
|---|---|---|
| `layout` | `"auto"` | `"auto"`, `"flow"` or `"split"`. `flow` is the one-column diff; `split` is side by side. `auto` is responsive: side by side when the pane is wide enough, flow when it is not. `\|` or `-` switches views for the session, and switching beats `auto`. `"unified"` is accepted as a spelling of `"flow"` |
| `highlight` | `"line"` | `"line"` washes the whole changed row; `"gutter"` keeps the colour in the sign and the line number and leaves the code to the syntax highlighting |
| `split_min_width` | `100` | Below this many columns, `auto` reads flow. Each side needs a line number, a sign, a gutter and about forty columns of code, with a divider between them; under that, side by side wraps so hard it shows less than the flow view. Minimum 60, which is the floor below |
| `expand_lines` | `10` | Lines `K` and `J` pull in around a hunk each press. Git shows three either side and the buffers hold the rest, so this is how much of the rest arrives at a time. Between 1 and 500 |

```toml
[diff]
layout = "auto"
highlight = "line"
split_min_width = 100
expand_lines = 10
```

The wash colours are mixed from the theme rather than written per theme: the
hue a fifth of the way over the theme's own background, so a palette that
publishes a green and a background already says what its diff green is. The
default `terminal` palette is built from 256-colour indexes, which cannot be
mixed with anything, so it takes three from the fixed colour cube instead -
stronger than a mix, and deliberately so. Set `add_line`, `del_line` or
`filler` under `[theme]` to override any of them. `filler` is the side of a
split row that has no line on it: the shape of what was added or taken away,
rather than a hole in the middle of it.

`[ui] wrap` governs both views. A split row takes as many screen rows as its
taller column needs, so the two sides stay aligned and neither is cut off at
the divider; `zw` turns it off in the split view the same way it does in the
flow view. Continuation rows follow the line's own indentation, capped at a
third of the column so a deeply nested line still has most of it to wrap into;
a review note wraps flush, because indentation in prose is whatever the writer
happened to type. A file with no hunks - one opened whole with `<Space>F` - stays
flow, because both of its sides would be the same text.

**Below 60 columns there is no side by side at all**, whatever `layout` says
and whatever `\|` was last pressed. That is a floor rather than a threshold:
`split_min_width` is where `auto` stops *choosing* two columns, and 60 is where
they stop being possible - a gutter of about five and twenty-four columns of
code a side, plus the divider. Shrinking a pane past it falls back to flow and
widening brings the split straight back, because the layout you asked for is
suspended rather than forgotten.

**The two views spend different gutters.** The flow view has the pane to
itself and spends four columns: `+` or `-`, the column `]m`'s bar sits in, the
number, and two after it - the first where a comment's dot goes, the second
air the code reads better for.

The split view has halved itself already and spends **one**: the number, and
the single column between it and the code. That column is the separator, the
comment's dot and the mark's bar at once, whichever the line has earned - and
a comment wins it, because a comment is something you put there on purpose
while `]m` will walk you to the mark anyway. The sign is gone because the
number is green or red and the row is washed behind it; the air is gone
because there is none to spare. The flow view keeps all four precisely because
it can afford them, and because it is the one view a terminal without colour
can still read.

On an even-width pane the odd column goes to the new file, which is the side
being reviewed.

## `[ui]`

| Key | Default | |
|---|---|---|
| `preview` | `true` | The panel beside a list: the pane picker shows the pane's own screen, the comment list the remark as it was written, the file lists the head of that file's diff. One key for all three - they are the same idea, and a reader who does not want a list explaining itself does not want it three times |
| `wrap` | `true` | Soft wrap long lines. `zw` toggles it for the session. A wrapped code line's continuation rows start under the line's own indentation, so a run-on reads as one statement rather than as the start of a new one |
| `icons` | `"unicode"` | `"nerd"`, `"unicode"` or `"ascii"`. Only `nerd` has filetype icons; `ascii` exists for a terminal that would draw the rest as tofu |
| `comments` | `"marker"` | `"marker"` is the gutter dot alone; `"inline"` folds the comment text under the line it belongs to |
| `compose` | `"bottom"` | `"bottom"`, `"top"` or `"centre"`, where the compose box opens |
| `tab_width` | `4` | Columns a tab is drawn as, 1 to 16. A tab advances to the next multiple of it, so a line aligned with tabs stays aligned. Four rather than eight because the pane this is built for is a split one, and Go or a Makefile indented at eight spends a third of it before the code starts |
| `scroll_lines` | `3` | Rows one notch of the mouse wheel moves, up to 20. `0` never asks the terminal to report the mouse at all, which leaves the wheel and drag-selection to the terminal. Three is what a terminal sends when it turns the wheel into arrow keys itself; a trackpad reports a notch per line it travels, so `1` is the setting for one |
| `scroll_ms` | `250` | How long a jump takes to travel, up to 1000. `0` turns the animation off |
| `cursor_ms` | `80` | The same for the cursor |

```toml
[ui]
icons = "nerd"
comments = "inline"
compose = "bottom"
tab_width = 8        # what gofmt and make assume
scroll_ms = 0        # instant
scroll_lines = 1     # a trackpad scrolls a line at a time
```

## `[templates]`

Every sentence `lgtm` sends your agent, as data. Override the ones you want;
the rest keep their defaults.

```toml
[templates]
submit_review = "please review {path}, {count} note{s} waiting"
ref_single    = "look at {path} line {line}"
ask_test      = "{ref}: a table test, not a unit test"
```

| Key | Default | `{vars}` |
|---|---|---|
| `ref_single` | `#{change_id} {path}:{line}` | `change_id` `path` `line` |
| `ref_range` | `#{change_id} {path}:{start}-{end}` | `change_id` `path` `start` `end` |
| `ref_span` | ``#{change_id} {path}:{line} `{span}` `` | plus `span`, the selected text |
| `ref_hunk` | `#{change_id} {path}:{line} (deleted lines in this hunk)` | the cursor on a removed line, which the new file has no number for |
| `ref_file` | `{path}` | a file too large to render inline, so there is no hunk to point at |
| `ref_file_line` / `_range` / `_span` | `{path}:{line}` … | a file with no hunks at all, opened and read rather than reviewed, so no `#id` |
| `ref_prefix` | `PR #{pr} ` | put before every reference while a pull request is on screen, and nothing at all otherwise |
| `submit_review` | `review ready: {path} ({count} comment{s})` | `path` `count` `s` |
| `ask_why` `ask_revert` `ask_test` `ask_explain` | `{ref} - why this approach?` … | `ref`, whichever of the above the cursor produced |

`ref_prefix` exists because a pull request is somebody else's tree.
`src/config.zig:423` handed to an agent standing in your checkout points at
different code, and nothing in the reference says so. Every `{var}` above is
available to it, plus `{pr}`.

`{s}` on `submit_review` is the plural: empty for one comment, `s` otherwise.
It is a variable rather than a branch, because a template language with an `if`
in it is a template language.

**An unknown placeholder is left verbatim rather than dropped.** Write
`{lines}` where the table offers `{line}` and you will see the typo in the
message you just sent, instead of a silently shorter one. A key that is not a
template is reported with its file and line, like any other config mistake.

## `[snapshot]`

| Key | Default | |
|---|---|---|
| `keep` | `36` | Turns of the current session kept before the oldest are pruned. Minimum 4 |

```toml
[snapshot]
keep = 36
```

Pruning deletes refs; the objects go when `git gc` next runs. **Two turns are
pinned whatever `keep` says:** the baseline, `0 original`, which is the tree as
it was before the agent ran and the one snapshot nothing else can reconstruct;
and the turn the mark sits on, which is what `✓`, "since the mark" and `]m` all
point at. So lowering `keep` costs the middle of a long session and neither of
its ends. Other sessions are never pruned - they are somebody's afternoon, and
git shares the objects anyway.

Snapshots carry **every** changed file git reports, including ones
`[review] ignore` keeps off the screen. That is deliberate: a file hidden from
the review is still a file an agent can destroy, and the two kinds of ignoring
are different questions. `.gitignore` is still respected.

## `[review]`

| Key | |
|---|---|
| `ignore` | Paths to keep out of the review |

These are git pathspecs, passed to git as `:(exclude)`, so the glob semantics
are `.gitignore`'s exactly: there is no matcher here to get subtly wrong. git
never parses the hunks either, so a 900-line lockfile costs nothing.

What this is for is the file `.gitignore` *cannot* help with: the generated ones
that are tracked on purpose.

```toml
[review]
ignore = ["package-lock.json", "**/*.pb.go", "dist/**"]
```

Hidden files are counted on the status line, so nothing is ever hidden
silently, and `zi` reveals them.

## `[presets]`

Questions for the compose box's `<C-i>` list, and for `<Space>a`. Any names, any
number.

```toml
[presets]
why    = "why this approach?"
perf   = "is this hot path allocating?"
test   = "add a test covering this"
revert = "revert this, keep the rest"
```

A preset is inserted at the caret and deletes nothing, so you can drop one into
a sentence you are half way through.

## `[theme]`

```toml
[theme]
name = "gruvbox"
```

Seven are bundled: `terminal`, `catppuccin`, `tokyo-night`, `gruvbox`,
`dracula`, `rose-pine`, `kanagawa`. `terminal` paints nothing and lets your
emulator's own sixteen colours through.

`lgtm --theme-preview` shows them all, and `:theme <Tab>` cycles them inside a
running lgtm - which is the quicker way to choose one. That lasts for the
session; this file is what makes it stick.

Setting `name` here after a slot override discards the override, and `:theme`
does the same for the same reason: a palette is a set of colours, not a base to
patch.

### Overriding one colour

Any slot can be set by name in the same section. A slot takes a foreground, an
optional `on <colour>` background, and attributes, in any order:

```toml
[theme]
name = "gruvbox"
fresh = "#fabd2f bold"
comment_open = "cyan"
cursor_line = "on #3c3836"
```

Colours are `#rrggbb`, a 0–255 index, or a name (`red`, `bright-blue`, …).
Attributes are `bold`, `dim`, `italic`, `underline`, `reverse`.

The slots:

| | |
|---|---|
| Syntax | `text` `comment` `string` `number` `keyword` `type_name` `fn_name` `punct` |
| Accents | `accent` `popup_border` |
| Files | `file_plain` `file_added` `file_deleted` `file_modified` `file_renamed` `file_binary` |
| Diff | `add_sign` `del_sign` `add_line` `del_line` `filler` `hunk_id` `line_no` `added_count` `removed_count` |
| Comments | `comment_open` `comment_sent` `comment_stale` |
| The mark | `fresh` |
| Chrome | `rule` `dim` `path` `hint` `notice` `prompt` `mode_badge` `turn_badge` |
| Selection | `cursor_line` `selection` `search_match` |

## `[keys]`

Any command can be bound to any sequence, spelled the way `?` prints it:

```toml
[keys]
next_hunk = ["]h", "<Space>nh"]
mark_here = ["gm"]
turn_list = ["<Space>t"]
compose_presets = ["<C-p>"]
```

A command with no entry keeps its defaults. An entry replaces them, so listing
one spelling removes the others.

Spellings: a bare character (`j`, `]`, `?`), `<C-x>` for control, `<Space>` for
the leader, and `<CR>` `<Esc>` `<Tab>` `<BS>` `<Up>` `<Down>` `<Left>` `<Right>`
for the named keys. `<Enter>` `<Escape>` `<Backspace>` are accepted for the
first three. Shift only applies to a named key, so `<S-Tab>` and `<S-CR>` are
the two; on a character the shift *is* the character, and `V` is how you write
it. `<lt>` is a literal `<`, which a bare one cannot be. A sequence is those run
together: `]h`, `<Space>nc`, `gg`.

**Conflicts are reported, not resolved.** Binding something to `<Space>d` when
`<Space>dc` exists makes one of them unreachable, and `lgtm` says so on the
status line rather than picking a winner.

These names are also what `:` takes: `:next_file` runs the command whether or
not a key is bound to it, and `<Tab>` completes them. Typing one is the quickest
way to check a spelling before committing it to a config file.

### Every command

The default key is there so you can find a command by the key you already
press. `<Space>nx` and `<Space>px` are left out: every `]x` has one, and the
rule is easier to hold than fourteen more rows.

**Moving**

| Command | Default |
| --- | --- |
| `line_down` | `j` `<Down>` |
| `line_up` | `k` `<Up>` |
| `page_down` | `<C-d>` |
| `page_up` | `<C-u>` |
| `top` | `gg` |
| `bottom` | `G` |
| `char_left` | `h` `<Left>` |
| `char_right` | `l` `<Right>` |
| `word_next` | `w` |
| `word_prev` | `b` |
| `word_end` | `e` |
| `big_word_next` | `W` |
| `big_word_prev` | `B` |
| `big_word_end` | `E` |
| `line_start` | `0` |
| `line_end` | `$` |
| `first_non_blank` | `^` |
| `find_char` | `f` |
| `till_char` | `t` |
| `find_char_back` | `F` |
| `till_char_back` | `T` |
| `find_repeat` | `;` |
| `find_reverse` | `,` |
| `center` | `zz` |
| `next_break` | `}` |
| `prev_break` | `{` |

**Jumping**

| Command | Default |
| --- | --- |
| `next_hunk` | `]h` |
| `prev_hunk` | `[h` |
| `next_file` | `]f` |
| `prev_file` | `[f` |
| `next_comment` | `]c` |
| `prev_comment` | `[c` |
| `next_risk` | `]w` |
| `prev_risk` | `[w` |
| `search_forward` | `/` |
| `search_next` | `n` |
| `search_prev` | `N` |
| `search_word` | `*` |
| `search_word_back` | `#` |
| `clear_search` | `<Esc>` |

**The agent**

| Command | Default |
| --- | --- |
| `send_ref` | `<CR>` |
| `compose_ask` | `<Space>a` |
| `copy_text` | `y` |
| `copy_text_lines` | `Y` |
| `copy_ref` | `<Space>y` |
| `copy_ref_lines` | `<Space>Y` |
| `submit_review` | `<C-s>` |
| `pick_pane` | `<Space>t` |

**Comments**

| Command | Default |
| --- | --- |
| `comment_add` | `<Space>c` |
| `comment_view` | `<Space>vc` |
| `comment_list` | `<Space>lc` |
| `comment_send` | `<Space>sc` |
| `comment_delete` | `<Space>dc` |
| `comment_suggest` | `<Space>gc` |
| `comment_send_one` | `<C-s>` |
| `comment_send_all` | `<C-x>` |
| `comment_drop` | `<C-d>` |
| `comment_post_one` | `<C-p>` |
| `compose_post_now` | `<C-p>` |

**Pull requests**

| Command | Default |
| --- | --- |
| `pr_list` | `<Space>lp` |

**Turns and the mark**

| Command | Default |
| --- | --- |
| `mark_here` | `m` |
| `clear_mark` | `M` |
| `next_fresh` | `]m` |
| `prev_fresh` | `[m` |
| `next_turn` | `]t` |
| `prev_turn` | `[t` |
| `turn_list` | `<Space>lt` |
| `restore_file` | `R` |
| `undo_restore` | `u` |

**View**

| Command | Default |
| --- | --- |
| `toggle_zen` | `<Tab>` |
| `toggle_wrap` | `zw` |
| `toggle_split` | `|` `-` |
| `toggle_ignored` | `zi` |
| `expand_file` | `zo` |
| `collapse_file` | `zc` |
| `collapse_context` | `zf` |
| `expand_up` | `K` |
| `expand_down` | `J` |
| `focus_left` | `H` |
| `focus_right` | `L` |
| `file_list` | `<Space>f` |
| `file_browse` | `<Space>F` |
| `help` | `?` |
| `refresh` | `<C-r>` |
| `open_editor` | `<Space>e` |
| `visual_toggle` | `V` |
| `visual_char_toggle` | `v` |
| `visual_cancel` | `<Esc>` |
| `command_line` | `:` |
| `quit` | none |

**Lists**

| Command | Default |
| --- | --- |
| `list_down` | `J` `<Down>` `<C-n>` `<Tab>` |
| `list_up` | `K` `<Up>` `<C-p>` `<S-Tab>` |
| `list_left` | `H` `H` `<Left>` |
| `list_right` | `L` `L` `<Right>` |

**The compose box**

| Command | Default |
| --- | --- |
| `compose_submit` | `<CR>` |
| `compose_cancel` | `<Esc>` |
| `compose_send_now` | `<C-s>` |
| `compose_presets` | `<C-i>` `<Tab>` |
| `compose_mention` | `@` |
| `compose_newline` | `<C-o>` `<C-j>` `<S-CR>` |

The box's keys are bindings like any others, but with two rules of their own.
They must be **single chords**: a text box cannot hold a prefix while waiting
to see whether a sequence completes, because the next key is usually a letter
you are typing. And a **pending operator wins**: with `d` waiting for a motion,
`<Esc>` cancels the operator rather than the box.

The box's *motions* are not remappable, and that is deliberate rather than
unfinished. In a text box every printable key is data, so a keymap able to bind
`x` would be a keymap able to take `x` away from typing.

---

## A complete example

```toml
[nav]
scrolloff = 5
mark_on_submit = true

[ui]
icons = "nerd"
comments = "inline"
compose = "centre"
scroll_ms = 0

[review]
ignore = ["package-lock.json", "**/*.pb.go"]

[presets]
why  = "why this approach?"
perf = "is this hot path allocating?"

[theme]
name = "kanagawa"
fresh = "#ffa066 bold"

[keys]
mark_here = ["gm"]
turn_list = ["<Space>t"]
```
