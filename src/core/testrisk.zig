// SPDX-License-Identifier: Apache-2.0
//
// Did the agent quietly weaken a test?
//
// The failure mode with the worst consequences, and the one a human reviewer is
// least likely to catch: it hides in the part of a diff people skim. A deleted
// test, an added skip, an assertion that stopped asserting - each of them turns
// a red build green while looking like ordinary cleanup.
//
// The whole idea here is that this is a **comparison, not an analysis**. Both
// sides of the change are already in memory as `DiffLines`, so the question
// "does this file check less than it did" is a count over lines that appeared
// against lines that disappeared. No second parse, no structure, no new pass
// over the file - which is also why it can run on every re-diff.
//
// Matched as substrings of a line rather than as tokens. A removed line is one
// line of a file that no longer exists in that form, and half of them will not
// lex on their own; a substring survives that. It costs precision in one
// direction only: this misses things rather than inventing them, which is the
// side to err on. A signal that cries wolf twice is a signal that is ignored
// forever, and then it is worse than not having been built.
//
// Detected by content, never by path. Zig puts tests in the source file - this
// repository keeps 531 of them across 74 files that are not test files - so a
// rule that only looked inside `tests/` would miss almost all of them.
//
// Pure: a `FileDiff` and a `LangDef` in, four numbers out.

const std = @import("std");

const diff = @import("diff.zig");
const langdef = @import("../syntax/langdef.zig");

/// What one file's change did to its tests.
pub const Risk = struct {
    /// Test declarations that disappeared and did not come back. A rename
    /// removes one and adds one, and nets to zero, which is the point of
    /// counting both sides rather than only removals.
    removed: u32 = 0,
    /// Tests that were switched off rather than deleted. The clearest of the
    /// signals: an added `t.Skip` is almost never anything else.
    skipped: u32 = 0,
    /// How many fewer assertions the file makes than it did. Suggestive rather
    /// than certain - a refactor that merges two checks into one shows here
    /// too - so it is reported as a second line and never as the headline.
    fewer_asserts: u32 = 0,
    /// Whether the file itself is gone, and it contained tests. `status` says
    /// deleted; what makes it a *test* deletion is that the removed lines
    /// declared some.
    file_deleted: bool = false,

    /// Anything worth telling the reader about.
    pub fn any(self: Risk) bool {
        return self.removed > 0 or self.skipped > 0 or self.fewer_asserts > 0 or self.file_deleted;
    }

    /// The two signals precise enough to lead with. `fewer_asserts` is
    /// deliberately not one of them: it is right often enough to show and not
    /// often enough to alarm.
    pub fn certain(self: Risk) bool {
        return self.removed > 0 or self.skipped > 0 or self.file_deleted;
    }

    pub fn add(self: *Risk, other: Risk) void {
        self.removed += other.removed;
        self.skipped += other.skipped;
        self.fewer_asserts += other.fewer_asserts;
        self.file_deleted = self.file_deleted or other.file_deleted;
    }
};

/// Whether byte `at` sits inside a quoted string on this line.
///
/// The vocabulary is code, so any file that *talks about* test frameworks
/// carries it as data: this tool's own language tables hold `"error.SkipZigTest"`
/// and `".only("` as literals, and scanning lgtm with lgtm reported five skips
/// added the first time it was pointed at itself. A linter, a test framework's
/// own source, or a comment quoting an example all do the same.
///
/// Quote counting rather than lexing, because a removed line is one line of a
/// file that no longer exists in that form and cannot be parsed on its own. It
/// is wrong for a line that opens a string and does not close it, which is rare
/// and errs towards silence.
///
/// Every real declaration starts *outside* the quotes it contains - `test "`,
/// `it("`, `t.Skip(` - so this costs nothing on the cases that matter.
pub fn insideString(line: []const u8, at: usize) bool {
    // Counted separately. Sharing one parity made a backtick close a quote:
    // `` `"error.SkipZigTest"` `` in a doc comment came to two delimiters,
    // read as even, and reported itself as a skip - twice, in this file's own
    // comments about the problem.
    var quotes: usize = 0;
    var ticks: usize = 0;
    var i: usize = 0;
    while (i < at and i < line.len) : (i += 1) {
        if (line[i] == '\\') {
            i += 1;
            continue;
        }
        if (line[i] == '"') quotes += 1;
        if (line[i] == '`') ticks += 1;
    }
    return quotes % 2 == 1 or ticks % 2 == 1;
}

