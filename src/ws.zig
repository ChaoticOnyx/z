// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");

const libws = @import("libws.zig");
const os = @import("os.zig");
const x = @import("x.zig");
const z = @import("root.zig");

inline fn getState() *State {
    return &z.getState().wsstate;
}

const WsConfig = struct {
    max_connections: u32 = 256,
    max_connections_per_ip: u8 = 5,

    handshake_timeout_ms: i64 = 5_000,
    idle_timeout_ms: i64 = 300_000,
    ping_interval_ms: i64 = 30_000,
    pong_timeout_ms: i64 = 10_000,

    max_message_size: usize = 1 * 1024 * 1024,
    max_frame_size: usize = 1 * 1024 * 1024,
    max_handshake_size: usize = 8192,

    rate_limit_messages_per_sec: u32 = 100,
    rate_limit_bytes_per_sec: usize = 1 * 1024 * 1024,
};

const WsStartError = error{
    AlreadyRunning,
    FailedToStart,
};

const WsTickError = error{
    OutOfMemory,
};

const Server = struct {
    const CallbackCode = enum(u8) {
        close = 1,
        _,
    };

    server: libws.Server,
    listener: *os.TcpListener,
    connections: std.ArrayList(libws.Connection),
    on_text_proc: ?u32,
    on_binary_proc: ?u32,

    pub inline fn init(
        allocator: std.mem.Allocator,
        port: u16,
        on_text_proc: ?u32,
        on_binary_proc: ?u32,
        config: WsConfig,
    ) !Server {
        var connections: std.ArrayList(libws.Connection) = .empty;
        try connections.ensureTotalCapacity(allocator, config.max_connections);

        var listener = try allocator.create(os.TcpListener);
        errdefer allocator.destroy(listener);

        listener.* = os.TcpListener.bind(os.Address.any(port), 128) catch |err| {
            std.log.err("Failed to bind a socket on port {}: {t}", .{ port, err });

            return err;
        };
        errdefer listener.deinit();

        const server_config: libws.Connection.Config = .{
            .handshake_timeout_ms = config.handshake_timeout_ms,
            .idle_timeout_ms = config.idle_timeout_ms,
            .ping_interval_ms = config.ping_interval_ms,
            .pong_timeout_ms = config.pong_timeout_ms,
            .max_message_size = config.max_message_size,
            .max_frame_size = config.max_frame_size,
            .max_handshake_size = config.max_handshake_size,
            .rate_limit_messages_per_sec = config.rate_limit_messages_per_sec,
            .rate_limit_bytes_per_sec = config.rate_limit_bytes_per_sec,
        };
        const tracker_config: libws.ConnectionTracker.Config = .{
            .max_connections = config.max_connections,
            .max_connections_per_ip = config.max_connections_per_ip,
        };

        const server = libws.Server.init(listener.interface(), server_config, os.NativeTimeProvider.interface(), .init(tracker_config));

        return .{
            .server = server,
            .listener = listener,
            .connections = connections,
            .on_text_proc = on_text_proc,
            .on_binary_proc = on_binary_proc,
        };
    }

    pub inline fn tick(this: *Server, allocator: std.mem.Allocator) WsTickError!void {
        // Accept new connections
        while (true) {
            var conn = this.server.acceptConnection(allocator) catch |err| {
                if (err == error.WouldBlock) {
                    break;
                }

                continue;
            };

            conn.performHandshake(allocator) catch {
                conn.deinit(allocator);

                continue;
            };

            this.connections.append(allocator, conn) catch {
                z.getState().last_error = @errorName(WsTickError.OutOfMemory);

                return WsTickError.OutOfMemory;
            };
        }

        // Process connections
        var i: usize = 0;

        while (i < this.connections.items.len) {
            var conn = &this.connections.items[i];

            conn.tick() catch {};

            // Read data
            data_blk: while (true) {
                const msg = conn.readMessage(allocator) catch |err| {
                    if (err == error.WouldBlock) {
                        break :data_blk;
                    }

                    conn.deinit(allocator);
                    _ = this.connections.swapRemove(i);

                    break :data_blk;
                };

                defer msg.deinit(allocator);

                switch (msg.opcode) {
                    .text => {
                        if (this.on_text_proc == null) {
                            continue;
                        }

                        var content: x.ByondValue = .{};
                        x.ByondValue_SetStr(&content, msg.payload);

                        var addr: [os.Address.MAX_STRING_LEN + 1]u8 = undefined;
                        var writer: std.Io.Writer = .fixed(&addr);

                        conn.getRemoteAddress().?.format(&writer) catch unreachable;
                        writer.writeByte(0) catch unreachable;

                        var byond_addr: x.ByondValue = .{};
                        x.ByondValue_SetStr(&byond_addr, addr[0 .. writer.end - 1 :0]);

                        var ret: x.ByondValue = .{};
                        if (!x.Byond_CallGlobalProcByStrId(this.on_text_proc.?, &.{ content, byond_addr, x.Num(i) }, &ret)) {
                            std.log.err("Failed to call on_text_proc callback", .{});

                            conn.deinit(allocator);
                            _ = this.connections.swapRemove(i);

                            break :data_blk;
                        }

                        if (x.ByondValue_IsNum(&ret)) {
                            const code = std.enums.fromInt(CallbackCode, @as(u32, @intFromFloat(x.ByondValue_GetNum(&ret)))).?;

                            switch (code) {
                                .close => {
                                    conn.deinit(allocator);
                                    _ = this.connections.swapRemove(i);

                                    break :data_blk;
                                },
                                else => continue,
                            }
                        }
                    },
                    .binary => {
                        if (this.on_binary_proc == null) {
                            continue;
                        }

                        var content: x.ByondValue = .{};
                        if (!x.Byond_CreateListLen(&content, msg.payload.len)) {
                            std.log.err("Failed to create a list fo size {} for a WebSocket message", .{msg.payload.len});

                            conn.deinit(allocator);
                            _ = this.connections.swapRemove(i);

                            break :data_blk;
                        }

                        for (msg.payload, 0..) |byte, idx| {
                            if (!x.Byond_WriteListIndex(&content, &x.Num(idx + 1), &x.Num(byte))) {
                                std.log.err("Failed to write a byte from a WebSocket message into list at {}", .{msg.payload.len});

                                conn.deinit(allocator);
                                _ = this.connections.swapRemove(i);

                                break :data_blk;
                            }
                        }

                        var addr: [os.Address.MAX_STRING_LEN + 1]u8 = undefined;
                        var writer: std.Io.Writer = .fixed(&addr);

                        conn.getRemoteAddress().?.format(&writer) catch unreachable;
                        writer.writeByte(0) catch unreachable;

                        var byond_addr: x.ByondValue = .{};
                        x.ByondValue_SetStr(&byond_addr, addr[0 .. writer.end - 1 :0]);

                        var ret: x.ByondValue = .{};
                        if (!x.Byond_CallGlobalProcByStrId(this.on_binary_proc.?, &.{ content, byond_addr, x.Num(i) }, &ret)) {
                            std.log.err("Failed to call on_binary_proc callback", .{});

                            conn.deinit(allocator);
                            _ = this.connections.swapRemove(i);

                            break :data_blk;
                        }

                        if (x.ByondValue_IsNum(&ret)) {
                            const code = std.enums.fromInt(CallbackCode, @as(u32, @intFromFloat(x.ByondValue_GetNum(&ret)))).?;

                            switch (code) {
                                .close => {
                                    conn.deinit(allocator);
                                    _ = this.connections.swapRemove(i);

                                    break :data_blk;
                                },
                                else => continue,
                            }
                        }
                    },
                    else => {},
                }
            }

            if (i < this.connections.items.len and &this.connections.items[i] == conn) {
                i += 1;
            }
        }
    }

    pub inline fn deinit(this: *Server, allocator: std.mem.Allocator) void {
        for (this.connections.items) |*conn| {
            conn.deinit(allocator);
        }

        this.connections.deinit(allocator);

        this.server.deinit(allocator);
        this.listener.deinit();

        allocator.destroy(this.listener);
    }
};

