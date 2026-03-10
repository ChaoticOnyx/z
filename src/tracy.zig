// Protocol version 76 (Tracy 0.13.1)

const std = @import("std");
const builtin = @import("builtin");

const os = @import("os.zig");

pub const ProtocolVersion: u32 = 76;
pub const BroadcastVersion: u16 = 3;
pub const DefaultPort: u16 = 8086;
pub const BroadcastPort: u16 = 8087;

pub const HandshakeShibboleth = [8]u8{ 'T', 'r', 'a', 'c', 'y', 'P', 'r', 'f' };
pub const TargetFrameSize: usize = 256 * 1024;
pub const WelcomeMessageProgramNameSize: usize = 64;
pub const WelcomeMessageHostInfoSize: usize = 1024;

/// Convert a pointer to u64 for protocol
pub inline fn ptrToU64(ptr: anytype) u64 {
    const T = @TypeOf(ptr);
    if (@typeInfo(T) == .optional) {
        if (ptr) |p| {
            return @intFromPtr(p);
        }
        return 0;
    }
    return @intFromPtr(ptr);
}

/// Convert u64 from protocol to pointer (returns null if out of range on 32-bit)
pub inline fn u64ToPtr(comptime T: type, val: u64) ?T {
    if (comptime @sizeOf(usize) == 4) {
        if (val > std.math.maxInt(u32)) {
            return null;
        }
    }

    if (val == 0) {
        return null;
    }

    return @ptrFromInt(@as(usize, @truncate(val)));
}

pub const HandshakeStatus = enum(u8) {
    Pending = 0,
    Welcome = 1,
    ProtocolMismatch = 2,
    NotAvailable = 3,
    Dropped = 4,
};

pub const CpuArchitecture = enum(u8) {
    Unknown = 0,
    X86 = 1,
    X64 = 2,
    Arm32 = 3,
    Arm64 = 4,
};

pub const ServerQuery = enum(u8) {
    Terminate = 0,
    String = 1,
    ThreadString = 2,
    SourceLocation = 3,
    PlotName = 4,
    FrameName = 5,
    Parameter = 6,
    FiberName = 7,
    ExternalName = 8,
    Disconnect = 9,
    CallstackFrame = 10,
    Symbol = 11,
    SymbolCode = 12,
    SourceCode = 13,
    DataTransfer = 14,
    DataTransferPart = 15,
};

pub const QueueType = enum(u8) {
    ZoneText = 0,
    ZoneName = 1,
    Message = 2,
    MessageColor = 3,
    MessageCallstack = 4,
    MessageColorCallstack = 5,
    MessageAppInfo = 6,
    ZoneBeginAllocSrcLoc = 7,
    ZoneBeginAllocSrcLocCallstack = 8,
    CallstackSerial = 9,
    Callstack = 10,
    CallstackAlloc = 11,
    CallstackSample = 12,
    CallstackSampleContextSwitch = 13,
    FrameImage = 14,
    ZoneBegin = 15,
    ZoneBeginCallstack = 16,
    ZoneEnd = 17,
    LockWait = 18,
    LockObtain = 19,
    LockRelease = 20,
    LockSharedWait = 21,
    LockSharedObtain = 22,
    LockSharedRelease = 23,
    LockName = 24,
    MemAlloc = 25,
    MemAllocNamed = 26,
    MemFree = 27,
    MemFreeNamed = 28,
    MemAllocCallstack = 29,
    MemAllocCallstackNamed = 30,
    MemFreeCallstack = 31,
    MemFreeCallstackNamed = 32,
    MemDiscard = 33,
    MemDiscardCallstack = 34,
    GpuZoneBegin = 35,
    GpuZoneBeginCallstack = 36,
    GpuZoneBeginAllocSrcLoc = 37,
    GpuZoneBeginAllocSrcLocCallstack = 38,
    GpuZoneEnd = 39,
    GpuZoneBeginSerial = 40,
    GpuZoneBeginCallstackSerial = 41,
    GpuZoneBeginAllocSrcLocSerial = 42,
    GpuZoneBeginAllocSrcLocCallstackSerial = 43,
    GpuZoneEndSerial = 44,
    PlotDataInt = 45,
    PlotDataFloat = 46,
    PlotDataDouble = 47,
    ContextSwitch = 48,
    ThreadWakeup = 49,
    GpuTime = 50,
    GpuContextName = 51,
    GpuAnnotationName = 52,
    CallstackFrameSize = 53,
    SymbolInformation = 54,
    ExternalNameMetadata = 55,
    SymbolCodeMetadata = 56,
    SourceCodeMetadata = 57,
    FiberEnter = 58,
    FiberLeave = 59,
    Terminate = 60,
    KeepAlive = 61,
    ThreadContext = 62,
    GpuCalibration = 63,
    GpuTimeSync = 64,
    Crash = 65,
    CrashReport = 66,
    ZoneValidation = 67,
    ZoneColor = 68,
    ZoneValue = 69,
    FrameMarkMsg = 70,
    FrameMarkMsgStart = 71,
    FrameMarkMsgEnd = 72,
    FrameVsync = 73,
    SourceLocation = 74,
    LockAnnounce = 75,
    LockTerminate = 76,
    LockMark = 77,
    MessageLiteral = 78,
    MessageLiteralColor = 79,
    MessageLiteralCallstack = 80,
    MessageLiteralColorCallstack = 81,
    GpuNewContext = 82,
    CallstackFrame = 83,
    SysTimeReport = 84,
    SysPowerReport = 85,
    TidToPid = 86,
    HwSampleCpuCycle = 87,
    HwSampleInstructionRetired = 88,
    HwSampleCacheReference = 89,
    HwSampleCacheMiss = 90,
    HwSampleBranchRetired = 91,
    HwSampleBranchMiss = 92,
    PlotConfig = 93,
    ParamSetup = 94,
    AckServerQueryNoop = 95,
    AckSourceCodeNotAvailable = 96,
    AckSymbolCodeNotAvailable = 97,
    CpuTopology = 98,
    SingleStringData = 99,
    SecondStringData = 100,
    MemNamePayload = 101,
    ThreadGroupHint = 102,
    GpuZoneAnnotation = 103,
    StringData = 104,
    ThreadName = 105,
    PlotName = 106,
    SourceLocationPayload = 107,
    CallstackPayload = 108,
    CallstackAllocPayload = 109,
    FrameName = 110,
    FrameImageData = 111,
    ExternalName = 112,
    ExternalThreadName = 113,
    SymbolCode = 114,
    SourceCode = 115,
    FiberName = 116,
};