/// Whether `line` contains any of `words`, ignoring what is around it.
///
/// Deliberately not word-boundary aware. `t.Skip(` and `@pytest.mark.skip` are
/// not identifiers, `it.only(` is punctuation in the middle, and a boundary
/// rule that handled all of them would be a parser. The vocabulary is chosen to
/// be specific enough that a substring is safe: `Skip` alone would match
/// `SkipList`, so the tables say `t.Skip(`.
pub fn mentions(line: []const u8, words: []const []const u8) bool {
    for (words) |w| {
        if (w.len == 0) continue;
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, line, at, w)) |found| {
            if (!insideString(line, found)) return true;
            at = found + 1;
        }
    }
    return false;
}

/// How many of `words` appear in `line`, counting repeats.
///
/// Assertions are counted rather than merely detected, because one line can
/// hold several and because the whole signal is a difference of counts.
pub fn countIn(line: []const u8, words: []const []const u8) u32 {
    var n: u32 = 0;
    for (words) |w| {
        if (w.len == 0) continue;
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, line, at, w)) |found| {
            if (!insideString(line, found)) n += 1;
            at = found + w.len;
        }
    }
    return n;
}

/// What this file's change did to its tests.
///
/// A language with no test vocabulary yields nothing, which is the right answer
/// for one nobody has described yet: silence rather than a guess.
pub fn scan(f: *const diff.FileDiff, lang: *const langdef.LangDef) Risk {
    var out: Risk = .{};
    if (lang.test_decl.len == 0 and lang.assert_names.len == 0 and lang.skip_names.len == 0) return out;

    var decl_gone: u32 = 0;
    var decl_new: u32 = 0;
    var assert_gone: u32 = 0;
    var assert_new: u32 = 0;
    var skip_gone: u32 = 0;
    var skip_new: u32 = 0;

    for (0..f.lines.len()) |i| {
        const text = f.lines.text[i];
        switch (f.lines.kind[i]) {
            .context => {},
            .del => {
                if (mentions(text, lang.test_decl)) decl_gone += 1;
                if (mentions(text, lang.skip_names)) skip_gone += 1;
                assert_gone += countIn(text, lang.assert_names);
            },
            .add => {
                if (mentions(text, lang.test_decl)) decl_new += 1;
                if (mentions(text, lang.skip_names)) skip_new += 1;
                assert_new += countIn(text, lang.assert_names);
            },
        }
    }

    // Net, on every count. A test moved within a file is removed and added; an
    // assertion rewritten is one of each. Reporting gross removals would make
    // every reformatting look like an attack, and a warning that fires on
    // reformatting is one nobody reads twice.
    out.removed = decl_gone -| decl_new;
    out.skipped = skip_new -| skip_gone;
    out.fewer_asserts = assert_gone -| assert_new;

    // A deleted file is only a *test* deletion if it had tests in it. Every
    // line of it is a removal, so the declarations are all on the `del` side.
    if (f.status == .deleted and decl_gone > 0) {
        out.file_deleted = true;
        out.removed = decl_gone;
    }
    return out;
}