pub const State = struct {
    allocator: std.mem.Allocator,
    server: ?Server = null,

    pub inline fn init(allocator: std.mem.Allocator) State {
        return .{
            .allocator = allocator,
        };
    }

    pub inline fn start(
        this: *State,
        port: u16,
        on_text_proc: ?u32,
        on_binary_proc: ?u32,
        config: WsConfig,
    ) WsStartError!bool {
        if (this.server != null) {
            z.getState().last_error = @errorName(WsStartError.AlreadyRunning);

            return WsStartError.AlreadyRunning;
        }

        this.server = Server.init(this.allocator, port, on_text_proc, on_binary_proc, config) catch |err| {
            std.log.err("Failed to start a WebSocket server: {t}", .{err});
            z.getState().last_error = @errorName(WsStartError.FailedToStart);

            return WsStartError.FailedToStart;
        };

        return true;
    }

    pub inline fn tick(this: *State) WsTickError!bool {
        if (this.server) |*server| {
            try server.tick(this.allocator);

            return true;
        }

        return false;
    }

    pub inline fn getPort(this: *State) ?u16 {
        if (this.server) |*server| {
            if (server.listener.getLocalAddress()) |addr| {
                return addr.getPort();
            }
        }

        return null;
    }

    pub inline fn stop(this: *State) bool {
        if (this.server) |*server| {
            server.deinit(this.allocator);
            this.server = null;

            return true;
        }

        return false;
    }

    pub inline fn deinit(this: *State) void {
        _ = this.stop();
    }
};

