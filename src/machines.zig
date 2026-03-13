// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");

const ondatra = @import("ondatra");
const sdk = @import("mcu_sdk");

const flate = @import("compress/flate.zig");
const helpers = @import("helpers.zig");
const os = @import("os.zig");
const tracy = @import("tracy.zig");
const ws = @import("ws.zig");
const x = @import("x.zig");
const z = @import("root.zig");

const MAX_FILE_SIZE = 1e9;
const DEFAULT_FREQUENCY: u64 = 1_000_000;
const MAX_DEBT_FACTOR = 2;

inline fn getState() *State {
    return &z.getState().mstate;
}

inline fn sizeOfField(comptime Type: type, comptime field_name: []const u8) usize {
    return @sizeOf(@FieldType(Type, field_name));
}

inline fn dmaFill(pattern: []const u8, dst: []u8) void {
    var remaining: u32 = dst.len;
    var dst_pos: u32 = 0;

    while (remaining > 0) {
        const chunk_len: u32 = @min(pattern.len, remaining);
        @memmove(dst[dst_pos..][0..chunk_len], pattern[0..chunk_len]);

        dst_pos += chunk_len;
        remaining -= chunk_len;
    }
}

inline fn genericMmioRead(this: anytype, offset: usize, comptime T: type) ?u8 {
    switch (offset) {
        @offsetOf(T, "_config")...(@offsetOf(T, "_config") + sizeOfField(T, "_config") - 1) => {
            const rel_offset = offset - @offsetOf(T, "_config");
            const bytes = std.mem.asBytes(&this._config);

            return bytes[rel_offset];
        },
        @offsetOf(T, "_status")...(@offsetOf(T, "_status") + sizeOfField(T, "_status") - 1) => {
            const rel_offset = offset - @offsetOf(T, "_status");
            const bytes = std.mem.asBytes(&this._status);

            return bytes[rel_offset];
        },
        else => return null,
    }
}

const Tts = struct {
    pub const NativeCommand = enum(u8) {
        say = 1,

        pub inline fn byond(this: NativeCommand) x.ByondValue {
            return x.num(@intFromEnum(this));
        }
    };

    pub const ByondCommand = enum(u8) {
        ready_status = 1,
        _,

        pub inline fn byond(v: *const x.ByondValue) ByondCommand {
            const raw: u32 = @intFromFloat(x.ByondValue_GetNum(v));

            return std.enums.fromInt(ByondCommand, @as(u8, @truncate(raw))).?;
        }
    };

    memory: [sdk.Tts.BUFFER_SIZE]u8 = std.mem.zeroes([sdk.Tts.BUFFER_SIZE]u8),
    mmio: sdk.Tts = .{},

    pub inline fn reset(this: *Tts) void {
        @memset(&this.memory, 0);
        this.mmio = .{};
    }

    pub inline fn mmioRead(this: *Tts, slot: u8, machine: *Machine, offset: usize) ?u8 {
        _ = slot;
        _ = machine;

        return genericMmioRead(&this.mmio, offset, sdk.Tts);
    }

    pub inline fn mmioWrite(this: *Tts, slot: u8, machine: *Machine, offset: usize, value: u8) bool {
        switch (offset) {
            @offsetOf(sdk.Tts, "_config")...(@offsetOf(sdk.Tts, "_config") + sizeOfField(sdk.Tts, "_config") - 1) => {
                const rel_offset = offset - @offsetOf(sdk.Tts, "_config");
                const bytes = std.mem.asBytes(&this.mmio._config);

                bytes[rel_offset] = value;
                machine.updateExternalInterrupts();

                return true;
            },
            @offsetOf(sdk.Tts, "_action")...(@offsetOf(sdk.Tts, "_action") + sizeOfField(sdk.Tts, "_action") - 1) => {
                const rel_offset = offset - @offsetOf(sdk.Tts, "_action");

                switch (rel_offset) {
                    @offsetOf(sdk.Tts.Action, "execute") => {
                        if (!this.mmio._status.ready) {
                            return false;
                        }

                        const term_pos = std.mem.indexOfScalar(u8, &this.memory, 0) orelse {
                            return false;
                        };

                        const msg = this.memory[0..term_pos :0];

                        if (msg.len == 0) {
                            return false;
                        }

                        var byond_msg: x.ByondValue = .{};
                        x.ByondValue_SetStr(&byond_msg, msg);

                        return machine.tryCallSyscallProc(&.{ x.num(slot), NativeCommand.say.byond(), byond_msg, x.num(@intFromEnum(this.mmio._config.language)) });
                    },
                    @offsetOf(sdk.Tts.Action, "ack") => {
                        this.mmio._status.last_event = .{};
                        machine.updateExternalInterrupts();

                        return true;
                    },
                    else => return false,
                }
            },
            else => return false,
        }
    }

    pub inline fn executeDma(this: *Tts, slot: u8, machine: *Machine, cfg: sdk.Dma.Config) bool {
        _ = slot;

        switch (cfg.mode) {
            .read => return false,
            .write => {
                if (cfg.dst_address +| cfg.len > this.memory.len) {
                    return false;
                }

                if (cfg.src_address +| cfg.len > machine.cpu.ram.len) {
                    return false;
                }

                @memcpy(this.memory[cfg.dst_address..][0..cfg.len], machine.cpu.ram[cfg.src_address..][0..cfg.len]);

                return true;
            },
            .fill => {
                if (cfg.dst_address +| cfg.len > this.memory.len) {
                    return false;
                }

                if (cfg.src_address +| cfg.pattern_len > machine.cpu.ram.len) {
                    return false;
                }

                const pattern = machine.cpu.ram[cfg.src_address..][0..cfg.pattern_len];
                dmaFill(pattern, this.memory[cfg.dst_address..][0..cfg.len]);

                return true;
            },
            else => return false,
        }
    }

    pub inline fn syscall(this: *Tts, slot: u8, machine: *Machine, args: []const x.ByondValue) x.ByondValue {
        _ = slot;

        if (args.len == 0) {
            return x.False();
        }

        switch (ByondCommand.byond(&args[0])) {
            .ready_status => {
                if (args.len != 2) {
                    return x.False();
                }

                this.mmio._status.ready = x.ByondValue_IsTrue(&args[1]);

                if (this.mmio._status.ready) {
                    this.mmio._status.last_event = .{ .ty = .ready };
                }

                machine.updateExternalInterrupts();

                return x.True();
            },
            _ => return x.False(),
        }
    }

    pub inline fn isInterruptPending(this: *Tts, slot: u8, machine: *Machine) bool {
        _ = slot;
        _ = machine;

        if (this.mmio._config.interrupts.on_ready and this.mmio._status.last_event.ty == .ready) {
            return true;
        }

        return false;
    }
};

const SerialTerminal = struct {
    pub const NativeCommand = enum(u8) {
        write = 1,
        set_raw_mode = 2,

        pub inline fn byond(this: NativeCommand) x.ByondValue {
            return x.num(@intFromEnum(this));
        }
    };

    pub const ByondCommand = enum(u8) {
        write = 1,
        _,

        pub inline fn byond(v: *const x.ByondValue) ByondCommand {
            const raw: u32 = @intFromFloat(x.ByondValue_GetNum(v));

            return std.enums.fromInt(ByondCommand, @as(u8, @truncate(raw))).?;
        }
    };

    output: []u8,
    input: []u8,
    mmio: sdk.SerialTerminal = .{},

    pub inline fn init(allocator: std.mem.Allocator) error{OutOfMemory}!SerialTerminal {
        const output = try allocator.alloc(u8, sdk.SerialTerminal.OUTPUT_BUFFER_SIZE);
        errdefer allocator.free(output);

        const input = try allocator.alloc(u8, sdk.SerialTerminal.INPUT_BUFFER_SIZE);
        errdefer allocator.free(input);

        return .{
            .output = output,
            .input = input,
        };
    }

    pub inline fn reset(this: *SerialTerminal) void {
        @memset(this.output, 0);
        @memset(this.input, 0);
        this.mmio = .{};
    }

    pub inline fn mmioRead(this: *SerialTerminal, slot: u8, machine: *Machine, offset: usize) ?u8 {
        _ = slot;
        _ = machine;

        return genericMmioRead(&this.mmio, offset, sdk.SerialTerminal);
    }

    pub inline fn mmioWrite(this: *SerialTerminal, slot: u8, machine: *Machine, offset: usize, value: u8) bool {
        switch (offset) {
            @offsetOf(sdk.SerialTerminal, "_config")...(@offsetOf(sdk.SerialTerminal, "_config") + sizeOfField(sdk.SerialTerminal, "_config") - 1) => {
                const rel_offset = offset - @offsetOf(sdk.SerialTerminal, "_config");
                const bytes = std.mem.asBytes(&this.mmio._config);

                const old_raw_mode = this.mmio._config.raw_mode;
                bytes[rel_offset] = value;

                if (this.mmio._config.raw_mode != old_raw_mode) {
                    this.mmio._status.len = 0;
                    @memset(this.input, 0);

                    _ = machine.tryCallSyscallProc(&.{
                        x.num(slot),
                        NativeCommand.set_raw_mode.byond(),
                        x.num(if (this.mmio._config.raw_mode != 0) @as(u32, 1) else @as(u32, 0)),
                    });
                }

                machine.updateExternalInterrupts();

                return true;
            },
            @offsetOf(sdk.SerialTerminal, "_action")...(@offsetOf(sdk.SerialTerminal, "_action") + sizeOfField(sdk.SerialTerminal, "_action") - 1) => {
                const rel_offset = offset - @offsetOf(sdk.SerialTerminal, "_action");

                switch (rel_offset) {
                    @offsetOf(sdk.SerialTerminal.Action, "flush") => {
                        const len = std.mem.indexOfScalar(u8, this.output, 0) orelse this.output.len;

                        if (len == 0) {
                            return true;
                        }

                        var byond_bytes: x.ByondValue = .{};
                        if (!x.Byond_CreateListLen(&byond_bytes, len)) {
                            std.log.err("Failed to create a BYOND list for SerialTerminal output of len {}", .{len});

                            return false;
                        }

                        for (0..len) |idx| {
                            if (!x.Byond_WriteListIndex(&byond_bytes, &x.num(idx + 1), &x.num(this.output[idx]))) {
                                std.log.err("Failed to write an output byte from Serial Terminal at {}", .{idx});
                            }
                        }

                        @memset(this.output[0..len], 0);

                        return machine.tryCallSyscallProc(&.{ x.num(slot), NativeCommand.write.byond(), byond_bytes });
                    },
                    @offsetOf(sdk.SerialTerminal.Action, "ack") => {
                        this.mmio._status.last_event = .{};
                        this.mmio._status.len = 0;
                        machine.updateExternalInterrupts();

                        return true;
                    },
                    else => return false,
                }
            },
            else => return false,
        }
    }

    pub inline fn executeDma(this: *SerialTerminal, slot: u8, machine: *Machine, cfg: sdk.Dma.Config) bool {
        _ = slot;

        switch (cfg.mode) {
            .read => {
                if (cfg.dst_address +| cfg.len > machine.cpu.ram.len) {
                    return false;
                }

                if (cfg.src_address +| cfg.len > this.input.len) {
                    return false;
                }

                @memcpy(machine.cpu.ram[cfg.dst_address..][0..cfg.len], this.input[cfg.src_address..][0..cfg.len]);

                return true;
            },
            .write => {
                if (cfg.dst_address +| cfg.len > this.output.len) {
                    return false;
                }

                if (cfg.src_address +| cfg.len > machine.cpu.ram.len) {
                    return false;
                }

                @memcpy(this.output[cfg.dst_address..][0..cfg.len], machine.cpu.ram[cfg.src_address..][0..cfg.len]);

                return true;
            },
            .fill => {
                if (cfg.dst_address +| cfg.len > this.output.len) {
                    return false;
                }

                if (cfg.src_address +| cfg.pattern_len > machine.cpu.ram.len) {
                    return false;
                }

                const pattern = machine.cpu.ram[cfg.src_address..][0..cfg.pattern_len];
                dmaFill(pattern, this.output[cfg.dst_address..][0..cfg.len]);

                return true;
            },
            else => return false,
        }
    }

    pub inline fn syscall(this: *SerialTerminal, slot: u8, machine: *Machine, args: []const x.ByondValue) x.ByondValue {
        _ = slot;

        if (args.len == 0) {
            return x.False();
        }

        switch (ByondCommand.byond(&args[0])) {
            .write => {
                if (args.len != 2) {
                    return x.False();
                }

                const bytes = &args[1];

                if (!x.ByondValue_IsList(bytes)) {
                    return x.False();
                }

                var byond_bytes_len: x.ByondValue = .{};

                if (!x.Byond_Length(bytes, &byond_bytes_len)) {
                    return x.False();
                }

                const incoming_len: u32 = @intFromFloat(x.ByondValue_GetNum(&byond_bytes_len));

                const current_len: u32 = this.mmio._status.len;
                const available: u32 = @intCast(sdk.SerialTerminal.INPUT_BUFFER_SIZE - current_len);
                const bytes_to_write: u32 = @min(incoming_len, available);

                if (bytes_to_write == 0) {
                    // Buffer full - signal overflow but don't lose the interrupt
                    if (current_len > 0) {
                        this.mmio._status.last_event = .{ .ty = .new_data };
                        machine.updateExternalInterrupts();
                    }

                    return x.True();
                }

                var actually_written: u32 = 0;
                for (0..bytes_to_write) |i| {
                    var byond_byte: x.ByondValue = .{};

                    if (!x.Byond_ReadListIndex(bytes, &x.num(i + 1), &byond_byte)) {
                        break;
                    }

                    if (!x.ByondValue_IsNum(&byond_byte)) {
                        break;
                    }

                    const byte: u32 = @intFromFloat(x.ByondValue_GetNum(&byond_byte));
                    this.input[current_len + i] = @truncate(byte);
                    actually_written += 1;
                }

                if (actually_written > 0) {
                    this.mmio._status.last_event = .{ .ty = .new_data };
                    this.mmio._status.len = @truncate(current_len + actually_written);
                    machine.updateExternalInterrupts();
                }

                return x.True();
            },
            _ => return x.False(),
        }
    }

    pub inline fn isInterruptPending(this: *SerialTerminal, slot: u8, machine: *Machine) bool {
        _ = slot;
        _ = machine;

        if (this.mmio._config.interrupts.on_new_data and this.mmio._status.last_event.ty == .new_data) {
            return true;
        }

        return false;
    }

    pub inline fn deinit(this: *SerialTerminal, allocator: std.mem.Allocator) void {
        allocator.free(this.input);
        allocator.free(this.output);
    }
};

