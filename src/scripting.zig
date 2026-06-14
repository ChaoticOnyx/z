// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");

const c = @import("basic26");

const helpers = @import("helpers.zig");
const x = @import("x.zig");
const z = @import("root.zig");

inline fn getState() *State {
    return &z.getState().sstate;
}

const VarCast = enum(u32) {
    none = 0,
    int = 1,
    symbol = 2,
    object = 3,
    address = 4,
};

const ScriptResult = enum(u32) {
    err = 0,
    ok = 1,
    yielded = 2,
    out_of_memory = 3,
    out_of_limits = 4,
};

const CompileResult = enum(u32) {
    err = 0,
    ok = 1,
    out_of_memory = 2,
    out_of_limits = 3,
};

const VarType = enum(u32) {
    null = 0,
    int = 1,
    float = 2,
    string = 3,
    symbol = 4,
    object = 5,
    address = 6,
};

const Typing = packed struct {
    null: bool = false,
    int: bool = false,
    float: bool = false,
    string: bool = false,
    symbol: bool = false,
    object: bool = false,
    address: bool = false,
    varargs: bool = false,
    _padding: u24 = 0,

    pub inline fn isAny(this: Typing) bool {
        return this == Typing{};
    }

    pub inline fn isTypeAllowed(this: Typing, ty: c_uint) bool {
        if (this.isAny()) {
            return true;
        }

        switch (ty) {
            c.BASIC26_VALUE_TYPE_NULL => {
                return this.null;
            },
            c.BASIC26_VALUE_TYPE_INT => {
                return this.int;
            },
            c.BASIC26_VALUE_TYPE_FLOAT => {
                return this.float;
            },
            c.BASIC26_VALUE_TYPE_STRING => {
                return this.string;
            },
            c.BASIC26_VALUE_TYPE_SYMBOL => {
                return this.symbol;
            },
            c.BASIC26_VALUE_TYPE_OBJECT => {
                return this.object;
            },
            c.BASIC26_VALUE_TYPE_ADDRESS => {
                return this.address;
            },
            else => return false,
        }
    }
};

const FunctionResult = enum(u32) {
    err = 0,
    ok = 1,
    yield = 2,
};

const MAX_ARGS: usize = 16;

