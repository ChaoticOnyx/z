// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const builtin = @import("builtin");

const ondatra = @import("ondatra");
const sdk = @import("mcu_sdk");

const logger = @import("logger.zig");
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

const MAX_FILE_SIZE = 1e9;
const DEFAULT_FREQUENCY: u64 = 1_000_000;
const MAX_DEBT_FACTOR = 2;

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

pub inline fn sizeOfField(comptime Type: type, comptime field_name: []const u8) usize {
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

pub const Tts = struct {
    pub const NativeCommand = enum(u8) {
        say = 1,

        pub inline fn byond(this: NativeCommand) x.ByondValue {
            return x.Num(@floatFromInt(@intFromEnum(this)));
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

    pub inline fn mmioRead(this: *Tts, slot: u8, machine: *Machine, offset: usize) ?u8 {
        _ = slot;
        _ = machine;

        switch (offset) {
            @offsetOf(sdk.Tts, "_config")...(@offsetOf(sdk.Tts, "_config") + @sizeOf(sdk.Tts.Config) - 1) => {
                const rel_offset = offset - @offsetOf(sdk.Tts, "_config");
                const bytes = std.mem.asBytes(&this.mmio._config);

                return bytes[rel_offset];
            },
            @offsetOf(sdk.Tts, "_status")...(@offsetOf(sdk.Tts, "_status") + @sizeOf(sdk.Tts.Status) - 1) => {
                const rel_offset = offset - @offsetOf(sdk.Tts, "_status");
                const bytes = std.mem.asBytes(&this.mmio._status);

                return bytes[rel_offset];
            },
            else => return null,
        }
    }

    pub inline fn mmioWrite(this: *Tts, slot: u8, machine: *Machine, offset: usize, value: u8) bool {
        switch (offset) {
            @offsetOf(sdk.Tts, "_config")...(@offsetOf(sdk.Tts, "_config") + @sizeOf(sdk.Tts.Config) - 1) => {
                const rel_offset = offset - @offsetOf(sdk.Tts, "_config");
                const bytes = std.mem.asBytes(&this.mmio._config);

                bytes[rel_offset] = value;
                machine.updateExternalInterrupts();

                return true;
            },
            @offsetOf(sdk.Tts, "_action")...(@offsetOf(sdk.Tts, "_action") + @sizeOf(sdk.Tts.Action) - 1) => {
                const rel_offset = offset - @offsetOf(sdk.Tts, "_action");

                switch (rel_offset) {
                    @offsetOf(sdk.Tts.Action, "execute") => {
                        if (!this.mmio._status.is_ready) {
                            return false;
                        }

                        const term_pos = std.mem.indexOfScalar(u8, &this.memory, 0) orelse {
                            return false;
                        };

                        const msg = this.memory[0 .. term_pos - 1 :0];

                        if (msg.len == 0) {
                            return false;
                        }

                        var byond_msg: x.ByondValue = .{};
                        x.ByondValue_SetStr(&byond_msg, msg);

                        return machine.tryCallSyscallProc(&.{ x.Num(@floatFromInt(slot)), NativeCommand.say.byond(), byond_msg });
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

                this.mmio._status.is_ready = x.ByondValue_IsTrue(&args[1]);

                if (this.mmio._status.is_ready) {
                    this.mmio._status.last_event = .{ .ty = .ready };
                    machine.updateExternalInterrupts();
                }
            },
            _ => return x.False(),
        }

        return x.True();
    }

    pub inline fn isInterruptPending(this: *Tts, slot: u8, machine: *Machine) bool {
        _ = slot;
        _ = machine;

        if (this.mmio._config.interrupt_when_ready and this.mmio._status.last_event.ty == .ready) {
            return true;
        }

        return false;
    }
};

pub const SerialTerminal = struct {
    pub const NativeCommand = enum(u8) {
        write = 1,

        pub inline fn byond(this: NativeCommand) x.ByondValue {
            return x.Num(@floatFromInt(@intFromEnum(this)));
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

    pub inline fn mmioRead(this: *SerialTerminal, slot: u8, machine: *Machine, offset: usize) ?u8 {
        _ = slot;
        _ = machine;

        switch (offset) {
            @offsetOf(sdk.SerialTerminal, "_config")...(@offsetOf(sdk.SerialTerminal, "_config") + @sizeOf(sdk.SerialTerminal.Config) - 1) => {
                const rel_offset = offset - @offsetOf(sdk.SerialTerminal, "_config");
                const bytes = std.mem.asBytes(&this.mmio._config);

                return bytes[rel_offset];
            },
            @offsetOf(sdk.SerialTerminal, "_status")...(@offsetOf(sdk.SerialTerminal, "_status") + @sizeOf(sdk.SerialTerminal.Status) - 1) => {
                const rel_offset = offset - @offsetOf(sdk.SerialTerminal, "_status");
                const bytes = std.mem.asBytes(&this.mmio._status);

                return bytes[rel_offset];
            },
            else => return null,
        }
    }

    pub inline fn mmioWrite(this: *SerialTerminal, slot: u8, machine: *Machine, offset: usize, value: u8) bool {
        switch (offset) {
            @offsetOf(sdk.SerialTerminal, "_config")...(@offsetOf(sdk.SerialTerminal, "_config") + @sizeOf(sdk.SerialTerminal.Config) - 1) => {
                const rel_offset = offset - @offsetOf(sdk.SerialTerminal, "_config");
                const bytes = std.mem.asBytes(&this.mmio._config);

                bytes[rel_offset] = value;

                return true;
            },
            @offsetOf(sdk.SerialTerminal, "_action")...(@offsetOf(sdk.SerialTerminal, "_action") + @sizeOf(sdk.SerialTerminal.Action) - 1) => {
                const rel_offset = offset - @offsetOf(sdk.SerialTerminal, "_action");

                switch (rel_offset) {
                    @offsetOf(sdk.SerialTerminal.Action, "flush") => {
                        const len = std.mem.indexOfScalar(u8, this.output, 0) orelse {
                            return true;
                        };

                        if (len == 0) {
                            return true;
                        }

                        var byond_bytes: x.ByondValue = .{};
                        if (!x.Byond_CreateListLen(&byond_bytes, len)) {
                            std.log.err("Failed to create a BYOND list for SerialTerminal output of len {}", .{len});

                            return false;
                        }

                        for (0..len) |idx| {
                            const byond_value = x.Num(@floatFromInt(this.output[idx]));
                            const byond_idx = x.Num(@floatFromInt(idx + 1));

                            if (!x.Byond_WriteListIndex(&byond_bytes, &byond_idx, &byond_value)) {
                                std.log.err("Failed to write an output byte from Serial Terminal at {}", .{idx});
                            }
                        }

                        return machine.tryCallSyscallProc(&.{ x.Num(@floatFromInt(slot)), NativeCommand.write.byond(), byond_bytes });
                    },
                    @offsetOf(sdk.SerialTerminal.Action, "ack") => {
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

                var bytes_len: u32 = @intFromFloat(x.ByondValue_GetNum(&byond_bytes_len));
                bytes_len = std.math.clamp(bytes_len, 0, sdk.SerialTerminal.INPUT_BUFFER_SIZE);

                for (0..bytes_len) |i| {
                    const byond_idx = x.Num(@floatFromInt(i + 1));
                    var byond_byte: x.ByondValue = .{};

                    if (!x.Byond_ReadListIndex(bytes, &byond_idx, &byond_byte)) {
                        this.input[i] = 0;
                        bytes_len = i;

                        break;
                    }

                    if (!x.ByondValue_IsNum(&byond_byte)) {
                        this.input[i] = 0;
                        bytes_len = i;

                        break;
                    }

                    const byte: u32 = @intFromFloat(x.ByondValue_GetNum(&byond_byte));
                    this.input[i] = @truncate(byte);
                }

                if (bytes_len > 0) {
                    this.mmio._status.last_event = .{ .ty = .new_data };
                    this.mmio._status.len = @truncate(bytes_len);
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

pub const Signaler = struct {
    pub const NativeCommand = enum(u8) {
        set = 1,
        send = 2,

        pub inline fn byond(this: NativeCommand) x.ByondValue {
            return x.Num(@floatFromInt(@intFromEnum(this)));
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

    pub inline fn mmioRead(this: *Signaler, slot: u8, machine: *Machine, offset: usize) ?u8 {
        _ = slot;
        _ = machine;

        switch (offset) {
            @offsetOf(sdk.Signaler, "_config")...(@offsetOf(sdk.Signaler, "_config") + @sizeOf(sdk.Signaler.Config) - 1) => {
                const rel_offset = offset - @offsetOf(sdk.Signaler, "_config");
                const bytes = std.mem.asBytes(&this.mmio._config);

                return bytes[rel_offset];
            },
            @offsetOf(sdk.Signaler, "_status")...(@offsetOf(sdk.Signaler, "_status") + @sizeOf(sdk.Signaler.Status) - 1) => {
                const rel_offset = offset - @offsetOf(sdk.Signaler, "_status");
                const bytes = std.mem.asBytes(&this.mmio._status);

                return bytes[rel_offset];
            },
            else => return null,
        }
    }

    pub inline fn mmioWrite(this: *Signaler, slot: u8, machine: *Machine, offset: usize, value: u8) bool {
        switch (offset) {
            @offsetOf(sdk.Signaler, "_config")...(@offsetOf(sdk.Signaler, "_config") + @sizeOf(sdk.Signaler.Config) - 1) => {
                const rel_offset = offset - @offsetOf(sdk.Signaler, "_config");
                const bytes = std.mem.asBytes(&this.mmio._config);

                bytes[rel_offset] = value;

                return true;
            },
            @offsetOf(sdk.Signaler, "_action")...(@offsetOf(sdk.Signaler, "_action") + @sizeOf(sdk.Signaler.Action) - 1) => {
                const rel_offset = offset - @offsetOf(sdk.Signaler, "_action");

                switch (rel_offset) {
                    @offsetOf(sdk.Signaler.Action, "set") => {
                        if (!this.mmio._status.ready) {
                            return false;
                        }

                        return machine.tryCallSyscallProc(&.{
                            x.Num(@floatFromInt(slot)),
                            NativeCommand.set.byond(),
                            x.Num(@floatFromInt(this.mmio._config.frequency)),
                            x.Num(@floatFromInt(this.mmio._config.code)),
                        });
                    },
                    @offsetOf(sdk.Signaler.Action, "send") => {
                        if (!this.mmio._status.ready) {
                            return false;
                        }

                        return machine.tryCallSyscallProc(&.{ x.Num(@floatFromInt(slot)), NativeCommand.send.byond() });
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

    pub inline fn executeDma(this: *Signaler, slot: u8, machine: *Machine, cfg: sdk.Dma.Config) bool {
        _ = this;
        _ = slot;
        _ = machine;
        _ = cfg;

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
                    machine.updateExternalInterrupts();
                }

                return x.True();
            },
            else => return x.False(),
        }

        return x.False();
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

pub const Device = union(enum) {
    none,
    tts: Tts,
    serial_terminal: SerialTerminal,
    signaler: Signaler,

    pub inline fn mmioRead(this: *Device, slot: u8, machine: *Machine, offset: usize) ?u8 {
        return switch (this.*) {
            .none => return null,
            .tts => return this.tts.mmioRead(slot, machine, offset),
            .serial_terminal => return this.serial_terminal.mmioRead(slot, machine, offset),
            .signaler => return this.signaler.mmioRead(slot, machine, offset),
        };
    }

    pub inline fn mmioWrite(this: *Device, slot: u8, machine: *Machine, offset: usize, value: u8) bool {
        return switch (this.*) {
            .none => return false,
            .tts => return this.tts.mmioWrite(slot, machine, offset, value),
            .serial_terminal => return this.serial_terminal.mmioWrite(slot, machine, offset, value),
            .signaler => return this.signaler.mmioWrite(slot, machine, offset, value),
        };
    }

    pub inline fn executeDma(this: *Device, slot: u8, machine: *Machine, cfg: sdk.Dma.Config) bool {
        return switch (this.*) {
            .none => return false,
            .tts => return this.tts.executeDma(slot, machine, cfg),
            .serial_terminal => return this.serial_terminal.executeDma(slot, machine, cfg),
            .signaler => return this.signaler.executeDma(slot, machine, cfg),
        };
    }

    pub inline fn syscall(this: *Device, slot: u8, machine: *Machine, args: []const x.ByondValue) x.ByondValue {
        return switch (this.*) {
            .none => return x.ByondValue{},
            .tts => return this.tts.syscall(slot, machine, args),
            .serial_terminal => return this.serial_terminal.syscall(slot, machine, args),
            .signaler => return this.signaler.syscall(slot, machine, args),
        };
    }

    pub inline fn isInterruptPending(this: *Device, slot: u8, machine: *Machine) bool {
        return switch (this.*) {
            .none => return false,
            .tts => return this.tts.isInterruptPending(slot, machine),
            .serial_terminal => return this.serial_terminal.isInterruptPending(slot, machine),
            .signaler => return this.signaler.isInterruptPending(slot, machine),
        };
    }

    pub inline fn mmioSize(this: *const Device) usize {
        return switch (this.*) {
            .none => return 0,
            .tts => return @sizeOf(sdk.Tts),
            .serial_terminal => return @sizeOf(sdk.SerialTerminal),
            .signaler => return @sizeOf(sdk.Signaler),
        };
    }

    pub inline fn sdkType(this: *const Device) sdk.Pci.DeviceType {
        return switch (this.*) {
            .none => .none,
            .tts => .tts,
            .serial_terminal => .serial_terminal,
            .signaler => .signaler,
        };
    }

    pub inline fn deinit(this: *Device, allocator: std.mem.Allocator) void {
        switch (this.*) {
            .none, .tts, .signaler => {},
            .serial_terminal => this.serial_terminal.deinit(allocator),
        }
    }
};

pub const Pci = struct {
    mmio: sdk.Pci = .{},
    devices: [sdk.Pci.MAX_DEVICES]Device = .{.none} ** sdk.Pci.MAX_DEVICES,

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
    state: Machine.State = .stopped,
    frequency: u32 = DEFAULT_FREQUENCY,
    cpu: Cpu,
    utilization: f32 = 0.0,
    executed: u64 = 0,
    idle_executed: u64 = 0,
    overshoot: u64 = 0,
    debt: u64 = 0,
    prng: std.Random.DefaultPrng,
    dma: sdk.Dma = .{},
    src_object: ?x.ByondValue = null,
    post_tick_proc: ?u32 = null,
    trap_proc: ?u32 = null,
    syscall_proc: ?u32 = null,
    free_ram_start: u32 = 0,
    pci: Pci = .{},
    sensors: sdk.Sensors = .{},

    pub inline fn init(id: Machine.Id) Machine {
        const ram: []u8 = &.{};

        var prng_seed: u64 = 0;
        std.posix.getrandom(std.mem.asBytes(&prng_seed)) catch {};

        return .{
            .id = id,
            .cpu = .init(ram),
            .prng = .init(prng_seed),
        };
    }

    pub inline fn deinit(this: *Machine, allocator: std.mem.Allocator) void {
        allocator.free(this.cpu.ram);
        this.cpu.ram = &.{};

        if (this.src_object != null) {
            x.ByondValue_DecRef(&this.src_object.?);
            this.src_object = null;
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
        const src = this.src_object orelse return;
        const proc = this.post_tick_proc orelse return;

        var ret: x.ByondValue = .{};
        _ = x.Byond_CallProcByStrId(&src, proc, &.{x.Num(@floatFromInt(delta_us))}, &ret);
    }

    pub inline fn tryCallTrapProc(this: *const Machine) void {
        const src = this.src_object orelse return;
        const proc = this.trap_proc orelse return;

        var ret: x.ByondValue = .{};
        _ = x.Byond_CallProcByStrId(&src, proc, &.{}, &ret);
    }

    pub inline fn tryCallSyscallProc(this: *const Machine, args: []const x.ByondValue) bool {
        const src = this.src_object orelse return false;
        const proc = this.syscall_proc orelse return false;

        var ret: x.ByondValue = .{};
        if (!x.Byond_CallProcByStrId(&src, proc, args, &ret)) {
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

        if (this.pci.mmio._config.interrupts.connected and this.pci.mmio._status.last_event.ty == .connected) {
            has_external_interrupt = true;

            return;
        }

        if (this.pci.mmio._config.interrupts.disconnected and this.pci.mmio._status.last_event.ty == .disconnected) {
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

    inline fn mmioRead(ctx: *anyopaque, address: u32) ?u8 {
        const this: *Machine = @ptrCast(@alignCast(ctx));

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

    inline fn readClint(this: *Machine, offset: u32) ?u8 {
        switch (offset) {
            @offsetOf(sdk.Clint, "_config")...(@offsetOf(sdk.Clint, "_config") + @sizeOf(sdk.Clint.Config) - 1) => {
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
                    else => return null,
                }
            },
            else => return null,
        }
    }

    inline fn readPrng(this: *Machine, offset: u32) ?u8 {
        switch (offset) {
            @offsetOf(sdk.Prng, "_status")...(@offsetOf(sdk.Prng, "_status") + @sizeOf(sdk.Prng.Status) - 1) => {
                return @truncate(this.prng.next());
            },
            else => return null,
        }
    }

    inline fn readDma(this: *Machine, offset: u32) ?u8 {
        switch (offset) {
            @offsetOf(sdk.Dma, "_config")...(@offsetOf(sdk.Dma, "_config") + @sizeOf(sdk.Dma.Config) - 1) => {
                const rel_offset = offset - @offsetOf(sdk.Dma, "_config");
                const bytes = std.mem.asBytes(&this.dma._config);

                return bytes[rel_offset];
            },
            else => return null,
        }
    }

    inline fn readPci(this: *Machine, offset: u32) ?u8 {
        switch (offset) {
            @offsetOf(sdk.Pci, "_config")...(@offsetOf(sdk.Pci, "_config") + @sizeOf(sdk.Pci.Config) - 1) => {
                const rel_offset = offset - @offsetOf(sdk.Pci, "_config");
                const bytes = std.mem.asBytes(&this.pci.mmio._config);

                return bytes[rel_offset];
            },
            @offsetOf(sdk.Pci, "_status")...(@offsetOf(sdk.Pci, "_status") + @sizeOf(sdk.Pci.Status) - 1) => {
                const rel_offset = offset - @offsetOf(sdk.Pci, "_status");
                const bytes = std.mem.asBytes(&this.pci.mmio._status);

                return bytes[rel_offset];
            },
            else => return null,
        }
    }

    inline fn mmioWrite(ctx: *anyopaque, address: u32, value: u8) bool {
        const this: *Machine = @ptrCast(@alignCast(ctx));

        if (address >= sdk.Memory.CLINT and address < sdk.Memory.CLINT + @sizeOf(sdk.Clint)) {
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

    inline fn writeClint(this: *Machine, offset: u32, value: u8) bool {
        switch (offset) {
            @offsetOf(sdk.Clint, "_config")...(@offsetOf(sdk.Clint, "_config") + @sizeOf(sdk.Clint.Config) - 1) => {
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
                    else => return false,
                }
            },
            else => return false,
        }
    }

    inline fn writeDma(this: *Machine, offset: u32, value: u8) bool {
        switch (offset) {
            @offsetOf(sdk.Dma, "_config")...(@offsetOf(sdk.Dma, "_config") + @sizeOf(sdk.Dma.Config) - 1) => {
                const rel_offset = offset - @offsetOf(sdk.Dma, "_config");
                const bytes = std.mem.asBytes(&this.dma._config);

                bytes[rel_offset] = value;

                return true;
            },
            @offsetOf(sdk.Dma, "_action")...(@offsetOf(sdk.Dma, "_action") + @sizeOf(sdk.Dma.Action) - 1) => {
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
            @offsetOf(sdk.Pci, "_config")...(@offsetOf(sdk.Pci, "_config") + @sizeOf(sdk.Pci.Config) - 1) => {
                const rel_offset = offset - @offsetOf(sdk.Pci, "_config");
                const bytes = std.mem.asBytes(&this.pci.mmio._config);

                bytes[rel_offset] = value;
                this.updateExternalInterrupts();

                return true;
            },
            @offsetOf(sdk.Pci, "_action")...(@offsetOf(sdk.Pci, "_action") + @sizeOf(sdk.Pci.Action) - 1) => {
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
                    return false;
                }
            },
            .read, .write => {
                if (this.dma._config.len == 0) {
                    return false;
                }
            },
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

pub const MachineCreationError = error{
    OutOfId,
    OutOfMemory,
};

pub const MachineResetError = error{
    MachineNotFound,
};

pub const MachineConnectError = error{
    MachineNotFound,
};

pub const MachineSetRamSizeError = error{
    MachineNotFound,
    OutOfRam,
};

pub const MachineGetRamSizeError = error{
    MachineNotFound,
};

pub const MachineReadRamError = error{
    MachineNotFound,
    OutOfBounds,
};

pub const MachineWriteRamError = error{
    MachineNotFound,
    OutOfBounds,
};

pub const MachineSetFrequencyError = error{
    MachineNotFound,
};

pub const MachineSetStateError = error{
    MachineNotFound,
    BadState,
};

pub const MachineGetStateError = error{
    MachineNotFound,
};

pub const MachineGetUtilizationError = error{
    MachineNotFound,
};

pub const MachineGetExecutedError = error{
    MachineNotFound,
};

pub const MachineSetSensorsError = error{
    MachineNotFound,
};

pub const MachineSetProcError = error{
    MachineNotFound,
};

pub const MachineLoadElfError = error{
    MachineNotFound,
    FileNotFound,
    FileTooBig,
    OutOfMemory,
    OutOfRam,
    BadElf,
    Unknown,
};

pub const MachineSyscallError = error{
    MachineNotFound,
    SlotNotFound,
};

pub const MachineAttachPciError = error{
    MachineNotFound,
    BadDeviceType,
    OutOfMemory,
};

pub const MachineDetachPciError = error{
    MachineNotFound,
};

pub const MachineAppendCountersError = error{
    MachineNotFound,
};

pub const MachineDumpRegistersError = error{
    MachineNotFound,
    OutOfMemory,
};

const State = struct {
    pub const Stats = struct {
        last_wall_us: u64 = 0,
        last_budget_us: u64 = 0,
        last_machines_served: u32 = 0,
        last_machines_starved: u32 = 0,
        load_avg: f32 = 0.0,
    };

    alloc: std.heap.DebugAllocator(.{}),
    next_id: Machine.Id = 1,
    machines: std.ArrayList(Machine) = .empty,
    robin_index: usize = 0,
    budget_percent: usize = 40,
    stats: Stats = .{},
    last_error: ?[:0]const u8 = null,

    pub inline fn machineCreate(this: *State) MachineCreationError!Machine.Id {
        if (this.next_id == std.math.maxInt(Machine.Id)) {
            this.last_error = @errorName(MachineCreationError.OutOfId);

            return MachineCreationError.OutOfId;
        }

        const machine: Machine = .init(this.next_id);

        this.machines.append(this.alloc.allocator(), machine) catch {
            this.last_error = @errorName(MachineCreationError.OutOfMemory);

            return MachineCreationError.OutOfMemory;
        };
        this.next_id += 1;

        return machine.id;
    }

    pub inline fn machineReset(this: *State, id: Machine.Id) MachineResetError!void {
        const machine = this.findMachine(id) orelse {
            this.last_error = @errorName(MachineConnectError.MachineNotFound);

            return MachineConnectError.MachineNotFound;
        };

        @memset(machine.cpu.ram, 0);
        machine.cpu.registers = .{};
    }

    pub inline fn machineConnect(this: *State, id: Machine.Id, src_object: ?x.ByondValue) MachineConnectError!void {
        const machine = this.findMachine(id) orelse {
            this.last_error = @errorName(MachineConnectError.MachineNotFound);

            return MachineConnectError.MachineNotFound;
        };

        if (machine.src_object != null) {
            x.ByondValue_DecRef(&machine.src_object.?);
            machine.src_object = null;
        }

        if (src_object != null) {
            x.ByondValue_IncRef(&src_object.?);
            machine.src_object = src_object;
        }
    }

    pub inline fn machineSetRamSize(this: *State, id: Machine.Id, ram_size: u32) MachineSetRamSizeError!void {
        const machine = this.findMachine(id) orelse {
            this.last_error = @errorName(MachineSetRamSizeError.MachineNotFound);

            return MachineSetRamSizeError.MachineNotFound;
        };

        const new_ram = this.alloc.allocator().alloc(u8, ram_size) catch {
            this.last_error = @errorName(MachineSetRamSizeError.OutOfRam);

            return MachineSetRamSizeError.OutOfRam;
        };
        this.alloc.allocator().free(machine.cpu.ram);

        machine.cpu.ram = new_ram;
    }

    pub inline fn machineGetRamSize(this: *State, id: Machine.Id) MachineGetRamSizeError!u32 {
        const machine = this.findMachine(id) orelse {
            this.last_error = @errorName(MachineGetRamSizeError.MachineNotFound);

            return MachineGetRamSizeError.MachineNotFound;
        };

        return machine.cpu.ram.len;
    }

    pub inline fn machineReadRamByte(this: *State, id: Machine.Id, address: u32) MachineReadRamError!u8 {
        const machine = this.findMachine(id) orelse {
            this.last_error = @errorName(MachineReadRamError.MachineNotFound);

            return MachineReadRamError.MachineNotFound;
        };

        if (address >= machine.cpu.ram.len) {
            this.last_error = @errorName(MachineReadRamError.OutOfBounds);

            return MachineReadRamError.OutOfBounds;
        }

        return machine.cpu.ram[address];
    }

    pub inline fn machineWriteRamByte(this: *State, id: Machine.Id, address: u32, value: u8) MachineWriteRamError!void {
        const machine = this.findMachine(id) orelse {
            this.last_error = @errorName(MachineWriteRamError.MachineNotFound);

            return MachineWriteRamError.MachineNotFound;
        };

        if (address >= machine.cpu.ram.len) {
            this.last_error = @errorName(MachineWriteRamError.OutOfBounds);

            return MachineWriteRamError.OutOfBounds;
        }

        machine.cpu.ram[address] = value;
    }

    pub inline fn machineReadRamBytes(this: *State, id: Machine.Id, address: u32, dst: *const x.ByondValue) MachineReadRamError!void {
        const machine = this.findMachine(id) orelse {
            this.last_error = @errorName(MachineReadRamError.MachineNotFound);

            return MachineReadRamError.MachineNotFound;
        };

        var byond_len: x.ByondValue = .{};
        if (!x.Byond_Length(dst, &byond_len)) {
            this.last_error = @errorName(MachineReadRamError.OutOfBounds);

            return MachineReadRamError.OutOfBounds;
        }

        const len: u32 = @intFromFloat(x.ByondValue_GetNum(&byond_len));

        if (address +| len > machine.cpu.ram.len) {
            this.last_error = @errorName(MachineReadRamError.OutOfBounds);

            return MachineReadRamError.OutOfBounds;
        }

        for (0..len) |idx| {
            const value = x.Num(@floatFromInt(machine.cpu.ram[address + idx]));
            const byond_idx = x.Num(@floatFromInt(idx + 1));

            if (!x.Byond_WriteListIndex(dst, &byond_idx, &value)) {
                this.last_error = @errorName(MachineReadRamError.OutOfBounds);

                return MachineReadRamError.OutOfBounds;
            }
        }
    }

    pub inline fn machineWriteRamBytes(this: *State, id: Machine.Id, address: u32, src: *const x.ByondValue) MachineWriteRamError!void {
        const machine = this.findMachine(id) orelse {
            this.last_error = @errorName(MachineWriteRamError.MachineNotFound);

            return MachineWriteRamError.MachineNotFound;
        };

        var byond_len: x.ByondValue = .{};
        if (!x.Byond_Length(src, &byond_len)) {
            this.last_error = @errorName(MachineReadRamError.OutOfBounds);

            return MachineReadRamError.OutOfBounds;
        }

        const len: u32 = @intFromFloat(x.ByondValue_GetNum(&byond_len));

        if (address +| len > machine.cpu.ram.len) {
            this.last_error = @errorName(MachineWriteRamError.OutOfBounds);

            return MachineWriteRamError.OutOfBounds;
        }

        for (0..len) |idx| {
            const byond_idx = x.Num(@floatFromInt(idx + 1));
            var byond_value: x.ByondValue = .{};

            if (!x.Byond_ReadListIndex(src, &byond_idx, &byond_value)) {
                this.last_error = @errorName(MachineReadRamError.OutOfBounds);

                return MachineReadRamError.OutOfBounds;
            }

            const value: u32 = @intFromFloat(x.ByondValue_GetNum(&byond_value));

            machine.cpu.ram[address + idx] = @truncate(value);
        }
    }

    pub inline fn machineSetFrequency(this: *State, id: Machine.Id, frequency: u32) MachineSetFrequencyError!void {
        const machine = this.findMachine(id) orelse {
            this.last_error = @errorName(MachineSetRamSizeError.MachineNotFound);

            return MachineSetRamSizeError.MachineNotFound;
        };

        machine.frequency = frequency;
    }

    pub inline fn machineSetState(this: *State, id: Machine.Id, state: u32) MachineSetStateError!void {
        const machine = this.findMachine(id) orelse {
            this.last_error = @errorName(MachineSetRamSizeError.MachineNotFound);

            return MachineSetRamSizeError.MachineNotFound;
        };

        machine.state = std.enums.fromInt(Machine.State, state) orelse {
            this.last_error = @errorName(MachineSetStateError.BadState);

            return MachineSetStateError.BadState;
        };
    }

    pub inline fn machineGetState(this: *State, id: Machine.Id) MachineGetStateError!Machine.State {
        const machine = this.findMachine(id) orelse {
            this.last_error = @errorName(MachineSetRamSizeError.MachineNotFound);

            return MachineSetRamSizeError.MachineNotFound;
        };

        return machine.state;
    }

    pub inline fn machineGetUtilization(this: *State, id: Machine.Id) MachineGetUtilizationError!f32 {
        const machine = this.findMachine(id) orelse {
            this.last_error = @errorName(MachineSetRamSizeError.MachineNotFound);

            return MachineSetRamSizeError.MachineNotFound;
        };

        return machine.utilization;
    }

    pub inline fn machineGetExecuted(this: *State, id: Machine.Id) MachineGetExecutedError!u64 {
        const machine = this.findMachine(id) orelse {
            this.last_error = @errorName(MachineSetRamSizeError.MachineNotFound);

            return MachineSetRamSizeError.MachineNotFound;
        };

        return machine.executed;
    }

    pub inline fn machineSetSensors(this: *State, id: Machine.Id, temperature: i16, power_usage: u16, overheat: bool, throttled: bool) MachineSetSensorsError!void {
        const machine = this.findMachine(id) orelse {
            this.last_error = @errorName(MachineSetRamSizeError.MachineNotFound);

            return MachineSetRamSizeError.MachineNotFound;
        };

        machine.sensors = .{
            .temperature = temperature,
            .power_usage = power_usage,
            .flags = .{
                .overheat = overheat,
                .throttled = throttled,
            },
        };
    }

    pub inline fn machineSetPostTickProc(this: *State, id: Machine.Id, proc_name_id: ?u32) MachineSetProcError!void {
        const machine = this.findMachine(id) orelse {
            this.last_error = @errorName(MachineSetProcError.MachineNotFound);

            return MachineSetProcError.MachineNotFound;
        };

        machine.post_tick_proc = proc_name_id;
    }

    pub inline fn machineSetTrapProc(this: *State, id: Machine.Id, proc_name_id: ?u32) MachineSetProcError!void {
        const machine = this.findMachine(id) orelse {
            this.last_error = @errorName(MachineSetProcError.MachineNotFound);

            return MachineSetProcError.MachineNotFound;
        };

        machine.trap_proc = proc_name_id;
    }

    pub inline fn machineSetSyscallProc(this: *State, id: Machine.Id, proc_name_id: ?u32) MachineSetProcError!void {
        const machine = this.findMachine(id) orelse {
            this.last_error = @errorName(MachineSetProcError.MachineNotFound);

            return MachineSetProcError.MachineNotFound;
        };

        machine.syscall_proc = proc_name_id;
    }

    pub inline fn machineLoadElf(this: *State, id: Machine.Id, path: []const u8) MachineLoadElfError!void {
        const machine = this.findMachine(id) orelse {
            this.last_error = @errorName(MachineLoadElfError.MachineNotFound);

            return MachineLoadElfError.MachineNotFound;
        };

        const file_content = std.fs.cwd().readFileAlloc(this.alloc.allocator(), path, MAX_FILE_SIZE) catch |err| switch (err) {
            error.FileNotFound => {
                this.last_error = @errorName(MachineLoadElfError.FileNotFound);

                return MachineLoadElfError.FileNotFound;
            },
            error.FileTooBig => {
                this.last_error = @errorName(MachineLoadElfError.FileTooBig);

                return MachineLoadElfError.FileTooBig;
            },
            error.OutOfMemory => {
                this.last_error = @errorName(MachineLoadElfError.OutOfMemory);

                return MachineLoadElfError.OutOfMemory;
            },
            else => {
                this.last_error = @errorName(MachineLoadElfError.Unknown);

                return MachineLoadElfError.Unknown;
            },
        };

        defer this.alloc.allocator().free(file_content);

        _ = machine.loadElf(this.alloc.allocator(), file_content) catch |err| switch (err) {
            error.OutOfRam => {
                this.last_error = @errorName(MachineLoadElfError.OutOfRam);

                return MachineLoadElfError.OutOfRam;
            },
            else => {
                this.last_error = @errorName(MachineLoadElfError.BadElf);

                return MachineLoadElfError.BadElf;
            },
        };
    }

    pub inline fn machineSyscall(this: *State, id: Machine.Id, slot: u8, args: []const x.ByondValue) MachineSyscallError!x.ByondValue {
        const machine = this.findMachine(id) orelse {
            this.last_error = @errorName(MachineSyscallError.MachineNotFound);

            return MachineSyscallError.MachineNotFound;
        };

        return machine.syscall(slot, args) catch |err| {
            this.last_error = @errorName(err);

            return err;
        };
    }

    pub inline fn machineTryAttachPci(this: *State, id: Machine.Id, type_id: u8) MachineAttachPciError!?u8 {
        const machine = this.findMachine(id) orelse {
            this.last_error = @errorName(MachineAttachPciError.MachineNotFound);

            return MachineAttachPciError.MachineNotFound;
        };

        const sdk_type_id = std.enums.fromInt(sdk.Pci.DeviceType, type_id) orelse {
            this.last_error = @errorName(MachineAttachPciError.BadDeviceType);

            return MachineAttachPciError.BadDeviceType;
        };

        const device: Device = switch (sdk_type_id) {
            .none, _ => {
                this.last_error = @errorName(MachineAttachPciError.BadDeviceType);

                return MachineAttachPciError.BadDeviceType;
            },
            .tts => .{ .tts = .{} },
            .serial_terminal => .{
                .serial_terminal = SerialTerminal.init(this.alloc.allocator()) catch {
                    std.log.err("Failed to allocate memory for a serial terminal device", .{});
                    this.last_error = @errorName(MachineAttachPciError.OutOfMemory);

                    return MachineAttachPciError.OutOfMemory;
                },
            },
            .signaler => .{ .signaler = .{} },
        };

        return machine.tryAttachPci(device);
    }

    pub inline fn machineTryDetachPci(this: *State, id: Machine.Id, slot: u8) MachineDetachPciError!bool {
        const machine = this.findMachine(id) orelse {
            this.last_error = @errorName(MachineDetachPciError.MachineNotFound);

            return MachineDetachPciError.MachineNotFound;
        };

        return machine.tryDetachPci(slot);
    }

    pub inline fn machineAppendCounters(this: *State, id: Machine.Id, cycles: u64, idle_cycles: u64, mtime: u64) MachineAppendCountersError!void {
        const machine = this.findMachine(id) orelse {
            this.last_error = @errorName(MachineAppendCountersError.MachineNotFound);

            return MachineAppendCountersError.MachineNotFound;
        };

        machine.cpu.registers.cycle +%= cycles;
        machine.idle_executed += idle_cycles;
        machine.cpu.registers.mtime +%= mtime;
    }

    pub inline fn machinesTick(this: *State, delta_us: u32) void {
        const wall_budget_us: i64 = @divFloor(@as(i64, delta_us) * this.budget_percent, 100);
        const wall_start = std.time.microTimestamp();

        if (this.machines.items.len == 0) {
            this.updateStats(wall_start, delta_us);

            return;
        }

        var served: usize = 0;

        while (served < this.machines.items.len) : (served += 1) {
            const idx = (this.robin_index + served) % this.machines.items.len;
            var machine = &this.machines.items[idx];

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
            this.last_error = @errorName(MachineDumpRegistersError.MachineNotFound);

            return MachineDumpRegistersError.MachineNotFound;
        };

        var writer: std.Io.Writer.Allocating = .init(this.alloc.allocator());
        std.json.Stringify.value(machine.cpu.registers, .{}, &writer.writer) catch {
            this.last_error = @errorName(MachineDumpRegistersError.OutOfMemory);

            return MachineDumpRegistersError.OutOfMemory;
        };
        errdefer writer.deinit();

        return writer.toOwnedSliceSentinel(0) catch {
            this.last_error = @errorName(MachineDumpRegistersError.OutOfMemory);

            return MachineDumpRegistersError.OutOfMemory;
        };
    }

    pub inline fn machineDestroy(this: *State, id: Machine.Id) bool {
        if (this.findMachineEntry(id)) |entry| {
            entry.ptr.deinit(this.alloc.allocator());
            _ = this.machines.swapRemove(entry.idx);

            return true;
        }

        return false;
    }

    pub inline fn deinit(this: *State) void {
        std.log.info("deinit", .{});

        for (this.machines.items) |*machine| {
            machine.deinit(this.alloc.allocator());
        }

        this.machines.deinit(this.alloc.allocator());
        _ = this.alloc.deinit();
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

var _state: ?State = null;

inline fn getState() *State {
    if (_state == null) {
        const alloc: std.heap.DebugAllocator(.{}) = .init;

        _state = .{
            .alloc = alloc,
        };
    }

    return &_state.?;
}

// all the exported functions should return ByondValue as a u64 number,
// otherwise your balls will explode.

pub export fn Z_get_last_error(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) u64 {
    _ = argv;

    if (argc != 0) {
        x.Byond_CRASH("Z_get_last_error does not accept args");

        return 0;
    }

    const state = getState();
    var ret: x.ByondValue = .{};

    if (state.last_error) |msg| {
        x.ByondValue_SetStr(&ret, msg);
    }

    return @bitCast(ret);
}

pub export fn Z_machine_create(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) u64 {
    _ = argv;

    if (argc != 0) {
        x.Byond_CRASH("Z_machine_create does not accept args");

        return 0;
    }

    const state = getState();
    const id = state.machineCreate() catch {
        return 0;
    };

    return @bitCast(x.Num(@floatFromInt(id)));
}

pub export fn Z_machine_reset(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) u64 {
    const args = argv[0..argc];

    if (args.len != 1) {
        x.Byond_CRASH("Z_machine_reset requires 1 argument");

        return 0;
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));

    state.machineReset(id) catch {
        return @bitCast(x.False());
    };

    return @bitCast(x.True());
}

pub export fn Z_machine_connect(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) u64 {
    const args = argv[0..argc];

    if (args.len != 2) {
        x.Byond_CRASH("Z_macine_connect requires 2 arguments");

        return 0;
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const src_object = &args[1];

    state.machineConnect(id, if (x.ByondValue_IsNull(src_object)) null else src_object.*) catch {
        return @bitCast(x.False());
    };

    return @bitCast(x.True());
}

pub export fn Z_machine_set_ram_size(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) u64 {
    const args = argv[0..argc];

    if (args.len != 2) {
        x.Byond_CRASH("Z_machine_set_ram_size requires 2 arguments");

        return 0;
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const ram_size: u32 = @intFromFloat(x.ByondValue_GetNum(&args[1]));

    state.machineSetRamSize(id, ram_size) catch {
        return @bitCast(x.False());
    };

    return @bitCast(x.True());
}

pub export fn Z_machine_get_ram_size(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) u64 {
    const args = argv[0..argc];

    if (args.len != 1) {
        x.Byond_CRASH("Z_machine_get_ram_size requires 1 argument");

        return 0;
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));

    const size = state.machineGetRamSize(id) catch {
        return 0;
    };

    return @bitCast(x.Num(@floatFromInt(size)));
}

pub export fn Z_machine_read_ram_byte(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) u64 {
    const args = argv[0..argc];

    if (args.len != 2) {
        x.Byond_CRASH("Z_machine_read_ram_byte requires 2 arguments");

        return 0;
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const address: u32 = @intFromFloat(x.ByondValue_GetNum(&args[1]));

    const value = state.machineReadRamByte(id, address) catch {
        return 0;
    };

    return @bitCast(x.Num(@floatFromInt(value)));
}

pub export fn Z_machine_write_ram_byte(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) u64 {
    const args = argv[0..argc];

    if (args.len != 3) {
        x.Byond_CRASH("Z_machine_write_ram_byte requires 3 arguments");

        return 0;
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const address: u32 = @intFromFloat(x.ByondValue_GetNum(&args[1]));
    const value: u8 = @intFromFloat(x.ByondValue_GetNum(&args[2]));

    state.machineWriteRamByte(id, address, value) catch {
        return @bitCast(x.False());
    };

    return @bitCast(x.True());
}

pub export fn Z_machine_read_ram_bytes(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) u64 {
    const args = argv[0..argc];

    if (args.len != 3) {
        x.Byond_CRASH("Z_machine_read_ram_bytes requires 3 arguments");

        return 0;
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const address: u32 = @intFromFloat(x.ByondValue_GetNum(&args[1]));
    const dst = &args[2];

    if (!x.ByondValue_IsList(dst)) {
        x.Byond_CRASH("Z_machine_read_ram_bytes requires a list as the third argument");

        return @bitCast(x.False());
    }

    state.machineReadRamBytes(id, address, dst) catch {
        return @bitCast(x.False());
    };

    return @bitCast(x.True());
}

pub export fn Z_machine_write_ram_bytes(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) u64 {
    const args = argv[0..argc];

    if (args.len != 3) {
        x.Byond_CRASH("Z_machine_write_ram_bytes requires 3 arguments");

        return 0;
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const address: u32 = @intFromFloat(x.ByondValue_GetNum(&args[1]));
    const src = &args[2];

    if (!x.ByondValue_IsList(src)) {
        x.Byond_CRASH("Z_machine_write_ram_bytes requires a list as the third argument");

        return @bitCast(x.False());
    }

    state.machineWriteRamBytes(id, address, src) catch {
        return @bitCast(x.False());
    };

    return @bitCast(x.True());
}

pub export fn Z_machine_set_frequency(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) u64 {
    const args = argv[0..argc];

    if (args.len != 2) {
        x.Byond_CRASH("Z_machine_set_frequency requires 2 arguments");

        return 0;
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const frequency: u32 = @intFromFloat(x.ByondValue_GetNum(&args[1]));

    state.machineSetFrequency(id, frequency) catch {
        return @bitCast(x.False());
    };

    return @bitCast(x.True());
}

pub export fn Z_machine_set_state(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) u64 {
    const args = argv[0..argc];

    if (args.len != 2) {
        x.Byond_CRASH("Z_machine_set_state requires 2 arguments");

        return 0;
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const machine_state: u32 = @intFromFloat(x.ByondValue_GetNum(&args[1]));

    state.machineSetState(id, machine_state) catch {
        return @bitCast(x.False());
    };

    return @bitCast(x.True());
}

pub export fn Z_machine_get_state(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) u64 {
    const args = argv[0..argc];

    if (args.len != 1) {
        x.Byond_CRASH("Z_machine_get_state requires 1 argument");

        return 0;
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));

    const machine_state = state.machineGetState(id) catch {
        return @bitCast(x.False());
    };

    return @bitCast(x.Num(@floatFromInt(@intFromEnum(machine_state))));
}

pub export fn Z_machine_get_utilization(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) u64 {
    const args = argv[0..argc];

    if (args.len != 1) {
        x.Byond_CRASH("Z_machine_get_utilization requires 1 argument");

        return 0;
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));

    const utilization = state.machineGetUtilization(id) catch {
        return @bitCast(x.False());
    };

    return @bitCast(x.Num(utilization));
}

pub export fn Z_machine_get_executed(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) u64 {
    const args = argv[0..argc];

    if (args.len != 1) {
        x.Byond_CRASH("Z_machine_get_executed requires 1 argument");

        return 0;
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));

    const executed = state.machineGetExecuted(id) catch {
        return @bitCast(x.False());
    };
    const executed_32: u32 = @truncate(executed);

    return @bitCast(x.Num(@floatFromInt(executed_32)));
}

pub export fn Z_machine_set_sensors(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) u64 {
    const args = argv[0..argc];

    if (args.len != 5) {
        x.Byond_CRASH("Z_machine_set_sensors requires 5 argument");

        return 0;
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const temperature: i32 = @intFromFloat(x.ByondValue_GetNum(&args[1]));
    const power_usage: u32 = @intFromFloat(x.ByondValue_GetNum(&args[2]));
    const overheat = x.ByondValue_IsTrue(&args[3]);
    const throttled = x.ByondValue_IsTrue(&args[4]);

    state.machineSetSensors(id, @truncate(temperature), @truncate(power_usage), overheat, throttled) catch {
        return @bitCast(x.False());
    };

    return @bitCast(x.True());
}

pub export fn Z_machine_set_post_tick_proc(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) u64 {
    const args = argv[0..argc];

    if (args.len != 2) {
        x.Byond_CRASH("Z_machine_set_post_tick_proc requires 2 arguments");

        return 0;
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const proc = &args[1];

    if (x.ByondValue_IsNull(proc)) {
        state.machineSetPostTickProc(id, null) catch {
            return @bitCast(x.False());
        };

        return @bitCast(x.True());
    }

    if (!x.ByondValue_IsStr(proc)) {
        x.Byond_CRASH("The proc name should be a string");

        return @bitCast(x.False());
    }

    state.machineSetPostTickProc(id, x.ByondValue_GetRef(proc)) catch {
        return @bitCast(x.False());
    };

    return @bitCast(x.True());
}

pub export fn Z_machine_set_trap_proc(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) u64 {
    const args = argv[0..argc];

    if (args.len != 2) {
        x.Byond_CRASH("Z_machine_set_trap_proc requires 2 arguments");

        return 0;
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const proc = &args[1];

    if (x.ByondValue_IsNull(proc)) {
        state.machineSetTrapProc(id, null) catch {
            return @bitCast(x.False());
        };

        return @bitCast(x.True());
    }

    if (!x.ByondValue_IsStr(proc)) {
        x.Byond_CRASH("The proc name should be a string");

        return @bitCast(x.False());
    }

    state.machineSetTrapProc(id, x.ByondValue_GetRef(proc)) catch {
        return @bitCast(x.False());
    };

    return @bitCast(x.True());
}

pub export fn Z_machine_set_syscall_proc(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) u64 {
    const args = argv[0..argc];

    if (args.len != 2) {
        x.Byond_CRASH("Z_machine_set_syscall_proc requires 2 arguments");

        return 0;
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const proc = &args[1];

    if (x.ByondValue_IsNull(proc)) {
        state.machineSetSyscallProc(id, null) catch {
            return @bitCast(x.False());
        };

        return @bitCast(x.True());
    }

    if (!x.ByondValue_IsStr(proc)) {
        x.Byond_CRASH("The proc name should be a string");

        return 0;
    }

    state.machineSetSyscallProc(id, x.ByondValue_GetRef(proc)) catch {
        return @bitCast(x.False());
    };

    return @bitCast(x.True());
}

pub export fn Z_machine_append_counters(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) u64 {
    const args = argv[0..argc];

    if (args.len != 4) {
        x.Byond_CRASH("Z_machine_append_cycles requires 3 arguments");

        return 0;
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const cycles: u32 = @intFromFloat(x.ByondValue_GetNum(&args[1]));
    const idle_cycles: u32 = @intFromFloat(x.ByondValue_GetNum(&args[2]));
    const mtime: u32 = @intFromFloat(x.ByondValue_GetNum(&args[3]));

    state.machineAppendCounters(id, cycles, idle_cycles, mtime) catch {
        return @bitCast(x.False());
    };

    return @bitCast(x.True());
}

pub export fn Z_machine_load_elf(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) u64 {
    const args = argv[0..argc];

    if (args.len != 2) {
        x.Byond_CRASH("Z_machine_load_elf requires 2 arguments");

        return 0;
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));

    const byond_path = &args[1];
    var len: u32 = 0;

    if (!x.Byond_ToString(byond_path, null, &len) and len == 0) {
        x.Byond_CRASH("Failed to convert the path argument to a string");

        return 0;
    }

    const path = state.alloc.allocator().allocSentinel(u8, len - 1, 0) catch {
        x.Byond_CRASH("Failed to allocate a memory for a path: Out of memory");

        return 0;
    };
    defer state.alloc.allocator().free(path);

    if (!x.Byond_ToString(byond_path, path.ptr, &len)) {
        x.Byond_CRASH("Failed to convert the path argument to a string");

        return 0;
    }

    state.machineLoadElf(id, path) catch {
        return @bitCast(x.False());
    };

    return @bitCast(x.True());
}

pub export fn Z_machine_syscall(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) u64 {
    const args = argv[0..argc];

    if (args.len < 2) {
        x.Byond_CRASH("Z_machine_syscall requires at least 2 arguments");

        return 0;
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const slot: u32 = @intFromFloat(x.ByondValue_GetNum(&args[1]));

    const ret = state.machineSyscall(id, @truncate(slot), args[2..]) catch {
        return 0;
    };

    return @bitCast(ret);
}

pub export fn Z_machine_try_attach_pci(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) u64 {
    const args = argv[0..argc];

    if (args.len != 2) {
        x.Byond_CRASH("Z_machine_try_attach_pci requires 2 arguments");

        return 0;
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const type_id: u8 = @intFromFloat(x.ByondValue_GetNum(&args[1]));

    const pci_slot = state.machineTryAttachPci(id, type_id) catch {
        return 0;
    };

    if (pci_slot == null) {
        return 0;
    }

    return @bitCast(x.Num(@floatFromInt(pci_slot.?)));
}

pub export fn Z_machine_try_detach_pci(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) u64 {
    const args = argv[0..argc];

    if (args.len != 2) {
        x.Byond_CRASH("Z_machine_try_detach_pci requires 2 arguments");

        return 0;
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const slot: u32 = @intFromFloat(x.ByondValue_GetNum(&args[1]));

    const was_removed = state.machineTryDetachPci(id, @truncate(slot)) catch {
        return 0;
    };

    return if (was_removed)
        @bitCast(x.True())
    else
        @bitCast(x.False());
}

pub export fn Z_machine_dump_registers(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) u64 {
    const args = argv[0..argc];

    if (args.len != 1) {
        x.Byond_CRASH("Z_machine_dump_registers requires 1 argument");

        return 0;
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));

    const dump = state.machineDumpRegisters(id) catch {
        return 0;
    };
    defer state.alloc.allocator().free(dump);

    var ret: x.ByondValue = .{};
    x.ByondValue_SetStr(&ret, dump);

    return @bitCast(ret);
}

pub export fn Z_machine_destroy(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) u64 {
    const args = argv[0..argc];

    if (args.len != 1) {
        x.Byond_CRASH("Z_machine_destroy requires 1 argument");

        return 0;
    }

    const state = getState();
    const id: Machine.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));

    return if (state.machineDestroy(id)) @bitCast(x.True()) else @bitCast(x.False());
}

pub export fn Z_machines_tick(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) u64 {
    const args = argv[0..argc];

    if (args.len != 1) {
        x.Byond_CRASH("Z_machines_tick requires 1 argument");

        return 0;
    }

    const state = getState();
    const delta_us: u32 = @intFromFloat(x.ByondValue_GetNum(&args[0]));

    state.machinesTick(delta_us);

    return @bitCast(x.True());
}

pub export fn Z_machines_stats(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) u64 {
    _ = argv;

    if (argc != 0) {
        x.Byond_CRASH("Z_machines_stats does not accept args");

        return 0;
    }

    const state = getState();
    const stats = state.stats;

    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    std.json.Stringify.value(stats, .{}, &writer) catch {
        x.Byond_CRASH("Failed to format the stats");

        return @bitCast(x.False());
    };

    writer.writeByte(0) catch {
        x.Byond_CRASH("Failed to format the stats");

        return 0;
    };

    var ret: x.ByondValue = .{};
    x.ByondValue_SetStr(&ret, buffer[0 .. writer.end - 1 :0]);

    return @bitCast(ret);
}

pub export fn Z_machines_set_budget(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) u64 {
    const args = argv[0..argc];

    if (args.len != 1) {
        x.Byond_CRASH("Z_machines_set_budget requires 1 argument");

        return 0;
    }

    const budget: u32 = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const state = getState();

    state.budget_percent = std.math.clamp(budget, 10, 80);

    return @bitCast(x.True());
}

pub export fn Z_deinit(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) u64 {
    _ = argc;
    _ = argv;

    if (_state) |*state| {
        state.deinit();
    }

    _state = null;

    return @bitCast(x.True());
}

comptime {
    _ = x;
}