const Signaler = struct {
    pub const NativeCommand = enum(u8) {
        set = 1,
        send = 2,

        pub inline fn byond(this: NativeCommand) x.ByondValue {
            return x.num(@intFromEnum(this));
        }
    };

    pub const ByondCommand = enum(u8) {
        pulse = 1,
        ready_status = 2,
        _,

        pub inline fn byond(v: *const x.ByondValue) ByondCommand {
            const raw: u32 = @intFromFloat(x.ByondValue_GetNum(v));

            return std.enums.fromInt(ByondCommand, @as(u8, @truncate(raw))).?;
        }
    };

    mmio: sdk.Signaler = .{},

    pub inline fn reset(this: *Signaler) void {
        this.mmio = .{};
    }

    pub inline fn mmioRead(this: *Signaler, slot: u8, machine: *Machine, offset: usize) ?u8 {
        _ = slot;
        _ = machine;

        return genericMmioRead(&this.mmio, offset, sdk.Signaler);
    }

    pub inline fn mmioWrite(this: *Signaler, slot: u8, machine: *Machine, offset: usize, value: u8) bool {
        switch (offset) {
            @offsetOf(sdk.Signaler, "_config")...(@offsetOf(sdk.Signaler, "_config") + sizeOfField(sdk.Signaler, "_config") - 1) => {
                const rel_offset = offset - @offsetOf(sdk.Signaler, "_config");
                const bytes = std.mem.asBytes(&this.mmio._config);

                bytes[rel_offset] = value;
                machine.updateExternalInterrupts();

                return true;
            },
            @offsetOf(sdk.Signaler, "_action")...(@offsetOf(sdk.Signaler, "_action") + sizeOfField(sdk.Signaler, "_action") - 1) => {
                const rel_offset = offset - @offsetOf(sdk.Signaler, "_action");

                switch (rel_offset) {
                    @offsetOf(sdk.Signaler.Action, "set") => {
                        if (!this.mmio._status.ready) {
                            return false;
                        }

                        return machine.tryCallSyscallProc(&.{
                            x.num(slot),
                            NativeCommand.set.byond(),
                            x.num(this.mmio._config.frequency),
                            x.num(this.mmio._config.code),
                        });
                    },
                    @offsetOf(sdk.Signaler.Action, "send") => {
                        if (!this.mmio._status.ready) {
                            return false;
                        }

                        return machine.tryCallSyscallProc(&.{ x.num(slot), NativeCommand.send.byond() });
                    },
                    @offsetOf(sdk.Signaler.Action, "ack") => {
                        this.mmio._status.last_event = .{ .ty = .none };
                        machine.updateExternalInterrupts();

                        return true;
                    },
                    else => return false,
                }
            },
            else => return false,
        }

        return false;
    }

    pub inline fn syscall(this: *Signaler, slot: u8, machine: *Machine, args: []const x.ByondValue) x.ByondValue {
        _ = slot;

        if (args.len == 0) {
            return x.False();
        }

        switch (ByondCommand.byond(&args[0])) {
            .pulse => {
                if (args.len != 1) {
                    return x.False();
                }

                this.mmio._status.last_event = .{ .ty = .pulse };
                machine.updateExternalInterrupts();

                return x.True();
            },
            .ready_status => {
                if (args.len != 2) {
                    return x.False();
                }

                this.mmio._status.ready = x.ByondValue_IsTrue(&args[1]);

                if (this.mmio._status.ready) {
                    this.mmio._status.last_event = .{ .ty = .ready };
                }

                machine.updateExternalInterrupts();

                return x.True();
            },
            else => return x.False(),
        }
    }

    pub inline fn isInterruptPending(this: *Signaler, slot: u8, machine: *Machine) bool {
        _ = slot;
        _ = machine;

        if (this.mmio._config.interrupts.on_ready and this.mmio._status.last_event.ty == .ready) {
            return true;
        }

        if (this.mmio._config.interrupts.on_pulse and this.mmio._status.last_event.ty == .pulse) {
            return true;
        }

        return false;
    }
};

const Gps = struct {
    pub inline fn mmioRead(this: *Gps, slot: u8, machine: *Machine, offset: usize) ?u8 {
        _ = this;
        _ = slot;

        switch (offset) {
            @offsetOf(sdk.Gps, "_status")...(@offsetOf(sdk.Gps, "_status") + sizeOfField(sdk.Gps, "_status") - 1) => {
                machine.idle_executed += 100;

                const rel_offset = offset - @offsetOf(sdk.Gps, "_status");

                var xyz: x.ByondXYZ = .{};
                if (!x.Byond_XYZ(&machine.src, &xyz)) {
                    std.log.err("Failed to get XYZ of an object", .{});

                    return null;
                }

                const status: sdk.Gps.Status = .{
                    .x = xyz.x,
                    .y = xyz.y,
                    .z = xyz.z,
                };

                return std.mem.asBytes(&status)[rel_offset];
            },
            else => return null,
        }
    }
};

const Light = struct {
    pub const NativeCommand = enum(u8) {
        set = 1,

        pub inline fn byond(this: NativeCommand) x.ByondValue {
            return x.num(@intFromEnum(this));
        }
    };

    pub const ByondCommand = enum(u8) {
        ready_status = 1,
        _,

        pub inline fn byond(v: *const x.ByondValue) ByondCommand {
            const raw: u32 = @intFromFloat(x.ByondValue_GetNum(v));

            return std.enums.fromInt(ByondCommand, @as(u8, @truncate(raw))).?;
        }
    };

    mmio: sdk.Light = .{},

    pub inline fn reset(this: *Light) void {
        this.mmio = .{};
    }

    pub inline fn mmioRead(this: *Light, slot: u8, machine: *Machine, offset: usize) ?u8 {
        _ = slot;
        _ = machine;

        return genericMmioRead(&this.mmio, offset, sdk.Light);
    }

    pub inline fn mmioWrite(this: *Light, slot: u8, machine: *Machine, offset: usize, value: u8) bool {
        switch (offset) {
            @offsetOf(sdk.Light, "_config")...(@offsetOf(sdk.Light, "_config") + sizeOfField(sdk.Light, "_config") - 1) => {
                const rel_offset = offset - @offsetOf(sdk.Light, "_config");
                const bytes = std.mem.asBytes(&this.mmio._config);

                bytes[rel_offset] = value;
                machine.updateExternalInterrupts();

                return true;
            },
            @offsetOf(sdk.Light, "_action")...(@offsetOf(sdk.Light, "_action") + sizeOfField(sdk.Light, "_action") - 1) => {
                const rel_offset = offset - @offsetOf(sdk.Light, "_action");

                switch (rel_offset) {
                    @offsetOf(sdk.Light.Action, "set") => {
                        if (!this.mmio._status.ready) {
                            return false;
                        }

                        const color = this.mmio._config.color;
                        var hex_buffer: [7:0]u8 = undefined;
                        var writer: std.Io.Writer = .fixed(&hex_buffer);

                        writer.print("#{x:0>2}{x:0>2}{x:0>2}", .{ color.r, color.g, color.b }) catch unreachable;

                        var byond_hex: x.ByondValue = .{};
                        x.ByondValue_SetStr(&byond_hex, &hex_buffer);

                        return machine.tryCallSyscallProc(&.{
                            x.num(slot),
                            NativeCommand.set.byond(),
                            byond_hex,
                            x.num(this.mmio._config.brightness),
                        });
                    },
                    @offsetOf(sdk.Light.Action, "ack") => {
                        this.mmio._status.last_event = .{};
                        machine.updateExternalInterrupts();

                        return true;
                    },
                    else => return false,
                }
            },
            else => return false,
        }
    }

    pub inline fn syscall(this: *Light, slot: u8, machine: *Machine, args: []const x.ByondValue) x.ByondValue {
        _ = slot;

        if (args.len == 0) {
            return x.False();
        }

        switch (ByondCommand.byond(&args[0])) {
            .ready_status => {
                if (args.len != 2) {
                    return x.False();
                }

                this.mmio._status.ready = x.ByondValue_IsTrue(&args[1]);

                if (this.mmio._status.ready) {
                    this.mmio._status.last_event = .{ .ty = .ready };
                }

                machine.updateExternalInterrupts();

                return x.True();
            },
            else => return .{},
        }
    }

    pub inline fn isInterruptPending(this: *Light, slot: u8, machine: *Machine) bool {
        _ = slot;
        _ = machine;

        if (this.mmio._config.interrupts.on_ready and this.mmio._status.last_event.ty == .ready) {
            return true;
        }

        return false;
    }
};

const EnvSensor = struct {
    pub const NativeCommand = enum(u8) {
        update = 1,

        pub inline fn byond(this: NativeCommand) x.ByondValue {
            return x.num(@intFromEnum(this));
        }
    };

    pub const ByondCommand = enum(u8) {
        ready_status = 1,
        update = 2,
        _,

        pub inline fn byond(v: *const x.ByondValue) ByondCommand {
            const raw: u32 = @intFromFloat(x.ByondValue_GetNum(v));

            return std.enums.fromInt(ByondCommand, @as(u8, @truncate(raw))).?;
        }
    };

    mmio: sdk.EnvSensor = .{},

    pub inline fn reset(this: *EnvSensor) void {
        this.mmio = .{};
    }

    pub inline fn mmioRead(this: *EnvSensor, slot: u8, machine: *Machine, offset: usize) ?u8 {
        _ = slot;
        _ = machine;

        return genericMmioRead(&this.mmio, offset, sdk.EnvSensor);
    }

    pub inline fn mmioWrite(this: *EnvSensor, slot: u8, machine: *Machine, offset: usize, value: u8) bool {
        switch (offset) {
            @offsetOf(sdk.EnvSensor, "_config")...(@offsetOf(sdk.EnvSensor, "_config") + sizeOfField(sdk.EnvSensor, "_config") - 1) => {
                const rel_offset = offset - @offsetOf(sdk.EnvSensor, "_config");
                const bytes = std.mem.asBytes(&this.mmio._config);

                bytes[rel_offset] = value;
                machine.updateExternalInterrupts();

                return true;
            },
            @offsetOf(sdk.EnvSensor, "_action")...(@offsetOf(sdk.EnvSensor, "_action") + sizeOfField(sdk.EnvSensor, "_action") - 1) => {
                const rel_offset = offset - @offsetOf(sdk.EnvSensor, "_action");

                switch (rel_offset) {
                    @offsetOf(sdk.EnvSensor.Action, "update") => {
                        if (!this.mmio._status.ready) {
                            return false;
                        }

                        return machine.tryCallSyscallProc(&.{
                            x.num(slot),
                            NativeCommand.update.byond(),
                            if (this.mmio._config.rays.alpha) x.True() else x.False(),
                            if (this.mmio._config.rays.beta) x.True() else x.False(),
                            if (this.mmio._config.rays.hawking) x.True() else x.False(),
                        });
                    },
                    @offsetOf(sdk.EnvSensor.Action, "ack") => {
                        this.mmio._status.last_event = .{};
                        machine.updateExternalInterrupts();

                        return true;
                    },
                    else => return false,
                }
            },
            else => return false,
        }
    }

    pub inline fn syscall(this: *EnvSensor, slot: u8, machine: *Machine, args: []const x.ByondValue) x.ByondValue {
        _ = slot;

        if (args.len == 0) {
            return x.False();
        }

        switch (ByondCommand.byond(&args[0])) {
            .update => {
                if (args.len != 3) {
                    return x.False();
                }

                const byond_atmos = &args[1];
                const byond_radiation = &args[2];

                if (!x.ByondValue_IsList(byond_atmos)) {
                    return x.False();
                }

                if (!x.ByondValue_IsList(byond_radiation)) {
                    return x.False();
                }

                // Atmos
                {
                    var cursor: usize = 1;

                    var byond_total_moles: x.ByondValue = .{};
                    if (!x.Byond_ReadListIndex(byond_atmos, &x.num(cursor), &byond_total_moles)) {
                        std.log.err("Failed to read atmos list at index {}", .{cursor});

                        return x.False();
                    }

                    cursor += 1;
                    this.mmio._status.atmos.total_moles = @intFromFloat(x.ByondValue_GetNum(&byond_total_moles));

                    var byond_pressure: x.ByondValue = .{};
                    if (!x.Byond_ReadListIndex(byond_atmos, &x.num(cursor), &byond_pressure)) {
                        std.log.err("Failed to read atmos list at index {}", .{cursor});

                        return x.False();
                    }

                    cursor += 1;
                    this.mmio._status.atmos.pressure = @intFromFloat(x.ByondValue_GetNum(&byond_pressure));

                    var byond_temperature: x.ByondValue = .{};
                    if (!x.Byond_ReadListIndex(byond_atmos, &x.num(cursor), &byond_temperature)) {
                        std.log.err("Failed to read atmos list at index {}", .{cursor});

                        return x.False();
                    }

                    cursor += 1;
                    this.mmio._status.atmos.temperature = @intFromFloat(x.ByondValue_GetNum(&byond_temperature));

                    var byond_oxygen: x.ByondValue = .{};
                    if (!x.Byond_ReadListIndex(byond_atmos, &x.num(cursor), &byond_oxygen)) {
                        std.log.err("Failed to read atmos list at index {}", .{cursor});

                        return x.False();
                    }

                    cursor += 1;
                    this.mmio._status.atmos.oxygen = @intFromFloat(x.ByondValue_GetNum(&byond_oxygen));

                    var byond_nitrogen: x.ByondValue = .{};
                    if (!x.Byond_ReadListIndex(byond_atmos, &x.num(cursor), &byond_nitrogen)) {
                        std.log.err("Failed to read atmos list at index {}", .{cursor});

                        return x.False();
                    }

                    cursor += 1;
                    this.mmio._status.atmos.nitrogen = @intFromFloat(x.ByondValue_GetNum(&byond_nitrogen));

                    var byond_carbon_dioxide: x.ByondValue = .{};
                    if (!x.Byond_ReadListIndex(byond_atmos, &x.num(cursor), &byond_carbon_dioxide)) {
                        std.log.err("Failed to read atmos list at index {}", .{cursor});

                        return x.False();
                    }

                    cursor += 1;
                    this.mmio._status.atmos.carbon_dioxide = @intFromFloat(x.ByondValue_GetNum(&byond_carbon_dioxide));

                    var byond_hydrogen: x.ByondValue = .{};
                    if (!x.Byond_ReadListIndex(byond_atmos, &x.num(cursor), &byond_hydrogen)) {
                        std.log.err("Failed to read atmos list at index {}", .{cursor});

                        return x.False();
                    }

                    cursor += 1;
                    this.mmio._status.atmos.hydrogen = @intFromFloat(x.ByondValue_GetNum(&byond_hydrogen));

                    var byond_plasma: x.ByondValue = .{};
                    if (!x.Byond_ReadListIndex(byond_atmos, &x.num(cursor), &byond_plasma)) {
                        std.log.err("Failed to read atmos list at index {}", .{cursor});

                        return x.False();
                    }

                    cursor += 1;
                    this.mmio._status.atmos.plasma = @intFromFloat(x.ByondValue_GetNum(&byond_plasma));
                }

                // Radiation
                {
                    var cursor: usize = 1;

                    var byond_avg_activity: x.ByondValue = .{};
                    if (!x.Byond_ReadListIndex(byond_radiation, &x.num(cursor), &byond_avg_activity)) {
                        std.log.err("Failed to read radiation list at index {}", .{cursor});

                        return x.False();
                    }

                    cursor += 1;
                    this.mmio._status.radiation.avg_activity = @intFromFloat(x.ByondValue_GetNum(&byond_avg_activity));

                    var byond_avg_energy: x.ByondValue = .{};
                    if (!x.Byond_ReadListIndex(byond_radiation, &x.num(cursor), &byond_avg_energy)) {
                        std.log.err("Failed to read radiation list at index {}", .{cursor});

                        return x.False();
                    }

                    cursor += 1;
                    this.mmio._status.radiation.avg_energy = @intFromFloat(x.ByondValue_GetNum(&byond_avg_energy));

                    var byond_dose: x.ByondValue = .{};
                    if (!x.Byond_ReadListIndex(byond_radiation, &x.num(cursor), &byond_dose)) {
                        std.log.err("Failed to read radiation list at index {}", .{cursor});

                        return x.False();
                    }

                    cursor += 1;
                    this.mmio._status.radiation.dose = @intFromFloat(x.ByondValue_GetNum(&byond_dose));
                }

                return x.True();
            },
            .ready_status => {
                if (args.len != 2) {
                    return x.False();
                }

                this.mmio._status.ready = x.ByondValue_IsTrue(&args[1]);

                if (this.mmio._status.ready) {
                    this.mmio._status.last_event = .{ .ty = .ready };
                }

                machine.updateExternalInterrupts();

                return x.True();
            },
            else => return x.False(),
        }
    }

    pub inline fn isInterruptPending(this: *EnvSensor, slot: u8, machine: *Machine) bool {
        _ = slot;
        _ = machine;

        if (this.mmio._config.interrupts.on_ready and this.mmio._status.last_event.ty == .ready) {
            return true;
        }

        return false;
    }
};

