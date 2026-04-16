// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const builtin = @import("builtin");

const options = @import("options");

const crypto = @import("crypto.zig");
const logger = @import("logger.zig");
const machines = @import("machines.zig");
const machines_lua = @import("machines_lua.zig");
const os = @import("os.zig");
const tracy = @import("tracy.zig");
const ws = @import("ws.zig");
const x = @import("x.zig");

comptime {
    if (builtin.os.tag != .windows and builtin.os.tag != .linux) {
        @compileError("Only Linux and Windows are supported");
    }

    if (builtin.cpu.arch != .x86) {
        @compileError("Only x86 (32-bit) architecture is supported");
    }
}

pub const panic = std.debug.FullPanic(panicFn);

pub const std_options: std.Options = .{
    .logFn = logger.stdLogFn,
};

inline fn dumpStackTrace(stack_trace: std.builtin.StackTrace, writer: *std.Io.Writer) void {
    const debug_info = std.debug.getSelfDebugInfo() catch |err| {
        writer.print("Unable to dump stack trace: Unable to open debug info: {s}\n", .{@errorName(err)}) catch return;

        return;
    };

    std.debug.writeStackTrace(stack_trace, writer, debug_info, .no_color) catch |err| {
        writer.print("Unable to dump stack trace: {s}\n", .{@errorName(err)}) catch return;

        return;
    };
}

fn panicFn(msg: []const u8, rt: ?usize) noreturn {
    std.log.err("Panic: {s}", .{msg});
    @breakpoint();

    var buffer: [4096]u8 = undefined;

    var writer = logger.getWriter(&buffer) catch {
        std.process.exit(1);
    };
    defer writer.file.close();

    if (@errorReturnTrace()) |t| {
        dumpStackTrace(t.*, &writer.interface);
    }

    std.debug.dumpCurrentStackTraceToWriter(rt orelse @returnAddress(), &writer.interface) catch {};
    writer.interface.flush() catch {};

    std.process.exit(1);
}

const State = struct {
    allocator: std.mem.Allocator,
    mstate: machines.State,
    mlstate: machines_lua.State,
    wsstate: ws.State,
    last_error: ?[:0]const u8 = null,

    pub inline fn deinit(this: *State) void {
        this.mstate.deinit();
        this.mlstate.deinit();
        this.wsstate.deinit();

        if (comptime options.profiler) {
            tracy.deinitGlobal();
        }
    }
};

var _state: ?State = null;
var _dbg_allocator: std.heap.DebugAllocator(.{}) = .init;

pub inline fn getState() *State {
    if (_state == null) {
        os.init() catch |err| {
            std.debug.panic("Failed to initialize the OS API: {t}", .{err});
        };

        _state = .{
            .allocator = if (builtin.mode == .Debug)
                _dbg_allocator.allocator()
            else
                std.heap.smp_allocator,
            .mstate = undefined,
            .mlstate = undefined,
            .wsstate = undefined,
        };

        _state.?.mstate = .init(_state.?.allocator);
        _state.?.mlstate = .init(_state.?.allocator);
        _state.?.wsstate = .init(_state.?.allocator);

        if (comptime options.profiler) {
            tracy.initGlobal(_state.?.allocator) catch |err| {
                std.debug.panic("Failed to initialize Tracy: {t}", .{err});
            };

            tracy.getGlobal().?.setProgramName("Z");

            tracy.getGlobal().?.start(8086) catch |err| {
                std.debug.panic("Failed to start Tracy: {t}", .{err});
            };
        }
    }

    return &_state.?;
}

pub const ReturnType = if (builtin.os.tag == .windows)
    u64
else
    x.ByondValue;

pub inline fn returnCast(in: x.ByondValue) ReturnType {
    if (comptime builtin.os.tag == .windows) {
        return @bitCast(in);
    } else {
        return in;
    }
}

pub export fn Z_get_last_error(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) ReturnType {
    _ = argv;

    if (argc != 0) {
        x.Byond_CRASH("Z_get_last_error does not accept args");

        return returnCast(.{});
    }

    const state = getState();
    var ret: x.ByondValue = .{};

    if (state.last_error) |msg| {
        x.ByondValue_SetStr(&ret, msg);
    }

    return returnCast(ret);
}

pub export fn Z_deinit(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) ReturnType {
    _ = argv;

    if (argc != 0) {
        x.Byond_CRASH("Z_deinit does not accept args");

        return returnCast(.{});
    }

    if (_state) |*state| {
        state.deinit();
        _state = null;
    }

    os.deinit();

    if (comptime builtin.mode == .Debug) {
        if (_dbg_allocator.deinit() == .leak) {
            std.log.warn("Memory leaks detected", .{});
        }

        _dbg_allocator = .init;
    }

    return returnCast(x.True());
}

comptime {
    _ = crypto;
    _ = machines;
    _ = machines_lua;
    _ = ws;
}

extern const __CTOR_LIST__: anyopaque;
extern const __DTOR_LIST__: anyopaque;

pub fn globalCtors() void {
    const ptr: [*]const usize = @ptrCast(@alignCast(&__CTOR_LIST__));

    var nptrs = ptr[0];

    if (nptrs == std.math.maxInt(usize)) {
        nptrs = 0;

        while (ptr[nptrs + 1] != 0) : (nptrs += 1) {}
    }

    var i: usize = nptrs;

    while (i >= 1) : (i -= 1) {
        const ctor: *const fn () callconv(.c) void = @ptrFromInt(ptr[i]);

        ctor();
    }
}

pub fn globalDtors() void {
    const ptr: [*]const usize = @ptrCast(@alignCast(&__DTOR_LIST__));
    var nptrs = ptr[0];

    if (nptrs == std.math.maxInt(usize)) {
        nptrs = 0;

        while (ptr[nptrs + 1] != 0) : (nptrs += 1) {}
    }

    var i: usize = 1;

    while (i <= nptrs) : (i += 1) {
        const dtor: *const fn () callconv(.c) void = @ptrFromInt(ptr[i]);

        dtor();
    }
}

const DLL_PROCESS_ATTACH: std.os.windows.DWORD = 1;
const DLL_PROCESS_DETACH: std.os.windows.DWORD = 0;

pub export fn DllMain(
    hinst_dll: std.os.windows.HINSTANCE,
    fdw_reason: std.os.windows.DWORD,
    lpv_reserved: std.os.windows.LPVOID,
) std.os.windows.BOOL {
    _ = hinst_dll;
    _ = lpv_reserved;

    switch (fdw_reason) {
        DLL_PROCESS_ATTACH => {
            globalCtors();
        },
        DLL_PROCESS_DETACH => {
            globalDtors();
        },
        else => {},
    }

    return std.os.windows.TRUE;
}
