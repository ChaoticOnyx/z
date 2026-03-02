// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");

const FILE_NAME = "z.log";
const MAX_SIZE = std.math.pow(usize, 2, 20);

pub const Level = enum {
    debug,
    info,
    warn,
    err,
    fatal,
};

pub inline fn getWriter(buffer: []u8) !std.fs.File.Writer {
    var file = try std.fs.cwd().createFile(FILE_NAME, .{ .truncate = false });
    errdefer file.close();

    if (file.getEndPos() catch 0 > MAX_SIZE) {
        file.close();
        file = try std.fs.cwd().createFile(FILE_NAME, .{ .truncate = true });
    }

    var writer = file.writer(buffer);
    try writer.seekTo(try file.getEndPos());

    return writer;
}

pub fn stdLogFn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    var buffer: [4096]u8 = undefined;

    var writer = getWriter(&buffer) catch return;
    defer writer.file.close();

    switch (message_level) {
        .debug => writer.interface.print("[DEBUG] ", .{}) catch return,
        .info => writer.interface.print("[INFO]  ", .{}) catch return,
        .warn => writer.interface.print("[WARN]  ", .{}) catch return,
        .err => writer.interface.print("[ERROR] ", .{}) catch return,
    }

    if (scope != .default) {
        writer.interface.print("(" ++ @tagName(scope) ++ ") ", .{}) catch return;
    }

    writer.interface.print(format ++ "\n", args) catch return;
    writer.interface.flush() catch return;
}