pub const Vga = struct {
    pub const NativeCommand = enum(u8) {
        vblank = 1,
        set_resolution = 2,

        pub inline fn byond(this: NativeCommand) x.ByondValue {
            return x.num(@intFromEnum(this));
        }
    };

    pub const ByondCommand = enum(u8) {
        send_screen = 1,
        keyboard_event = 2,
        mouse_event = 3,
        _,

        pub inline fn byond(v: *const x.ByondValue) ByondCommand {
            const raw: u32 = @intFromFloat(x.ByondValue_GetNum(v));

            return std.enums.fromInt(ByondCommand, @as(u8, @truncate(raw))).?;
        }
    };

    pub const Frame = struct {
        buffer: []u8,
        compressed_len: usize = 0,
        dirty: bool = true,

        pub inline fn init(allocator: std.mem.Allocator) !Frame {
            return Frame{
                .buffer = try allocator.alloc(u8, sdk.Vga.Resolution.hi.len() * @sizeOf(sdk.Rgb)),
            };
        }

        pub inline fn reset(this: *Frame) void {
            this.compressed_len = 0;
            this.dirty = true;
        }

        pub inline fn deinit(this: *Frame, allocator: std.mem.Allocator) void {
            allocator.free(this.buffer);
            this.buffer = &.{};
            this.dirty = true;
        }
    };

    mmio: sdk.Vga = .{},
    palette: []sdk.Rgb,
    fb: []u8,
    frame: Frame,
    keyboard: []sdk.Vga.KeyState,
    keyboard_events: std.ArrayList(sdk.Vga.KeyboardEvent) = .empty,
    mouse_events: std.ArrayList(sdk.Vga.MouseEvent) = .empty,
    elapsed_from_vblank_us: u32 = 0,
    lock: std.Thread.Mutex = .{},

    pub inline fn init(allocator: std.mem.Allocator) !Vga {
        const palette = try allocator.alloc(sdk.Rgb, sdk.Vga.PAL_LEN);
        errdefer allocator.free(palette);

        const fb = try allocator.alloc(u8, sdk.Vga.Resolution.hi.len());
        errdefer allocator.free(fb);

        var frame = try Frame.init(allocator);
        errdefer frame.deinit(allocator);

        const keyboard = try allocator.alloc(sdk.Vga.KeyState, sdk.Vga.Scancode.KEYS);
        errdefer allocator.free(keyboard);

        var keyboard_events = try std.ArrayList(sdk.Vga.KeyboardEvent).initCapacity(allocator, sdk.Vga.KeyboardEvent.MAX_EVENTS);
        errdefer keyboard_events.deinit(allocator);

        var mouse_events = try std.ArrayList(sdk.Vga.MouseEvent).initCapacity(allocator, sdk.Vga.MouseEvent.MAX_EVENTS);
        errdefer mouse_events.deinit(allocator);

        return Vga{
            .mmio = .{},
            .palette = palette,
            .fb = fb,
            .frame = frame,
            .keyboard = keyboard,
            .keyboard_events = keyboard_events,
            .mouse_events = mouse_events,
        };
    }

    pub inline fn deinit(this: *Vga, allocator: std.mem.Allocator) void {
        allocator.free(this.keyboard);
        this.keyboard_events.deinit(allocator);
        this.mouse_events.deinit(allocator);

        allocator.free(this.palette);
        this.palette = &.{};

        allocator.free(this.fb);
        this.fb = &.{};

        this.frame.deinit(allocator);
    }

    pub inline fn reset(this: *Vga) void {
        this.lock.lock();
        defer this.lock.unlock();

        this.mmio = .{};
        @memset(this.palette, .{});
        @memset(this.fb, 0);
        this.frame.reset();
        @memset(this.keyboard, .{});
        this.keyboard_events.clearRetainingCapacity();
        this.mouse_events.clearRetainingCapacity();
    }

    pub inline fn worker(this: *Vga, slot: u8, machine: *Machine) void {
        _ = slot;
        _ = machine;

        // Lock for this.palette, this.fb and this.frame
        this.lock.lock();
        defer this.lock.unlock();

        if (!this.frame.dirty) {
            return;
        }

        var window_buffer: [flate.max_window_len]u8 = undefined;
        var writer: std.Io.Writer = .fixed(this.frame.buffer);
        var compressor = flate.Compress.init(&writer, &window_buffer, .zlib, .best) catch |err| {
            std.log.err("Failed to write compressed data: {t}", .{err});

            return;
        };

        compressor.writer.writeAll(std.mem.sliceAsBytes(this.palette)) catch |err| {
            std.log.err("Failed to compress palette data: {t}", .{err});

            return;
        };

        const fb_len = this.mmio._config.resolution.len();
        compressor.writer.writeAll(std.mem.sliceAsBytes(this.fb[0..fb_len])) catch |err| {
            std.log.err("Failed to compress framebuffer data: {t}", .{err});

            return;
        };

        compressor.finish() catch |err| {
            std.log.err("Failed to finish the compressor: {t}", .{err});

            return;
        };

        this.frame.compressed_len = writer.end;
        this.frame.dirty = false;
    }

    // Caller should lock the machine.
    pub inline fn requiresWorker(this: *Vga, slot: u8, machine: *Machine) bool {
        _ = slot;
        _ = machine;

        return this.frame.dirty;
    }

    pub inline fn update(this: *Vga, slot: u8, machine: *Machine, delta_us: u32) void {
        const freq_s: f32 = 1.0 / @as(f32, @floatFromInt(this.mmio._config.resolution.fps()));
        const freq_us: u32 = @intFromFloat(freq_s * std.time.us_per_s);

        this.elapsed_from_vblank_us +|= delta_us;

        if (this.elapsed_from_vblank_us < freq_us) {
            return;
        }

        this.elapsed_from_vblank_us -= freq_us;

        this.mmio._status.last_event = .{ .ty = .vblank };
        machine.updateExternalInterrupts();

        _ = machine.tryCallSyscallProc(&.{
            x.num(slot),
            NativeCommand.vblank.byond(),
        });
    }

    pub inline fn mmioRead(this: *Vga, slot: u8, machine: *Machine, offset: usize) ?u8 {
        _ = slot;
        _ = machine;

        return genericMmioRead(&this.mmio, offset, sdk.Vga);
    }

    pub inline fn mmioWrite(this: *Vga, slot: u8, machine: *Machine, offset: usize, value: u8) bool {
        switch (offset) {
            @offsetOf(sdk.Vga, "_config")...(@offsetOf(sdk.Vga, "_config") + sizeOfField(sdk.Vga, "_config") - 1) => {
                const rel_offset = offset - @offsetOf(sdk.Vga, "_config");
                const bytes = std.mem.asBytes(&this.mmio._config);

                const old_res = this.mmio._config.resolution;

                bytes[rel_offset] = value;
                machine.updateExternalInterrupts();

                const new_res = this.mmio._config.resolution;

                if (new_res != old_res) {
                    this.elapsed_from_vblank_us = 0;
                    _ = machine.tryCallSyscallProc(&.{
                        x.num(slot),
                        NativeCommand.set_resolution.byond(),
                        x.num(new_res.width()),
                        x.num(new_res.height()),
                    });
                }

                return true;
            },
            @offsetOf(sdk.Vga, "_action")...(@offsetOf(sdk.Vga, "_action") + sizeOfField(sdk.Vga, "_action") - 1) => {
                const rel_offset = offset - @offsetOf(sdk.Vga, "_action");

                switch (rel_offset) {
                    @offsetOf(sdk.Vga.Action, "ack") => {
                        this.mmio._status.last_event = .{};
                        machine.updateExternalInterrupts();

                        return true;
                    },
                    @offsetOf(sdk.Vga.Action, "keyboard_ack") => {
                        this.mmio._status.head_keyboard_event = .{};

                        if (this.keyboard_events.items.len > 0) {
                            this.mmio._status.head_keyboard_event = this.keyboard_events.orderedRemove(0);
                        }

                        machine.updateExternalInterrupts();

                        return true;
                    },
                    @offsetOf(sdk.Vga.Action, "mouse_ack") => {
                        this.mmio._status.head_mouse_event = .{};

                        if (this.mouse_events.items.len > 0) {
                            this.mmio._status.head_mouse_event = this.mouse_events.orderedRemove(0);
                        }

                        machine.updateExternalInterrupts();

                        return true;
                    },
                    @offsetOf(sdk.Vga.Action, "execute_blitter") => {
                        return this.executeBlitter(machine);
                    },
                    else => return false,
                }
            },
            else => return false,
        }
    }

    pub inline fn executeDma(this: *Vga, slot: u8, machine: *Machine, cfg: sdk.Dma.Config) bool {
        _ = slot;

        // Lock for this.palette, this.fb and this.frame
        this.lock.lock();
        defer this.lock.unlock();

        const pal_bytes = std.mem.sliceAsBytes(this.palette);
        const fb_bytes = std.mem.sliceAsBytes(this.fb);
        const keyboard_bytes = std.mem.sliceAsBytes(this.keyboard);

        std.debug.assert(this.palette.len == sdk.Vga.PAL_LEN);
        std.debug.assert(pal_bytes.len == sdk.Vga.PAL_SIZE);

        std.debug.assert(this.fb.len == sdk.Vga.Resolution.hi.len());
        std.debug.assert(fb_bytes.len == sdk.Vga.Resolution.hi.size());

        std.debug.assert(this.keyboard.len == sdk.Vga.KEYBOARD_LEN);
        std.debug.assert(keyboard_bytes.len == sdk.Vga.KEYBOARD_SIZE);

        switch (cfg.mode) {
            .read => {
                if (cfg.dst_address +| cfg.len > machine.cpu.ram.len) {
                    return false;
                }

                switch (cfg.src_address) {
                    sdk.Vga.KEYBOARD_ADDRESS...(sdk.Vga.KEYBOARD_ADDRESS + sdk.Vga.KEYBOARD_SIZE - 1) => {
                        const rel_offset = cfg.src_address - sdk.Vga.KEYBOARD_ADDRESS;

                        if (rel_offset +| cfg.len > sdk.Vga.KEYBOARD_SIZE) {
                            return false;
                        }

                        @memcpy(machine.cpu.ram[cfg.dst_address..][0..cfg.len], keyboard_bytes[rel_offset..][0..cfg.len]);

                        return true;
                    },
                    sdk.Vga.PAL_ADDRESS...(sdk.Vga.PAL_ADDRESS + sdk.Vga.PAL_SIZE - 1) => {
                        const rel_offset = cfg.src_address - sdk.Vga.PAL_ADDRESS;

                        if (rel_offset +| cfg.len > sdk.Vga.PAL_SIZE) {
                            return false;
                        }

                        @memcpy(machine.cpu.ram[cfg.dst_address..][0..cfg.len], pal_bytes[rel_offset..][0..cfg.len]);

                        return true;
                    },
                    sdk.Vga.FB_ADDRESS...(sdk.Vga.FB_ADDRESS + sdk.Vga.Resolution.hi.size() - 1) => {
                        const rel_offset = cfg.src_address - sdk.Vga.FB_ADDRESS;

                        if (rel_offset +| cfg.len > sdk.Vga.Resolution.hi.size()) {
                            return false;
                        }

                        @memcpy(machine.cpu.ram[cfg.dst_address..][0..cfg.len], fb_bytes[rel_offset..][0..cfg.len]);

                        return true;
                    },
                    else => return false,
                }
            },
            .write => {
                if (cfg.src_address +| cfg.len > machine.cpu.ram.len) {
                    return false;
                }

                this.frame.dirty = true;

                switch (cfg.dst_address) {
                    sdk.Vga.KEYBOARD_ADDRESS...(sdk.Vga.KEYBOARD_ADDRESS + sdk.Vga.KEYBOARD_SIZE - 1) => return false,
                    sdk.Vga.PAL_ADDRESS...(sdk.Vga.PAL_ADDRESS + sdk.Vga.PAL_SIZE - 1) => {
                        const rel_offset = cfg.dst_address - sdk.Vga.PAL_ADDRESS;

                        if (rel_offset +| cfg.len > sdk.Vga.PAL_SIZE) {
                            return false;
                        }

                        @memcpy(pal_bytes[rel_offset..][0..cfg.len], machine.cpu.ram[cfg.src_address..][0..cfg.len]);

                        return true;
                    },
                    sdk.Vga.FB_ADDRESS...(sdk.Vga.FB_ADDRESS + sdk.Vga.Resolution.hi.size() - 1) => {
                        const rel_offset = cfg.dst_address - sdk.Vga.FB_ADDRESS;

                        if (rel_offset +| cfg.len > sdk.Vga.Resolution.hi.size()) {
                            return false;
                        }

                        @memcpy(fb_bytes[rel_offset..][0..cfg.len], machine.cpu.ram[cfg.src_address..][0..cfg.len]);

                        return true;
                    },
                    else => return false,
                }
            },
            .fill => {
                if (cfg.src_address +| cfg.pattern_len > machine.cpu.ram.len) {
                    return false;
                }

                this.frame.dirty = true;

                const pattern = machine.cpu.ram[cfg.src_address..][0..cfg.pattern_len];

                switch (cfg.dst_address) {
                    sdk.Vga.KEYBOARD_ADDRESS...(sdk.Vga.KEYBOARD_ADDRESS + sdk.Vga.KEYBOARD_SIZE - 1) => return false,
                    sdk.Vga.PAL_ADDRESS...(sdk.Vga.PAL_ADDRESS + sdk.Vga.PAL_SIZE - 1) => {
                        const rel_offset = cfg.dst_address - sdk.Vga.PAL_ADDRESS;

                        if (rel_offset +| cfg.len > sdk.Vga.PAL_SIZE) {
                            return false;
                        }

                        dmaFill(pattern, pal_bytes[rel_offset..][0..cfg.len]);

                        return true;
                    },
                    sdk.Vga.FB_ADDRESS...(sdk.Vga.FB_ADDRESS + sdk.Vga.Resolution.hi.size() - 1) => {
                        const rel_offset = cfg.dst_address - sdk.Vga.FB_ADDRESS;

                        if (rel_offset +| cfg.len > sdk.Vga.Resolution.hi.size()) {
                            return false;
                        }

                        dmaFill(pattern, fb_bytes[rel_offset..][0..cfg.len]);

                        return true;
                    },
                    else => return false,
                }
            },
            else => return false,
        }
    }

    pub fn syscall(this: *Vga, slot: u8, machine: *Machine, args: []const x.ByondValue) x.ByondValue {
        _ = slot;

        if (args.len == 0) {
            return x.False();
        }

        switch (ByondCommand.byond(&args[0])) {
            .send_screen => {
                if (args.len != 2) {
                    return x.False();
                }

                // Lock for this.frame
                this.lock.lock();
                defer this.lock.unlock();

                if (this.frame.compressed_len == 0 or this.frame.dirty == true) {
                    return x.True();
                }

                const byond_conn_id = &args[1];
                const conn_id: u32 = @intFromFloat(x.ByondValue_GetNum(byond_conn_id));

                const ws_state = ws.getState();

                if (ws_state.server == null) {
                    return x.True();
                }

                if (conn_id >= ws_state.server.?.connections.items.len) {
                    return x.True();
                }

                const conn = &ws_state.server.?.connections.items[conn_id];

                conn.sendBinary(ws_state.allocator, this.frame.buffer[0..this.frame.compressed_len]) catch |err| {
                    std.log.err("Failed to send the screen data: {t}", .{err});

                    return x.False();
                };

                return x.True();
            },
            .keyboard_event => {
                if (args.len != 4) {
                    return x.False();
                }

                const raw_ty = helpers.safeIntTruncate(u8, x.ByondValue_GetNum(&args[1])) orelse {
                    return x.True();
                };

                const ty = std.enums.fromInt(sdk.Vga.KeyboardEvent.Type, raw_ty) orelse {
                    return x.True();
                };

                const raw_scancode = helpers.safeIntTruncate(u8, x.ByondValue_GetNum(&args[2])) orelse {
                    return x.True();
                };

                const scancode = std.enums.fromInt(sdk.Vga.Scancode, raw_scancode) orelse {
                    return x.True();
                };

                const modifiers = helpers.safeIntTruncate(u8, x.ByondValue_GetNum(&args[3])) orelse {
                    return x.True();
                };

                this.enqueueKeyboardEvent(machine, .{
                    .ty = ty,
                    .scancode = scancode,
                    .modifiers = @bitCast(modifiers),
                });

                return x.True();
            },
            .mouse_event => {
                if (args.len != 7) {
                    return x.False();
                }

                const raw_ty = helpers.safeIntTruncate(u8, x.ByondValue_GetNum(&args[1])) orelse {
                    return x.True();
                };

                const ty = std.enums.fromInt(sdk.Vga.MouseEvent.Type, raw_ty) orelse {
                    return x.True();
                };

                const raw_button = helpers.safeIntTruncate(u8, x.ByondValue_GetNum(&args[2])) orelse {
                    return x.True();
                };

                const button = std.enums.fromInt(sdk.Vga.MouseButton, raw_button) orelse {
                    return x.True();
                };

                const dx = helpers.safeIntTruncate(i16, x.ByondValue_GetNum(&args[3])) orelse {
                    return x.True();
                };

                const dy = helpers.safeIntTruncate(i16, x.ByondValue_GetNum(&args[4])) orelse {
                    return x.True();
                };

                const scroll_dx = helpers.safeIntTruncate(i16, x.ByondValue_GetNum(&args[5])) orelse {
                    return x.True();
                };

                const scroll_dy = helpers.safeIntTruncate(i16, x.ByondValue_GetNum(&args[6])) orelse {
                    return x.True();
                };

                this.enqueueMouseEvent(machine, .{
                    .ty = ty,
                    .button = button,
                    .dx = dx,
                    .dy = dy,
                    .scroll_dx = scroll_dx,
                    .scroll_dy = scroll_dy,
                });

                return x.True();
            },
            else => return x.False(),
        }
    }

    pub inline fn isInterruptPending(this: *Vga, slot: u8, machine: *Machine) bool {
        _ = slot;
        _ = machine;

        if (this.mmio._config.interrupts.on_vblank and this.mmio._status.last_event.ty == .vblank) {
            return true;
        }

        const kbd = this.mmio._config.keyboard_interrupts;

        if (kbd.on_key_press or kbd.on_key_release) {
            if (kbd.on_key_press and this.mmio._status.head_keyboard_event.ty == .press) {
                return true;
            }

            if (kbd.on_key_release and this.mmio._status.head_keyboard_event.ty == .release) {
                return true;
            }

            for (this.keyboard_events.items) |item| {
                if (kbd.on_key_press and item.ty == .press) {
                    return true;
                }

                if (kbd.on_key_release and item.ty == .release) {
                    return true;
                }
            }
        }

        const mouse = this.mmio._config.mouse_interrupts;

        if (mouse.on_button_press or mouse.on_button_release or mouse.on_move or mouse.on_scroll) {
            if (mouse.on_button_press and this.mmio._status.head_mouse_event.ty == .press) {
                return true;
            }

            if (mouse.on_button_release and this.mmio._status.head_mouse_event.ty == .release) {
                return true;
            }

            if (mouse.on_move and this.mmio._status.head_mouse_event.ty == .move) {
                return true;
            }

            if (mouse.on_scroll and this.mmio._status.head_mouse_event.ty == .scroll) {
                return true;
            }

            for (this.mouse_events.items) |item| {
                if (mouse.on_button_press and item.ty == .press) {
                    return true;
                }

                if (mouse.on_button_release and item.ty == .release) {
                    return true;
                }

                if (mouse.on_move and item.ty == .move) {
                    return true;
                }

                if (mouse.on_scroll and item.ty == .scroll) {
                    return true;
                }
            }
        }

        return false;
    }

    inline fn isqrt(n: i64) i32 {
        if (n <= 0) {
            return 0;
        }

        return @intFromFloat(@sqrt(@as(f64, @floatFromInt(n))));
    }

    inline fn wrapCoord(val: i32, size: i32) usize {
        var m = @rem(val, size);

        if (m < 0) {
            m += size;
        }

        return @intCast(m);
    }

    inline fn applyRectOrigin(
        pos: sdk.Vga.BlitterConfig.Args.Position,
        w: u16,
        h: u16,
        origin: sdk.Vga.BlitterConfig.Args.Origin,
    ) struct { x: i32, y: i32 } {
        const px: i32 = pos.x;
        const py: i32 = pos.y;
        const wi: i32 = w;
        const hi: i32 = h;

        return switch (origin) {
            .top_left => .{ .x = px, .y = py },
            .top => .{ .x = px - @divTrunc(wi, 2), .y = py },
            .top_right => .{ .x = px - wi, .y = py },
            .right => .{ .x = px - wi, .y = py - @divTrunc(hi, 2) },
            .bottom_right => .{ .x = px - wi, .y = py - hi },
            .bottom => .{ .x = px - @divTrunc(wi, 2), .y = py - hi },
            .bottom_left => .{ .x = px, .y = py - hi },
            .left => .{ .x = px, .y = py - @divTrunc(hi, 2) },
            .center => .{ .x = px - @divTrunc(wi, 2), .y = py - @divTrunc(hi, 2) },
        };
    }

    inline fn applyCircleOrigin(
        pos: sdk.Vga.BlitterConfig.Args.Position,
        r: u16,
        origin: sdk.Vga.BlitterConfig.Args.Origin,
    ) struct { x: i32, y: i32 } {
        const px: i32 = pos.x;
        const py: i32 = pos.y;
        const ri: i32 = r;

        return switch (origin) {
            .top_left => .{ .x = px + ri, .y = py + ri },
            .top => .{ .x = px, .y = py + ri },
            .top_right => .{ .x = px - ri, .y = py + ri },
            .right => .{ .x = px - ri, .y = py },
            .bottom_right => .{ .x = px - ri, .y = py - ri },
            .bottom => .{ .x = px, .y = py - ri },
            .bottom_left => .{ .x = px + ri, .y = py - ri },
            .left => .{ .x = px + ri, .y = py },
            .center => .{ .x = px, .y = py },
        };
    }

    inline fn executeBlitter(this: *Vga, machine: *Machine) bool {
        // Lock for this.palette and this.fb
        this.lock.lock();
        defer this.lock.unlock();

        this.frame.dirty = true;

        const cmd = this.mmio._config.blitter.cmd;
        const args = this.mmio._config.blitter.args;

        const width = this.mmio._config.resolution.width();
        const height = this.mmio._config.resolution.height();

        switch (cmd) {
            .clear => {
                @memset(this.fb, args.clear.color);

                return true;
            },
            .rect => {
                const rect = args.rect;
                const pos = applyRectOrigin(rect.pos, rect.w, rect.h, rect.origin);

                switch (rect.mode) {
                    .crop => {
                        const x_start = @max(0, pos.x);
                        const y_start = @max(0, pos.y);
                        const x_end = @min(width, pos.x + @as(i32, rect.w));
                        const y_end = @min(height, pos.y + @as(i32, rect.h));

                        if (x_start >= x_end or y_start >= y_end) {
                            return true;
                        }

                        const xs: usize = @intCast(x_start);
                        const xe: usize = @intCast(x_end);
                        const row_len = xe - xs;

                        for (@as(usize, @intCast(y_start))..@as(usize, @intCast(y_end))) |y| {
                            @memset(this.fb[y * width + xs ..][0..row_len], rect.color);
                        }

                        return true;
                    },
                    .wrap => {
                        for (0..rect.h) |dy| {
                            const cy = wrapCoord(pos.y + @as(i32, @intCast(dy)), height);

                            for (0..rect.w) |dx| {
                                const cx = wrapCoord(pos.x + @as(i32, @intCast(dx)), width);

                                this.fb[cy * width + cx] = rect.color;
                            }
                        }

                        return true;
                    },
                }
            },
            .circle => {
                const circle = args.circle;
                const center = applyCircleOrigin(circle.pos, circle.r, circle.origin);
                const r: i32 = circle.r;

                if (r == 0) {
                    return true;
                }

                const r_sq: i64 = @as(i64, r) * @as(i64, r);

                switch (circle.mode) {
                    .crop => {
                        const y_min = @max(0, center.y - r);
                        const y_max = @min(height, center.y + r + 1);

                        if (y_min >= y_max) {
                            return true;
                        }

                        for (@as(usize, @intCast(y_min))..@as(usize, @intCast(y_max))) |y| {
                            const dy: i64 = @as(i32, @intCast(y)) - center.y;
                            const x_offset_raw = isqrt(r_sq - dy * dy);

                            if (x_offset_raw == 0 and r >= 3) {
                                continue;
                            }

                            const x_offset = if (x_offset_raw == r and r >= 3) x_offset_raw - 1 else x_offset_raw;

                            const x_start = @max(0, center.x - x_offset);
                            const x_end = @min(width, center.x + x_offset + 1);

                            if (x_start < x_end) {
                                const xs: usize = @intCast(x_start);
                                const xe: usize = @intCast(x_end);

                                @memset(this.fb[y * width + xs ..][0 .. xe - xs], circle.color);
                            }
                        }

                        return true;
                    },
                    .wrap => {
                        const diameter: usize = @as(usize, 2 * @as(u32, circle.r)) + 1;

                        for (0..diameter) |dy_idx| {
                            const dy: i64 = @as(i32, @intCast(dy_idx)) - r;
                            const x_offset_sq = r_sq - dy * dy;

                            if (x_offset_sq < 0) {
                                continue;
                            }

                            const x_offset_raw = isqrt(x_offset_sq);

                            if (x_offset_raw == 0 and r >= 3) {
                                continue;
                            }

                            const x_offset = if (x_offset_raw == r and r >= 3) x_offset_raw - 1 else x_offset_raw;

                            const cy = wrapCoord(center.y + @as(i32, @intCast(dy_idx)) - r, height);
                            const span: usize = @as(usize, @intCast(2 * x_offset)) + 1;

                            for (0..span) |dx_idx| {
                                const dx: i32 = @as(i32, @intCast(dx_idx)) - x_offset;
                                const cx = wrapCoord(center.x + dx, width);

                                this.fb[cy * width + cx] = circle.color;
                            }
                        }

                        return true;
                    },
                }
            },
            .copy => {
                const copy = args.copy;
                const bytes_len = @as(u64, copy.w) * @as(u64, copy.h);

                if (copy.src +| bytes_len > machine.cpu.ram.len) {
                    return false;
                }

                const src: [*]const u8 = @ptrCast(@alignCast(&machine.cpu.ram[copy.src]));
                const src_stride: usize = copy.w;

                if (copy.src_pos.x >= copy.w or copy.src_pos.y >= copy.h) {
                    return true;
                }

                const copy_w: usize = copy.w - copy.src_pos.x;
                const copy_h: usize = copy.h - copy.src_pos.y;

                const src_x: usize = copy.src_pos.x;
                const src_y: usize = copy.src_pos.y;

                switch (copy.mode) {
                    .crop => {
                        if (copy.dst_pos.x >= width or copy.dst_pos.y >= height) {
                            return true;
                        }

                        const dst_x: usize = copy.dst_pos.x;
                        const dst_y: usize = copy.dst_pos.y;

                        const actual_w = @min(copy_w, width - dst_x);
                        const actual_h = @min(copy_h, height - dst_y);

                        for (0..actual_h) |dy| {
                            const src_offset = (src_y + dy) * src_stride + src_x;
                            const dst_offset = (dst_y + dy) * width + dst_x;

                            @memcpy(this.fb[dst_offset..][0..actual_w], src[src_offset..][0..actual_w]);
                        }

                        return true;
                    },
                    .wrap => {
                        for (0..copy_h) |dy| {
                            const wrap_y = @mod(@as(usize, copy.dst_pos.y) + dy, height);
                            const src_row = (src_y + dy) * src_stride + src_x;

                            for (0..copy_w) |dx| {
                                const wrap_x = @mod(@as(usize, copy.dst_pos.x) + dx, width);

                                this.fb[wrap_y * width + wrap_x] = src[src_row + dx];
                            }
                        }

                        return true;
                    },
                }
            },
            else => return true,
        }
    }

    inline fn enqueueKeyboardEvent(this: *Vga, machine: *Machine, event: sdk.Vga.KeyboardEvent) void {
        if (event.scancode != .none) {
            const idx = event.scancode.toIdx();

            if (idx < sdk.Vga.Scancode.KEYS) {
                this.keyboard[idx] = switch (event.ty) {
                    .press => true,
                    .release => false,
                    else => this.keyboard[idx],
                };
            }
        }

        if (this.mmio._status.head_keyboard_event.ty == .none) {
            this.mmio._status.head_keyboard_event = event;
        } else if (this.keyboard_events.items.len < sdk.Vga.KeyboardEvent.MAX_EVENTS) {
            this.keyboard_events.appendAssumeCapacity(event);
        }

        machine.updateExternalInterrupts();
    }

    inline fn enqueueMouseEvent(this: *Vga, machine: *Machine, event: sdk.Vga.MouseEvent) void {
        switch (event.ty) {
            .press => switch (event.button) {
                .left => this.mmio._status.mouse_state.left = true,
                .right => this.mmio._status.mouse_state.right = true,
                .middle => this.mmio._status.mouse_state.middle = true,
                else => {},
            },
            .release => switch (event.button) {
                .left => this.mmio._status.mouse_state.left = false,
                .right => this.mmio._status.mouse_state.right = false,
                .middle => this.mmio._status.mouse_state.middle = false,
                else => {},
            },
            else => {},
        }

        if (this.mmio._status.head_mouse_event.ty == .none) {
            this.mmio._status.head_mouse_event = event;
        } else if (this.mouse_events.items.len < sdk.Vga.MouseEvent.MAX_EVENTS) {
            this.mouse_events.appendAssumeCapacity(event);
        }

        machine.updateExternalInterrupts();
    }
};

