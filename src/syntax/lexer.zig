// SPDX-License-Identifier: Apache-2.0
//
// One generic lexer over per-language definitions supplied at comptime
//. A lexer rather than a parser, because a hunk is by
// definition a fragment - unbalanced braces, functions cut off at both ends.
// Lexers handle fragments naturally; parsers fall into error recovery, which
// is their slowest path.

const std = @import("std");
const Allocator = std.mem.Allocator;

const langdef = @import("langdef.zig");
const token = @import("token.zig");

// Re-exported: "the lexer produces runs of a kind, over a language definition"
// is one idea to every caller, whatever it is split into underneath.
pub const Kind = token.Kind;
pub const Run = token.Run;
pub const max_run_len = token.max_run_len;
pub const LangDef = langdef.LangDef;
pub const StringSpec = langdef.StringSpec;
pub const BlockComment = langdef.BlockComment;
pub const Blocks = langdef.Blocks;
pub const define = langdef.define;

/// Everything needed to resume lexing at a line boundary. Small and copyable,
/// which is what makes checkpoints cheap to store.
pub const State = struct {
    mode: Mode = .normal,
    /// Block-comment nesting depth, when `mode` is `.block_comment`.
    nest: u16 = 0,
    /// Index into `LangDef.strings` of the literal currently open.
    spec: u8 = 0,
    /// '#' count of an open raw string.
    hashes: u8 = 0,
    /// Net brace depth since the start of the file. Signed, because a fragment
    /// can close more braces than it opens.
    depth: i32 = 0,
    /// Indentation of the line that opened a block scalar. Its body is every
    /// line indented past this one.
    block_indent: u16 = 0,
    /// The byte an open fence is made of, and how many. A fence closes only
    /// on its own character and at least as many. Here, not on `Scan`, so a
    /// lex resumed from a checkpoint inside one matches a whole-file lex.
    fence_char: u8 = 0,
    fence_len: u8 = 0,
    /// A `|---|---|` has been seen and no line since has ended the table. In
    /// `State` so a lex resumed from a checkpoint inside a long table knows
    /// it is in one; a row alone is a paragraph that happens to have pipes.
    in_table: bool = false,

    pub const Mode = enum(u8) { normal, block_comment, string, block_scalar, fence };
};

pub const checkpoint_lines = 64;

/// `{brace_depth, lex_state}` every 64 lines. Lexing any
/// region restarts from the nearest preceding checkpoint, so reaching line
/// 9000 costs 64 lines of scanning, not 9000.
pub const Checkpoint = struct {
    /// Byte offset of the first byte of `line`.
    offset: u32,
    line: u32,
    state: State,
};

/// A named function span. `end_line` is inclusive, and is the last line of the
/// file when the body never closes - which is the normal case for a file an
/// agent is halfway through writing.
pub const FnDecl = struct {
    /// Borrowed from the scanned text, which must outlive it.
    name: []const u8,
    start_line: u32,
    end_line: u32,
    depth: i32,
    indent: u16,
    /// False while a `fn_decl_body` declaration is still waiting for the block
    /// that would prove it is a function. `structure` drops whatever is still
    /// false at the end, so a consumer never sees one.
    confirmed: bool = true,
};

/// The whole-file pass: what the visible range needs before it can be lexed
/// from the middle, plus what the hunk header needs.
pub const Structure = struct {
    checkpoints: []Checkpoint,
    fns: []FnDecl,
    lines: u32,

    pub fn deinit(self: *Structure, gpa: Allocator) void {
        gpa.free(self.checkpoints);
        gpa.free(self.fns);
        self.* = undefined;
    }

    /// Nearest checkpoint at or before `line`. Never fails: a file always has
    /// a checkpoint at line 0.
    pub fn checkpointFor(self: Structure, line: u32) Checkpoint {
        if (self.checkpoints.len == 0) return .{ .offset = 0, .line = 0, .state = .{} };
        const idx = @min(line / checkpoint_lines, self.checkpoints.len - 1);
        return self.checkpoints[idx];
    }

    /// Innermost function containing `line`, or null outside every body.
    ///
    /// Backwards from the end, so the first span that contains the line is the
    /// innermost one: nested declarations always come later in file order.
    pub fn enclosingFn(self: Structure, line: u32) ?FnDecl {
        var i = self.fns.len;
        while (i > 0) {
            i -= 1;
            const f = self.fns[i];
            if (f.start_line > line) continue;
            if (f.end_line >= line) return f;
        }
        return null;
    }
};

pub const Lexer = struct {
    def: *const LangDef,

    pub fn init(def: *const LangDef) Lexer {
        return .{ .def = def };
    }

    /// Runs for `text[from..to]`, resuming from `state`, appended to `out`.
    /// Returns the state at `to`.
    ///
    /// `from` must be the first byte of a line - in practice a checkpoint
    /// offset - because line-start bookkeeping (indentation, checkpoints) is
    /// only correct there.
    pub fn lex(
        self: Lexer,
        gpa: Allocator,
        text: []const u8,
        from: usize,
        to: usize,
        state: State,
        out: *std.ArrayList(Run),
    ) Allocator.Error!State {
        // Roughly one run per four bytes across this repository, so one
        // reservation replaces a dozen growth steps.
        try out.ensureUnusedCapacity(gpa, (to - from) / 4 + 16);

        var s: Scan = .{
            .def = self.def,
            .gpa = gpa,
            .text = text,
            .i = from,
            .end = to,
            .st = state,
            .runs = out,
            .text_start = from,
        };
        try s.run();
        try s.flushText(s.i);
        return s.st;
    }

    /// Convenience for the common "lex this whole thing" case, used by tests
    /// and by anything small enough not to bother with checkpoints.
    pub fn lexAll(self: Lexer, gpa: Allocator, text: []const u8) Allocator.Error![]Run {
        var out: std.ArrayList(Run) = .empty;
        errdefer out.deinit(gpa);
        _ = try self.lex(gpa, text, 0, text.len, .{}, &out);
        return out.toOwnedSlice(gpa);
    }

    /// One pass over the whole file recording checkpoints and function spans.
    /// Emits no runs, so it allocates only for those two lists.
    pub fn structure(self: Lexer, gpa: Allocator, text: []const u8) Allocator.Error!Structure {
        var cps: std.ArrayList(Checkpoint) = .empty;
        errdefer cps.deinit(gpa);
        var fns: std.ArrayList(FnDecl) = .empty;
        errdefer fns.deinit(gpa);
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(gpa);

        var s: Scan = .{
            .def = self.def,
            .gpa = gpa,
            .text = text,
            .i = 0,
            .end = text.len,
            .st = .{},
            .runs = null,
            .text_start = 0,
            .checkpoints = &cps,
            .fns = &fns,
            .stack = &stack,
        };
        try s.run();

        // `s.line` counted newlines, so a file ending in one has no extra line.
        const lines: u32 = if (text.len == 0)
            0
        else if (text[text.len - 1] == '\n') s.line else s.line + 1;

        // Whatever is still open at EOF is a fragment, not an error: close it
        // at the last line, so a note inside a half-written function still
        // reports a function name.
        const last = if (lines == 0) 0 else lines - 1;
        for (stack.items) |idx| fns.items[idx].end_line = last;

        // Drop the `fn_decl_body` declarations that never opened a block - the
        // plain assignments that share JavaScript's `const NAME =` shape.
        // Compacted in place, so what survives keeps its declaration order and
        // `enclosingFn`'s backwards scan still finds the innermost first.
        var kept: usize = 0;
        for (fns.items) |f| {
            if (!f.confirmed) continue;
            fns.items[kept] = f;
            kept += 1;
        }
        fns.shrinkRetainingCapacity(kept);

        const cp_slice = try cps.toOwnedSlice(gpa);
        errdefer gpa.free(cp_slice);
        return .{
            .checkpoints = cp_slice,
            .fns = try fns.toOwnedSlice(gpa),
            .lines = lines,
        };
    }
};

