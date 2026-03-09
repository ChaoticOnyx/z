// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const os = @import("os.zig");

pub const ConnectionTracker = struct {
    current_connections: u32 = 0,
    ip_connections: std.AutoHashMapUnmanaged(u32, u8) = .empty,
    config: Config,

    pub const Config = struct {
        max_connections: u32 = 256,
        max_connections_per_ip: u8 = 5,
    };

    pub const AcquireError = error{
        TooManyConnections,
        TooManyConnectionsFromIp,
        OutOfMemory,
    };

    pub inline fn init(config: Config) ConnectionTracker {
        return .{
            .config = config,
        };
    }

    pub inline fn deinit(this: *ConnectionTracker, allocator: std.mem.Allocator) void {
        this.ip_connections.deinit(allocator);
    }

    pub inline fn tryAcquire(this: *ConnectionTracker, allocator: std.mem.Allocator, ip: [4]u8) AcquireError!void {
        if (this.current_connections >= this.config.max_connections) {
            return error.TooManyConnections;
        }

        const ip_key = ipToKey(ip);
        const current_from_ip = this.ip_connections.get(ip_key) orelse 0;

        if (this.config.max_connections_per_ip > 0 and current_from_ip >= this.config.max_connections_per_ip) {
            return error.TooManyConnectionsFromIp;
        }

        this.ip_connections.put(allocator, ip_key, current_from_ip + 1) catch {
            return error.OutOfMemory;
        };

        this.current_connections += 1;
    }

    pub inline fn release(this: *ConnectionTracker, allocator: std.mem.Allocator, ip: [4]u8) void {
        const ip_key = ipToKey(ip);

        if (this.ip_connections.get(ip_key)) |count| {
            if (count <= 1) {
                _ = this.ip_connections.remove(ip_key);
            } else {
                this.ip_connections.put(allocator, ip_key, count - 1) catch {};
            }
        }

        if (this.current_connections > 0) {
            this.current_connections -= 1;
        }
    }

    pub inline fn getConnectionCount(this: *const ConnectionTracker) u32 {
        return this.current_connections;
    }

    pub inline fn getConnectionCountFromIp(this: *const ConnectionTracker, ip: [4]u8) u8 {
        return this.ip_connections.get(ipToKey(ip)) orelse 0;
    }

    inline fn ipToKey(ip: [4]u8) u32 {
        return @bitCast(ip);
    }
};

pub const Stream = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const ReadError = error{
        WouldBlock,
        ConnectionReset,
        ConnectionRefused,
        BrokenPipe,
        Unexpected,
        OutOfMemory,
        ConnectionClosed,
        Timeout,
    };

    pub const WriteError = error{
        WouldBlock,
        ConnectionReset,
        BrokenPipe,
        Unexpected,
        OutOfMemory,
    };

    pub const VTable = struct {
        read: *const fn (ctx: *anyopaque, buf: []u8) ReadError!usize,
        write: *const fn (ctx: *anyopaque, data: []const u8) WriteError!usize,
        get_remote_address: *const fn (ctx: *anyopaque) ?os.Address,
        deinit: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) void,
    };

    pub inline fn read(this: Stream, buf: []u8) ReadError!usize {
        return this.vtable.read(this.ptr, buf);
    }

    pub inline fn write(this: Stream, data: []const u8) WriteError!usize {
        return this.vtable.write(this.ptr, data);
    }

    pub inline fn getRemoteAddress(this: Stream) ?os.Address {
        return this.vtable.get_remote_address(this.ptr);
    }

    pub inline fn writeAll(this: Stream, data: []const u8) WriteError!void {
        var written: usize = 0;

        while (written < data.len) {
            written += try this.write(data[written..]);
        }
    }

    pub inline fn deinit(this: Stream, allocator: std.mem.Allocator) void {
        this.vtable.deinit(this.ptr, allocator);
    }
};

pub const Listener = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const AcceptError = error{
        WouldBlock,
        SystemResources,
        Unexpected,
    };

    pub const VTable = struct {
        accept: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) AcceptError!Stream,
    };

    pub inline fn accept(this: Listener, allocator: std.mem.Allocator) AcceptError!Stream {
        return this.vtable.accept(this.ptr, allocator);
    }
};

pub const TimeProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        milliTimestamp: *const fn (ctx: *anyopaque) i64,
    };

    pub inline fn milliTimestamp(this: TimeProvider) i64 {
        return this.vtable.milliTimestamp(this.ptr);
    }
};

pub const RealTimeProvider = struct {
    pub fn milliTimestamp(ctx: *anyopaque) i64 {
        _ = ctx;

        return std.time.milliTimestamp();
    }

    pub fn interface() TimeProvider {
        return .{
            .ptr = undefined,
            .vtable = &.{ .milliTimestamp = milliTimestamp },
        };
    }
};

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,

    pub inline fn isControl(this: Opcode) bool {
        return @intFromEnum(this) >= 0x8;
    }

    pub inline fn isValid(this: Opcode) bool {
        return switch (this) {
            .continuation, .text, .binary, .close, .ping, .pong => true,
            _ => false,
        };
    }
};

pub const CloseCode = enum(u16) {
    normal_closure = 1000,
    going_away = 1001,
    protocol_error = 1002,
    unsupported_data = 1003,
    no_status_received = 1005,
    abnormal_closure = 1006,
    invalid_payload = 1007,
    policy_violation = 1008,
    message_too_big = 1009,
    mandatory_extension = 1010,
    internal_error = 1011,
    tls_handshake = 1015,
    _,

    /// Validates if a close code can be sent in a close frame (RFC 6455 Section 7.4.1)
    pub inline fn isValidForSend(code: u16) bool {
        if (code < 1000) {
            return false;
        }

        if (code >= 1004 and code <= 1006) {
            return false;
        }

        if (code >= 1014 and code < 3000) {
            return false;
        }

        if (code >= 5000) {
            return false;
        }

        return true;
    }

    /// Validates if a received close code is valid (RFC 6455 Section 7.4)
    pub inline fn isValidReceived(code: u16) bool {
        if (code < 1000) {
            return false;
        }

        if (code == 1004) {
            return false;
        }

        // 1005, 1006, 1015: Should never appear in close frames
        if (code == 1005 or code == 1006 or code == 1015) {
            return false;
        }

        if (code >= 1016 and code < 3000) {
            return false;
        }

        if (code >= 5000) {
            return false;
        }

        return true;
    }
};

pub const Message = struct {
    opcode: Opcode,
    payload: [:0]const u8,

    pub inline fn deinit(this: *const Message, allocator: std.mem.Allocator) void {
        allocator.free(this.payload);
    }
};

pub const HandshakeError = error{
    InvalidMethod,
    InvalidHttpVersion,
    MissingUpgradeHeader,
    MissingConnectionHeader,
    MissingSecWebSocketKey,
    InvalidSecWebSocketKey,
    MissingSecWebSocketVersion,
    UnsupportedWebSocketVersion,
    HandshakeTooLarge,
    ConnectionClosed,
    InvalidRequest,
    MalformedHeader,
    HandshakeTimeout,
    InvalidState,
} || Stream.ReadError || Stream.WriteError;

pub const FrameError = error{
    InvalidOpcode,
    UnmaskedClientFrame,
    InvalidControlFrameLength,
    FragmentedControlFrame,
    InvalidPayloadLength,
    MessageTooLarge,
    ReservedBitsSet,
    UnexpectedContinuation,
    ExpectedContinuation,
    ConnectionClosed,
    InvalidUtf8,
    RateLimitExceeded,
    InvalidState,
    IdleTimeout,
    PongTimeout,
    InvalidCloseCode,
} || Stream.ReadError || std.mem.Allocator.Error;

pub const SendError = error{
    InvalidState,
    PayloadTooLarge,
    WriteBufferFull,
} || Stream.WriteError;

