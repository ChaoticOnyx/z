// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");

pub inline fn safeInt(v: f32) ?i32 {
    if (!std.math.isFinite(v)) {
        return null;
    }

    return @intFromFloat(v);
}

pub inline fn safeIntTruncate(comptime T: type, v: f32) ?T {
    if (!std.math.isFinite(v)) {
        return null;
    }

    const t_info = @typeInfo(T);

    if (t_info != .int) {
        @compileError("Only integers are supported");
    }

    if (t_info.int.signedness == .signed) {
        if (@bitSizeOf(T) == @bitSizeOf(f32)) {
            return @intFromFloat(v);
        }

        return @truncate(@as(i32, @intFromFloat(v)));
    }

    const uv: u32 = @bitCast(@as(i32, @intFromFloat(v)));

    if (@bitSizeOf(T) == @bitSizeOf(f32)) {
        return uv;
    }

    return @truncate(uv);
}
