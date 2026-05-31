// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
pub const socklen_t = std.c.socklen_t;
const builtin = @import("builtin");

const libws = @import("libws.zig");
const z = @import("root.zig");

pub const is_windows = builtin.os.tag == .windows;
pub const is_linux = builtin.os.tag == .linux;

// Linux socket / network constants
const AF_INET: c_int = 2;
const SOCK_STREAM: c_int = 1;
const IPPROTO_TCP: c_int = 6;

// SOL_SOCKET and SO_REUSEADDR have different values on Windows and Linux
const SOL_SOCKET: c_int = if (is_windows) 0xFFFF else 1;
const SO_REUSEADDR: c_int = if (is_windows) 0x0004 else 2;

const TCP_NODELAY: c_int = 1;
const MSG_NOSIGNAL: c_int = 16384;
const F_GETFL: c_int = 3;
const F_SETFL: c_int = 4;
const O_NONBLOCK: c_int = 2048;

// Linux errno constants
const EAGAIN: c_int = 11;
const EWOULDBLOCK: c_int = 11;
const EINPROGRESS: c_int = 115;
const ECONNRESET: c_int = 104;
const ECONNREFUSED: c_int = 111;
const EPIPE: c_int = 32;
const EINTR: c_int = 4;

// Windows WSA error constants
const WSAEWOULDBLOCK: c_int = 10035;
const WSAECONNRESET: c_int = 10054;
const WSAECONNREFUSED: c_int = 10061;
const WSAEINPROGRESS: c_int = 10036;
const WSAEINTR: c_int = 10004;

const INADDR_ANY: u32 = 0;

const winapi_sock = struct {
    extern "Ws2_32" fn socket(domain: c_int, sock_type: c_int, protocol: c_int) callconv(.winapi) usize;
    extern "Ws2_32" fn connect(sockfd: usize, addr: *const std.c.sockaddr, addrlen: c_int) callconv(.winapi) c_int;
    extern "Ws2_32" fn bind(sockfd: usize, addr: *const std.c.sockaddr, addrlen: c_int) callconv(.winapi) c_int;
    extern "Ws2_32" fn listen(sockfd: usize, backlog: c_int) callconv(.winapi) c_int;
    extern "Ws2_32" fn accept(sockfd: usize, addr: ?*std.c.sockaddr, addrlen: ?*c_int) callconv(.winapi) usize;
    extern "Ws2_32" fn setsockopt(sockfd: usize, level: c_int, optname: c_int, optval: ?*const anyopaque, optlen: c_int) callconv(.winapi) c_int;
    extern "Ws2_32" fn getsockname(sockfd: usize, addr: *std.c.sockaddr, addrlen: *c_int) callconv(.winapi) c_int;
    extern "Ws2_32" fn getpeername(sockfd: usize, addr: *std.c.sockaddr, addrlen: *c_int) callconv(.winapi) c_int;
    extern "Ws2_32" fn recv(sockfd: usize, buf: ?*anyopaque, len: c_int, flags: c_int) callconv(.winapi) c_int;
    extern "Ws2_32" fn send(sockfd: usize, buf: *const anyopaque, len: c_int, flags: c_int) callconv(.winapi) c_int;
};

inline fn w_socket(domain: c_int, sock_type: c_int, protocol: c_int) isize {
    if (comptime is_windows) {
        const result = winapi_sock.socket(domain, sock_type, protocol);
        if (result == ~@as(usize, 0)) {
            return -1;
        }
        return @intCast(result);
    } else {
        return std.c.socket(domain, sock_type, protocol);
    }
}

inline fn w_connect(sockfd: std.c.fd_t, addr: *const std.c.sockaddr, addrlen: std.c.socklen_t) c_int {
    if (comptime is_windows) {
        return winapi_sock.connect(socketToWinsock(sockfd), addr, @intCast(addrlen));
    } else {
        return std.c.connect(sockfd, addr, addrlen);
    }
}

inline fn w_bind(sockfd: std.c.fd_t, addr: *const std.c.sockaddr, addrlen: std.c.socklen_t) c_int {
    if (comptime is_windows) {
        return winapi_sock.bind(socketToWinsock(sockfd), addr, @intCast(addrlen));
    } else {
        return std.c.bind(sockfd, addr, addrlen);
    }
}

inline fn w_listen(sockfd: std.c.fd_t, backlog: c_int) c_int {
    if (comptime is_windows) {
        return winapi_sock.listen(socketToWinsock(sockfd), backlog);
    } else {
        return std.c.listen(sockfd, @intCast(backlog));
    }
}