pub const Connection = struct {
    stream: Stream,
    state: State = .connecting,
    read_buffer: std.ArrayList(u8) = .empty,
    write_buffer: std.ArrayList(u8) = .empty,
    write_pos: usize = 0,
    fragment_buffer: std.ArrayList(u8) = .empty,
    fragment_opcode: ?Opcode = null,
    config: Config,
    time_provider: TimeProvider,
    userdata: ?*anyopaque = null,

    // Timing
    handshake_start_time: i64 = 0,
    last_activity_time: i64 = 0,
    last_ping_time: i64 = 0,
    awaiting_pong: bool = false,

    // Rate limiting
    rate_window_start: i64 = 0,
    messages_in_window: u32 = 0,
    bytes_in_window: usize = 0,

    // Close tracking
    close_code_sent: ?CloseCode = null,
    tracker: ?*ConnectionTracker = null,
    remote_address: ?os.Address,

    // Frame parsing state (for resumable parsing)
    frame_state: FrameParseState = .{},

    const WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

    pub const State = enum {
        connecting,
        open,
        closing,
        closed,

        pub inline fn canRead(this: State) bool {
            return this == .open or this == .closing;
        }

        pub inline fn canWrite(this: State) bool {
            return this == .open;
        }
    };

    const FrameParseState = struct {
        phase: Phase = .header,
        fin: bool = false,
        opcode: Opcode = .continuation,
        payload_len: u64 = 0,
        mask_key: [4]u8 = undefined,
        payload: ?[:0]u8 = null,
        payload_read: usize = 0,

        const Phase = enum {
            header,
            extended_len_16,
            extended_len_64,
            mask,
            payload,
        };

        fn reset(this: *FrameParseState) void {
            this.* = .{};
        }
    };

    pub const Config = struct {
        handshake_timeout_ms: i64 = 5_000,
        idle_timeout_ms: i64 = 300_000,
        ping_interval_ms: i64 = 30_000,
        pong_timeout_ms: i64 = 10_000,

        max_message_size: usize = 1 * 1024 * 1024,
        max_frame_size: usize = 1 * 1024 * 1024,
        max_handshake_size: usize = 8192,
        max_write_buffer_size: usize = 64 * 1024,

        rate_limit_messages_per_sec: u32 = 100,
        rate_limit_bytes_per_sec: usize = 1 * 1024 * 1024,

        trust_x_real_ip: bool = false,
    };

    pub inline fn init(
        stream: Stream,
        config: Config,
        time_provider: TimeProvider,
    ) Connection {
        const now = time_provider.milliTimestamp();

        return .{
            .stream = stream,
            .config = config,
            .time_provider = time_provider,
            .handshake_start_time = now,
            .last_activity_time = now,
            .rate_window_start = now,
            .remote_address = stream.getRemoteAddress(),
        };
    }

    pub inline fn initTracked(
        stream: Stream,
        config: Config,
        time_provider: TimeProvider,
        tracker: *ConnectionTracker,
    ) Connection {
        var conn = init(stream, config, time_provider);
        conn.tracker = tracker;

        return conn;
    }

    pub inline fn getRemoteAddress(this: *const Connection) ?os.Address {
        return this.remote_address;
    }

    pub inline fn deinit(this: *Connection, allocator: std.mem.Allocator) void {
        if (this.tracker) |tracker| {
            const ip = if (this.remote_address) |addr|
                addr.getIp()
            else
                [4]u8{ 0, 0, 0, 0 };

            tracker.release(allocator, ip);
            this.tracker = null;
        }

        if (this.frame_state.payload) |payload| {
            allocator.free(payload);
            this.frame_state.payload = null;
        }

        this.read_buffer.deinit(allocator);
        this.write_buffer.deinit(allocator);
        this.fragment_buffer.deinit(allocator);
        this.stream.deinit(allocator);
        this.state = .closed;
    }

    /// Flushes pending write buffer. Returns true if all data was sent.
    /// Call this when socket becomes writable after WouldBlock.
    pub inline fn flushWrites(this: *Connection) Stream.WriteError!bool {
        while (this.write_pos < this.write_buffer.items.len) {
            const n = this.stream.write(this.write_buffer.items[this.write_pos..]) catch |err| {
                if (err == error.WouldBlock) {
                    return false;
                }

                return err;
            };

            this.write_pos += n;
        }

        this.write_buffer.clearRetainingCapacity();
        this.write_pos = 0;

        return true;
    }

    /// Returns true if there's pending data to write
    pub inline fn hasPendingWrites(this: *const Connection) bool {
        return this.write_pos < this.write_buffer.items.len;
    }

    pub fn performHandshake(this: *Connection, allocator: std.mem.Allocator) HandshakeError!void {
        if (this.state != .connecting) {
            return error.InvalidState;
        }

        // First, try to flush any pending writes (handshake response from previous call)
        if (this.hasPendingWrites()) {
            const flushed = this.flushWrites() catch |err| {
                this.state = .closed;

                return err;
            };

            if (!flushed) {
                return error.WouldBlock;
            }

            // Response was fully sent, handshake complete
            this.state = .open;
            this.last_activity_time = this.time_provider.milliTimestamp();

            return;
        }

        // Check for headers end in existing buffer
        var headers_end = std.mem.indexOf(u8, this.read_buffer.items, "\r\n\r\n");

        while (headers_end == null) {
            const now = this.time_provider.milliTimestamp();

            if (now - this.handshake_start_time > this.config.handshake_timeout_ms) {
                this.state = .closed;

                return error.HandshakeTimeout;
            }

            // Try to read more data
            var buf: [1024]u8 = undefined;
            const n = this.stream.read(&buf) catch |err| {
                if (err == error.WouldBlock) {
                    return error.WouldBlock;
                }

                this.state = .closed;

                return err;
            };

            if (n == 0) {
                this.state = .closed;

                return error.ConnectionClosed;
            }

            if (this.read_buffer.items.len + n > this.config.max_handshake_size) {
                this.state = .closed;

                return error.HandshakeTooLarge;
            }

            this.read_buffer.appendSlice(allocator, buf[0..n]) catch |err| {
                this.state = .closed;

                return err;
            };

            headers_end = std.mem.indexOf(u8, this.read_buffer.items, "\r\n\r\n");
        }

        const header_end = headers_end.?;
        const request = this.read_buffer.items[0 .. header_end + 4];

        const result = this.parseAndValidateHandshake(request) catch |err| {
            this.sendHttpError(allocator, 400, "Bad Request") catch {};
            this.state = .closed;

            return err;
        };

        if (result.real_ip) |real_ip| {
            const port = if (this.remote_address) |addr|
                addr.getPort()
            else
                0;

            if (this.tracker) |tracker| {
                const old_ip = if (this.remote_address) |addr|
                    addr.getIp()
                else
                    [4]u8{ 0, 0, 0, 0 };

                tracker.release(allocator, old_ip);
                tracker.tryAcquire(allocator, real_ip) catch |track_err| {
                    this.state = .closed;
                    this.sendHttpError(allocator, 429, "Too Many Connections") catch {};

                    return switch (track_err) {
                        error.OutOfMemory => error.OutOfMemory,
                        else => error.ConnectionClosed,
                    };
                };
            }

            this.remote_address = os.Address.init(real_ip, port);
        }

        // Queue handshake response
        this.queueHandshakeResponse(allocator, &result.accept_key) catch |err| {
            this.state = .closed;

            return err;
        };

        // Keep any data after headers for frame parsing
        const remaining_start = header_end + 4;

        if (remaining_start < this.read_buffer.items.len) {
            const remaining_len = this.read_buffer.items.len - remaining_start;

            @memmove(
                this.read_buffer.items[0..remaining_len],
                this.read_buffer.items[remaining_start..],
            );

            this.read_buffer.shrinkRetainingCapacity(remaining_len);
        } else {
            this.read_buffer.clearRetainingCapacity();
        }

        // Try to flush immediately
        const flushed = this.flushWrites() catch |err| {
            this.state = .closed;

            return err;
        };

        if (!flushed) {
            // Response not fully sent, will complete on next call
            return error.WouldBlock;
        }

        this.state = .open;
        this.last_activity_time = this.time_provider.milliTimestamp();
    }

    const HandshakeResult = struct {
        accept_key: [28]u8,
        real_ip: ?[4]u8,
    };

    fn parseAndValidateHandshake(this: *Connection, request: []const u8) HandshakeError!HandshakeResult {
        var lines = std.mem.splitSequence(u8, request, "\r\n");
        const request_line = lines.first();

        var parts = std.mem.splitScalar(u8, request_line, ' ');

        const method = parts.next() orelse {
            return error.InvalidRequest;
        };

        _ = parts.next() orelse {
            return error.InvalidRequest;
        };

        const version = parts.next() orelse {
            return error.InvalidRequest;
        };

        if (!std.mem.eql(u8, method, "GET")) {
            return error.InvalidMethod;
        }

        if (!std.mem.startsWith(u8, version, "HTTP/1.1")) {
            return error.InvalidHttpVersion;
        }

        var upgrade_websocket = false;
        var connection_upgrade = false;
        var sec_websocket_key: ?[]const u8 = null;
        var sec_websocket_version: ?[]const u8 = null;
        var real_ip: ?[4]u8 = null;

        while (lines.next()) |line| {
            if (line.len == 0) {
                break;
            }

            const colon_pos = std.mem.indexOf(u8, line, ":") orelse {
                continue;
            };

            const header_name = std.mem.trim(u8, line[0..colon_pos], " \t");
            const header_value = std.mem.trim(u8, line[colon_pos + 1 ..], " \t");

            if (std.ascii.eqlIgnoreCase(header_name, "Upgrade")) {
                if (std.ascii.eqlIgnoreCase(header_value, "websocket")) {
                    upgrade_websocket = true;
                }
            } else if (std.ascii.eqlIgnoreCase(header_name, "Connection")) {
                var values = std.mem.splitAny(u8, header_value, ", \t");

                while (values.next()) |val| {
                    const trimmed = std.mem.trim(u8, val, " \t");

                    if (std.ascii.eqlIgnoreCase(trimmed, "Upgrade")) {
                        connection_upgrade = true;

                        break;
                    }
                }
            } else if (std.ascii.eqlIgnoreCase(header_name, "Sec-WebSocket-Key")) {
                sec_websocket_key = header_value;
            } else if (std.ascii.eqlIgnoreCase(header_name, "Sec-WebSocket-Version")) {
                sec_websocket_version = header_value;
            } else if (std.ascii.eqlIgnoreCase(header_name, "X-Real-IP")) {
                if (!this.config.trust_x_real_ip) {
                    return error.InvalidRequest;
                }

                real_ip = os.Address.parseIp(header_value);
            }
        }

        if (!upgrade_websocket) {
            return error.MissingUpgradeHeader;
        }

        if (!connection_upgrade) {
            return error.MissingConnectionHeader;
        }

        const key = sec_websocket_key orelse {
            return error.MissingSecWebSocketKey;
        };

        if (key.len < 22 or key.len > 24) {
            return error.InvalidSecWebSocketKey;
        }

        const version_str = sec_websocket_version orelse {
            return error.MissingSecWebSocketVersion;
        };

        if (!std.mem.eql(u8, version_str, "13")) {
            return error.UnsupportedWebSocketVersion;
        }

        var hasher = std.crypto.hash.Sha1.init(.{});
        hasher.update(key);
        hasher.update(WEBSOCKET_GUID);
        const hash = hasher.finalResult();

        var accept_key: [28]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&accept_key, &hash);

        return .{
            .accept_key = accept_key,
            .real_ip = real_ip,
        };
    }

    inline fn queueHandshakeResponse(this: *Connection, allocator: std.mem.Allocator, accept_key: *const [28]u8) !void {
        const response =
            "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: ";

        try this.write_buffer.appendSlice(allocator, response);
        try this.write_buffer.appendSlice(allocator, accept_key);
        try this.write_buffer.appendSlice(allocator, "\r\n\r\n");
    }

    inline fn sendHttpError(this: *Connection, allocator: std.mem.Allocator, code: u16, message: []const u8) !void {
        var buf: [256]u8 = undefined;
        const response = std.fmt.bufPrint(&buf, "HTTP/1.1 {d} {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{ code, message }) catch return;

        try this.write_buffer.appendSlice(allocator, response);
        _ = this.flushWrites() catch {};
    }

    /// Reads data from socket into read_buffer until we have at least `needed` bytes
    inline fn ensureReadBuffer(this: *Connection, allocator: std.mem.Allocator, needed: usize) FrameError!void {
        while (this.read_buffer.items.len < needed) {
            var buf: [4096]u8 = undefined;
            const n = this.stream.read(&buf) catch |err| {
                return err;
            };

            if (n == 0) {
                return error.ConnectionClosed;
            }

            try this.read_buffer.appendSlice(allocator, buf[0..n]);
        }
    }

    /// Consumes n bytes from the front of read_buffer
    inline fn consumeReadBuffer(this: *Connection, n: usize) void {
        const remaining = this.read_buffer.items.len - n;

        if (remaining > 0) {
            @memmove(
                this.read_buffer.items[0..remaining],
                this.read_buffer.items[n..],
            );
        }

        this.read_buffer.shrinkRetainingCapacity(remaining);
    }

    pub fn readMessage(this: *Connection, allocator: std.mem.Allocator) FrameError!Message {
        if (!this.state.canRead()) {
            return error.InvalidState;
        }

        while (true) {
            try this.checkTimeouts();

            const frame = this.readFrame(allocator) catch |err| {
                switch (err) {
                    error.WouldBlock => return error.WouldBlock,
                    error.UnmaskedClientFrame,
                    error.InvalidOpcode,
                    error.ReservedBitsSet,
                    error.FragmentedControlFrame,
                    error.InvalidControlFrameLength,
                    error.InvalidPayloadLength,
                    error.UnexpectedContinuation,
                    error.ExpectedContinuation,
                    => {
                        this.closeWithError(allocator, .protocol_error, "Protocol error") catch {};

                        return err;
                    },
                    error.MessageTooLarge => {
                        this.closeWithError(allocator, .message_too_big, "Message too large") catch {};

                        return err;
                    },
                    error.InvalidUtf8 => {
                        this.closeWithError(allocator, .invalid_payload, "Invalid UTF-8") catch {};

                        return err;
                    },
                    error.RateLimitExceeded => {
                        this.closeWithError(allocator, .policy_violation, "Rate limit exceeded") catch {};

                        return err;
                    },
                    else => return err,
                }
            };

            this.last_activity_time = this.time_provider.milliTimestamp();

            switch (frame.opcode) {
                .ping => {
                    this.sendPong(allocator, frame.payload) catch {};
                    allocator.free(frame.payload);
                },
                .pong => {
                    this.awaiting_pong = false;
                    allocator.free(frame.payload);
                },
                .close => {
                    return this.handleCloseFrame(allocator, frame.payload);
                },
                .continuation => {
                    if (this.fragment_opcode == null) {
                        allocator.free(frame.payload);
                        this.closeWithError(allocator, .protocol_error, "Unexpected continuation") catch {};

                        return error.UnexpectedContinuation;
                    }

                    if (this.fragment_buffer.items.len +| frame.payload.len > this.config.max_message_size) {
                        allocator.free(frame.payload);
                        this.closeWithError(allocator, .message_too_big, "Message too large") catch {};

                        return error.MessageTooLarge;
                    }

                    this.fragment_buffer.appendSlice(allocator, frame.payload) catch |err| {
                        allocator.free(frame.payload);

                        return err;
                    };
                    allocator.free(frame.payload);

                    if (frame.fin) {
                        const opcode = this.fragment_opcode.?;
                        this.fragment_opcode = null;

                        if (opcode == .text) {
                            if (!std.unicode.utf8ValidateSlice(this.fragment_buffer.items)) {
                                this.fragment_buffer.clearRetainingCapacity();
                                this.closeWithError(allocator, .invalid_payload, "Invalid UTF-8") catch {};

                                return error.InvalidUtf8;
                            }
                        }

                        return Message{
                            .opcode = opcode,
                            .payload = try this.fragment_buffer.toOwnedSliceSentinel(allocator, 0),
                        };
                    }
                },
                .text, .binary => {
                    if (this.fragment_opcode != null) {
                        allocator.free(frame.payload);
                        this.closeWithError(allocator, .protocol_error, "Expected continuation") catch {};

                        return error.ExpectedContinuation;
                    }

                    if (frame.fin) {
                        if (frame.opcode == .text) {
                            if (!std.unicode.utf8ValidateSlice(frame.payload)) {
                                allocator.free(frame.payload);
                                this.closeWithError(allocator, .invalid_payload, "Invalid UTF-8") catch {};

                                return error.InvalidUtf8;
                            }
                        }

                        return Message{
                            .opcode = frame.opcode,
                            .payload = frame.payload,
                        };
                    } else {
                        this.fragment_opcode = frame.opcode;
                        this.fragment_buffer.clearRetainingCapacity();
                        this.fragment_buffer.appendSlice(allocator, frame.payload) catch |err| {
                            allocator.free(frame.payload);
                            this.fragment_opcode = null;

                            return err;
                        };
                        allocator.free(frame.payload);
                    }
                },
                _ => {
                    allocator.free(frame.payload);
                    this.closeWithError(allocator, .protocol_error, "Invalid opcode") catch {};

                    return error.InvalidOpcode;
                },
            }
        }
    }

    fn handleCloseFrame(this: *Connection, allocator: std.mem.Allocator, payload: [:0]u8) FrameError!Message {
        defer allocator.free(payload);

        var received_code: CloseCode = .no_status_received;

        if (payload.len >= 2) {
            const code_value = std.mem.readInt(u16, payload[0..2], .big);

            if (!CloseCode.isValidReceived(code_value)) {
                if (this.state == .open) {
                    this.closeWithError(allocator, .protocol_error, "Invalid close code") catch {};
                }

                this.state = .closed;

                return error.InvalidCloseCode;
            }

            received_code = @enumFromInt(code_value);
        }

        if (payload.len > 2) {
            if (!std.unicode.utf8ValidateSlice(payload[2..])) {
                if (this.state == .open) {
                    this.closeWithError(allocator, .invalid_payload, "Invalid UTF-8 in close reason") catch {};
                }

                this.state = .closed;

                return error.InvalidUtf8;
            }
        }

        if (this.state == .open) {
            this.state = .closing;
            this.sendCloseFrame(allocator, @intFromEnum(received_code), "") catch {};
        }

        this.state = .closed;

        return error.ConnectionClosed;
    }

    const Frame = struct {
        fin: bool,
        opcode: Opcode,
        payload: [:0]u8,
    };

    fn readFrame(this: *Connection, allocator: std.mem.Allocator) FrameError!Frame {
        try this.checkRateLimit(0);

        // State machine for frame parsing
        while (true) {
            switch (this.frame_state.phase) {
                .header => {
                    try this.ensureReadBuffer(allocator, 2);

                    const header = this.read_buffer.items[0..2];
                    this.frame_state.fin = (header[0] & 0x80) != 0;
                    const rsv = header[0] & 0x70;
                    this.frame_state.opcode = @enumFromInt(header[0] & 0x0F);
                    const masked = (header[1] & 0x80) != 0;
                    const len7 = header[1] & 0x7F;

                    if (rsv != 0) {
                        this.frame_state.reset();

                        return error.ReservedBitsSet;
                    }

                    if (!this.frame_state.opcode.isValid()) {
                        this.frame_state.reset();

                        return error.InvalidOpcode;
                    }

                    if (!masked) {
                        this.frame_state.reset();

                        return error.UnmaskedClientFrame;
                    }

                    if (this.frame_state.opcode.isControl()) {
                        if (!this.frame_state.fin) {
                            this.frame_state.reset();

                            return error.FragmentedControlFrame;
                        }
                        if (len7 > 125) {
                            this.frame_state.reset();

                            return error.InvalidControlFrameLength;
                        }
                    }

                    this.consumeReadBuffer(2);

                    if (len7 < 126) {
                        this.frame_state.payload_len = len7;
                        this.frame_state.phase = .mask;
                    } else if (len7 == 126) {
                        this.frame_state.phase = .extended_len_16;
                    } else {
                        this.frame_state.phase = .extended_len_64;
                    }
                },

                .extended_len_16 => {
                    try this.ensureReadBuffer(allocator, 2);

                    this.frame_state.payload_len = std.mem.readInt(u16, this.read_buffer.items[0..2], .big);
                    this.consumeReadBuffer(2);
                    this.frame_state.phase = .mask;
                },

                .extended_len_64 => {
                    try this.ensureReadBuffer(allocator, 8);

                    this.frame_state.payload_len = std.mem.readInt(u64, this.read_buffer.items[0..8], .big);
                    this.consumeReadBuffer(8);

                    if (this.frame_state.payload_len >> 63 != 0) {
                        this.frame_state.reset();

                        return error.InvalidPayloadLength;
                    }

                    this.frame_state.phase = .mask;
                },

                .mask => {
                    if (this.frame_state.payload_len > this.config.max_frame_size) {
                        this.frame_state.reset();

                        return error.MessageTooLarge;
                    }

                    if (!this.frame_state.opcode.isControl() and this.frame_state.fin and this.fragment_opcode == null) {
                        if (this.frame_state.payload_len > this.config.max_message_size) {
                            this.frame_state.reset();

                            return error.MessageTooLarge;
                        }
                    }

                    try this.checkRateLimit(this.frame_state.payload_len);
                    try this.ensureReadBuffer(allocator, 4);

                    @memcpy(&this.frame_state.mask_key, this.read_buffer.items[0..4]);
                    this.consumeReadBuffer(4);

                    // Allocate payload buffer
                    this.frame_state.payload = try allocator.allocSentinel(u8, @intCast(this.frame_state.payload_len), 0);
                    this.frame_state.payload_read = 0;
                    this.frame_state.phase = .payload;
                },

                .payload => {
                    const payload = this.frame_state.payload.?;
                    const remaining = payload.len - this.frame_state.payload_read;

                    if (remaining > 0) {
                        // Try to read from buffer first
                        const from_buffer = @min(remaining, this.read_buffer.items.len);
                        if (from_buffer > 0) {
                            @memcpy(
                                payload[this.frame_state.payload_read..][0..from_buffer],
                                this.read_buffer.items[0..from_buffer],
                            );
                            this.consumeReadBuffer(from_buffer);
                            this.frame_state.payload_read += from_buffer;
                        }

                        // If still need more, try to read from socket
                        const still_remaining = payload.len - this.frame_state.payload_read;
                        if (still_remaining > 0) {
                            const n = this.stream.read(payload[this.frame_state.payload_read..]) catch |err| {
                                if (err == error.WouldBlock) {
                                    return error.WouldBlock;
                                }

                                allocator.free(payload);
                                this.frame_state.payload = null;
                                this.frame_state.reset();

                                return err;
                            };

                            if (n == 0) {
                                allocator.free(payload);
                                this.frame_state.payload = null;
                                this.frame_state.reset();

                                return error.ConnectionClosed;
                            }

                            this.frame_state.payload_read += n;
                        }
                    }

                    // Check if we have all payload data
                    if (this.frame_state.payload_read < payload.len) {
                        continue;
                    }

                    // Unmask payload
                    for (payload, 0..) |*byte, i| {
                        byte.* ^= this.frame_state.mask_key[i % 4];
                    }

                    // Update rate limit counters
                    this.messages_in_window += 1;
                    this.bytes_in_window += payload.len;

                    const frame = Frame{
                        .fin = this.frame_state.fin,
                        .opcode = this.frame_state.opcode,
                        .payload = payload,
                    };

                    this.frame_state.payload = null;
                    this.frame_state.reset();

                    return frame;
                },
            }
        }
    }

    inline fn checkRateLimit(this: *Connection, additional_bytes: u64) FrameError!void {
        const now = this.time_provider.milliTimestamp();

        if (now - this.rate_window_start >= 1000) {
            this.rate_window_start = now;
            this.messages_in_window = 0;
            this.bytes_in_window = 0;
        }

        if (this.messages_in_window >= this.config.rate_limit_messages_per_sec) {
            return error.RateLimitExceeded;
        }

        if (this.bytes_in_window + additional_bytes > this.config.rate_limit_bytes_per_sec) {
            return error.RateLimitExceeded;
        }
    }

    inline fn checkTimeouts(this: *Connection) FrameError!void {
        const now = this.time_provider.milliTimestamp();

        if (now - this.last_activity_time > this.config.idle_timeout_ms) {
            return error.IdleTimeout;
        }

        if (this.awaiting_pong) {
            if (now - this.last_ping_time > this.config.pong_timeout_ms) {
                return error.PongTimeout;
            }
        }
    }

    pub inline fn tick(this: *Connection, allocator: std.mem.Allocator) !void {
        if (this.state != .open) return;

        // Flush pending writes
        if (this.hasPendingWrites()) {
            _ = try this.flushWrites();
        }

        const now = this.time_provider.milliTimestamp();

        if (!this.awaiting_pong and now - this.last_ping_time >= this.config.ping_interval_ms) {
            try this.sendPing(allocator, "");
            this.last_ping_time = now;
            this.awaiting_pong = true;
        }
    }

    pub inline fn sendText(this: *Connection, allocator: std.mem.Allocator, data: []const u8) SendError!void {
        if (!this.state.canWrite()) {
            return error.InvalidState;
        }

        try this.queueFrame(allocator, .text, data);
    }

    pub inline fn sendBinary(this: *Connection, allocator: std.mem.Allocator, data: []const u8) SendError!void {
        if (!this.state.canWrite()) {
            return error.InvalidState;
        }

        try this.queueFrame(allocator, .binary, data);
    }

    pub inline fn sendPing(this: *Connection, allocator: std.mem.Allocator, data: []const u8) SendError!void {
        if (data.len > 125) {
            return error.PayloadTooLarge;
        }

        if (!this.state.canWrite()) {
            return error.InvalidState;
        }

        try this.queueFrame(allocator, .ping, data);
    }

    pub inline fn sendPong(this: *Connection, allocator: std.mem.Allocator, data: []const u8) SendError!void {
        if (data.len > 125) {
            return error.PayloadTooLarge;
        }

        if (this.state == .closed) {
            return error.InvalidState;
        }

        try this.queueFrame(allocator, .pong, data);
    }

    pub inline fn sendClose(this: *Connection, allocator: std.mem.Allocator, code: CloseCode) SendError!void {
        return this.sendCloseFrame(allocator, @intFromEnum(code), "");
    }

    pub inline fn sendCloseWithReason(this: *Connection, allocator: std.mem.Allocator, code: CloseCode, reason: []const u8) SendError!void {
        if (reason.len > 123) {
            return error.PayloadTooLarge;
        }

        return this.sendCloseFrame(allocator, @intFromEnum(code), reason);
    }

    fn closeWithError(this: *Connection, allocator: std.mem.Allocator, code: CloseCode, reason: []const u8) SendError!void {
        if (this.state == .closed or this.close_code_sent != null) {
            return;
        }

        try this.sendCloseFrame(allocator, @intFromEnum(code), reason);
    }

    fn sendCloseFrame(this: *Connection, allocator: std.mem.Allocator, code: u16, reason: []const u8) SendError!void {
        if (this.state == .closed) {
            return error.InvalidState;
        }

        if (this.close_code_sent != null) {
            return error.InvalidState;
        }

        this.close_code_sent = @enumFromInt(code);

        var payload: [125]u8 = undefined;
        std.mem.writeInt(u16, payload[0..2], code, .big);

        const reason_len: usize = @min(reason.len, 123);
        @memcpy(payload[2 .. 2 + reason_len], reason[0..reason_len]);

        this.queueFrame(allocator, .close, payload[0 .. 2 + reason_len]) catch |err| {
            this.state = .closing;
            return err;
        };

        this.state = .closing;
    }

    fn queueFrame(this: *Connection, allocator: std.mem.Allocator, opcode: Opcode, payload: []const u8) !void {
        const frame_size = if (payload.len < 126)
            2 + payload.len
        else if (payload.len <= 65535)
            4 + payload.len
        else
            10 + payload.len;

        if (this.write_buffer.items.len + frame_size > this.config.max_write_buffer_size) {
            return error.WriteBufferFull;
        }

        var header: [10]u8 = undefined;
        var header_len: usize = 2;

        header[0] = 0x80 | @as(u8, @intFromEnum(opcode));

        if (payload.len < 126) {
            header[1] = @intCast(payload.len);
        } else if (payload.len <= 65535) {
            header[1] = 126;
            std.mem.writeInt(u16, header[2..4], @intCast(payload.len), .big);
            header_len = 4;
        } else {
            header[1] = 127;
            std.mem.writeInt(u64, header[2..10], payload.len, .big);
            header_len = 10;
        }

        try this.write_buffer.appendSlice(allocator, header[0..header_len]);

        if (payload.len > 0) {
            try this.write_buffer.appendSlice(allocator, payload);
        }
    }

    pub inline fn getState(this: *const Connection) State {
        return this.state;
    }

    pub inline fn getCloseSentCode(this: *const Connection) ?CloseCode {
        return this.close_code_sent;
    }
};

