// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");

const zlua = @import("zlua");

const x = @import("x.zig");
const z = @import("root.zig");
const helpers = @import("helpers.zig");

inline fn getState() *State {
    return &z.getState().mlstate;
}

fn lua_print(str: []const u8) void {
    std.log.info("luau: {s}", .{str});
}

const Machine = struct {
    pub const State = enum(u8) {
        stopped = 1,
        running = 2,
    };

    const LuaState = struct {
        global: *zlua.Lua,

        pub inline fn init(allocator: std.mem.Allocator) error{ OutOfMemory, LuaError }!LuaState {
            const lua = try zlua.Lua.init(allocator);
            errdefer lua.deinit();

            lua.openBase();
            lua.openMath();
            lua.openString();
            lua.openTable();

            lua.autoPushFunction(lua_print);
            lua.setGlobal("print");
            lua.setInterruptCallbackFn(interruptCallback);

            return .{
                .global = lua,
            };
        }

        pub inline fn deinit(this: *LuaState) void {
            this.global.deinit();
        }

        pub inline fn loadBytecode(this: *LuaState, bytecode: []const u8) error{LuaError}!void {
            try this.global.loadBytecode("eeprom", bytecode);
        }

        fn interruptCallback(state: ?*zlua.LuaState, gc: c_int) callconv(.c) void {
            _ = gc;

            const lua: ?*zlua.Lua = @ptrCast(state);
            _ = lua.?.yield(0);
        }
    };

    src: x.ByondValue,
    ram: []u8,
    lua_allocator: *std.heap.FixedBufferAllocator,
    lua: ?LuaState = null,
    eeprom: ?[]const u8 = null,
    state: Machine.State = .stopped,

    pub inline fn init(allocator: std.mem.Allocator, src: x.ByondValue, ram_size: u32) error{OutOfMemory}!Machine {
        const ram = try allocator.alloc(u8, ram_size);
        errdefer allocator.free(ram);

        @memset(ram, 0);

        const lua_allocator = try allocator.create(std.heap.FixedBufferAllocator);
        errdefer allocator.destroy(lua_allocator);

        lua_allocator.* = .init(ram);

        return .{
            .src = src,
            .ram = ram,
            .lua_allocator = lua_allocator,
        };
    }

    pub inline fn deinit(this: *Machine, allocator: std.mem.Allocator) void {
        if (this.eeprom) |eeprom| {
            allocator.free(eeprom);
            this.eeprom = null;
        }

        if (this.lua) |*l| {
            l.deinit();
        }

        allocator.destroy(this.lua_allocator);
        allocator.free(this.ram);

        x.ByondValue_DecRef(&this.src);
    }

    pub inline fn loadEeprom(this: *Machine, allocator: std.mem.Allocator, source: []const u8) error{OutOfMemory}!void {
        if (this.eeprom) |eeprom| {
            allocator.free(eeprom);
            this.eeprom = null;
        }

        const options: zlua.CompileOptions = .{
            .optimization_level = 2,
            .debug_level = 0,
            .type_info_level = 0,
            .coverage_level = 0,
        };

        this.eeprom = try zlua.compile(allocator, source, options);
    }

    pub inline fn setState(this: *Machine, state: Machine.State) error{ OutOfMemory, LuaError }!void {
        if (this.state == state) {
            return;
        }

        if (this.lua) |*l| {
            l.deinit();
        }

        if (state == .stopped) {
            this.state = state;

            return;
        }

        if (this.eeprom == null) {
            return;
        }

        this.state = state;
        this.lua_allocator.reset();

        errdefer this.state = .stopped;

        this.lua = try LuaState.init(this.lua_allocator.allocator());
        errdefer this.lua.?.deinit();

        try this.lua.?.loadBytecode(this.eeprom.?);
    }
};

const MachineCreateError = error{
    OutOfMemory,
};

const MachineDestroyError = error{
    MachineNotFound,
};

const MachineLoadEepromError = error{
    MachineNotFound,
    OutOfMemory,
};

const MachineSetStateError = error{
    MachineNotFound,
    OutOfMemory,
    LuaError,
};

