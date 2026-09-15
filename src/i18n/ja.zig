// SPDX-License-Identifier: Apache-2.0

const Entry = @import("i18n.zig").Entry;

pub const entries: []const Entry =
    @import("ja/turns.zig").entries ++
    @import("ja/review.zig").entries ++
    @import("ja/app.zig").entries ++
    @import("ja/keys.zig").entries ++
    @import("ja/chrome.zig").entries;