const Scan = struct {
    def: *const LangDef,
    gpa: Allocator,
    text: []const u8,
    i: usize,
    end: usize,
    st: State,

    /// Null in structure mode, where classification is computed but discarded.
    runs: ?*std.ArrayList(Run),
    /// Start of the pending `.text` run, flushed when a classified run begins.
    text_start: usize,

    checkpoints: ?*std.ArrayList(Checkpoint) = null,
    fns: ?*std.ArrayList(FnDecl) = null,
    stack: ?*std.ArrayList(u32) = null,

    line: u32 = 0,
    indent: u16 = 0,
    at_line_start: bool = true,
    /// Nothing but whitespace and a sequence dash has been seen on this line.
    /// What `key_words` means by the head of a line, and not part of `State`:
    /// it never survives a newline, so a checkpoint has nothing to carry.
    head: bool = true,
    /// Set by a `fn_decl` keyword; the next identifier is the function name.
    expect_fn: bool = false,
    /// Whether that keyword was a `fn_decl_body` one, so the span it opens
    /// needs a block on the same line before it counts.
    expect_fn_body: bool = false,
    /// Set by `<` or `</` under `angle_tags`; the next identifier is a tag
    /// name. Deliberately not part of `State`: a tag name never survives a
    /// newline, so a checkpoint has nothing to carry.
    expect_tag: bool = false,
    /// What this line is to a table, decided once at its start. Not in
    /// `State`: a table row does not cross a newline.
    table: Table = .none,

    fn run(self: *Scan) Allocator.Error!void {
        while (self.i < self.end) {
            if (self.at_line_start) {
                try self.lineStart();
                self.at_line_start = false;
                self.head = true;
            }

            const before = self.i;
            switch (self.st.mode) {
                .normal => try self.inNormal(),
                .block_comment => try self.inBlockComment(self.i),
                .string => try self.inString(self.i),
                .block_scalar => try self.inBlockScalar(),
                .fence => try self.inFence(),
            }
            // Every step consumes at least one byte and never runs past the
            // newline that ends a line, so this is the single place lines are
            // counted.
            std.debug.assert(self.i > before);
            if (self.text[self.i - 1] == '\n') {
                self.line += 1;
                self.at_line_start = true;
            }
        }
    }

    fn lineStart(self: *Scan) Allocator.Error!void {
        if (self.checkpoints) |cps| {
            if (self.line % checkpoint_lines == 0) {
                try cps.append(self.gpa, .{
                    .offset = @intCast(self.i),
                    .line = self.line,
                    .state = self.st,
                });
            }
        }

        self.table = .none;

        // Indentation is only meaningful outside a multi-line literal.
        if (self.st.mode == .block_comment or self.st.mode == .string) return;
        if (self.st.mode == .fence) return;

        var j = self.i;
        var col: u16 = 0;
        while (j < self.end and (self.text[j] == ' ' or self.text[j] == '\t')) : (j += 1) col += 1;
        const blank = j >= self.end or self.text[j] == '\n' or self.text[j] == '\r';
        self.indent = col;
        if (blank) {
            // A blank line ends a table, so the next row of pipes is a
            // paragraph again until another rule says otherwise.
            self.st.in_table = false;
            return;
        }

        if (self.def.blocks == .indent) self.closeIndentSpans(col);
        if (self.def.tables) self.table = self.classifyTable(j);
    }

    /// A header is only knowable from the line below it, and a row only from
    /// the rule above it: without one, pipes are pipes in a paragraph.
    fn classifyTable(self: *Scan, from: usize) Table {
        if (from >= self.end or self.text[from] != '|') {
            self.st.in_table = false;
            return .none;
        }
        if (isDelimRow(self.text[from..self.lineEndFrom(from)])) {
            self.st.in_table = true;
            return .delim;
        }
        if (self.nextLineIsDelim(from)) return .header;
        return if (self.st.in_table) .row else .none;
    }

    fn lineEndFrom(self: Scan, from: usize) usize {
        return std.mem.indexOfScalarPos(u8, self.text[0..self.end], from, '\n') orelse self.end;
    }

    fn nextLineIsDelim(self: Scan, from: usize) bool {
        const nl = std.mem.indexOfScalarPos(u8, self.text[0..self.end], from, '\n') orelse return false;
        var j = nl + 1;
        while (j < self.end and (self.text[j] == ' ' or self.text[j] == '\t')) j += 1;
        if (j >= self.end or self.text[j] != '|') return false;
        return isDelimRow(self.text[j..self.lineEndFrom(j)]);
    }

    // -- emitting ----------------------------------------------------------

    fn push(self: *Scan, from: usize, to: usize, kind: Kind) Allocator.Error!void {
        const runs = self.runs orelse return;
        var at = from;
        while (at < to) {
            const len: u16 = @intCast(@min(to - at, max_run_len));
            try runs.append(self.gpa, .{ .start = @intCast(at), .len = len, .kind = kind });
            at += len;
        }
    }

    fn flushText(self: *Scan, upto: usize) Allocator.Error!void {
        if (upto > self.text_start) try self.push(self.text_start, upto, .text);
        self.text_start = upto;
    }

    fn emit(self: *Scan, from: usize, to: usize, kind: Kind) Allocator.Error!void {
        if (kind == .text) {
            // Leave it pending so adjacent unclassified bytes coalesce.
            return;
        }
        try self.flushText(from);
        try self.push(from, to, kind);
        self.text_start = to;
    }

    // -- scanning ----------------------------------------------------------

    fn match(self: Scan, lit: []const u8) bool {
        if (lit.len == 0) return false;
        if (self.i + lit.len > self.end) return false;
        return std.mem.eql(u8, self.text[self.i .. self.i + lit.len], lit);
    }

    /// True when a comment or string literal starts here. Used to stop a
    /// punctuation run from eating the `//` of a comment.
    fn startsDelimiter(self: Scan) bool {
        for (self.def.line_comment) |lc| if (self.match(lc)) return true;
        for (self.def.line_string) |ls| if (self.match(ls)) return true;
        if (self.def.block_comment) |bc| if (self.match(bc.open)) return true;
        for (self.def.strings) |spec| {
            // A prefixless hashed spec has nothing for `match` to compare, and
            // the '#' run alone is not enough: Swift's `#available` is not a
            // literal, `#"` is.
            if (spec.open.len == 0) {
                if (self.text[self.i] != '#') continue;
                var j = self.i;
                while (j < self.end and self.text[j] == '#') j += 1;
                if (j < self.end and self.text[j] == '"') return true;
                continue;
            }
            if (self.match(spec.open)) return true;
        }
        return false;
    }

    fn inNormal(self: *Scan) Allocator.Error!void {
        const c = self.text[self.i];

        if (c == '\n') {
            self.i += 1;
            // A tag name does not cross a line, so the lookahead cannot leak
            // past a checkpoint boundary and make a resumed lex differ.
            self.expect_tag = false;
            // Flush here, not at the next classified token: without this a run
            // of blank lines coalesces into one `.text` run holding several
            // newlines, and the renderer can no longer group runs into rows.
            try self.flushText(self.i);
            return;
        }
        if (c == ' ' or c == '\t' or c == '\r') {
            while (self.i < self.end) : (self.i += 1) {
                const w = self.text[self.i];
                if (w != ' ' and w != '\t' and w != '\r') break;
            }
            return;
        }

        // Before the literals, because markdown's inline-code spec opens on
        // the same byte: ``` is a fence, not an empty code span.
        if (self.def.fences and self.head) {
            const n = self.opensFence();
            if (n > 0) {
                const start = self.i;
                self.st.fence_char = c;
                self.st.fence_len = n;
                self.st.mode = .fence;
                self.i += n;
                try self.emit(start, self.i, .punct);
                // Classified either way, so the body starts with no text
                // pending. The info string names a language.
                const info = self.i;
                self.toLineEnd();
                if (self.i == info) return;
                const rest = std.mem.trimEnd(u8, self.text[info..self.i], "\r\n");
                const named = std.mem.trim(u8, rest, " \t").len > 0;
                return self.emit(info, self.i, if (named) .type_name else .punct);
            }
        }

        // One table lookup stands in for every opener test below. Most bytes
        // in source are not the start of a comment or a literal.
        if (self.def.delim_start[c]) {
            // Block comments are tried first because Lua's `--[[` opens with
            // its own line comment `--`: the other order takes the opener for
            // a line comment and lets the block run on to the end of the file.
            // No language has the conflict the other way round.
            if (self.def.block_comment) |bc| {
                if (self.match(bc.open)) {
                    const start = self.i;
                    self.i += bc.open.len;
                    self.st.mode = .block_comment;
                    self.st.nest = 1;
                    self.expect_fn = false;
                    return self.inBlockComment(start);
                }
            }

            for (self.def.line_comment) |lc| {
                if (!self.match(lc)) continue;
                if (self.def.comment_word and self.i > 0 and !wordBreak(self.text[self.i - 1])) continue;
                const start = self.i;
                self.toLineEnd();
                return self.emit(start, self.i, .comment);
            }

            for (self.def.line_string) |ls| {
                if (!self.match(ls)) continue;
                const start = self.i;
                self.toLineEnd();
                return self.emit(start, self.i, .string);
            }

            for (self.def.strings, 0..) |spec, si| {
                const start = self.i;
                if (spec.hashed) {
                    if (spec.open.len > 0 and !self.match(spec.open)) continue;
                    var j = self.i + spec.open.len;
                    var hashes: usize = 0;
                    while (j < self.end and self.text[j] == '#') : (j += 1) hashes += 1;
                    // Swift's `#"`: with no prefix the '#' run is the whole
                    // opener, so an empty one would match every plain `"`.
                    if (spec.open.len == 0 and hashes == 0) continue;
                    if (j >= self.end or self.text[j] != '"') continue;
                    if (hashes > std.math.maxInt(u8)) continue;
                    self.i = j + 1;
                    self.st.hashes = @intCast(hashes);
                } else {
                    if (!self.match(spec.open)) continue;
                    if (spec.max_bytes) |limit| if (!self.closesWithin(spec, limit)) continue;
                    self.i += spec.open.len;
                    self.st.hashes = 0;
                }
                self.st.spec = @intCast(si);
                self.st.mode = .string;
                self.expect_fn = false;
                return self.inString(start);
            }
        }

        // Whitespace above returned already, so this is a token: the head of
        // the line ends here unless it is the dash that opens a sequence item.
        const at_head = self.head;
        self.head = self.head and c == '-';

        // Before the number branch, which would take the digits and leave
        // the dot.
        if (self.def.list_marks and at_head and std.ascii.isDigit(c)) {
            if (self.orderedMarkEnd()) |end| {
                const start = self.i;
                self.i = end;
                return self.emit(start, self.i, .list_mark);
            }
        }

        // Before the identifier branch: '_' starts an identifier.
        if (self.def.emphasis and (c == '*' or c == '_' or c == '~')) {
            if (self.emphasisEnd()) |span| {
                const start = self.i;
                self.i = span.end;
                self.expect_fn = false;
                // A run of three or more tildes is a fence, taken above.
                const kind: Kind = if (c == '~')
                    .strikethrough
                else if (span.marks == 2) .strong else .emphasis;
                return self.emit(start, self.i, kind);
            }
        }

        if (std.ascii.isDigit(c)) {
            const start = self.i;
            self.scanNumber();
            self.expect_fn = false;
            return self.emit(start, self.i, if (self.def.prose) .text else .number);
        }

        if (self.def.ident_start[c]) {
            const start = self.i;
            self.i += 1;
            while (self.i < self.end and self.def.ident_cont[self.text[self.i]]) self.i += 1;
            const word = self.text[start..self.i];

            var kind: Kind = .text;
            if (self.def.lookupWord(word)) |k| kind = k;

            // Only a keyword can introduce a function, so this second map is
            // never consulted for an ordinary identifier.
            if (kind == .keyword and self.def.isFnWord(word)) {
                self.expect_fn = true;
                self.expect_fn_body = self.def.isFnBodyWord(word);
            } else if (self.expect_fn and kind == .text) {
                // `function M.foo()`: a qualifier means the declared name is
                // still ahead, so `M` stays an ordinary word and the lookahead
                // survives to reach `foo`.
                if (!self.def.fn_qualified or !self.qualifierFollows()) {
                    kind = .fn_name;
                    self.expect_fn = false;
                    try self.openFn(word, !self.expect_fn_body);
                }
            } else {
                self.expect_fn = false;
                if (self.def.fn_decl_paren and kind == .text and self.appliedToArgs()) {
                    // A call and a declaration are the same shape to a reader,
                    // and every highlighter paints them alike. Only the ones
                    // that pass the whole test open a span.
                    kind = .fn_name;
                    if (!self.throughReceiver(start) and self.argsPrecedeBlock()) {
                        try self.openFn(word, true);
                    }
                }
            }

            // Position beats vocabulary: a word the language reads as a key is
            // one whatever the word is.
            const keyable = switch (self.def.key_words) {
                .none => false,
                .line_head => at_head,
                .anywhere => true,
            };
            if (keyable) {
                if (self.afterKey()) |j| {
                    kind = .type_name;
                    // Only a key whose value is a block names the lines under
                    // it. A scalar's key names one line, which is the line the
                    // reader is already looking at.
                    const next = self.text[j];
                    if (next == '\n' or next == '\r' or next == '#') try self.openFn(word, true);
                }
            }

            // A tag name is an ordinary identifier the markup put after `<`,
            // so it never collides with a keyword lookup.
            if (self.expect_tag) {
                if (kind == .text) kind = .type_name;
                self.expect_tag = false;
            }
            return self.emit(start, self.i, kind);
        }

        // The rest of the line is a marker; the body starts below it.
        if (self.def.block_scalars and self.opensBlockScalar(self.i)) {
            const start = self.i;
            self.st.block_indent = self.indent;
            self.st.mode = .block_scalar;
            self.toLineEnd();
            return self.emit(start, self.i, .punct);
        }

        // A header's cells are labels, drawn rather than lexed: through the
        // keyword lookup, `default` would colour in one table and not the
        // next.
        if (at_head and (self.table == .delim or self.table == .header)) {
            const stop = self.lineEndFrom(self.i);
            if (self.table == .delim) {
                const start = self.i;
                self.i = stop;
                return self.emit(start, self.i, .punct);
            }
            while (self.i < stop) {
                const start = self.i;
                if (self.text[self.i] == '|') {
                    self.i += 1;
                    try self.emit(start, self.i, .punct);
                    continue;
                }
                while (self.i < stop and self.text[self.i] != '|') self.i += 1;
                try self.emit(start, self.i, .strong);
            }
            return;
        }

        // Pipes only: a cell lexes on its own, so inline code in one reads
        // as inline code.
        if (self.table == .row and c == '|') {
            const start = self.i;
            self.i += 1;
            return self.emit(start, self.i, .punct);
        }

        // The `#` count is the depth, and the line is the name - which is
        // what puts the section in the hunk header.
        if (self.def.blocks == .headings and at_head and c == '#') {
            const start = self.i;
            var level: u16 = 0;
            while (self.i < self.end and self.text[self.i] == '#') : (self.i += 1) level += 1;
            // `#hashtag` is a word. A heading's run is followed by a space.
            const spaced = self.i < self.end and (self.text[self.i] == ' ' or self.text[self.i] == '\t');
            if (level <= 6 and spaced) {
                self.toLineEnd();
                const name = std.mem.trim(u8, self.text[start..self.i], "# \t\r\n");
                // The level stands in for the column, and nests.
                self.indent = level;
                if (name.len > 0) try self.openFn(name, true);
                return self.emit(start, self.i, .heading);
            }
            self.i = start;
        }

        // A rule under a line of prose is that line's heading, not a rule.
        // Before the thematic-break branch, which would otherwise take it.
        if (self.def.blocks == .headings and at_head) {
            if (self.setextOver()) |h| {
                const start = self.i;
                self.i = self.lineEndFrom(self.i);
                self.indent = h.level;
                try self.openFn(h.name, true);
                // The section starts at its title, not at the rule under it.
                if (self.fns) |fns| {
                    if (fns.items.len > 0) fns.items[fns.items.len - 1].start_line -|= 1;
                }
                return self.emit(start, self.i, .heading);
            }
        }

        if (self.def.list_marks and at_head) {
            if (c == '>') {
                self.i += 1;
                return self.emit(self.i - 1, self.i, .list_mark);
            }
            if (c == '-' or c == '*' or c == '+') {
                const start = self.i;
                while (self.i < self.end and self.text[self.i] == c) self.i += 1;
                const marks = self.i - start;
                // Three or more alone on a line is a thematic break.
                if (marks >= 3 and self.restOfLineBlank())
                    return self.emit(start, self.i, .punct);
                self.i = start;
                // One mark and then a space. `**bold**` opens a line as
                // often as a list does and is not one.
                const next = if (start + 1 < self.end) self.text[start + 1] else '\n';
                const spaced = next == ' ' or next == '\t' or next == '\n' or next == '\r';
                if (marks == 1 and spaced) {
                    self.i = start + 1;
                    // The box belongs to the bullet, not to the link branch.
                    if (self.taskBoxEnd()) |end| self.i = end;
                    return self.emit(start, self.i, .list_mark);
                }
                // Not a mark. Falls through, and the line reads as prose.
            }
        }

        // Three pieces, so what is between the brackets lexes as itself. The
        // opener is drawn only once the rest of the link is really there, or
        // every `[1]` in prose would be chrome.
        if (self.def.links) {
            const bang = c == '!' and self.i + 1 < self.end and self.text[self.i + 1] == '[';
            if ((c == '[' or bang) and self.linkFollows(self.i + @intFromBool(bang))) {
                const start = self.i;
                self.i += 1 + @as(usize, @intFromBool(bang));
                return self.emit(start, self.i, .punct);
            }
            if (c == ']' and self.i + 1 < self.end and self.text[self.i + 1] == '(') {
                if (self.closeParen(self.i + 2)) |close| {
                    const start = self.i;
                    self.i += 2;
                    try self.emit(start, self.i, .punct);
                    try self.emit(self.i, close, .string);
                    self.i = close;
                    const end = self.i + 1;
                    self.i = end;
                    return self.emit(close, end, .punct);
                }
            }
            // All target, so there is no text half to leave alone.
            if (c == '<') {
                if (self.autolinkEnd()) |end| {
                    const start = self.i;
                    self.i += 1;
                    try self.emit(start, self.i, .punct);
                    try self.emit(self.i, end - 1, .string);
                    self.i = end;
                    return self.emit(end - 1, end, .punct);
                }
            }
        }

        // A table header is the whole bracketed name, and the only structure
        // TOML has. It has a line to itself, which is what tells it from an
        // array element that happens to start one: `[1, 2],` is a value.
        if (self.def.bracket_tables and at_head and c == '[') {
            const start = self.i;
            while (self.i < self.end and self.text[self.i] != '\n' and self.text[self.i] != ']') self.i += 1;
            // `[[products]]` closes with two, and both belong to the name.
            const closed = self.i < self.end and self.text[self.i] == ']';
            while (self.i < self.end and self.text[self.i] == ']') self.i += 1;
            const name = std.mem.trim(u8, self.text[start..self.i], "[]");
            if (closed and name.len > 0 and self.restOfLineBlank()) {
                try self.openFn(name, true);
                return self.emit(start, self.i, .type_name);
            }
            self.i = start;
        }

        // Punctuation, merged into one run. The merge stops at anything that
        // could open a comment or a literal, so `x=//c` still finds the
        // comment.
        const start = self.i;
        while (self.i < self.end) {
            const p = self.text[self.i];
            if (p == '\n' or p == ' ' or p == '\t' or p == '\r') break;
            if (std.ascii.isAlphanumeric(p) or p == '_' or p >= 0x80) break;
            if (self.def.ident_start[p]) break;
            if (self.i != start and self.def.delim_start[p] and self.startsDelimiter()) break;

            if (self.def.blocks == .braces) {
                const opens = p == '{' or (self.def.block_brackets and p == '[');
                const closes = p == '}' or (self.def.block_brackets and p == ']');
                if (opens) {
                    self.st.depth += 1;
                    self.confirmPending();
                } else if (closes) {
                    self.st.depth -= 1;
                    self.closeBraceSpans();
                }
            }
            if (self.expect_fn and self.def.fn_receiver and p == '(') {
                self.skipBalanced();
                continue;
            }
            if (self.def.angle_tags) {
                // `<div` and `</div` both name a tag; any other punctuation
                // ends the lookahead, so `a <= b` does not colour `b`. A bare
                // `a < b` in text content does, which is the price of having
                // no parser - see lang/html.zig.
                self.expect_tag = p == '<' or (p == '/' and self.expect_tag);
            }
            // A qualifier is part of the name's path, so unlike every other
            // punctuation byte it does not end the lookahead.
            if (!(self.def.fn_qualified and (p == '.' or p == ':'))) self.expect_fn = false;
            self.i += 1;
        }
        if (self.i == start) self.i += 1; // never stall
        if (self.def.prose) return self.emit(start, self.i, .text);
        return self.emit(start, self.i, .punct);
    }

    /// std's scalar search is vectorised, so this beats stepping a byte at a
    /// time - and comment-heavy source spends a lot of its time right here.
    /// A YAML block scalar: every line indented past the `|` or `>` that
    /// opened it, whatever it happens to contain.
    ///
    /// Emitted as one string run per line rather than lexed, because the body
    /// is somebody else's language - a shell script in a `run:` step - and
    /// reading `key: value` or a `#` in it as YAML is a guess that is usually
    /// wrong. A blank line stays inside: it is a blank line of the script.
    fn inBlockScalar(self: *Scan) Allocator.Error!void {
        const start = self.i;
        self.toLineEnd();
        const line = std.mem.trimEnd(u8, self.text[start..self.i], "\r\n");
        const blank = std.mem.trim(u8, line, " \t").len == 0;
        if (!blank and self.indent <= self.st.block_indent) {
            // Back out to the parent's level: the block ended before this
            // line, which belongs to the mapping again.
            self.i = start;
            self.st.mode = .normal;
            return self.inNormal();
        }
        return self.emit(start, self.i, .string);
    }

    /// `Title` over `=====` is an H1, and over `-----` an H2.
    ///
    /// Only the rule is coloured. Repainting the title would mean reaching
    /// back into runs a resumed lex never emitted, so it would be bold at some
    /// scroll positions and not others. The name still reaches the hunk
    /// header. Reading backwards is safe; the buffer is whole whatever range
    /// is being lexed.
    fn setextOver(self: Scan) ?struct { level: u16, name: []const u8 } {
        const c = self.text[self.i];
        if (c != '=' and c != '-') return null;
        var j = self.i;
        while (j < self.end and self.text[j] == c) j += 1;
        if (std.mem.trim(u8, self.text[j..self.lineEndFrom(self.i)], " \t\r").len != 0) return null;

        // Under a blank line a rule is a rule.
        const here = std.mem.lastIndexOfScalar(u8, self.text[0..self.i], '\n') orelse return null;
        const from = if (std.mem.lastIndexOfScalar(u8, self.text[0..here], '\n')) |p| p + 1 else 0;
        const name = std.mem.trim(u8, self.text[from..here], " \t\r");
        if (name.len == 0) return null;
        switch (name[0]) {
            '#', '|', '>', '`', '~', '=', '-' => return null,
            else => {},
        }
        return .{ .level = if (c == '=') 1 else 2, .name = name };
    }

    /// One past the `.` or `)` of an ordered marker. Bounded, because a year
    /// at the head of a line is not a list.
    fn orderedMarkEnd(self: Scan) ?usize {
        var j = self.i;
        while (j < self.end and std.ascii.isDigit(self.text[j])) j += 1;
        if (j - self.i > 9 or j >= self.end) return null;
        if (self.text[j] != '.' and self.text[j] != ')') return null;
        j += 1;
        if (j >= self.end) return j;
        return if (isSpace(self.text[j])) j else null;
    }

    /// One past the `]` of the `[ ]` or `[x]` that may follow a bullet.
    fn taskBoxEnd(self: Scan) ?usize {
        var j = self.i;
        while (j < self.end and (self.text[j] == ' ' or self.text[j] == '\t')) j += 1;
        if (j == self.i or j + 2 >= self.end or self.text[j] != '[') return null;
        const mark = self.text[j + 1];
        if (mark != ' ' and mark != 'x' and mark != 'X') return null;
        return if (self.text[j + 2] == ']') j + 3 else null;
    }

    /// A `]` with a `(` after it on the same line, and a `)` to close it.
    fn linkFollows(self: Scan, from: usize) bool {
        var j = from + 1;
        while (j < self.end and self.text[j] != '\n') : (j += 1) {
            if (self.text[j] == '[') return false;
            if (self.text[j] != ']') continue;
            if (j + 1 >= self.end or self.text[j + 1] != '(') return false;
            return self.closeParen(j + 2) != null;
        }
        return false;
    }

    /// The `)` closing a target, counting pairs so a URL with brackets in it
    /// survives. Null past the end of the line.
    fn closeParen(self: Scan, from: usize) ?usize {
        var depth: usize = 1;
        var j = from;
        while (j < self.end and self.text[j] != '\n') : (j += 1) {
            switch (self.text[j]) {
                '(' => depth += 1,
                ')' => {
                    depth -= 1;
                    if (depth == 0) return j;
                },
                else => {},
            }
        }
        return null;
    }

    /// One past the `>` of `<scheme://rest>`. The scheme is what tells it
    /// from the `<img` opening a line of raw HTML.
    fn autolinkEnd(self: Scan) ?usize {
        var j = self.i + 1;
        var scheme = false;
        while (j < self.end and self.text[j] != '\n') : (j += 1) {
            const b = self.text[j];
            if (isSpace(b) or b == '<') return null;
            if (b == ':') scheme = true;
            if (b == '>') return if (scheme and j > self.i + 1) j + 1 else null;
        }
        return null;
    }

    /// Where a span ends and how many marks opened it, or null.
    ///
    /// Three rules, each refusing a false positive rather than catching a true
    /// one: it never crosses a line, so a stray `*` costs one sentence; the
    /// marks hug their words, which tells `2 * 3 * 4` from `*emphasis*`; and
    /// `_` needs a word boundary, without which `some_flag and other_flag` is
    /// one italic span.
    fn emphasisEnd(self: Scan) ?struct { end: usize, marks: usize } {
        const c = self.text[self.i];
        var marks: usize = 0;
        while (self.i + marks < self.end and self.text[self.i + marks] == c) marks += 1;
        if (marks > 2) return null;
        if (c == '_' and self.i > 0 and self.def.ident_cont[self.text[self.i - 1]]) return null;

        const body = self.i + marks;
        if (body >= self.end or isSpace(self.text[body])) return null;

        var j = body;
        while (j < self.end and self.text[j] != '\n') {
            if (self.text[j] != c) {
                j += 1;
                continue;
            }
            var close: usize = 0;
            while (j + close < self.end and self.text[j + close] == c) close += 1;
            const after = j + close;
            // `*a\\*b*` closes on the last mark, not the escaped one.
            if (close != marks or isSpace(self.text[j - 1]) or self.text[j - 1] == '\\') {
                j = after;
                continue;
            }
            if (c == '_' and after < self.end and self.def.ident_cont[self.text[after]]) {
                j = after;
                continue;
            }
            return .{ .end = after, .marks = marks };
        }
        return null;
    }

    /// Every line to the closing fence, as text rather than lexed: the body
    /// is somebody else's language, and this scanner runs one definition at a
    /// time. Unclosed it runs to the end, which is right for a fragment.
    fn inFence(self: *Scan) Allocator.Error!void {
        const start = self.i;
        self.toLineEnd();
        const line = std.mem.trimEnd(u8, self.text[start..self.i], "\r\n");
        const bare = std.mem.trimStart(u8, line, " \t");
        var marks: usize = 0;
        while (marks < bare.len and bare[marks] == self.st.fence_char) marks += 1;
        // Its own character, at least as many, and nothing else.
        if (marks >= self.st.fence_len and std.mem.trim(u8, bare[marks..], " \t").len == 0) {
            self.st.mode = .normal;
            self.st.fence_char = 0;
            self.st.fence_len = 0;
            return self.emit(start, self.i, .punct);
        }
        // Flushed per line: `.text` is the pending run, and a block left
        // pending would be one run holding every newline in it.
        return self.flushText(self.i);
    }

    /// How many backticks or tildes open a fence here, or zero for none.
    fn opensFence(self: Scan) u8 {
        const c = self.text[self.i];
        if (c != '`' and c != '~') return 0;
        var j = self.i;
        while (j < self.end and self.text[j] == c) j += 1;
        const marks = j - self.i;
        return if (marks >= 3) @intCast(@min(marks, 255)) else 0;
    }

    /// `|`, `>` and their modifiers - `|-`, `>+`, `|2` - with nothing after
    /// them but the newline.
    fn opensBlockScalar(self: Scan, from: usize) bool {
        if (self.text[from] != '|' and self.text[from] != '>') return false;
        var j = from + 1;
        while (j < self.end and (self.text[j] == '-' or self.text[j] == '+' or std.ascii.isDigit(self.text[j]))) j += 1;
        while (j < self.end and (self.text[j] == ' ' or self.text[j] == '\t' or self.text[j] == '\r')) j += 1;
        return j >= self.end or self.text[j] == '\n';
    }

    fn toLineEnd(self: *Scan) void {
        const nl = std.mem.indexOfScalarPos(u8, self.text[0..self.end], self.i, '\n');
        self.i = if (nl) |n| n + 1 else self.end;
    }

    fn scanNumber(self: *Scan) void {
        self.i += 1;
        while (self.i < self.end) {
            const c = self.text[self.i];
            if (std.ascii.isAlphanumeric(c) or c == '_') {
                // An exponent sign belongs to the literal; anything else after
                // a letter does not.
                if ((c == 'e' or c == 'E' or c == 'p' or c == 'P') and self.i + 1 < self.end and
                    (self.text[self.i + 1] == '+' or self.text[self.i + 1] == '-'))
                {
                    self.i += 2;
                    continue;
                }
                self.i += 1;
                continue;
            }
            // `1..10` is a range, not a number with two dots.
            if (c == '.' and self.i + 1 < self.end and std.ascii.isDigit(self.text[self.i + 1])) {
                self.i += 1;
                continue;
            }
            break;
        }
    }

    /// Whether `spec` closes on this line within `limit` bytes of the opener.
    fn closesWithin(self: Scan, spec: StringSpec, limit: u16) bool {
        var j = self.i + spec.open.len;
        const stop = @min(self.end, self.i + limit);
        while (j < stop) {
            const c = self.text[j];
            if (c == '\n') return false;
            if (spec.escape) |e| if (c == e) {
                j += 2;
                continue;
            };
            if (j + spec.close.len <= self.end and
                std.mem.eql(u8, self.text[j .. j + spec.close.len], spec.close)) return true;
            j += 1;
        }
        return false;
    }

    fn inBlockComment(self: *Scan, start: usize) Allocator.Error!void {
        const bc = self.def.block_comment.?;
        // Jump between the only bytes that can matter rather than inspecting
        // every byte of the comment body.
        var set_buf: [3]u8 = undefined;
        var set_len: usize = 0;
        set_buf[set_len] = '\n';
        set_len += 1;
        set_buf[set_len] = bc.close[0];
        set_len += 1;
        if (bc.nested) {
            set_buf[set_len] = bc.open[0];
            set_len += 1;
        }
        const set = set_buf[0..set_len];

        while (self.i < self.end) {
            self.i = std.mem.indexOfAnyPos(u8, self.text[0..self.end], self.i, set) orelse {
                self.i = self.end;
                break;
            };
            if (self.text[self.i] == '\n') {
                self.i += 1;
                break;
            }
            if (bc.nested and self.match(bc.open)) {
                self.st.nest +|= 1;
                self.i += bc.open.len;
                continue;
            }
            if (self.match(bc.close)) {
                self.i += bc.close.len;
                self.st.nest -= 1;
                if (self.st.nest == 0) {
                    self.st.mode = .normal;
                    break;
                }
                continue;
            }
            self.i += 1;
        }
        try self.emit(start, self.i, .comment);
    }

    fn inString(self: *Scan, start: usize) Allocator.Error!void {
        const spec = self.def.strings[self.st.spec];
        var set_buf: [3]u8 = undefined;
        var set_len: usize = 0;
        set_buf[set_len] = '\n';
        set_len += 1;
        set_buf[set_len] = spec.close[0];
        set_len += 1;
        if (spec.escape) |e| {
            set_buf[set_len] = e;
            set_len += 1;
        }
        const set = set_buf[0..set_len];

        var closed = false;
        while (self.i < self.end) {
            self.i = std.mem.indexOfAnyPos(u8, self.text[0..self.end], self.i, set) orelse {
                self.i = self.end;
                break;
            };
            const c = self.text[self.i];
            if (c == '\n') {
                self.i += 1;
                // An unterminated single-line literal recovers at the line
                // end. Half-written lines are the common case here, not the
                // exception.
                if (!spec.multiline) self.st.mode = .normal;
                break;
            }
            if (spec.escape) |e| {
                if (c == e) {
                    self.i = @min(self.i + 2, self.end);
                    continue;
                }
            }
            if (self.matchesClose(spec)) {
                self.i += spec.close.len + @as(usize, self.st.hashes);
                self.st.mode = .normal;
                closed = true;
                break;
            }
            self.i += 1;
        }

        // Only a literal that opened and closed in this one step can be a key:
        // a resumed segment has the opener on an earlier line, and an
        // unterminated one recovered at the newline rather than closing.
        if (closed and self.def.key_strings and start + spec.open.len < self.i) {
            if (self.afterKey()) |j| {
                // Only a key whose value is a block can name the lines under
                // it, and `confirmPending` reaches the block only on this
                // line. Testing it here rather than opening a span per key is
                // what keeps a 10k-line config from appending one entry a
                // line for spans that are all dropped again.
                if (self.text[j] == '{' or (self.def.block_brackets and self.text[j] == '[')) {
                    const name = self.text[start + spec.open.len .. self.i - spec.close.len];
                    try self.openFn(name, false);
                }
                return self.emit(start, self.i, .type_name);
            }
        }
        try self.emit(start, self.i, .string);
    }

    /// Nothing but spaces or a comment between here and the end of the line.
    fn restOfLineBlank(self: Scan) bool {
        var j = self.i;
        while (j < self.end and (self.text[j] == ' ' or self.text[j] == '\t' or self.text[j] == '\r')) j += 1;
        if (j >= self.end or self.text[j] == '\n') return true;
        for (self.def.line_comment) |lc| {
            if (std.mem.startsWith(u8, self.text[j..self.end], lc)) return true;
        }
        return false;
    }

    /// The first byte past the `key_sep` that follows the word or literal
    /// which just ended, or null if the next thing on the line is not one.
    fn afterKey(self: Scan) ?usize {
        var j = self.i;
        while (j < self.end and (self.text[j] == ' ' or self.text[j] == '\t')) j += 1;
        if (j >= self.end or self.text[j] != self.def.key_sep) return null;
        j += 1;
        if (self.def.key_sep_spaced) {
            const after = if (j < self.end) self.text[j] else '\n';
            if (after != ' ' and after != '\t' and after != '\n' and after != '\r') return null;
        }
        while (j < self.end and (self.text[j] == ' ' or self.text[j] == '\t')) j += 1;
        return if (j < self.end) j else null;
    }

    fn matchesClose(self: Scan, spec: StringSpec) bool {
        if (!self.match(spec.close)) return false;
        if (!spec.hashed) return true;
        const from = self.i + spec.close.len;
        const to = from + @as(usize, self.st.hashes);
        if (to > self.end) return false;
        for (self.text[from..to]) |c| if (c != '#') return false;
        return true;
    }

    /// Skips a balanced `(...)`, for Go's method receiver.
    fn skipBalanced(self: *Scan) void {
        var open: u32 = 0;
        while (self.i < self.end) {
            const c = self.text[self.i];
            if (c == '\n') return;
            self.i += 1;
            if (c == '(') open += 1;
            if (c == ')') {
                open -= 1;
                if (open == 0) return;
            }
        }
    }

    /// `fn_qualified`: does a '.' or ':' follow the identifier that just
    /// ended? Then it named a table on the way to the function, not the
    /// function.
    fn qualifierFollows(self: Scan) bool {
        return self.i < self.end and (self.text[self.i] == '.' or self.text[self.i] == ':');
    }

    /// `fn_decl_paren`: is the identifier that just ended applied to an
    /// argument list? True for a call as much as for a declaration - it is
    /// what decides the colour, and `argsPrecedeBlock` decides the span.
    fn appliedToArgs(self: *Scan) bool {
        var j = self.i;
        while (j < self.end and (self.text[j] == ' ' or self.text[j] == '\t')) j += 1;
        return j < self.end and self.text[j] == '(';
    }

    /// How far a declaration's argument list may wrap before the lookahead
    /// gives up on it.
    ///
    /// Not the thing that decides a call from a declaration - the tail does
    /// that, and every call shape traced against this rejects on its `;`
    /// whether it wrapped or not. This bounds the cost, and bounds how far a
    /// file being typed into can be misread from one unclosed parenthesis.
    /// Six leaves room for a seven-parameter signature with an annotation on
    /// each: the four-line ones in an ordinary Spring controller sit close
    /// enough to a tighter bound that it would be the bound, rather than the
    /// tail, deciding whether a method gets its name.
    const decl_wrap_lines: u32 = 6;

    /// `fn_decl_paren`: was the identifier that just ended reached through a
    /// receiver? `list.add(x)` is a call whatever follows it, because a method
    /// is never declared through one - so the span is refused and only the
    /// colour is kept.
    ///
    /// Backwards over spaces and tabs but never over a newline, so the `.` of
    /// a chained call broken across lines - `stream\n    .forEach(` - is still
    /// found, and the `.` ending the statement above an ordinary declaration
    /// is not.
    fn throughReceiver(self: Scan, start: usize) bool {
        var j = start;
        while (j > 0) {
            j -= 1;
            const c = self.text[j];
            if (c == ' ' or c == '\t') continue;
            return c == '.';
        }
        return false;
    }

    /// A literal the lookahead stepped over: where it ends, and whether it
    /// ended at its own close rather than at the end of the line.
    const Literal = struct { past: usize, closed: bool };

    /// `fn_decl_paren`: the literal that opens at `j`, or null if none does.
    ///
    /// The lookahead below reads raw bytes, and a `)` or a `{` inside a string
    /// is neither - `format("%s) {", x)` would otherwise close the argument
    /// list early, find a brace behind it, and name the rest of the enclosing
    /// method after `format`. An unclosed literal is reported rather than
    /// skipped over, because the lookahead now crosses lines and everything
    /// past an unterminated quote is a guess: it ends there instead, which is
    /// no span rather than a wrong one.
    ///
    /// Read from `LangDef.strings` rather than from a `'"'` written here, and
    /// with the same first-match-wins order the scanner itself uses, so Java's
    /// `"""` is tried before its `"`. A multiline literal is not followed
    /// across the break either - it is unreachable inside an argument list
    /// that could be a declaration's. Hashed literals - Swift's `#"` - are
    /// declined: no language with `fn_decl_paren` has them, and guessing at
    /// one here would be a second implementation of `matchesClose`.
    fn skipLiteral(self: Scan, j: usize) ?Literal {
        const text = self.text[0..self.end];
        for (self.def.strings) |spec| {
            if (spec.hashed or spec.open.len == 0) continue;
            if (!std.mem.startsWith(u8, text[j..], spec.open)) continue;

            var k = j + spec.open.len;
            while (k < self.end) {
                const c = text[k];
                if (c == '\n') return .{ .past = k, .closed = false };
                if (spec.escape) |e| if (c == e) {
                    k = @min(k + 2, self.end);
                    continue;
                };
                if (std.mem.startsWith(u8, text[k..], spec.close)) {
                    const past = k + spec.close.len;
                    // The byte limit that keeps an apostrophe from painting the
                    // rest of a line applies here too, or `it's` in a trailing
                    // comment would swallow the lookahead.
                    if (spec.max_bytes) |limit| if (past - j > limit) break;
                    return .{ .past = past, .closed = true };
                }
                k += 1;
            }
            // A `max_bytes` literal that did not close is not one - the same
            // rule the scanner applies, so `it's` stays prose.
            if (spec.max_bytes != null) continue;
            return .{ .past = self.end, .closed = false };
        }
        return null;
    }

    /// `fn_decl_paren`: does that argument list close on this line with a block
    /// behind it? This is the whole of the declaration test, and it is a
    /// lookahead rather than the brace-on-the-same-line rule `fn_decl_body`
    /// uses, because in this position that rule is not accurate enough:
    /// `if (isReady(x)) {` puts a call and a block on one line and would name
    /// the block after the call.
    ///
    /// Between the `)` and the `{` only a `throws` clause may stand, so the
    /// tail admits words and the punctuation a type list is written with.
    /// Anything else - the `;` of a statement, the second `)` of the `if`, the
    /// `(` of the real declaration on `@Test(60) void f() {` - is a rejection.
    /// A `->` inside the parentheses never closes them on the line it opens
    /// them, which is what keeps `assertThrows(E.class, () -> {` a call.
    ///
    /// The argument list may wrap, within `decl_wrap_lines`, because a Spring
    /// or JPA signature with an annotation on each parameter does not fit on
    /// one line and refusing those left a controller's methods unnamed. What
    /// discriminates a wrapped signature from a wrapped call is unchanged and
    /// is the tail: `changePassword(a,\n b) throws IOException {` reaches a
    /// brace, `register(a,\n () -> {\n ...\n });` reaches the `;`.
    ///
    /// The tail itself is *not* allowed to wrap, and that asymmetry is load
    /// bearing rather than an omission. `@RequestMapping("/users")` closes its
    /// parentheses with a class declaration on the line below, and a tail that
    /// crossed the break would read the brace ending that declaration as the
    /// annotation's own body. So a brace on its own line - `void f()\n{` - and
    /// a `throws` clause that wraps still name nothing, which is the failure
    /// this is built to make: no span rather than a wrong one, with the
    /// enclosing class still naming the line.
    fn argsPrecedeBlock(self: *Scan) bool {
        var j = self.i;
        while (j < self.end and (self.text[j] == ' ' or self.text[j] == '\t')) j += 1;
        if (j >= self.end or self.text[j] != '(') return false;

        var open: u32 = 0;
        var wrapped: u32 = 0;
        while (j < self.end) {
            if (self.skipLiteral(j)) |lit| {
                // Everything past an unterminated quote is a guess, and the
                // lookahead is about to cross a line on the strength of it.
                if (!lit.closed) return false;
                j = lit.past;
                continue;
            }
            const c = self.text[j];
            if (c == '\n') {
                wrapped += 1;
                if (wrapped > decl_wrap_lines) return false;
            }
            j += 1;
            if (c == '(') open += 1;
            if (c == ')') {
                open -= 1;
                if (open == 0) break;
            }
        } else return false;

        var lines: u32 = 0;
        while (j < self.end) : (j += 1) {
            const c = self.text[j];
            if (c == '{') return true;
            if (c == '\n') {
                // C writes a function's brace on its own line as often as not.
                // One line and no further: two would let a call reach a block
                // below it that it has nothing to do with.
                if (!self.def.fn_block_own_line) return false;
                lines += 1;
                if (lines > 1) return false;
                continue;
            }
            const tail = c == ' ' or c == '\t' or c == '\r' or c == ',' or c == '.' or
                c == '<' or c == '>' or c == '&' or
                std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
            if (!tail) return false;
        }
        return false;
    }

    // -- function spans ----------------------------------------------------

    fn openFn(self: *Scan, name: []const u8, confirmed: bool) Allocator.Error!void {
        const fns = self.fns orelse return;
        const stack = self.stack.?;

        // A sibling at the same level closes the previous one. Without this a
        // bodyless declaration - `fn foo(&self);` in a trait - would stay open
        // and be reported as the enclosing function of everything after it.
        switch (self.def.blocks) {
            // Depth never moves under `none`, so this closes every sibling,
            // which is the whole of what a flat language needs.
            .braces, .none => self.closeBraceSpans(),
            // A heading's level is its column, set before the call.
            .indent, .headings => self.closeIndentSpans(self.indent),
        }

        try fns.append(self.gpa, .{
            .name = name,
            .start_line = self.line,
            .end_line = self.line,
            .depth = self.st.depth,
            .indent = self.indent,
            .confirmed = confirmed,
        });
        try stack.append(self.gpa, @intCast(fns.items.len - 1));
    }

    /// A `fn_decl_body` declaration is a function only if a block opens on its
    /// own line: `const f = () => {` yes, `const email = form.email;` no. The
    /// same-line test is what keeps a later `if (x) {` in the same scope from
    /// confirming a binding that has long since stopped being relevant.
    fn confirmPending(self: *Scan) void {
        const fns = self.fns orelse return;
        const stack = self.stack.?;
        if (stack.items.len == 0) return;
        const top = &fns.items[stack.items[stack.items.len - 1]];
        if (!top.confirmed and top.start_line == self.line) top.confirmed = true;
    }

    fn closeBraceSpans(self: *Scan) void {
        self.closeWhile(self.st.depth, null);
    }

    fn closeIndentSpans(self: *Scan, col: u16) void {
        self.closeWhile(0, col);
    }

    /// Closes every open span that `depth` (braces) or `indent` (indent) has
    /// fallen back to or past.
    fn closeWhile(self: *Scan, depth: i32, indent: ?u16) void {
        const fns = self.fns orelse return;
        const stack = self.stack.?;
        while (stack.items.len > 0) {
            const idx = stack.items[stack.items.len - 1];
            const f = &fns.items[idx];
            const closed = if (indent) |col| f.indent >= col else f.depth >= depth;
            if (!closed) return;
            // The span ends on the previous line: this line already belongs to
            // whatever encloses it.
            f.end_line = if (self.line > f.start_line) self.line - 1 else f.start_line;
            _ = stack.pop();
        }
    }
};

