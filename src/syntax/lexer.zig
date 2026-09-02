// SPDX-License-Identifier: Apache-2.0
//
// One generic lexer over per-language definitions supplied at comptime
// (ARCHITECTURE.md 5). A lexer rather than a parser, because a hunk is by
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

    pub const Mode = enum(u8) { normal, block_comment, string };
};

pub const checkpoint_lines = 64;

/// `{brace_depth, lex_state}` every 64 lines (PERFORMANCE.md 6.2). Lexing any
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

        const cp_slice = try cps.toOwnedSlice(gpa);
        errdefer gpa.free(cp_slice);
        return .{
            .checkpoints = cp_slice,
            .fns = try fns.toOwnedSlice(gpa),
            .lines = lines,
        };
    }
};

fn isIdentCont(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

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
    /// Set by a `fn_decl` keyword; the next identifier is the function name.
    expect_fn: bool = false,

    fn run(self: *Scan) Allocator.Error!void {
        while (self.i < self.end) {
            if (self.at_line_start) {
                try self.lineStart();
                self.at_line_start = false;
            }

            const before = self.i;
            switch (self.st.mode) {
                .normal => try self.inNormal(),
                .block_comment => try self.inBlockComment(self.i),
                .string => try self.inString(self.i),
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

        // Indentation is only meaningful outside a multi-line literal.
        if (self.st.mode != .normal) return;

        var j = self.i;
        var col: u16 = 0;
        while (j < self.end and (self.text[j] == ' ' or self.text[j] == '\t')) : (j += 1) col += 1;
        const blank = j >= self.end or self.text[j] == '\n' or self.text[j] == '\r';
        self.indent = col;
        if (blank) return;

        if (self.def.blocks == .indent) self.closeIndentSpans(col);
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

        // One table lookup stands in for every opener test below. Most bytes
        // in source are not the start of a comment or a literal.
        if (self.def.delim_start[c]) {
            for (self.def.line_comment) |lc| {
                if (!self.match(lc)) continue;
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

        if (std.ascii.isDigit(c)) {
            const start = self.i;
            self.scanNumber();
            self.expect_fn = false;
            return self.emit(start, self.i, .number);
        }

        if (self.def.ident_start[c]) {
            const start = self.i;
            self.i += 1;
            while (self.i < self.end and isIdentCont(self.text[self.i])) self.i += 1;
            const word = self.text[start..self.i];

            var kind: Kind = .text;
            if (self.def.lookupWord(word)) |k| kind = k;

            // Only a keyword can introduce a function, so this second map is
            // never consulted for an ordinary identifier.
            if (kind == .keyword and self.def.fn_words.has(word)) {
                self.expect_fn = true;
            } else if (self.expect_fn and kind == .text) {
                kind = .fn_name;
                self.expect_fn = false;
                try self.openFn(word);
            } else {
                self.expect_fn = false;
            }
            return self.emit(start, self.i, kind);
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
                if (p == '{') {
                    self.st.depth += 1;
                } else if (p == '}') {
                    self.st.depth -= 1;
                    self.closeBraceSpans();
                }
            }
            if (self.expect_fn and self.def.fn_receiver and p == '(') {
                self.skipBalanced();
                continue;
            }
            self.expect_fn = false;
            self.i += 1;
        }
        if (self.i == start) self.i += 1; // never stall
        return self.emit(start, self.i, .punct);
    }

    /// std's scalar search is vectorised, so this beats stepping a byte at a
    /// time - and comment-heavy source spends a lot of its time right here
    /// (PERFORMANCE.md 6.3).
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
                break;
            }
            self.i += 1;
        }
        try self.emit(start, self.i, .string);
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

    // -- function spans ----------------------------------------------------

    fn openFn(self: *Scan, name: []const u8) Allocator.Error!void {
        const fns = self.fns orelse return;
        const stack = self.stack.?;

        // A sibling at the same level closes the previous one. Without this a
        // bodyless declaration - `fn foo(&self);` in a trait - would stay open
        // and be reported as the enclosing function of everything after it.
        switch (self.def.blocks) {
            .braces => self.closeBraceSpans(),
            .indent => self.closeIndentSpans(self.indent),
        }

        try fns.append(self.gpa, .{
            .name = name,
            .start_line = self.line,
            .end_line = self.line,
            .depth = self.st.depth,
            .indent = self.indent,
        });
        try stack.append(self.gpa, @intCast(fns.items.len - 1));
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

/// Asserts the two invariants every renderer depends on. Called by most tests
/// below rather than tested once, because a new language definition is exactly
/// the kind of change that breaks them somewhere unexpected.
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