const LimitedAllocator = struct {
    child: std.mem.Allocator,
    used: usize = 0,
    max: usize = 0,

    pub inline fn init(child: std.mem.Allocator, max: usize) LimitedAllocator {
        return .{
            .child = child,
            .max = max,
        };
    }

    pub inline fn allocator(this: *LimitedAllocator) std.mem.Allocator {
        return .{
            .ptr = this,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const this: *LimitedAllocator = @ptrCast(@alignCast(ctx));

        if ((this.used +| len) > this.max) {
            return null;
        }

        const ret = this.child.rawAlloc(len, alignment, ret_addr) orelse {
            return null;
        };

        this.used += len;

        return ret;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const this: *LimitedAllocator = @ptrCast(@alignCast(ctx));

        if (new_len > memory.len and this.used +| (new_len - memory.len) > this.max) {
            return false;
        }

        const ret = this.child.rawResize(memory, alignment, new_len, ret_addr);

        if (ret) {
            if (new_len > memory.len) {
                this.used +|= new_len - memory.len;
            } else {
                this.used -|= memory.len - new_len;
            }
        }

        return ret;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const this: *LimitedAllocator = @ptrCast(@alignCast(ctx));

        if (new_len > memory.len and this.used +| (new_len - memory.len) > this.max) {
            return null;
        }

        const ret = this.child.rawRemap(memory, alignment, new_len, ret_addr) orelse {
            return null;
        };

        if (new_len > memory.len) {
            this.used +|= new_len - memory.len;
        } else {
            this.used -|= memory.len - new_len;
        }

        return ret;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const this: *LimitedAllocator = @ptrCast(@alignCast(ctx));

        this.child.rawFree(memory, alignment, ret_addr);
        this.used -|= memory.len;
    }
};

const ManagedObject = struct {
    src: x.ByondValue,
    gc_mark: bool,

    pub inline fn init(this: *ManagedObject, src: x.ByondValue) void {
        x.ByondValue_IncRef(&src);

        this.* = .{
            .src = src,
            .gc_mark = false,
        };
    }

    pub inline fn deinit(this: *ManagedObject) void {
        x.ByondValue_DecRef(&this.src);
        this.gc_mark = false;
    }
};

const Function = struct {
    name: c.basic26_SymbolId,
    callback: u32,
    src: ?x.ByondValue,
    typings: [MAX_ARGS]Typing,
    typings_len: usize,

    pub inline fn init(
        name: c.basic26_SymbolId,
        callback: u32,
        src: ?x.ByondValue,
        typings: [MAX_ARGS]Typing,
        typings_len: usize,
    ) Function {
        if (src != null) {
            x.ByondValue_IncRef(&src.?);
        }

        return .{
            .name = name,
            .callback = callback,
            .src = src,
            .typings = typings,
            .typings_len = typings_len,
        };
    }

    pub inline fn deinit(this: *Function) void {
        if (this.src != null) {
            x.ByondValue_DecRef(&this.src.?);
        }
    }
};

const CompileErrorInfo = struct {
    kind: c_uint,
    pos: usize,
};

const RuntimeError = struct {
    kind: c_uint,
    ip: usize,
};

const Script = struct {
    pub const Id = usize;

    const Pair = struct {
        src: x.ByondValue,
        object: *ManagedObject,

        pub inline fn init(src: x.ByondValue, object: *ManagedObject) Pair {
            return .{
                .src = src,
                .object = object,
            };
        }
    };

    id: Id,
    allocator: LimitedAllocator,
    src: x.ByondValue,
    vm: ?*c.basic26_Vm,
    state: ?*c.basic26_State,
    script: ?*c.basic26_Script,
    debug_info: ?*c.basic26_DebugInfo,
    objects: std.ArrayList(Pair),
    functions: std.ArrayList(Function),
    compile_error: ?CompileErrorInfo,
    runtime_error: ?RuntimeError,

    pub inline fn init(this: *Script, allocator: std.mem.Allocator, id: Id, src: x.ByondValue, memory_size: usize) error{OutOfMemory}!void {
        this.id = id;
        this.allocator = .init(allocator, memory_size);

        if (c.basic26_Vm_create(&.{
            .userdata = this,
            .alloc = vm_alloc,
            .free = vm_free,
        }, &this.vm) != c.BASIC26_RESULT_OK) {
            return error.OutOfMemory;
        }
        errdefer c.basic26_Vm_destroy(this.vm.?);

        if (c.basic26_State_create(this.vm.?, &this.state) != c.BASIC26_RESULT_OK) {
            return error.OutOfMemory;
        }
        errdefer c.basic26_State_destroy(this.state.?);

        if (c.basic26_Script_create(this.vm.?, &this.script) != c.BASIC26_RESULT_OK) {
            return error.OutOfMemory;
        }
        errdefer c.basic26_Script_destroy(this.script.?);

        if (c.basic26_DebugInfo_create(this.vm.?, &this.debug_info) != c.BASIC26_RESULT_OK) {
            return error.OutOfMemory;
        }
        errdefer c.basic26_DebugInfo_destroy(this.debug_info.?);

        x.ByondValue_IncRef(&src);
        this.src = src;
        this.objects = .empty;
        this.functions = .empty;
        this.compile_error = null;
        this.runtime_error = null;
    }

    pub inline fn deinit(this: *Script) void {
        for (this.objects.items) |pair| {
            pair.object.deinit();
            this.allocator.allocator().destroy(pair.object);
        }

        this.objects.deinit(this.allocator.allocator());

        for (this.functions.items) |*func| {
            func.deinit();
        }

        this.functions.deinit(this.allocator.allocator());

        c.basic26_DebugInfo_destroy(this.debug_info);
        c.basic26_Script_destroy(this.script);
        c.basic26_State_destroy(this.state);
        c.basic26_Vm_destroy(this.vm);

        x.ByondValue_DecRef(&this.src);
    }

    pub inline fn getOrCreateObject(this: *Script, src: x.ByondValue) error{OutOfMemory}!*ManagedObject {
        for (this.objects.items) |pair| {
            if (!std.mem.eql(u8, std.mem.asBytes(&src), std.mem.asBytes(&pair.src))) {
                continue;
            }

            return pair.object;
        }

        const object = try this.allocator.allocator().create(ManagedObject);
        errdefer this.allocator.allocator().destroy(object);

        try this.objects.append(this.allocator.allocator(), .init(src, object));
        object.init(src);

        return object;
    }

    pub inline fn gcCollect(this: *Script) void {
        var prev: ?*c.basic26_SymbolId = null;
        var it: c.basic26_SymbolId = 0;

        while (c.basic26_State_var_next(this.state, prev, &it)) {
            prev = &it;

            var value: c.basic26_Value = undefined;

            if (c.basic26_State_get_var(this.state, it, &value) != c.BASIC26_RESULT_OK) {
                std.log.err("failed to find a variable {d}", .{it});

                continue;
            }

            if (value.type != c.BASIC26_VALUE_TYPE_OBJECT) {
                continue;
            }

            const object: *ManagedObject = @ptrCast(@alignCast(value.as.object_ptr));
            object.gc_mark = true;
        }

        var i: usize = 0;

        while (i < this.objects.items.len) {
            const pair = this.objects.items[i];

            if (pair.object.gc_mark) {
                pair.object.gc_mark = false;
                i += 1;

                continue;
            }

            pair.object.deinit();
            this.allocator.allocator().destroy(pair.object);
            _ = this.objects.swapRemove(i);
        }
    }

    fn vm_alloc(ctx: ?*anyopaque, len: usize, alignment: usize) callconv(.c) ?*anyopaque {
        const this: *Script = @ptrCast(@alignCast(ctx.?));

        return this.allocator.allocator().rawAlloc(len, .fromByteUnits(alignment), 0);
    }

    fn vm_free(ctx: ?*anyopaque, ptr: ?*anyopaque, len: usize, alignment: usize) callconv(.c) void {
        const this: *Script = @ptrCast(@alignCast(ctx.?));

        const memory: []u8 = @as([*]u8, @ptrCast(@alignCast(ptr.?)))[0..len];
        this.allocator.allocator().rawFree(memory, .fromByteUnits(alignment), 0);
    }
};

const ScriptCreateError = error{
    OutOfId,
    OutOfMemory,
};

const HasVarError = error{
    ScriptNotFound,
};

const SetVarError = error{
    ScriptNotFound,
    BadInt,
    UnsupportedType,
    OutOfMemory,
};

const GetVarError = error{
    ScriptNotFound,
    VarNotFound,
    OutOfMemory,
};

const GetVarTypeError = error{
    ScriptNotFound,
    VarNotFound,
};

const UnsetVarError = error{
    ScriptNotFound,
};

const RegisterFunctionError = error{
    ScriptNotFound,
    AlreadyExists,
    BadTypings,
    OutOfMemory,
};

const UnregisterFunctionError = error{
    ScriptNotFound,
};

const CompileError = error{
    ScriptNotFound,
    OutOfLimits,
    OutOfMemory,
};

const GetCompileErrorKindError = error{
    ScriptNotFound,
};

const GetCompileErrorPosError = error{
    ScriptNotFound,
};

const RunError = error{
    ScriptNotFound,
    OutOfLimits,
    OutOfMemory,
};

const GetRuntimeErrorKindError = error{
    ScriptNotFound,
};

const GetRuntimeErrorIpError = error{
    ScriptNotFound,
};

const ClearError = error{
    ScriptNotFound,
};

const GcCollectError = error{
    ScriptNotFound,
};

const GetIpError = error{
    ScriptNotFound,
};

const SetIpError = error{
    ScriptNotFound,
};

const GetOpPos = error{
    ScriptNotFound,
    OutOfRange,
};

const GetUsedMemory = error{
    ScriptNotFound,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    next_id: Script.Id = 1,
    scripts: std.ArrayList(*Script) = .empty,

    pub inline fn init(allocator: std.mem.Allocator) State {
        return .{
            .allocator = allocator,
        };
    }

    pub inline fn deinit(this: *State) void {
        for (this.scripts.items) |script| {
            script.deinit();
            this.allocator.destroy(script);
        }

        this.scripts.deinit(this.allocator);
    }

    pub inline fn createScript(this: *State, src: x.ByondValue, memory_size: usize) ScriptCreateError!Script.Id {
        if (this.next_id == std.math.maxInt(Script.Id)) {
            z.getState().last_error = @errorName(ScriptCreateError.OutOfId);

            return ScriptCreateError.OutOfId;
        }

        const script = this.allocator.create(Script) catch {
            z.getState().last_error = @errorName(ScriptCreateError.OutOfMemory);

            return ScriptCreateError.OutOfMemory;
        };
        errdefer this.allocator.destroy(script);

        script.init(this.allocator, this.next_id, src, memory_size) catch {
            z.getState().last_error = @errorName(ScriptCreateError.OutOfMemory);

            return ScriptCreateError.OutOfMemory;
        };
        errdefer script.deinit();

        this.scripts.append(this.allocator, script) catch |err| {
            z.getState().last_error = @errorName(err);

            return err;
        };

        this.next_id += 1;

        return script.id;
    }

    pub inline fn destroyScript(this: *State, id: Script.Id) bool {
        if (this.findScripEntry(id)) |entry| {
            entry.ptr.deinit();
            this.allocator.destroy(entry.ptr);

            _ = this.scripts.swapRemove(entry.idx);

            return true;
        }

        return false;
    }

    pub inline fn hasVar(this: *State, id: Script.Id, name: []const u8) HasVarError!bool {
        const script = this.findScript(id) orelse {
            z.getState().last_error = @errorName(HasVarError.ScriptNotFound);

            return HasVarError.ScriptNotFound;
        };

        var symbol_id: c.basic26_SymbolId = undefined;

        if (c.basic26_Vm_get_string_id(script.vm.?, name.ptr, name.len, false, &symbol_id) != c.BASIC26_RESULT_OK) {
            return false;
        }

        var value: c.basic26_Value = undefined;

        if (c.basic26_State_get_var(script.state.?, symbol_id, &value) != c.BASIC26_RESULT_OK) {
            return false;
        }

        return true;
    }

    pub inline fn setVar(this: *State, id: Script.Id, name: []const u8, byond_value: x.ByondValue, cast: VarCast) SetVarError!void {
        const script = this.findScript(id) orelse {
            z.getState().last_error = @errorName(SetVarError.ScriptNotFound);

            return SetVarError.ScriptNotFound;
        };

        var symbol_id: c.basic26_SymbolId = undefined;

        if (c.basic26_Vm_get_string_id(script.vm, name.ptr, name.len, true, &symbol_id) != c.BASIC26_RESULT_OK) {
            z.getState().last_error = @errorName(SetVarError.OutOfMemory);

            return SetVarError.OutOfMemory;
        }

        const value = blk: {
            if (x.ByondValue_IsList(&byond_value)) {
                z.getState().last_error = @errorName(SetVarError.UnsupportedType);

                return SetVarError.UnsupportedType;
            }

            if (x.ByondValue_IsNum(&byond_value)) {
                if (cast == .int) {
                    const int = helpers.safeIntTruncate(c.basic26_IntType, x.ByondValue_GetNum(&byond_value)) orelse {
                        z.getState().last_error = @errorName(SetVarError.BadInt);

                        return SetVarError.BadInt;
                    };

                    break :blk c.basic26_Value{
                        .type = c.BASIC26_VALUE_TYPE_INT,
                        .as = .{
                            .int_val = int,
                        },
                    };
                } else if (cast == .address) {
                    const int = helpers.safeIntTruncate(usize, x.ByondValue_GetNum(&byond_value)) orelse {
                        z.getState().last_error = @errorName(SetVarError.BadInt);

                        return SetVarError.BadInt;
                    };

                    break :blk c.basic26_Value{
                        .type = c.BASIC26_VALUE_TYPE_ADDRESS,
                        .as = .{
                            .address_val = int,
                        },
                    };
                } else if (cast != .none) {
                    z.getState().last_error = @errorName(SetVarError.UnsupportedType);

                    return SetVarError.UnsupportedType;
                }

                break :blk c.basic26_Value{
                    .type = c.BASIC26_VALUE_TYPE_FLOAT,
                    .as = .{
                        .float_val = x.ByondValue_GetNum(&byond_value),
                    },
                };
            } else if (x.ByondValue_IsStr(&byond_value)) {
                const string = x.toString(this.allocator, &byond_value) catch {
                    z.getState().last_error = @errorName(SetVarError.OutOfMemory);

                    return SetVarError.OutOfMemory;
                };
                defer this.allocator.free(string);

                var string_id: c.basic26_StringId = undefined;

                if (c.basic26_Vm_get_string_id(script.vm, string.ptr, string.len, true, &string_id) != c.BASIC26_RESULT_OK) {
                    z.getState().last_error = @errorName(SetVarError.OutOfMemory);

                    return SetVarError.OutOfMemory;
                }

                if (cast == .symbol) {
                    break :blk c.basic26_Value{
                        .type = c.BASIC26_VALUE_TYPE_SYMBOL,
                        .as = .{
                            .symbol_id = string_id,
                        },
                    };
                } else if (cast != .none) {
                    z.getState().last_error = @errorName(SetVarError.UnsupportedType);

                    return SetVarError.UnsupportedType;
                }

                break :blk c.basic26_Value{
                    .type = c.BASIC26_VALUE_TYPE_STRING,
                    .as = .{
                        .string_id = string_id,
                    },
                };
            } else if (x.ByondValue_IsNull(&byond_value)) {
                if (cast != .object and cast != .none) {
                    z.getState().last_error = @errorName(SetVarError.UnsupportedType);

                    return SetVarError.UnsupportedType;
                }

                break :blk c.basic26_Value{
                    .type = c.BASIC26_VALUE_TYPE_NULL,
                };
            }

            const object = script.getOrCreateObject(byond_value) catch {
                z.getState().last_error = @errorName(SetVarError.OutOfMemory);

                return SetVarError.OutOfMemory;
            };

            break :blk c.basic26_Value{
                .type = c.BASIC26_VALUE_TYPE_OBJECT,
                .as = .{
                    .object_ptr = object,
                },
            };
        };

        if (c.basic26_State_set_var(script.state, symbol_id, &value) != c.BASIC26_RESULT_OK) {
            z.getState().last_error = @errorName(SetVarError.OutOfMemory);

            return SetVarError.OutOfMemory;
        }
    }

    pub inline fn getVar(this: *State, id: Script.Id, name: []const u8) GetVarError!x.ByondValue {
        const script = this.findScript(id) orelse {
            z.getState().last_error = @errorName(GetVarError.ScriptNotFound);

            return GetVarError.ScriptNotFound;
        };

        var symbol_id: c.basic26_SymbolId = undefined;

        if (c.basic26_Vm_get_string_id(script.vm, name.ptr, name.len, false, &symbol_id) != c.BASIC26_RESULT_OK) {
            z.getState().last_error = @errorName(GetVarError.VarNotFound);

            return GetVarError.VarNotFound;
        }

        var value: c.basic26_Value = undefined;

        if (c.basic26_State_get_var(script.state, symbol_id, &value) != c.BASIC26_RESULT_OK) {
            z.getState().last_error = @errorName(GetVarError.VarNotFound);

            return GetVarError.VarNotFound;
        }

        switch (value.type) {
            c.BASIC26_VALUE_TYPE_NULL => {
                return .{};
            },
            c.BASIC26_VALUE_TYPE_INT => {
                return x.numI(@truncate(value.as.int_val));
            },
            c.BASIC26_VALUE_TYPE_ADDRESS => {
                return x.num(@truncate(value.as.address_val));
            },
            c.BASIC26_VALUE_TYPE_FLOAT => {
                return x.numF(@floatCast(value.as.float_val));
            },
            c.BASIC26_VALUE_TYPE_STRING, c.BASIC26_VALUE_TYPE_SYMBOL => {
                const string_id = if (value.type == c.BASIC26_VALUE_TYPE_STRING)
                    value.as.string_id
                else
                    value.as.symbol_id;

                var out_string: ?[*]const u8 = null;
                var out_string_len: usize = 0;

                if (c.basic26_Vm_get_string(script.vm, string_id, &out_string, &out_string_len) != c.BASIC26_RESULT_OK) {
                    z.getState().last_error = @errorName(GetVarError.VarNotFound);

                    return GetVarError.VarNotFound;
                }

                const dupe: [:0]const u8 = this.allocator.dupeSentinel(u8, out_string.?[0..out_string_len], 0) catch {
                    z.getState().last_error = @errorName(GetVarError.OutOfMemory);

                    return GetVarError.OutOfMemory;
                };
                defer this.allocator.free(dupe);

                var ret: x.ByondValue = .{};
                x.ByondValue_SetStr(&ret, dupe);

                return ret;
            },
            c.BASIC26_VALUE_TYPE_OBJECT => {
                const object: *const ManagedObject = @ptrCast(@alignCast(value.as.object_ptr));

                return object.src;
            },
            else => {
                z.getState().last_error = @errorName(GetVarError.VarNotFound);

                return GetVarError.VarNotFound;
            },
        }
    }

    pub inline fn getVarType(this: *State, id: Script.Id, name: []const u8) GetVarTypeError!VarType {
        const script = this.findScript(id) orelse {
            z.getState().last_error = @errorName(GetVarTypeError.ScriptNotFound);

            return GetVarTypeError.ScriptNotFound;
        };

        var symbol_id: c.basic26_SymbolId = undefined;

        if (c.basic26_Vm_get_string_id(script.vm, name.ptr, name.len, false, &symbol_id) != c.BASIC26_RESULT_OK) {
            z.getState().last_error = @errorName(GetVarTypeError.VarNotFound);

            return GetVarTypeError.VarNotFound;
        }

        var value: c.basic26_Value = undefined;

        if (c.basic26_State_get_var(script.state, symbol_id, &value) != c.BASIC26_RESULT_OK) {
            z.getState().last_error = @errorName(GetVarTypeError.VarNotFound);

            return GetVarTypeError.VarNotFound;
        }

        switch (value.type) {
            c.BASIC26_VALUE_TYPE_NULL => return .null,
            c.BASIC26_VALUE_TYPE_INT => return .int,
            c.BASIC26_VALUE_TYPE_FLOAT => return .float,
            c.BASIC26_VALUE_TYPE_STRING => return .string,
            c.BASIC26_VALUE_TYPE_SYMBOL => return .symbol,
            c.BASIC26_VALUE_TYPE_OBJECT => return .object,
            c.BASIC26_VALUE_TYPE_ADDRESS => return .address,
            else => {
                z.getState().last_error = @errorName(GetVarTypeError.VarNotFound);

                return GetVarTypeError.VarNotFound;
            },
        }
    }

    pub inline fn unsetVar(this: *State, id: Script.Id, name: []const u8) UnsetVarError!void {
        const script = this.findScript(id) orelse {
            z.getState().last_error = @errorName(UnsetVarError.ScriptNotFound);

            return UnsetVarError.ScriptNotFound;
        };

        var symbol_id: c.basic26_SymbolId = undefined;

        if (c.basic26_Vm_get_string_id(script.vm, name.ptr, name.len, false, &symbol_id) != c.BASIC26_RESULT_OK) {
            return;
        }

        c.basic26_State_unset_var(script.state, symbol_id);
    }

    pub inline fn registerFunction(
        this: *State,
        id: Script.Id,
        name: []const u8,
        callback: u32,
        src: ?x.ByondValue,
        byond_typings: x.ByondValue,
    ) RegisterFunctionError!void {
        const script = this.findScript(id) orelse {
            z.getState().last_error = @errorName(UnsetVarError.ScriptNotFound);

            return UnsetVarError.ScriptNotFound;
        };

        var symbol_id: c.basic26_SymbolId = undefined;

        if (c.basic26_Vm_get_string_id(script.vm, name.ptr, name.len, true, &symbol_id) != c.BASIC26_RESULT_OK) {
            return;
        }

        for (script.functions.items) |func| {
            if (func.name == symbol_id) {
                z.getState().last_error = @errorName(RegisterFunctionError.AlreadyExists);

                return RegisterFunctionError.AlreadyExists;
            }
        }

        var typings_buffer = std.mem.zeroes([MAX_ARGS]Typing);
        var byond_typings_len: x.ByondValue = .{};

        if (!x.Byond_Length(&byond_typings, &byond_typings_len)) {
            return RegisterFunctionError.BadTypings;
        }

        const typings_len: usize = helpers.safeIntTruncate(usize, x.ByondValue_GetNum(&byond_typings_len)) orelse {
            return RegisterFunctionError.BadTypings;
        };

        if (typings_len > MAX_ARGS) {
            return RegisterFunctionError.BadTypings;
        }

        var typings: std.ArrayList(Typing) = .initBuffer(&typings_buffer);
        var i: usize = 0;

        while (i < typings_len) : (i += 1) {
            const idx = x.num(@intCast(i + 1));
            var out: x.ByondValue = .{};

            if (!x.Byond_ReadListIndex(&byond_typings, &idx, &out)) {
                return RegisterFunctionError.BadTypings;
            }

            if (!x.ByondValue_IsNum(&out)) {
                return RegisterFunctionError.BadTypings;
            }

            const raw_typing = helpers.safeIntTruncate(u32, x.ByondValue_GetNum(&out)) orelse {
                return RegisterFunctionError.BadTypings;
            };

            const typing: Typing = @bitCast(raw_typing);

            if (typing._padding != 0) {
                return RegisterFunctionError.BadTypings;
            }

            typings.appendAssumeCapacity(typing);
        }

        script.functions.append(script.allocator.allocator(), .init(
            symbol_id,
            callback,
            src,
            typings_buffer,
            typings.items.len,
        )) catch {
            z.getState().last_error = @errorName(RegisterFunctionError.OutOfMemory);

            return RegisterFunctionError.OutOfMemory;
        };

        if (c.basic26_Vm_register_function(script.vm, &.{
            .name = symbol_id,
            .callback = function_callback,
        }) != c.BASIC26_RESULT_OK) {
            z.getState().last_error = @errorName(RegisterFunctionError.OutOfMemory);

            return RegisterFunctionError.OutOfMemory;
        }
    }

    pub inline fn unregisterFunction(this: *State, id: Script.Id, name: []const u8) UnregisterFunctionError!void {
        const script = this.findScript(id) orelse {
            z.getState().last_error = @errorName(UnsetVarError.ScriptNotFound);

            return UnsetVarError.ScriptNotFound;
        };

        var symbol_id: c.basic26_SymbolId = undefined;

        if (c.basic26_Vm_get_string_id(script.vm, name.ptr, name.len, false, &symbol_id) != c.BASIC26_RESULT_OK) {
            return;
        }

        var i: usize = 0;

        while (i < script.functions.items.len) : (i += 1) {
            const func = &script.functions.items[i];

            if (func.name == symbol_id) {
                func.deinit();
                _ = script.functions.swapRemove(i);

                break;
            }
        }

        c.basic26_Vm_unregister_function(script.vm, symbol_id);
    }

    pub inline fn compile(
        this: *State,
        id: Script.Id,
        byond_source: x.ByondValue,
        max_opcodes: usize,
        max_strings: usize,
    ) CompileError!CompileResult {
        const script = this.findScript(id) orelse {
            z.getState().last_error = @errorName(CompileError.ScriptNotFound);

            return CompileError.ScriptNotFound;
        };

        script.runtime_error = null;
        script.compile_error = null;

        const source = x.toString(script.allocator.allocator(), &byond_source) catch {
            z.getState().last_error = @errorName(CompileError.OutOfMemory);

            return CompileError.OutOfMemory;
        };
        defer script.allocator.allocator().free(source);

        script.compile_error = null;
        var compile_error: c.basic26_CompileErrorInfo = .{};

        switch (c.basic26_Script_compile(script.script, &.{
            .source = source.ptr,
            .source_len = source.len,
            .limits = &.{
                .max_opcodes = max_opcodes,
                .max_strings = max_strings,
            },
            .debug_info = script.debug_info.?,
        }, &compile_error)) {
            c.BASIC26_RESULT_OK => {
                return .ok;
            },
            c.BASIC26_RESULT_OUT_OF_LIMITS => {
                return .out_of_limits;
            },
            c.BASIC26_RESULT_OUT_OF_MEMORY => {
                return .out_of_memory;
            },
            c.BASIC26_RESULT_COMPILE_ERROR => {
                script.compile_error = .{
                    .pos = compile_error.pos,
                    .kind = compile_error.code,
                };

                return .err;
            },
            else => {
                return .err;
            },
        }
    }

    pub inline fn getCompileErrorKind(this: *State, id: Script.Id) GetCompileErrorKindError!?c_uint {
        const script = this.findScript(id) orelse {
            z.getState().last_error = @errorName(GetCompileErrorKindError.ScriptNotFound);

            return GetCompileErrorKindError.ScriptNotFound;
        };

        if (script.compile_error == null) {
            return null;
        }

        return script.compile_error.?.kind;
    }

    pub inline fn getCompileErrorPos(this: *State, id: Script.Id) GetCompileErrorPosError!?usize {
        const script = this.findScript(id) orelse {
            z.getState().last_error = @errorName(GetCompileErrorPosError.ScriptNotFound);

            return GetCompileErrorPosError.ScriptNotFound;
        };

        if (script.compile_error == null) {
            return null;
        }

        return script.compile_error.?.pos;
    }

    pub inline fn run(
        this: *State,
        id: Script.Id,
        max_ops: usize,
        max_time_ns: usize,
        time_check_interval: usize,
    ) RunError!ScriptResult {
        const script = this.findScript(id) orelse {
            z.getState().last_error = @errorName(CompileError.ScriptNotFound);

            return CompileError.ScriptNotFound;
        };

        script.runtime_error = null;
        script.compile_error = null;

        var runtime_error: c.basic26_RuntimeErrorInfo = .{};

        switch (c.basic26_Vm_run(script.vm, &.{
            .state = script.state,
            .script = script.script,
            .limits = &.{
                .max_ops = max_ops,
                .max_time_ns = max_time_ns,
                .time_check_interval = time_check_interval,
            },
            .userdata = script,
        }, &runtime_error)) {
            c.BASIC26_RESULT_OK => return ScriptResult.ok,
            c.BASIC26_RESULT_YIELDED => return ScriptResult.yielded,
            c.BASIC26_RESULT_OUT_OF_MEMORY => return ScriptResult.out_of_memory,
            c.BASIC26_RESULT_OUT_OF_LIMITS => return ScriptResult.out_of_limits,
            c.BASIC26_RESULT_RUNTIME_ERROR => {
                script.runtime_error = .{
                    .kind = runtime_error.code,
                    .ip = runtime_error.ip,
                };

                return ScriptResult.err;
            },
            else => return ScriptResult.err,
        }
    }

    pub inline fn getRuntimeErrorKind(this: *State, id: Script.Id) GetRuntimeErrorKindError!?c_uint {
        const script = this.findScript(id) orelse {
            z.getState().last_error = @errorName(GetRuntimeErrorKindError.ScriptNotFound);

            return GetRuntimeErrorKindError.ScriptNotFound;
        };

        if (script.runtime_error == null) {
            return null;
        }

        return script.runtime_error.?.kind;
    }

    pub inline fn getRuntimeErrorIp(this: *State, id: Script.Id) GetRuntimeErrorIpError!?usize {
        const script = this.findScript(id) orelse {
            z.getState().last_error = @errorName(GetRuntimeErrorIpError.ScriptNotFound);

            return GetRuntimeErrorIpError.ScriptNotFound;
        };

        if (script.runtime_error == null) {
            return null;
        }

        return script.runtime_error.?.ip;
    }

    pub inline fn reset(
        this: *State,
        id: Script.Id,
        clear_vars: bool,
        clear_functions: bool,
        clear_stack: bool,
    ) ClearError!void {
        const script = this.findScript(id) orelse {
            z.getState().last_error = @errorName(ClearError.ScriptNotFound);

            return ClearError.ScriptNotFound;
        };

        c.basic26_Vm_clear(script.vm.?, &.{
            .clear_strings = false,
            .clear_functions = clear_functions,
        });

        if (clear_functions) {
            for (script.functions.items) |*func| {
                func.deinit();
            }

            script.functions.clearRetainingCapacity();
        }

        c.basic26_State_clear(script.state.?, &.{
            .clear_stack = clear_stack,
            .clear_vars = clear_vars,
        });

        c.basic26_State_set_ip(script.state, 0);
    }

    pub inline fn gcCollect(this: *State, id: Script.Id) GcCollectError!void {
        const script = this.findScript(id) orelse {
            z.getState().last_error = @errorName(GcCollectError.ScriptNotFound);

            return GcCollectError.ScriptNotFound;
        };

        script.gcCollect();
    }

    pub inline fn getIp(this: *State, id: Script.Id) GetIpError!usize {
        const script = this.findScript(id) orelse {
            z.getState().last_error = @errorName(GetIpError.ScriptNotFound);

            return GetIpError.ScriptNotFound;
        };

        var ip: usize = 0;
        c.basic26_State_get_ip(script.state.?, &ip);

        return ip;
    }

    pub inline fn setIp(this: *State, id: Script.Id, ip: usize) SetIpError!void {
        const script = this.findScript(id) orelse {
            z.getState().last_error = @errorName(SetIpError.ScriptNotFound);

            return SetIpError.ScriptNotFound;
        };

        c.basic26_State_set_ip(script.state.?, ip);
    }

    pub inline fn getOpPos(this: *State, id: Script.Id, ip: usize) GetOpPos!usize {
        const script = this.findScript(id) orelse {
            z.getState().last_error = @errorName(GetOpPos.ScriptNotFound);

            return GetOpPos.ScriptNotFound;
        };

        var pos: usize = 0;

        if (c.basic26_DebugInfo_get_source_pos(script.debug_info.?, ip, &pos) != c.BASIC26_RESULT_OK) {
            z.getState().last_error = @errorName(GetOpPos.OutOfRange);

            return GetOpPos.OutOfRange;
        }

        return pos;
    }

    pub inline fn getUsedMemory(this: *State, id: Script.Id) GetUsedMemory!usize {
        const script = this.findScript(id) orelse {
            z.getState().last_error = @errorName(GetOpPos.ScriptNotFound);

            return GetUsedMemory.ScriptNotFound;
        };

        return script.allocator.used;
    }

    const ScriptEntry = struct {
        ptr: *Script,
        idx: usize,
    };

    inline fn findScripEntry(this: *State, id: Script.Id) ?ScriptEntry {
        if (id == 0) {
            return null;
        }

        for (this.scripts.items, 0..) |script, idx| {
            if (script.id != id) {
                continue;
            }

            return .{ .ptr = script, .idx = idx };
        }

        return null;
    }

    inline fn findScript(this: *State, id: Script.Id) ?*Script {
        if (this.findScripEntry(id)) |entry| {
            return entry.ptr;
        }

        return null;
    }

    fn function_callback(
        info: ?*const c.basic26_CallInfo,
        argc: usize,
        argv: ?[*]const c.basic26_Value,
    ) callconv(.c) c.basic26_FunctionResult {
        const this: *Script = @ptrCast(@alignCast(info.?.userdata));

        const func: Function = blk: {
            for (this.functions.items) |func| {
                if (func.name == info.?.function_name) {
                    break :blk func;
                }
            }

            return c.BASIC26_FUNCTION_RESULT_ERROR;
        };

        var buffer: [MAX_ARGS]x.ByondValue = undefined;

        if (argc > MAX_ARGS) {
            return c.BASIC26_FUNCTION_RESULT_ERROR;
        }

        if (argc == 0 and func.src == null) {
            return c.BASIC26_FUNCTION_RESULT_ERROR;
        }

        var varargs: ?Typing = null;
        var args: std.ArrayList(x.ByondValue) = .initBuffer(&buffer);
        var i: usize = 0;

        while (i < argc) : (i += 1) {
            const arg = argv.?[i];

            if (varargs) |va| {
                if (!va.isTypeAllowed(arg.type)) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }
            } else {
                if (i >= func.typings_len) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                if (i == 0 and func.src == null and arg.type != c.BASIC26_VALUE_TYPE_OBJECT) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                const typing = func.typings[i];

                if (!typing.isTypeAllowed(arg.type)) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                if (typing.varargs) {
                    varargs = typing;
                }
            }

            switch (arg.type) {
                c.BASIC26_VALUE_TYPE_INT => {
                    args.appendAssumeCapacity(x.numI(@truncate(arg.as.int_val)));
                },
                c.BASIC26_VALUE_TYPE_FLOAT => {
                    args.appendAssumeCapacity(x.numF(@floatCast(arg.as.float_val)));
                },
                c.BASIC26_VALUE_TYPE_ADDRESS => {
                    args.appendAssumeCapacity(x.num(@truncate(arg.as.address_val)));
                },
                c.BASIC26_VALUE_TYPE_STRING, c.BASIC26_VALUE_TYPE_SYMBOL => {
                    const string_id = if (arg.type == c.BASIC26_VALUE_TYPE_STRING)
                        arg.as.string_id
                    else
                        arg.as.symbol_id;

                    var str: ?[*]const u8 = null;
                    var str_len: usize = 0;

                    if (c.basic26_Vm_get_string(this.vm, string_id, &str, &str_len) != c.BASIC26_RESULT_OK) {
                        return c.BASIC26_FUNCTION_RESULT_ERROR;
                    }

                    const zstr = this.allocator.allocator().dupeSentinel(u8, str.?[0..str_len], 0) catch {
                        return c.BASIC26_FUNCTION_RESULT_ERROR;
                    };
                    defer this.allocator.allocator().free(zstr);

                    var value: x.ByondValue = .{};
                    x.ByondValue_SetStr(&value, zstr);

                    args.appendAssumeCapacity(value);
                },
                c.BASIC26_VALUE_TYPE_OBJECT => {
                    const object: *const ManagedObject = @ptrCast(@alignCast(arg.as.object_ptr));

                    args.appendAssumeCapacity(object.src);
                },
                else => {
                    args.appendAssumeCapacity(.{});
                },
            }
        }

        var result: x.ByondValue = .{};

        const src = if (func.src == null)
            &args.items[0]
        else
            &func.src.?;

        const call_args = if (func.src == null)
            args.items[1..]
        else
            args.items;

        if (!x.Byond_CallProcByStrId(src, func.callback, call_args, &result)) {
            return c.BASIC26_FUNCTION_RESULT_ERROR;
        }

        if (!x.ByondValue_IsNum(&result)) {
            return c.BASIC26_FUNCTION_RESULT_ERROR;
        }

        const func_result_raw = helpers.safeIntTruncate(@typeInfo(FunctionResult).@"enum".tag_type, x.ByondValue_GetNum(&result)) orelse {
            return c.BASIC26_FUNCTION_RESULT_ERROR;
        };

        const func_result = std.enums.fromInt(FunctionResult, func_result_raw) orelse {
            return c.BASIC26_FUNCTION_RESULT_ERROR;
        };

        return switch (func_result) {
            .ok => c.BASIC26_FUNCTION_RESULT_OK,
            .err => c.BASIC26_FUNCTION_RESULT_ERROR,
            .yield => c.BASIC26_FUNCTION_RESULT_YIELD,
        };
    }
};