/// One bool per row of `f`: whether that row is a finding worth walking to.
///
/// Only the certain two. A removed test declaration and an added skip are
/// *places* - there is a line to put the cursor on and something to read when
/// you get there. A fallen assertion count is a property of the file, and
/// landing the reader on one arbitrary removed line to explain it would be
/// pointing at evidence rather than at the thing.
pub fn markRows(gpa: std.mem.Allocator, f: *const diff.FileDiff, lang: *const langdef.LangDef) std.mem.Allocator.Error![]bool {
    const out = try gpa.alloc(bool, f.lines.len());
    errdefer gpa.free(out);
    @memset(out, false);
    if (lang.test_decl.len == 0 and lang.skip_names.len == 0) return out;

    for (0..f.lines.len()) |i| {
        const text = f.lines.text[i];
        out[i] = switch (f.lines.kind[i]) {
            .del => mentions(text, lang.test_decl),
            .add => mentions(text, lang.skip_names),
            .context => false,
        };
    }
    return out;
}

const testing = std.testing;
const hunk = @import("hunk.zig");

/// The Zig vocabulary, written out here rather than imported, so these tests
/// describe the behaviour instead of the table. The real tables live beside
/// each language in `syntax/lang/`.
const zig_like: langdef.LangDef = .{
    .name = "ziglike",
    .test_decl = &.{"test \""},
    .assert_names = &.{ "try testing.expect", "try std.testing.expect" },
    .skip_names = &.{"error.SkipZigTest"},
};

fn fileOf(gpa: std.mem.Allocator, spec: []const []const u8, status: diff.Status) !diff.FileDiff {
    var lines: hunk.DiffLines = .{
        .kind = try gpa.alloc(hunk.LineKind, spec.len),
        .old_no = try gpa.alloc(u32, spec.len),
        .new_no = try gpa.alloc(u32, spec.len),
        .text = try gpa.alloc([]const u8, spec.len),
    };
    for (spec, 0..) |s, i| {
        lines.kind[i] = switch (s[0]) {
            '+' => .add,
            '-' => .del,
            else => .context,
        };
        lines.old_no[i] = @intCast(i + 1);
        lines.new_no[i] = @intCast(i + 1);
        lines.text[i] = s[1..];
    }
    return .{ .old_path = "a.zig", .new_path = "a.zig", .status = status, .lines = lines };
}

test "a deleted test is the signal, and a moved one is not" {
    const gpa = testing.allocator;
    var f = try fileOf(gpa, &.{
        " fn thing() void {}",
        "-test \"thing handles zero\" {",
        "-    try testing.expect(thing(0));",
        "-}",
    }, .modified);
    defer f.lines.deinit(gpa);

    const r = scan(&f, &zig_like);
    try testing.expectEqual(@as(u32, 1), r.removed);
    try testing.expect(r.certain());

    // The same test, moved: one declaration leaves and one arrives. Counting
    // only removals would make every reordering look like an attack.
    var moved = try fileOf(gpa, &.{
        "-test \"thing handles zero\" {",
        "-    try testing.expect(thing(0));",
        "-}",
        "+test \"thing handles zero\" {",
        "+    try testing.expect(thing(0));",
        "+}",
    }, .modified);
    defer moved.lines.deinit(gpa);
    try testing.expect(!scan(&moved, &zig_like).any());
}

test "an added skip is the clearest signal there is" {
    const gpa = testing.allocator;
    var f = try fileOf(gpa, &.{
        " test \"the flaky one\" {",
        "+    if (true) return error.SkipZigTest;",
        "     try testing.expect(thing());",
        " }",
    }, .modified);
    defer f.lines.deinit(gpa);

    const r = scan(&f, &zig_like);
    try testing.expectEqual(@as(u32, 1), r.skipped);
    try testing.expectEqual(@as(u32, 0), r.removed);
    try testing.expect(r.certain());
}

test "removing a skip is not a risk, it is the opposite" {
    const gpa = testing.allocator;
    var f = try fileOf(gpa, &.{
        " test \"was flaky\" {",
        "-    if (true) return error.SkipZigTest;",
        " }",
    }, .modified);
    defer f.lines.deinit(gpa);
    try testing.expect(!scan(&f, &zig_like).any());
}