/// Runs overlapping `[lo, hi)`. Binary search for the first, then a walk:
/// runs are sorted and non-overlapping, so this is O(log n + k) per row rather
/// than a scan of the file's runs for every visible line.
pub fn runsIn(runs: []const Run, lo: u32, hi: u32) []const Run {
    var low: usize = 0;
    var high: usize = runs.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (runs[mid].end() <= lo) low = mid + 1 else high = mid;
    }
    const start = low;
    var end = start;
    while (end < runs.len and runs[end].start < hi) end += 1;
    return runs[start..end];
}

const testing = std.testing;

// The files this one is split into; see the note in `ui/app.zig`. Neither has
// tests of its own today, and this is what makes sure the first one added
// actually runs.
test {
    _ = langdef;
    _ = token;
}
const zig_lang = @import("lang/zig.zig");
const rust_lang = @import("lang/rust.zig");
const go_lang = @import("lang/go.zig");
const python_lang = @import("lang/python.zig");
const swift_lang = @import("lang/swift.zig");
const java_lang = @import("lang/java.zig");
const c_lang = @import("lang/c.zig");
const cpp_lang = @import("lang/cpp.zig");
const csharp_lang = @import("lang/csharp.zig");
const lua_lang = @import("lang/lua.zig");
const javascript_lang = @import("lang/javascript.zig");
const typescript_lang = @import("lang/typescript.zig");
const css_lang = @import("lang/css.zig");
const html_lang = @import("lang/html.zig");
const json_lang = @import("lang/json.zig");
const yaml_lang = @import("lang/yaml.zig");
const toml_lang = @import("lang/toml.zig");
const dockerfile_lang = @import("lang/dockerfile.zig");
const shell_lang = @import("lang/shell.zig");
const sql_lang = @import("lang/sql.zig");
const markdown_lang = @import("lang/markdown.zig");