export fn Z_script_create(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 2) {
        x.Byond_CRASH("Z_script_create requires 2 arguments");

        return z.returnCast(.{});
    }

    const state = getState();
    const src = args[0];
    const memory_size = helpers.safeIntTruncate(usize, x.ByondValue_GetNum(&args[1])) orelse {
        x.Byond_CRASH("Bad memory_size");

        return z.returnCast(.{});
    };

    const id = state.createScript(src, memory_size) catch {
        return z.returnCast(.{});
    };

    return z.returnCast(x.num(id));
}

export fn Z_script_destroy(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 1) {
        x.Byond_CRASH("Z_script_destroy requires 1 argument");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Script.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));

    return if (state.destroyScript(id))
        @bitCast(x.True())
    else
        @bitCast(x.False());
}

export fn Z_script_has_var(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 1) {
        x.Byond_CRASH("Z_script_has_var requires 1 argument");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Script.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));

    var buffer: [1024]u8 = undefined;
    var buffer_allocator: std.heap.FixedBufferAllocator = .init(&buffer);

    const name = x.toString(buffer_allocator.allocator(), &args[1]) catch {
        x.Byond_CRASH("Name too long");

        return z.returnCast(.{});
    };

    const ret = state.hasVar(id, name) catch {
        return z.returnCast(.{});
    };

    return if (ret)
        z.returnCast(x.True())
    else
        z.returnCast(x.False());
}