pub const WelcomeMessage = extern struct {
    timerMul: f64 align(1),
    initBegin: i64 align(1),
    initEnd: i64 align(1),
    resolution: u64 align(1),
    epoch: u64 align(1),
    exectime: u64 align(1),
    pid: u64 align(1),
    samplingPeriod: i64 align(1),
    flags: u8 align(1),
    cpuArch: u8 align(1),
    cpuManufacturer: [12]u8 align(1),
    cpuId: u32 align(1),
    programName: [WelcomeMessageProgramNameSize]u8 align(1),
    hostInfo: [WelcomeMessageHostInfoSize]u8 align(1),
};

pub const ServerQueryPacket = extern struct {
    query_type: u8 align(1),
    ptr: u64 align(1),
    extra: u32 align(1),
};

pub const QueueHeader = extern struct {
    queue_type: u8 align(1),
};

// ZoneBeginLean - only time, used with allocated source location
pub const QueueZoneBeginLean = extern struct {
    time: i64 align(1),
};

// Full ZoneBegin with static srcloc pointer
pub const QueueZoneBegin = extern struct {
    time: i64 align(1),
    srcloc: u64 align(1),
};

pub const QueueZoneEnd = extern struct {
    time: i64 align(1),
};

pub const QueueThreadContext = extern struct {
    thread: u32 align(1),
};

pub const QueueSourceLocation = extern struct {
    name: u64 align(1),
    function: u64 align(1),
    file: u64 align(1),
    line: u32 align(1),
    b: u8 align(1),
    g: u8 align(1),
    r: u8 align(1),
};

pub const QueueStringTransfer = extern struct {
    ptr: u64 align(1),
};

pub const QueueZoneText = extern struct {
    text: u64 align(1),
    size: u16 align(1),
};

pub const QueueZoneColor = extern struct {
    b: u8 align(1),
    g: u8 align(1),
    r: u8 align(1),
};

pub const QueueZoneValue = extern struct {
    value: u64 align(1),
};

pub const QueueFrameMark = extern struct {
    time: i64 align(1),
    name: u64 align(1),
};

// Lean message - just time, used with inline string data
pub const QueueMessage = extern struct {
    time: i64 align(1),
};

// Fat message - includes text pointer and size (for deferred strings)
pub const QueueMessageFat = extern struct {
    time: i64 align(1),
    text: u64 align(1),
    size: u16 align(1),
};

// Literal message - text is a pointer to static string
pub const QueueMessageLiteral = extern struct {
    time: i64 align(1),
    text: u64 align(1),
};

pub const QueueSysTime = extern struct {
    time: i64 align(1),
    sysTime: f32 align(1),
};

comptime {
    std.debug.assert(@sizeOf(ServerQueryPacket) == 13);
}

