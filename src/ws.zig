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

const ConnectionMeta = struct {
    src: ?x.ByondValue = null,
    on_text_proc: ?u32 = null,
    on_binary_proc: ?u32 = null,
    on_disconnect_proc: ?u32 = null,

    pub inline fn deinit(this: *ConnectionMeta) void {
        if (this.src) |src| {
            x.ByondValue_DecRef(&src);
        }

        this.* = .{};
    }
};

const Server = struct {
    server: libws.Server,
    listener: *os.TcpListener,
    connections: std.ArrayList(libws.Connection),
    on_text_proc: ?u32,
    on_binary_proc: ?u32,
    is_processing: bool = false,

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

            const meta: *ConnectionMeta = allocator.create(ConnectionMeta) catch {
                conn.deinit(allocator);

                z.getState().last_error = @errorName(WsTickError.OutOfMemory);

                return WsTickError.OutOfMemory;
            };
            meta.* = .{};

            conn.userdata = meta;
            this.connections.append(allocator, conn) catch {
                allocator.destroy(meta);
                conn.deinit(allocator);

                z.getState().last_error = @errorName(WsTickError.OutOfMemory);

                return WsTickError.OutOfMemory;
            };
        }

        this.is_processing = true;
        defer this.is_processing = false;

        // Process connections
        var i: usize = 0;

        while (i < this.connections.items.len) {
            var conn = &this.connections.items[i];

            if (conn.userdata == null) {
                std.log.err("A connection {} without metadata", .{i});
                this.removeConnection(allocator, i);

                continue;
            }

            const meta: *ConnectionMeta = @ptrCast(@alignCast(conn.userdata.?));

            conn.tick() catch {
                this.removeConnection(allocator, i);

                continue;
            };

            var removed = false;

            // Read data
            data_blk: while (!removed) {
                const msg = conn.readMessage(allocator) catch |err| {
                    if (err == error.WouldBlock) {
                        break :data_blk;
                    }

                    this.removeConnection(allocator, i);
                    removed = true;
                    break :data_blk;
                };

                defer msg.deinit(allocator);

                switch (msg.opcode) {
                    .text => {
                        const src = meta.src;
                        const proc = if (src != null)
                            meta.on_text_proc
                        else
                            this.on_text_proc;

                        if (proc == null) {
                            continue :data_blk;
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

                        if (src == null) {
                            if (!x.Byond_CallGlobalProcByStrId(proc.?, &.{ content, byond_addr, x.num(i) }, &ret)) {
                                std.log.err("Failed to call on_text_proc callback", .{});

                                this.removeConnection(allocator, i);
                                removed = true;
                                break :data_blk;
                            }
                        } else {
                            if (!x.Byond_CallProcByStrId(&src.?, proc.?, &.{ content, byond_addr, x.num(i) }, &ret)) {
                                std.log.err("Failed to call on_text_proc callback", .{});

                                this.removeConnection(allocator, i);
                                removed = true;
                                break :data_blk;
                            }
                        }

                        if (!x.ByondValue_IsTrue(&ret)) {
                            this.removeConnection(allocator, i);
                            removed = true;
                            break :data_blk;
                        }
                    },
                    .binary => {
                        const src = meta.src;
                        const proc = if (src != null)
                            meta.on_binary_proc
                        else
                            this.on_binary_proc;

                        if (proc == null) {
                            continue :data_blk;
                        }

                        var content: x.ByondValue = .{};
                        if (!x.Byond_CreateListLen(&content, msg.payload.len)) {
                            std.log.err("Failed to create a list fo size {} for a WebSocket message", .{msg.payload.len});

                            this.removeConnection(allocator, i);
                            removed = true;
                            break :data_blk;
                        }

                        for (msg.payload, 0..) |byte, idx| {
                            if (!x.Byond_WriteListIndex(&content, &x.num(idx + 1), &x.num(byte))) {
                                std.log.err("Failed to write a byte from a WebSocket message into list at {}", .{msg.payload.len});

                                this.removeConnection(allocator, i);
                                removed = true;
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

                        if (src == null) {
                            if (!x.Byond_CallGlobalProcByStrId(proc.?, &.{ content, byond_addr, x.num(i) }, &ret)) {
                                std.log.err("Failed to call on_binary_proc callback", .{});

                                this.removeConnection(allocator, i);
                                removed = true;
                                break :data_blk;
                            }
                        } else {
                            if (!x.Byond_CallProcByStrId(&src.?, proc.?, &.{ content, byond_addr, x.num(i) }, &ret)) {
                                std.log.err("Failed to call on_binary_proc callback", .{});

                                this.removeConnection(allocator, i);
                                removed = true;
                                break :data_blk;
                            }
                        }

                        if (!x.ByondValue_IsTrue(&ret)) {
                            this.removeConnection(allocator, i);
                            removed = true;
                            break :data_blk;
                        }
                    },
                    else => {},
                }
            }

            if (i < this.connections.items.len) {
                i += 1;
            }
        }
    }

    pub inline fn removeConnection(this: *Server, allocator: std.mem.Allocator, idx: usize) void {
        const conn = &this.connections.items[idx];

        if (conn.userdata) |userdata| {
            const meta: *ConnectionMeta = @ptrCast(@alignCast(userdata));

            if (meta.src != null and meta.on_disconnect_proc != null) {
                var ret: x.ByondValue = .{};

                if (!x.Byond_CallProcByStrId(&meta.src.?, meta.on_disconnect_proc.?, &.{}, &ret)) {
                    std.log.err("Failed to call on_disconnect callback", .{});
                }
            }
        }

        freeMetadata(allocator, conn);
        conn.deinit(allocator);
        _ = this.connections.swapRemove(idx);
    }

    pub inline fn deinit(this: *Server, allocator: std.mem.Allocator) void {
        for (this.connections.items) |*conn| {
            freeMetadata(allocator, conn);
            conn.deinit(allocator);
        }

        this.connections.deinit(allocator);

        this.server.deinit(allocator);
        this.listener.deinit();

        allocator.destroy(this.listener);
    }

    inline fn freeMetadata(allocator: std.mem.Allocator, connection: *libws.Connection) void {
        if (connection.userdata) |userdata| {
            const meta: *ConnectionMeta = @ptrCast(@alignCast(userdata));
            meta.deinit();

            allocator.destroy(meta);
            connection.userdata = null;
        }
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

            if (!x.Byond_ReadListIndex(byond_content, &x.num(i + 1), &byond_value)) {
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

pub export fn Z_ws_tie(argc: x.u4c, argv: [*c]x.ByondValue) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 5) {
        x.Byond_CRASH("Z_ws_tie requires 5 arguments");

        return z.returnCast(.{});
    }

    const state = getState();

    if (state.server == null) {
        return z.returnCast(x.False());
    }

    const byond_idx = &args[0];

    if (!x.ByondValue_IsNum(byond_idx)) {
        x.Byond_CRASH("Idx should be a number");

        return z.returnCast(.{});
    }

    const idx: u32 = @intFromFloat(x.ByondValue_GetNum(byond_idx));
    if (idx >= state.server.?.connections.items.len) {
        return z.returnCast(x.False());
    }

    const conn = &state.server.?.connections.items[idx];

    if (conn.userdata == null) {
        std.log.err("Connection {} has no userdata", .{idx});
        x.Byond_CRASH("Connection has no userdata");

        return z.returnCast(.{});
    }

    const meta: *ConnectionMeta = @ptrCast(@alignCast(conn.userdata.?));

    if (meta.src != null) {
        return z.returnCast(x.False());
    }

    const obj = &args[1];
    const byond_on_text_proc = &args[2];
    const byond_on_binary_proc = &args[3];
    const byond_on_disconnect_proc = &args[4];

    if (x.ByondValue_IsNull(obj)) {
        x.Byond_CRASH("Obj should not be null");

        return z.returnCast(.{});
    }

    var on_text_proc: ?u32 = null;
    if (!x.ByondValue_IsNull(byond_on_text_proc)) {
        if (!x.ByondValue_IsStr(byond_on_text_proc)) {
            x.Byond_CRASH("On_text_proc should be a string");

            return z.returnCast(.{});
        }

        on_text_proc = x.ByondValue_GetRef(byond_on_text_proc);
    }

    var on_binary_proc: ?u32 = null;
    if (!x.ByondValue_IsNull(byond_on_binary_proc)) {
        if (!x.ByondValue_IsStr(byond_on_binary_proc)) {
            x.Byond_CRASH("On_binary_proc should be a string");

            return z.returnCast(.{});
        }

        on_binary_proc = x.ByondValue_GetRef(byond_on_binary_proc);
    }

    var on_disconnect_proc: ?u32 = null;
    if (!x.ByondValue_IsNull(byond_on_disconnect_proc)) {
        if (!x.ByondValue_IsStr(byond_on_disconnect_proc)) {
            x.Byond_CRASH("On_disconnect_proc should be a string");

            return z.returnCast(.{});
        }

        on_disconnect_proc = x.ByondValue_GetRef(byond_on_disconnect_proc);
    }

    x.ByondValue_IncRef(obj);

    meta.* = .{
        .src = obj.*,
        .on_text_proc = on_text_proc,
        .on_binary_proc = on_binary_proc,
        .on_disconnect_proc = on_disconnect_proc,
    };

    return z.returnCast(x.True());
}

pub export fn Z_ws_get_tied(argc: x.u4c, argv: [*c]x.ByondValue) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 1) {
        x.Byond_CRASH("Z_ws_get_tied requires 1 argument");

        return z.returnCast(.{});
    }

    const state = getState();

    if (state.server == null) {
        return z.returnCast(x.False());
    }

    const byond_obj = &args[0];

    if (x.ByondValue_IsNull(byond_obj)) {
        x.Byond_CRASH("Obj should not be null");

        return z.returnCast(.{});
    }

    const obj_ref = x.ByondValue_GetRef(byond_obj);

    for (state.server.?.connections.items, 0..) |*conn, i| {
        if (conn.userdata == null) {
            continue;
        }

        const meta: *ConnectionMeta = @ptrCast(@alignCast(conn.userdata.?));

        if (meta.src == null) {
            continue;
        }

        const conn_ref = x.ByondValue_GetRef(&meta.src.?);

        if (obj_ref == conn_ref) {
            return z.returnCast(x.num(i));
        }
    }

    return z.returnCast(.{});
}