export fn Z_script_set_var(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 4) {
        x.Byond_CRASH("Z_script_set_var requires 4 arguments");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Script.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));

    var buffer: [1024]u8 = undefined;
    var buffer_allocator: std.heap.FixedBufferAllocator = .init(&buffer);

    const name = x.toString(buffer_allocator.allocator(), &args[1]) catch {
        x.Byond_CRASH("Name too long");

        return z.returnCast(.{});
    };

    const var_cast_raw = helpers.safeIntTruncate(@typeInfo(VarCast).@"enum".tag_type, x.ByondValue_GetNum(&args[3])) orelse {
        x.Byond_CRASH("Bad cast");

        return z.returnCast(.{});
    };

    const var_cast = std.enums.fromInt(VarCast, var_cast_raw) orelse {
        x.Byond_CRASH("Bad cast");

        return z.returnCast(.{});
    };

    state.setVar(id, name, args[2], var_cast) catch {
        return z.returnCast(.{});
    };

    return z.returnCast(x.True());
}

export fn Z_script_get_var(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 2) {
        x.Byond_CRASH("Z_script_get_var requires 2 arguments");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Script.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));

    var buffer: [1024]u8 = undefined;
    var buffer_allocator: std.heap.FixedBufferAllocator = .init(&buffer);

    const name = x.toString(buffer_allocator.allocator(), &args[1]) catch {
        x.Byond_CRASH("Name too long");

        return z.returnCast(.{});
    };

    const ret = state.getVar(id, name) catch {
        return z.returnCast(.{});
    };

    return z.returnCast(ret);
}