inline fn w_accept(sockfd: std.c.fd_t, addr: ?*std.c.sockaddr, addrlen: ?*std.c.socklen_t) isize {
    if (comptime is_windows) {
        var win_addrlen: c_int = if (addrlen) |ptr| @intCast(ptr.*) else 0;
        const result = winapi_sock.accept(
            socketToWinsock(sockfd),
            addr,
            if (addrlen != null) &win_addrlen else null,
        );
        if (addrlen != null) {
            addrlen.?.* = @intCast(win_addrlen);
        }
        if (result == ~@as(usize, 0)) {
            return -1;
        }
        return @intCast(result);
    } else {
        return std.c.accept(sockfd, addr, addrlen);
    }
}

inline fn w_setsockopt(sockfd: std.c.fd_t, level: c_int, optname: c_int, optval: ?*const anyopaque, optlen: std.c.socklen_t) c_int {
    if (comptime is_windows) {
        return winapi_sock.setsockopt(socketToWinsock(sockfd), level, optname, optval, @intCast(optlen));
    } else {
        return std.c.setsockopt(sockfd, level, @intCast(optname), optval, optlen);
    }
}

inline fn w_getsockname(sockfd: std.c.fd_t, addr: *std.c.sockaddr, addrlen: *std.c.socklen_t) c_int {
    if (comptime is_windows) {
        var win_addrlen: c_int = @intCast(addrlen.*);
        const result = winapi_sock.getsockname(socketToWinsock(sockfd), addr, &win_addrlen);
        addrlen.* = @intCast(win_addrlen);
        return result;
    } else {
        return std.c.getsockname(sockfd, addr, addrlen);
    }
}

inline fn w_getpeername(sockfd: std.c.fd_t, addr: *std.c.sockaddr, addrlen: *std.c.socklen_t) c_int {
    if (comptime is_windows) {
        var win_addrlen: c_int = @intCast(addrlen.*);
        const result = winapi_sock.getpeername(socketToWinsock(sockfd), addr, &win_addrlen);
        addrlen.* = @intCast(win_addrlen);
        return result;
    } else {
        return std.c.getpeername(sockfd, addr, addrlen);
    }
}

inline fn w_recv(sockfd: std.c.fd_t, buf: ?*anyopaque, len: usize, flags: c_int) isize {
    if (comptime is_windows) {
        return @intCast(winapi_sock.recv(socketToWinsock(sockfd), buf, @intCast(len), flags));
    } else {
        return std.c.recv(sockfd, buf, len, flags);
    }
}

inline fn w_send(sockfd: std.c.fd_t, buf: *const anyopaque, len: usize, flags: c_int) isize {
    if (comptime is_windows) {
        return @intCast(winapi_sock.send(socketToWinsock(sockfd), buf, @intCast(len), flags));
    } else {
        return std.c.send(sockfd, buf, len, @intCast(flags));
    }
}

const sockaddr_in = extern struct {
    sin_family: u16,
    sin_port: u16,
    sin_addr: extern union {
        s_addr: u32,
    },
    sin_zero: [8]u8,
};

const timeval = extern struct {
    tv_sec: isize,
    tv_usec: isize,
};

const tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: isize,
    tm_zone: [*:0]const u8,
};

extern fn clock_gettime(clockid: c_int, tp: *std.posix.timespec) c_int;
extern fn gettimeofday(tv: *timeval, tz: ?*anyopaque) c_int;
extern fn localtime(timer: *const isize) ?*tm;
extern fn gmtime(timer: *const isize) ?*tm;

const SOCKET = usize;

const WSADATA = extern struct {
    wVersion: u16,
    wHighVersion: u16,
    szDescription: [257]u8,
    szSystemStatus: [129]u8,
    iMaxSockets: u16,
    iMaxUdpDg: u16,
    lpVendorInfo: ?*u8,
};

const FILETIME = extern struct {
    dwLowDateTime: u32,
    dwHighDateTime: u32,
};

extern "Ws2_32" fn WSAStartup(wVersionRequired: u16, lpWSAData: *WSADATA) callconv(.winapi) c_int;
extern "Ws2_32" fn WSACleanup() callconv(.winapi) c_int;
extern "Ws2_32" fn WSAGetLastError() callconv(.winapi) c_int;
extern "Ws2_32" fn ioctlsocket(s: SOCKET, cmd: u32, argp: *u32) callconv(.winapi) c_int;
extern "Ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) c_int;

extern "kernel32" fn GetSystemTimeAsFileTime(lpFileTime: *FILETIME) callconv(.winapi) void;

fn LOBYTE(w: u16) u8 {
    return @truncate(w);
}
fn HIBYTE(w: u16) u8 {
    return @truncate(w >> 8);
}

pub const Socket = if (is_windows) ?*anyopaque else std.c.fd_t;
pub const SOCKET_ERROR: c_int = -1;