pub export fn Z_ws_untie(argc: x.u4c, argv: [*c]x.ByondValue) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 1) {
        x.Byond_CRASH("Z_ws_untie requires 1 argument");

        return z.returnCast(.{});
    }

    const state = getState();

    if (state.server == null) {
        return z.returnCast(x.False());
    }

    const byond_idx = &args[0];

    if (!x.ByondValue_IsNum(byond_idx)) {
        x.Byond_CRASH("Idx should be a number");

        return z.returnCast(.{});
    }

    const idx: u32 = @intFromFloat(x.ByondValue_GetNum(byond_idx));
    if (idx >= state.server.?.connections.items.len) {
        return z.returnCast(x.False());
    }

    const conn = &state.server.?.connections.items[idx];

    if (conn.userdata == null) {
        std.log.err("Connection {} has no userdata", .{idx});
        x.Byond_CRASH("Connection has no userdata");

        return z.returnCast(.{});
    }

    const meta: *ConnectionMeta = @ptrCast(@alignCast(conn.userdata.?));

    if (meta.src == null) {
        return z.returnCast(x.False());
    }

    meta.deinit();

    return z.returnCast(x.True());
}

pub export fn Z_ws_disconnect(argc: x.u4c, argv: [*c]x.ByondValue) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 1) {
        x.Byond_CRASH("Z_ws_disconnect requires 1 argument");

        return z.returnCast(.{});
    }

    const state = getState();

    if (state.server == null) {
        return z.returnCast(x.False());
    }

    if (state.server.?.is_processing) {
        x.Byond_CRASH("Trying to disconnect while processing the connections");

        return z.returnCast(.{});
    }

    const byond_idx = &args[0];

    if (!x.ByondValue_IsNum(byond_idx)) {
        x.Byond_CRASH("Idx should be a number");

        return z.returnCast(.{});
    }

    const idx: u32 = @intFromFloat(x.ByondValue_GetNum(byond_idx));
    if (idx >= state.server.?.connections.items.len) {
        return z.returnCast(x.False());
    }

    state.server.?.removeConnection(state.allocator, idx);

    return z.returnCast(x.True());
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

    return z.returnCast(x.num(port));
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

    return z.returnCast(x.num(@truncate(count)));
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
