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

    pub inline fn any() Typing {
        return .{
            .null = true,
            .int = true,
            .float = true,
            .string = true,
            .symbol = true,
            .object = true,
            .address = true,
        };
    }

    pub inline fn anyVarargs() Typing {
        return .{
            .null = true,
            .int = true,
            .float = true,
            .string = true,
            .symbol = true,
            .object = true,
            .address = true,
            .varargs = true,
        };
    }

    pub inline fn isAny(this: Typing) bool {
        return this.null and this.int and this.float and this.string and this.symbol and this.object and this.address;
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
    pub const Value = union(enum) {
        pub const Byond = struct {
            src: x.ByondValue = .{},

            pub inline fn init(src: x.ByondValue) Byond {
                x.ByondValue_IncRef(&src);

                return .{ .src = src };
            }

            pub inline fn deinit(this: *Byond) void {
                x.ByondValue_DecRef(&this.src);
            }
        };

        pub const Array = struct {
            data: std.ArrayList(c.basic26_Value) = .empty,

            pub inline fn init() Array {
                return .{};
            }

            pub inline fn deinit(this: *Array, allocator: std.mem.Allocator) void {
                this.data.deinit(allocator);
            }

            fn createFunction(
                script: *Script,
                args: []const c.basic26_Value,
            ) c.basic26_FunctionResult {
                if (args.len != 1) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                const object = script.allocator.allocator().create(ManagedObject) catch {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                };
                object.initArray();

                script.objects.append(script.allocator.allocator(), .init(.{}, object)) catch {
                    object.deinit(script.allocator.allocator());
                    script.allocator.allocator().destroy(object);

                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                };

                const value = c.basic26_Value{
                    .type = c.BASIC26_VALUE_TYPE_OBJECT,
                    .as = .{ .object_ptr = object },
                };

                if (c.basic26_State_set_var(script.state.?, args[0].as.symbol_id, &value) != c.BASIC26_RESULT_OK) {
                    _ = script.objects.pop();
                    object.deinit(script.allocator.allocator());
                    script.allocator.allocator().destroy(object);

                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                return c.BASIC26_FUNCTION_RESULT_OK;
            }

            fn pushFunction(
                script: *Script,
                args: []const c.basic26_Value,
            ) c.basic26_FunctionResult {
                if (args.len < 2) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                if (args[0].type != c.BASIC26_VALUE_TYPE_OBJECT) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                const obj: *ManagedObject = @ptrCast(@alignCast(args[0].as.object_ptr));

                if (obj.value != .array) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                for (args[1..]) |arg| {
                    if (arg.type == c.BASIC26_VALUE_TYPE_OBJECT) {
                        const push_obj: *const ManagedObject = @ptrCast(@alignCast(arg.as.object_ptr));

                        if (push_obj.value == .array) {
                            return c.BASIC26_FUNCTION_RESULT_ERROR;
                        }
                    }

                    obj.value.array.data.append(script.allocator.allocator(), arg) catch {
                        return c.BASIC26_FUNCTION_RESULT_ERROR;
                    };
                }

                return c.BASIC26_FUNCTION_RESULT_OK;
            }

            fn popFunction(
                script: *Script,
                args: []const c.basic26_Value,
            ) c.basic26_FunctionResult {
                if (args.len != 2) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                if (args[0].type != c.BASIC26_VALUE_TYPE_OBJECT) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                const obj: *ManagedObject = @ptrCast(@alignCast(args[0].as.object_ptr));

                if (obj.value != .array) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                const items = &obj.value.array.data;

                if (items.items.len == 0) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                const value = items.pop().?;

                if (args[1].type == c.BASIC26_VALUE_TYPE_NULL) {
                    return c.BASIC26_FUNCTION_RESULT_OK;
                }

                if (c.basic26_State_set_var(script.state.?, args[1].as.symbol_id, &value) != c.BASIC26_RESULT_OK) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                return c.BASIC26_FUNCTION_RESULT_OK;
            }

            fn atFunction(
                script: *Script,
                args: []const c.basic26_Value,
            ) c.basic26_FunctionResult {
                if (args.len != 3) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                if (args[0].type != c.BASIC26_VALUE_TYPE_OBJECT) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                const obj: *ManagedObject = @ptrCast(@alignCast(args[0].as.object_ptr));

                if (obj.value != .array) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                if (args[1].as.int_val < 0) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                const idx: usize = @intCast(args[1].as.int_val);
                const array = &obj.value.array.data;

                if (idx >= array.items.len) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                const value = array.items[idx];

                if (c.basic26_State_set_var(script.state.?, args[2].as.symbol_id, &value) != c.BASIC26_RESULT_OK) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                return c.BASIC26_FUNCTION_RESULT_OK;
            }

            fn setFunction(
                script: *Script,
                args: []const c.basic26_Value,
            ) c.basic26_FunctionResult {
                _ = script;

                if (args.len != 3) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                if (args[0].type != c.BASIC26_VALUE_TYPE_OBJECT) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                const obj: *ManagedObject = @ptrCast(@alignCast(args[0].as.object_ptr));

                if (obj.value != .array) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                if (args[1].as.int_val < 0) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                const idx: usize = @intCast(args[1].as.int_val);
                const array = &obj.value.array.data;

                if (idx >= array.items.len) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                const value = args[2];

                if (value.type == c.BASIC26_VALUE_TYPE_OBJECT) {
                    const value_obj: *const ManagedObject = @ptrCast(@alignCast(value.as.object_ptr));

                    if (value_obj.value == .array) {
                        return c.BASIC26_FUNCTION_RESULT_ERROR;
                    }
                }

                array.items[idx] = value;

                return c.BASIC26_FUNCTION_RESULT_OK;
            }

            fn lenFunction(
                script: *Script,
                args: []const c.basic26_Value,
            ) c.basic26_FunctionResult {
                if (args.len != 2) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                if (args[0].type != c.BASIC26_VALUE_TYPE_OBJECT) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                const obj: *ManagedObject = @ptrCast(@alignCast(args[0].as.object_ptr));

                if (obj.value != .array) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                const len: c.basic26_Value = .{
                    .type = c.BASIC26_VALUE_TYPE_INT,
                    .as = .{
                        .int_val = obj.value.array.data.items.len,
                    },
                };

                if (c.basic26_State_set_var(script.state.?, args[1].as.symbol_id, &len) != c.BASIC26_RESULT_OK) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                return c.BASIC26_FUNCTION_RESULT_OK;
            }

            fn removeFunction(
                script: *Script,
                args: []const c.basic26_Value,
            ) c.basic26_FunctionResult {
                if (args.len != 3) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                if (args[0].type != c.BASIC26_VALUE_TYPE_OBJECT) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                const obj: *ManagedObject = @ptrCast(@alignCast(args[0].as.object_ptr));

                if (obj.value != .array) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                if (args[1].as.int_val < 0) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                const idx: usize = @intCast(args[1].as.int_val);
                const array = &obj.value.array.data;

                if (idx >= array.items.len) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                const value = array.orderedRemove(idx);

                if (args[2].type == c.BASIC26_VALUE_TYPE_NULL) {
                    return c.BASIC26_FUNCTION_RESULT_OK;
                }

                if (c.basic26_State_set_var(script.state.?, args[2].as.symbol_id, &value) != c.BASIC26_RESULT_OK) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                return c.BASIC26_FUNCTION_RESULT_OK;
            }

            fn insertFunction(
                script: *Script,
                args: []const c.basic26_Value,
            ) c.basic26_FunctionResult {
                if (args.len != 3) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                if (args[0].type != c.BASIC26_VALUE_TYPE_OBJECT) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                const obj: *ManagedObject = @ptrCast(@alignCast(args[0].as.object_ptr));

                if (obj.value != .array) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                if (args[1].as.int_val < 0) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                const idx: usize = @intCast(args[1].as.int_val);
                const array = &obj.value.array.data;

                if (idx > array.items.len) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                const value = args[2];

                if (value.type == c.BASIC26_VALUE_TYPE_OBJECT) {
                    const value_obj: *const ManagedObject = @ptrCast(@alignCast(value.as.object_ptr));

                    if (value_obj.value == .array) {
                        return c.BASIC26_FUNCTION_RESULT_ERROR;
                    }
                }

                array.insert(script.allocator.allocator(), idx, value) catch {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                };

                return c.BASIC26_FUNCTION_RESULT_OK;
            }

            fn clearFunction(
                script: *Script,
                args: []const c.basic26_Value,
            ) c.basic26_FunctionResult {
                _ = script;

                if (args.len != 1) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                if (args[0].type != c.BASIC26_VALUE_TYPE_OBJECT) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                const obj: *ManagedObject = @ptrCast(@alignCast(args[0].as.object_ptr));

                if (obj.value != .array) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                obj.value.array.data.clearRetainingCapacity();

                return c.BASIC26_FUNCTION_RESULT_OK;
            }
        };

        pub const Text = struct {
            data: std.ArrayList(u8) = .empty,

            pub inline fn init() Text {
                return .{};
            }

            pub inline fn deinit(this: *Text, allocator: std.mem.Allocator) void {
                this.data.deinit(allocator);
            }

            fn createFunction(
                script: *Script,
                args: []const c.basic26_Value,
            ) c.basic26_FunctionResult {
                if (args.len != 1) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                const object = script.allocator.allocator().create(ManagedObject) catch {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                };
                object.initText();

                script.objects.append(script.allocator.allocator(), .init(.{}, object)) catch {
                    object.deinit(script.allocator.allocator());
                    script.allocator.allocator().destroy(object);

                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                };

                const value = c.basic26_Value{
                    .type = c.BASIC26_VALUE_TYPE_OBJECT,
                    .as = .{ .object_ptr = object },
                };

                if (c.basic26_State_set_var(script.state.?, args[0].as.symbol_id, &value) != c.BASIC26_RESULT_OK) {
                    _ = script.objects.pop();
                    object.deinit(script.allocator.allocator());
                    script.allocator.allocator().destroy(object);

                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                return c.BASIC26_FUNCTION_RESULT_OK;
            }

            fn appendFunction(
                script: *Script,
                args: []const c.basic26_Value,
            ) c.basic26_FunctionResult {
                if (args.len == 0) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                if (args[0].type != c.BASIC26_VALUE_TYPE_OBJECT) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                const obj: *ManagedObject = @ptrCast(@alignCast(args[0].as.object_ptr));

                if (obj.value != .text) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                const text = &obj.value.text.data;

                if (args.len == 1) {
                    return c.BASIC26_FUNCTION_RESULT_OK;
                }

                for (args[1..]) |arg| {
                    switch (arg.type) {
                        c.BASIC26_VALUE_TYPE_NULL => {
                            text.print(script.allocator.allocator(), "NULL", .{}) catch {
                                return c.BASIC26_FUNCTION_RESULT_ERROR;
                            };
                        },
                        c.BASIC26_VALUE_TYPE_INT => {
                            text.print(script.allocator.allocator(), "{}", .{arg.as.int_val}) catch {
                                return c.BASIC26_FUNCTION_RESULT_ERROR;
                            };
                        },
                        c.BASIC26_VALUE_TYPE_FLOAT => {
                            text.print(script.allocator.allocator(), "{}", .{arg.as.float_val}) catch {
                                return c.BASIC26_FUNCTION_RESULT_ERROR;
                            };
                        },
                        c.BASIC26_VALUE_TYPE_STRING, c.BASIC26_VALUE_TYPE_SYMBOL => {
                            var str: ?[*]const u8 = null;
                            var str_len: usize = 0;

                            const string_id = if (arg.type == c.BASIC26_VALUE_TYPE_STRING)
                                arg.as.string_id
                            else
                                arg.as.symbol_id;

                            if (c.basic26_Vm_get_string(script.vm, string_id, &str, &str_len) != c.BASIC26_RESULT_OK) {
                                return c.BASIC26_FUNCTION_RESULT_ERROR;
                            }

                            text.print(script.allocator.allocator(), "{s}", .{str.?[0..str_len]}) catch {
                                return c.BASIC26_FUNCTION_RESULT_ERROR;
                            };
                        },
                        c.BASIC26_VALUE_TYPE_OBJECT => {
                            const arg_obj: *const ManagedObject = @ptrCast(@alignCast(arg.as.object_ptr));

                            switch (arg_obj.value) {
                                .byond => {
                                    const zstr = x.toString(script.allocator.allocator(), &arg_obj.value.byond.src) catch {
                                        return c.BASIC26_FUNCTION_RESULT_ERROR;
                                    };
                                    defer script.allocator.allocator().free(zstr);

                                    // 🖕🖕🖕
                                    const str = zstr[0..std.mem.findSentinel(u8, 0, zstr.ptr)];

                                    text.print(script.allocator.allocator(), "{s}", .{str}) catch {
                                        return c.BASIC26_FUNCTION_RESULT_ERROR;
                                    };
                                },
                                .text => {
                                    text.print(script.allocator.allocator(), "{s}", .{arg_obj.value.text.data.items}) catch {
                                        return c.BASIC26_FUNCTION_RESULT_ERROR;
                                    };
                                },
                                else => {
                                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                                },
                            }
                        },
                        c.BASIC26_VALUE_TYPE_ADDRESS => {
                            text.print(script.allocator.allocator(), "{}", .{arg.as.address_val}) catch {
                                return c.BASIC26_FUNCTION_RESULT_ERROR;
                            };
                        },
                        else => return c.BASIC26_FUNCTION_RESULT_ERROR,
                    }
                }

                return c.BASIC26_FUNCTION_RESULT_OK;
            }

            fn startsWithFunction(
                script: *Script,
                args: []const c.basic26_Value,
            ) c.basic26_FunctionResult {
                if (args.len != 3) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                if (args[0].type != c.BASIC26_VALUE_TYPE_OBJECT) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                const obj: *ManagedObject = @ptrCast(@alignCast(args[0].as.object_ptr));

                if (obj.value != .text) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                const needle = getStr(script, args[1]) orelse {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                };

                const starts = std.mem.startsWith(u8, obj.value.text.data.items, needle);
                const value: c.basic26_Value = .{
                    .type = c.BASIC26_VALUE_TYPE_INT,
                    .as = .{
                        .int_val = if (starts)
                            1
                        else
                            0,
                    },
                };

                if (c.basic26_State_set_var(script.state, args[2].as.symbol_id, &value) != c.BASIC26_RESULT_OK) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                return c.BASIC26_FUNCTION_RESULT_OK;
            }

            fn endsWithFunction(
                script: *Script,
                args: []const c.basic26_Value,
            ) c.basic26_FunctionResult {
                if (args.len != 3) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                if (args[0].type != c.BASIC26_VALUE_TYPE_OBJECT) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                const obj: *ManagedObject = @ptrCast(@alignCast(args[0].as.object_ptr));

                if (obj.value != .text) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                const needle = getStr(script, args[1]) orelse {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                };

                const starts = std.mem.endsWith(u8, obj.value.text.data.items, needle);
                const value: c.basic26_Value = .{
                    .type = c.BASIC26_VALUE_TYPE_INT,
                    .as = .{
                        .int_val = if (starts)
                            1
                        else
                            0,
                    },
                };

                if (c.basic26_State_set_var(script.state, args[2].as.symbol_id, &value) != c.BASIC26_RESULT_OK) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                return c.BASIC26_FUNCTION_RESULT_OK;
            }

            fn clearFunction(
                script: *Script,
                args: []const c.basic26_Value,
            ) c.basic26_FunctionResult {
                _ = script;

                if (args.len != 1) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                if (args[0].type != c.BASIC26_VALUE_TYPE_OBJECT) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                const obj: *ManagedObject = @ptrCast(@alignCast(args[0].as.object_ptr));

                if (obj.value != .text) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }

                obj.value.text.data.clearRetainingCapacity();

                return c.BASIC26_FUNCTION_RESULT_OK;
            }

            inline fn getStr(script: *Script, value: c.basic26_Value) ?[]const u8 {
                switch (value.type) {
                    c.BASIC26_VALUE_TYPE_STRING => {
                        var str: ?[*]const u8 = null;
                        var str_len: usize = 0;

                        if (c.basic26_Vm_get_string(script.vm, value.as.string_id, &str, &str_len) != c.BASIC26_RESULT_OK) {
                            return null;
                        }

                        return str.?[0..str_len];
                    },
                    c.BASIC26_VALUE_TYPE_OBJECT => {
                        const args_obj: *const ManagedObject = @ptrCast(@alignCast(value.as.object_ptr));

                        if (args_obj.value != .text) {
                            return null;
                        }

                        return args_obj.value.text.data.items;
                    },
                    else => return null,
                }
            }
        };

        byond: Byond,
        array: Array,
        text: Text,

        pub inline fn deinit(this: *Value, allocator: std.mem.Allocator) void {
            switch (this.*) {
                .byond => this.byond.deinit(),
                .array => this.array.deinit(allocator),
                .text => this.text.deinit(allocator),
            }
        }
    };

    value: Value,
    gc_mark: bool = false,

    pub inline fn initByond(this: *ManagedObject, src: x.ByondValue) void {
        this.value = .{ .byond = .init(src) };
    }

    pub inline fn initArray(this: *ManagedObject) void {
        this.value = .{ .array = .init() };
    }

    pub inline fn initText(this: *ManagedObject) void {
        this.value = .{ .text = .init() };
    }

    pub inline fn deinit(this: *ManagedObject, allocator: std.mem.Allocator) void {
        this.value.deinit(allocator);
        this.gc_mark = false;
    }

    pub fn gcMark(this: *ManagedObject) void {
        if (this.gc_mark) {
            return;
        }

        this.gc_mark = true;

        switch (this.value) {
            .byond => {},
            .array => {
                for (this.value.array.data.items) |item| {
                    if (item.type == c.BASIC26_VALUE_TYPE_OBJECT) {
                        const inner: *ManagedObject = @ptrCast(@alignCast(item.as.object_ptr));

                        if (inner.value == .array) {
                            std.log.err("BUG: An array inside of an array!", .{});
                        } else {
                            inner.gcMark();
                        }
                    }
                }
            },
            .text => {},
        }
    }
};

const ByondFunction = struct {
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
    ) ByondFunction {
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

    pub inline fn deinit(this: *ByondFunction) void {
        if (this.src != null) {
            x.ByondValue_DecRef(&this.src.?);
        }
    }
};

const NativeFunction = struct {
    const Callback = *const fn (script: *Script, args: []const c.basic26_Value) c.basic26_FunctionResult;

    name: c.basic26_SymbolId,
    callback: Callback,
    typings: [MAX_ARGS]Typing,
    typings_len: usize,

    pub inline fn init(
        name: c.basic26_SymbolId,
        callback: Callback,
        typings: [MAX_ARGS]Typing,
        typings_len: usize,
    ) NativeFunction {
        return .{
            .name = name,
            .callback = callback,
            .typings = typings,
            .typings_len = typings_len,
        };
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
    byond_functions: std.ArrayList(ByondFunction),
    native_functions: std.ArrayList(NativeFunction),
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
        this.byond_functions = .empty;
        this.native_functions = .empty;
        this.compile_error = null;
        this.runtime_error = null;
    }

    pub inline fn deinit(this: *Script) void {
        for (this.objects.items) |pair| {
            pair.object.deinit(this.allocator.allocator());
            this.allocator.allocator().destroy(pair.object);
        }

        this.objects.deinit(this.allocator.allocator());

        for (this.byond_functions.items) |*func| {
            func.deinit();
        }

        this.byond_functions.deinit(this.allocator.allocator());
        this.native_functions.deinit(this.allocator.allocator());

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
        object.initByond(src);

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
            object.gcMark();
        }

        var i: usize = 0;

        while (i < this.objects.items.len) {
            const pair = this.objects.items[i];

            if (pair.object.gc_mark) {
                pair.object.gc_mark = false;
                i += 1;

                continue;
            }

            pair.object.deinit(this.allocator.allocator());
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

const GetOpPosError = error{
    ScriptNotFound,
    OutOfRange,
};

const GetUsedMemoryError = error{
    ScriptNotFound,
};

const RegisterBuiltinArrayError = error{
    ScriptNotFound,
    OutOfMemory,
};

const RegisterBuiltinTextError = error{
    ScriptNotFound,
    OutOfMemory,
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

                if (object.value != .byond) {
                    z.getState().last_error = @errorName(GetVarError.VarNotFound);

                    return GetVarError.VarNotFound;
                }

                return object.value.byond.src;
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

        for (script.byond_functions.items) |func| {
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

        script.byond_functions.append(script.allocator.allocator(), .init(
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
            .callback = functionCallback,
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

        while (i < script.byond_functions.items.len) : (i += 1) {
            const func = &script.byond_functions.items[i];

            if (func.name == symbol_id) {
                func.deinit();
                _ = script.byond_functions.swapRemove(i);

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
            for (script.byond_functions.items) |*func| {
                func.deinit();
            }

            script.byond_functions.clearRetainingCapacity();
            script.native_functions.clearRetainingCapacity();
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

    pub inline fn getOpPos(this: *State, id: Script.Id, ip: usize) GetOpPosError!usize {
        const script = this.findScript(id) orelse {
            z.getState().last_error = @errorName(GetOpPosError.ScriptNotFound);

            return GetOpPosError.ScriptNotFound;
        };

        var pos: usize = 0;

        if (c.basic26_DebugInfo_get_source_pos(script.debug_info.?, ip, &pos) != c.BASIC26_RESULT_OK) {
            z.getState().last_error = @errorName(GetOpPosError.OutOfRange);

            return GetOpPosError.OutOfRange;
        }

        return pos;
    }

    pub inline fn getUsedMemory(this: *State, id: Script.Id) GetUsedMemoryError!usize {
        const script = this.findScript(id) orelse {
            z.getState().last_error = @errorName(GetOpPosError.ScriptNotFound);

            return GetUsedMemoryError.ScriptNotFound;
        };

        return script.allocator.used;
    }

    pub inline fn registerBuiltinArray(this: *State, id: Script.Id) RegisterBuiltinArrayError!void {
        const script = this.findScript(id) orelse {
            z.getState().last_error = @errorName(RegisterBuiltinArrayError.ScriptNotFound);

            return RegisterBuiltinArrayError.ScriptNotFound;
        };

        // Array_Create out
        registerNativeFunction(script, "Array_Create", ManagedObject.Value.Array.createFunction, &.{
            .{ .symbol = true },
        }) catch {
            z.getState().last_error = @errorName(RegisterBuiltinArrayError.OutOfMemory);

            return RegisterBuiltinArrayError.OutOfMemory;
        };

        // Array_Push this, value
        registerNativeFunction(script, "Array_Push", ManagedObject.Value.Array.pushFunction, &.{
            .{ .object = true },
            .anyVarargs(),
        }) catch {
            z.getState().last_error = @errorName(RegisterBuiltinArrayError.OutOfMemory);

            return RegisterBuiltinArrayError.OutOfMemory;
        };

        // Array_Pop this, out
        registerNativeFunction(script, "Array_Pop", ManagedObject.Value.Array.popFunction, &.{
            .{ .object = true },
            .{ .null = true, .symbol = true },
        }) catch {
            z.getState().last_error = @errorName(RegisterBuiltinArrayError.OutOfMemory);

            return RegisterBuiltinArrayError.OutOfMemory;
        };

        // Array_At this, idx, out
        registerNativeFunction(script, "Array_At", ManagedObject.Value.Array.atFunction, &.{
            .{ .object = true },
            .{ .int = true },
            .{ .symbol = true },
        }) catch {
            z.getState().last_error = @errorName(RegisterBuiltinArrayError.OutOfMemory);

            return RegisterBuiltinArrayError.OutOfMemory;
        };

        // Array_Set this, idx, value
        registerNativeFunction(script, "Array_Set", ManagedObject.Value.Array.setFunction, &.{
            .{ .object = true },
            .{ .int = true },
            .any(),
        }) catch {
            z.getState().last_error = @errorName(RegisterBuiltinArrayError.OutOfMemory);

            return RegisterBuiltinArrayError.OutOfMemory;
        };

        // Array_Len this, out
        registerNativeFunction(script, "Array_Len", ManagedObject.Value.Array.lenFunction, &.{
            .{ .object = true },
            .{ .symbol = true },
        }) catch {
            z.getState().last_error = @errorName(RegisterBuiltinArrayError.OutOfMemory);

            return RegisterBuiltinArrayError.OutOfMemory;
        };

        // Array_Remove this, idx, out
        registerNativeFunction(script, "Array_Remove", ManagedObject.Value.Array.removeFunction, &.{
            .{ .object = true },
            .{ .int = true },
            .{ .null = true, .symbol = true },
        }) catch {
            z.getState().last_error = @errorName(RegisterBuiltinArrayError.OutOfMemory);

            return RegisterBuiltinArrayError.OutOfMemory;
        };

        // Array_Clear this, idx, value
        registerNativeFunction(script, "Array_Insert", ManagedObject.Value.Array.insertFunction, &.{
            .{ .object = true },
            .{ .int = true },
            .any(),
        }) catch {
            z.getState().last_error = @errorName(RegisterBuiltinArrayError.OutOfMemory);

            return RegisterBuiltinArrayError.OutOfMemory;
        };

        // Array_Clear this
        registerNativeFunction(script, "Array_Clear", ManagedObject.Value.Array.clearFunction, &.{
            .{ .object = true },
        }) catch {
            z.getState().last_error = @errorName(RegisterBuiltinArrayError.OutOfMemory);

            return RegisterBuiltinArrayError.OutOfMemory;
        };
    }

    pub inline fn registerBuiltinText(this: *State, id: Script.Id) RegisterBuiltinTextError!void {
        const script = this.findScript(id) orelse {
            z.getState().last_error = @errorName(RegisterBuiltinTextError.ScriptNotFound);

            return RegisterBuiltinTextError.ScriptNotFound;
        };

        // Text_Create out
        registerNativeFunction(script, "Text_Create", ManagedObject.Value.Text.createFunction, &.{
            .{ .symbol = true },
        }) catch {
            z.getState().last_error = @errorName(RegisterBuiltinTextError.OutOfMemory);

            return RegisterBuiltinTextError.OutOfMemory;
        };

        // Text_Append this, args
        registerNativeFunction(script, "Text_Append", ManagedObject.Value.Text.appendFunction, &.{
            .{ .object = true },
            .anyVarargs(),
        }) catch {
            z.getState().last_error = @errorName(RegisterBuiltinTextError.OutOfMemory);

            return RegisterBuiltinTextError.OutOfMemory;
        };

        // Text_StartsWith this, value, out
        registerNativeFunction(script, "Text_StartsWith", ManagedObject.Value.Text.startsWithFunction, &.{
            .{ .object = true },
            .{ .string = true, .object = true },
            .{ .symbol = true },
        }) catch {
            z.getState().last_error = @errorName(RegisterBuiltinTextError.OutOfMemory);

            return RegisterBuiltinTextError.OutOfMemory;
        };

        // Text_EndsWith this, value, out
        registerNativeFunction(script, "Text_EndsWith", ManagedObject.Value.Text.endsWithFunction, &.{
            .{ .object = true },
            .{ .string = true, .object = true },
            .{ .symbol = true },
        }) catch {
            z.getState().last_error = @errorName(RegisterBuiltinTextError.OutOfMemory);

            return RegisterBuiltinTextError.OutOfMemory;
        };

        // Text_Clear this
        registerNativeFunction(script, "Text_Clear", ManagedObject.Value.Text.clearFunction, &.{
            .{ .object = true },
        }) catch {
            z.getState().last_error = @errorName(RegisterBuiltinTextError.OutOfMemory);

            return RegisterBuiltinTextError.OutOfMemory;
        };
    }

    inline fn registerNativeFunction(
        script: *Script,
        name: []const u8,
        callback: NativeFunction.Callback,
        comptime typings: []const Typing,
    ) error{OutOfMemory}!void {
        var symbol_id: c.basic26_SymbolId = undefined;

        if (c.basic26_Vm_get_string_id(script.vm.?, name.ptr, name.len, true, &symbol_id) != c.BASIC26_RESULT_OK) {
            return error.OutOfMemory;
        }

        for (script.native_functions.items) |existing| {
            if (existing.name == symbol_id) {
                return error.OutOfMemory;
            }
        }

        var typings_buffer = std.mem.zeroes([MAX_ARGS]Typing);
        const typings_len = typings.len;

        if (typings_len > MAX_ARGS) {
            return error.OutOfMemory;
        }

        for (typings, 0..) |t, i| {
            typings_buffer[i] = t;
        }

        script.native_functions.append(script.allocator.allocator(), .init(
            symbol_id,
            callback,
            typings_buffer,
            typings_len,
        )) catch {
            return error.OutOfMemory;
        };

        if (c.basic26_Vm_register_function(script.vm.?, &.{
            .name = symbol_id,
            .callback = functionCallback,
        }) != c.BASIC26_RESULT_OK) {
            return error.OutOfMemory;
        }
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

    fn functionCallback(
        info: ?*const c.basic26_CallInfo,
        argc: usize,
        argv: ?[*]const c.basic26_Value,
    ) callconv(.c) c.basic26_FunctionResult {
        const this: *Script = @ptrCast(@alignCast(info.?.userdata));

        for (this.native_functions.items) |*func| {
            if (func.name == info.?.function_name) {
                return nativeFunctionDispatch(this, func, argc, argv.?);
            }
        }

        const func: ByondFunction = blk: {
            for (this.byond_functions.items) |func| {
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

                    switch (object.value) {
                        .byond => {
                            args.appendAssumeCapacity(object.value.byond.src);
                        },
                        .text => {
                            const str = object.value.text.data.items;

                            const zstr = this.allocator.allocator().dupeSentinel(u8, str, 0) catch {
                                return c.BASIC26_FUNCTION_RESULT_ERROR;
                            };
                            defer this.allocator.allocator().free(zstr);

                            var value: x.ByondValue = .{};
                            x.ByondValue_SetStr(&value, zstr);

                            args.appendAssumeCapacity(value);
                        },
                        else => {
                            return c.BASIC26_FUNCTION_RESULT_ERROR;
                        },
                    }
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

    inline fn nativeFunctionDispatch(
        this: *Script,
        func: *const NativeFunction,
        argc: usize,
        argv: [*]const c.basic26_Value,
    ) c.basic26_FunctionResult {
        if (argc > MAX_ARGS) {
            return c.BASIC26_FUNCTION_RESULT_ERROR;
        }

        var varargs: ?Typing = null;
        var i: usize = 0;

        while (i < argc) : (i += 1) {
            const arg = argv[i];

            if (varargs) |va| {
                if (!va.isTypeAllowed(arg.type)) {
                    return c.BASIC26_FUNCTION_RESULT_ERROR;
                }
            } else {
                if (i >= func.typings_len) {
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
        }

        return func.callback(this, argv[0..argc]);
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

export fn Z_script_register_builtin_array(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 1) {
        x.Byond_CRASH("Z_script_register_builtin_array requires 1 argument");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Script.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));

    state.registerBuiltinArray(id) catch {
        return z.returnCast(.{});
    };

    return z.returnCast(x.True());
}

export fn Z_script_register_builtin_text(argc: x.u4c, argv: [*c]x.ByondValue) callconv(.c) z.ReturnType {
    const args = argv[0..argc];

    if (args.len != 1) {
        x.Byond_CRASH("Z_script_register_builtin_text requires 1 argument");

        return z.returnCast(.{});
    }

    const state = getState();
    const id: Script.Id = @intFromFloat(x.ByondValue_GetNum(&args[0]));

    state.registerBuiltinText(id) catch {
        return z.returnCast(.{});
    };

    return z.returnCast(x.True());
}