/// Asserts the two invariants every renderer depends on. Called by most tests
/// below rather than tested once, because a new language definition is exactly
/// the kind of change that breaks them somewhere unexpected.
/// What a line is to a table.
pub const Table = enum { none, row, header, delim };

/// `|---|:---:|`, with at least one dash. Anything else is an ordinary row.
fn isDelimRow(line: []const u8) bool {
    var dashes = false;
    for (std.mem.trimEnd(u8, line, " \t\r")) |c| {
        switch (c) {
            '-' => dashes = true,
            '|', ':', ' ', '\t' => {},
            else => return false,
        }
    }
    return dashes;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// What a word may start after: whitespace, or an operator it can follow without one.
fn wordBreak(c: u8) bool {
    return isSpace(c) or c == ';' or c == '&' or c == '|' or c == '(';
}

fn expectTiles(runs: []const Run, text: []const u8, from: u32, to: u32) !void {
    var at = from;
    for (runs) |r| {
        try testing.expectEqual(at, r.start);
        try testing.expect(r.len > 0);
        at = r.end();
        const bytes = text[r.start..r.end()];
        // At most one newline, and only as the last byte.
        if (std.mem.indexOfScalar(u8, bytes, '\n')) |n| {
            try testing.expectEqual(bytes.len - 1, n);
        }
    }
    try testing.expectEqual(to, at);
}

fn kindOf(runs: []const Run, text: []const u8, needle: []const u8) ?Kind {
    const at = std.mem.indexOf(u8, text, needle) orelse return null;
    for (runs) |r| {
        if (r.start <= at and at < r.end()) return r.kind;
    }
    return null;
}

test "runs tile the span and classify zig source" {
    const src =
        \\// a comment
        \\const std = @import("std");
        \\
        \\pub fn add(a: u32, b: u32) u32 {
        \\    return a + b + 42;
        \\}
        \\
    ;
    var lx: Lexer = .init(&zig_lang.def);
    const runs = try lx.lexAll(testing.allocator, src);
    defer testing.allocator.free(runs);

    try expectTiles(runs, src, 0, @intCast(src.len));
    try testing.expectEqual(Kind.comment, kindOf(runs, src, "// a comment").?);
    try testing.expectEqual(Kind.keyword, kindOf(runs, src, "const").?);
    try testing.expectEqual(Kind.string, kindOf(runs, src, "\"std\"").?);
    try testing.expectEqual(Kind.type_name, kindOf(runs, src, "u32").?);
    try testing.expectEqual(Kind.fn_name, kindOf(runs, src, "add").?);
    try testing.expectEqual(Kind.number, kindOf(runs, src, "42").?);
}

test "a blank run of lines does not coalesce into one run" {
    const src = "a\n\n\n\nb\n";
    var lx: Lexer = .init(&zig_lang.def);
    const runs = try lx.lexAll(testing.allocator, src);
    defer testing.allocator.free(runs);

    try expectTiles(runs, src, 0, @intCast(src.len));
    try testing.expectEqual(@as(usize, 5), runs.len);
}

test "zig multiline string literals are strings, not escapes" {
    // Written with escapes rather than a `\\` literal, because the fixture is
    // itself Zig multiline-string syntax and cannot nest.
    const src = "const s =\n    \\\\line one\n    \\\\line two\n;\n";
    var lx: Lexer = .init(&zig_lang.def);
    const runs = try lx.lexAll(testing.allocator, src);
    defer testing.allocator.free(runs);

    try expectTiles(runs, src, 0, @intCast(src.len));
    try testing.expectEqual(Kind.string, kindOf(runs, src, "line one").?);
    try testing.expectEqual(Kind.string, kindOf(runs, src, "line two").?);
}

test "rust nested block comments close at the right depth" {
    const src = "let a = /* outer /* inner */ still */ 1;\n";
    var lx: Lexer = .init(&rust_lang.def);
    const runs = try lx.lexAll(testing.allocator, src);
    defer testing.allocator.free(runs);

    try expectTiles(runs, src, 0, @intCast(src.len));
    try testing.expectEqual(Kind.comment, kindOf(runs, src, "still").?);
    try testing.expectEqual(Kind.number, kindOf(runs, src, "1").?);
}

test "a rust lifetime is not an unterminated char literal" {
    const src = "fn f<'a>(x: &'a str) -> u32 { 7 }\n";
    var lx: Lexer = .init(&rust_lang.def);
    const runs = try lx.lexAll(testing.allocator, src);
    defer testing.allocator.free(runs);

    try expectTiles(runs, src, 0, @intCast(src.len));
    // If the lifetime had opened a literal, everything after it would be one
    // string run and `str` would not be classified.
    try testing.expectEqual(Kind.type_name, kindOf(runs, src, "str").?);
    try testing.expectEqual(Kind.number, kindOf(runs, src, "7").?);
}

test "a rust char literal is still a string" {
    const src = "let c = 'x';\n";
    var lx: Lexer = .init(&rust_lang.def);
    const runs = try lx.lexAll(testing.allocator, src);
    defer testing.allocator.free(runs);
    try testing.expectEqual(Kind.string, kindOf(runs, src, "'x'").?);
}

test "raw strings close only on a matching hash count" {
    const src =
        \\let a = r#"a "quoted" thing"# ;
        \\let b = 1;
        \\
    ;
    var lx: Lexer = .init(&rust_lang.def);
    const runs = try lx.lexAll(testing.allocator, src);
    defer testing.allocator.free(runs);

    try expectTiles(runs, src, 0, @intCast(src.len));
    try testing.expectEqual(Kind.string, kindOf(runs, src, "\"quoted\"").?);
    // The literal ended, so the next line lexes normally.
    try testing.expectEqual(Kind.number, kindOf(runs, src, "1;").?);
}

test "runs tile the span and classify swift source" {
    const src =
        \\/// A doc comment.
        \\@MainActor
        \\final class Tile {
        \\    private let name: String = "hello"
        \\
        \\    func isPressable(_ actionID: Int) -> Bool {
        \\        return actionID > 0
        \\    }
        \\}
        \\
    ;
    var lx: Lexer = .init(&swift_lang.def);
    const runs = try lx.lexAll(testing.allocator, src);
    defer testing.allocator.free(runs);

    try expectTiles(runs, src, 0, @intCast(src.len));
    try testing.expectEqual(Kind.comment, kindOf(runs, src, "/// A doc").?);
    try testing.expectEqual(Kind.keyword, kindOf(runs, src, "func").?);
    try testing.expectEqual(Kind.type_name, kindOf(runs, src, "String").?);
    try testing.expectEqual(Kind.type_name, kindOf(runs, src, "Bool").?);
    try testing.expectEqual(Kind.string, kindOf(runs, src, "\"hello\"").?);
    try testing.expectEqual(Kind.fn_name, kindOf(runs, src, "isPressable").?);
    try testing.expectEqual(Kind.number, kindOf(runs, src, "0").?);
}

test "a swift raw string closes only on a matching hash count" {
    const src =
        \\let a = #"a "quoted" thing"#
        \\let b = 1
        \\
    ;
    var lx: Lexer = .init(&swift_lang.def);
    const runs = try lx.lexAll(testing.allocator, src);
    defer testing.allocator.free(runs);

    try expectTiles(runs, src, 0, @intCast(src.len));
    // The inner quotes do not close it; `"#` does.
    try testing.expectEqual(Kind.string, kindOf(runs, src, "\"quoted\"").?);
    try testing.expectEqual(Kind.number, kindOf(runs, src, "1").?);
}

test "a swift pound directive is not a raw string" {
    const src =
        \\if #available(macOS 14, *) {
        \\    let n = 2
        \\}
        \\
    ;
    var lx: Lexer = .init(&swift_lang.def);
    const runs = try lx.lexAll(testing.allocator, src);
    defer testing.allocator.free(runs);

    try expectTiles(runs, src, 0, @intCast(src.len));
    // A '#' run opens a literal only when a quote follows it.
    try testing.expect(kindOf(runs, src, "#available").? != .string);
    try testing.expectEqual(Kind.number, kindOf(runs, src, "2").?);
}

test "a swift multiline string spans lines and holds bare quotes" {
    const src =
        \\let s = """
        \\line one
        \\a "quoted" word
        \\"""
        \\let n = 3
        \\
    ;
    var lx: Lexer = .init(&swift_lang.def);
    const runs = try lx.lexAll(testing.allocator, src);
    defer testing.allocator.free(runs);

    try expectTiles(runs, src, 0, @intCast(src.len));
    try testing.expectEqual(Kind.string, kindOf(runs, src, "line one").?);
    try testing.expectEqual(Kind.string, kindOf(runs, src, "\"quoted\"").?);
    // The literal ended, so the next line lexes normally.
    try testing.expectEqual(Kind.number, kindOf(runs, src, "3").?);
}

test "runs tile the span and classify java source" {
    const src =
        \\/** A doc comment. */
        \\package app;
        \\
        \\public final class Tile {
        \\    private final String name = "hello";
        \\
        \\    @Override
        \\    public boolean isPressable(int actionID) {
        \\        return actionID > 0;
        \\    }
        \\}
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&java_lang.def);
    const runs = try lx.lexAll(gpa, src);
    defer gpa.free(runs);

    try expectTiles(runs, src, 0, @intCast(src.len));
    try testing.expectEqual(Kind.comment, kindOf(runs, src, "/** A doc").?);
    try testing.expectEqual(Kind.keyword, kindOf(runs, src, "class").?);
    try testing.expectEqual(Kind.type_name, kindOf(runs, src, "String").?);
    try testing.expectEqual(Kind.type_name, kindOf(runs, src, "boolean").?);
    try testing.expectEqual(Kind.string, kindOf(runs, src, "\"hello\"").?);
    try testing.expectEqual(Kind.fn_name, kindOf(runs, src, "Tile").?);
    try testing.expectEqual(Kind.fn_name, kindOf(runs, src, "isPressable").?);
    try testing.expectEqual(Kind.number, kindOf(runs, src, "0;").?);
}

test "a java text block spans lines and holds bare quotes" {
    const src =
        \\String q = """
        \\    a "quoted" thing
        \\    """;
        \\int n = 1;
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&java_lang.def);
    const runs = try lx.lexAll(gpa, src);
    defer gpa.free(runs);

    try expectTiles(runs, src, 0, @intCast(src.len));
    try testing.expectEqual(Kind.string, kindOf(runs, src, "\"quoted\"").?);
    // The block closed, so the line after it lexes normally.
    try testing.expectEqual(Kind.type_name, kindOf(runs, src, "int n").?);
    try testing.expectEqual(Kind.number, kindOf(runs, src, "1;").?);
}