pub const Lz4 = struct {
    const HASH_LOG = 12;
    const HASH_SIZE = 1 << HASH_LOG;
    const MIN_MATCH = 4;
    const LAST_LITERALS = 5;
    const MF_LIMIT = 12;

    pub fn compressBound(inputSize: usize) usize {
        return inputSize + (inputSize / 255) + 16;
    }

    pub fn compress(src: []const u8, dst: []u8) usize {
        if (src.len == 0) {
            return 0;
        }

        if (src.len < MF_LIMIT) {
            return compressLiterals(src, dst);
        }

        var hashTable: [HASH_SIZE]u32 = [_]u32{0} ** HASH_SIZE;
        var srcPos: usize = 0;
        var dstPos: usize = 0;
        var anchor: usize = 0;

        while (srcPos + MF_LIMIT <= src.len) {
            const hash = hashSequence(src[srcPos..]);
            const matchPos = hashTable[hash];
            hashTable[hash] = @intCast(srcPos);

            if (matchPos > 0 and srcPos - matchPos < 65535 and
                matchPos + 4 <= src.len and srcPos + 4 <= src.len and
                std.mem.eql(u8, src[matchPos..][0..4], src[srcPos..][0..4]))
            {
                const literalLen = srcPos - anchor;

                var matchLen: usize = 4;
                while (srcPos + matchLen < src.len and
                    matchPos + matchLen < srcPos and
                    src[srcPos + matchLen] == src[matchPos + matchLen])
                {
                    matchLen += 1;
                }

                const litToken: u8 = @intCast(@min(literalLen, 15));
                const matchToken: u8 = @intCast(@min(matchLen - 4, 15));
                const token: u8 = (litToken << 4) | matchToken;
                dst[dstPos] = token;
                dstPos += 1;

                if (literalLen >= 15) {
                    var remaining = literalLen - 15;
                    while (remaining >= 255) {
                        dst[dstPos] = 255;
                        dstPos += 1;
                        remaining -= 255;
                    }

                    dst[dstPos] = @intCast(remaining);
                    dstPos += 1;
                }

                @memcpy(dst[dstPos..][0..literalLen], src[anchor..][0..literalLen]);
                dstPos += literalLen;

                const offset: u16 = @intCast(srcPos - matchPos);
                dst[dstPos] = @intCast(offset & 0xFF);
                dst[dstPos + 1] = @intCast(offset >> 8);
                dstPos += 2;

                if (matchLen - 4 >= 15) {
                    var remaining = matchLen - 4 - 15;
                    while (remaining >= 255) {
                        dst[dstPos] = 255;
                        dstPos += 1;
                        remaining -= 255;
                    }

                    dst[dstPos] = @intCast(remaining);
                    dstPos += 1;
                }

                srcPos += matchLen;
                anchor = srcPos;
            } else {
                srcPos += 1;
            }
        }

        return dstPos + compressLiterals(src[anchor..], dst[dstPos..]);
    }

    fn compressLiterals(src: []const u8, dst: []u8) usize {
        const literalLen = src.len;
        var dstPos: usize = 0;

        const litToken: u8 = @intCast(@min(literalLen, 15));
        const token: u8 = litToken << 4;
        dst[dstPos] = token;
        dstPos += 1;

        if (literalLen >= 15) {
            var remaining = literalLen - 15;
            while (remaining >= 255) {
                dst[dstPos] = 255;
                dstPos += 1;
                remaining -= 255;
            }

            dst[dstPos] = @intCast(remaining);
            dstPos += 1;
        }

        @memcpy(dst[dstPos..][0..literalLen], src);
        dstPos += literalLen;

        return dstPos;
    }

    fn hashSequence(data: []const u8) usize {
        if (data.len < 4) {
            return 0;
        }

        const v = std.mem.readInt(u32, data[0..4], .little);
        return @intCast((v *% 2654435761) >> (32 - HASH_LOG));
    }
};

const c = @cImport({
    if (os.is_windows) {
        @cDefine("WIN32_LEAN_AND_MEAN", "1");
        @cInclude("windows.h");
    } else {
        @cInclude("time.h");
        @cInclude("unistd.h");
        @cInclude("sys/types.h");
    }
});

pub fn getTime() i64 {
    if (comptime os.is_windows) {
        var counter: c.LARGE_INTEGER = undefined;
        _ = c.QueryPerformanceCounter(&counter);
        return counter.QuadPart;
    } else if (comptime os.is_linux) {
        var ts: c.timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC_RAW, &ts);
        return @as(i64, ts.tv_sec) * 1_000_000_000 + ts.tv_nsec;
    } else {
        return std.time.nanoTimestamp();
    }
}

pub fn getTimerMul() f64 {
    if (comptime os.is_windows) {
        var freq: c.LARGE_INTEGER = undefined;
        _ = c.QueryPerformanceFrequency(&freq);
        return 1_000_000_000.0 / @as(f64, @floatFromInt(freq.QuadPart));
    } else {
        return 1.0;
    }
}

pub fn getResolution() u64 {
    if (comptime os.is_windows) {
        var freq: c.LARGE_INTEGER = undefined;
        _ = c.QueryPerformanceFrequency(&freq);
        return @intCast(freq.QuadPart);
    } else {
        return 1_000_000_000;
    }
}

pub fn getEpoch() u64 {
    return @intCast(@max(0, std.time.timestamp()));
}

