// SPDX-License-Identifier: Apache-2.0
//
// Re-anchoring. The primary path is a table lookup through an old-to-new line
// map, not a search (PERFORMANCE.md 3.1). Fallback tiers come later; this file
// is the part the go/no-go gate measures.

const std = @import("std");
const Allocator = std.mem.Allocator;

const linemap = @import("linemap.zig");

// Re-exported: "re-anchoring" is one idea to a caller, and the matcher it is
// built on is the same module to them as the tiers are.
pub const window = linemap.window;
pub const Interner = linemap.Interner;
pub const HashIndex = linemap.HashIndex;
pub const LineMap = linemap.LineMap;
pub const lineMap = linemap.lineMap;
pub const windowHash = linemap.windowHash;
pub const normalise = linemap.normalise;

pub const Version = struct {
    ids: []u32,
    norm_ids: []u32,
    exact: ?HashIndex = null,
    norm: ?HashIndex = null,

    /// How often laziness failed to pay off, for the harness to report.
    pub var index_builds: usize = 0;

    pub fn init(
        gpa: Allocator,
        exact_interner: *Interner,
        norm_interner: *Interner,
        norm_arena: Allocator,
        text: []const u8,
    ) !Version {
        const ids = try exact_interner.internLines(gpa, text);
        errdefer gpa.free(ids);

        var norm_list: std.ArrayList(u32) = .empty;
        errdefer norm_list.deinit(gpa);
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            const n = try normalise(norm_arena, line);
            try norm_list.append(gpa, try norm_interner.intern(gpa, n));
        }
        if (norm_list.items.len > 0 and text.len > 0 and text[text.len - 1] == '\n') {
            _ = norm_list.pop();
        }
        const norm_ids = try norm_list.toOwnedSlice(gpa);
        return .{ .ids = ids, .norm_ids = norm_ids };
    }

    fn exactIndex(self: *Version, gpa: Allocator) Allocator.Error!HashIndex {
        if (self.exact == null) {
            self.exact = try HashIndex.build(gpa, self.ids);
            index_builds += 1;
        }
        return self.exact.?;
    }

    fn normIndex(self: *Version, gpa: Allocator) Allocator.Error!HashIndex {
        if (self.norm == null) {
            self.norm = try HashIndex.build(gpa, self.norm_ids);
            index_builds += 1;
        }
        return self.norm.?;
    }

    pub fn deinit(self: *Version, gpa: Allocator) void {
        gpa.free(self.ids);
        gpa.free(self.norm_ids);
        if (self.exact) |*i| i.deinit(gpa);
        if (self.norm) |*i| i.deinit(gpa);
        self.* = undefined;
    }
};

/// Which path placed a note. Recorded so the remaining tiers get built against
/// evidence rather than speculation.
pub const Outcome = enum {
    /// Primary path: the line map had a counterpart (PERFORMANCE.md 3.1).
    mapped,
    /// Tier 1: exact window hash within the near window.
    near_hash,
    /// Tier 2: exact window hash anywhere in the file.
    far_hash,
    /// Tier 3: whitespace-normalised window hash.
    normalised_hash,
    /// Tier 6. Tiers 4 and 5 are not built: 5 needs `hunk_hash` from phase 2,
    /// and nothing has yet produced a case that 4 would rescue.
    stale,
};

/// How far tier 1 looks before falling through to a whole-file lookup.
pub const near_window = 50;

/// A note's position, carried across versions.
pub const Anchor = struct {
    line: u32,
    exact_hash: u64,
    norm_hash: u64,
    stale: bool = false,

    pub fn init(v: Version, line: u32) Anchor {
        return .{
            .line = line,
            .exact_hash = windowHash(v.ids, line),
            .norm_hash = windowHash(v.norm_ids, line),
        };
    }

    /// Walks the ladder, stopping at the first tier that places the note. The
    /// anchor is only ever marked stale, never silently dropped (hard rule 7).
    pub fn reanchor(self: *Anchor, gpa: Allocator, map: LineMap, to: *Version) Allocator.Error!Outcome {
        if (self.stale) return .stale;
        const from_line = self.line;

        // Primary path. No index is built when this succeeds, which is the
        // common case (PERFORMANCE.md 3.1).
        if (map.get(from_line)) |n| {
            self.line = n;
            return .mapped;
        }
        if (nearest((try to.exactIndex(gpa)).lookup(self.exact_hash), from_line)) |n| {
            self.line = n;
            const delta = if (n > from_line) n - from_line else from_line - n;
            return if (delta <= near_window) .near_hash else .far_hash;
        }
        if (nearest((try to.normIndex(gpa)).lookup(self.norm_hash), from_line)) |n| {
            self.line = n;
            return .normalised_hash;
        }
        self.stale = true;
        return .stale;
    }
};

