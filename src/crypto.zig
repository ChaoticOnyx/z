// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");

const x = @import("x.zig");
const z = @import("root.zig");

const base64_encoder = std.base64.url_safe_no_pad.Encoder;

pub export fn Z_crypto_random_base64(argc: x.u4c, argv: [*c]x.ByondValue) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 1) {
        x.Byond_CRASH("Z_crypto_random_base64 requires 2 argument");

        return z.returnCast(.{});
    }

    const state = z.getState();
    const byond_len = &args[0];

    if (!x.ByondValue_IsNum(byond_len)) {
        x.Byond_CRASH("Len argument should be a number");

        return z.returnCast(.{});
    }

    const bytes = state.allocator.alloc(u8, @intFromFloat(x.ByondValue_GetNum(byond_len))) catch {
        x.Byond_CRASH("Failed to allocate memory for random bytes");

        return z.returnCast(.{});
    };

    std.crypto.random.bytes(bytes);

    const base64_len = base64_encoder.calcSize(bytes.len);
    const base64 = state.allocator.allocSentinel(u8, base64_len, 0) catch {
        x.Byond_CRASH("Failed to allocate a base64 string");

        return z.returnCast(.{});
    };
    defer state.allocator.free(base64);

    _ = base64_encoder.encode(base64, bytes);

    var ret: x.ByondValue = .{};
    x.ByondValue_SetStr(&ret, base64);

    return z.returnCast(ret);
}

pub export fn Z_crypto_hmac_sha256(argc: x.u4c, argv: [*c]x.ByondValue) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 2) {
        x.Byond_CRASH("Z_crypto_hmac_sha256 requires 2 argument");

        return z.returnCast(.{});
    }

    const state = z.getState();
    const byond_content = &args[0];

    if (!x.ByondValue_IsStr(byond_content)) {
        x.Byond_CRASH("Content argument should be a string");

        return z.returnCast(.{});
    }

    const byond_key = &args[1];

    if (!x.ByondValue_IsStr(byond_key)) {
        x.Byond_CRASH("Key argument should be a string");

        return z.returnCast(.{});
    }

    const content = x.toString(state.allocator, byond_content) catch |err| {
        std.log.err("Failed to convert content argument to string: {t}", .{err});

        return z.returnCast(.{});
    };
    defer state.allocator.free(content);

    const key = x.toString(state.allocator, byond_key) catch |err| {
        std.log.err("Failed to convert key argument to string: {t}", .{err});

        return z.returnCast(.{});
    };
    defer state.allocator.free(key);

    const HmacSha256 = std.crypto.auth.hmac.Hmac(std.crypto.hash.sha2.Sha256);

    var buf: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&buf, content, key);

    const base64_len = base64_encoder.calcSize(buf.len);
    const base64 = state.allocator.allocSentinel(u8, base64_len, 0) catch {
        x.Byond_CRASH("Failed to allocate a base64 string");

        return z.returnCast(.{});
    };
    defer state.allocator.free(base64);

    _ = base64_encoder.encode(base64, &buf);

    var ret: x.ByondValue = .{};
    x.ByondValue_SetStr(&ret, base64);

    return z.returnCast(ret);
}