export fn Z_script_get_var_type(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 2) {
        x.Byond_CRASH("Z_script_get_var requires 2 arguments");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Script.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));

    var buffer: [1024]u8 = undefined;
    var buffer_allocator: std.heap.FixedBufferAllocator = .init(&buffer);

    const name = x.toString(buffer_allocator.allocator(), &args[1]) catch {
        x.Byond_CRASH("Name too long");

        return z.returnCast(.{});
    };

    const ret = state.getVarType(id, name) catch {
        return z.returnCast(.{});
    };

    return z.returnCast(x.num(@intFromEnum(ret)));
}

export fn Z_script_unset_var(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 2) {
        x.Byond_CRASH("Z_script_unset_var requires 2 arguments");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Script.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));

    var buffer: [1024]u8 = undefined;
    var buffer_allocator: std.heap.FixedBufferAllocator = .init(&buffer);

    const name = x.toString(buffer_allocator.allocator(), &args[1]) catch {
        x.Byond_CRASH("Name too long");

        return z.returnCast(.{});
    };

    state.unsetVar(id, name) catch {
        return z.returnCast(.{});
    };

    return z.returnCast(x.True());
}

export fn Z_script_register_function(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 5) {
        x.Byond_CRASH("Z_script_register_function requires 5 arguments");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Script.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));

    var buffer: [1024]u8 = undefined;
    var buffer_allocator: std.heap.FixedBufferAllocator = .init(&buffer);

    const name = x.toString(buffer_allocator.allocator(), &args[1]) catch {
        x.Byond_CRASH("Name too long");

        return z.returnCast(.{});
    };

    if (!x.ByondValue_IsStr(&args[2])) {
        x.Byond_CRASH("The callback should be a string");

        return z.returnCast(.{});
    }

    const callback = x.ByondValue_GetRef(&args[2]);
    const src = if (x.ByondValue_IsNull(&args[3]))
        null
    else
        args[3];

    const typings = args[4];

    if (!x.ByondValue_IsList(&typings)) {
        x.Byond_CRASH("The typings should be a list");

        return z.returnCast(.{});
    }

    state.registerFunction(id, name, callback, src, typings) catch {
        return z.returnCast(.{});
    };

    return z.returnCast(x.True());
}