const Device = union(enum) {
    none,
    tts: Tts,
    serial_terminal: SerialTerminal,
    signaler: Signaler,
    gps: Gps,
    light: Light,
    env_sensor: EnvSensor,
    vga: Vga,

    pub inline fn worker(this: *Device, slot: u8, machine: *Machine) void {
        switch (this.*) {
            .none, .tts, .serial_terminal, .signaler, .gps, .light, .env_sensor => {},
            .vga => this.vga.worker(slot, machine),
        }
    }

    // Caller should lock the machine.
    pub inline fn requiresWorker(this: *Device, slot: u8, machine: *Machine) bool {
        return switch (this.*) {
            .none, .tts, .serial_terminal, .signaler, .gps, .light, .env_sensor => false,
            .vga => this.vga.requiresWorker(slot, machine),
        };
    }

    pub inline fn update(this: *Device, slot: u8, machine: *Machine, delta_us: u32) void {
        switch (this.*) {
            .none, .tts, .serial_terminal, .signaler, .gps, .light, .env_sensor => {},
            .vga => this.vga.update(slot, machine, delta_us),
        }
    }

    pub inline fn mmioRead(this: *Device, slot: u8, machine: *Machine, offset: usize) ?u8 {
        return switch (this.*) {
            .none => return null,
            .tts => return this.tts.mmioRead(slot, machine, offset),
            .serial_terminal => return this.serial_terminal.mmioRead(slot, machine, offset),
            .signaler => return this.signaler.mmioRead(slot, machine, offset),
            .gps => return this.gps.mmioRead(slot, machine, offset),
            .light => return this.light.mmioRead(slot, machine, offset),
            .env_sensor => return this.env_sensor.mmioRead(slot, machine, offset),
            .vga => return this.vga.mmioRead(slot, machine, offset),
        };
    }

    pub inline fn mmioWrite(this: *Device, slot: u8, machine: *Machine, offset: usize, value: u8) bool {
        return switch (this.*) {
            .none, .gps => return false,
            .tts => return this.tts.mmioWrite(slot, machine, offset, value),
            .serial_terminal => return this.serial_terminal.mmioWrite(slot, machine, offset, value),
            .signaler => return this.signaler.mmioWrite(slot, machine, offset, value),
            .light => return this.light.mmioWrite(slot, machine, offset, value),
            .env_sensor => return this.env_sensor.mmioWrite(slot, machine, offset, value),
            .vga => return this.vga.mmioWrite(slot, machine, offset, value),
        };
    }

    pub inline fn executeDma(this: *Device, slot: u8, machine: *Machine, cfg: sdk.Dma.Config) bool {
        return switch (this.*) {
            .none, .signaler, .gps, .light, .env_sensor => return false,
            .tts => return this.tts.executeDma(slot, machine, cfg),
            .serial_terminal => return this.serial_terminal.executeDma(slot, machine, cfg),
            .vga => return this.vga.executeDma(slot, machine, cfg),
        };
    }

    pub inline fn syscall(this: *Device, slot: u8, machine: *Machine, args: []const x.ByondValue) x.ByondValue {
        return switch (this.*) {
            .none, .gps => return x.ByondValue{},
            .tts => return this.tts.syscall(slot, machine, args),
            .serial_terminal => return this.serial_terminal.syscall(slot, machine, args),
            .signaler => return this.signaler.syscall(slot, machine, args),
            .light => return this.light.syscall(slot, machine, args),
            .env_sensor => return this.env_sensor.syscall(slot, machine, args),
            .vga => return this.vga.syscall(slot, machine, args),
        };
    }

    pub inline fn isInterruptPending(this: *Device, slot: u8, machine: *Machine) bool {
        return switch (this.*) {
            .none, .gps => return false,
            .tts => return this.tts.isInterruptPending(slot, machine),
            .serial_terminal => return this.serial_terminal.isInterruptPending(slot, machine),
            .signaler => return this.signaler.isInterruptPending(slot, machine),
            .light => return this.light.isInterruptPending(slot, machine),
            .env_sensor => return this.env_sensor.isInterruptPending(slot, machine),
            .vga => return this.vga.isInterruptPending(slot, machine),
        };
    }

    pub inline fn mmioSize(this: *const Device) usize {
        return switch (this.*) {
            .none => return 0,
            .tts => return @sizeOf(sdk.Tts),
            .serial_terminal => return @sizeOf(sdk.SerialTerminal),
            .signaler => return @sizeOf(sdk.Signaler),
            .gps => return @sizeOf(sdk.Gps),
            .light => return @sizeOf(sdk.Light),
            .env_sensor => return @sizeOf(sdk.EnvSensor),
            .vga => return @sizeOf(sdk.Vga),
        };
    }

    pub inline fn sdkType(this: *const Device) sdk.Pci.DeviceType {
        return switch (this.*) {
            .none => .none,
            .tts => .tts,
            .serial_terminal => .serial_terminal,
            .signaler => .signaler,
            .gps => .gps,
            .light => .light,
            .env_sensor => .env_sensor,
            .vga => .vga,
        };
    }

    pub inline fn reset(this: *Device) void {
        switch (this.*) {
            .none, .gps => {},
            .tts => this.tts.reset(),
            .serial_terminal => this.serial_terminal.reset(),
            .signaler => this.signaler.reset(),
            .light => this.light.reset(),
            .env_sensor => this.env_sensor.reset(),
            .vga => this.vga.reset(),
        }
    }

    pub inline fn deinit(this: *Device, allocator: std.mem.Allocator) void {
        switch (this.*) {
            .none, .tts, .signaler, .gps, .light, .env_sensor => {},
            .serial_terminal => this.serial_terminal.deinit(allocator),
            .vga => this.vga.deinit(allocator),
        }
    }
};

