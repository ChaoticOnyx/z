// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const builtin = @import("builtin");

const libws = @import("libws.zig");

pub const is_windows = builtin.os.tag == .windows;
pub const is_linux = builtin.os.tag == .linux;

const c = @cImport({
    @cInclude("time.h");

    if (is_windows) {
        @cDefine("_WIN32_WINNT", "0x0600");
        @cDefine("WIN32_LEAN_AND_MEAN", "1");
        @cInclude("winsock2.h");
        @cInclude("ws2tcpip.h");
        @cInclude("windows.h");
    } else {
        @cInclude("errno.h");
        @cInclude("sys/socket.h");
        @cInclude("sys/types.h");
        @cInclude("netinet/in.h");
        @cInclude("netinet/tcp.h");
        @cInclude("arpa/inet.h");
        @cInclude("unistd.h");
        @cInclude("fcntl.h");
        @cInclude("poll.h");
        @cInclude("sys/time.h");
    }
});

pub const Socket = if (is_windows) c.SOCKET else c_int;
pub const INVALID_SOCKET: Socket = if (is_windows) ~@as(Socket, 0) else -1;
pub const SOCKET_ERROR: c_int = -1;

pub const socklen_t = if (is_windows) c_int else c.socklen_t;

const EAGAIN = if (is_linux) c.EAGAIN else 0;
const EWOULDBLOCK = if (is_linux) c.EWOULDBLOCK else 0;
const EINPROGRESS = if (is_linux) c.EINPROGRESS else 0;
const ECONNRESET = if (is_linux) c.ECONNRESET else 0;
const ECONNREFUSED = if (is_linux) c.ECONNREFUSED else 0;
const EPIPE = if (is_linux) c.EPIPE else 0;
const EINTR = if (is_linux) c.EINTR else 0;

const WSAEWOULDBLOCK = if (is_windows) c.WSAEWOULDBLOCK else 0;
const WSAECONNRESET = if (is_windows) c.WSAECONNRESET else 0;
const WSAECONNREFUSED = if (is_windows) c.WSAECONNREFUSED else 0;
const WSAEINPROGRESS = if (is_windows) c.WSAEINPROGRESS else 0;
const WSAEINTR = if (is_windows) c.WSAEINTR else 0;

var wsa_initialized: bool = false;
var wsa_init_error: bool = false;

pub const InitError = error{
    WsaStartupFailed,
    WsaVersionNotSupported,
};

pub inline fn init() InitError!void {
    if (comptime is_windows) {
        if (wsa_init_error) {
            return error.WsaStartupFailed;
        }

        if (wsa_initialized) {
            return;
        }

        var wsa_data: c.WSADATA = undefined;
        const result = c.WSAStartup(0x0202, &wsa_data);

        if (result != 0) {
            wsa_init_error = true;

            return error.WsaStartupFailed;
        }

        // Verify version 2.2
        if (c.LOBYTE(wsa_data.wVersion) != 2 or c.HIBYTE(wsa_data.wVersion) != 2) {
            _ = c.WSACleanup();
            wsa_init_error = true;

            return error.WsaVersionNotSupported;
        }

        wsa_initialized = true;
    }
}

pub inline fn deinit() void {
    if (is_windows and wsa_initialized) {
        _ = c.WSACleanup();

        wsa_initialized = false;
    }
}

inline fn getLastError() c_int {
    if (comptime is_windows) {
        return c.WSAGetLastError();
    } else {
        return @intCast(std.c._errno().*);
    }
}

inline fn isWouldBlock(err: c_int) bool {
    if (comptime is_windows) {
        return err == WSAEWOULDBLOCK;
    } else {
        return err == EAGAIN or err == EWOULDBLOCK;
    }
}

inline fn isConnReset(err: c_int) bool {
    if (comptime is_windows) {
        return err == WSAECONNRESET;
    } else {
        return err == ECONNRESET or err == EPIPE;
    }
}

inline fn isConnRefused(err: c_int) bool {
    if (comptime is_windows) {
        return err == WSAECONNREFUSED;
    } else {
        return err == ECONNREFUSED;
    }
}

inline fn isInterrupted(err: c_int) bool {
    if (comptime is_windows) {
        return err == WSAEINTR;
    } else {
        return err == EINTR;
    }
}

inline fn mapReadError(err: c_int) libws.Stream.ReadError {
    if (isWouldBlock(err)) {
        return error.WouldBlock;
    }

    if (isConnReset(err)) {
        return error.ConnectionReset;
    }

    if (isConnRefused(err)) {
        return error.ConnectionRefused;
    }

    return error.Unexpected;
}