pub fn getPid() u64 {
    if (comptime os.is_windows) {
        return c.GetCurrentProcessId();
    } else {
        return @intCast(c.getpid());
    }
}

pub fn getThreadId() u32 {
    if (comptime os.is_windows) {
        return c.GetCurrentThreadId();
    } else if (comptime os.is_linux) {
        return @intCast(std.os.linux.gettid());
    } else {
        return @intCast(@intFromPtr(std.Thread.getCurrentId()));
    }
}

pub fn getCpuArch() CpuArchitecture {
    return switch (builtin.cpu.arch) {
        .x86 => .X86,
        .x86_64 => .X64,
        .arm, .armeb => .Arm32,
        .aarch64, .aarch64_be => .Arm64,
        else => .Unknown,
    };
}

fn getCpuManufacturer() [12]u8 {
    var result: [12]u8 = [_]u8{0} ** 12;

    if (comptime builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .x86) {
        var eax: u32 = undefined;
        var ebx: u32 = undefined;
        var ecx: u32 = undefined;
        var edx: u32 = undefined;

        asm volatile ("cpuid"
            : [eax] "={eax}" (eax),
              [ebx] "={ebx}" (ebx),
              [ecx] "={ecx}" (ecx),
              [edx] "={edx}" (edx),
        );

        @memcpy(result[0..4], @as(*const [4]u8, @ptrCast(&ebx)));
        @memcpy(result[4..8], @as(*const [4]u8, @ptrCast(&edx)));
        @memcpy(result[8..12], @as(*const [4]u8, @ptrCast(&ecx)));
    }

    return result;
}

pub const SourceLocationData = struct {
    name: ?[:0]const u8,
    function: [:0]const u8,
    file: [:0]const u8,
    line: u32,
    color: u32,
};