const Pci = struct {
    mmio: sdk.Pci = .{},
    devices: [sdk.Pci.MAX_DEVICES]Device = .{.none} ** sdk.Pci.MAX_DEVICES,

    pub inline fn reset(this: *Pci) void {
        for (&this.devices) |*device| {
            device.reset();
        }
    }

    pub inline fn deinit(this: *Pci, allocator: std.mem.Allocator) void {
        for (&this.devices) |*device| {
            device.deinit(allocator);
        }
    }
};

const Machine = struct {
    pub const Id = usize;

    pub const State = enum(u8) {
        stopped = 1,
        running = 2,
    };

    pub const Cpu = ondatra.cpu.Cpu(.{
        .compile = .fast_compile,
        .runtime = .{
            .enable_pmp_m = false,
            .csr_write_access = .{
                .counters = false,
            },
        },
        .hooks = .{
            .write = mmioWrite,
            .read = mmioRead,
            .instruction_cost = instructionCost,
        },
        .vars = .{
            .ram_start = 0x8000_0000,
        },
    });

    id: Id,
    cpu: Cpu,
    src: x.ByondValue,
    state: Machine.State = .stopped,
    frequency: u32 = DEFAULT_FREQUENCY,
    utilization: f32 = 0.0,
    executed: u64 = 0,
    idle_executed: u64 = 0,
    overshoot: u64 = 0,
    debt: u64 = 0,
    prng: std.Random.DefaultPrng,
    dma: sdk.Dma = .{},
    post_tick_proc: ?u32 = null,
    trap_proc: ?u32 = null,
    syscall_proc: ?u32 = null,
    free_ram_start: u32 = 0,
    pci: Pci = .{},
    sensors: sdk.Sensors = .{},
    power: sdk.Power = .{},
    clint: sdk.Clint = .{},
    rtc: sdk.Rtc = .{},
    // Lock for the pci and the machine itself.
    lock: std.Thread.Mutex = .{},

    pub inline fn init(id: Machine.Id, src: x.ByondValue) Machine {
        const ram: []u8 = &.{};

        var prng_seed: u64 = 0;
        std.posix.getrandom(std.mem.asBytes(&prng_seed)) catch {};

        return .{
            .id = id,
            .cpu = .init(ram),
            .prng = .init(prng_seed),
            .src = src,
        };
    }

    pub inline fn reset(this: *Machine) void {
        @memset(this.cpu.ram, 0);
        this.cpu.registers = .{};
        this.utilization = 0.0;
        this.executed = 0;
        this.idle_executed = 0;
        this.overshoot = 0;
        this.debt = 0;
        this.dma = .{};
        this.sensors = .{};
        this.power = .{};
        this.clint = .{};
        this.rtc = .{};
    }

    pub inline fn deinit(this: *Machine, allocator: std.mem.Allocator) void {
        allocator.free(this.cpu.ram);
        this.cpu.ram = &.{};

        if (x.ByondValue_IsNull(&this.src)) {
            x.ByondValue_DecRef(&this.src);
            this.src = .{};
        }

        this.post_tick_proc = null;
        this.trap_proc = null;
        this.syscall_proc = null;
        this.pci.deinit(allocator);
        this.pci = .{};
    }

    pub inline fn loadElf(this: *Machine, allocator: std.mem.Allocator, content: []const u8) Cpu.ElfLoadError!void {
        this.free_ram_start = try this.cpu.loadElf(allocator, content) + sdk.Memory.RAM_START;
    }

    pub inline fn cycleBudget(this: *const Machine, delta_us: u32) u64 {
        return @as(u64, this.frequency) * @as(u64, delta_us) / 1_000_000;
    }

    pub inline fn isRunnable(this: *const Machine) bool {
        return this.state == .running and this.cpu.ram.len > 0 and this.frequency > 0;
    }

    pub inline fn tryCallPostTickProc(this: *const Machine, delta_us: u32) void {
        const proc = this.post_tick_proc orelse return;

        var ret: x.ByondValue = .{};
        _ = x.Byond_CallProcByStrId(&this.src, proc, &.{x.num(delta_us)}, &ret);
    }

    pub inline fn tryCallTrapProc(this: *const Machine) void {
        const proc = this.trap_proc orelse return;

        var ret: x.ByondValue = .{};
        _ = x.Byond_CallProcByStrId(&this.src, proc, &.{}, &ret);
    }

    pub inline fn tryCallSyscallProc(this: *const Machine, args: []const x.ByondValue) bool {
        const proc = this.syscall_proc orelse return false;

        var ret: x.ByondValue = .{};
        if (!x.Byond_CallProcByStrId(&this.src, proc, args, &ret)) {
            return false;
        }

        return x.ByondValue_IsTrue(&ret);
    }

    pub inline fn syscall(this: *Machine, slot: u8, args: []const x.ByondValue) MachineSyscallError!x.ByondValue {
        if (slot >= sdk.Pci.MAX_DEVICES or this.pci.devices[slot] == .none) {
            return MachineSyscallError.SlotNotFound;
        }

        const entry = &this.pci.devices[slot];

        return entry.syscall(slot, this, args);
    }

    pub inline fn tryAttachPci(this: *Machine, device: Device) ?u8 {
        const mmio_size = device.mmioSize();
        const alignment = std.mem.Alignment.of(u32);

        // Lock for the pci.
        this.lock.lock();
        defer this.lock.unlock();

        // Find a free slot
        var free_slot: ?usize = null;
        for (this.pci.devices, 0..) |entry, idx| {
            if (entry == .none) {
                free_slot = idx;

                break;
            }
        }

        const slot_idx = free_slot orelse return null;

        // Find a non-overlapping memory region in [PCI_DEVICES, RAM_START)
        var addr: usize = alignment.forward(sdk.Memory.PCI_DEVICES);

        restart: while (addr + mmio_size <= sdk.Memory.RAM_START) {
            for (this.pci.mmio._status.entries) |entry| {
                if (entry.ty == .none) {
                    continue;
                }

                const occ_end = entry.address + entry.len;

                // [addr, addr+mmio_size) overlaps [occupied.address, occ_end)?
                if (addr < occ_end and addr + mmio_size > entry.address) {
                    addr = alignment.forward(occ_end);

                    continue :restart;
                }
            }

            // No overlap with any existing device — place here
            this.pci.mmio._status.entries[slot_idx] = .{
                .address = addr,
                .len = mmio_size,
                .ty = device.sdkType(),
            };
            this.pci.devices[slot_idx] = device;
            this.pci.mmio._status.devices_count += 1;

            this.pci.mmio._status.last_event = .{
                .ty = .connected,
                .slot = @intCast(slot_idx),
                .device_type = device.sdkType(),
            };
            this.updateExternalInterrupts();

            return @intCast(slot_idx);
        }

        // No room before RAM_START
        return null;
    }

    pub inline fn tryDetachPci(this: *Machine, slot: u8) bool {
        // Lock for the pci.
        this.lock.lock();
        defer this.lock.unlock();

        if (slot >= sdk.Pci.MAX_DEVICES) {
            return false;
        }

        const device = &this.pci.devices[slot];
        const entry = &this.pci.mmio._status.entries[slot];
        const was_removed = device.* != .none;

        if (was_removed) {
            this.pci.mmio._status.devices_count -= 1;
            this.pci.mmio._status.last_event = .{
                .ty = .disconnected,
                .slot = slot,
                .device_type = device.sdkType(),
            };
            this.updateExternalInterrupts();
        }

        device.* = .none;
        entry.* = .{};

        return was_removed;
    }

    pub inline fn skipToTimer(this: *Machine, remaining: u64) u64 {
        if (this.cpu.registers.mie.mtie and
            this.cpu.registers.mtimecmp > this.cpu.registers.mtime)
        {
            const to_irq = this.cpu.registers.mtimecmp - this.cpu.registers.mtime;
            const skip = @min(to_irq, remaining);
            this.cpu.registers.updateTimer(skip);

            return skip;
        } else {
            this.cpu.registers.updateTimer(remaining);

            return remaining;
        }
    }

    pub inline fn updateExternalInterrupts(this: *Machine) void {
        var has_external_interrupt = false;
        defer this.cpu.registers.mip.meip = has_external_interrupt;

        if (this.clint._config.interrupts.on_sync_pulse and this.clint._status.last_event.ty == .sync) {
            has_external_interrupt = true;

            return;
        }

        if (this.pci.mmio._config.interrupts.on_connected and this.pci.mmio._status.last_event.ty == .connected) {
            has_external_interrupt = true;

            return;
        }

        if (this.pci.mmio._config.interrupts.on_disconnected and this.pci.mmio._status.last_event.ty == .disconnected) {
            has_external_interrupt = true;

            return;
        }

        if (this.rtc._config.interrupts.on_interval and this.rtc._status.last_event.ty == .interval) {
            has_external_interrupt = true;

            return;
        }

        if (this.rtc._config.interrupts.on_alarm and this.rtc._status.last_event.ty == .alarm) {
            has_external_interrupt = true;

            return;
        }

        for (&this.pci.devices, 0..) |*device, slot| {
            if (device.isInterruptPending(@intCast(slot), this)) {
                has_external_interrupt = true;

                return;
            }
        }
    }

    inline fn updateRtc(this: *Machine, timestamp: u64) void {
        this.rtc._status.timestamp = timestamp;

        if (this.rtc._config.interval == 0) {
            this.rtc._status.prev_interval_at = timestamp;
        } else {
            const prev_interval_at: u64 = this.rtc._status.prev_interval_at;
            const over_interval = switch (this.rtc._config.unit) {
                .seconds => timestamp - prev_interval_at >= this.rtc._config.interval,
                .minutes => timestamp - prev_interval_at >= this.rtc._config.interval * 60,
                .hours => timestamp - prev_interval_at >= this.rtc._config.interval * 3600,
                _ => false,
            };

            if (over_interval) {
                this.rtc._status.prev_interval_at = @truncate(timestamp);
                this.rtc._status.last_event = .{ .ty = .interval };
            }
        }

        if (this.rtc._config.alarm != 0 and timestamp >= this.rtc._config.alarm) {
            this.rtc._status.last_event = .{ .ty = .alarm };
        }
    }

    inline fn updatePci(this: *Machine, delta_us: u32) void {
        for (&this.pci.devices, 0..) |*device, slot| {
            device.update(@intCast(slot), this, delta_us);
        }
    }

    // Caller should lock the machine.
    inline fn requiresWorker(this: *Machine) bool {
        for (&this.pci.devices, 0..) |*device, slot| {
            if (device.requiresWorker(@intCast(slot), this)) {
                return true;
            }
        }

        return false;
    }

    inline fn mmioRead(ctx: *anyopaque, address: u32) ?u8 {
        const cpu: *Cpu = @ptrCast(@alignCast(ctx));
        const this: *Machine = @fieldParentPtr("cpu", cpu);

        if (address >= sdk.Memory.BOOT_INFO and address < sdk.Memory.BOOT_INFO + @sizeOf(sdk.BootInfo)) {
            const offset = address - sdk.Memory.BOOT_INFO;
            const boot_info: sdk.BootInfo = .{
                .cpu_frequency = this.frequency,
                .free_ram_start = this.free_ram_start,
                .ram_size = this.cpu.ram.len,
            };

            return std.mem.asBytes(&boot_info)[offset];
        } else if (address >= sdk.Memory.SENSORS and address < sdk.Memory.SENSORS + @sizeOf(sdk.Sensors)) {
            const offset = address - sdk.Memory.SENSORS;
            const bytes = std.mem.asBytes(&this.sensors);

            return bytes[offset];
        } else if (address >= sdk.Memory.POWER and address < sdk.Memory.POWER + @sizeOf(sdk.Power)) {
            const offset = address - sdk.Memory.POWER;
            const bytes = std.mem.asBytes(&this.power);

            return bytes[offset];
        } else if (address >= sdk.Memory.RTC and address < sdk.Memory.RTC + @sizeOf(sdk.Rtc)) {
            const offset = address - sdk.Memory.RTC;

            return this.readRtc(offset);
        } else if (address >= sdk.Memory.CLINT and address < sdk.Memory.CLINT + @sizeOf(sdk.Clint)) {
            const offset = address - sdk.Memory.CLINT;

            return this.readClint(offset);
        } else if (address >= sdk.Memory.PRNG and address < sdk.Memory.PRNG + @sizeOf(sdk.Prng)) {
            const offset = address - sdk.Memory.PRNG;

            return this.readPrng(offset);
        } else if (address >= sdk.Memory.DMA and address < sdk.Memory.DMA + @sizeOf(sdk.Dma)) {
            const offset = address - sdk.Memory.DMA;

            return this.readDma(offset);
        } else if (address >= sdk.Memory.PCI and address < sdk.Memory.PCI + @sizeOf(sdk.Pci)) {
            const offset = address - sdk.Memory.PCI;

            return this.readPci(offset);
        } else if (address >= sdk.Memory.PCI_DEVICES) {
            for (&this.pci.mmio._status.entries, 0..) |*entry, slot| {
                if (entry.ty == .none) {
                    continue;
                }

                if (address >= entry.address and address < entry.address + entry.len) {
                    return this.pci.devices[slot].mmioRead(@intCast(slot), this, address - entry.address);
                }
            }

            return null;
        }

        return null;
    }

    inline fn readRtc(this: *Machine, offset: u32) ?u8 {
        return genericMmioRead(&this.rtc, offset, sdk.Rtc);
    }

    inline fn readClint(this: *Machine, offset: u32) ?u8 {
        switch (offset) {
            @offsetOf(sdk.Clint, "_config")...(@offsetOf(sdk.Clint, "_config") + sizeOfField(sdk.Clint, "_config") - 1) => {
                const rel_offset = offset - @offsetOf(sdk.Clint, "_config");

                switch (rel_offset) {
                    @offsetOf(sdk.Clint.Config, "mtime")...(@offsetOf(sdk.Clint.Config, "mtime") + sizeOfField(sdk.Clint.Config, "mtime") - 1) => {
                        const byte = rel_offset - @offsetOf(sdk.Clint.Config, "mtime");
                        const bytes = std.mem.asBytes(&this.cpu.registers.mtime);

                        return bytes[byte];
                    },
                    @offsetOf(sdk.Clint.Config, "mtimecmp")...(@offsetOf(sdk.Clint.Config, "mtimecmp") + sizeOfField(sdk.Clint.Config, "mtimecmp") - 1) => {
                        const byte = rel_offset - @offsetOf(sdk.Clint.Config, "mtimecmp");
                        const bytes = std.mem.asBytes(&this.cpu.registers.mtimecmp);

                        return bytes[byte];
                    },
                    @offsetOf(sdk.Clint.Config, "interrupts")...(@offsetOf(sdk.Clint.Config, "interrupts") + sizeOfField(sdk.Clint.Config, "interrupts") - 1) => {
                        const byte = rel_offset - @offsetOf(sdk.Clint.Config, "interrupts");
                        const bytes = std.mem.asBytes(&this.clint._config.interrupts);

                        return bytes[byte];
                    },
                    else => return null,
                }
            },
            @offsetOf(sdk.Clint, "_status")...(@offsetOf(sdk.Clint, "_status") + sizeOfField(sdk.Clint, "_status") - 1) => {
                const byte = offset - @offsetOf(sdk.Clint, "_status");
                const bytes = std.mem.asBytes(&this.clint._status);

                return bytes[byte];
            },
            else => return null,
        }
    }

    inline fn readPrng(this: *Machine, offset: u32) ?u8 {
        switch (offset) {
            @offsetOf(sdk.Prng, "_status")...(@offsetOf(sdk.Prng, "_status") + sizeOfField(sdk.Prng, "_status") - 1) => {
                return @truncate(this.prng.next());
            },
            else => return null,
        }
    }

    inline fn readDma(this: *Machine, offset: u32) ?u8 {
        switch (offset) {
            @offsetOf(sdk.Dma, "_config")...(@offsetOf(sdk.Dma, "_config") + sizeOfField(sdk.Dma, "_config") - 1) => {
                const rel_offset = offset - @offsetOf(sdk.Dma, "_config");
                const bytes = std.mem.asBytes(&this.dma._config);

                return bytes[rel_offset];
            },
            else => return null,
        }
    }

    inline fn readPci(this: *Machine, offset: u32) ?u8 {
        switch (offset) {
            @offsetOf(sdk.Pci, "_config")...(@offsetOf(sdk.Pci, "_config") + sizeOfField(sdk.Pci, "_config") - 1) => {
                const rel_offset = offset - @offsetOf(sdk.Pci, "_config");
                const bytes = std.mem.asBytes(&this.pci.mmio._config);

                return bytes[rel_offset];
            },
            @offsetOf(sdk.Pci, "_status")...(@offsetOf(sdk.Pci, "_status") + sizeOfField(sdk.Pci, "_status") - 1) => {
                const rel_offset = offset - @offsetOf(sdk.Pci, "_status");
                const bytes = std.mem.asBytes(&this.pci.mmio._status);

                return bytes[rel_offset];
            },
            else => return null,
        }
    }

    inline fn mmioWrite(ctx: *anyopaque, address: u32, value: u8) bool {
        const cpu: *Cpu = @ptrCast(@alignCast(ctx));
        const this: *Machine = @fieldParentPtr("cpu", cpu);

        if (address >= sdk.Memory.RTC and address < sdk.Memory.RTC + @sizeOf(sdk.Rtc)) {
            const offset = address - sdk.Memory.RTC;

            return this.writeRtc(offset, value);
        } else if (address >= sdk.Memory.CLINT and address < sdk.Memory.CLINT + @sizeOf(sdk.Clint)) {
            const offset = address - sdk.Memory.CLINT;

            return this.writeClint(offset, value);
        } else if (address >= sdk.Memory.DMA and address < sdk.Memory.DMA + @sizeOf(sdk.Dma)) {
            const offset = address - sdk.Memory.DMA;

            return this.writeDma(offset, value);
        } else if (address >= sdk.Memory.PCI and address < sdk.Memory.PCI + @sizeOf(sdk.Pci)) {
            const offset = address - sdk.Memory.PCI;

            return this.writePci(offset, value);
        } else if (address >= sdk.Memory.PCI_DEVICES) {
            for (&this.pci.mmio._status.entries, 0..) |*entry, slot| {
                if (entry.ty == .none) {
                    continue;
                }

                if (address >= entry.address and address < entry.address + entry.len) {
                    return this.pci.devices[slot].mmioWrite(@intCast(slot), this, address - entry.address, value);
                }
            }

            return false;
        }

        return false;
    }

    inline fn writeRtc(this: *Machine, offset: u32, value: u8) bool {
        switch (offset) {
            @offsetOf(sdk.Rtc, "_config")...(@offsetOf(sdk.Rtc, "_config") + sizeOfField(sdk.Rtc, "_config") - 1) => {
                const rel_offset = offset - @offsetOf(sdk.Rtc, "_config");
                const bytes = std.mem.asBytes(&this.rtc._config);

                bytes[rel_offset] = value;
                this.updateExternalInterrupts();

                return true;
            },
            @offsetOf(sdk.Rtc, "_action")...(@offsetOf(sdk.Rtc, "_action") + sizeOfField(sdk.Rtc, "_action") - 1) => {
                const rel_offset = offset - @offsetOf(sdk.Rtc, "_action");

                switch (rel_offset) {
                    @offsetOf(sdk.Rtc.Action, "ack") => {
                        this.rtc._status.last_event = .{};
                        this.updateExternalInterrupts();

                        return true;
                    },
                    else => return false,
                }
            },
            else => return false,
        }
    }

    inline fn writeClint(this: *Machine, offset: u32, value: u8) bool {
        switch (offset) {
            @offsetOf(sdk.Clint, "_config")...(@offsetOf(sdk.Clint, "_config") + sizeOfField(sdk.Clint, "_config") - 1) => {
                const rel_offset = offset - @offsetOf(sdk.Clint, "_config");

                switch (rel_offset) {
                    @offsetOf(sdk.Clint.Config, "mtime")...(@offsetOf(sdk.Clint.Config, "mtime") + sizeOfField(sdk.Clint.Config, "mtime") - 1) => {
                        const byte = rel_offset - @offsetOf(sdk.Clint.Config, "mtime");
                        const bytes = std.mem.asBytes(&this.cpu.registers.mtime);

                        bytes[byte] = value;
                        this.cpu.registers.setMtime(this.cpu.registers.mtime);

                        return true;
                    },
                    @offsetOf(sdk.Clint.Config, "mtimecmp")...(@offsetOf(sdk.Clint.Config, "mtimecmp") + sizeOfField(sdk.Clint.Config, "mtimecmp") - 1) => {
                        const byte = rel_offset - @offsetOf(sdk.Clint.Config, "mtimecmp");
                        const bytes = std.mem.asBytes(&this.cpu.registers.mtimecmp);

                        bytes[byte] = value;
                        this.cpu.registers.setMtimecmp(this.cpu.registers.mtimecmp);

                        return true;
                    },
                    @offsetOf(sdk.Clint.Config, "interrupts")...(@offsetOf(sdk.Clint.Config, "interrupts") + sizeOfField(sdk.Clint.Config, "interrupts") - 1) => {
                        const byte = rel_offset - @offsetOf(sdk.Clint.Config, "interrupts");
                        const bytes = std.mem.asBytes(&this.clint._config.interrupts);

                        bytes[byte] = value;
                        this.updateExternalInterrupts();

                        return true;
                    },
                    else => return false,
                }
            },
            @offsetOf(sdk.Clint, "_action")...(@offsetOf(sdk.Clint, "_action") + sizeOfField(sdk.Clint, "_action") - 1) => {
                const rel_offset = offset - @offsetOf(sdk.Clint, "_action");

                switch (rel_offset) {
                    @offsetOf(sdk.Clint.Action, "ack") => {
                        this.clint._status.last_event = .{};
                        this.updateExternalInterrupts();

                        return true;
                    },
                    else => return false,
                }
            },
            else => return false,
        }
    }

    inline fn writeDma(this: *Machine, offset: u32, value: u8) bool {
        switch (offset) {
            @offsetOf(sdk.Dma, "_config")...(@offsetOf(sdk.Dma, "_config") + sizeOfField(sdk.Dma, "_config") - 1) => {
                const rel_offset = offset - @offsetOf(sdk.Dma, "_config");
                const bytes = std.mem.asBytes(&this.dma._config);

                bytes[rel_offset] = value;

                return true;
            },
            @offsetOf(sdk.Dma, "_action")...(@offsetOf(sdk.Dma, "_action") + sizeOfField(sdk.Dma, "_action") - 1) => {
                const rel_offset = offset - @offsetOf(sdk.Dma, "_action");

                switch (rel_offset) {
                    @offsetOf(sdk.Dma.Action, "execute") => {
                        return this.executeDma();
                    },
                    else => return false,
                }
            },
            else => return false,
        }
    }

    inline fn writePci(this: *Machine, offset: u32, value: u8) bool {
        switch (offset) {
            @offsetOf(sdk.Pci, "_config")...(@offsetOf(sdk.Pci, "_config") + sizeOfField(sdk.Pci, "_config") - 1) => {
                const rel_offset = offset - @offsetOf(sdk.Pci, "_config");
                const bytes = std.mem.asBytes(&this.pci.mmio._config);

                bytes[rel_offset] = value;
                this.updateExternalInterrupts();

                return true;
            },
            @offsetOf(sdk.Pci, "_action")...(@offsetOf(sdk.Pci, "_action") + sizeOfField(sdk.Pci, "_action") - 1) => {
                const rel_offset = offset - @offsetOf(sdk.Pci, "_action");

                switch (rel_offset) {
                    @offsetOf(sdk.Pci.Action, "ack") => {
                        this.pci.mmio._status.last_event = .{};
                        this.updateExternalInterrupts();

                        return true;
                    },
                    else => return false,
                }
            },
            else => return false,
        }
    }

    inline fn executeDma(this: *Machine) bool {
        switch (this.dma._config.mode) {
            .fill => {
                if (this.dma._config.pattern_len == 0) {
                    return true;
                }
            },
            .read, .write => {
                if (this.dma._config.len == 0) {
                    return true;
                }
            },
            else => return false,
        }

        if (this.dma._config.channel >= sdk.Pci.MAX_DEVICES) {
            return false;
        }

        const device = &this.pci.devices[this.dma._config.channel];

        if (device.* == .none) {
            return false;
        }

        return device.executeDma(this.dma._config.channel, this, this.dma._config);
    }

    inline fn instructionCost(instruction: ondatra.arch.Instruction) usize {
        return switch (instruction) {
            .add, .sub, .@"and", .@"or", .xor, .xori, .slt, .sltu, .sltiu => return 1,
            .addi, .andi, .ori, .slti => return 1,
            .sll, .srl, .sra, .slli, .srli, .srai => return 1,
            .lui, .auipc => return 1,
            .beq, .bne, .blt, .bltu, .bge, .bgeu, .jal, .jalr => return 2,
            .lw, .lh, .lb, .lhu, .lbu => return 3,
            .sw, .sh, .sb => return 2,
            .mul, .mulh, .mulhu, .mulhsu => return 3,
            .div, .divu, .rem, .remu => 8,
            .fadd_s, .fsub_s, .fmul_s => return 4,
            .fdiv_s => return 10,
            .fsqrt_s => return 15,
            .fcvt_s_w, .fcvt_s_wu, .fcvt_w_s, .fcvt_wu_s, .fmv_w_x, .fmv_x_w => return 3,
            .flt_s, .fle_s, .feq_s, .fmin_s, .fmax_s => return 2,
            .fsgnj_s, .fsgnjn_s, .fsgnjx_s => return 1,
            .fclass_s => return 1,
            .flw => return 3,
            .fsw => return 2,
            .fmadd_s, .fmsub_s, .fnmsub_s, .fnmadd_s => return 5,
            .clz, .ctz, .cpop => return 1,
            .andn, .orn, .xnor => return 1,
            .max, .maxu, .min, .minu => return 1,
            .sext_b, .sext_h, .zext_h => return 1,
            .rol, .ror, .rori => return 1,
            .orc_b, .rev8 => return 1,
            .sh1add, .sh2add, .sh3add => return 1,
            .csrrw, .csrrs, .csrrc, .csrrwi, .csrrsi, .csrrci => return 2,
            .fence, .ecall, .ebreak, .wfi, .fence_i, .mret => return 1,
        };
    }
};