/// Convert the c_int returned by socket()/accept() to Socket (fd_t).
/// On Windows, fd_t is *anyopaque so we need @ptrFromInt; on Linux fd_t is i32 (identity).
inline fn toSocket(fd: isize) Socket {
    if (comptime is_windows) {
        if (fd == -1) {
            return null;
        }

        return @ptrFromInt(@as(usize, @intCast(@as(u32, @bitCast(@as(i32, @intCast(fd)))))));
    } else {
        return @intCast(fd);
    }
}

inline fn socketToFd(sock: Socket) std.c.fd_t {
    if (comptime is_windows) {
        return sock orelse unreachable;
    } else {
        return sock;
    }
}

inline fn isInvalidSocket(sock: Socket) bool {
    if (comptime is_windows) {
        return sock == null;
    } else {
        return sock == -1;
    }
}

inline fn socketToWinsock(sock: std.c.fd_t) usize {
    if (comptime is_windows) {
        return @intCast(@intFromPtr(sock));
    } else {
        @compileError("Should not be called on Linux");
    }
}

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

        var wsa_data: WSADATA = undefined;
        const result = WSAStartup(0x0202, &wsa_data);

        if (result != 0) {
            wsa_init_error = true;

            return error.WsaStartupFailed;
        }

        // Verify version 2.2
        if (LOBYTE(wsa_data.wVersion) != 2 or HIBYTE(wsa_data.wVersion) != 2) {
            _ = WSACleanup();
            wsa_init_error = true;

            return error.WsaVersionNotSupported;
        }

        wsa_initialized = true;
    }
}

pub inline fn deinit() void {
    if (is_windows and wsa_initialized) {
        _ = WSACleanup();

        wsa_initialized = false;
    }
}

inline fn getLastError() c_int {
    if (comptime is_windows) {
        return WSAGetLastError();
    } else {
        return std.c._errno().*;
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
        var mode: u32 = 1;

        if (ioctlsocket(socketToWinsock(socketToFd(sock)), @bitCast(FIONBIO), &mode) == SOCKET_ERROR) {
            return error.SetOptionFailed;
        }
    } else {
        const flags = std.c.fcntl(sock, F_GETFL, @as(c_int, 0));

        if (flags == -1) {
            return error.SetOptionFailed;
        }

        if (std.c.fcntl(sock, F_SETFL, flags | O_NONBLOCK) == -1) {
            return error.SetOptionFailed;
        }
    }
}

inline fn setReuseAddr(sock: Socket) !void {
    var optval: c_int = 1;
    const result = w_setsockopt(
        socketToFd(sock),
        SOL_SOCKET,
        SO_REUSEADDR,
        @ptrCast(&optval),
        @sizeOf(c_int),
    );

    if (result == SOCKET_ERROR) {
        return error.SetOptionFailed;
    }
}

inline fn setNoDelay(sock: Socket) !void {
    var optval: c_int = 1;
    const result = w_setsockopt(
        socketToFd(sock),
        IPPROTO_TCP,
        TCP_NODELAY,
        @ptrCast(&optval),
        @sizeOf(c_int),
    );

    if (result == SOCKET_ERROR) {
        return error.SetOptionFailed;
    }
}

inline fn closeSocket(sock: Socket) void {
    if (isInvalidSocket(sock)) return;
    if (comptime is_windows) {
        _ = closesocket(socketToWinsock(socketToFd(sock)));
    } else {
        _ = std.os.linux.close(sock);
    }
}