pub const Profiler = struct {
    listener: ?os.TcpListener = null,
    client: ?os.TcpStream = null,
    connected: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    timerMul: f64 = 1.0,
    initBegin: i64 = 0,
    initEnd: i64 = 0,
    resolution: u64 = 1,

    currentThread: u32 = 0,

    sendBuffer: []u8,
    sendPos: usize = 0,
    compressBuffer: []u8,

    pendingQueries: std.ArrayList(ServerQueryPacket) = .empty,
    queriesMutex: std.Thread.Mutex = .{},

    allocator: std.mem.Allocator,

    workerThread: ?std.Thread = null,
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    programName: [WelcomeMessageProgramNameSize]u8 = [_]u8{0} ** WelcomeMessageProgramNameSize,

    lastKeepAlive: i64 = 0,

    serialLock: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator) !*Profiler {
        try os.init();

        const this = try allocator.create(Profiler);
        errdefer allocator.destroy(this);

        const sendBuffer = try allocator.alloc(u8, TargetFrameSize * 2);
        errdefer allocator.free(sendBuffer);

        const compressBuffer = try allocator.alloc(u8, Lz4.compressBound(TargetFrameSize));
        errdefer allocator.free(compressBuffer);

        this.* = .{
            .allocator = allocator,
            .sendBuffer = sendBuffer,
            .compressBuffer = compressBuffer,
        };

        this.initBegin = getTime();
        this.timerMul = getTimerMul();
        this.resolution = getResolution();
        this.currentThread = getThreadId();

        return this;
    }

    pub fn deinit(this: *Profiler) void {
        this.stop();

        this.pendingQueries.deinit(this.allocator);
        this.allocator.free(this.sendBuffer);
        this.allocator.free(this.compressBuffer);
        this.allocator.destroy(this);

        os.deinit();
    }

    pub fn setProgramName(this: *Profiler, name: []const u8) void {
        const len = @min(name.len, WelcomeMessageProgramNameSize - 1);
        @memcpy(this.programName[0..len], name[0..len]);
        this.programName[len] = 0;
    }

    pub fn start(this: *Profiler, port: u16) !void {
        const addr = os.Address.any(port);
        this.listener = try os.TcpListener.bind(addr, 1);
        this.initEnd = getTime();

        this.workerThread = try std.Thread.spawn(.{}, workerLoop, .{this});
    }

    pub fn stop(this: *Profiler) void {
        this.shutdown.store(true, .release);

        if (this.workerThread) |t| {
            t.join();
            this.workerThread = null;
        }

        this.disconnect();

        if (this.listener) |*l| {
            l.deinit();
            this.listener = null;
        }
    }

    pub fn isConnected(this: *Profiler) bool {
        return this.connected.load(.acquire);
    }

    fn workerLoop(this: *Profiler) void {
        while (!this.shutdown.load(.acquire)) {
            if (!this.connected.load(.acquire)) {
                this.tryAcceptConnection();
            } else {
                this.tick() catch |err| {
                    std.debug.print("Tracy error: {}\n", .{err});
                    this.disconnect();
                };
            }

            std.Thread.sleep(1_000_000);
        }
    }

    fn tryAcceptConnection(this: *Profiler) void {
        if (this.listener) |*listener| {
            const stream = listener.accept(this.allocator) catch |err| {
                if (err != error.WouldBlock) {
                    std.debug.print("Accept error: {}\n", .{err});
                }

                return;
            };

            const tcpStream: *os.TcpStream = @ptrCast(@alignCast(stream.ptr));
            this.client = tcpStream.*;

            this.handleHandshake() catch |err| {
                std.debug.print("Handshake error: {}\n", .{err});
                this.disconnect();
                return;
            };

            std.debug.print("Tracy: Client connected\n", .{});
        }
    }

    fn handleHandshake(this: *Profiler) !void {
        const client = &(this.client orelse return error.NotConnected);

        var shibboleth: [8]u8 = undefined;
        try this.readExact(client, &shibboleth);

        if (!std.mem.eql(u8, &shibboleth, &HandshakeShibboleth)) {
            return error.InvalidShibboleth;
        }

        var versionBytes: [4]u8 = undefined;
        try this.readExact(client, &versionBytes);
        const version = std.mem.readInt(u32, &versionBytes, .little);

        if (version != ProtocolVersion) {
            const status = [_]u8{@intFromEnum(HandshakeStatus.ProtocolMismatch)};
            _ = try this.writeAll(client, &status);
            return error.ProtocolMismatch;
        }

        const status = [_]u8{@intFromEnum(HandshakeStatus.Welcome)};
        _ = try this.writeAll(client, &status);

        try this.sendWelcomeMessage();

        this.connected.store(true, .release);
        this.lastKeepAlive = getTime();
    }

    fn sendWelcomeMessage(this: *Profiler) !void {
        const client = &(this.client orelse return error.NotConnected);

        var welcome: WelcomeMessage = std.mem.zeroes(WelcomeMessage);

        welcome.timerMul = this.timerMul;
        welcome.initBegin = this.initBegin;
        welcome.initEnd = this.initEnd;
        welcome.resolution = this.resolution;
        welcome.epoch = getEpoch();
        welcome.exectime = 0;
        welcome.pid = getPid();
        welcome.samplingPeriod = 0;
        welcome.flags = 0;
        welcome.cpuArch = @intFromEnum(getCpuArch());
        welcome.cpuManufacturer = getCpuManufacturer();
        welcome.cpuId = 0;
        welcome.programName = this.programName;

        const bytes = std.mem.asBytes(&welcome);
        _ = try this.writeAll(client, bytes);
    }

    fn tick(this: *Profiler) !void {
        try this.handleServerQueries();

        const now = getTime();
        const elapsed = now - this.lastKeepAlive;
        const keepAliveInterval: i64 = 1_000_000_000;

        if (elapsed > keepAliveInterval) {
            try this.sendKeepAlive();
            this.lastKeepAlive = now;
        }

        this.serialLock.lock();
        defer this.serialLock.unlock();

        if (this.sendPos > 0) {
            try this.commitData();
        }
    }

    fn handleServerQueries(this: *Profiler) !void {
        var client = &(this.client orelse return error.NotConnected);

        var buf: [@sizeOf(ServerQueryPacket)]u8 = undefined;
        const bytesRead = client.read(&buf) catch |err| {
            if (err == error.WouldBlock) return;

            return err;
        };

        if (bytesRead == 0) {
            return error.ConnectionClosed;
        }

        if (bytesRead < @sizeOf(ServerQueryPacket)) {
            return;
        }

        const packet: *ServerQueryPacket = @ptrCast(&buf);
        const queryType: ServerQuery = @enumFromInt(packet.query_type);

        switch (queryType) {
            .Terminate => return error.TerminateRequested,
            .Disconnect => return error.DisconnectRequested,
            .String => try this.handleStringQuery(packet.ptr),
            .SourceLocation => try this.handleSourceLocationQuery(packet.ptr),
            .ThreadString => try this.handleThreadStringQuery(packet.ptr),
            else => {
                try this.sendAck();
            },
        }
    }

    fn handleStringQuery(this: *Profiler, ptr: u64) !void {
        if (ptr == 0) {
            try this.sendAck();

            return;
        }

        const strPtr = u64ToPtr([*:0]const u8, ptr);
        if (strPtr) |p| {
            const str = std.mem.span(p);
            try this.sendStringData(ptr, str);
        } else {
            try this.sendAck();
        }
    }

    fn handleSourceLocationQuery(this: *Profiler, ptr: u64) !void {
        _ = ptr;
        try this.sendAck();
    }

    fn handleThreadStringQuery(this: *Profiler, ptr: u64) !void {
        _ = ptr;
        try this.sendAck();
    }

    fn sendAck(this: *Profiler) !void {
        this.serialLock.lock();
        defer this.serialLock.unlock();

        const hdr = [_]u8{@intFromEnum(QueueType.AckServerQueryNoop)};
        try this.appendData(&hdr);
    }

    fn sendKeepAlive(this: *Profiler) !void {
        this.serialLock.lock();
        defer this.serialLock.unlock();

        const hdr = [_]u8{@intFromEnum(QueueType.KeepAlive)};
        try this.appendData(&hdr);
        try this.commitData();
    }

    fn sendStringData(this: *Profiler, ptr: u64, str: []const u8) !void {
        this.serialLock.lock();
        defer this.serialLock.unlock();

        // StringData format: type (1) + ptr (8) + length (2) + data
        const hdr = [_]u8{@intFromEnum(QueueType.StringData)};
        try this.appendData(&hdr);

        var ptrBytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &ptrBytes, ptr, .little);
        try this.appendData(&ptrBytes);

        const len: u16 = @intCast(@min(str.len, std.math.maxInt(u16)));
        var lenBytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &lenBytes, len, .little);
        try this.appendData(&lenBytes);
        try this.appendData(str[0..len]);

        try this.commitData();
    }

    fn appendData(this: *Profiler, data: []const u8) !void {
        if (this.sendPos + data.len > TargetFrameSize) {
            try this.commitData();
        }

        @memcpy(this.sendBuffer[this.sendPos..][0..data.len], data);
        this.sendPos += data.len;
    }

    fn commitData(this: *Profiler) !void {
        if (this.sendPos == 0) {
            return;
        }

        const client = &(this.client orelse return error.NotConnected);

        const compressedSize = Lz4.compress(
            this.sendBuffer[0..this.sendPos],
            this.compressBuffer,
        );

        var sizeBytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &sizeBytes, @intCast(compressedSize), .little);
        _ = try this.writeAll(client, &sizeBytes);

        _ = try this.writeAll(client, this.compressBuffer[0..compressedSize]);

        this.sendPos = 0;
    }

    fn disconnect(this: *Profiler) void {
        if (this.client) |*c_| {
            c_.close();
            this.client = null;
        }

        this.connected.store(false, .release);
        this.sendPos = 0;
    }

    fn readExact(this: *Profiler, client: *os.TcpStream, buf: []u8) !void {
        _ = this;
        var totalRead: usize = 0;

        while (totalRead < buf.len) {
            const n = client.read(buf[totalRead..]) catch |err| {
                if (err == error.WouldBlock) {
                    std.Thread.sleep(1_000_000);

                    continue;
                }

                return err;
            };

            if (n == 0) {
                return error.ConnectionClosed;
            }

            totalRead += n;
        }
    }

    fn writeAll(this: *Profiler, client: *os.TcpStream, data: []const u8) !usize {
        _ = this;
        var totalWritten: usize = 0;

        while (totalWritten < data.len) {
            const n = client.write(data[totalWritten..]) catch |err| {
                if (err == error.WouldBlock) {
                    std.Thread.sleep(1_000_000);

                    continue;
                }

                return err;
            };

            totalWritten += n;
        }

        return totalWritten;
    }

    pub fn zoneBegin(this: *Profiler, src: std.builtin.SourceLocation) ZoneCtx {
        return this.zoneBeginInternal(src, null, 0);
    }

    pub fn zoneBeginN(this: *Profiler, src: std.builtin.SourceLocation, name: ?[:0]const u8) ZoneCtx {
        return this.zoneBeginInternal(src, name, 0);
    }

    pub fn zoneBeginC(this: *Profiler, src: std.builtin.SourceLocation, color: u32) ZoneCtx {
        return this.zoneBeginInternal(src, null, color);
    }

    pub fn zoneBeginNC(this: *Profiler, src: std.builtin.SourceLocation, name: ?[:0]const u8, color: u32) ZoneCtx {
        return this.zoneBeginInternal(src, name, color);
    }

    fn zoneBeginInternal(
        this: *Profiler,
        src: std.builtin.SourceLocation,
        name: ?[:0]const u8,
        color: u32,
    ) ZoneCtx {
        if (!this.connected.load(.acquire)) {
            return ZoneCtx{ .profiler = this, .active = false };
        }

        this.serialLock.lock();
        defer this.serialLock.unlock();

        const time = getTime();
        const thread = getThreadId();

        // Send thread context if changed
        if (thread != this.currentThread) {
            this.currentThread = thread;
            this.sendThreadContext(thread) catch return ZoneCtx{ .profiler = this, .active = false };
        }

        // Build source location payload
        // Format: size(2) + color(4) + line(4) + function\0 + file\0 + [name]
        var payload: [512]u8 = undefined;
        var pos: usize = 2; // Skip size field

        // Color (4 bytes)
        std.mem.writeInt(u32, payload[pos..][0..4], color, .little);
        pos += 4;

        // Line (4 bytes)
        std.mem.writeInt(u32, payload[pos..][0..4], src.line, .little);
        pos += 4;

        // Function name + null terminator
        @memcpy(payload[pos..][0..src.fn_name.len], src.fn_name);
        pos += src.fn_name.len;
        payload[pos] = 0;
        pos += 1;

        // File name + null terminator
        @memcpy(payload[pos..][0..src.file.len], src.file);
        pos += src.file.len;
        payload[pos] = 0;
        pos += 1;

        // Optional name (no null terminator)
        if (name) |n| {
            @memcpy(payload[pos..][0..n.len], n);
            pos += n.len;
        }

        // Write size (excluding the size field itself!)
        const payloadSize: u16 = @intCast(pos - 2);
        std.mem.writeInt(u16, payload[0..2], payloadSize, .little);

        // Send ZoneBeginAllocSrcLoc first
        this.sendZoneBeginAllocSrcLoc(time) catch return ZoneCtx{ .profiler = this, .active = false };

        // Send source location payload immediately after
        this.sendSourceLocationPayload(payload[0..pos]) catch return ZoneCtx{ .profiler = this, .active = false };

        return ZoneCtx{ .profiler = this, .active = true };
    }

    fn sendThreadContext(this: *Profiler, thread: u32) !void {
        const hdr = [_]u8{@intFromEnum(QueueType.ThreadContext)};
        try this.appendData(&hdr);

        var threadBytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &threadBytes, thread, .little);
        try this.appendData(&threadBytes);
    }

    fn sendZoneBeginAllocSrcLoc(this: *Profiler, time: i64) !void {
        const hdr = [_]u8{@intFromEnum(QueueType.ZoneBeginAllocSrcLoc)};
        try this.appendData(&hdr);

        var timeBytes: [8]u8 = undefined;
        std.mem.writeInt(i64, &timeBytes, time, .little);
        try this.appendData(&timeBytes);
    }

    fn sendSourceLocationPayload(this: *Profiler, payload: []const u8) !void {
        // SourceLocationPayload format: type (1) + payload data (already includes size prefix)
        const hdr = [_]u8{@intFromEnum(QueueType.SourceLocationPayload)};
        try this.appendData(&hdr);
        try this.appendData(payload);
    }

    pub fn zoneEnd(this: *Profiler) void {
        if (!this.connected.load(.acquire)) {
            return;
        }

        this.serialLock.lock();
        defer this.serialLock.unlock();

        const time = getTime();

        const hdr = [_]u8{@intFromEnum(QueueType.ZoneEnd)};
        this.appendData(&hdr) catch {
            return;
        };

        var timeBytes: [8]u8 = undefined;
        std.mem.writeInt(i64, &timeBytes, time, .little);

        this.appendData(&timeBytes) catch {
            return;
        };
    }

    pub fn frameMark(this: *Profiler) void {
        this.frameMarkNamed(null);
    }

    pub fn frameMarkNamed(this: *Profiler, name: ?[:0]const u8) void {
        if (!this.connected.load(.acquire)) {
            return;
        }

        this.serialLock.lock();
        defer this.serialLock.unlock();

        const time = getTime();

        const hdr = [_]u8{@intFromEnum(QueueType.FrameMarkMsg)};
        this.appendData(&hdr) catch {
            return;
        };

        var timeBytes: [8]u8 = undefined;
        std.mem.writeInt(i64, &timeBytes, time, .little);
        this.appendData(&timeBytes) catch {
            return;
        };

        var nameBytes: [8]u8 = undefined;
        const namePtr: u64 = if (name) |n| ptrToU64(n.ptr) else 0;
        std.mem.writeInt(u64, &nameBytes, namePtr, .little);
        this.appendData(&nameBytes) catch {
            return;
        };
    }

    /// Send a message with inline string data
    pub fn message(this: *Profiler, text: []const u8) void {
        if (!this.connected.load(.acquire)) {
            return;
        }

        this.serialLock.lock();
        defer this.serialLock.unlock();

        const time = getTime();
        const thread = getThreadId();

        // Send thread context if changed
        if (thread != this.currentThread) {
            this.currentThread = thread;
            this.sendThreadContext(thread) catch {
                return;
            };
        }

        // Message format: type (1) + time (8)
        const hdr = [_]u8{@intFromEnum(QueueType.Message)};
        this.appendData(&hdr) catch return;

        var timeBytes: [8]u8 = undefined;
        std.mem.writeInt(i64, &timeBytes, time, .little);
        this.appendData(&timeBytes) catch {
            return;
        };

        // Followed by SingleStringData
        this.sendSingleString(text) catch {
            return;
        };
    }

    /// Send a literal message (pointer-based, must be static string)
    pub fn messageLiteral(this: *Profiler, text: [:0]const u8) void {
        if (!this.connected.load(.acquire)) {
            return;
        }

        this.serialLock.lock();
        defer this.serialLock.unlock();

        const time = getTime();
        const thread = getThreadId();

        // Send thread context if changed
        if (thread != this.currentThread) {
            this.currentThread = thread;
            this.sendThreadContext(thread) catch {
                return;
            };
        }

        // MessageLiteral format: type (1) + time (8) + text ptr (8)
        const hdr = [_]u8{@intFromEnum(QueueType.MessageLiteral)};
        this.appendData(&hdr) catch {
            return;
        };

        var timeBytes: [8]u8 = undefined;
        std.mem.writeInt(i64, &timeBytes, time, .little);
        this.appendData(&timeBytes) catch {
            return;
        };

        var textBytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &textBytes, ptrToU64(text.ptr), .little);
        this.appendData(&textBytes) catch {
            return;
        };
    }

    fn sendSingleString(this: *Profiler, text: []const u8) !void {
        // SingleStringData format: type (1) + length (2) + data
        const hdr = [_]u8{@intFromEnum(QueueType.SingleStringData)};
        try this.appendData(&hdr);

        const len: u16 = @intCast(@min(text.len, std.math.maxInt(u16)));
        var lenBytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &lenBytes, len, .little);
        try this.appendData(&lenBytes);
        try this.appendData(text[0..len]);
    }
};