pub const Server = struct {
    config: Connection.Config,
    listener: Listener,
    time_provider: TimeProvider,
    tracker: ConnectionTracker,

    pub const AcceptError = error{
        WouldBlock,
        TooManyConnections,
        TooManyConnectionsFromIp,
        Unexpected,
    };

    pub inline fn init(
        listener: Listener,
        config: Connection.Config,
        time_provider: TimeProvider,
        tracker: ConnectionTracker,
    ) Server {
        return .{
            .config = config,
            .listener = listener,
            .time_provider = time_provider,
            .tracker = tracker,
        };
    }

    pub inline fn deinit(this: *Server, allocator: std.mem.Allocator) void {
        this.tracker.deinit(allocator);
    }

    pub inline fn acceptConnection(this: *Server, allocator: std.mem.Allocator) AcceptError!Connection {
        const stream = this.listener.accept(allocator) catch |err| {
            return switch (err) {
                error.WouldBlock => error.WouldBlock,
                else => error.Unexpected,
            };
        };

        errdefer stream.deinit(allocator);

        const remote_ip = if (stream.getRemoteAddress()) |addr|
            addr.getIp()
        else
            [4]u8{ 0, 0, 0, 0 };

        this.tracker.tryAcquire(allocator, remote_ip) catch |err| {
            return switch (err) {
                error.TooManyConnections => error.TooManyConnections,
                error.TooManyConnectionsFromIp => error.TooManyConnectionsFromIp,
                error.OutOfMemory => error.Unexpected,
            };
        };

        return Connection.initTracked(stream, this.config, this.time_provider, &this.tracker);
    }

    pub inline fn getConnectionCount(this: *const Server) u32 {
        return this.tracker.getConnectionCount();
    }
};