test "a test that keeps its name but stops checking" {
    // The case the assertion count exists for: the declaration survives, so
    // nothing else notices, and the body no longer asserts anything.
    const gpa = testing.allocator;
    var f = try fileOf(gpa, &.{
        " test \"parses a header\" {",
        "-    try testing.expect(parse(input) != null);",
        "-    try testing.expect(parse(input).?.len == 3);",
        "+    _ = parse(input);",
        " }",
    }, .modified);
    defer f.lines.deinit(gpa);

    const r = scan(&f, &zig_like);
    try testing.expectEqual(@as(u32, 2), r.fewer_asserts);
    try testing.expectEqual(@as(u32, 0), r.removed);
    // Suggestive, not certain: a refactor that merges two checks looks the
    // same, so this shows as a second line and never leads.
    try testing.expect(r.any());
    try testing.expect(!r.certain());
}

test "more assertions than before is not a risk" {
    const gpa = testing.allocator;
    var f = try fileOf(gpa, &.{
        " test \"parses a header\" {",
        "     try testing.expect(parse(input) != null);",
        "+    try testing.expect(parse(input).?.len == 3);",
        " }",
    }, .modified);
    defer f.lines.deinit(gpa);
    try testing.expect(!scan(&f, &zig_like).any());
}

test "a deleted file counts only when it held tests" {
    const gpa = testing.allocator;
    var tests_gone = try fileOf(gpa, &.{
        "-test \"one\" {}",
        "-test \"two\" {}",
    }, .deleted);
    defer tests_gone.lines.deinit(gpa);

    const r = scan(&tests_gone, &zig_like);
    try testing.expect(r.file_deleted);
    try testing.expectEqual(@as(u32, 2), r.removed);

    // A deleted file with no tests in it is an ordinary deletion, and saying
    // otherwise about every removed file is how this feature would get muted.
    var plain = try fileOf(gpa, &.{ "-const a = 1;", "-const b = 2;" }, .deleted);
    defer plain.lines.deinit(gpa);
    try testing.expect(!scan(&plain, &zig_like).any());
}

test "a language nobody has described says nothing" {
    const gpa = testing.allocator;
    var f = try fileOf(gpa, &.{"-test \"gone\" {"}, .modified);
    defer f.lines.deinit(gpa);

    // Silence rather than a guess. A half-filled table would report whichever
    // half it had, which reads as "this language is safe".
    const unknown: langdef.LangDef = .{ .name = "unknown" };
    try testing.expect(!scan(&f, &unknown).any());
}

test "substrings are matched, because a removed line need not parse" {
    // `t.Skip(` rather than `Skip`, so `SkipList` does not trip it. The
    // vocabulary carries the precision that a token match would have given.
    try testing.expect(mentions("\tt.Skip(\"flaky\")", &.{"t.Skip("}));
    try testing.expect(!mentions("var s SkipList", &.{"t.Skip("}));
    try testing.expect(mentions("@pytest.mark.skip(reason=...)", &.{"@pytest.mark.skip"}));
}

test "assertions are counted, not merely noticed" {
    // One line can hold several, and the signal is a difference of counts.
    try testing.expectEqual(@as(u32, 2), countIn(
        "try testing.expect(a); try testing.expect(b);",
        &.{"try testing.expect"},
    ));
    try testing.expectEqual(@as(u32, 0), countIn("const x = 1;", &.{"try testing.expect"}));
}

test "risks add up across files" {
    var total: Risk = .{};
    total.add(.{ .removed = 2, .skipped = 1 });
    total.add(.{ .removed = 1, .fewer_asserts = 3, .file_deleted = true });
    try testing.expectEqual(@as(u32, 3), total.removed);
    try testing.expectEqual(@as(u32, 1), total.skipped);
    try testing.expectEqual(@as(u32, 3), total.fewer_asserts);
    try testing.expect(total.file_deleted);
}

// -- the real vocabularies -------------------------------------------------
//
// The tests above describe the algorithm against a stand-in table. These check
// the tables themselves, which is where the precision actually lives: a
// substring chosen one character too short is how this feature starts crying
// wolf, and no amount of correct counting saves it after that.

