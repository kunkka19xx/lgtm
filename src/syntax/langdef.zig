// SPDX-License-Identifier: Apache-2.0
//
// The vocabulary a language is described in: what opens a comment, what quotes
// a string, which words are keywords, how a function body is delimited. One
// comptime struct per language in `lang/`, and `define` turns each into the
// lookup tables the scanner's inner loop wants.
//
// Separate from `lexer.zig` because a language definition is data about a
// language, not part of the machine that reads it: `lang/zig.zig` has no
// business importing a scanner. The performance notes below are why this file
// is larger than the data it holds - every table here exists because a
// measurement asked for it.

const std = @import("std");
const token = @import("token.zig");
const Kind = token.Kind;

pub const BlockComment = struct {
    open: []const u8,
    close: []const u8,
    nested: bool = false,
};

pub const StringSpec = struct {
    open: []const u8,
    close: []const u8,
    /// Byte that escapes the next one; null for raw literals.
    escape: ?u8 = '\\',
    /// May the literal cross a newline? An unterminated single-line literal
    /// recovers at the end of the line rather than swallowing the file.
    multiline: bool = false,
    /// Rust's `r#"..."#`: after `open` count the '#'s, require a '"', and
    /// require the same number of '#'s after the closing quote.
    ///
    /// `open` may be empty, which is Swift's `#"..."#` - the '#' run is the
    /// whole opener. A prefixless spec needs at least one '#', or it would
    /// match every plain `"` and impose the raw literal's escape rules on it.
    hashed: bool = false,
    /// A literal that does not close within this many bytes was never a
    /// literal. This is what stops a Rust lifetime (`'a`) from being read as
    /// an unterminated char literal and painting the rest of the line.
    max_bytes: ?u16 = null,
};

/// How the language delimits a function body. Determines both brace-depth
/// tracking and how the enclosing-function scan closes a span.
pub const Blocks = enum { braces, indent };

pub const LangDef = struct {
    name: []const u8,
    /// Lower-case, without the leading dot.
    extensions: []const []const u8 = &.{},
    line_comment: []const []const u8 = &.{},
    block_comment: ?BlockComment = null,
    /// Zig's `\\`: a string literal that runs to the end of the line.
    line_string: []const []const u8 = &.{},
    /// Checked in order, so longer openers come first - Python's `"""` has to
    /// be tried before `"`.
    strings: []const StringSpec = &.{},
    keywords: []const []const u8 = &.{},
    types: []const []const u8 = &.{},
    /// Keywords that introduce a named function: the next identifier is its
    /// name, and it opens a span for the enclosing-function scan.
    fn_decl: []const []const u8 = &.{},
    /// The subset of `fn_decl` that only counts when a block opens on the same
    /// line. JavaScript needs `const` in `fn_decl` - `const App = () => {}` is
    /// how a module's functions are written - but `const email = form.email`
    /// is the same two tokens and is not a function. Without this its span
    /// runs to the enclosing brace and every line after it reports `email`
    /// instead of the function it sits in.
    ///
    /// Not the default for `fn_decl`, because `fn foo(\n    a: u32,\n) u32 {`
    /// is ordinary Zig and Rust, and a trait's bodyless `fn foo(&self);` is
    /// meant to declare a span at all.
    fn_decl_body: []const []const u8 = &.{},
    /// Go's `func (r *T) Name()`: allow a parenthesised receiver between the
    /// keyword and the name.
    fn_receiver: bool = false,
    blocks: Blocks = .braces,
    /// Identifier start bytes beyond letters and '_': Zig's `@import`.
    ident_extra: []const u8 = "",
    /// Identifier *continuation* bytes beyond letters, digits and '_': CSS's
    /// `grid-template-columns`. Not implied by `ident_extra` - Zig's '@' starts
    /// an identifier and never continues one - so a language that wants both
    /// names the byte twice.
    ident_cont_extra: []const u8 = "",
    /// HTML: the identifier after `<` or `</` is a tag name. One token of
    /// lookahead, like `fn_decl`, but it names an element rather than a
    /// function, so it is typed `.type_name` and opens no span.
    angle_tags: bool = false,

    /// Filled in by `define`. Written by hand nowhere.
    words: std.StaticStringMap(Kind) = .{},
    fn_words: std.StaticStringMap(void) = .{},
    /// Consulted only for a word `fn_words` already matched, so an ordinary
    /// keyword never pays for it.
    fn_body_words: std.StaticStringMap(void) = .{},
    /// Bytes that can begin a comment or a literal. The scanner's inner loop
    /// consults this before trying any opener, so ordinary identifiers and
    /// operators never pay for the `startsWith` ladder. Measured: 148 ns/line
    /// before, 82 ns/line after.
    delim_start: [256]bool = @splat(false),
    /// Bytes that can begin an identifier, including `ident_extra`.
    ident_start: [256]bool = @splat(false),
    /// Bytes that can continue one, including `ident_cont_extra`. A table for
    /// the same reason `ident_start` is one: it sits in the scanner's inner
    /// loop, one byte per identifier character.
    ident_cont: [256]bool = @splat(false),
    /// Bit `n` is set when some keyword or type name of length `n` starts
    /// (respectively ends) with this byte. See `lookupWord`.
    word_first: [256]u64 = @splat(0),
    word_last: [256]u64 = @splat(0),

    /// Keyword lookup with a prefilter, because most identifiers are not
    /// keywords and the map was 20% of total scan time without one (measured
    /// by removing it: 0.542 ms to 0.435 ms over a 6.4k-line corpus).
    ///
    /// The two masks agree on a length only for a word that really could be a
    /// keyword, so a non-match costs two loads and an `and`. False positives
    /// fall through to the map and are still answered correctly; false
    /// negatives are impossible, since a real keyword sets both of its bits.
    ///
    /// This is the tier-one win at the cost of a comptime table
    /// rather than a hand-rolled perfect hash. Revisit only if a profile says
    /// the remainder still matters.
    pub fn lookupWord(self: *const LangDef, word: []const u8) ?Kind {
        if (word.len == 0 or word.len >= 64) return null;
        const bit = @as(u64, 1) << @intCast(word.len);
        if ((self.word_first[word[0]] & self.word_last[word[word.len - 1]] & bit) == 0) return null;
        return self.words.get(word);
    }
};