pub const MockTimeProvider = struct {
    current_time: i64 = 0,

    pub inline fn advance(this: *MockTimeProvider, ms: i64) void {
        this.current_time += ms;
    }

    pub inline fn setTime(this: *MockTimeProvider, ms: i64) void {
        this.current_time = ms;
    }

    fn getTime(ctx: *anyopaque) i64 {
        const this: *MockTimeProvider = @ptrCast(@alignCast(ctx));

        return this.current_time;
    }

    pub inline fn interface(this: *MockTimeProvider) TimeProvider {
        return .{
            .ptr = this,
            .vtable = &.{ .milliTimestamp = getTime },
        };
    }
};

pub const MockStream = struct {
    allocator: std.mem.Allocator,
    input: std.ArrayList(u8) = .empty,
    read_pos: usize = 0,
    output: std.ArrayList(u8) = .empty,
    closed: bool = false,
    read_returns_would_block: bool = false,
    simulate_timeout: bool = false,
    remote_address: ?os.Address = null,

    pub inline fn init(allocator: std.mem.Allocator) MockStream {
        return .{ .allocator = allocator };
    }

    pub inline fn initWithData(allocator: std.mem.Allocator, data: []const u8) !MockStream {
        var mock = MockStream.init(allocator);
        try mock.addInput(data);

        return mock;
    }

    pub inline fn initWithAddress(allocator: std.mem.Allocator, ip: [4]u8, port: u16) MockStream {
        return .{
            .allocator = allocator,
            .remote_address = os.Address.init(ip, port),
        };
    }

    pub inline fn deinit(this: *MockStream) void {
        this.input.deinit(this.allocator);
        this.output.deinit(this.allocator);
    }

    pub inline fn addInput(this: *MockStream, data: []const u8) !void {
        try this.input.appendSlice(this.allocator, data);
    }

    pub inline fn getWritten(this: *const MockStream) []const u8 {
        return this.output.items;
    }

    pub inline fn clearWritten(this: *MockStream) void {
        this.output.clearRetainingCapacity();
    }

    pub fn interface(this: *MockStream) Stream {
        return .{
            .ptr = this,
            .vtable = &.{
                .read = streamRead,
                .write = streamWrite,
                .get_remote_address = streamGetRemoteAddress,
                .deinit = streamDeinit,
            },
        };
    }

    fn streamRead(ctx: *anyopaque, buf: []u8) Stream.ReadError!usize {
        const this: *MockStream = @ptrCast(@alignCast(ctx));

        if (this.closed) {
            return error.ConnectionReset;
        }

        if (this.read_returns_would_block) {
            return error.WouldBlock;
        }

        if (this.simulate_timeout) {
            return error.Timeout;
        }

        if (this.read_pos >= this.input.items.len) {
            return 0;
        }

        const available = this.input.items.len - this.read_pos;
        const to_read = @min(available, buf.len);

        @memcpy(buf[0..to_read], this.input.items[this.read_pos .. this.read_pos + to_read]);
        this.read_pos += to_read;

        return to_read;
    }

    fn streamWrite(ctx: *anyopaque, data: []const u8) Stream.WriteError!usize {
        const this: *MockStream = @ptrCast(@alignCast(ctx));

        if (this.closed) {
            return error.BrokenPipe;
        }

        try this.output.appendSlice(this.allocator, data);

        return data.len;
    }

    fn streamGetRemoteAddress(ctx: *anyopaque) ?os.Address {
        const this: *MockStream = @ptrCast(@alignCast(ctx));

        return this.remote_address;
    }

    fn streamDeinit(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        _ = allocator;

        const this: *MockStream = @ptrCast(@alignCast(ctx));

        this.closed = true;
    }
};

pub const MockListener = struct {
    pending: std.ArrayList(Stream) = .empty,
    closed: bool = false,

    pub inline fn init() MockListener {
        return .{};
    }

    pub inline fn deinit(this: *MockListener, allocator: std.mem.Allocator) void {
        this.pending.deinit(allocator);
    }

    pub inline fn enqueueConnection(this: *MockListener, allocator: std.mem.Allocator, stream: Stream) !void {
        try this.pending.append(allocator, stream);
    }

    pub fn interface(this: *MockListener) Listener {
        return .{
            .ptr = @ptrCast(this),
            .vtable = &.{
                .accept = listenerAccept,
            },
        };
    }

    fn listenerAccept(ctx: *anyopaque, allocator: std.mem.Allocator) Listener.AcceptError!Stream {
        _ = allocator;

        const this: *MockListener = @ptrCast(@alignCast(ctx));

        if (this.pending.items.len == 0) {
            return error.WouldBlock;
        }

        return this.pending.orderedRemove(0);
    }
};

inline fn buildHandshakeRequest(comptime key: []const u8) []const u8 {
    return "GET /chat HTTP/1.1\r\n" ++
        "Host: localhost:8080\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: " ++ key ++ "\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "\r\n";
}

fn buildMaskedFrame(
    allocator: std.mem.Allocator,
    fin: bool,
    opcode: Opcode,
    payload: []const u8,
    mask_key: [4]u8,
) ![]u8 {
    var frame: std.ArrayList(u8) = .empty;
    errdefer frame.deinit(allocator);

    const byte0: u8 = (@as(u8, if (fin) 0x80 else 0x00)) | @intFromEnum(opcode);
    try frame.append(allocator, byte0);

    if (payload.len < 126) {
        try frame.append(allocator, 0x80 | @as(u8, @intCast(payload.len)));
    } else if (payload.len <= 65535) {
        try frame.append(allocator, 0x80 | 126);
        const len_bytes = std.mem.toBytes(std.mem.nativeTo(u16, @intCast(payload.len), .big));
        try frame.appendSlice(allocator, &len_bytes);
    } else {
        try frame.append(allocator, 0x80 | 127);
        const len_bytes = std.mem.toBytes(std.mem.nativeTo(u64, @intCast(payload.len), .big));
        try frame.appendSlice(allocator, &len_bytes);
    }

    try frame.appendSlice(allocator, &mask_key);

    for (payload, 0..) |byte, i| {
        try frame.append(allocator, byte ^ mask_key[i % 4]);
    }

    return frame.toOwnedSlice(allocator);
}

fn buildCloseFrame(allocator: std.mem.Allocator, code: u16, reason: []const u8) ![]u8 {
    var payload_buf: [125]u8 = undefined;
    std.mem.writeInt(u16, payload_buf[0..2], code, .big);
    @memcpy(payload_buf[2 .. 2 + reason.len], reason);

    return buildMaskedFrame(
        allocator,
        true,
        .close,
        payload_buf[0 .. 2 + reason.len],
        [4]u8{ 0x12, 0x34, 0x56, 0x78 },
    );
}

fn findFrameAfterHandshake(data: []const u8) ?[]const u8 {
    const end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse {
        return null;
    };

    return data[end + 4 ..];
}

fn parseCloseCode(frame_data: []const u8) ?u16 {
    if (frame_data.len < 4) {
        return null;
    }

    if (frame_data[0] != 0x88) {
        // Not a close frame.
        return null;
    }

    const payload_len = frame_data[1] & 0x7F;

    if (payload_len < 2) {
        return null;
    }

    return std.mem.readInt(u16, frame_data[2..4], .big);
}

test "handshake - valid request" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock.deinit();

    var conn = Connection.init(mock.interface(), .{}, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);

    try std.testing.expectEqual(.open, conn.state);
    try std.testing.expect(std.mem.indexOf(u8, mock.getWritten(), "101 Switching Protocols") != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.getWritten(), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") != null);
}