const lang_zig = @import("../syntax/lang/zig.zig");
const lang_go = @import("../syntax/lang/go.zig");
const lang_js = @import("../syntax/lang/javascript.zig");
const lang_py = @import("../syntax/lang/python.zig");
const lang_java = @import("../syntax/lang/java.zig");

test "the vocabularies do not fire on ordinary code" {
    // The failure that would kill this feature. Every line here is normal code
    // from a language's own idiom, and none of it is a test being weakened.
    const ordinary = [_]struct { line: []const u8, def: *const langdef.LangDef }{
        .{ .line = "    const latest = store.state.latest_turn;", .def = &lang_zig.def },
        .{ .line = "fn testableThing() void {}", .def = &lang_zig.def },
        .{ .line = "    var s SkipList", .def = &lang_go.def },
        // `func Test` matched this until the table moved to the signature.
        .{ .line = "func TestingHelper(x int) {}", .def = &lang_go.def },
        // The one that made `it(` unusable on its own.
        .{ .line = "  submit(form);", .def = &lang_js.def },
        .{ .line = "  const x = edit(value);", .def = &lang_js.def },
        // `xit(` matched this until the table gave it a leading space.
        .{ .line = "  exit(1);", .def = &lang_js.def },
        .{ .line = "    assertion = compute()", .def = &lang_py.def },
        .{ .line = "    def testing_helper(self):", .def = &lang_py.def },
        // `@Test` needs its `@`, so the import that brings it in is not a
        // declaration. `@TestInstance(...)` is the one that gets through - see
        // the note in `syntax/lang/java.zig`.
        .{ .line = "import org.junit.jupiter.api.Test;", .def = &lang_java.def },
        .{ .line = "    private boolean ignored = false;", .def = &lang_java.def },
    };
    for (ordinary) |o| {
        try testing.expect(!mentions(o.line, o.def.test_decl));
        try testing.expect(!mentions(o.line, o.def.skip_names));
    }
}

test "the vocabularies do fire on the real thing" {
    const real = [_]struct { line: []const u8, def: *const langdef.LangDef }{
        .{ .line = "test \"a deleted test is the signal\" {", .def = &lang_zig.def },
        .{ .line = "test {", .def = &lang_zig.def },
        .{ .line = "func TestParse(t *testing.T) {", .def = &lang_go.def },
        .{ .line = "  it(\"parses a header\", () => {", .def = &lang_js.def },
        .{ .line = "  test('rounds correctly', async () => {", .def = &lang_js.def },
        .{ .line = "def test_parses_header():", .def = &lang_py.def },
        .{ .line = "    @Test", .def = &lang_java.def },
        .{ .line = "    @ParameterizedTest", .def = &lang_java.def },
    };
    for (real) |r| try testing.expect(mentions(r.line, r.def.test_decl));

    const skips = [_]struct { line: []const u8, def: *const langdef.LangDef }{
        .{ .line = "    if (flaky) return error.SkipZigTest;", .def = &lang_zig.def },
        .{ .line = "\tt.Skip(\"flaky on CI\")", .def = &lang_go.def },
        .{ .line = "  it.skip(\"parses a header\", () => {", .def = &lang_js.def },
        .{ .line = "  it.only(\"just this one\", () => {", .def = &lang_js.def },
        .{ .line = "  xit(\"disabled for now\", () => {", .def = &lang_js.def },
        .{ .line = "@pytest.mark.skip(reason=\"flaky\")", .def = &lang_py.def },
        .{ .line = "    @Disabled(\"flaky on CI\")", .def = &lang_java.def },
        .{ .line = "        assumeTrue(hasNetwork());", .def = &lang_java.def },
    };
    for (skips) |s| try testing.expect(mentions(s.line, s.def.skip_names));
}