/// Builds the word lookups at comptime. `std.StaticStringMap` buckets by
/// length and compares only same-length keys, which is enough: the perfect
/// hash is a tier-one item and waits for profile evidence.
pub fn define(comptime d: LangDef) LangDef {
    comptime {
        var out = d;

        var words: [d.keywords.len + d.types.len]struct { []const u8, Kind } = undefined;
        for (d.keywords, 0..) |k, i| words[i] = .{ k, .keyword };
        for (d.types, 0..) |t, i| words[d.keywords.len + i] = .{ t, .type_name };
        const frozen_words = words;
        out.words = .initComptime(frozen_words);

        var fns: [d.fn_decl.len]struct { []const u8 } = undefined;
        for (d.fn_decl, 0..) |f, i| fns[i] = .{f};
        const frozen_fns = fns;
        out.fn_words = .initComptime(frozen_fns);

        var bodied: [d.fn_decl_body.len]struct { []const u8 } = undefined;
        for (d.fn_decl_body, 0..) |f, i| bodied[i] = .{f};
        const frozen_bodied = bodied;
        out.fn_body_words = .initComptime(frozen_bodied);

        var delim: [256]bool = @splat(false);
        for (d.line_comment) |x| {
            if (x.len > 0) delim[x[0]] = true;
        }
        for (d.line_string) |x| {
            if (x.len > 0) delim[x[0]] = true;
        }
        if (d.block_comment) |bc| {
            if (bc.open.len > 0) delim[bc.open[0]] = true;
        }
        for (d.strings) |sp| {
            // A prefixless hashed spec opens on the '#' run itself, so that is
            // the byte the scanner's inner loop has to stop on.
            const first: ?u8 = if (sp.open.len > 0)
                sp.open[0]
            else if (sp.hashed)
                '#'
            else
                @compileError("string spec with an empty opener must be hashed: " ++ d.name);
            if (first) |b| delim[b] = true;
        }
        out.delim_start = delim;

        var m_first: [256]u64 = @splat(0);
        var m_last: [256]u64 = @splat(0);
        for (d.keywords ++ d.types) |kw| {
            if (kw.len == 0 or kw.len >= 64) @compileError("keyword out of range: " ++ kw);
            const bit = @as(u64, 1) << @intCast(kw.len);
            m_first[kw[0]] |= bit;
            m_last[kw[kw.len - 1]] |= bit;
        }
        out.word_first = m_first;
        out.word_last = m_last;

        // `fn_decl` is only consulted for words the map already called a
        // keyword, so every one of them has to be in `keywords` too. Caught
        // here rather than as a language that silently stops finding its
        // function names.
        for (d.fn_decl) |f| {
            var found = false;
            for (d.keywords) |k| {
                if (std.mem.eql(u8, k, f)) found = true;
            }
            if (!found) @compileError("fn_decl word not in keywords: " ++ f);
        }

        // `fn_decl_body` narrows `fn_decl`; a word only in the narrower list
        // would never be consulted, which is a typo rather than an intent.
        for (d.fn_decl_body) |f| {
            var found = false;
            for (d.fn_decl) |k| {
                if (std.mem.eql(u8, k, f)) found = true;
            }
            if (!found) @compileError("fn_decl_body word not in fn_decl: " ++ f);
        }

        var ident: [256]bool = @splat(false);
        var cont: [256]bool = @splat(false);
        for (0..256) |c| {
            const b: u8 = @intCast(c);
            ident[c] = std.ascii.isAlphabetic(b) or b == '_' or b >= 0x80;
            cont[c] = std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80;
        }
        for (d.ident_extra) |b| ident[b] = true;
        for (d.ident_cont_extra) |b| cont[b] = true;
        out.ident_start = ident;
        out.ident_cont = cont;

        return out;
    }
}