test "handshake - missing upgrade header" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    const request = "GET /chat HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n\r\n";

    var mock = try MockStream.initWithData(allocator, request);
    defer mock.deinit();

    var conn = Connection.init(mock.interface(), .{}, time.interface());
    defer conn.deinit(allocator);

    try std.testing.expectError(error.MissingUpgradeHeader, conn.performHandshake(allocator));
    try std.testing.expectEqual(.closed, conn.state);
}

test "handshake - timeout" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = MockStream.init(allocator);
    defer mock.deinit();

    var conn = Connection.init(mock.interface(), .{ .handshake_timeout_ms = 5000 }, time.interface());
    defer conn.deinit(allocator);

    // Add incomplete request
    try mock.addInput("GET /chat HTTP/1.1\r\n");
    time.advance(6000);

    try std.testing.expectError(error.HandshakeTimeout, conn.performHandshake(allocator));
    try std.testing.expectEqual(.closed, conn.state);
}

test "frame - read text message" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock.deinit();

    const frame = try buildMaskedFrame(allocator, true, .text, "Hello!", [4]u8{ 0x37, 0xfa, 0x21, 0x3d });
    defer allocator.free(frame);
    try mock.addInput(frame);

    var conn = Connection.init(mock.interface(), .{}, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);
    const msg = try conn.readMessage(allocator);
    defer msg.deinit(allocator);

    try std.testing.expectEqual(.text, msg.opcode);
    try std.testing.expectEqualStrings("Hello!", msg.payload);
}

test "frame - read binary message" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock.deinit();

    const payload = &[_]u8{ 0x00, 0x01, 0xFF, 0xFE };
    const frame = try buildMaskedFrame(allocator, true, .binary, payload, [4]u8{ 0x12, 0x34, 0x56, 0x78 });
    defer allocator.free(frame);
    try mock.addInput(frame);

    var conn = Connection.init(mock.interface(), .{}, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);
    const msg = try conn.readMessage(allocator);
    defer msg.deinit(allocator);

    try std.testing.expectEqual(.binary, msg.opcode);
    try std.testing.expectEqualSlices(u8, payload, msg.payload);
}

test "frame - ping/pong automatic response" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock.deinit();

    const ping = try buildMaskedFrame(allocator, true, .ping, "ping", [4]u8{ 0xAB, 0xCD, 0xEF, 0x01 });
    defer allocator.free(ping);
    const text = try buildMaskedFrame(allocator, true, .text, "test", [4]u8{ 0xAB, 0xCD, 0xEF, 0x01 });
    defer allocator.free(text);

    try mock.addInput(ping);
    try mock.addInput(text);

    var conn = Connection.init(mock.interface(), .{}, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);
    const msg = try conn.readMessage(allocator);
    defer msg.deinit(allocator);

    try std.testing.expectEqualStrings("test", msg.payload);

    _ = try conn.flushWrites();

    // Verify pong was sent
    const frames = findFrameAfterHandshake(mock.getWritten()).?;
    try std.testing.expectEqual(@as(u8, 0x8A), frames[0]); // Pong opcode
    try std.testing.expectEqual(@as(u8, 4), frames[1]); // Length
    try std.testing.expectEqualStrings("ping", frames[2..6]); // Echo payload
}

test "frame - fragmented message" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock.deinit();

    const mask = [4]u8{ 0x11, 0x22, 0x33, 0x44 };
    const frag1 = try buildMaskedFrame(allocator, false, .text, "Hel", mask);
    defer allocator.free(frag1);
    const frag2 = try buildMaskedFrame(allocator, false, .continuation, "lo, ", mask);
    defer allocator.free(frag2);
    const frag3 = try buildMaskedFrame(allocator, true, .continuation, "World!", mask);
    defer allocator.free(frag3);

    try mock.addInput(frag1);
    try mock.addInput(frag2);
    try mock.addInput(frag3);

    var conn = Connection.init(mock.interface(), .{}, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);
    const msg = try conn.readMessage(allocator);
    defer msg.deinit(allocator);

    try std.testing.expectEqualStrings("Hello, World!", msg.payload);
}

test "frame - close handshake" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock.deinit();

    const close = try buildCloseFrame(allocator, 1000, "goodbye");
    defer allocator.free(close);
    try mock.addInput(close);

    var conn = Connection.init(mock.interface(), .{}, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);
    try std.testing.expectError(error.ConnectionClosed, conn.readMessage(allocator));
    try std.testing.expectEqual(.closed, conn.state);

    _ = try conn.flushWrites();

    // Verify close was echoed
    const frames = findFrameAfterHandshake(mock.getWritten()).?;
    try std.testing.expectEqual(@as(u8, 0x88), frames[0]);
    const echoed_code = parseCloseCode(frames);
    try std.testing.expectEqual(@as(u16, 1000), echoed_code.?);
}

test "frame - unmasked client frame → close 1002" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock.deinit();

    // Unmasked frame (invalid for client)
    try mock.addInput(&[_]u8{ 0x81, 0x05 } ++ "Hello");

    var conn = Connection.init(mock.interface(), .{}, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);
    try std.testing.expectError(error.UnmaskedClientFrame, conn.readMessage(allocator));

    _ = try conn.flushWrites();

    const frames = findFrameAfterHandshake(mock.getWritten()).?;
    try std.testing.expectEqual(@as(u16, 1002), parseCloseCode(frames).?);
}

test "frame - invalid UTF-8 in text → close 1007" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock.deinit();

    // Invalid UTF-8 sequence
    const invalid_utf8 = &[_]u8{ 0xFF, 0xFE, 0x00, 0x01 };
    const frame = try buildMaskedFrame(allocator, true, .text, invalid_utf8, [4]u8{ 0x12, 0x34, 0x56, 0x78 });
    defer allocator.free(frame);
    try mock.addInput(frame);

    var conn = Connection.init(mock.interface(), .{}, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);
    try std.testing.expectError(error.InvalidUtf8, conn.readMessage(allocator));

    _ = try conn.flushWrites();

    const frames = findFrameAfterHandshake(mock.getWritten()).?;
    try std.testing.expectEqual(@as(u16, 1007), parseCloseCode(frames).?);
}

test "frame - payload too large → close 1009" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock.deinit();

    // Frame header indicating 1MB + 1 byte payload (over default limit)
    // We only add the header, not actual payload
    const max_size = 100;
    var header: [14]u8 = undefined;
    header[0] = 0x82; // FIN + binary
    header[1] = 0xFF; // Masked + 127 (extended length)
    std.mem.writeInt(u64, header[2..10], max_size + 1, .big);
    header[10] = 0x12; // Mask key
    header[11] = 0x34;
    header[12] = 0x56;
    header[13] = 0x78;

    try mock.addInput(&header);

    var conn = Connection.init(mock.interface(), .{ .max_frame_size = max_size }, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);
    try std.testing.expectError(error.MessageTooLarge, conn.readMessage(allocator));

    _ = try conn.flushWrites();

    const frames = findFrameAfterHandshake(mock.getWritten()).?;
    try std.testing.expectEqual(@as(u16, 1009), parseCloseCode(frames).?);
}

test "frame - fragmented message exceeds max size → close 1009" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock.deinit();

    const mask = [4]u8{ 0x11, 0x22, 0x33, 0x44 };

    // Two fragments that together exceed limit
    const frag1 = try buildMaskedFrame(allocator, false, .text, "Hello", mask);
    defer allocator.free(frag1);
    const frag2 = try buildMaskedFrame(allocator, true, .continuation, " World!", mask);
    defer allocator.free(frag2);

    try mock.addInput(frag1);
    try mock.addInput(frag2);

    var conn = Connection.init(mock.interface(), .{ .max_message_size = 10 }, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);
    try std.testing.expectError(error.MessageTooLarge, conn.readMessage(allocator));

    _ = try conn.flushWrites();

    const frames = findFrameAfterHandshake(mock.getWritten()).?;
    try std.testing.expectEqual(@as(u16, 1009), parseCloseCode(frames).?);
}

test "rate limit - messages per second exceeded" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock.deinit();

    // Add many small frames
    const mask = [4]u8{ 0x11, 0x22, 0x33, 0x44 };
    for (0..6) |_| {
        const frame = try buildMaskedFrame(allocator, true, .text, "x", mask);
        defer allocator.free(frame);
        try mock.addInput(frame);
    }

    var conn = Connection.init(mock.interface(), .{ .rate_limit_messages_per_sec = 5 }, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);

    // Read 5 messages successfully
    for (0..5) |_| {
        const msg = try conn.readMessage(allocator);
        msg.deinit(allocator);
    }

    // 6th should fail
    try std.testing.expectError(error.RateLimitExceeded, conn.readMessage(allocator));

    _ = try conn.flushWrites();

    const frames = findFrameAfterHandshake(mock.getWritten()).?;
    // Should have sent close 1008 (policy violation)
    try std.testing.expectEqual(@as(u16, 1008), parseCloseCode(frames).?);
}

test "rate limit - resets after window" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock.deinit();

    const mask = [4]u8{ 0x11, 0x22, 0x33, 0x44 };
    for (0..4) |_| {
        const frame = try buildMaskedFrame(allocator, true, .text, "x", mask);
        defer allocator.free(frame);
        try mock.addInput(frame);
    }

    var conn = Connection.init(mock.interface(), .{ .rate_limit_messages_per_sec = 2 }, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);

    // Read 2 messages
    for (0..2) |_| {
        const msg = try conn.readMessage(allocator);
        msg.deinit(allocator);
    }

    // Advance time past window
    time.advance(1001);

    // Should be able to read more
    const msg = try conn.readMessage(allocator);
    msg.deinit(allocator);
}

test "timeout - idle connection" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock.deinit();

    // Add a frame but don't let it be read yet
    const frame = try buildMaskedFrame(allocator, true, .text, "test", [4]u8{ 0x11, 0x22, 0x33, 0x44 });
    defer allocator.free(frame);
    try mock.addInput(frame);

    var conn = Connection.init(mock.interface(), .{ .idle_timeout_ms = 5000 }, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);

    // Advance time past idle timeout
    time.advance(6000);

    try std.testing.expectError(error.IdleTimeout, conn.readMessage(allocator));
}

test "state - cannot read before handshake" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = MockStream.init(allocator);
    defer mock.deinit();

    var conn = Connection.init(mock.interface(), .{}, time.interface());
    defer conn.deinit(allocator);

    try std.testing.expectError(error.InvalidState, conn.readMessage(allocator));
}

test "state - cannot send before handshake" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = MockStream.init(allocator);
    defer mock.deinit();

    var conn = Connection.init(mock.interface(), .{}, time.interface());
    defer conn.deinit(allocator);

    try std.testing.expectError(error.InvalidState, conn.sendText(allocator, "hello"));
}

test "state - cannot handshake twice" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock.deinit();

    var conn = Connection.init(mock.interface(), .{}, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);
    try std.testing.expectError(error.InvalidState, conn.performHandshake(allocator));
}

test "state - cannot send after close sent" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock.deinit();

    var conn = Connection.init(mock.interface(), .{}, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);
    try conn.sendClose(allocator, .normal_closure);

    try std.testing.expectEqual(.closing, conn.state);
    try std.testing.expectError(error.InvalidState, conn.sendText(allocator, "hello"));
}

