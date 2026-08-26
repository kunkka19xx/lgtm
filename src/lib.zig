// SPDX-License-Identifier: Apache-2.0
//
// The headless library surface. Rooted at src/ so that modules spanning core/
// and io/ resolve, and so harness executables can depend on one module rather
// than assembling a graph each time.
//
// Terminal-facing modules (io/tty.zig, ui/) are deliberately absent: they pull
// in vaxis, and the parts the build order calls headless-testable must not
// drag a TUI dependency into a harness.

pub const fs = @import("io/fs.zig");
pub const proc = @import("io/proc.zig");
pub const metrics = @import("io/metrics.zig");

pub const buffer = @import("text/buffer.zig");
pub const edit = @import("text/edit.zig");

pub const anchor = @import("core/anchor.zig");
pub const event = @import("core/event.zig");
pub const diff = @import("core/diff.zig");
pub const git = @import("core/git.zig");
pub const hunk = @import("core/hunk.zig");

test {
    _ = fs;
    _ = proc;
    _ = metrics;
    _ = buffer;
    _ = edit;
    _ = anchor;
    _ = event;
    _ = diff;
    _ = git;
    _ = hunk;
}