const MachineGetStateError = error{
    MachineNotFound,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    machines: std.ArrayList(Machine) = .empty,

    pub inline fn init(allocator: std.mem.Allocator) State {
        return .{
            .allocator = allocator,
        };
    }

    pub inline fn deinit(this: *State) void {
        _ = this;
    }

    pub inline fn machineCreate(this: *State, src: x.ByondValue, ram_size: u32) MachineCreateError!void {
        var machine = Machine.init(this.allocator, src, ram_size) catch |err| {
            z.getState().last_error = @errorName(err);

            return err;
        };
        errdefer machine.deinit(this.allocator);

        this.machines.append(this.allocator, machine) catch |err| {
            z.getState().last_error = @errorName(err);

            return err;
        };
    }

    pub inline fn machineDestroy(this: *State, src: x.ByondValue) bool {
        const ref = x.ByondValue_GetRef(&src);

        for (0..this.machines.items.len) |i| {
            const m = &this.machines.items[i];
            const m_ref = x.ByondValue_GetRef(&m.src);

            if (m_ref != ref) {
                continue;
            }

            _ = this.machines.swapRemove(i);
            m.deinit(this.allocator);

            return true;
        }

        return false;
    }

    pub inline fn tick(this: *State) void {
        for (this.machines.items) |*m| {
            if (m.state != .running) {
                continue;
            }

            m.state = .stopped;

            const resume_status = m.lua.?.global.resumeThreadLuau(null, 0) catch |err| {
                std.log.err("Resume error: {t}\n", .{err});

                continue;
            };
            // const resume_status = m.lua.?.main_thread.resumeThreadLuau(null, 0) catch |err| {
            //     std.log.err("Resume error: {t}\n", .{err});

            //     continue;
            // };

            std.log.info("Resume status = {t}", .{resume_status});
        }
    }

    pub inline fn machineLoadEeprom(this: *const State, src: x.ByondValue, source: []const u8) MachineLoadEepromError!void {
        const machine = this.findMachine(src) orelse {
            z.getState().last_error = @errorName(MachineLoadEepromError.MachineNotFound);

            return MachineLoadEepromError.MachineNotFound;
        };

        machine.loadEeprom(this.allocator, source) catch |err| {
            z.getState().last_error = @errorName(err);

            return err;
        };
    }

    pub inline fn machineSetState(this: *const State, src: x.ByondValue, state: Machine.State) MachineSetStateError!void {
        const machine = this.findMachine(src) orelse {
            z.getState().last_error = @errorName(MachineSetStateError.MachineNotFound);

            return MachineSetStateError.MachineNotFound;
        };

        machine.setState(state) catch |err| {
            z.getState().last_error = @errorName(err);

            return err;
        };
    }

    pub inline fn machineGetState(this: *const State, src: x.ByondValue) MachineGetStateError!Machine.State {
        const machine = this.findMachine(src) orelse {
            z.getState().last_error = @errorName(MachineGetStateError.MachineNotFound);

            return MachineGetStateError.MachineNotFound;
        };

        return machine.state;
    }

    const MachineEntry = struct {
        ptr: *Machine,
        idx: usize,
    };

    inline fn findMachineEntry(this: *const State, src: x.ByondValue) ?MachineEntry {
        const ref = x.ByondValue_GetRef(&src);

        for (this.machines.items, 0..) |*m, idx| {
            const mref = x.ByondValue_GetRef(&m.src);

            if (ref != mref) {
                continue;
            }

            return .{ .ptr = m, .idx = idx };
        }

        return null;
    }

    inline fn findMachine(this: *const State, src: x.ByondValue) ?*Machine {
        if (this.findMachineEntry(src)) |entry| {
            return entry.ptr;
        }

        return null;
    }
};

pub export fn Z_machine_l_create(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 2) {
        x.Byond_CRASH("Z_machine_l_create requires 2 arguments");

        return z.returnCast(.{});
    }

    const state = getState();
    const src = args[0];
    const ram_size = helpers.safeIntTruncate(u32, x.ByondValue_GetNum(&args[1])) orelse {
        x.Byond_CRASH("Bad ram_size");

        return z.returnCast(.{});
    };

    state.machineCreate(src, ram_size) catch {
        return z.returnCast(.{});
    };

    return z.returnCast(x.True());
}

pub export fn Z_machine_l_destroy(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 2) {
        x.Byond_CRASH("Z_machine_l_destroy requires 1 argument");

        return z.returnCast(.{});
    }

    const state = getState();
    const src = args[0];

    return if (state.machineDestroy(src))
        z.returnCast(x.True())
    else
        z.returnCast(x.False());
}

pub export fn Z_machines_l_tick(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    _ = argv;

    if (argc != 0) {
        x.Byond_CRASH("Z_machines_l_tick does not accept arguments");
    }

    const state = getState();
    state.tick();

    return z.returnCast(x.True());
}

pub export fn Z_machine_l_load_eeprom(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 2) {
        x.Byond_CRASH("Z_machine_l_load_eeprom requires 1 argument");

        return z.returnCast(.{});
    }

    const state = getState();
    const src = args[0];
    const byond_content = args[1];

    if (!x.ByondValue_IsStr(&byond_content)) {
        x.Byond_CRASH("Argument content is not a string");

        return z.returnCast(.{});
    }

    const content = x.toString(state.allocator, &byond_content) catch {
        x.Byond_CRASH("Failed to Byond_ToString the content argument");

        return z.returnCast(.{});
    };
    defer state.allocator.free(content);

    state.machineLoadEeprom(src, content) catch {
        return z.returnCast(.{});
    };

    return z.returnCast(x.True());
}

pub export fn Z_machine_l_set_state(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 2) {
        x.Byond_CRASH("Z_machine_l_set_state requires 2 arguments");

        return z.returnCast(.{});
    }

    const state = getState();
    const src = args[0];
    const raw_state = helpers.safeInt(x.ByondValue_GetNum(&args[1])) orelse {
        x.Byond_CRASH("Bad state");

        return z.returnCast(.{});
    };

    const mstate = std.enums.fromInt(Machine.State, raw_state) orelse {
        x.Byond_CRASH("Bad state");

        return z.returnCast(.{});
    };

    state.machineSetState(src, mstate) catch {
        return z.returnCast(.{});
    };

    return z.returnCast(x.True());
}

pub export fn Z_machine_l_get_state(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 1) {
        x.Byond_CRASH("Z_machine_l_set_state requires 1 argument");

        return z.returnCast(.{});
    }

    const state = getState();
    const src = args[0];

    const mstate = state.machineGetState(src) catch {
        return z.returnCast(.{});
    };

    return z.returnCast(x.num(@intFromEnum(mstate)));
}