test "runs tile the span and classify lua source" {
    const src =
        \\--[[ a block
        \\     comment ]]
        \\local M = {}
        \\
        \\-- one line
        \\function M.greet(name)
        \\    local greeting = string.format("hello %s", name)
        \\    return #greeting > 0x10 and greeting or nil
        \\end
        \\
        \\return M
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&lua_lang.def);
    const runs = try lx.lexAll(gpa, src);
    defer gpa.free(runs);

    try expectTiles(runs, src, 0, @intCast(src.len));
    // `--[[` has to beat `--`, or the block never closes.
    try testing.expectEqual(Kind.comment, kindOf(runs, src, "a block").?);
    try testing.expectEqual(Kind.comment, kindOf(runs, src, "-- one line").?);
    try testing.expectEqual(Kind.keyword, kindOf(runs, src, "local M").?);
    try testing.expectEqual(Kind.type_name, kindOf(runs, src, "string").?);
    try testing.expectEqual(Kind.string, kindOf(runs, src, "\"hello %s\"").?);
    try testing.expectEqual(Kind.number, kindOf(runs, src, "0x10").?);
    try testing.expectEqual(Kind.keyword, kindOf(runs, src, "end").?);
}

test "a lua long string is raw and spans lines" {
    const src =
        \\local sql = [[
        \\  select 'a', "b" -- not a comment
        \\]]
        \\local n = 1
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&lua_lang.def);
    const runs = try lx.lexAll(gpa, src);
    defer gpa.free(runs);

    try expectTiles(runs, src, 0, @intCast(src.len));
    try testing.expectEqual(Kind.string, kindOf(runs, src, "select").?);
    try testing.expectEqual(Kind.string, kindOf(runs, src, "-- not a comment").?);
    // The literal closed, so the line after it lexes normally.
    try testing.expectEqual(Kind.number, kindOf(runs, src, "1").?);
}

test "lua names a function past the table it hangs off" {
    const src =
        \\local M = {}
        \\
        \\function M.greet(name)
        \\    return name
        \\end
        \\
        \\function M.Session:close()
        \\    self.open = false
        \\end
        \\
        \\local function helper()
        \\    return 1
        \\end
        \\
        \\M.cb = function()
        \\    return 2
        \\end
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&lua_lang.def);
    var st = try lx.structure(gpa, src);
    defer st.deinit(gpa);

    try testing.expectEqualStrings("greet", st.enclosingFn(3).?.name);
    // Every segment but the last is a qualifier, however many there are.
    try testing.expectEqualStrings("close", st.enclosingFn(7).?.name);
    try testing.expectEqualStrings("helper", st.enclosingFn(11).?.name);
    // An anonymous function opens no span, so the binding above it does not
    // acquire a name it never had.
    try testing.expect(st.enclosingFn(15) == null);

    const runs = try lx.lexAll(gpa, src);
    defer gpa.free(runs);
    try expectTiles(runs, src, 0, @intCast(src.len));
    try testing.expectEqual(Kind.fn_name, kindOf(runs, src, "greet").?);
    try testing.expectEqual(Kind.text, kindOf(runs, src, "M.greet").?);
}

test "lua spans close on indentation" {
    const src =
        \\function outer()
        \\    local function inner()
        \\        return 1
        \\    end
        \\    return inner
        \\end
        \\
        \\function after()
        \\    return 2
        \\end
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&lua_lang.def);
    var st = try lx.structure(gpa, src);
    defer st.deinit(gpa);

    try testing.expectEqualStrings("outer", st.enclosingFn(0).?.name);
    try testing.expectEqualStrings("inner", st.enclosingFn(2).?.name);
    // The inner `end` is at the inner declaration's indentation, so the line
    // after it is back in `outer`.
    try testing.expectEqualStrings("outer", st.enclosingFn(4).?.name);
    try testing.expectEqualStrings("after", st.enclosingFn(7).?.name);
}

test "runs tile the span and classify c source" {
    const src =
        \\/* A block comment. */
        \\#include <stdio.h>
        \\#define MAX 0x10
        \\
        \\static const char *name = "hello";
        \\
        \\int main(int argc, char **argv)
        \\{
        \\    // one line
        \\    struct stat st;
        \\    return argc > 1 ? 0 : 'x';
        \\}
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&c_lang.def);
    const runs = try lx.lexAll(gpa, src);
    defer gpa.free(runs);

    try expectTiles(runs, src, 0, @intCast(src.len));
    try testing.expectEqual(Kind.comment, kindOf(runs, src, "/* A block").?);
    try testing.expectEqual(Kind.comment, kindOf(runs, src, "// one line").?);
    // A directive is one word, so it can be a keyword.
    try testing.expectEqual(Kind.keyword, kindOf(runs, src, "#include").?);
    try testing.expectEqual(Kind.keyword, kindOf(runs, src, "#define").?);
    try testing.expectEqual(Kind.type_name, kindOf(runs, src, "char *name").?);
    try testing.expectEqual(Kind.string, kindOf(runs, src, "\"hello\"").?);
    try testing.expectEqual(Kind.string, kindOf(runs, src, "'x'").?);
    try testing.expectEqual(Kind.number, kindOf(runs, src, "0x10").?);
    try testing.expectEqual(Kind.keyword, kindOf(runs, src, "struct").?);
}

test "a c function is named with its brace on the next line" {
    const src =
        \\int main(int argc, char **argv)
        \\{
        \\    return 0;
        \\}
        \\
        \\static void helper(void) {
        \\    puts("same line");
        \\}
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&c_lang.def);
    var st = try lx.structure(gpa, src);
    defer st.deinit(gpa);

    // The brace on its own line is half of all C, and Java's same-line rule
    // would have named neither of these.
    try testing.expectEqualStrings("main", st.enclosingFn(2).?.name);
    try testing.expectEqualStrings("helper", st.enclosingFn(6).?.name);
}

test "a c type declaration does not steal its function's name" {
    const src =
        \\int run(void)
        \\{
        \\    struct stat st;
        \\    union u_t v;
        \\    if (stat("/tmp", &st) < 0)
        \\        return -1;
        \\    return 0;
        \\}
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&c_lang.def);
    var st = try lx.structure(gpa, src);
    defer st.deinit(gpa);

    // `struct stat st;` is ordinary C. With `struct` in `fn_decl` it would
    // open a span at the same depth, close `run`, and take the header from
    // every line under it.
    for (2..7) |line| {
        try testing.expectEqualStrings("run", st.enclosingFn(@intCast(line)).?.name);
    }
}

test "a c call two lines above a block is not a declaration" {
    const src =
        \\void caller(void)
        \\{
        \\    setup(1);
        \\
        \\    {
        \\        int scoped = 2;
        \\    }
        \\}
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&c_lang.def);
    var st = try lx.structure(gpa, src);
    defer st.deinit(gpa);

    // One line of slack and no more: the bare block is two lines below the
    // call, and `setup` must not have claimed it.
    try testing.expectEqualStrings("caller", st.enclosingFn(5).?.name);
}

test "c++ adds its vocabulary to c and names a class" {
    const src =
        \\#include <vector>
        \\
        \\namespace app {
        \\
        \\class Tile : public Shape {
        \\public:
        \\    explicit Tile(std::string name) : name_(std::move(name)) {}
        \\
        \\    bool pressable() const noexcept
        \\    {
        \\        return !name_.empty();
        \\    }
        \\
        \\private:
        \\    std::string name_;
        \\};
        \\
        \\}  // namespace app
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&cpp_lang.def);
    const runs = try lx.lexAll(gpa, src);
    defer gpa.free(runs);

    try expectTiles(runs, src, 0, @intCast(src.len));
    // Inherited from C.
    try testing.expectEqual(Kind.keyword, kindOf(runs, src, "#include").?);
    try testing.expectEqual(Kind.type_name, kindOf(runs, src, "bool").?);
    // Added by C++.
    try testing.expectEqual(Kind.keyword, kindOf(runs, src, "namespace").?);
    try testing.expectEqual(Kind.keyword, kindOf(runs, src, "explicit").?);
    try testing.expectEqual(Kind.keyword, kindOf(runs, src, "noexcept").?);
    try testing.expectEqual(Kind.type_name, kindOf(runs, src, "std").?);

    var st = try lx.structure(gpa, src);
    defer st.deinit(gpa);
    try testing.expectEqualStrings("Tile", st.enclosingFn(5).?.name);
    // A method wins over the class it is in, brace on its own line and all.
    try testing.expectEqualStrings("pressable", st.enclosingFn(10).?.name);
}

test "runs tile the span and classify c# source" {
    const src =
        \\#nullable enable
        \\using System;
        \\
        \\namespace App;
        \\
        \\public sealed record Tile(string Name)
        \\{
        \\    public bool Pressable { get; init; }
        \\
        \\    public async Task<int> RunAsync(int id)
        \\    {
        \\        var path = @"C:\temp";
        \\        return await Task.FromResult(id > 0 ? 1 : 0);
        \\    }
        \\}
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&csharp_lang.def);
    const runs = try lx.lexAll(gpa, src);
    defer gpa.free(runs);

    try expectTiles(runs, src, 0, @intCast(src.len));
    try testing.expectEqual(Kind.keyword, kindOf(runs, src, "#nullable").?);
    try testing.expectEqual(Kind.keyword, kindOf(runs, src, "namespace").?);
    try testing.expectEqual(Kind.keyword, kindOf(runs, src, "record").?);
    try testing.expectEqual(Kind.keyword, kindOf(runs, src, "async").?);
    try testing.expectEqual(Kind.keyword, kindOf(runs, src, "init").?);
    try testing.expectEqual(Kind.type_name, kindOf(runs, src, "Task<int>").?);
    try testing.expectEqual(Kind.type_name, kindOf(runs, src, "var path").?);
    // A verbatim literal: the backslash is an ordinary character, not an
    // escape that would eat the closing quote.
    try testing.expectEqual(Kind.string, kindOf(runs, src, "@\"C:").?);
    try testing.expectEqual(Kind.number, kindOf(runs, src, "0 ?").?);
}

test "c# names a method whose brace is on the next line" {
    const src =
        \\namespace App;
        \\
        \\public class Service
        \\{
        \\    public int Add(int a, int b)
        \\    {
        \\        return a + b;
        \\    }
        \\
        \\    public string Name => "svc";
        \\}
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&csharp_lang.def);
    var st = try lx.structure(gpa, src);
    defer st.deinit(gpa);

    try testing.expectEqualStrings("Add", st.enclosingFn(6).?.name);
    // Between the methods the class is the answer, and the file-scoped
    // namespace is what is left above it.
    try testing.expectEqualStrings("Service", st.enclosingFn(9).?.name);
    try testing.expectEqualStrings("App", st.enclosingFn(1).?.name);
}

test "css hyphenated properties survive as one word" {
    const src =
        \\/* layout */
        \\@media (min-width: 40rem) {
        \\  .card {
        \\    grid-template-columns: 1fr auto;
        \\    display: none;
        \\  }
        \\}
        \\
    ;
    var lx: Lexer = .init(&css_lang.def);
    const runs = try lx.lexAll(testing.allocator, src);
    defer testing.allocator.free(runs);

    try expectTiles(runs, src, 0, @intCast(src.len));
    try testing.expectEqual(Kind.comment, kindOf(runs, src, "/* layout").?);
    try testing.expectEqual(Kind.keyword, kindOf(runs, src, "@media").?);
    // The whole hyphenated name, not `grid` plus punctuation plus `template`.
    try testing.expectEqual(Kind.keyword, kindOf(runs, src, "grid-template-columns").?);
    try testing.expectEqual(Kind.keyword, kindOf(runs, src, "display").?);
    try testing.expectEqual(Kind.type_name, kindOf(runs, src, "none").?);
    try testing.expectEqual(Kind.number, kindOf(runs, src, "40rem").?);
}

test "javascript names arrow functions and holds template literals" {
    const src =
        \\const greet = (name) => {
        \\  return `hi ${name}`;
        \\};
        \\
    ;
    var lx: Lexer = .init(&javascript_lang.def);
    const runs = try lx.lexAll(testing.allocator, src);
    defer testing.allocator.free(runs);

    try expectTiles(runs, src, 0, @intCast(src.len));
    try testing.expectEqual(Kind.keyword, kindOf(runs, src, "const").?);
    // `const` is a `fn_decl` word, so the binding names the hunk.
    try testing.expectEqual(Kind.fn_name, kindOf(runs, src, "greet").?);
    try testing.expectEqual(Kind.keyword, kindOf(runs, src, "return").?);
    // Interpolation stays inside the literal rather than re-entering.
    try testing.expectEqual(Kind.string, kindOf(runs, src, "${name}").?);
}

test "a javascript division is not a literal" {
    const src =
        \\const ratio = width / height / 2;
        \\const ok = 3;
        \\
    ;
    var lx: Lexer = .init(&javascript_lang.def);
    const runs = try lx.lexAll(testing.allocator, src);
    defer testing.allocator.free(runs);

    try expectTiles(runs, src, 0, @intCast(src.len));
    // No `/`-delimited string spec exists, which is why `a / b / c` survives.
    try testing.expectEqual(Kind.number, kindOf(runs, src, "2").?);
    try testing.expectEqual(Kind.number, kindOf(runs, src, "3").?);
}

test "typescript adds the type vocabulary and names an interface" {
    const src =
        \\interface Point {
        \\  x: number;
        \\  y: string;
        \\}
        \\export type Id = string;
        \\
    ;
    var lx: Lexer = .init(&typescript_lang.def);
    const runs = try lx.lexAll(testing.allocator, src);
    defer testing.allocator.free(runs);

    try expectTiles(runs, src, 0, @intCast(src.len));
    try testing.expectEqual(Kind.keyword, kindOf(runs, src, "interface").?);
    try testing.expectEqual(Kind.fn_name, kindOf(runs, src, "Point").?);
    try testing.expectEqual(Kind.type_name, kindOf(runs, src, "number").?);
    // Inherited from javascript.zig rather than restated.
    try testing.expectEqual(Kind.keyword, kindOf(runs, src, "export").?);
}

test "html tags, attributes and comments" {
    const src =
        \\<!-- nav -->
        \\<section class="card" id='main'>
        \\  <my-widget data-x="1"></my-widget>
        \\</section>
        \\
    ;
    var lx: Lexer = .init(&html_lang.def);
    const runs = try lx.lexAll(testing.allocator, src);
    defer testing.allocator.free(runs);

    try expectTiles(runs, src, 0, @intCast(src.len));
    try testing.expectEqual(Kind.comment, kindOf(runs, src, "<!-- nav").?);
    try testing.expectEqual(Kind.type_name, kindOf(runs, src, "section").?);
    // A hyphenated element is one tag name, not three tokens.
    try testing.expectEqual(Kind.type_name, kindOf(runs, src, "my-widget").?);
    try testing.expectEqual(Kind.string, kindOf(runs, src, "\"card\"").?);
    try testing.expectEqual(Kind.string, kindOf(runs, src, "'main'").?);
    // Attribute names stay plain: see the note in lang/html.zig.
    try testing.expectEqual(Kind.text, kindOf(runs, src, "class").?);
}

test "an html closing tag still names its element" {
    const src = "</footer>\n";
    var lx: Lexer = .init(&html_lang.def);
    const runs = try lx.lexAll(testing.allocator, src);
    defer testing.allocator.free(runs);

    try expectTiles(runs, src, 0, @intCast(src.len));
    // `/` extends the lookahead that `<` opened rather than ending it.
    try testing.expectEqual(Kind.type_name, kindOf(runs, src, "footer").?);
}

test "json keys are told apart from their values" {
    const src =
        \\{
        \\  "name": "lgtm",
        \\  "version": 3,
        \\  "private": true,
        \\  "url": "https://example.com/a//b"
        \\}
        \\
    ;
    var lx: Lexer = .init(&json_lang.def);
    const runs = try lx.lexAll(testing.allocator, src);
    defer testing.allocator.free(runs);

    try expectTiles(runs, src, 0, @intCast(src.len));
    try testing.expectEqual(Kind.type_name, kindOf(runs, src, "\"name\"").?);
    try testing.expectEqual(Kind.string, kindOf(runs, src, "\"lgtm\"").?);
    try testing.expectEqual(Kind.number, kindOf(runs, src, "3").?);
    try testing.expectEqual(Kind.keyword, kindOf(runs, src, "true").?);
    // The `//` of a URL is inside the literal before any comment opener is
    // tried, so the value stays one string and the line does not go grey.
    try testing.expectEqual(Kind.string, kindOf(runs, src, "//b").?);
}