pub const ZoneCtx = struct {
    profiler: *Profiler,
    active: bool,

    pub fn end(this: ZoneCtx) void {
        if (this.active) {
            this.profiler.zoneEnd();
        }
    }

    pub fn setText(this: ZoneCtx, text: []const u8) void {
        if (!this.active) return;
        this.profiler.zoneText(text);
    }

    pub fn setColor(this: ZoneCtx, color: u32) void {
        if (!this.active) return;
        this.profiler.zoneColor(color);
    }

    pub fn setValue(this: ZoneCtx, value: u64) void {
        if (!this.active) return;
        this.profiler.zoneValue(value);
    }
};

pub fn zoneText(this: *Profiler, text: []const u8) void {
    if (!this.connected.load(.acquire)) {
        return;
    }

    this.serialLock.lock();
    defer this.serialLock.unlock();

    const hdr = [_]u8{@intFromEnum(QueueType.ZoneText)};
    this.appendData(&hdr) catch {
        return;
    };

    this.sendSingleString(text) catch {
        return;
    };
}

pub fn zoneColor(this: *Profiler, color: u32) void {
    if (!this.connected.load(.acquire)) {
        return;
    }

    this.serialLock.lock();
    defer this.serialLock.unlock();

    const hdr = [_]u8{@intFromEnum(QueueType.ZoneColor)};
    this.appendData(&hdr) catch {
        return;
    };

    // BGR format
    const colorBytes = [_]u8{
        @truncate(color), // B
        @truncate(color >> 8), // G
        @truncate(color >> 16), // R
    };
    this.appendData(&colorBytes) catch {
        return;
    };
}

