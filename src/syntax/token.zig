// SPDX-License-Identifier: Apache-2.0
//
// What a lexer produces: token kinds, and the runs that carry them.
//
// Its own file because everything downstream needs this vocabulary and nothing
// else from `syntax/` - a theme maps a `Kind` to a style, a renderer walks
// `Run`s - and because a language definition needs `Kind` too, which would
// otherwise mean the definitions importing the engine that consumes them.

const std = @import("std");

pub const Kind = enum(u8) {
    /// Whitespace, and anything the definition does not classify. Runs tile
    /// the scanned span completely, so a renderer walking runs never has to
    /// fill a gap or fall back to the raw bytes.
    text,
    comment,
    string,
    number,
    keyword,
    type_name,
    fn_name,
    punct,
    /// Markdown's `**bold**`.
    strong,
    /// Markdown's `_italic_`.
    emphasis,
    /// Markdown's `~~struck out~~`.
    strikethrough,
    /// A bullet, an ordered marker, a task box or a blockquote's `>`. Its own
    /// kind rather than `punct`, which table pipes and `---` rules share: one
    /// marker per item is the thing that says the line is an item, where a
    /// row of pipes is chrome that should get out of the way.
    list_mark,
    /// Markdown's `# heading`. Its own kind rather than `type_name`, which it
    /// borrowed until there was a way to say bold - going bold there would
    /// have taken every other language's type names with it.
    heading,
};

/// Token runs, never per-character styles. `start` is a
/// byte offset into the scanned text.
///
/// Two invariants the renderer depends on, both asserted in the tests below:
///
/// 1. Runs tile the scanned span exactly - no gaps, no overlaps.
/// 2. A run holds at most one '\n', and only as its final byte. So runs group
///    into rows by scanning forward, and a row's text is the run's bytes with
///    a trailing newline trimmed.
pub const Run = struct {
    start: u32,
    len: u16,
    kind: Kind,

    pub fn end(self: Run) u32 {
        return self.start + self.len;
    }
};

/// A token longer than this is emitted as several consecutive runs of the same
/// kind. Only generated code reaches it.
pub const max_run_len = std.math.maxInt(u16);