test "a json key names the lines under its block" {
    const src =
        \\{
        \\  "scripts": {
        \\    "build": "zig build",
        \\    "test": "zig build test"
        \\  },
        \\  "files": [
        \\    "src",
        \\    "README.md"
        \\  ]
        \\}
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&json_lang.def);
    var st = try lx.structure(gpa, src);
    defer st.deinit(gpa);

    try testing.expectEqualStrings("scripts", st.enclosingFn(2).?.name);
    try testing.expectEqualStrings("scripts", st.enclosingFn(3).?.name);
    // An array is a block too, or every list-valued key would name nothing.
    try testing.expectEqualStrings("files", st.enclosingFn(6).?.name);
    // A scalar key opens no span, so the brace lines outside every block are
    // unnamed rather than named by the key above them.
    try testing.expect(st.enclosingFn(0) == null);
}

test "a json string that is not a key stays a string" {
    const src =
        \\{
        \\  "list": ["a", "b"],
        \\  "note": "key: value"
        \\}
        \\
    ;
    var lx: Lexer = .init(&json_lang.def);
    const runs = try lx.lexAll(testing.allocator, src);
    defer testing.allocator.free(runs);

    try expectTiles(runs, src, 0, @intCast(src.len));
    try testing.expectEqual(Kind.string, kindOf(runs, src, "\"a\"").?);
    // A colon inside the literal is not the one that follows it.
    try testing.expectEqual(Kind.string, kindOf(runs, src, "\"key: value\"").?);
}

test "an unterminated string recovers at the end of the line" {
    const src =
        \\const a = "half written
        \\const b = 5;
        \\
    ;
    var lx: Lexer = .init(&zig_lang.def);
    const runs = try lx.lexAll(testing.allocator, src);
    defer testing.allocator.free(runs);

    try expectTiles(runs, src, 0, @intCast(src.len));
    try testing.expectEqual(Kind.string, kindOf(runs, src, "half written").?);
    // Recovery: the next line is not swallowed by the literal.
    try testing.expectEqual(Kind.keyword, kindOf(runs, src, "const b").?);
    try testing.expectEqual(Kind.number, kindOf(runs, src, "5").?);
}

test "an unclosed block comment leaves the state open without stalling" {
    const src = "fn f() { /* never closed\nmore text\n";
    var lx: Lexer = .init(&rust_lang.def);
    var out: std.ArrayList(Run) = .empty;
    defer out.deinit(testing.allocator);
    const end = try lx.lex(testing.allocator, src, 0, src.len, .{}, &out);

    try expectTiles(out.items, src, 0, @intCast(src.len));
    try testing.expectEqual(State.Mode.block_comment, end.mode);
    try testing.expectEqual(Kind.comment, kindOf(out.items, src, "more text").?);
}

test "a token longer than a run is split, not truncated" {
    const long = "x" ** (max_run_len + 100);
    const src = "const s = \"" ++ long ++ "\";\n";
    var lx: Lexer = .init(&zig_lang.def);
    const runs = try lx.lexAll(testing.allocator, src);
    defer testing.allocator.free(runs);

    try expectTiles(runs, src, 0, @intCast(src.len));
    var string_runs: usize = 0;
    for (runs) |r| {
        if (r.kind == .string) string_runs += 1;
    }
    try testing.expect(string_runs >= 2);
}

/// Builds a file long enough to need several checkpoints, with a block comment
/// and a multi-line string crossing checkpoint boundaries so the resumed state
/// actually matters.
fn longSource(gpa: Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var i: usize = 0;
    while (i < 400) : (i += 1) {
        switch (i % 7) {
            0 => try buf.print(gpa, "pub fn f{d}(x: u32) u32 {{\n", .{i}),
            1 => try buf.appendSlice(gpa, "    const s = \"text\";\n"),
            2 => try buf.appendSlice(gpa, "    // a comment\n"),
            3 => try buf.appendSlice(gpa, "    const m =\n        \\\\multi\n        \\\\line\n    ;\n"),
            4 => try buf.appendSlice(gpa, "    return x + 1;\n"),
            5 => try buf.appendSlice(gpa, "}\n"),
            else => try buf.appendSlice(gpa, "\n"),
        }
    }
    return buf.toOwnedSlice(gpa);
}

test "lexing from a checkpoint matches lexing from the start" {
    const gpa = testing.allocator;
    const src = try longSource(gpa);
    defer gpa.free(src);

    var lx: Lexer = .init(&zig_lang.def);
    var st = try lx.structure(gpa, src);
    defer st.deinit(gpa);
    try testing.expect(st.checkpoints.len > 3);

    const whole = try lx.lexAll(gpa, src);
    defer gpa.free(whole);

    // Every checkpoint must reproduce the tail of the whole-file run list
    // exactly. If the stored state were wrong, a resumed lex would misclassify
    // the first block comment or string it landed inside.
    for (st.checkpoints) |cp| {
        var out: std.ArrayList(Run) = .empty;
        defer out.deinit(gpa);
        _ = try lx.lex(gpa, src, cp.offset, src.len, cp.state, &out);

        var first: usize = 0;
        while (first < whole.len and whole[first].start < cp.offset) first += 1;
        // A run straddling the checkpoint offset cannot happen: checkpoints sit
        // on line starts and runs never cross lines.
        try testing.expectEqual(whole.len - first, out.items.len);
        for (whole[first..], out.items) |a, b| {
            try testing.expectEqual(a.start, b.start);
            try testing.expectEqual(a.len, b.len);
            try testing.expectEqual(a.kind, b.kind);
        }
    }
}

test "checkpoints land every 64 lines and index by line" {
    const gpa = testing.allocator;
    const src = try longSource(gpa);
    defer gpa.free(src);

    var lx: Lexer = .init(&zig_lang.def);
    var st = try lx.structure(gpa, src);
    defer st.deinit(gpa);

    for (st.checkpoints, 0..) |cp, i| {
        try testing.expectEqual(@as(u32, @intCast(i * checkpoint_lines)), cp.line);
    }
    try testing.expectEqual(@as(u32, 0), st.checkpointFor(5).line);
    try testing.expectEqual(@as(u32, 64), st.checkpointFor(64).line);
    try testing.expectEqual(@as(u32, 64), st.checkpointFor(127).line);
    try testing.expectEqual(@as(u32, 128), st.checkpointFor(128).line);
    // Past the end clamps rather than reading out of bounds.
    try testing.expect(st.checkpointFor(1_000_000).line <= st.lines);
}

test "line count matches the buffer's, with and without a trailing newline" {
    const gpa = testing.allocator;
    var lx: Lexer = .init(&zig_lang.def);

    var a = try lx.structure(gpa, "one\ntwo\n");
    defer a.deinit(gpa);
    try testing.expectEqual(@as(u32, 2), a.lines);

    var b = try lx.structure(gpa, "one\ntwo");
    defer b.deinit(gpa);
    try testing.expectEqual(@as(u32, 2), b.lines);

    var c = try lx.structure(gpa, "");
    defer c.deinit(gpa);
    try testing.expectEqual(@as(u32, 0), c.lines);
    try testing.expect(c.enclosingFn(0) == null);
}

test "enclosing function names, including nesting" {
    const src =
        \\const std = @import("std");
        \\
        \\pub fn outer(a: u32) u32 {
        \\    const inner = struct {
        \\        fn helper(b: u32) u32 {
        \\            return b;
        \\        }
        \\    };
        \\    return inner.helper(a);
        \\}
        \\
        \\fn other() void {}
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&zig_lang.def);
    var st = try lx.structure(gpa, src);
    defer st.deinit(gpa);

    try testing.expect(st.enclosingFn(0) == null);
    try testing.expectEqualStrings("outer", st.enclosingFn(3).?.name);
    try testing.expectEqualStrings("helper", st.enclosingFn(5).?.name);
    // Back out of the nested body.
    try testing.expectEqualStrings("outer", st.enclosingFn(8).?.name);
    try testing.expectEqualStrings("other", st.enclosingFn(11).?.name);
}

test "a javascript local binding does not steal its function's name" {
    const src =
        \\const App = () => {
        \\  const handleSubmit = async (e) => {
        \\    const email = form.email;
        \\    setState(email);
        \\    return true;
        \\  };
        \\  return handleSubmit;
        \\};
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&javascript_lang.def);
    var st = try lx.structure(gpa, src);
    defer st.deinit(gpa);

    // Both arrows opened a block on their declaration line, so both count.
    try testing.expectEqualStrings("App", st.enclosingFn(0).?.name);
    try testing.expectEqualStrings("handleSubmit", st.enclosingFn(1).?.name);
    // `const email = form.email;` did not, so it was dropped and every line
    // after it still reports the function it sits in.
    try testing.expectEqualStrings("handleSubmit", st.enclosingFn(2).?.name);
    try testing.expectEqualStrings("handleSubmit", st.enclosingFn(3).?.name);
    try testing.expectEqualStrings("handleSubmit", st.enclosingFn(4).?.name);
    try testing.expectEqualStrings("App", st.enclosingFn(6).?.name);
    for (st.fns) |f| try testing.expect(!std.mem.eql(u8, f.name, "email"));
}

test "java names methods that no keyword introduces" {
    const src =
        \\package app;
        \\
        \\public class Tile {
        \\    private int count = 0;
        \\
        \\    public Tile(int count) {
        \\        this.count = count;
        \\    }
        \\
        \\    public static void main(String[] args) {
        \\        System.out.println(count);
        \\    }
        \\}
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&java_lang.def);
    var st = try lx.structure(gpa, src);
    defer st.deinit(gpa);

    try testing.expect(st.enclosingFn(0) == null);
    // Between the members, the class is still better than nothing.
    try testing.expectEqualStrings("Tile", st.enclosingFn(3).?.name);
    // A constructor is a declaration by the same shape as a method.
    try testing.expectEqualStrings("Tile", st.enclosingFn(6).?.name);
    try testing.expectEqualStrings("main", st.enclosingFn(9).?.name);
    try testing.expectEqualStrings("main", st.enclosingFn(10).?.name);
    // `println` is a call through a receiver and opened no span of its own.
    for (st.fns) |f| try testing.expect(!std.mem.eql(u8, f.name, "println"));
}

test "a java call does not steal its method's name" {
    const src =
        \\class Repo {
        \\    void save(Row row) {
        \\        validate(row);
        \\        rows.forEach(r -> {
        \\            store.put(r);
        \\        });
        \\        assertThrows(IOException.class, () -> {
        \\            flush();
        \\        });
        \\    }
        \\}
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&java_lang.def);
    var st = try lx.structure(gpa, src);
    defer st.deinit(gpa);

    // `validate(row);` opened no block on its line, so it was dropped.
    try testing.expectEqualStrings("save", st.enclosingFn(2).?.name);
    // Both lambdas open a block on the call's line. The receiver guard covers
    // `rows.forEach`, the `->` guard covers the unqualified `assertThrows`.
    try testing.expectEqualStrings("save", st.enclosingFn(4).?.name);
    try testing.expectEqualStrings("save", st.enclosingFn(7).?.name);
    for (st.fns) |f| {
        try testing.expect(!std.mem.eql(u8, f.name, "validate"));
        try testing.expect(!std.mem.eql(u8, f.name, "forEach"));
        try testing.expect(!std.mem.eql(u8, f.name, "assertThrows"));
    }
}

test "a java brace inside a string does not open a method" {
    // The lookahead reads raw bytes, so the `) {` in the format string used to
    // close the argument list early and name every line after it `format`. The
    // span it opened was never entered - the brace depth had not moved - so it
    // ran to the end of the enclosing method.
    const src =
        \\class X {
        \\    void b(String x) {
        \\        String s = format("%s) {", x);
        \\        logger.info("done) {} rows", 3);
        \\        realWork();
        \\    }
        \\}
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&java_lang.def);
    var st = try lx.structure(gpa, src);
    defer st.deinit(gpa);

    for (2..5) |li| {
        try testing.expectEqualStrings("b", st.enclosingFn(@intCast(li)).?.name);
    }
    for (st.fns) |f| {
        try testing.expect(!std.mem.eql(u8, f.name, "format"));
        try testing.expect(!std.mem.eql(u8, f.name, "info"));
    }
}

test "a java string in the parameter list does not cost the method its span" {
    // The other half of the same rule, and the reason the lookahead skips a
    // literal rather than stopping at one: an annotated parameter is ordinary
    // Spring, and refusing every signature that holds a quote would lose the
    // name of most of a controller.
    const src =
        \\class Api {
        \\    public void handle(@RequestParam("id") String id) {
        \\        use(id);
        \\    }
        \\}
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&java_lang.def);
    var st = try lx.structure(gpa, src);
    defer st.deinit(gpa);

    try testing.expectEqualStrings("handle", st.enclosingFn(2).?.name);
}

test "a java signature may wrap, and a wrapped call still may not" {
    // A parameter per line is what an annotated Spring or JPA signature looks
    // like, and the whole method used to go unnamed for it.
    const src =
        \\class Api {
        \\    public Response changePassword(@RequestParam String current,
        \\                                   @RequestParam String next) throws IOException {
        \\        service.change(current, next);
        \\    }
        \\
        \\    void wide() {
        \\        register("click",
        \\                 handler,
        \\                 () -> {
        \\                     fire();
        \\                 });
        \\    }
        \\}
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&java_lang.def);
    var st = try lx.structure(gpa, src);
    defer st.deinit(gpa);

    // The continuation line and the body both belong to the method.
    try testing.expectEqualStrings("changePassword", st.enclosingFn(2).?.name);
    try testing.expectEqualStrings("changePassword", st.enclosingFn(3).?.name);
    // The call wraps too, and closes on a `;`. That tail is what separates the
    // two, not the number of lines either of them takes.
    try testing.expectEqualStrings("wide", st.enclosingFn(10).?.name);
    for (st.fns) |f| try testing.expect(!std.mem.eql(u8, f.name, "register"));
}

test "a java annotation does not take the declaration below it" {
    // Why the tail may not wrap even though the argument list may: this
    // annotation closes its parentheses with a class on the next line, and a
    // tail that crossed the break would find that class's brace and read the
    // whole type as the annotation's body.
    const src =
        \\@RequestMapping("/users")
        \\public class UserController {
        \\    void get() {
        \\    }
        \\}
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&java_lang.def);
    var st = try lx.structure(gpa, src);
    defer st.deinit(gpa);

    try testing.expectEqualStrings("UserController", st.enclosingFn(1).?.name);
    try testing.expectEqualStrings("get", st.enclosingFn(2).?.name);
    for (st.fns) |f| try testing.expect(!std.mem.eql(u8, f.name, "RequestMapping"));
}

test "a java signature wrapped past the bound names nothing" {
    // The documented failure, kept as a test so the bound is a decision rather
    // than an accident: the class still names the lines, which is the answer
    // this degrades to everywhere else.
    const src =
        \\class Wide {
        \\    void far(int a,
        \\             int b,
        \\             int c,
        \\             int d,
        \\             int e,
        \\             int f,
        \\             int g,
        \\             int h) {
        \\        use(a);
        \\    }
        \\}
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&java_lang.def);
    var st = try lx.structure(gpa, src);
    defer st.deinit(gpa);

    try testing.expectEqualStrings("Wide", st.enclosingFn(9).?.name);
    for (st.fns) |f| try testing.expect(!std.mem.eql(u8, f.name, "far"));
}

test "a java receiver never introduces a declaration" {
    // Valid Java has no line where a qualified call closes its parentheses and
    // a block follows - `if (a.b(c)) {` is rejected by the `)` the `if` adds.
    // A file being typed into has plenty, and this is the guard that makes the
    // outcome not depend on that: a method is never declared through a
    // receiver, whatever the rest of the line is doing.
    const src =
        \\class X {
        \\    void c(int n) {
        \\        obj.make(n) {
        \\        }
        \\    }
        \\}
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&java_lang.def);
    var st = try lx.structure(gpa, src);
    defer st.deinit(gpa);

    try testing.expectEqualStrings("c", st.enclosingFn(2).?.name);
    for (st.fns) |f| try testing.expect(!std.mem.eql(u8, f.name, "make"));
}