pub fn zoneValue(this: *Profiler, value: u64) void {
    if (!this.connected.load(.acquire)) {
        return;
    }

    this.serialLock.lock();
    defer this.serialLock.unlock();

    const hdr = [_]u8{@intFromEnum(QueueType.ZoneValue)};
    this.appendData(&hdr) catch {
        return;
    };

    var valueBytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &valueBytes, value, .little);
    this.appendData(&valueBytes) catch {
        return;
    };
}

var globalProfiler: ?*Profiler = null;

pub fn initGlobal(allocator: std.mem.Allocator) !void {
    globalProfiler = try Profiler.init(allocator);
}

pub fn deinitGlobal() void {
    if (globalProfiler) |p| {
        p.deinit();
        globalProfiler = null;
    }
}

pub fn getGlobal() ?*Profiler {
    return globalProfiler;
}

pub inline fn zone(src: std.builtin.SourceLocation) ZoneCtx {
    if (globalProfiler) |p| {
        return p.zoneBegin(src);
    }

    return ZoneCtx{ .profiler = undefined, .active = false };
}

pub inline fn zoneN(src: std.builtin.SourceLocation, name: [:0]const u8) ZoneCtx {
    if (globalProfiler) |p| {
        return p.zoneBeginN(src, name);
    }

    return ZoneCtx{ .profiler = undefined, .active = false };
}

pub inline fn zoneC(src: std.builtin.SourceLocation, color: u32) ZoneCtx {
    if (globalProfiler) |p| {
        return p.zoneBeginC(src, color);
    }

    return ZoneCtx{ .profiler = undefined, .active = false };
}

pub inline fn zoneNC(src: std.builtin.SourceLocation, name: [:0]const u8, color: u32) ZoneCtx {
    if (globalProfiler) |p| {
        return p.zoneBeginNC(src, name, color);
    }

    return ZoneCtx{ .profiler = undefined, .active = false };
}

pub inline fn frameMark() void {
    if (globalProfiler) |p| {
        p.frameMark();
    }
}

pub inline fn frameMarkNamed(name: [:0]const u8) void {
    if (globalProfiler) |p| {
        p.frameMarkNamed(name);
    }
}

pub inline fn message(text: []const u8) void {
    if (globalProfiler) |p| {
        p.message(text);
    }
}

pub inline fn messageLiteral(text: [:0]const u8) void {
    if (globalProfiler) |p| {
        p.messageLiteral(text);
    }
}