test "server - accept connection" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var listener = MockListener.init();
    defer listener.deinit(allocator);

    var mock = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock.deinit();

    try listener.enqueueConnection(allocator, mock.interface());

    var server = Server.init(listener.interface(), .{}, time.interface(), .init(.{}));
    defer server.deinit(allocator);

    var conn = try server.acceptConnection(allocator);
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);
    try std.testing.expectEqual(.open, conn.state);
}

test "multiple connections - error isolation" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};

    // Connection 1: Will fail (bad data)
    var mock1 = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock1.deinit();
    try mock1.addInput(&[_]u8{ 0x81, 0x05 } ++ "Hello"); // Unmasked frame

    // Connection 2: Valid
    var mock2 = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock2.deinit();
    const frame = try buildMaskedFrame(allocator, true, .text, "Valid", [4]u8{ 0x11, 0x22, 0x33, 0x44 });
    defer allocator.free(frame);
    try mock2.addInput(frame);

    var conn1 = Connection.init(mock1.interface(), .{}, time.interface());
    defer conn1.deinit(allocator);

    var conn2 = Connection.init(mock2.interface(), .{}, time.interface());
    defer conn2.deinit(allocator);

    try conn1.performHandshake(allocator);
    try conn2.performHandshake(allocator);

    // conn1 fails
    try std.testing.expectError(error.UnmaskedClientFrame, conn1.readMessage(allocator));

    // conn2 still works
    const msg = try conn2.readMessage(allocator);
    defer msg.deinit(allocator);
    try std.testing.expectEqualStrings("Valid", msg.payload);
}

test "many connections - stress test" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var listener = MockListener.init();
    defer listener.deinit(allocator);

    const NUM_CONNECTIONS = 100;

    var mocks: [NUM_CONNECTIONS]MockStream = undefined;
    var connections: [NUM_CONNECTIONS]Connection = undefined;
    var frames: [NUM_CONNECTIONS][]u8 = undefined;

    // Initialize all
    for (0..NUM_CONNECTIONS) |i| {
        mocks[i] = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
        frames[i] = try buildMaskedFrame(allocator, true, .text, "test", [4]u8{ 0x11, 0x22, 0x33, 0x44 });
        try mocks[i].addInput(frames[i]);
        try listener.enqueueConnection(allocator, mocks[i].interface());
    }
    defer {
        for (0..NUM_CONNECTIONS) |i| {
            allocator.free(frames[i]);
            mocks[i].deinit();
        }
    }

    var server = Server.init(listener.interface(), .{}, time.interface(), .init(.{
        .max_connections_per_ip = NUM_CONNECTIONS,
    }));
    defer server.deinit(allocator);

    // Accept and process all connections
    for (0..NUM_CONNECTIONS) |i| {
        connections[i] = try server.acceptConnection(allocator);
    }

    defer {
        for (0..NUM_CONNECTIONS) |i| {
            connections[i].deinit(allocator);
        }
    }

    for (0..NUM_CONNECTIONS) |i| {
        try connections[i].performHandshake(allocator);
        const msg = try connections[i].readMessage(allocator);
        msg.deinit(allocator);
    }
}

test "send text message" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock.deinit();

    var conn = Connection.init(mock.interface(), .{}, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);
    try conn.sendText(allocator, "Hello from server!");

    _ = try conn.flushWrites();

    const frames = findFrameAfterHandshake(mock.getWritten()).?;
    try std.testing.expectEqual(@as(u8, 0x81), frames[0]); // FIN + text
    try std.testing.expectEqual(@as(u8, 18), frames[1]); // length
    try std.testing.expectEqualStrings("Hello from server!", frames[2..20]);
}

test "send binary message" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock.deinit();

    var conn = Connection.init(mock.interface(), .{}, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);
    try conn.sendBinary(allocator, &[_]u8{ 0x00, 0x01, 0xFF });

    _ = try conn.flushWrites();

    const frames = findFrameAfterHandshake(mock.getWritten()).?;
    try std.testing.expectEqual(@as(u8, 0x82), frames[0]); // FIN + binary
}

test "send ping" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock.deinit();

    var conn = Connection.init(mock.interface(), .{}, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);
    try conn.sendPing(allocator, "test");

    _ = try conn.flushWrites();

    const frames = findFrameAfterHandshake(mock.getWritten()).?;
    try std.testing.expectEqual(@as(u8, 0x89), frames[0]); // FIN + ping
}

test "send - payload too large for control frame" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock.deinit();

    var conn = Connection.init(mock.interface(), .{}, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);

    var large_payload: [126]u8 = undefined;
    try std.testing.expectError(error.PayloadTooLarge, conn.sendPing(allocator, &large_payload));
}

test "handshake - size limit exact boundary" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = MockStream.init(allocator);
    defer mock.deinit();

    const base_request = "GET /chat HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n";

    var conn = Connection.init(mock.interface(), .{ .max_handshake_size = base_request.len + 10 }, time.interface());
    defer conn.deinit(allocator);

    try mock.addInput(base_request);
    try mock.addInput("X-Padding: 12345678901234567890\r\n\r\n");

    try std.testing.expectError(error.HandshakeTooLarge, conn.performHandshake(allocator));
}

test "frame - close code 1005 is invalid in frame" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock.deinit();

    const close = try buildCloseFrame(allocator, 1005, "");
    defer allocator.free(close);
    try mock.addInput(close);

    var conn = Connection.init(mock.interface(), .{}, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);
    try std.testing.expectError(error.InvalidCloseCode, conn.readMessage(allocator));

    _ = try conn.flushWrites();

    const frames = findFrameAfterHandshake(mock.getWritten()).?;
    try std.testing.expectEqual(@as(u16, 1002), parseCloseCode(frames).?);
}

test "frame - close code 1006 is invalid in frame" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock.deinit();

    const close = try buildCloseFrame(allocator, 1006, "");
    defer allocator.free(close);
    try mock.addInput(close);

    var conn = Connection.init(mock.interface(), .{}, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);
    try std.testing.expectError(error.InvalidCloseCode, conn.readMessage(allocator));
}

test "frame - close code 5000+ is invalid (reserved)" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock.deinit();

    const close = try buildCloseFrame(allocator, 5000, "");
    defer allocator.free(close);
    try mock.addInput(close);

    var conn = Connection.init(mock.interface(), .{}, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);
    try std.testing.expectError(error.InvalidCloseCode, conn.readMessage(allocator));
}

test "frame - close code 4000 (private use) is valid" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock.deinit();

    const close = try buildCloseFrame(allocator, 4000, "private");
    defer allocator.free(close);
    try mock.addInput(close);

    var conn = Connection.init(mock.interface(), .{}, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);
    try std.testing.expectError(error.ConnectionClosed, conn.readMessage(allocator));

    _ = try conn.flushWrites();

    const frames = findFrameAfterHandshake(mock.getWritten()).?;
    try std.testing.expectEqual(@as(u16, 4000), parseCloseCode(frames).?);
}

test "frame - close with invalid UTF-8 reason" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock.deinit();

    var payload_buf: [125]u8 = undefined;
    std.mem.writeInt(u16, payload_buf[0..2], 1000, .big);
    payload_buf[2] = 0xFF;
    payload_buf[3] = 0xFE;

    const close = try buildMaskedFrame(allocator, true, .close, payload_buf[0..4], [4]u8{ 0x12, 0x34, 0x56, 0x78 });
    defer allocator.free(close);
    try mock.addInput(close);

    var conn = Connection.init(mock.interface(), .{}, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);
    try std.testing.expectError(error.InvalidUtf8, conn.readMessage(allocator));

    _ = try conn.flushWrites();

    const frames = findFrameAfterHandshake(mock.getWritten()).?;
    try std.testing.expectEqual(@as(u16, 1007), parseCloseCode(frames).?);
}

test "frame - close with empty payload (no status)" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock.deinit();

    const close = try buildMaskedFrame(allocator, true, .close, "", [4]u8{ 0x12, 0x34, 0x56, 0x78 });
    defer allocator.free(close);
    try mock.addInput(close);

    var conn = Connection.init(mock.interface(), .{}, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);
    try std.testing.expectError(error.ConnectionClosed, conn.readMessage(allocator));
    try std.testing.expectEqual(.closed, conn.state);
}

test "state - cannot send close twice" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock.deinit();

    var conn = Connection.init(mock.interface(), .{}, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);
    try conn.sendClose(allocator, .normal_closure);

    try std.testing.expectError(error.InvalidState, conn.sendClose(allocator, .going_away));
    try std.testing.expectEqual(CloseCode.normal_closure, conn.getCloseSentCode().?);
}

test "frame - control frame interleaved with fragmented message" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock.deinit();

    const mask = [4]u8{ 0x11, 0x22, 0x33, 0x44 };

    const frag1 = try buildMaskedFrame(allocator, false, .text, "Hello", mask);
    defer allocator.free(frag1);
    const ping = try buildMaskedFrame(allocator, true, .ping, "mid", mask);
    defer allocator.free(ping);
    const frag2 = try buildMaskedFrame(allocator, true, .continuation, " World", mask);
    defer allocator.free(frag2);

    try mock.addInput(frag1);
    try mock.addInput(ping);
    try mock.addInput(frag2);

    var conn = Connection.init(mock.interface(), .{}, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);
    const msg = try conn.readMessage(allocator);
    defer msg.deinit(allocator);

    try std.testing.expectEqualStrings("Hello World", msg.payload);

    _ = try conn.flushWrites();

    const frames = findFrameAfterHandshake(mock.getWritten()).?;
    try std.testing.expectEqual(@as(u8, 0x8A), frames[0]);
}

test "frame - continuation without initial frame" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock.deinit();

    const frame = try buildMaskedFrame(allocator, true, .continuation, "data", [4]u8{ 0x12, 0x34, 0x56, 0x78 });
    defer allocator.free(frame);
    try mock.addInput(frame);

    var conn = Connection.init(mock.interface(), .{}, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);
    try std.testing.expectError(error.UnexpectedContinuation, conn.readMessage(allocator));
}

test "frame - new data frame during fragmentation" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock.deinit();

    const mask = [4]u8{ 0x11, 0x22, 0x33, 0x44 };

    const frag1 = try buildMaskedFrame(allocator, false, .text, "Hello", mask);
    defer allocator.free(frag1);
    const frag2 = try buildMaskedFrame(allocator, true, .text, "World", mask);
    defer allocator.free(frag2);

    try mock.addInput(frag1);
    try mock.addInput(frag2);

    var conn = Connection.init(mock.interface(), .{}, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);
    try std.testing.expectError(error.ExpectedContinuation, conn.readMessage(allocator));
}

test "rate limit - bytes per second exceeded" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock.deinit();

    const mask = [4]u8{ 0x11, 0x22, 0x33, 0x44 };

    const payload1 = try allocator.alloc(u8, 600);
    defer allocator.free(payload1);
    @memset(payload1, 'A');

    const payload2 = try allocator.alloc(u8, 600);
    defer allocator.free(payload2);
    @memset(payload2, 'B');

    const frame1 = try buildMaskedFrame(allocator, true, .binary, payload1, mask);
    defer allocator.free(frame1);
    const frame2 = try buildMaskedFrame(allocator, true, .binary, payload2, mask);
    defer allocator.free(frame2);

    try mock.addInput(frame1);
    try mock.addInput(frame2);

    var conn = Connection.init(mock.interface(), .{ .rate_limit_bytes_per_sec = 1000 }, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);

    const msg1 = try conn.readMessage(allocator);
    msg1.deinit(allocator);

    try std.testing.expectError(error.RateLimitExceeded, conn.readMessage(allocator));
}