inline fn mapWriteError(err: c_int) libws.Stream.WriteError {
    if (isWouldBlock(err)) {
        return error.WouldBlock;
    }

    if (isConnReset(err)) {
        return error.ConnectionReset;
    }

    if (is_linux and err == EPIPE) {
        return error.BrokenPipe;
    }

    return error.Unexpected;
}

const FIONBIO: u32 = 0x8004667E;

inline fn setNonBlocking(sock: Socket) !void {
    if (comptime is_windows) {
        var mode: c_ulong = 1;

        if (c.ioctlsocket(sock, @bitCast(FIONBIO), &mode) == SOCKET_ERROR) {
            return error.SetOptionFailed;
        }
    } else {
        const flags = c.fcntl(sock, c.F_GETFL, @as(c_int, 0));

        if (flags == -1) {
            return error.SetOptionFailed;
        }

        if (c.fcntl(sock, c.F_SETFL, flags | c.O_NONBLOCK) == -1) {
            return error.SetOptionFailed;
        }
    }
}

inline fn setReuseAddr(sock: Socket) !void {
    var optval: c_int = 1;
    const result = c.setsockopt(
        sock,
        c.SOL_SOCKET,
        c.SO_REUSEADDR,
        @ptrCast(&optval),
        @sizeOf(c_int),
    );

    if (result == SOCKET_ERROR) {
        return error.SetOptionFailed;
    }
}

inline fn setNoDelay(sock: Socket) !void {
    var optval: c_int = 1;
    const result = c.setsockopt(
        sock,
        c.IPPROTO_TCP,
        c.TCP_NODELAY,
        @ptrCast(&optval),
        @sizeOf(c_int),
    );

    if (result == SOCKET_ERROR) {
        return error.SetOptionFailed;
    }
}

inline fn closeSocket(sock: Socket) void {
    if (sock == INVALID_SOCKET) {
        return;
    }

    if (comptime is_windows) {
        _ = c.closesocket(sock);
    } else {
        _ = c.close(sock);
    }
}

pub const Address = struct {
    pub const MAX_STRING_LEN = 21; // "255.255.255.255:65535"

    addr: c.sockaddr_in,

    pub inline fn init(ip: [4]u8, port: u16) Address {
        var addr: c.sockaddr_in = std.mem.zeroes(c.sockaddr_in);
        addr.sin_family = c.AF_INET;
        addr.sin_port = toBigEndian16(port);

        if (comptime is_windows) {
            addr.sin_addr.S_un.S_un_b = .{
                .s_b1 = ip[0],
                .s_b2 = ip[1],
                .s_b3 = ip[2],
                .s_b4 = ip[3],
            };
        } else {
            addr.sin_addr.s_addr = @bitCast(ip);
        }

        return .{ .addr = addr };
    }

    pub inline fn any(port: u16) Address {
        var addr: c.sockaddr_in = std.mem.zeroes(c.sockaddr_in);
        addr.sin_family = c.AF_INET;
        addr.sin_port = toBigEndian16(port);

        if (comptime is_windows) {
            addr.sin_addr.S_un.S_addr = c.INADDR_ANY;
        } else {
            addr.sin_addr.s_addr = c.INADDR_ANY;
        }

        return .{ .addr = addr };
    }

    pub inline fn localhost(port: u16) Address {
        return .init(.{ 127, 0, 0, 1 }, port);
    }

    pub inline fn getPort(this: Address) u16 {
        return fromBigEndian16(this.addr.sin_port);
    }

    pub inline fn getIp(this: Address) [4]u8 {
        if (comptime is_windows) {
            return .{
                this.addr.sin_addr.S_un.S_un_b.s_b1,
                this.addr.sin_addr.S_un.S_un_b.s_b2,
                this.addr.sin_addr.S_un.S_un_b.s_b3,
                this.addr.sin_addr.S_un.S_un_b.s_b4,
            };
        } else {
            return @bitCast(this.addr.sin_addr.s_addr);
        }
    }

    pub inline fn format(this: Address, writer: *std.Io.Writer) !void {
        const ip = this.getIp();
        const port = this.getPort();

        try writer.print("{d}.{d}.{d}.{d}:{d}", .{ ip[0], ip[1], ip[2], ip[3], port });
    }

    inline fn toBigEndian16(val: u16) u16 {
        return std.mem.nativeToBig(u16, val);
    }

    inline fn fromBigEndian16(val: u16) u16 {
        return std.mem.bigToNative(u16, val);
    }

    pub inline fn parseIp(str: []const u8) ?[4]u8 {
        var octets: [4]u8 = undefined;
        var octet_index: usize = 0;
        var current: u16 = 0;
        var has_digit = false;

        for (str) |ch| {
            if (ch == '.') {
                if (!has_digit or octet_index >= 3) {
                    return null;
                }

                if (current > 255) {
                    return null;
                }

                octets[octet_index] = @intCast(current);
                octet_index += 1;
                current = 0;
                has_digit = false;
            } else if (ch >= '0' and ch <= '9') {
                current = current * 10 + (ch - '0');
                has_digit = true;
            } else {
                return null;
            }
        }

        if (!has_digit or octet_index != 3) {
            return null;
        }

        if (current > 255) {
            return null;
        }

        octets[3] = @intCast(current);

        return octets;
    }

    pub inline fn fromIpString(str: []const u8, port: u16) ?Address {
        const ip = parseIp(str) orelse {
            return null;
        };

        return .init(ip, port);
    }
};