/// Of several equally-hashing candidates, the one closest to where the note
/// used to be. Ties go to the lower line.
fn nearest(candidates: []const u32, to: u32) ?u32 {
    var best: ?u32 = null;
    var best_delta: u32 = std.math.maxInt(u32);
    for (candidates) |c| {
        const delta = if (c > to) c - to else to - c;
        if (delta < best_delta) {
            best_delta = delta;
            best = c;
        }
    }
    return best;
}

const testing = std.testing;

// The matcher this file is policy over; see the note in `ui/app.zig`.
test {
    _ = linemap;
}


test "anchor takes the primary path when the line maps" {
    var h = Harness.init(testing.allocator);
    defer h.deinit();

    const v0 = try h.add("one\ntwo\nthree\n");
    const v1 = try h.add("zero\none\ntwo\nthree\n");

    var map = try lineMap(testing.allocator, v0.ids, v1.ids);
    defer map.deinit(testing.allocator);

    var a: Anchor = .init(v0.*, 1);
    try testing.expectEqual(Outcome.mapped, try a.reanchor(testing.allocator, map, v1));
    try testing.expectEqual(@as(u32, 2), a.line);
}

test "tier 3 rescues a whitespace-only reindent" {
    var h = Harness.init(testing.allocator);
    defer h.deinit();

    const v0 = try h.add(
        \\fn f() {
        \\    if (a) {
        \\        return b;
        \\    }
        \\}
        \\
    );
    const v1 = try h.add(
        \\fn f() {
        \\  if (a) {
        \\    return b;
        \\  }
        \\}
        \\
    );

    var map = try lineMap(testing.allocator, v0.ids, v1.ids);
    defer map.deinit(testing.allocator);

    // `return b;` is reindented, so no exact hash can match it.
    var a: Anchor = .init(v0.*, 2);
    try testing.expectEqual(Outcome.normalised_hash, try a.reanchor(testing.allocator, map, v1));
    try testing.expectEqual(@as(u32, 2), a.line);
    try testing.expect(!a.stale);
}

test "a rewritten neighbourhood goes stale rather than relocating" {
    var h = Harness.init(testing.allocator);
    defer h.deinit();

    const v0 = try h.add("fn f() {\n    let x = 1;\n    deprecated(x);\n    total(x)\n}\n");
    const v1 = try h.add("fn f() {\n    let x = compute();\n    summarise(x)\n}\n");

    var map = try lineMap(testing.allocator, v0.ids, v1.ids);
    defer map.deinit(testing.allocator);

    var a: Anchor = .init(v0.*, 2);
    try testing.expectEqual(Outcome.stale, try a.reanchor(testing.allocator, map, v1));
    try testing.expect(a.stale);
}

test "a stale anchor stays stale" {
    var h = Harness.init(testing.allocator);
    defer h.deinit();
    const v0 = try h.add("a\nb\nc\n");
    const v1 = try h.add("a\nb\nc\n");

    var map = try lineMap(testing.allocator, v0.ids, v1.ids);
    defer map.deinit(testing.allocator);

    var a: Anchor = .init(v0.*, 1);
    a.stale = true;
    try testing.expectEqual(Outcome.stale, try a.reanchor(testing.allocator, map, v1));
}

test "nearest candidate wins, ties go low" {
    try testing.expectEqual(@as(?u32, 8), nearest(&.{ 3, 8, 20 }, 9));
    try testing.expectEqual(@as(?u32, 5), nearest(&.{ 5, 15 }, 10));
    try testing.expectEqual(@as(?u32, null), nearest(&.{}, 4));
}

/// Wires up the two interners and the normalisation arena that Version needs.
const Harness = struct {
    gpa: Allocator,
    exact: Interner = .{},
    norm: Interner = .{},
    arena: std.heap.ArenaAllocator,
    versions: std.ArrayList(Version) = .empty,

    fn init(gpa: Allocator) Harness {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    /// Returns a pointer into the list, so callers can trigger lazy index builds.
    fn add(self: *Harness, text: []const u8) !*Version {
        const v = try Version.init(self.gpa, &self.exact, &self.norm, self.arena.allocator(), text);
        try self.versions.append(self.gpa, v);
        return &self.versions.items[self.versions.items.len - 1];
    }

    fn deinit(self: *Harness) void {
        for (self.versions.items) |*v| v.deinit(self.gpa);
        self.versions.deinit(self.gpa);
        self.exact.deinit(self.gpa);
        self.norm.deinit(self.gpa);
        self.arena.deinit();
    }
};

test "hash index finds every line sharing a window" {
    var h = Harness.init(testing.allocator);
    defer h.deinit();
    const v = try h.add("a\nb\nc\nd\n");

    var idx = try HashIndex.build(testing.allocator, v.ids);
    defer idx.deinit(testing.allocator);
    const hits = idx.lookup(windowHash(v.ids, 2));
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqual(@as(u32, 2), hits[0]);

    try testing.expectEqual(@as(usize, 0), idx.lookup(0xdead_beef).len);
}