test "timeout - pong timeout" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock.deinit();

    const frame = try buildMaskedFrame(allocator, true, .text, "test", [4]u8{ 0x11, 0x22, 0x33, 0x44 });
    defer allocator.free(frame);
    try mock.addInput(frame);

    var conn = Connection.init(mock.interface(), .{
        .ping_interval_ms = 1000,
        .pong_timeout_ms = 2000,
        .idle_timeout_ms = 300_000,
    }, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);

    time.advance(1500);
    try conn.tick(allocator);
    try std.testing.expect(conn.awaiting_pong);

    time.advance(2500);

    try std.testing.expectError(error.PongTimeout, conn.readMessage(allocator));
}

test "connection tracker - max connections limit" {
    const allocator = std.testing.allocator;

    var tracker = ConnectionTracker.init(.{ .max_connections = 2, .max_connections_per_ip = 10 });
    defer tracker.deinit(allocator);

    try tracker.tryAcquire(allocator, .{ 192, 168, 1, 1 });
    try tracker.tryAcquire(allocator, .{ 192, 168, 1, 2 });

    try std.testing.expectEqual(@as(u32, 2), tracker.getConnectionCount());
    try std.testing.expectError(error.TooManyConnections, tracker.tryAcquire(allocator, .{ 192, 168, 1, 3 }));
}

test "connection tracker - max connections per ip limit" {
    const allocator = std.testing.allocator;

    var tracker = ConnectionTracker.init(.{ .max_connections = 100, .max_connections_per_ip = 2 });
    defer tracker.deinit(allocator);

    const ip = [4]u8{ 192, 168, 1, 1 };
    try tracker.tryAcquire(allocator, ip);
    try tracker.tryAcquire(allocator, ip);

    try std.testing.expectEqual(@as(u8, 2), tracker.getConnectionCountFromIp(ip));
    try std.testing.expectError(error.TooManyConnectionsFromIp, tracker.tryAcquire(allocator, ip));

    // Different IP still works
    try tracker.tryAcquire(allocator, .{ 192, 168, 1, 2 });
}

test "connection tracker - release frees slot" {
    const allocator = std.testing.allocator;

    var tracker = ConnectionTracker.init(.{ .max_connections = 2, .max_connections_per_ip = 2 });
    defer tracker.deinit(allocator);

    const ip = [4]u8{ 192, 168, 1, 1 };
    try tracker.tryAcquire(allocator, ip);
    try tracker.tryAcquire(allocator, ip);

    try std.testing.expectEqual(@as(u32, 2), tracker.getConnectionCount());
    try std.testing.expectEqual(@as(u8, 2), tracker.getConnectionCountFromIp(ip));

    tracker.release(allocator, ip);

    try std.testing.expectEqual(@as(u32, 1), tracker.getConnectionCount());
    try std.testing.expectEqual(@as(u8, 1), tracker.getConnectionCountFromIp(ip));

    // Can acquire again after release
    try tracker.tryAcquire(allocator, ip);
}

test "connection tracker - release all from ip removes entry" {
    const allocator = std.testing.allocator;

    var tracker = ConnectionTracker.init(.{ .max_connections = 10, .max_connections_per_ip = 10 });
    defer tracker.deinit(allocator);

    const ip = [4]u8{ 10, 0, 0, 1 };
    try tracker.tryAcquire(allocator, ip);
    tracker.release(allocator, ip);

    try std.testing.expectEqual(@as(u8, 0), tracker.getConnectionCountFromIp(ip));
    try std.testing.expectEqual(@as(u32, 0), tracker.getConnectionCount());
}

test "server - rejects when too many connections" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var listener = MockListener.init();
    defer listener.deinit(allocator);

    var mock1 = MockStream.initWithAddress(allocator, .{ 10, 0, 0, 1 }, 1234);
    defer mock1.deinit();
    var mock2 = MockStream.initWithAddress(allocator, .{ 10, 0, 0, 2 }, 1234);
    defer mock2.deinit();
    var mock3 = MockStream.initWithAddress(allocator, .{ 10, 0, 0, 3 }, 1234);
    defer mock3.deinit();

    try listener.enqueueConnection(allocator, mock1.interface());
    try listener.enqueueConnection(allocator, mock2.interface());
    try listener.enqueueConnection(allocator, mock3.interface());

    var server = Server.init(
        listener.interface(),
        .{},
        time.interface(),
        ConnectionTracker.init(.{ .max_connections = 2, .max_connections_per_ip = 10 }),
    );
    defer server.deinit(allocator);

    var conn1 = try server.acceptConnection(allocator);
    defer conn1.deinit(allocator);
    var conn2 = try server.acceptConnection(allocator);
    defer conn2.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 2), server.getConnectionCount());
    try std.testing.expectError(error.TooManyConnections, server.acceptConnection(allocator));
}

test "server - rejects when too many connections from same ip" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var listener = MockListener.init();
    defer listener.deinit(allocator);

    const same_ip = [4]u8{ 192, 168, 1, 100 };

    var mock1 = MockStream.initWithAddress(allocator, same_ip, 1234);
    defer mock1.deinit();
    var mock2 = MockStream.initWithAddress(allocator, same_ip, 1235);
    defer mock2.deinit();
    var mock3 = MockStream.initWithAddress(allocator, same_ip, 1236);
    defer mock3.deinit();

    try listener.enqueueConnection(allocator, mock1.interface());
    try listener.enqueueConnection(allocator, mock2.interface());
    try listener.enqueueConnection(allocator, mock3.interface());

    var server = Server.init(
        listener.interface(),
        .{},
        time.interface(),
        ConnectionTracker.init(.{ .max_connections = 100, .max_connections_per_ip = 2 }),
    );
    defer server.deinit(allocator);

    var conn1 = try server.acceptConnection(allocator);
    defer conn1.deinit(allocator);
    var conn2 = try server.acceptConnection(allocator);
    defer conn2.deinit(allocator);

    try std.testing.expectError(error.TooManyConnectionsFromIp, server.acceptConnection(allocator));
}

test "server - connection deinit releases tracker slot" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var listener = MockListener.init();
    defer listener.deinit(allocator);

    var mock1 = MockStream.initWithAddress(allocator, .{ 10, 0, 0, 1 }, 1234);
    defer mock1.deinit();
    var mock2 = MockStream.initWithAddress(allocator, .{ 10, 0, 0, 2 }, 1234);
    defer mock2.deinit();

    try listener.enqueueConnection(allocator, mock1.interface());
    try listener.enqueueConnection(allocator, mock2.interface());

    var server = Server.init(
        listener.interface(),
        .{},
        time.interface(),
        ConnectionTracker.init(.{ .max_connections = 1, .max_connections_per_ip = 10 }),
    );
    defer server.deinit(allocator);

    {
        var conn1 = try server.acceptConnection(allocator);
        try std.testing.expectEqual(@as(u32, 1), server.getConnectionCount());
        conn1.deinit(allocator);
    }

    try std.testing.expectEqual(@as(u32, 0), server.getConnectionCount());

    // Can accept new connection after release
    var conn2 = try server.acceptConnection(allocator);
    defer conn2.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 1), server.getConnectionCount());
}

test "tick - sends ping after interval" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock.deinit();

    var conn = Connection.init(mock.interface(), .{ .ping_interval_ms = 1000 }, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);
    mock.clearWritten();

    try std.testing.expect(!conn.awaiting_pong);

    time.advance(1500);
    try conn.tick(allocator);
    _ = try conn.flushWrites();

    try std.testing.expect(conn.awaiting_pong);

    const written = mock.getWritten();
    try std.testing.expect(written.len >= 2);
    try std.testing.expectEqual(@as(u8, 0x89), written[0]); // FIN + Ping
}

test "tick - does not send ping if already awaiting pong" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock.deinit();

    var conn = Connection.init(mock.interface(), .{ .ping_interval_ms = 1000 }, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);
    mock.clearWritten();

    time.advance(1500);
    try conn.tick(allocator);
    _ = try conn.flushWrites();

    const first_write_len = mock.getWritten().len;
    mock.clearWritten();

    time.advance(1500);
    try conn.tick(allocator);
    _ = try conn.flushWrites();

    // Should not send another ping
    try std.testing.expectEqual(@as(usize, 0), mock.getWritten().len);
    _ = first_write_len;
}

test "frame - pong resets awaiting_pong flag" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock.deinit();

    var conn = Connection.init(mock.interface(), .{
        .ping_interval_ms = 1000,
        .pong_timeout_ms = 5000,
    }, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);

    time.advance(1500);
    try conn.tick(allocator);
    try std.testing.expect(conn.awaiting_pong);

    // Add pong and text message
    const pong = try buildMaskedFrame(allocator, true, .pong, "", [4]u8{ 0x11, 0x22, 0x33, 0x44 });
    defer allocator.free(pong);
    const text = try buildMaskedFrame(allocator, true, .text, "hi", [4]u8{ 0x11, 0x22, 0x33, 0x44 });
    defer allocator.free(text);

    try mock.addInput(pong);
    try mock.addInput(text);

    const msg = try conn.readMessage(allocator);
    defer msg.deinit(allocator);

    try std.testing.expect(!conn.awaiting_pong);
}

test "tick - no action when not open" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = MockStream.init(allocator);
    defer mock.deinit();

    var conn = Connection.init(mock.interface(), .{}, time.interface());
    defer conn.deinit(allocator);

    // Still in connecting state
    time.advance(100000);
    try conn.tick(allocator);

    try std.testing.expectEqual(@as(usize, 0), mock.getWritten().len);
}

test "send close with reason" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock.deinit();

    var conn = Connection.init(mock.interface(), .{}, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);
    try conn.sendCloseWithReason(allocator, .going_away, "server shutdown");

    _ = try conn.flushWrites();

    const frames = findFrameAfterHandshake(mock.getWritten()).?;
    try std.testing.expectEqual(@as(u8, 0x88), frames[0]);
    try std.testing.expectEqual(@as(u16, 1001), parseCloseCode(frames).?);

    // Reason starts after opcode(1) + len(1) + code(2)
    const payload_len = frames[1] & 0x7F;
    try std.testing.expectEqual(@as(u8, 2 + 15), payload_len); // code + reason
    try std.testing.expectEqualStrings("server shutdown", frames[4..19]);
}

test "send close with reason too long" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock.deinit();

    var conn = Connection.init(mock.interface(), .{}, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);

    var long_reason: [124]u8 = undefined;
    @memset(&long_reason, 'x');

    try std.testing.expectError(error.PayloadTooLarge, conn.sendCloseWithReason(allocator, .normal_closure, &long_reason));
}

test "frame - medium payload 126 length encoding" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock.deinit();

    const payload = try allocator.alloc(u8, 200);
    defer allocator.free(payload);
    @memset(payload, 'X');

    const frame = try buildMaskedFrame(allocator, true, .text, payload, [4]u8{ 0x11, 0x22, 0x33, 0x44 });
    defer allocator.free(frame);
    try mock.addInput(frame);

    var conn = Connection.init(mock.interface(), .{}, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);
    const msg = try conn.readMessage(allocator);
    defer msg.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 200), msg.payload.len);
    try std.testing.expectEqual(@as(u8, 'X'), msg.payload[0]);
    try std.testing.expectEqual(@as(u8, 'X'), msg.payload[199]);
}

test "send - medium payload uses 126 encoding" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock.deinit();

    var conn = Connection.init(mock.interface(), .{}, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);

    var payload: [200]u8 = undefined;
    @memset(&payload, 'Y');
    try conn.sendText(allocator, &payload);

    _ = try conn.flushWrites();

    const frames = findFrameAfterHandshake(mock.getWritten()).?;
    try std.testing.expectEqual(@as(u8, 0x81), frames[0]); // FIN + text
    try std.testing.expectEqual(@as(u8, 126), frames[1]); // Extended length marker
    const len = std.mem.readInt(u16, frames[2..4], .big);
    try std.testing.expectEqual(@as(u16, 200), len);
}