const MachineCreationError = error{
    OutOfId,
    OutOfMemory,
    BadSrc,
};

const MachineResetError = error{
    MachineNotFound,
};

const MachineConnectError = error{
    MachineNotFound,
};

const MachineSetRamSizeError = error{
    MachineNotFound,
    OutOfRam,
};

const MachineGetRamSizeError = error{
    MachineNotFound,
};

const MachineReadRamError = error{
    MachineNotFound,
    OutOfBounds,
};

const MachineWriteRamError = error{
    MachineNotFound,
    OutOfBounds,
};

const MachineSetFrequencyError = error{
    MachineNotFound,
};

const MachineSetStateError = error{
    MachineNotFound,
    BadState,
};

const MachineGetStateError = error{
    MachineNotFound,
};

const MachineGetUtilizationError = error{
    MachineNotFound,
};

const MachineGetExecutedError = error{
    MachineNotFound,
};

const MachineSetSensorsError = error{
    MachineNotFound,
};

const MachineSetPowerError = error{
    MachineNotFound,
};

const MachineSetShiftIdError = error{
    MachineNotFound,
};

const MachineSetProcError = error{
    MachineNotFound,
};

const MachineLoadElfError = error{
    MachineNotFound,
    FileNotFound,
    FileTooBig,
    OutOfMemory,
    OutOfRam,
    BadElf,
    Unknown,
};

const MachineSyscallError = error{
    MachineNotFound,
    SlotNotFound,
};

const MachineAttachPciError = error{
    MachineNotFound,
    BadDeviceType,
    OutOfMemory,
};

const MachineDetachPciError = error{
    MachineNotFound,
};

const MachineAppendCountersError = error{
    MachineNotFound,
};

const MachineDumpRegistersError = error{
    MachineNotFound,
    OutOfMemory,
};

