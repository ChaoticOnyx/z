const std = @import("std");

const c = @cImport({
    @cInclude("time.h");
});

pub const Timezone = struct {
    offset_seconds: i32,

    pub fn getLocal() Timezone {
        var t: c.time_t = @intCast(std.time.timestamp());

        const local_ptr = c.localtime(&t);

        if (local_ptr == null) {
            return .{ .offset_seconds = 0 };
        }

        const local_tm = local_ptr.*;

        const utc_ptr = c.gmtime(&t);

        if (utc_ptr == null) {
            return .{ .offset_seconds = 0 };
        }

        const utc_tm = utc_ptr.*;

        const local_hours: i32 = @intCast(local_tm.tm_hour);
        const utc_hours: i32 = @intCast(utc_tm.tm_hour);
        const local_min: i32 = @intCast(local_tm.tm_min);
        const utc_min: i32 = @intCast(utc_tm.tm_min);
        const local_day: i32 = @intCast(local_tm.tm_yday);
        const utc_day: i32 = @intCast(utc_tm.tm_yday);

        var day_diff = local_day - utc_day;

        // 365 -> 0
        if (day_diff > 1) {
            day_diff = -1;
        }

        // 0 -> 365
        if (day_diff < -1) {
            day_diff = 1;
        }

        const hour_diff = local_hours - utc_hours + day_diff * 24;
        const min_diff = local_min - utc_min;

        return .{ .offset_seconds = hour_diff * 3600 + min_diff * 60 };
    }

    pub fn applyTo(self: Timezone, utc_timestamp: i64) i64 {
        return utc_timestamp + self.offset_seconds;
    }
};
