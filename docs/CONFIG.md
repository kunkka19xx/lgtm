# Configuring `lgtm`

Two files, merged key by key:

```
~/.config/lgtm/config.toml     yours, everywhere
.lgtm/config.toml              this repository's
```

The repository's wins where they disagree. `.lgtm/` is ignored by the
`.gitignore` `lgtm` writes there, except `config.toml` — so a project can commit
its own settings without committing anyone's session state.

**A bad setting never stops `lgtm` starting.** It is reported on the status line
with the file, the line and the key, and only that one key falls back to its
default. This is a rule, not an accident: a review tool that refuses to open
because of a typo is a review tool you stop running.

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

```toml
[diff]
layout = "auto"
highlight = "line"
split_min_width = 100
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
| `wrap` | `true` | Soft wrap long lines. `zw` toggles it for the session. A wrapped code line's continuation rows start under the line's own indentation, so a run-on reads as one statement rather than as the start of a new one |
| `icons` | `"unicode"` | `"nerd"`, `"unicode"` or `"ascii"`. Only `nerd` has filetype icons; `ascii` exists for a terminal that would draw the rest as tofu |
| `comments` | `"marker"` | `"marker"` is the gutter dot alone; `"inline"` folds the comment text under the line it belongs to |
| `compose` | `"bottom"` | `"bottom"`, `"top"` or `"centre"` — where the compose box opens |
| `scroll_ms` | `250` | How long a jump takes to travel, up to 1000. `0` turns the animation off |
| `cursor_ms` | `80` | The same for the cursor |

```toml
[ui]
icons = "nerd"
comments = "inline"
compose = "bottom"
scroll_ms = 0        # instant
```

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
are `.gitignore`'s exactly — there is no matcher here to get subtly wrong. git
never parses the hunks either, so a 900-line lockfile costs nothing.

What this is for is the file `.gitignore` *cannot* help with: the generated ones
that are tracked on purpose.

```toml
[review]
ignore = ["package-lock.json", "**/*.pb.go", "dist/**"]
```

Hidden files are counted on the status line — nothing is ever hidden silently —
and `zi` reveals them.

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

`lgtm --theme-preview` shows them all.

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
the leader, and `<CR>` `<Esc>` `<Tab>` `<S-Tab>` `<BS>` `<Up>` `<Down>` `<Left>`
`<Right>` for the named keys. A sequence is those run together: `]h`,
`<Space>nc`, `gg`.

**Conflicts are reported, not resolved.** Binding something to `<Space>d` when
`<Space>dc` exists makes one of them unreachable, and `lgtm` says so on the
status line rather than picking a winner.

These names are also what `:` takes: `:next_file` runs the command whether or
not a key is bound to it, and `<Tab>` completes them. Typing one is the quickest
way to check a spelling before committing it to a config file.

### Every command

**Moving** `line_down` `line_up` `page_down` `page_up` `top` `bottom`
`char_left` `char_right` `word_next` `word_prev` `word_end` `big_word_next`
`big_word_prev` `big_word_end` `line_start` `line_end` `first_non_blank`
`find_char` `till_char` `find_char_back` `till_char_back` `find_repeat`
`find_reverse` `center`

**Jumping** `next_hunk` `prev_hunk` `next_file` `prev_file` `next_comment`
`prev_comment` `next_risk` `prev_risk` `search_forward` `search_next`
`search_prev` `search_word` `search_word_back` `clear_search`

**The agent** `send_ref` `compose_ask` `copy_text` `copy_text_lines` `copy_ref`
`copy_ref_lines` `submit_review`

**Comments** `comment_add` `comment_view` `comment_list` `comment_send`
`comment_delete` `comment_send_one` `comment_send_all` `comment_drop`

**Turns and the mark** `mark_here` `clear_mark` `next_fresh` `prev_fresh`
`next_turn` `prev_turn` `turn_list` `restore_file` `undo_restore`

**View** `toggle_zen` `toggle_wrap` `toggle_split` `toggle_ignored` `expand_file`
`collapse_file` `file_list` `file_browse` `help` `refresh` `open_editor`
`visual_toggle` `visual_char_toggle` `visual_cancel` `command_line` `quit`

**Lists** `list_down` `list_up` `list_left` `list_right`

**The compose box** `compose_submit` `compose_cancel` `compose_send_now`
`compose_presets` `compose_mention` `compose_newline`

The box's keys are bindings like any others, but with two rules of their own.
They must be **single chords** — a text box cannot hold a prefix while waiting
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
