Markdown, every construct
=========================

A sample to read *in* `lgtm`, not about it. Open it with `@` or `<Space>F` and
look: every line below is either something the highlighter claims, or something
it deliberately refuses. The refusals matter as much as the claims.

The `=====` rule above is what makes this line 1 an H1, and the hunk header at
the top of the screen should say so.

## Headings

### Three deep

#### Four deep

The hunk header names the innermost heading a line sits under, so scrolling
through this file should walk `Headings`, `Three deep`, `Four deep` and back
out again. These two are not headings, and are written bare so you can see it:

#hashtag is a word, because a heading's run is followed by a space.

####### Seven is more levels than exist.

A setext H2
-----------

A `---` under a line of prose is that line's heading. A `---` under a blank
line is a horizontal rule, like the one further down. Only the rule is
coloured; the title above it stays prose, deliberately.

## Prose, and what is left alone

Inline code is `zig build check`, and ``a span with a ` in it`` needs two
backticks. **Bold text** is bold, _italic text_ is underlined rather than
italic, and ~~struck out~~ is struck.

Now the refusals, written bare rather than in backticks - inside a code span
they would prove nothing. Every line below should be flat prose:

some_flag and other_flag on one line are two identifiers, not one italic span.

2 * 3 * 4 is arithmetic, because those marks do not hug the words between them.

\*Escaped stars\* stay prose, and *a \* b* closes on the last mark, not the
escaped one.

A stray ` backtick gives up at the end of its line rather than painting the rest
of the file.

An <img width="1400"> is a quantity in a sentence, and the digits in
0eb27774-9c64-43c2-ba22 are the same colour as the letters beside them.

## Lists

- a bullet
* another marker
+ and a third
- [ ] a task, not done
- [x] a task, done
  - nested one level
    - and two

1. ordered
2) also ordered
10. ten, and `2026 was a year` is not a list at all

> A blockquote. The `>` is the mark; what follows it is prose.

## Tables

| Setting | Default | What it does |
|---|---|:--:|
| `comments` | `"marker"` | the gutter dot alone |
| `layout` | `"flow"` | one column, or `"split"` |

The pipes and the rule recede, the header row goes bold, and a body cell lexes
on its own - so the inline code above still reads as inline code. The next line
has pipes but no rule under it, so it is prose:

| a pipe in it | and another |

## Links

See [the guide](docs/GUIDE.md), [`config.zig`](src/config.zig) with code in the
text, and a target with brackets of its own:
[a shot](https://host/assets/a(1).png).

![an image](https://host/assets/2c585a09-129f.png) and an autolink,
<https://example.com/path>. Prose with [square brackets] in it opens no link,
because nothing follows them.

## Fenced code

```zig
// # not a heading, and "not a string to us"
const x: u32 = 1400;
```

~~~
A tilde fence. The ``` inside it is a line of the block, not a closing fence,
because a fence closes only on its own character.
~~~

The info string after the opening fence names a language and is coloured; the
body is not lexed at all, because it is somebody else's language.

<!-- An HTML comment, which markdown allows and this reads as a comment. -->

---

Everything below that rule is after a thematic break: the rule has a blank line
above it, so it is a rule and not a heading.
