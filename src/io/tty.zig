// SPDX-License-Identifier: Apache-2.0
//
// Owns the terminal handle and the buffered writer handed to the renderer.
// ui/ receives the writer as a parameter and never constructs one
// (ARCHITECTURE.md 5c).

const std = @import("std");
const vaxis = @import("vaxis");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// One flush per frame is the budget (PERFORMANCE.md 7.4). Sized so a full
/// repaint with styling never forces an early flush.
pub const default_buffer_bytes = 256 << 10;

pub const Winsize = vaxis.Winsize;

pub const Tty = struct {
    inner: vaxis.tty.Tty,
    buffer: []u8,
    gpa: Allocator,

    pub fn init(gpa: Allocator, io: Io, buffer_bytes: usize) !Tty {
        const buffer = try gpa.alloc(u8, buffer_bytes);
        errdefer gpa.free(buffer);
        return .{
            .inner = try vaxis.tty.Tty.init(io, buffer),
            .buffer = buffer,
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *Tty) void {
        self.inner.deinit();
        self.gpa.free(self.buffer);
        self.* = undefined;
    }

    /// The interface passed to vaxis render(). Callers must flush.
    pub fn writer(self: *Tty) *Io.Writer {
        return self.inner.writer();
    }

    pub fn winsize(self: *Tty) !Winsize {
        return self.inner.getWinsize();
    }

    pub fn read(self: *const Tty, buf: []u8) !usize {
        return self.inner.read(buf);
    }
};

/// Plain stdout writer for non-TUI output: --help, --version, --profile.
pub const Stdout = struct {
    file_writer: Io.File.Writer,
    buffer: []u8,
    gpa: Allocator,

    pub fn init(gpa: Allocator, io: Io, buffer_bytes: usize) Allocator.Error!Stdout {
        const buffer = try gpa.alloc(u8, buffer_bytes);
        const file = Io.File.stdout();
        return .{
            .file_writer = file.writer(io, buffer),
            .buffer = buffer,
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *Stdout) void {
        self.gpa.free(self.buffer);
        self.* = undefined;
    }

    pub fn writer(self: *Stdout) *Io.Writer {
        return &self.file_writer.interface;
    }
};