pub const State = struct {
    pub const Stats = struct {
        last_wall_us: u64 = 0,
        last_budget_us: u64 = 0,
        load_avg: f32 = 0.0,
    };

    allocator: std.mem.Allocator,
    next_id: Machine.Id = 1,
    machines: std.ArrayList(Machine) = .empty,
    robin_index: usize = 0,
    budget_percent: usize = 40,
    stats: Stats = .{},
    wg: std.Thread.WaitGroup = .{},

    pub inline fn init(allocator: std.mem.Allocator) State {
        return .{
            .allocator = allocator,
        };
    }

    pub inline fn deinit(this: *State) void {
        // Wait for all the workers to finish with the machines.
        this.wg.wait();

        for (this.machines.items) |*machine| {
            machine.deinit(this.allocator);
        }

        this.machines.deinit(this.allocator);
    }

    pub inline fn machineCreate(this: *State, src: x.ByondValue) MachineCreationError!Machine.Id {
        if (x.ByondValue_IsNull(&src)) {
            z.getState().last_error = @errorName(MachineCreationError.BadSrc);

            return MachineCreationError.BadSrc;
        }

        if (this.next_id == std.math.maxInt(Machine.Id)) {
            z.getState().last_error = @errorName(MachineCreationError.OutOfId);

            return MachineCreationError.OutOfId;
        }

        const machine: Machine = .init(this.next_id, src);

        this.machines.append(this.allocator, machine) catch {
            z.getState().last_error = @errorName(MachineCreationError.OutOfMemory);

            return MachineCreationError.OutOfMemory;
        };
        this.next_id += 1;

        return machine.id;
    }

    pub inline fn machineReset(this: *State, id: Machine.Id) MachineResetError!void {
        const machine = this.findMachine(id) orelse {
            z.getState().last_error = @errorName(MachineConnectError.MachineNotFound);

            return MachineConnectError.MachineNotFound;
        };

        machine.reset();
    }

    pub inline fn machineSetRamSize(this: *State, id: Machine.Id, ram_size: u32) MachineSetRamSizeError!void {
        const machine = this.findMachine(id) orelse {
            z.getState().last_error = @errorName(MachineSetRamSizeError.MachineNotFound);

            return MachineSetRamSizeError.MachineNotFound;
        };

        const new_ram = this.allocator.alloc(u8, ram_size) catch {
            z.getState().last_error = @errorName(MachineSetRamSizeError.OutOfRam);

            return MachineSetRamSizeError.OutOfRam;
        };
        this.allocator.free(machine.cpu.ram);

        machine.cpu.ram = new_ram;
    }

    pub inline fn machineGetRamSize(this: *State, id: Machine.Id) MachineGetRamSizeError!u32 {
        const machine = this.findMachine(id) orelse {
            z.getState().last_error = @errorName(MachineGetRamSizeError.MachineNotFound);

            return MachineGetRamSizeError.MachineNotFound;
        };

        return machine.cpu.ram.len;
    }

    pub inline fn machineReadRamByte(this: *State, id: Machine.Id, address: u32) MachineReadRamError!u8 {
        const machine = this.findMachine(id) orelse {
            z.getState().last_error = @errorName(MachineReadRamError.MachineNotFound);

            return MachineReadRamError.MachineNotFound;
        };

        if (address >= machine.cpu.ram.len) {
            z.getState().last_error = @errorName(MachineReadRamError.OutOfBounds);

            return MachineReadRamError.OutOfBounds;
        }

        return machine.cpu.ram[address];
    }

    pub inline fn machineWriteRamByte(this: *State, id: Machine.Id, address: u32, value: u8) MachineWriteRamError!void {
        const machine = this.findMachine(id) orelse {
            z.getState().last_error = @errorName(MachineWriteRamError.MachineNotFound);

            return MachineWriteRamError.MachineNotFound;
        };

        if (address >= machine.cpu.ram.len) {
            z.getState().last_error = @errorName(MachineWriteRamError.OutOfBounds);

            return MachineWriteRamError.OutOfBounds;
        }

        machine.cpu.ram[address] = value;
    }

    pub inline fn machineReadRamBytes(this: *State, id: Machine.Id, address: u32, dst: *const x.ByondValue) MachineReadRamError!void {
        const machine = this.findMachine(id) orelse {
            z.getState().last_error = @errorName(MachineReadRamError.MachineNotFound);

            return MachineReadRamError.MachineNotFound;
        };

        var byond_len: x.ByondValue = .{};
        if (!x.Byond_Length(dst, &byond_len)) {
            z.getState().last_error = @errorName(MachineReadRamError.OutOfBounds);

            return MachineReadRamError.OutOfBounds;
        }

        const len: u32 = @intFromFloat(x.ByondValue_GetNum(&byond_len));

        if (address +| len > machine.cpu.ram.len) {
            z.getState().last_error = @errorName(MachineReadRamError.OutOfBounds);

            return MachineReadRamError.OutOfBounds;
        }

        for (0..len) |idx| {
            if (!x.Byond_WriteListIndex(dst, &x.num(idx + 1), &x.num(machine.cpu.ram[address + idx]))) {
                z.getState().last_error = @errorName(MachineReadRamError.OutOfBounds);

                return MachineReadRamError.OutOfBounds;
            }
        }
    }

    pub inline fn machineWriteRamBytes(this: *State, id: Machine.Id, address: u32, src: *const x.ByondValue) MachineWriteRamError!void {
        const machine = this.findMachine(id) orelse {
            z.getState().last_error = @errorName(MachineWriteRamError.MachineNotFound);

            return MachineWriteRamError.MachineNotFound;
        };

        var byond_len: x.ByondValue = .{};
        if (!x.Byond_Length(src, &byond_len)) {
            z.getState().last_error = @errorName(MachineReadRamError.OutOfBounds);

            return MachineReadRamError.OutOfBounds;
        }

        const len: u32 = @intFromFloat(x.ByondValue_GetNum(&byond_len));

        if (address +| len > machine.cpu.ram.len) {
            z.getState().last_error = @errorName(MachineWriteRamError.OutOfBounds);

            return MachineWriteRamError.OutOfBounds;
        }

        for (0..len) |idx| {
            var byond_value: x.ByondValue = .{};

            if (!x.Byond_ReadListIndex(src, &x.num(idx + 1), &byond_value)) {
                z.getState().last_error = @errorName(MachineReadRamError.OutOfBounds);

                return MachineReadRamError.OutOfBounds;
            }

            const value: u32 = @intFromFloat(x.ByondValue_GetNum(&byond_value));

            machine.cpu.ram[address + idx] = @truncate(value);
        }
    }

    pub inline fn machineSetFrequency(this: *State, id: Machine.Id, frequency: u32) MachineSetFrequencyError!void {
        const machine = this.findMachine(id) orelse {
            z.getState().last_error = @errorName(MachineSetRamSizeError.MachineNotFound);

            return MachineSetRamSizeError.MachineNotFound;
        };

        machine.frequency = frequency;
    }

    pub inline fn machineSetState(this: *State, id: Machine.Id, state: u32) MachineSetStateError!void {
        const machine = this.findMachine(id) orelse {
            z.getState().last_error = @errorName(MachineSetRamSizeError.MachineNotFound);

            return MachineSetRamSizeError.MachineNotFound;
        };

        machine.state = std.enums.fromInt(Machine.State, state) orelse {
            z.getState().last_error = @errorName(MachineSetStateError.BadState);

            return MachineSetStateError.BadState;
        };
    }

    pub inline fn machineGetState(this: *State, id: Machine.Id) MachineGetStateError!Machine.State {
        const machine = this.findMachine(id) orelse {
            z.getState().last_error = @errorName(MachineSetRamSizeError.MachineNotFound);

            return MachineSetRamSizeError.MachineNotFound;
        };

        return machine.state;
    }

    pub inline fn machineGetUtilization(this: *State, id: Machine.Id) MachineGetUtilizationError!f32 {
        const machine = this.findMachine(id) orelse {
            z.getState().last_error = @errorName(MachineSetRamSizeError.MachineNotFound);

            return MachineSetRamSizeError.MachineNotFound;
        };

        return machine.utilization;
    }

    pub inline fn machineGetExecuted(this: *State, id: Machine.Id) MachineGetExecutedError!u64 {
        const machine = this.findMachine(id) orelse {
            z.getState().last_error = @errorName(MachineSetRamSizeError.MachineNotFound);

            return MachineSetRamSizeError.MachineNotFound;
        };

        return machine.executed;
    }

    pub inline fn machineSetSensors(this: *State, id: Machine.Id, temperature: i16, overheat: bool, throttled: bool) MachineSetSensorsError!void {
        const machine = this.findMachine(id) orelse {
            z.getState().last_error = @errorName(MachineSetRamSizeError.MachineNotFound);

            return MachineSetRamSizeError.MachineNotFound;
        };

        machine.sensors = .{
            .temperature = temperature,
            .flags = .{
                .overheat = overheat,
                .throttled = throttled,
            },
        };
    }

    pub inline fn machineSetPower(this: *State, id: Machine.Id, battery_charge: u32, has_external_source: bool) MachineSetPowerError!void {
        const machine = this.findMachine(id) orelse {
            z.getState().last_error = @errorName(MachineSetPowerError.MachineNotFound);

            return MachineSetPowerError.MachineNotFound;
        };

        machine.power = .{
            .battery_charge = battery_charge,
            .has_external_source = has_external_source,
        };
    }

    pub inline fn machineSetShiftId(this: *State, id: Machine.Id, shift_id: u32) MachineSetShiftIdError!void {
        const machine = this.findMachine(id) orelse {
            z.getState().last_error = @errorName(MachineSetShiftIdError.MachineNotFound);

            return MachineSetShiftIdError.MachineNotFound;
        };

        machine.rtc._status.shift_id = shift_id;
    }

    pub inline fn machineSetPostTickProc(this: *State, id: Machine.Id, proc_name_id: ?u32) MachineSetProcError!void {
        const machine = this.findMachine(id) orelse {
            z.getState().last_error = @errorName(MachineSetProcError.MachineNotFound);

            return MachineSetProcError.MachineNotFound;
        };

        machine.post_tick_proc = proc_name_id;
    }

    pub inline fn machineSetTrapProc(this: *State, id: Machine.Id, proc_name_id: ?u32) MachineSetProcError!void {
        const machine = this.findMachine(id) orelse {
            z.getState().last_error = @errorName(MachineSetProcError.MachineNotFound);

            return MachineSetProcError.MachineNotFound;
        };

        machine.trap_proc = proc_name_id;
    }

    pub inline fn machineSetSyscallProc(this: *State, id: Machine.Id, proc_name_id: ?u32) MachineSetProcError!void {
        const machine = this.findMachine(id) orelse {
            z.getState().last_error = @errorName(MachineSetProcError.MachineNotFound);

            return MachineSetProcError.MachineNotFound;
        };

        machine.syscall_proc = proc_name_id;
    }

    pub inline fn machineLoadElf(this: *State, id: Machine.Id, path: []const u8) MachineLoadElfError!void {
        const machine = this.findMachine(id) orelse {
            z.getState().last_error = @errorName(MachineLoadElfError.MachineNotFound);

            return MachineLoadElfError.MachineNotFound;
        };

        const file_content = std.fs.cwd().readFileAlloc(this.allocator, path, MAX_FILE_SIZE) catch |err| switch (err) {
            error.FileNotFound => {
                z.getState().last_error = @errorName(MachineLoadElfError.FileNotFound);

                return MachineLoadElfError.FileNotFound;
            },
            error.FileTooBig => {
                z.getState().last_error = @errorName(MachineLoadElfError.FileTooBig);

                return MachineLoadElfError.FileTooBig;
            },
            error.OutOfMemory => {
                z.getState().last_error = @errorName(MachineLoadElfError.OutOfMemory);

                return MachineLoadElfError.OutOfMemory;
            },
            else => {
                z.getState().last_error = @errorName(MachineLoadElfError.Unknown);

                return MachineLoadElfError.Unknown;
            },
        };

        defer this.allocator.free(file_content);

        _ = machine.loadElf(this.allocator, file_content) catch |err| switch (err) {
            error.OutOfRam => {
                z.getState().last_error = @errorName(MachineLoadElfError.OutOfRam);

                return MachineLoadElfError.OutOfRam;
            },
            else => {
                z.getState().last_error = @errorName(MachineLoadElfError.BadElf);

                return MachineLoadElfError.BadElf;
            },
        };
    }

    pub inline fn machineSyscall(this: *State, id: Machine.Id, slot: u8, args: []const x.ByondValue) MachineSyscallError!x.ByondValue {
        const machine = this.findMachine(id) orelse {
            z.getState().last_error = @errorName(MachineSyscallError.MachineNotFound);

            return MachineSyscallError.MachineNotFound;
        };

        return machine.syscall(slot, args) catch |err| {
            z.getState().last_error = @errorName(err);

            return err;
        };
    }

    pub inline fn machineTryAttachPci(this: *State, id: Machine.Id, type_id: u8) MachineAttachPciError!?u8 {
        const machine = this.findMachine(id) orelse {
            z.getState().last_error = @errorName(MachineAttachPciError.MachineNotFound);

            return MachineAttachPciError.MachineNotFound;
        };

        const sdk_type_id = std.enums.fromInt(sdk.Pci.DeviceType, type_id) orelse {
            z.getState().last_error = @errorName(MachineAttachPciError.BadDeviceType);

            return MachineAttachPciError.BadDeviceType;
        };

        const device: Device = switch (sdk_type_id) {
            .none, _ => {
                z.getState().last_error = @errorName(MachineAttachPciError.BadDeviceType);

                return MachineAttachPciError.BadDeviceType;
            },
            .tts => .{ .tts = .{} },
            .serial_terminal => .{
                .serial_terminal = SerialTerminal.init(this.allocator) catch {
                    std.log.err("Failed to allocate memory for a serial terminal device", .{});
                    z.getState().last_error = @errorName(MachineAttachPciError.OutOfMemory);

                    return MachineAttachPciError.OutOfMemory;
                },
            },
            .signaler => .{ .signaler = .{} },
            .gps => .{ .gps = .{} },
            .light => .{ .light = .{} },
            .env_sensor => .{ .env_sensor = .{} },
            .vga => .{
                .vga = Vga.init(this.allocator) catch {
                    std.log.err("Failed to allocate memory for a VGA", .{});
                    z.getState().last_error = @errorName(MachineAttachPciError.OutOfMemory);

                    return MachineAttachPciError.OutOfMemory;
                },
            },
        };

        return machine.tryAttachPci(device);
    }

    pub inline fn machineTryDetachPci(this: *State, id: Machine.Id, slot: u8) MachineDetachPciError!bool {
        const machine = this.findMachine(id) orelse {
            z.getState().last_error = @errorName(MachineDetachPciError.MachineNotFound);

            return MachineDetachPciError.MachineNotFound;
        };

        return machine.tryDetachPci(slot);
    }

    pub inline fn machineAppendCounters(this: *State, id: Machine.Id, cycles: u64, idle_cycles: u64, mtime: u64) MachineAppendCountersError!void {
        const machine = this.findMachine(id) orelse {
            z.getState().last_error = @errorName(MachineAppendCountersError.MachineNotFound);

            return MachineAppendCountersError.MachineNotFound;
        };

        machine.cpu.registers.cycle +%= cycles;
        machine.idle_executed += idle_cycles;
        machine.cpu.registers.mtime +%= mtime;
    }

    pub inline fn tick(this: *State, delta_us: u32) void {
        const wall_budget_us: i64 = @divFloor(@as(i64, delta_us) * this.budget_percent, 100);
        const wall_start = std.time.microTimestamp();

        if (this.machines.items.len == 0) {
            this.updateStats(wall_start, delta_us);

            return;
        }

        const timestamp: u64 = sdk.utils.DateTime.decompose(@bitCast(os.Timezone.getLocal().applyTo(std.time.timestamp()))).addYears(544).toTimestamp();
        var served: usize = 0;

        while (served < this.machines.items.len) : (served += 1) {
            const idx = (this.robin_index + served) % this.machines.items.len;
            var machine = &this.machines.items[idx];

            machine.lock.lock();
            defer machine.lock.unlock();

            defer {
                if (machine.requiresWorker()) {
                    const state = z.getState();
                    state.pool.spawnWg(&this.wg, worker, .{ this, machine });
                }
            }

            defer machine.tryCallPostTickProc(delta_us);

            if (!machine.isRunnable()) {
                machine.idle_executed = 0;

                continue;
            }

            const wall_elapsed = std.time.microTimestamp() - wall_start;

            if (wall_elapsed >= wall_budget_us) {
                var j = served;

                while (j < this.machines.items.len) : (j += 1) {
                    const jdx = (this.robin_index + j) % this.machines.items.len;
                    var m = &this.machines.items[jdx];

                    if (m.isRunnable()) {
                        m.debt += @intCast(m.cycleBudget(delta_us));
                    }
                }

                break;
            }

            const tick_budget = machine.cycleBudget(delta_us);
            var budget: u64 = @min(tick_budget +| machine.debt, tick_budget * MAX_DEBT_FACTOR);
            machine.debt = 0;

            if (machine.overshoot >= budget) {
                machine.overshoot -= budget;
                machine.executed = 0;
                machine.utilization = 0;
                machine.idle_executed = 0;

                continue;
            }

            budget -= machine.overshoot;
            machine.overshoot = 0;

            machine.executed = machine.idle_executed;

            machine.clint._status.last_event = .{ .ty = .sync };

            machine.updateRtc(timestamp);
            machine.updatePci(delta_us);
            machine.updateExternalInterrupts();

            while (machine.executed < budget and machine.isRunnable()) {
                const before = machine.cpu.registers.cycle;
                const state = machine.cpu.runCycles(budget - machine.executed);

                const elapsed = machine.cpu.registers.cycle -% before;
                machine.executed += elapsed;

                switch (state) {
                    .ok => {},
                    .halt => {
                        const remaining = budget -| machine.executed;
                        const skipped = machine.skipToTimer(remaining);

                        machine.executed += skipped;
                        machine.idle_executed += skipped;
                    },
                    .trap => {
                        machine.tryCallTrapProc();

                        break;
                    },
                }
            }

            const active = machine.executed -| machine.idle_executed;
            machine.utilization = @floatCast(@as(f64, @floatFromInt(@min(active, budget))) /
                @as(f64, @floatFromInt(@max(budget, 1))));

            if (machine.executed > budget) {
                const excess = machine.executed - budget;
                const active_excess = active -| budget;

                machine.overshoot = active_excess;
                machine.idle_executed = excess - active_excess;
            } else {
                machine.debt = @min(budget - machine.executed, tick_budget);
                machine.idle_executed = 0;
            }
        }

        this.robin_index = (this.robin_index + 1) % this.machines.items.len;
        this.updateStats(wall_start, delta_us);
    }

    pub inline fn machineDumpRegisters(this: *State, id: Machine.Id) MachineDumpRegistersError![:0]u8 {
        const machine = this.findMachine(id) orelse {
            z.getState().last_error = @errorName(MachineDumpRegistersError.MachineNotFound);

            return MachineDumpRegistersError.MachineNotFound;
        };

        var writer: std.Io.Writer.Allocating = .init(this.allocator);
        std.json.Stringify.value(machine.cpu.registers, .{}, &writer.writer) catch {
            z.getState().last_error = @errorName(MachineDumpRegistersError.OutOfMemory);

            return MachineDumpRegistersError.OutOfMemory;
        };
        errdefer writer.deinit();

        return writer.toOwnedSliceSentinel(0) catch {
            z.getState().last_error = @errorName(MachineDumpRegistersError.OutOfMemory);

            return MachineDumpRegistersError.OutOfMemory;
        };
    }

    pub inline fn machineDestroy(this: *State, id: Machine.Id) bool {
        // Wait for all the workers to finish with the machines.
        this.wg.wait();

        if (this.findMachineEntry(id)) |entry| {
            entry.ptr.deinit(this.allocator);
            _ = this.machines.swapRemove(entry.idx);

            return true;
        }

        return false;
    }

    inline fn worker(this: *State, machine: *Machine) void {
        _ = this;

        // Lock for pci and the machine itself.
        machine.lock.lock();
        defer machine.lock.unlock();

        for (&machine.pci.devices, 0..) |*device, slot| {
            device.worker(@intCast(slot), machine);
        }
    }

    inline fn updateStats(this: *State, wall_start: i64, delta_us: u32) void {
        const wall_us: u64 = @intCast(std.time.microTimestamp() - wall_start);
        const budget_us: u64 = @as(u64, delta_us) * this.budget_percent / 100;

        this.stats.last_wall_us = wall_us;
        this.stats.last_budget_us = budget_us;

        // EMA: load_avg = 0.9 * old + 0.1 * current
        const current_load: f32 = if (budget_us > 0)
            @as(f32, @floatFromInt(wall_us)) / @as(f32, @floatFromInt(budget_us))
        else
            0.0;

        this.stats.load_avg = this.stats.load_avg * 0.9 + current_load * 0.1;
    }

    const MachineEntry = struct {
        ptr: *Machine,
        idx: usize,
    };

    inline fn findMachineEntry(this: *State, id: Machine.Id) ?MachineEntry {
        if (id == 0) {
            return null;
        }

        for (this.machines.items, 0..) |*machine, idx| {
            if (machine.id != id) {
                continue;
            }

            return .{ .ptr = machine, .idx = idx };
        }

        return null;
    }

    inline fn findMachine(this: *State, id: Machine.Id) ?*Machine {
        if (this.findMachineEntry(id)) |entry| {
            return entry.ptr;
        }

        return null;
    }
};