test "one assertion is counted once, however it is spelled" {
    // `expectEqual` and `expectEqualStrings` both contain `testing.expect`, so
    // the table carries the prefix alone. Listing each helper separately would
    // report one call as two and inflate every count in the feature.
    try testing.expectEqual(@as(u32, 1), countIn(
        "    try testing.expectEqualStrings(\"a\", b);",
        lang_zig.def.assert_names,
    ));
    try testing.expectEqual(@as(u32, 1), countIn(
        "\tt.Errorf(\"got %v\", got)",
        lang_go.def.assert_names,
    ));
    // Every JUnit helper contains `assert`, so the table carries the stem
    // alone and one call counts once however it is spelled.
    try testing.expectEqual(@as(u32, 1), countIn(
        "        assertEquals(2, list.size());",
        lang_java.def.assert_names,
    ));
    try testing.expectEqual(@as(u32, 1), countIn(
        "        assertThat(row).isEqualTo(expected);",
        lang_java.def.assert_names,
    ));
    // Rust's three are genuinely distinct spellings and must not collapse.
    try testing.expectEqual(@as(u32, 1), countIn("    assert_eq!(a, b);", &.{ "assert!", "assert_eq!" }));
}

test "vocabulary quoted as data is not a test being weakened" {
    // Found by pointing lgtm at lgtm: the language tables carry
    // `"error.SkipZigTest"` and `".only("` as string literals, and adding them
    // was reported as five skips added. Any file that talks about a test
    // framework does this - a linter, a framework's own source, a comment
    // holding an example.
    const tables = [_][]const u8{
        "    .skip_names = &.{\"error.SkipZigTest\"},",
        "    .skip_names = &.{ \"it.skip\", \"xdescribe(\", \".only(\" },",
        "    .test_decl = &.{ \"test \\\"\", \"test {\" },",
    };
    for (tables) |line| {
        try testing.expect(!mentions(line, &.{"error.SkipZigTest"}));
        try testing.expect(!mentions(line, &.{ "it.skip", ".only(" }));
    }

    // And the real thing still fires: every declaration and skip in the
    // vocabulary begins outside the quotes it may contain.
    try testing.expect(mentions("    if (flaky) return error.SkipZigTest;", &.{"error.SkipZigTest"}));
    try testing.expect(mentions("  it.skip(\"flaky\", () => {", &.{"it.skip"}));
    try testing.expect(mentions("test \"a name\" {", &.{"test \""}));
    try testing.expect(mentions("\tt.Skip(\"flaky on CI\")", &.{"t.Skip"}));
}

test "a backtick does not close a quote" {
    // Both of these are lines from this file's own comments, and both reported
    // themselves as a skip until quotes and backticks were counted apart.
    const doc = "/// carries it as data: this tool's own tables hold `\"error.SkipZigTest\"`";
    try testing.expect(!mentions(doc, &.{"error.SkipZigTest"}));

    const md = "// `\"error.SkipZigTest\"` and `\".only(\"` as string literals, and adding them";
    try testing.expect(!mentions(md, &.{"error.SkipZigTest"}));
    try testing.expect(!mentions(md, &.{".only("}));

    // A backtick span on its own still hides what it holds, which is how code
    // gets quoted in a comment in the first place.
    try testing.expect(!mentions("// use `t.Skip(` to disable one", &.{"t.Skip("}));
}

test "the rows worth walking to are the two certain kinds" {
    const gpa = testing.allocator;
    var f = try fileOf(gpa, &.{
        " fn add() void {}",
        "-test \"add works\" {",
        "-    try testing.expect(add());",
        "-}",
        " test \"other\" {",
        "+    if (true) return error.SkipZigTest;",
        " }",
    }, .modified);
    defer f.lines.deinit(gpa);

    const rows = try markRows(gpa, &f, &zig_like);
    defer gpa.free(rows);

    // The removed declaration and the added skip: places with something to
    // read when you arrive.
    try testing.expect(rows[1]);
    try testing.expect(rows[5]);
    // Not the removed assertion. It is evidence for a count, not a finding to
    // stand on, and landing the reader there would explain nothing.
    try testing.expect(!rows[2]);
    try testing.expect(!rows[0] and !rows[3] and !rows[4] and !rows[6]);
}