pub const TcpStream = struct {
    handle: Socket,
    heap_allocated: bool = false,

    pub const ConnectError = error{
        SocketCreateFailed,
        SetOptionFailed,
        ConnectFailed,
        WouldBlock,
    };

    pub fn connect(address: Address) ConnectError!TcpStream {
        const sock = c.socket(c.AF_INET, c.SOCK_STREAM, c.IPPROTO_TCP);

        if (sock == INVALID_SOCKET) {
            return error.SocketCreateFailed;
        }
        errdefer closeSocket(sock);

        try setNonBlocking(sock);
        try setNoDelay(sock);

        const result = c.connect(
            sock,
            @ptrCast(&address.addr),
            @sizeOf(c.sockaddr_in),
        );

        if (result == SOCKET_ERROR) {
            const err = getLastError();

            // Non-blocking connect in progress is OK
            if (comptime is_windows) {
                if (err != WSAEWOULDBLOCK) {
                    return error.ConnectFailed;
                }
            } else {
                if (err != EINPROGRESS and !isWouldBlock(err)) {
                    return error.ConnectFailed;
                }
            }
        }

        return .{ .handle = sock };
    }

    pub inline fn fromHandle(handle: Socket) TcpStream {
        return .{ .handle = handle };
    }

    pub fn read(this: *TcpStream, buf: []u8) libws.Stream.ReadError!usize {
        while (true) {
            const result = c.recv(
                this.handle,
                @ptrCast(buf.ptr),
                @intCast(buf.len),
                0,
            );

            if (result == SOCKET_ERROR) {
                const err = getLastError();

                if (isInterrupted(err)) {
                    continue;
                }

                return mapReadError(err);
            }

            if (result == 0) {
                return error.ConnectionClosed;
            }

            return @intCast(result);
        }
    }

    pub fn write(this: *TcpStream, data: []const u8) libws.Stream.WriteError!usize {
        while (true) {
            const flags: c_int = if (is_linux) c.MSG_NOSIGNAL else 0;

            const result = c.send(
                this.handle,
                @ptrCast(data.ptr),
                @intCast(data.len),
                flags,
            );

            if (result == SOCKET_ERROR) {
                const err = getLastError();

                if (isInterrupted(err)) {
                    continue;
                }

                return mapWriteError(err);
            }

            return @intCast(result);
        }
    }

    pub inline fn close(this: *TcpStream) void {
        closeSocket(this.handle);
        this.handle = INVALID_SOCKET;
    }

    pub inline fn isValid(this: TcpStream) bool {
        return this.handle != INVALID_SOCKET;
    }

    pub inline fn getRemoteAddress(this: *TcpStream) ?Address {
        var addr: c.sockaddr_in = undefined;
        var len: socklen_t = @sizeOf(c.sockaddr_in);

        if (c.getpeername(this.handle, @ptrCast(&addr), &len) == SOCKET_ERROR) {
            return null;
        }

        return .{ .addr = addr };
    }

    pub inline fn interface(this: *TcpStream) libws.Stream {
        return .{
            .ptr = @ptrCast(this),
            .vtable = &.{
                .read = streamRead,
                .write = streamWrite,
                .get_remote_address = streamGetRemoteAddress,
                .deinit = streamDeinit,
            },
        };
    }

    fn streamRead(ctx: *anyopaque, buf: []u8) libws.Stream.ReadError!usize {
        const this: *TcpStream = @ptrCast(@alignCast(ctx));

        return this.read(buf);
    }

    fn streamWrite(ctx: *anyopaque, data: []const u8) libws.Stream.WriteError!usize {
        const this: *TcpStream = @ptrCast(@alignCast(ctx));

        return this.write(data);
    }

    fn streamGetRemoteAddress(ctx: *anyopaque) ?Address {
        const this: *TcpStream = @ptrCast(@alignCast(ctx));

        return this.getRemoteAddress();
    }

    fn streamClose(ctx: *anyopaque) void {
        const this: *TcpStream = @ptrCast(@alignCast(ctx));

        this.close();
    }

    fn streamDeinit(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const this: *TcpStream = @ptrCast(@alignCast(ctx));

        this.close();

        if (this.heap_allocated) {
            allocator.destroy(this);
        }
    }
};

