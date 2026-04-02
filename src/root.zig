// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const builtin = @import("builtin");

const options = @import("options");

const crypto = @import("crypto.zig");
const logger = @import("logger.zig");
const machines = @import("machines.zig");
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
    wsstate: ws.State,
    last_error: ?[:0]const u8 = null,

    pub inline fn deinit(this: *State) void {
        this.mstate.deinit();
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
            .wsstate = undefined,
        };

        _state.?.mstate = .init(_state.?.allocator);
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
    _ = ws;
}
