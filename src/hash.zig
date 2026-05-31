// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");

const c = @import("basic26");

const helpers = @import("helpers.zig");
const x = @import("x.zig");
const z = @import("root.zig");

export fn Z_hash_xxhash32(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 2) {
        x.Byond_CRASH("Z_hash_xxhash32 requires 2 argument");

        return z.returnCast(.{});
    }

    const seed = helpers.safeIntTruncate(i32, x.ByondValue_GetNum(&args[0])) orelse {
        x.Byond_CRASH("Bad seed");

        return z.returnCast(.{});
    };

    if (x.ByondValue_IsNum(&args[1])) {
        const value: f32 = x.ByondValue_GetNum(&args[1]);
        const hash = std.hash.XxHash32.hash(@bitCast(seed), std.mem.asBytes(&value));

        return z.returnCast(x.num(hash));
    } else if (x.ByondValue_IsStr(&args[1])) {
        const value = x.toString(z.getState().allocator, &args[1]) catch {
            x.Byond_CRASH("String value is too long");

            return z.returnCast(.{});
        };
        defer z.getState().allocator.free(value);

        const hash = std.hash.XxHash32.hash(@bitCast(seed), value);

        return z.returnCast(x.num(hash));
    }

    return z.returnCast(.{});
}