pub export fn Z_machine_create(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 1) {
        x.Byond_CRASH("Z_machine_create requires 1 argument");

        return z.returnCast(.{});
    }

    const state = getState();
    const id = state.machineCreate(args[0]) catch {
        return z.returnCast(.{});
    };

    return z.returnCast(x.num(id));
}

pub export fn Z_machine_reset(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 1) {
        x.Byond_CRASH("Z_machine_reset requires 1 argument");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));

    state.machineReset(id) catch {
        return z.returnCast(x.False());
    };

    return z.returnCast(x.True());
}

pub export fn Z_machine_set_ram_size(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 2) {
        x.Byond_CRASH("Z_machine_set_ram_size requires 2 arguments");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const ram_size: u32 = @intFromFloat(x.ByondValue_GetNum(&args[1]));

    state.machineSetRamSize(id, ram_size) catch {
        return z.returnCast(x.False());
    };

    return z.returnCast(x.True());
}

pub export fn Z_machine_get_ram_size(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 1) {
        x.Byond_CRASH("Z_machine_get_ram_size requires 1 argument");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));

    const size = state.machineGetRamSize(id) catch {
        return z.returnCast(.{});
    };

    return z.returnCast(x.num(size));
}

pub export fn Z_machine_read_ram_byte(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 2) {
        x.Byond_CRASH("Z_machine_read_ram_byte requires 2 arguments");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const address: u32 = @intFromFloat(x.ByondValue_GetNum(&args[1]));

    const value = state.machineReadRamByte(id, address) catch {
        return z.returnCast(.{});
    };

    return z.returnCast(x.num(value));
}

pub export fn Z_machine_write_ram_byte(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 3) {
        x.Byond_CRASH("Z_machine_write_ram_byte requires 3 arguments");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const address: u32 = @intFromFloat(x.ByondValue_GetNum(&args[1]));
    const value: u8 = @intFromFloat(x.ByondValue_GetNum(&args[2]));

    state.machineWriteRamByte(id, address, value) catch {
        return z.returnCast(x.False());
    };

    return z.returnCast(x.True());
}

pub export fn Z_machine_read_ram_bytes(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 3) {
        x.Byond_CRASH("Z_machine_read_ram_bytes requires 3 arguments");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const address: u32 = @intFromFloat(x.ByondValue_GetNum(&args[1]));
    const dst = &args[2];

    if (!x.ByondValue_IsList(dst)) {
        x.Byond_CRASH("Z_machine_read_ram_bytes requires a list as the third argument");

        return z.returnCast(x.False());
    }

    state.machineReadRamBytes(id, address, dst) catch {
        return z.returnCast(x.False());
    };

    return z.returnCast(x.True());
}

pub export fn Z_machine_write_ram_bytes(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 3) {
        x.Byond_CRASH("Z_machine_write_ram_bytes requires 3 arguments");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const address: u32 = @intFromFloat(x.ByondValue_GetNum(&args[1]));
    const src = &args[2];

    if (!x.ByondValue_IsList(src)) {
        x.Byond_CRASH("Z_machine_write_ram_bytes requires a list as the third argument");

        return z.returnCast(x.False());
    }

    state.machineWriteRamBytes(id, address, src) catch {
        return z.returnCast(x.False());
    };

    return z.returnCast(x.True());
}

pub export fn Z_machine_set_frequency(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 2) {
        x.Byond_CRASH("Z_machine_set_frequency requires 2 arguments");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const frequency: u32 = @intFromFloat(x.ByondValue_GetNum(&args[1]));

    state.machineSetFrequency(id, frequency) catch {
        return z.returnCast(x.False());
    };

    return z.returnCast(x.True());
}

pub export fn Z_machine_set_state(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 2) {
        x.Byond_CRASH("Z_machine_set_state requires 2 arguments");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const machine_state: u32 = @intFromFloat(x.ByondValue_GetNum(&args[1]));

    state.machineSetState(id, machine_state) catch {
        return z.returnCast(x.False());
    };

    return z.returnCast(x.True());
}

pub export fn Z_machine_get_state(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 1) {
        x.Byond_CRASH("Z_machine_get_state requires 1 argument");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));

    const machine_state = state.machineGetState(id) catch {
        return z.returnCast(x.False());
    };

    return z.returnCast(x.num(@intFromEnum(machine_state)));
}

pub export fn Z_machine_get_utilization(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 1) {
        x.Byond_CRASH("Z_machine_get_utilization requires 1 argument");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));

    const utilization = state.machineGetUtilization(id) catch {
        return z.returnCast(x.False());
    };

    return z.returnCast(x.numF(utilization));
}

pub export fn Z_machine_get_executed(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 1) {
        x.Byond_CRASH("Z_machine_get_executed requires 1 argument");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));

    const executed = state.machineGetExecuted(id) catch {
        return z.returnCast(x.False());
    };
    const executed_32: u32 = @truncate(executed);

    return z.returnCast(x.num(executed_32));
}

pub export fn Z_machine_set_sensors(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 4) {
        x.Byond_CRASH("Z_machine_set_sensors requires 5 argument");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const temperature: i32 = @intFromFloat(x.ByondValue_GetNum(&args[1]));
    const overheat = x.ByondValue_IsTrue(&args[2]);
    const throttled = x.ByondValue_IsTrue(&args[3]);

    state.machineSetSensors(id, @truncate(temperature), overheat, throttled) catch {
        return z.returnCast(x.False());
    };

    return z.returnCast(x.True());
}

pub export fn Z_machine_set_power(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 3) {
        x.Byond_CRASH("Z_machine_set_power requires 2 arguments");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const battery_charge: u32 = @intFromFloat(x.ByondValue_GetNum(&args[1]));
    const has_external_source = x.ByondValue_IsTrue(&args[2]);

    state.machineSetPower(id, battery_charge, has_external_source) catch {
        return z.returnCast(x.False());
    };

    return z.returnCast(x.True());
}

pub export fn Z_machine_set_shift_id(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 2) {
        x.Byond_CRASH("Z_machine_set_shift_id requires 2 arguments");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const byond_shift_id = &args[1];

    if (x.ByondValue_IsNum(byond_shift_id)) {
        state.machineSetShiftId(id, @intFromFloat(x.ByondValue_GetNum(byond_shift_id))) catch {
            return z.returnCast(x.False());
        };
    } else if (x.ByondValue_IsStr(byond_shift_id)) {
        var buffer: [256]u8 = undefined;
        var len: x.u4c = @intCast(buffer.len);

        if (!x.Byond_ToString(byond_shift_id, &buffer, &len)) {
            x.Byond_CRASH("The SHIFT_ID is too long");
        }

        const shift_id = std.hash.XxHash32.hash(0, buffer[0 .. len - 1 :0]);

        state.machineSetShiftId(id, shift_id) catch {
            return z.returnCast(x.False());
        };
    } else {
        x.Byond_CRASH("The SHIFT_ID must be a number or a string");

        return z.returnCast(.{});
    }

    return z.returnCast(x.True());
}

pub export fn Z_machine_set_post_tick_proc(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 2) {
        x.Byond_CRASH("Z_machine_set_post_tick_proc requires 2 arguments");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const proc = &args[1];

    if (x.ByondValue_IsNull(proc)) {
        state.machineSetPostTickProc(id, null) catch {
            return z.returnCast(x.False());
        };

        return z.returnCast(x.True());
    }

    if (!x.ByondValue_IsStr(proc)) {
        x.Byond_CRASH("The proc name should be a string");

        return z.returnCast(x.False());
    }

    state.machineSetPostTickProc(id, x.ByondValue_GetRef(proc)) catch {
        return z.returnCast(x.False());
    };

    return z.returnCast(x.True());
}

pub export fn Z_machine_set_trap_proc(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 2) {
        x.Byond_CRASH("Z_machine_set_trap_proc requires 2 arguments");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const proc = &args[1];

    if (x.ByondValue_IsNull(proc)) {
        state.machineSetTrapProc(id, null) catch {
            return @bitCast(x.False());
        };

        return z.returnCast(x.True());
    }

    if (!x.ByondValue_IsStr(proc)) {
        x.Byond_CRASH("The proc name should be a string");

        return z.returnCast(x.False());
    }

    state.machineSetTrapProc(id, x.ByondValue_GetRef(proc)) catch {
        return z.returnCast(x.False());
    };

    return z.returnCast(x.True());
}

pub export fn Z_machine_set_syscall_proc(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 2) {
        x.Byond_CRASH("Z_machine_set_syscall_proc requires 2 arguments");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const proc = &args[1];

    if (x.ByondValue_IsNull(proc)) {
        state.machineSetSyscallProc(id, null) catch {
            return z.returnCast(x.False());
        };

        return z.returnCast(x.True());
    }

    if (!x.ByondValue_IsStr(proc)) {
        x.Byond_CRASH("The proc name should be a string");

        return z.returnCast(.{});
    }

    state.machineSetSyscallProc(id, x.ByondValue_GetRef(proc)) catch {
        return z.returnCast(x.False());
    };

    return z.returnCast(x.True());
}

pub export fn Z_machine_append_counters(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 4) {
        x.Byond_CRASH("Z_machine_append_cycles requires 3 arguments");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const cycles: u32 = @intFromFloat(x.ByondValue_GetNum(&args[1]));
    const idle_cycles: u32 = @intFromFloat(x.ByondValue_GetNum(&args[2]));
    const mtime: u32 = @intFromFloat(x.ByondValue_GetNum(&args[3]));

    state.machineAppendCounters(id, cycles, idle_cycles, mtime) catch {
        return z.returnCast(x.False());
    };

    return z.returnCast(x.True());
}

pub export fn Z_machine_load_elf(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 2) {
        x.Byond_CRASH("Z_machine_load_elf requires 2 arguments");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));

    const byond_path = &args[1];

    const path = x.toString(state.allocator, byond_path) catch {
        x.Byond_CRASH("Failed to Byond_ToString the path argument");

        return z.returnCast(.{});
    };
    defer state.allocator.free(path);

    state.machineLoadElf(id, path) catch {
        return z.returnCast(x.False());
    };

    return z.returnCast(x.True());
}

pub export fn Z_machine_syscall(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len < 2) {
        x.Byond_CRASH("Z_machine_syscall requires at least 2 arguments");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const slot: u32 = @intFromFloat(x.ByondValue_GetNum(&args[1]));

    const ret = state.machineSyscall(id, @truncate(slot), args[2..]) catch {
        return z.returnCast(.{});
    };

    return z.returnCast(ret);
}

pub export fn Z_machine_try_attach_pci(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 2) {
        x.Byond_CRASH("Z_machine_try_attach_pci requires 2 arguments");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const type_id: u8 = @intFromFloat(x.ByondValue_GetNum(&args[1]));

    const pci_slot = state.machineTryAttachPci(id, type_id) catch {
        return z.returnCast(.{});
    };

    if (pci_slot == null) {
        return z.returnCast(.{});
    }

    return z.returnCast(x.num(pci_slot.?));
}

pub export fn Z_machine_try_detach_pci(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 2) {
        x.Byond_CRASH("Z_machine_try_detach_pci requires 2 arguments");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const slot: u32 = @intFromFloat(x.ByondValue_GetNum(&args[1]));

    const was_removed = state.machineTryDetachPci(id, @truncate(slot)) catch {
        return z.returnCast(.{});
    };

    return if (was_removed)
        z.returnCast(x.True())
    else
        z.returnCast(x.False());
}

pub export fn Z_machine_dump_registers(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 1) {
        x.Byond_CRASH("Z_machine_dump_registers requires 1 argument");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));

    const dump = state.machineDumpRegisters(id) catch {
        return z.returnCast(.{});
    };
    defer state.allocator.free(dump);

    var ret: x.ByondValue = .{};
    x.ByondValue_SetStr(&ret, dump);

    return z.returnCast(ret);
}

pub export fn Z_machine_destroy(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 1) {
        x.Byond_CRASH("Z_machine_destroy requires 1 argument");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));

    return if (state.machineDestroy(id)) @bitCast(x.True()) else @bitCast(x.False());
}

pub export fn Z_machines_tick(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 1) {
        x.Byond_CRASH("Z_machines_tick requires 1 argument");

        return z.returnCast(.{});
    }

    const state = getState();
    const delta_us: u32 = @intFromFloat(x.ByondValue_GetNum(&args[0]));

    state.tick(delta_us);

    return z.returnCast(x.True());
}

pub export fn Z_machines_stats(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    _ = argv;

    if (argc != 0) {
        x.Byond_CRASH("Z_machines_stats does not accept args");

        return z.returnCast(.{});
    }

    const state = getState();
    const stats = state.stats;

    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    std.json.Stringify.value(stats, .{}, &writer) catch {
        x.Byond_CRASH("Failed to format the stats");

        return z.returnCast(x.False());
    };

    writer.writeByte(0) catch {
        x.Byond_CRASH("Failed to format the stats");

        return z.returnCast(.{});
    };

    var ret: x.ByondValue = .{};
    x.ByondValue_SetStr(&ret, buffer[0 .. writer.end - 1 :0]);

    return z.returnCast(ret);
}

pub export fn Z_machines_set_budget(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 1) {
        x.Byond_CRASH("Z_machines_set_budget requires 1 argument");

        return z.returnCast(.{});
    }

    const budget: u32 = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const state = getState();

    state.budget_percent = std.math.clamp(budget, 10, 80);

    return z.returnCast(x.True());
}