test "a java control-flow block is not a method" {
    const src =
        \\class Loop {
        \\    void run(int n) {
        \\        for (int i = 0; i < n; i++) {
        \\            if (i > 2) {
        \\                break;
        \\            }
        \\        }
        \\        while (n-- > 0) {
        \\            n = n;
        \\        }
        \\    }
        \\}
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&java_lang.def);
    var st = try lx.structure(gpa, src);
    defer st.deinit(gpa);

    // Every one of these opens a block, and none of them is a declaration:
    // `for`, `if` and `while` are keywords, so no candidate is ever raised.
    try testing.expectEqualStrings("run", st.enclosingFn(4).?.name);
    try testing.expectEqualStrings("run", st.enclosingFn(8).?.name);
    try testing.expectEqual(@as(usize, 2), st.fns.len);
}

test "a truncated function still names its lines" {
    // Exactly what a file looks like mid-write: the body never closes.
    const src =
        \\pub fn halfWritten(a: u32) u32 {
        \\    const x = a + 1;
        \\    if (x > 2) {
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&zig_lang.def);
    var st = try lx.structure(gpa, src);
    defer st.deinit(gpa);

    try testing.expectEqualStrings("halfWritten", st.enclosingFn(1).?.name);
    try testing.expectEqualStrings("halfWritten", st.enclosingFn(2).?.name);
}

test "unbalanced closing braces do not misplace later functions" {
    // More closes than opens: the depth goes negative and must not trap or
    // leave a stale span open.
    const src =
        \\    }
        \\}
        \\}
        \\fn after() void {
        \\    return;
        \\}
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&zig_lang.def);
    var st = try lx.structure(gpa, src);
    defer st.deinit(gpa);

    try testing.expect(st.enclosingFn(0) == null);
    try testing.expectEqualStrings("after", st.enclosingFn(4).?.name);
}

test "a bodyless declaration does not adopt its siblings" {
    const src =
        \\trait T {
        \\    fn first(&self);
        \\    fn second(&self);
        \\}
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&rust_lang.def);
    var st = try lx.structure(gpa, src);
    defer st.deinit(gpa);

    try testing.expectEqualStrings("first", st.enclosingFn(1).?.name);
    try testing.expectEqualStrings("second", st.enclosingFn(2).?.name);
}

test "go methods are named past their receiver" {
    const src =
        \\package main
        \\
        \\func (s *Server) Handle(w int) error {
        \\    return nil
        \\}
        \\
        \\func plain() {
        \\    x := `raw
        \\    string`
        \\    _ = x
        \\}
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&go_lang.def);
    var st = try lx.structure(gpa, src);
    defer st.deinit(gpa);

    try testing.expectEqualStrings("Handle", st.enclosingFn(3).?.name);
    try testing.expectEqualStrings("plain", st.enclosingFn(9).?.name);

    const runs = try lx.lexAll(gpa, src);
    defer gpa.free(runs);
    try expectTiles(runs, src, 0, @intCast(src.len));
    try testing.expectEqual(Kind.string, kindOf(runs, src, "string`").?);
}

test "python spans close on indentation" {
    const src =
        \\class Thing:
        \\    def method(self):
        \\        """docstring
        \\        still a docstring: def not_a_function():
        \\        """
        \\        return 1
        \\
        \\    def other(self):
        \\        pass
        \\
        \\def top():
        \\    return 2
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&python_lang.def);
    var st = try lx.structure(gpa, src);
    defer st.deinit(gpa);

    try testing.expectEqualStrings("Thing", st.enclosingFn(0).?.name);
    try testing.expectEqualStrings("method", st.enclosingFn(5).?.name);
    // The `def` inside the docstring must not open a span.
    try testing.expectEqualStrings("method", st.enclosingFn(3).?.name);
    try testing.expectEqualStrings("other", st.enclosingFn(8).?.name);
    try testing.expectEqualStrings("top", st.enclosingFn(11).?.name);

    const runs = try lx.lexAll(gpa, src);
    defer gpa.free(runs);
    try expectTiles(runs, src, 0, @intCast(src.len));
    try testing.expectEqual(Kind.string, kindOf(runs, src, "docstring").?);
}

test "python comments and single quotes" {
    const src = "x = 'a'  # y = 'b'\nz = 2\n";
    const gpa = testing.allocator;
    var lx: Lexer = .init(&python_lang.def);
    const runs = try lx.lexAll(gpa, src);
    defer gpa.free(runs);

    try expectTiles(runs, src, 0, @intCast(src.len));
    try testing.expectEqual(Kind.string, kindOf(runs, src, "'a'").?);
    try testing.expectEqual(Kind.comment, kindOf(runs, src, "# y").?);
    try testing.expectEqual(Kind.number, kindOf(runs, src, "2").?);
}

test "a comment opener glued to punctuation is still a comment" {
    const src = "x=//c\ny=1;\n";
    const gpa = testing.allocator;
    var lx: Lexer = .init(&zig_lang.def);
    const runs = try lx.lexAll(gpa, src);
    defer gpa.free(runs);

    try expectTiles(runs, src, 0, @intCast(src.len));
    try testing.expectEqual(Kind.comment, kindOf(runs, src, "//c").?);
}

test "a range is not one number" {
    const src = "for (0..10) |i| {}\n";
    const gpa = testing.allocator;
    var lx: Lexer = .init(&zig_lang.def);
    const runs = try lx.lexAll(gpa, src);
    defer gpa.free(runs);

    try expectTiles(runs, src, 0, @intCast(src.len));
    try testing.expectEqual(Kind.punct, kindOf(runs, src, "..").?);
    try testing.expectEqual(Kind.number, kindOf(runs, src, "10").?);
}

test "structure mode allocates nothing for runs" {
    // Same scanner, no run list: this is the pass that runs over whole files.
    const gpa = testing.allocator;
    const src = try longSource(gpa);
    defer gpa.free(src);

    var lx: Lexer = .init(&zig_lang.def);
    var st = try lx.structure(gpa, src);
    defer st.deinit(gpa);
    try testing.expect(st.fns.len > 10);
    for (st.fns) |f| try testing.expect(f.end_line >= f.start_line);
}

test "a yaml key is the first word on its line and nothing else is" {
    const src =
        \\# a compose file
        \\version: "3.9"
        \\services:
        \\  web:
        \\    image: nginx:alpine
        \\    ports:
        \\      - "8080:80"
        \\    environment:
        \\      - KEY=value
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&yaml_lang.def);
    const runs = try lx.lexAll(gpa, src);
    defer gpa.free(runs);

    try expectTiles(runs, src, 0, @intCast(src.len));
    try testing.expectEqual(Kind.type_name, kindOf(runs, src, "version").?);
    try testing.expectEqual(Kind.type_name, kindOf(runs, src, "services").?);
    try testing.expectEqual(Kind.type_name, kindOf(runs, src, "image").?);
    try testing.expectEqual(Kind.string, kindOf(runs, src, "\"3.9\"").?);
    // The colon in a value is punctuation. Reading it as a key is what would
    // paint the tag of every image and the port of every mapping.
    try testing.expectEqual(Kind.text, kindOf(runs, src, "nginx").?);
    try testing.expectEqual(Kind.comment, kindOf(runs, src, "# a compose file").?);
    // Past the sequence dash, the item's own key still heads the line.
    try testing.expectEqual(Kind.string, kindOf(runs, src, "\"8080:80\"").?);
}

test "a yaml key beats the word it is spelled with" {
    // `on:` heads most workflow files. As a boolean it would be the wrong
    // colour and would name none of the lines under it.
    const src =
        \\name: ci
        \\on:
        \\  push:
        \\    branches: [main]
        \\jobs:
        \\  build:
        \\    runs-on: ubuntu-latest
        \\    steps:
        \\      - run: zig build test
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&yaml_lang.def);
    const runs = try lx.lexAll(gpa, src);
    defer gpa.free(runs);
    try expectTiles(runs, src, 0, @intCast(src.len));
    try testing.expectEqual(Kind.type_name, kindOf(runs, src, "on").?);
    // One word, because a dash continues an identifier here.
    try testing.expectEqual(Kind.type_name, kindOf(runs, src, "runs-on").?);

    var st = try lx.structure(gpa, src);
    defer st.deinit(gpa);
    // A key whose value is a block names the lines under it; a key with a
    // scalar value names only its own line, which the reader can already see.
    try testing.expectEqualStrings("push", st.enclosingFn(2).?.name);
    try testing.expectEqualStrings("build", st.enclosingFn(6).?.name);
    try testing.expectEqualStrings("steps", st.enclosingFn(8).?.name);
}

test "a dockerfile names its stages" {
    const src =
        \\# build it
        \\FROM golang:1.22 AS builder
        \\WORKDIR /src
        \\RUN go build -o app .
        \\
        \\FROM alpine:3.19 AS runtime
        \\RUN mkdir -p ${TARGET}/bin && chmod 755 ${TARGET}
        \\COPY --from=builder /src/app /app
        \\ENTRYPOINT ["/app"]
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&dockerfile_lang.def);
    const runs = try lx.lexAll(gpa, src);
    defer gpa.free(runs);

    try expectTiles(runs, src, 0, @intCast(src.len));
    try testing.expectEqual(Kind.keyword, kindOf(runs, src, "FROM").?);
    try testing.expectEqual(Kind.keyword, kindOf(runs, src, "ENTRYPOINT").?);
    try testing.expectEqual(Kind.comment, kindOf(runs, src, "# build it").?);
    try testing.expectEqual(Kind.string, kindOf(runs, src, "\"/app\"").?);

    // The only structure a Dockerfile has, and the one a hunk header wants:
    // which stage a line belongs to. A stage ends where the next begins.
    var st = try lx.structure(gpa, src);
    defer st.deinit(gpa);
    try testing.expectEqualStrings("builder", st.enclosingFn(3).?.name);
    // The brace of a shell expansion is not a scope: counted as one it closed
    // the stage on the line below it.
    try testing.expectEqualStrings("runtime", st.enclosingFn(8).?.name);
}

test "sql ignores case and names what a statement creates" {
    const src =
        \\/* users */
        \\CREATE TABLE users (id Bigint PRIMARY KEY, note text);
        \\Select "a--b", count(*) from users where note = 'it''s
        \\two lines';
        \\
        \\create or replace procedure touch_user(p_id in out number) is
        \\  type t_row is record (id number);
        \\begin
        \\  update users set note = 'x' where id = p_id; -- done
        \\end;
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&sql_lang.def);
    const runs = try lx.lexAll(gpa, src);
    defer gpa.free(runs);

    try expectTiles(runs, src, 0, @intCast(src.len));
    try testing.expectEqual(Kind.comment, kindOf(runs, src, "/* users */").?);
    try testing.expectEqual(Kind.keyword, kindOf(runs, src, "CREATE").?);
    try testing.expectEqual(Kind.keyword, kindOf(runs, src, "Select").?);
    try testing.expectEqual(Kind.keyword, kindOf(runs, src, "KEY").?);
    try testing.expectEqual(Kind.type_name, kindOf(runs, src, "Bigint").?);
    try testing.expectEqual(Kind.keyword, kindOf(runs, src, "count").?);
    try testing.expectEqual(Kind.fn_name, kindOf(runs, src, "users (").?);
    // A quoted identifier, not a comment.
    try testing.expectEqual(Kind.string, kindOf(runs, src, "a--b").?);
    // A string may cross a line, and `''` does not end it early.
    try testing.expectEqual(Kind.string, kindOf(runs, src, "s\ntwo lines'").?);
    try testing.expectEqual(Kind.comment, kindOf(runs, src, "-- done").?);

    var st = try lx.structure(gpa, src);
    defer st.deinit(gpa);
    try testing.expectEqualStrings("users", st.enclosingFn(2).?.name);
    try testing.expectEqualStrings("touch_user", st.enclosingFn(6).?.name);
    try testing.expectEqualStrings("touch_user", st.enclosingFn(8).?.name);
}

test "markdown headings are the outline, and they nest by level" {
    const src =
        \\# Config
        \\
        \\prose under the top.
        \\
        \\## `[keys]`
        \\
        \\more prose.
        \\
        \\### one deeper
        \\
        \\deepest.
        \\
        \\## `[nav]`
        \\
        \\back out one.
        \\
        \\# Another top
        \\
        \\and out entirely.
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&markdown_lang.def);
    const runs = try lx.lexAll(gpa, src);
    defer gpa.free(runs);
    try expectTiles(runs, src, 0, @intCast(src.len));
    try testing.expectEqual(Kind.heading, kindOf(runs, src, "# Config").?);

    var st = try lx.structure(gpa, src);
    defer st.deinit(gpa);
    try testing.expectEqualStrings("Config", st.enclosingFn(2).?.name);
    // The innermost heading wins, and a shallower one closes the deeper.
    try testing.expectEqualStrings("`[keys]`", st.enclosingFn(6).?.name);
    try testing.expectEqualStrings("one deeper", st.enclosingFn(10).?.name);
    try testing.expectEqualStrings("`[nav]`", st.enclosingFn(14).?.name);
    try testing.expectEqualStrings("Another top", st.enclosingFn(18).?.name);
}

test "a hash that is not a heading is not one" {
    const src =
        \\#hashtag is a word
        \\####### seven is too many
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&markdown_lang.def);
    const runs = try lx.lexAll(gpa, src);
    defer gpa.free(runs);
    try expectTiles(runs, src, 0, @intCast(src.len));
    try testing.expect(kindOf(runs, src, "hashtag").? != .heading);

    var st = try lx.structure(gpa, src);
    defer st.deinit(gpa);
    try testing.expect(st.enclosingFn(0) == null);
}

test "a backtick in prose does not paint the paragraph" {
    const src =
        \\Use `zig build` to compile.
        \\
        \\A stray ` here, and then a great deal of ordinary prose that runs on and
        \\on past any reasonable length for a code span, which is exactly the case
        \\a lone backtick in a sentence is.
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&markdown_lang.def);
    const runs = try lx.lexAll(gpa, src);
    defer gpa.free(runs);
    try expectTiles(runs, src, 0, @intCast(src.len));
    try testing.expectEqual(Kind.string, kindOf(runs, src, "zig build").?);
    // A comma is a comma. Dimming every one speckles a paragraph.
    try testing.expectEqual(Kind.text, kindOf(runs, src, ", and then").?);
    // The stray one gave up, so the sentence after it is still prose.
    try testing.expectEqual(Kind.text, kindOf(runs, src, "ordinary prose").?);
}

test "a fenced block is not lexed, and only its own fence closes it" {
    const src =
        \\Before.
        \\
        \\~~~zig
        \\// # not a heading
        \\const x = "not a string to us";
        \\```
        \\- not a bullet
        \\~~~
        \\
        \\After.
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&markdown_lang.def);
    const runs = try lx.lexAll(gpa, src);
    defer gpa.free(runs);
    try expectTiles(runs, src, 0, @intCast(src.len));

    // The info string names a language; the body is nobody's.
    try testing.expectEqual(Kind.type_name, kindOf(runs, src, "zig\n").?);
    try testing.expectEqual(Kind.text, kindOf(runs, src, "# not a heading").?);
    try testing.expectEqual(Kind.text, kindOf(runs, src, "not a string to us").?);
    // A backtick fence inside a tilde one is a line of the block.
    try testing.expectEqual(Kind.text, kindOf(runs, src, "- not a bullet").?);

    var st = try lx.structure(gpa, src);
    defer st.deinit(gpa);
    try testing.expect(st.enclosingFn(3) == null);
}

