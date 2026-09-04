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

## `[ui]`

| Key | Default | |
|---|---|---|
| `wrap` | `true` | Soft wrap long lines. `zw` toggles it for the session |
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
| Diff | `add_sign` `del_sign` `hunk_id` `line_no` `added_count` `removed_count` |
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

### Every command

**Moving** `line_down` `line_up` `page_down` `page_up` `top` `bottom`
`char_left` `char_right` `word_next` `word_prev` `word_end` `big_word_next`
`big_word_prev` `big_word_end` `line_start` `line_end` `first_non_blank`
`find_char` `till_char` `find_char_back` `till_char_back` `find_repeat`
`find_reverse` `center`

**Jumping** `next_hunk` `prev_hunk` `next_file` `prev_file` `next_comment`
`prev_comment` `next_fresh` `prev_fresh` `next_turn` `prev_turn`
`search_forward` `search_next` `search_prev` `clear_search`

**The agent** `send_ref` `compose_ask` `copy_text` `copy_text_lines` `copy_ref`
`copy_ref_lines` `submit_review`

**Comments** `comment_add` `comment_view` `comment_list` `comment_send`
`comment_delete` `comment_send_one` `comment_send_all` `comment_drop`

**Turns** `mark_here` `clear_mark` `turn_list` `restore_file` `undo_restore`

**View** `toggle_zen` `toggle_wrap` `toggle_ignored` `expand_file`
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