export fn Z_script_unregister_function(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 2) {
        x.Byond_CRASH("Z_script_unregister_function requires 2 arguments");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Script.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));

    var buffer: [1024]u8 = undefined;
    var buffer_allocator: std.heap.FixedBufferAllocator = .init(&buffer);

    const name = x.toString(buffer_allocator.allocator(), &args[1]) catch {
        x.Byond_CRASH("Name too long");

        return z.returnCast(.{});
    };

    state.unregisterFunction(id, name) catch {
        return z.returnCast(.{});
    };

    return z.returnCast(x.True());
}

export fn Z_script_compile(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 4) {
        x.Byond_CRASH("Z_script_compile requires 4 arguments");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Script.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const max_opcodes = helpers.safeIntTruncate(usize, x.ByondValue_GetNum(&args[2])) orelse {
        x.Byond_CRASH("Bad max_opcodes");

        return z.returnCast(.{});
    };

    const max_strings = helpers.safeIntTruncate(usize, x.ByondValue_GetNum(&args[3])) orelse {
        x.Byond_CRASH("Bad max_strings");

        return z.returnCast(.{});
    };

    const ret = state.compile(id, args[1], max_opcodes, max_strings) catch {
        return z.returnCast(.{});
    };

    return z.returnCast(x.num(@intFromEnum(ret)));
}

