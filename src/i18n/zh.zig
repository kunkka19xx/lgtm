// SPDX-License-Identifier: Apache-2.0

const Entry = @import("i18n.zig").Entry;

pub const entries: []const Entry =
    @import("zh/turns.zig").entries ++
    @import("zh/review.zig").entries ++
    @import("zh/app.zig").entries ++
    @import("zh/keys.zig").entries ++
    @import("zh/chrome.zig").entries;
