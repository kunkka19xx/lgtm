// SPDX-License-Identifier: Apache-2.0
//
// Byte offsets only. UTF-16 conversion belongs in lsp/position.zig, which does
// not exist yet.

const std = @import("std");

pub const Position = struct {
    line: u32,
    /// Byte offset from the start of the line, never a codepoint or UTF-16 index.
    byte: u32,

    pub fn order(a: Position, b: Position) std.math.Order {
        if (a.line != b.line) return std.math.order(a.line, b.line);
        return std.math.order(a.byte, b.byte);
    }
};

pub const Range = struct {
    start: Position,
    end: Position,

    pub fn isEmpty(self: Range) bool {
        return self.start.order(self.end) == .eq;
    }

    pub fn contains(self: Range, pos: Position) bool {
        return self.start.order(pos) != .gt and self.end.order(pos) == .gt;
    }
};

/// The only way text changes. Revert-a-hunk and stage/unstage in v0.3 are both
/// TextEdits, as are LSP code actions later.
pub const TextEdit = struct {
    range: Range,
    new_text: []const u8,
};

test "range containment uses byte order" {
    const r: Range = .{
        .start = .{ .line = 2, .byte = 4 },
        .end = .{ .line = 3, .byte = 0 },
    };
    try std.testing.expect(r.contains(.{ .line = 2, .byte = 4 }));
    try std.testing.expect(r.contains(.{ .line = 2, .byte = 99 }));
    try std.testing.expect(!r.contains(.{ .line = 3, .byte = 0 }));
    try std.testing.expect(!r.contains(.{ .line = 1, .byte = 0 }));
    try std.testing.expect(!r.isEmpty());
}