export fn Z_get_compile_error_kind(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 1) {
        x.Byond_CRASH("Z_get_compile_error_kind requires 1 argument");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Script.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const kind = state.getCompileErrorKind(id) catch {
        return z.returnCast(.{});
    } orelse 0;

    return z.returnCast(x.num(@truncate(kind)));
}

export fn Z_get_compile_error_pos(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 1) {
        x.Byond_CRASH("Z_get_compile_error_pos requires 1 argument");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Script.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const pos = state.getCompileErrorPos(id) catch {
        return z.returnCast(.{});
    };

    return if (pos == null)
        z.returnCast(x.numI(-1))
    else
        z.returnCast(x.num(@truncate(pos.?)));
}

export fn Z_script_run(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 5) {
        x.Byond_CRASH("Z_script_run requires 5 arguments");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Script.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const max_ops = helpers.safeIntTruncate(usize, x.ByondValue_GetNum(&args[1])) orelse {
        x.Byond_CRASH("Bad max_ops");

        return z.returnCast(.{});
    };

    const max_time_ds = x.ByondValue_GetNum(&args[2]);
    const max_time_ns: usize = @trunc(max_time_ds * 1e+8);

    const time_check_interval = helpers.safeIntTruncate(usize, x.ByondValue_GetNum(&args[3])) orelse {
        x.Byond_CRASH("Bad time_check_interval");

        return z.returnCast(.{});
    };

    const start = std.Io.Timestamp.now(z.getState().io.io(), .real);

    const result = state.run(id, max_ops, max_time_ns, time_check_interval) catch {
        return z.returnCast(.{});
    };

    const now = std.Io.Timestamp.now(z.getState().io.io(), .real);
    const elapsed = now.nanoseconds - start.nanoseconds;

    const util = if (max_time_ds == 0)
        x.numF(0.0)
    else
        x.numF(@floatCast(@as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(max_time_ns))));

    _ = x.Byond_WritePointer(&args[4], &util);

    return z.returnCast(x.num(@intFromEnum(result)));
}