pub const TcpListener = struct {
    handle: Socket,

    pub const BindError = error{
        SocketCreateFailed,
        SetOptionFailed,
        BindFailed,
        ListenFailed,
    };

    pub fn bind(address: Address, backlog: u31) BindError!TcpListener {
        const sock = c.socket(c.AF_INET, c.SOCK_STREAM, c.IPPROTO_TCP);

        if (sock == INVALID_SOCKET) {
            return error.SocketCreateFailed;
        }

        errdefer closeSocket(sock);

        try setReuseAddr(sock);
        try setNonBlocking(sock);

        const bind_result = c.bind(
            sock,
            @ptrCast(&address.addr),
            @sizeOf(c.sockaddr_in),
        );

        if (bind_result == SOCKET_ERROR) {
            return error.BindFailed;
        }

        const listen_result = c.listen(sock, @intCast(backlog));
        if (listen_result == SOCKET_ERROR) {
            return error.ListenFailed;
        }

        return .{ .handle = sock };
    }

    pub fn accept(this: *TcpListener, allocator: std.mem.Allocator) libws.Listener.AcceptError!libws.Stream {
        var client_addr: c.sockaddr_in = undefined;
        var addr_len: socklen_t = @sizeOf(c.sockaddr_in);

        const client_sock = c.accept(
            this.handle,
            @ptrCast(&client_addr),
            &addr_len,
        );

        if (client_sock == INVALID_SOCKET) {
            const err = getLastError();

            if (isWouldBlock(err)) {
                return error.WouldBlock;
            }

            return error.Unexpected;
        }

        // Configure accepted socket
        setNonBlocking(client_sock) catch {
            closeSocket(client_sock);

            return error.Unexpected;
        };

        setNoDelay(client_sock) catch {
            closeSocket(client_sock);

            return error.Unexpected;
        };

        // Allocate TcpStream on heap for stable pointer
        const stream = allocator.create(TcpStream) catch {
            closeSocket(client_sock);

            return error.Unexpected;
        };

        stream.* = TcpStream.fromHandle(client_sock);
        stream.heap_allocated = true;

        return stream.interface();
    }

    pub inline fn deinit(this: *TcpListener) void {
        closeSocket(this.handle);
        this.handle = INVALID_SOCKET;
    }

    pub inline fn isValid(this: TcpListener) bool {
        return this.handle != INVALID_SOCKET;
    }

    pub inline fn getLocalAddress(this: TcpListener) ?Address {
        var addr: c.sockaddr_in = undefined;
        var len: socklen_t = @sizeOf(c.sockaddr_in);

        if (c.getsockname(this.handle, @ptrCast(&addr), &len) == SOCKET_ERROR) {
            return null;
        }

        return .{ .addr = addr };
    }

    pub inline fn interface(this: *TcpListener) libws.Listener {
        return .{
            .ptr = @ptrCast(this),
            .vtable = &.{
                .accept = listenerAccept,
            },
        };
    }

    fn listenerAccept(ctx: *anyopaque, allocator: std.mem.Allocator) libws.Listener.AcceptError!libws.Stream {
        const this: *TcpListener = @ptrCast(@alignCast(ctx));

        return this.accept(allocator);
    }
};

pub const NativeTimeProvider = struct {
    pub fn milliTimestamp(_: *anyopaque) i64 {
        if (comptime is_windows) {
            var ft: c.FILETIME = undefined;
            c.GetSystemTimeAsFileTime(&ft);

            // FILETIME is 100-nanosecond intervals since Jan 1, 1601
            const intervals: u64 = (@as(u64, ft.dwHighDateTime) << 32) | ft.dwLowDateTime;

            // Convert to Unix epoch (Jan 1, 1970)
            // Difference is 11644473600 seconds = 116444736000000000 100-ns intervals
            const unix_intervals = intervals -% 116444736000000000;

            // Convert to milliseconds
            return @intCast(unix_intervals / 10000);
        } else {
            var tv: c.timeval = undefined;
            _ = c.gettimeofday(&tv, null);

            return @as(i64, tv.tv_sec) * 1000 + @divTrunc(@as(i64, tv.tv_usec), 1000);
        }
    }

    pub fn interface() libws.TimeProvider {
        return .{
            .ptr = undefined,
            .vtable = &.{
                .milliTimestamp = milliTimestamp,
            },
        };
    }
};

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

    pub fn applyTo(this: Timezone, utc_timestamp: i64) i64 {
        return utc_timestamp + this.offset_seconds;
    }
};