test "send - large payload uses 127 encoding" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock.deinit();

    var conn = Connection.init(mock.interface(), .{
        .max_write_buffer_size = 70000 * 2,
    }, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);

    const payload = try allocator.alloc(u8, 70000);
    defer allocator.free(payload);
    @memset(payload, 'Z');

    try conn.sendBinary(allocator, payload);
    _ = try conn.flushWrites();

    const frames = findFrameAfterHandshake(mock.getWritten()).?;
    try std.testing.expectEqual(@as(u8, 0x82), frames[0]); // FIN + binary
    try std.testing.expectEqual(@as(u8, 127), frames[1]); // Extended length marker
    const len = std.mem.readInt(u64, frames[2..10], .big);
    try std.testing.expectEqual(@as(u64, 70000), len);
}

test "frame - activity time updates on message" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = try MockStream.initWithData(allocator, buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));
    defer mock.deinit();

    var conn = Connection.init(mock.interface(), .{ .idle_timeout_ms = 10000 }, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);

    const initial_activity = conn.last_activity_time;

    time.advance(5000);

    const frame = try buildMaskedFrame(allocator, true, .text, "update", [4]u8{ 0x11, 0x22, 0x33, 0x44 });
    defer allocator.free(frame);
    try mock.addInput(frame);

    const msg = try conn.readMessage(allocator);
    defer msg.deinit(allocator);

    try std.testing.expect(conn.last_activity_time > initial_activity);
}

test "connection - remote address from stream" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = MockStream.initWithAddress(allocator, .{ 192, 168, 1, 100 }, 8080);
    defer mock.deinit();

    var conn = Connection.init(mock.interface(), .{}, time.interface());
    defer conn.deinit(allocator);

    const addr = conn.getRemoteAddress();
    try std.testing.expect(addr != null);
    try std.testing.expectEqual([4]u8{ 192, 168, 1, 100 }, addr.?.getIp());
    try std.testing.expectEqual(@as(u16, 8080), addr.?.getPort());
}

test "parseIp - valid addresses" {
    try std.testing.expectEqual([4]u8{ 192, 168, 1, 1 }, os.Address.parseIp("192.168.1.1").?);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, os.Address.parseIp("0.0.0.0").?);
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, os.Address.parseIp("255.255.255.255").?);
    try std.testing.expectEqual([4]u8{ 10, 0, 0, 1 }, os.Address.parseIp("10.0.0.1").?);
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, os.Address.parseIp("127.0.0.1").?);
    try std.testing.expectEqual([4]u8{ 1, 2, 3, 4 }, os.Address.parseIp("1.2.3.4").?);
}

test "parseIp - invalid addresses" {
    try std.testing.expectEqual(@as(?[4]u8, null), os.Address.parseIp(""));
    try std.testing.expectEqual(@as(?[4]u8, null), os.Address.parseIp("1.2.3"));
    try std.testing.expectEqual(@as(?[4]u8, null), os.Address.parseIp("1.2.3.4.5"));
    try std.testing.expectEqual(@as(?[4]u8, null), os.Address.parseIp("256.0.0.1"));
    try std.testing.expectEqual(@as(?[4]u8, null), os.Address.parseIp("1.2.3.999"));
    try std.testing.expectEqual(@as(?[4]u8, null), os.Address.parseIp("abc.def.ghi.jkl"));
    try std.testing.expectEqual(@as(?[4]u8, null), os.Address.parseIp("1.2.3."));
    try std.testing.expectEqual(@as(?[4]u8, null), os.Address.parseIp(".1.2.3"));
    try std.testing.expectEqual(@as(?[4]u8, null), os.Address.parseIp("1..2.3"));
    try std.testing.expectEqual(@as(?[4]u8, null), os.Address.parseIp("1.2.3.4:8080"));
    try std.testing.expectEqual(@as(?[4]u8, null), os.Address.parseIp("192.168.1"));
    try std.testing.expectEqual(@as(?[4]u8, null), os.Address.parseIp("1234"));
}

test "fromIpString - valid" {
    const addr = os.Address.fromIpString("85.12.34.56", 3508).?;
    try std.testing.expectEqual([4]u8{ 85, 12, 34, 56 }, addr.getIp());
    try std.testing.expectEqual(@as(u16, 3508), addr.getPort());
}

test "fromIpString - invalid returns null" {
    try std.testing.expectEqual(@as(?os.Address, null), os.Address.fromIpString("not.an.ip.x", 80));
}

inline fn buildHandshakeRequestWithRealIp(comptime key: []const u8, comptime real_ip: []const u8) []const u8 {
    return "GET /chat HTTP/1.1\r\n" ++
        "Host: localhost:8080\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: " ++ key ++ "\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "X-Real-IP: " ++ real_ip ++ "\r\n" ++
        "\r\n";
}

test "handshake - X-Real-IP updates remote address" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = MockStream.initWithAddress(allocator, .{ 127, 0, 0, 1 }, 9999);
    defer mock.deinit();

    try mock.addInput(buildHandshakeRequestWithRealIp("dGhlIHNhbXBsZSBub25jZQ==", "85.12.34.56"));

    var conn = Connection.init(mock.interface(), .{
        .trust_x_real_ip = true,
    }, time.interface());
    defer conn.deinit(allocator);

    // Before handshake: socket address (127.0.0.1)
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, conn.getRemoteAddress().?.getIp());

    try conn.performHandshake(allocator);

    // After handshake: real client IP from header
    const addr = conn.getRemoteAddress().?;
    try std.testing.expectEqual([4]u8{ 85, 12, 34, 56 }, addr.getIp());
    try std.testing.expectEqual(@as(u16, 9999), addr.getPort());
}

test "handshake - no X-Real-IP keeps original address" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = MockStream.initWithAddress(allocator, .{ 127, 0, 0, 1 }, 5555);
    defer mock.deinit();

    try mock.addInput(buildHandshakeRequest("dGhlIHNhbXBsZSBub25jZQ=="));

    var conn = Connection.init(mock.interface(), .{
        .trust_x_real_ip = true,
    }, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);

    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, conn.getRemoteAddress().?.getIp());
}

test "handshake - invalid X-Real-IP keeps original address" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var mock = MockStream.initWithAddress(allocator, .{ 127, 0, 0, 1 }, 5555);
    defer mock.deinit();

    try mock.addInput(buildHandshakeRequestWithRealIp("dGhlIHNhbXBsZSBub25jZQ==", "not-an-ip"));

    var conn = Connection.init(mock.interface(), .{
        .trust_x_real_ip = true,
    }, time.interface());
    defer conn.deinit(allocator);

    try conn.performHandshake(allocator);

    // Should keep original since header was invalid
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, conn.getRemoteAddress().?.getIp());
}

test "handshake - X-Real-IP re-registers in tracker" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var listener = MockListener.init();
    defer listener.deinit(allocator);

    // Socket address is 127.0.0.1, but X-Real-IP will be 85.12.34.56
    var mock = MockStream.initWithAddress(allocator, .{ 127, 0, 0, 1 }, 1234);
    defer mock.deinit();

    try mock.addInput(buildHandshakeRequestWithRealIp("dGhlIHNhbXBsZSBub25jZQ==", "85.12.34.56"));
    try listener.enqueueConnection(allocator, mock.interface());

    var server = Server.init(
        listener.interface(),
        .{
            .trust_x_real_ip = true,
        },
        time.interface(),
        ConnectionTracker.init(.{ .max_connections = 100, .max_connections_per_ip = 5 }),
    );
    defer server.deinit(allocator);

    var conn = try server.acceptConnection(allocator);
    defer conn.deinit(allocator);

    // Before handshake: tracked under 127.0.0.1
    try std.testing.expectEqual(@as(u8, 1), server.tracker.getConnectionCountFromIp(.{ 127, 0, 0, 1 }));
    try std.testing.expectEqual(@as(u8, 0), server.tracker.getConnectionCountFromIp(.{ 85, 12, 34, 56 }));

    try conn.performHandshake(allocator);

    // After handshake: moved to real IP
    try std.testing.expectEqual(@as(u8, 0), server.tracker.getConnectionCountFromIp(.{ 127, 0, 0, 1 }));
    try std.testing.expectEqual(@as(u8, 1), server.tracker.getConnectionCountFromIp(.{ 85, 12, 34, 56 }));
}

test "handshake - X-Real-IP tracker releases on deinit" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var listener = MockListener.init();
    defer listener.deinit(allocator);

    var mock = MockStream.initWithAddress(allocator, .{ 127, 0, 0, 1 }, 1234);
    defer mock.deinit();

    try mock.addInput(buildHandshakeRequestWithRealIp("dGhlIHNhbXBsZSBub25jZQ==", "10.20.30.40"));
    try listener.enqueueConnection(allocator, mock.interface());

    var server = Server.init(
        listener.interface(),
        .{
            .trust_x_real_ip = true,
        },
        time.interface(),
        ConnectionTracker.init(.{ .max_connections = 100, .max_connections_per_ip = 5 }),
    );
    defer server.deinit(allocator);

    {
        var conn = try server.acceptConnection(allocator);
        try conn.performHandshake(allocator);
        conn.deinit(allocator);
    }

    // After deinit: real IP slot freed
    try std.testing.expectEqual(@as(u8, 0), server.tracker.getConnectionCountFromIp(.{ 10, 20, 30, 40 }));
    try std.testing.expectEqual(@as(u32, 0), server.getConnectionCount());
}

test "handshake - X-Real-IP per-ip limit enforced on real IP" {
    const allocator = std.testing.allocator;

    var time = MockTimeProvider{};
    var listener = MockListener.init();
    defer listener.deinit(allocator);

    const real_ip = "192.168.50.1";
    const real_ip_bytes = [4]u8{ 192, 168, 50, 1 };

    // Create 3 connections all from 127.0.0.1 but with same X-Real-IP
    var mocks: [3]MockStream = undefined;
    for (0..3) |i| {
        mocks[i] = MockStream.initWithAddress(allocator, .{ 127, 0, 0, 1 }, @intCast(1234 + i));
        try mocks[i].addInput(buildHandshakeRequestWithRealIp("dGhlIHNhbXBsZSBub25jZQ==", real_ip));
        try listener.enqueueConnection(allocator, mocks[i].interface());
    }
    defer for (&mocks) |*m| m.deinit();

    var server = Server.init(
        listener.interface(),
        .{
            .trust_x_real_ip = true,
        },
        time.interface(),
        ConnectionTracker.init(.{ .max_connections = 100, .max_connections_per_ip = 2 }),
    );
    defer server.deinit(allocator);

    var conn1 = try server.acceptConnection(allocator);
    defer conn1.deinit(allocator);
    try conn1.performHandshake(allocator);

    var conn2 = try server.acceptConnection(allocator);
    defer conn2.deinit(allocator);
    try conn2.performHandshake(allocator);

    try std.testing.expectEqual(@as(u8, 2), server.tracker.getConnectionCountFromIp(real_ip_bytes));

    // Third connection: accept succeeds (127.0.0.1 has slots) but handshake should fail
    // because X-Real-IP re-registration will hit the per-ip limit
    var conn3 = try server.acceptConnection(allocator);
    defer conn3.deinit(allocator);

    try std.testing.expectError(error.ConnectionClosed, conn3.performHandshake(allocator));
    try std.testing.expectEqual(.closed, conn3.state);
}
