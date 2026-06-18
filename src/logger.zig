// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");

const z = @import("root.zig");

const FILE_NAME = "z.log";
const MAX_SIZE = std.math.pow(usize, 2, 20);

pub const Level = enum {
    debug,
    info,
    warn,
    err,
    fatal,
};

pub inline fn getWriter(io: std.Io, buffer: []u8) !std.Io.File.Writer {
    var file = try std.Io.Dir.cwd().createFile(io, FILE_NAME, .{ .truncate = false, .read = true });
    errdefer file.close(io);

    if (file.length(io) catch 0 > MAX_SIZE) {
        file.close(io);
        file = try std.Io.Dir.cwd().createFile(io, FILE_NAME, .{ .truncate = true, .read = true });
    }

    var writer = file.writer(io, buffer);
    try writer.seekTo(file.length(io) catch 0);

    return writer;
}

pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    var buffer: [4096]u8 = undefined;

    const io = z.getState().io.io();

    var writer = getWriter(io, &buffer) catch return;
    defer writer.file.close(io);

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