pub export fn Z_ws_start(argc: x.u4c, argv: [*c]x.ByondValue) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 4) {
        x.Byond_CRASH("Z_ws_start requires 4 arguments");

        return z.returnCast(.{});
    }

    const state = getState();
    const byond_port = &args[0];

    if (!x.ByondValue_IsNum(byond_port)) {
        x.Byond_CRASH("Z_ws_start requires the first argument to be a number");

        return z.returnCast(.{});
    }

    const port: u16 = @intFromFloat(x.ByondValue_GetNum(byond_port));
    const byond_on_text_proc = &args[1];
    var on_text_proc: ?u32 = null;

    if (!x.ByondValue_IsNull(byond_on_text_proc)) {
        if (!x.ByondValue_IsStr(byond_on_text_proc)) {
            x.Byond_CRASH("The on_text_proc should be a string");

            return z.returnCast(.{});
        }

        on_text_proc = x.ByondValue_GetRef(byond_on_text_proc);
    }

    const byond_on_binary_proc = &args[2];
    var on_binary_proc: ?u32 = null;

    if (!x.ByondValue_IsNull(byond_on_binary_proc)) {
        if (!x.ByondValue_IsStr(byond_on_binary_proc)) {
            x.Byond_CRASH("The byond_on_binary_proc should be a string");

            return z.returnCast(.{});
        }

        on_binary_proc = x.ByondValue_GetRef(byond_on_binary_proc);
    }

    var config: WsConfig = .{};
    const byond_config = &args[3];

    if (!x.ByondValue_IsNull(byond_config)) {
        var buflen: x.u4c = 0;

        if (!x.Byond_ToString(byond_config, null, &buflen) and buflen == 0) {
            x.Byond_CRASH("Failed to Byond_ToString the cfg argument");

            return z.returnCast(.{});
        }

        const buf = state.allocator.allocSentinel(u8, buflen - 1, 0) catch {
            x.Byond_CRASH("Failed to allocate memory for the cfg argument");

            return z.returnCast(.{});
        };
        defer state.allocator.free(buf);

        if (!x.Byond_ToString(byond_config, buf.ptr, &buflen)) {
            x.Byond_CRASH("Failed to Byond_ToString the cfg argument");

            return z.returnCast(.{});
        }

        const parsed_config = std.json.parseFromSlice(WsConfig, state.allocator, buf, .{}) catch |err| {
            std.log.err("Failed to parse the cfg argument: {t}", .{err});
            x.Byond_CRASH("Failed to parse the cfg argument");

            return z.returnCast(.{});
        };

        config = parsed_config.value;
        parsed_config.deinit();
    }

    const ret = state.start(port, on_text_proc, on_binary_proc, config) catch {
        return z.returnCast(.{});
    };

    return z.returnCast(if (ret)
        x.True()
    else
        x.False());
}