pub const Address = struct {
    pub const MAX_STRING_LEN = 21; // "255.255.255.255:65535"

    addr: sockaddr_in,

    pub inline fn init(ip: [4]u8, port: u16) Address {
        var addr: sockaddr_in = std.mem.zeroes(sockaddr_in);
        addr.sin_family = AF_INET;
        addr.sin_port = toBigEndian16(port);

        if (comptime is_windows) {
            addr.sin_addr.s_addr = @bitCast(@as(u32, ip[0]) | (@as(u32, ip[1]) << 8) | (@as(u32, ip[2]) << 16) | (@as(u32, ip[3]) << 24));
        } else {
            addr.sin_addr.s_addr = @bitCast(ip);
        }

        return .{ .addr = addr };
    }

    pub inline fn any(port: u16) Address {
        var addr: sockaddr_in = std.mem.zeroes(sockaddr_in);
        addr.sin_family = AF_INET;
        addr.sin_port = toBigEndian16(port);

        if (comptime is_windows) {
            addr.sin_addr.s_addr = INADDR_ANY;
        } else {
            addr.sin_addr.s_addr = INADDR_ANY;
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
            const s_addr = this.addr.sin_addr.s_addr;
            return .{
                @truncate(s_addr),
                @truncate(s_addr >> 8),
                @truncate(s_addr >> 16),
                @truncate(s_addr >> 24),
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
        const raw_sock = w_socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);

        if (raw_sock == -1) {
            return error.SocketCreateFailed;
        }

        const sock = toSocket(raw_sock);
        errdefer closeSocket(sock);

        try setNonBlocking(sock);
        try setNoDelay(sock);

        const result = w_connect(
            socketToFd(sock),
            @ptrCast(&address.addr),
            @sizeOf(sockaddr_in),
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
            const result = w_recv(
                socketToFd(this.handle),
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
            const flags: c_int = if (is_linux) MSG_NOSIGNAL else 0;

            const result = w_send(
                socketToFd(this.handle),
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

        if (comptime is_windows) {
            this.handle = null;
        } else {
            this.handle = -1;
        }
    }

    pub inline fn isValid(this: TcpStream) bool {
        return !isInvalidSocket(this.handle);
    }

    pub inline fn getRemoteAddress(this: *TcpStream) ?Address {
        var addr: sockaddr_in = undefined;
        var len: socklen_t = @sizeOf(sockaddr_in);

        if (w_getpeername(socketToFd(this.handle), @ptrCast(&addr), &len) == SOCKET_ERROR) {
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
        const raw_sock = w_socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);

        if (raw_sock == -1) {
            return error.SocketCreateFailed;
        }

        const sock = toSocket(raw_sock);
        errdefer closeSocket(sock);

        try setReuseAddr(sock);
        try setNonBlocking(sock);

        const bind_result = w_bind(
            socketToFd(sock),
            @ptrCast(&address.addr),
            @sizeOf(sockaddr_in),
        );

        if (bind_result == SOCKET_ERROR) {
            return error.BindFailed;
        }

        const listen_result = w_listen(socketToFd(sock), @intCast(backlog));
        if (listen_result == SOCKET_ERROR) {
            return error.ListenFailed;
        }

        return .{ .handle = sock };
    }

    pub fn accept(this: *TcpListener, allocator: std.mem.Allocator) libws.Listener.AcceptError!libws.Stream {
        var client_addr: sockaddr_in = undefined;
        var addr_len: socklen_t = @sizeOf(sockaddr_in);

        const raw_client = w_accept(
            socketToFd(this.handle),
            @ptrCast(&client_addr),
            &addr_len,
        );

        if (raw_client == -1) {
            const err = getLastError();

            if (isWouldBlock(err)) {
                return error.WouldBlock;
            }

            return error.Unexpected;
        }

        const client_sock = toSocket(raw_client);

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

        if (comptime is_windows) {
            this.handle = null;
        } else {
            this.handle = -1;
        }
    }

    pub inline fn isValid(this: TcpListener) bool {
        return !isInvalidSocket(this.handle);
    }

    pub inline fn getLocalAddress(this: TcpListener) ?Address {
        var addr: sockaddr_in = undefined;
        var len: socklen_t = @sizeOf(sockaddr_in);

        if (w_getsockname(socketToFd(this.handle), @ptrCast(&addr), &len) == SOCKET_ERROR) {
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
            var ft: FILETIME = undefined;
            GetSystemTimeAsFileTime(&ft);

            // FILETIME is 100-nanosecond intervals since Jan 1, 1601
            const intervals: u64 = (@as(u64, ft.dwHighDateTime) << 32) | ft.dwLowDateTime;

            // Convert to Unix epoch (Jan 1, 1970)
            // Difference is 11644473600 seconds = 116444736000000000 100-ns intervals
            const unix_intervals = intervals -% 116444736000000000;

            // Convert to milliseconds
            return @intCast(unix_intervals / 10000);
        } else {
            var tv: timeval = undefined;
            _ = gettimeofday(&tv, null);

            return @as(i64, tv.tv_sec) * 1000 + @divTrunc(@as(i64, tv.tv_usec), 1000);
        }
    }

    pub fn interface() libws.TimeProvider {
        return .{
            .ptr = undefined,
            .vtable = &.{
                .milliTimestamp = NativeTimeProvider.milliTimestamp,
            },
        };
    }
};

pub const Timezone = struct {
    offset_seconds: i32,

    pub fn getLocal() Timezone {
        var t: isize = @intCast(std.Io.Timestamp.now(z.getState().io.io(), .real).toSeconds());

        const local_ptr = localtime(&t);

        if (local_ptr == null) {
            return .{ .offset_seconds = 0 };
        }

        const local_tm = local_ptr.?.*;

        const utc_ptr = gmtime(&t);

        if (utc_ptr == null) {
            return .{ .offset_seconds = 0 };
        }

        const utc_tm = utc_ptr.?.*;

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