export fn Z_get_runtime_error_kind(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 1) {
        x.Byond_CRASH("Z_get_runtime_error_kind requires 1 argument");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Script.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));

    const kind = state.getRuntimeErrorKind(id) catch {
        return z.returnCast(.{});
    } orelse 0;

    return z.returnCast(x.num(kind));
}

export fn Z_get_runtime_error_ip(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 1) {
        x.Byond_CRASH("Z_get_runtime_error_ip requires 1 argument");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Script.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));

    const pos = state.getRuntimeErrorIp(id) catch {
        return z.returnCast(.{});
    } orelse 0;

    return z.returnCast(x.num(pos));
}

export fn Z_script_reset(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 4) {
        x.Byond_CRASH("Z_script_reset requires 4 argument");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Script.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const clear_vars = x.ByondValue_IsTrue(&args[1]);
    const clear_functions = x.ByondValue_IsTrue(&args[2]);
    const clear_stack = x.ByondValue_IsTrue(&args[3]);

    state.reset(id, clear_vars, clear_functions, clear_stack) catch {
        return z.returnCast(.{});
    };

    return z.returnCast(x.True());
}

export fn Z_script_gc_collect(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 1) {
        x.Byond_CRASH("Z_script_gc_collect requires 1 argument");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Script.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));

    state.gcCollect(id) catch {
        return z.returnCast(.{});
    };

    return z.returnCast(x.True());
}

export fn Z_script_get_ip(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 1) {
        x.Byond_CRASH("Z_script_get_ip requires 1 argument");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Script.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));

    const ip = state.getIp(id) catch {
        return z.returnCast(.{});
    };

    return z.returnCast(x.num(@truncate(ip)));
}

export fn Z_script_set_ip(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 2) {
        x.Byond_CRASH("Z_script_set_ip requires 2 argument");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Script.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const ip = helpers.safeIntTruncate(usize, x.ByondValue_GetNum(&args[1])) orelse {
        x.Byond_CRASH("Bad ip");

        return z.returnCast(.{});
    };

    state.setIp(id, ip) catch {
        return z.returnCast(.{});
    };

    return z.returnCast(x.True());
}

export fn Z_script_get_op_pos(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 2) {
        x.Byond_CRASH("Z_script_get_op_pos requires 2 argument");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Script.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));
    const ip = helpers.safeIntTruncate(usize, x.ByondValue_GetNum(&args[1])) orelse {
        x.Byond_CRASH("Bad ip");

        return z.returnCast(.{});
    };

    const ret = state.getOpPos(id, ip) catch {
        return z.returnCast(.{});
    };

    return z.returnCast(x.num(@truncate(ret)));
}

export fn Z_script_get_used_memory(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 1) {
        x.Byond_CRASH("Z_script_get_used_memory requires 1 argument");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Script.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));

    const ret = state.getUsedMemory(id) catch {
        return z.returnCast(.{});
    };

    return z.returnCast(x.num(@truncate(ret)));
}