test "an unclosed fence runs to the end, because a hunk is a fragment" {
    const src =
        \\```
        \\half a block, cut off by the hunk
        \\# still not a heading
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&markdown_lang.def);
    const runs = try lx.lexAll(gpa, src);
    defer gpa.free(runs);
    try expectTiles(runs, src, 0, @intCast(src.len));
    try testing.expectEqual(Kind.text, kindOf(runs, src, "# still not").?);
}

test "bullets and rules are marks, and the prose after them is prose" {
    const src =
        \\- one
        \\* two
        \\+ three
        \\> quoted
        \\
        \\---
        \\
        \\after the rule
        \\
        \\**Read what your agent wrote - before you say LGTM.**
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&markdown_lang.def);
    const runs = try lx.lexAll(gpa, src);
    defer gpa.free(runs);
    try expectTiles(runs, src, 0, @intCast(src.len));
    try testing.expectEqual(Kind.punct, kindOf(runs, src, "---").?);
    // A rule is chrome and stays with the pipes; a marker is not.
    try testing.expectEqual(Kind.list_mark, kindOf(runs, src, "* two").?);
    // `**bold**` opens a line as often as a list does, and is not a list.
    try testing.expectEqual(Kind.strong, kindOf(runs, src, "**Read what").?);
    try testing.expectEqual(Kind.list_mark, kindOf(runs, src, ">").?);
    try testing.expectEqual(Kind.text, kindOf(runs, src, "one").?);
    try testing.expectEqual(Kind.text, kindOf(runs, src, "after the rule").?);
}

test "emphasis is bold and italic, and refuses everything that only looks like it" {
    const src =
        \\**bold text** and _italic text_ in a sentence.
        \\
        \\some_flag and other_flag are two identifiers.
        \\
        \\A stray * in prose, and 2 * 3 * 4 is arithmetic.
        \\
        \\Not * this * either, because the marks do not hug the words.
        \\
        \\- a bullet, still a bullet
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&markdown_lang.def);
    const runs = try lx.lexAll(gpa, src);
    defer gpa.free(runs);
    try expectTiles(runs, src, 0, @intCast(src.len));

    try testing.expectEqual(Kind.strong, kindOf(runs, src, "bold text").?);
    try testing.expectEqual(Kind.emphasis, kindOf(runs, src, "italic text").?);
    // The word-boundary rule, which is the whole reason this is not a spec.
    try testing.expectEqual(Kind.text, kindOf(runs, src, "flag and other").?);
    // Marks that do not hug their words are not marks.
    try testing.expectEqual(Kind.text, kindOf(runs, src, "3 * 4").?);
    try testing.expectEqual(Kind.text, kindOf(runs, src, "this * either").?);
    // A stray one gives up at the end of its line rather than the file.
    try testing.expectEqual(Kind.text, kindOf(runs, src, "a bullet, still").?);
    try testing.expectEqual(Kind.list_mark, kindOf(runs, src, "- a bullet").?);
}

test "a number in a sentence is prose, not a literal" {
    // A URL's digits painted a different colour from its letters is the tool
    // asserting something about a link that is not true.
    const src =
        \\<img width="1400" src="https://host/assets/0eb27774-9c64-43c2-ba22" />
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&markdown_lang.def);
    const runs = try lx.lexAll(gpa, src);
    defer gpa.free(runs);
    try expectTiles(runs, src, 0, @intCast(src.len));
    try testing.expectEqual(Kind.text, kindOf(runs, src, "1400").?);
    try testing.expectEqual(Kind.text, kindOf(runs, src, "0eb27774").?);
    try testing.expectEqual(Kind.text, kindOf(runs, src, "9c64").?);
    // And a real language still has numbers.
    var zl: Lexer = .init(&zig_lang.def);
    const zsrc = "const n = 1400;\n";
    const zruns = try zl.lexAll(gpa, zsrc);
    defer gpa.free(zruns);
    try testing.expectEqual(Kind.number, kindOf(zruns, zsrc, "1400").?);
}

test "a table is pipes, a rule and a header row" {
    const src =
        \\Before.
        \\
        \\| Setting | Default | What it does |
        \\|---|---|:--:|
        \\| `comments` | `"marker"` | the gutter dot alone |
        \\
        \\| pipes | but no rule under them
        \\
        \\| Second | table |
        \\|---|---|
        \\| back | in one |
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&markdown_lang.def);
    const runs = try lx.lexAll(gpa, src);
    defer gpa.free(runs);
    try expectTiles(runs, src, 0, @intCast(src.len));

    // The header's cells are labels, drawn rather than lexed.
    try testing.expectEqual(Kind.strong, kindOf(runs, src, "Setting").?);
    try testing.expectEqual(Kind.punct, kindOf(runs, src, "|---|").?);
    // A body row keeps its pipes and lexes its cells, so inline code in one
    // still reads as inline code.
    try testing.expectEqual(Kind.string, kindOf(runs, src, "`comments`").?);
    try testing.expectEqual(Kind.text, kindOf(runs, src, "the gutter dot").?);
    // With no rule under it, the pipes themselves are prose too.
    try testing.expectEqual(Kind.text, kindOf(runs, src, "| pipes |").?);
    // And the table after it is a table again: the state does not leak.
    try testing.expectEqual(Kind.strong, kindOf(runs, src, "Second").?);
    try testing.expectEqual(Kind.punct, kindOf(runs, src, "| back |").?);
}

test "a link is its target, and what it says goes on lexing as itself" {
    const src =
        \\See [the guide](docs/GUIDE.md) and [`config.zig`](src/config.zig).
        \\
        \\![a shot](https://host/a(1).png) and <https://host/auto> too.
        \\
        \\Prose with [square brackets] and a lone ] in it.
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&markdown_lang.def);
    const runs = try lx.lexAll(gpa, src);
    defer gpa.free(runs);
    try expectTiles(runs, src, 0, @intCast(src.len));

    try testing.expectEqual(Kind.string, kindOf(runs, src, "docs/GUIDE.md").?);
    try testing.expectEqual(Kind.text, kindOf(runs, src, "the guide").?);
    // Inline code inside a link is still inline code.
    try testing.expectEqual(Kind.string, kindOf(runs, src, "`config.zig`").?);
    // A target with brackets of its own survives, and so does an autolink.
    try testing.expectEqual(Kind.string, kindOf(runs, src, "https://host/a(1).png").?);
    try testing.expectEqual(Kind.string, kindOf(runs, src, "https://host/auto").?);
    // Brackets that open no link are prose, which is what most brackets are.
    try testing.expectEqual(Kind.text, kindOf(runs, src, "square brackets").?);
}

test "the rest of a list: ordered markers and task boxes" {
    const src =
        \\1. first
        \\2) second
        \\10. tenth
        \\
        \\- [ ] not done
        \\- [x] done
        \\- plain
        \\
        \\2026 was a year, not a list.
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&markdown_lang.def);
    const runs = try lx.lexAll(gpa, src);
    defer gpa.free(runs);
    try expectTiles(runs, src, 0, @intCast(src.len));

    try testing.expectEqual(Kind.list_mark, kindOf(runs, src, "1.").?);
    try testing.expectEqual(Kind.list_mark, kindOf(runs, src, "2)").?);
    try testing.expectEqual(Kind.list_mark, kindOf(runs, src, "10.").?);
    // The box belongs to the bullet, and is not the `[` that opens a link.
    try testing.expectEqual(Kind.list_mark, kindOf(runs, src, "[ ]").?);
    try testing.expectEqual(Kind.list_mark, kindOf(runs, src, "[x]").?);
    try testing.expectEqual(Kind.text, kindOf(runs, src, "not done").?);
    // A number with no marker after it is a number in a sentence.
    try testing.expectEqual(Kind.text, kindOf(runs, src, "2026").?);
}

test "strikethrough, and an escaped mark that closes nothing" {
    const src =
        \\~~struck out~~ and ~single~ too.
        \\
        \\Escaped \*stars\* stay prose, and *a \* b* closes on the last one.
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&markdown_lang.def);
    const runs = try lx.lexAll(gpa, src);
    defer gpa.free(runs);
    try expectTiles(runs, src, 0, @intCast(src.len));

    try testing.expectEqual(Kind.strikethrough, kindOf(runs, src, "struck out").?);
    try testing.expectEqual(Kind.strikethrough, kindOf(runs, src, "single").?);
    // The punctuation run takes `\*` whole, so the star never opens a span.
    try testing.expectEqual(Kind.text, kindOf(runs, src, "stars").?);
    // And an escaped star does not close one either: the span runs to `b*`.
    try testing.expectEqual(Kind.emphasis, kindOf(runs, src, "a \\* b").?);
}

test "a rule under a line of prose is that line's heading" {
    const src =
        \\Config
        \\======
        \\
        \\prose under the top.
        \\
        \\A section
        \\---
        \\
        \\prose under that.
        \\
        \\***
        \\
        \\and that one is a rule, because nothing is above it.
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&markdown_lang.def);
    const runs = try lx.lexAll(gpa, src);
    defer gpa.free(runs);
    try expectTiles(runs, src, 0, @intCast(src.len));

    try testing.expectEqual(Kind.heading, kindOf(runs, src, "======").?);
    // The title keeps the prose runs it was emitted as, deliberately.
    try testing.expectEqual(Kind.text, kindOf(runs, src, "Config").?);
    // A rule with a blank line above it is still a rule.
    try testing.expectEqual(Kind.punct, kindOf(runs, src, "***").?);

    var st = try lx.structure(gpa, src);
    defer st.deinit(gpa);
    // Named from the line above, and the section starts at the title.
    try testing.expectEqualStrings("Config", st.enclosingFn(0).?.name);
    try testing.expectEqualStrings("Config", st.enclosingFn(3).?.name);
    // `-----` is an H2, so it nests inside the `=====` above it.
    try testing.expectEqualStrings("A section", st.enclosingFn(8).?.name);
}

test "a lex resumed inside a fence matches one from the top" {
    // The property every checkpoint rests on, and the one thing here that
    // cannot be eyeballed: the fence has to live in `State`.
    const gpa = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(gpa, "# Top\n\n```zig\n");
    for (0..200) |i| try src.print(gpa, "line {d} with `backticks` and # hashes\n", .{i});
    try src.appendSlice(gpa, "```\n\n## After\n\nprose.\n");

    var lx: Lexer = .init(&markdown_lang.def);
    const whole = try lx.lexAll(gpa, src.items);
    defer gpa.free(whole);

    var st = try lx.structure(gpa, src.items);
    defer st.deinit(gpa);
    // A checkpoint well inside the block, which is the case that matters.
    const cp = st.checkpointFor(100);
    try testing.expect(cp.line > 0);
    try testing.expect(cp.state.mode == .fence);

    var part: std.ArrayList(Run) = .empty;
    defer part.deinit(gpa);
    _ = try lx.lex(gpa, src.items, cp.offset, @intCast(src.items.len), cp.state, &part);

    var from: usize = 0;
    while (from < whole.len and whole[from].start < cp.offset) from += 1;
    try testing.expectEqualSlices(Run, whole[from..], part.items);
}

test "a yaml block scalar is not yaml" {
    const src =
        \\steps:
        \\  - name: build
        \\    run: |
        \\      # not a comment, and this is not yaml
        \\      key: not a key
        \\
        \\      echo done
        \\  - shell: bash
        \\    working-directory: src
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&yaml_lang.def);
    const runs = try lx.lexAll(gpa, src);
    defer gpa.free(runs);

    try expectTiles(runs, src, 0, @intCast(src.len));
    // Everything indented past the marker is the script, whatever it says.
    // A blank line stays inside it: it is a blank line of the script.
    try testing.expectEqual(Kind.string, kindOf(runs, src, "# not a comment").?);
    try testing.expectEqual(Kind.string, kindOf(runs, src, "key: not a key").?);
    try testing.expectEqual(Kind.string, kindOf(runs, src, "echo done").?);
    // Back at the mapping's level, and a key again.
    try testing.expectEqual(Kind.type_name, kindOf(runs, src, "shell").?);
    try testing.expectEqual(Kind.type_name, kindOf(runs, src, "working-directory").?);
}

test "a yaml key needs the space its grammar asks for" {
    // `dbdata:/var` is a plain scalar, not a mapping. Without the space test
    // every volume, every image tag and every URL heading a line was a key.
    const src =
        \\volumes:
        \\  - dbdata:/var/lib/postgresql/data
        \\  - name: cache
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&yaml_lang.def);
    const runs = try lx.lexAll(gpa, src);
    defer gpa.free(runs);
    try expectTiles(runs, src, 0, @intCast(src.len));
    try testing.expectEqual(Kind.text, kindOf(runs, src, "dbdata").?);
    try testing.expectEqual(Kind.type_name, kindOf(runs, src, "name").?);
}

test "a shell script: both function forms, and a # that is not a comment" {
    const src =
        \\#!/usr/bin/env bash
        \\set -euo pipefail
        \\
        \\deploy-app() {
        \\  local tag="$1"
        \\  echo 'it\'s quoted' >&2
        \\  nix build --no-link .#lgtm 2>&1
        \\}
        \\
        \\function rollback {
        \\  if [ -n "$tag" ]; then kill %1; fi
        \\}
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&shell_lang.def);
    const runs = try lx.lexAll(gpa, src);
    defer gpa.free(runs);

    try expectTiles(runs, src, 0, @intCast(src.len));
    try testing.expectEqual(Kind.comment, kindOf(runs, src, "#!/usr/bin/env bash").?);
    try testing.expectEqual(Kind.keyword, kindOf(runs, src, "local").?);
    try testing.expectEqual(Kind.keyword, kindOf(runs, src, "function").?);
    try testing.expectEqual(Kind.type_name, kindOf(runs, src, "echo").?);
    try testing.expectEqual(Kind.string, kindOf(runs, src, "\"$1\"").?);
    // No escape in single quotes: the literal ends at the backslashed one.
    try testing.expectEqual(Kind.string, kindOf(runs, src, "'it\\'").?);
    try testing.expectEqual(Kind.text, kindOf(runs, src, "lgtm 2>&1").?);

    // Both forms name the lines under them, which is what a hunk header says.
    var st = try lx.structure(gpa, src);
    defer st.deinit(gpa);
    try testing.expectEqualStrings("deploy-app", st.enclosingFn(5).?.name);
    try testing.expectEqualStrings("rollback", st.enclosingFn(10).?.name);
}

test "a toml table names the lines under it" {
    const src =
        \\# a manifest
        \\[package]
        \\name = "lgtm"
        \\version = "0.1.3"
        \\edition = "2021"
        \\
        \\[dependencies]
        \\serde = { version = "1.0", features = ["derive"] }
        \\log = "0.4"
        \\
        \\[[bin]]
        \\name = "lgtm"
        \\path = 'src/main.rs'
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&toml_lang.def);
    const runs = try lx.lexAll(gpa, src);
    defer gpa.free(runs);

    try expectTiles(runs, src, 0, @intCast(src.len));
    try testing.expectEqual(Kind.type_name, kindOf(runs, src, "[package]").?);
    try testing.expectEqual(Kind.type_name, kindOf(runs, src, "[[bin]]").?);
    try testing.expectEqual(Kind.type_name, kindOf(runs, src, "edition").?);
    try testing.expectEqual(Kind.string, kindOf(runs, src, "\"lgtm\"").?);
    // A literal string takes no escapes, so a path stays a path.
    try testing.expectEqual(Kind.string, kindOf(runs, src, "'src/main.rs'").?);
    // Every key of an inline table, not just the one that heads the line:
    // an unquoted '=' in TOML is an assignment and nothing else.
    try testing.expectEqual(Kind.type_name, kindOf(runs, src, "features").?);
    try testing.expectEqual(Kind.comment, kindOf(runs, src, "# a manifest").?);

    // The only structure the format has, and a table ends where the next
    // begins.
    var st = try lx.structure(gpa, src);
    defer st.deinit(gpa);
    try testing.expectEqualStrings("package", st.enclosingFn(3).?.name);
    try testing.expectEqualStrings("dependencies", st.enclosingFn(8).?.name);
    try testing.expectEqualStrings("bin", st.enclosingFn(12).?.name);
}

test "a toml value that spans lines is still one value" {
    const src =
        \\[tool]
        \\banner = """
        \\  = not a key
        \\  [not a table]
        \\"""
        \\paths = [
        \\  "a",
        \\  "b",
        \\]
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&toml_lang.def);
    const runs = try lx.lexAll(gpa, src);
    defer gpa.free(runs);
    try expectTiles(runs, src, 0, @intCast(src.len));
    // Inside a multi-line literal nothing is a key and nothing is a table.
    try testing.expectEqual(Kind.string, kindOf(runs, src, "not a key").?);
    try testing.expectEqual(Kind.string, kindOf(runs, src, "[not a table]").?);
    try testing.expectEqual(Kind.type_name, kindOf(runs, src, "paths").?);
}

test "a toml array element is not a table because it opens with a bracket" {
    const src =
        \\[matrix]
        \\pairs = [
        \\[1, 2],
        \\[3, 4],
        \\]
        \\rows = 2
        \\
    ;
    const gpa = testing.allocator;
    var lx: Lexer = .init(&toml_lang.def);
    const runs = try lx.lexAll(gpa, src);
    defer gpa.free(runs);
    try expectTiles(runs, src, 0, @intCast(src.len));
    // A table header has its line to itself. This one carries a value after
    // the bracket, so it is a value.
    try testing.expectEqual(Kind.punct, kindOf(runs, src, "[1,").?);
    try testing.expectEqual(Kind.type_name, kindOf(runs, src, "[matrix]").?);

    var st = try lx.structure(gpa, src);
    defer st.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), st.fns.len);
    try testing.expectEqualStrings("matrix", st.enclosingFn(5).?.name);
}