pub export fn Z_ws_tick(argc: x.u4c, argv: [*c]x.ByondValue) z.ReturnType {
    _ = argv;

    if (argc != 0) {
        x.Byond_CRASH("Z_ws_tick does not accept args");

        return z.returnCast(.{});
    }

    const state = getState();
    const ret = state.tick() catch {
        return z.returnCast(.{});
    };

    return z.returnCast(if (ret)
        x.True()
    else
        x.False());
}

pub export fn Z_ws_send(argc: x.u4c, argv: [*c]x.ByondValue) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 2) {
        x.Byond_CRASH("Z_ws_send requires 2 arguments");

        return z.returnCast(.{});
    }

    const state = getState();
    const byond_idx = &args[0];
    const byond_content = &args[1];

    if (state.server == null) {
        return z.returnCast(x.False());
    }

    const idx: u32 = @intFromFloat(x.ByondValue_GetNum(byond_idx));

    if (idx >= state.server.?.connections.items.len) {
        return z.returnCast(x.False());
    }

    const conn = &state.server.?.connections.items[idx];

    if (x.ByondValue_IsStr(byond_content)) {
        var buflen: x.u4c = 0;

        if (!x.Byond_ToString(byond_content, null, &buflen) and buflen == 0) {
            std.log.err("Failed to Byond_ToString the content argument", .{});

            return z.returnCast(.{});
        }

        const buf = state.allocator.allocSentinel(u8, buflen - 1, 0) catch {
            x.Byond_CRASH("Failed to allocate memory for the content argument");

            return z.returnCast(.{});
        };
        defer state.allocator.free(buf);

        if (!x.Byond_ToString(byond_content, buf.ptr, &buflen)) {
            x.Byond_CRASH("Failed to Byond_ToString the content argument");

            return z.returnCast(.{});
        }

        conn.sendText(buf) catch {
            return z.returnCast(x.False());
        };

        return z.returnCast(x.True());
    } else if (x.ByondValue_IsList(byond_content)) {
        var byond_len: x.ByondValue = .{};

        if (!x.Byond_Length(byond_content, &byond_len)) {
            std.log.err("Failed to get length of the content argument", .{});

            return z.returnCast(.{});
        }

        const len: usize = @intFromFloat(x.ByondValue_GetNum(&byond_len));
        const content = state.allocator.alloc(u8, len) catch {
            x.Byond_CRASH("Failed to allocate memory for the content argument");

            return z.returnCast(.{});
        };
        defer state.allocator.free(content);

        for (0..len) |i| {
            var byond_value: x.ByondValue = .{};

            if (!x.Byond_ReadListIndex(byond_content, &x.Num(i + 1), &byond_value)) {
                std.log.err("Failed to read a value from the content argument at index {}", .{i});

                return z.returnCast(.{});
            }

            const value: u32 = @intFromFloat(x.ByondValue_GetNum(&byond_value));
            content[i] = @truncate(value);
        }

        conn.sendBinary(content) catch {
            return z.returnCast(x.False());
        };

        return z.returnCast(x.True());
    } else {
        x.Byond_CRASH("The content should be a string or a list");

        return z.returnCast(.{});
    }
}

pub export fn Z_ws_get_port(argc: x.u4c, argv: [*c]x.ByondValue) z.ReturnType {
    _ = argv;

    if (argc != 0) {
        x.Byond_CRASH("Z_ws_get_port does not accept args");

        return z.returnCast(.{});
    }

    const state = getState();
    const port = state.getPort() orelse {
        return z.returnCast(.{});
    };

    return z.returnCast(x.Num(port));
}

pub export fn Z_ws_connections(argc: x.u4c, argv: [*c]x.ByondValue) z.ReturnType {
    _ = argv;

    if (argc != 0) {
        x.Byond_CRASH("Z_ws_connections does not accept args");

        return z.returnCast(.{});
    }

    const state = getState();

    if (state.server == null) {
        return z.returnCast(.{});
    }

    const count = state.server.?.connections.items.len;

    return z.returnCast(x.Num(@truncate(count)));
}

pub export fn Z_ws_stop(argc: x.u4c, argv: [*c]x.ByondValue) z.ReturnType {
    _ = argv;

    if (argc != 0) {
        x.Byond_CRASH("Z_ws_stop does not accept args");

        return z.returnCast(.{});
    }

    const state = getState();

    return z.returnCast(if (state.stop())
        x.True()
    else
        x.False());
}
