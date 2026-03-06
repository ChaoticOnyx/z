// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const builtin = @import("builtin");

const logger = @import("logger.zig");
const machines = @import("machines.zig");
const x = @import("x.zig");

comptime {
    if (builtin.cpu.arch != .x86) {
        @compileError("Only the x86 is supported");
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
    alloc: std.heap.DebugAllocator(.{}),
    mstate: machines.State,

    pub inline fn deinit(this: *State) void {
        this.mstate.deinit();

        if (this.alloc.deinit() == .leak) {
            std.log.warn("Memory leaks detected", .{});
        }
    }
};

var _state: ?State = null;

pub inline fn getState() *State {
    if (_state == null) {
        const alloc: std.heap.DebugAllocator(.{}) = .init;

        _state = .{
            .alloc = alloc,
            .mstate = undefined,
        };

        _state.?.mstate = .init(_state.?.alloc.allocator());
    }

    return &_state.?;
}

// Thank you brain-dead MSVC/LLVM developers.
pub const ReturnType = if (builtin.os.tag == .windows) u64 else x.ByondValue;

pub inline fn returnCast(in: x.ByondValue) ReturnType {
    if (comptime builtin.os.tag == .windows) {
        return @bitCast(in);
    } else {
        return in;
    }
}

pub export fn Z_deinit(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) ReturnType {
    _ = argc;
    _ = argv;

    if (_state) |*state| {
        state.deinit();
    }

    _state = null;

    return returnCast(x.True());
}

comptime {
    _ = machines;
}
