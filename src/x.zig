// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const builtin = @import("builtin");

const logger = @import("logger.zig");

pub const c = @cImport({
    @cInclude("byondapi.h");
});

const symbols = .{
    .{ "Byond_LastError", c.Byond_LastError },
    .{ "Byond_SetLastError", c.Byond_SetLastError },
    .{ "Byond_GetVersion", c.Byond_GetVersion },
    .{ "Byond_GetDMBVersion", c.Byond_GetDMBVersion },

    .{ "ByondValue_Clear", c.ByondValue_Clear },
    .{ "ByondValue_Type", c.ByondValue_Type },
    .{ "ByondValue_IsNull", c.ByondValue_IsNull },
    .{ "ByondValue_IsNum", c.ByondValue_IsNum },
    .{ "ByondValue_IsStr", c.ByondValue_IsStr },
    .{ "ByondValue_IsList", c.ByondValue_IsList },
    .{ "ByondValue_IsTrue", c.ByondValue_IsTrue },
    .{ "ByondValue_GetNum", c.ByondValue_GetNum },
    .{ "ByondValue_GetRef", c.ByondValue_GetRef },
    .{ "ByondValue_SetNum", c.ByondValue_SetNum },
    .{ "ByondValue_SetStr", c.ByondValue_SetStr },
    .{ "ByondValue_SetStrId", c.ByondValue_SetStrId },
    .{ "ByondValue_SetRef", c.ByondValue_SetRef },
    .{ "ByondValue_Equals", c.ByondValue_Equals },
    .{ "ByondValue_Equiv", c.ByondValue_Equiv },

    .{ "Byond_ThreadSync", c.Byond_ThreadSync },
    .{ "Byond_GetStrId", c.Byond_GetStrId },
    .{ "Byond_AddGetStrId", c.Byond_AddGetStrId },
    .{ "Byond_ReadVar", c.Byond_ReadVar },
    .{ "Byond_ReadVarByStrId", c.Byond_ReadVarByStrId },
    .{ "Byond_WriteVar", c.Byond_WriteVar },
    .{ "Byond_WriteVarByStrId", c.Byond_WriteVarByStrId },
    .{ "Byond_CreateList", c.Byond_CreateList },
    .{ "Byond_CreateListLen", c.Byond_CreateListLen },
    .{ "Byond_CreateDimensionalList", c.Byond_CreateDimensionalList },
    .{ "Byond_ReadList", c.Byond_ReadList },
    .{ "Byond_ReadListAssoc", c.Byond_ReadListAssoc },
    .{ "Byond_WriteList", c.Byond_WriteList },
    .{ "Byond_ReadListIndex", c.Byond_ReadListIndex },
    .{ "Byond_WriteListIndex", c.Byond_WriteListIndex },
    .{ "Byond_ListRemove", c.Byond_ListRemove },
    .{ "Byond_ReadPointer", c.Byond_ReadPointer },
    .{ "Byond_WritePointer", c.Byond_WritePointer },

    .{ "Byond_CallProc", c.Byond_CallProc },
    .{ "Byond_CallProcByStrId", c.Byond_CallProcByStrId },
    .{ "Byond_CallGlobalProc", c.Byond_CallGlobalProc },
    .{ "Byond_CallGlobalProcByStrId", c.Byond_CallGlobalProcByStrId },
    .{ "Byond_ToString", c.Byond_ToString },
    .{ "Byond_Return", c.Byond_Return },

    .{ "Byond_Block", c.Byond_Block },
    .{ "ByondValue_IsType", c.ByondValue_IsType },
    .{ "Byond_Length", c.Byond_Length },
    .{ "Byond_LocateIn", c.Byond_LocateIn },
    .{ "Byond_LocateXYZ", c.Byond_LocateXYZ },
    .{ "Byond_New", c.Byond_New },
    .{ "Byond_NewArglist", c.Byond_NewArglist },
    .{ "Byond_Refcount", c.Byond_Refcount },
    .{ "Byond_XYZ", c.Byond_XYZ },
    .{ "Byond_PixLoc", c.Byond_PixLoc },
    .{ "Byond_BoundPixLoc", c.Byond_BoundPixLoc },

    .{ "ByondValue_IncRef", c.ByondValue_IncRef },
    .{ "ByondValue_DecRef", c.ByondValue_DecRef },
    .{ "Byond_TestRef", c.Byond_TestRef },

    .{ "Byond_CRASH", c.Byond_CRASH },
};

pub const Table = blk: {
    var fields: [symbols.len]std.builtin.Type.StructField = undefined;

    for (symbols, 0..) |sym, i| {
        fields[i] = .{
            .name = sym[0],
            .type = @TypeOf(&sym[1]),
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(@TypeOf(&sym[1])),
        };
    }

    break :blk @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
};

const is_windows = builtin.os.tag == .windows;

extern "kernel32" fn GetModuleHandleExW(dwFlags: u32, lpModuleName: [*:0]const u16, phModule: *?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn GetProcAddress(hModule: *anyopaque, lpProcName: [*:0]const u8) callconv(.winapi) ?*anyopaque;

const GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT: u32 = 0x00000002;
const BYONDCORE_DLL: [*:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("byondcore.dll");

const Library = struct {
    handle: ?*anyopaque = null,
    table: ?Table = null,

    pub inline fn getTable(this: *Library) *const Table {
        if (this.table == null) {
            this.fillTable();
        }

        return &this.table.?;
    }

    inline fn getSymbolPtr(handle: *anyopaque, comptime name: [:0]const u8) ?*anyopaque {
        const ptr: ?*anyopaque = if (is_windows)
            GetProcAddress(handle, name.ptr)
        else
            std.c.dlsym(handle, name.ptr);

        return ptr;
    }

    inline fn getHandle(this: *Library) ?*anyopaque {
        if (this.handle == null) {
            if (comptime is_windows) {
                const result = GetModuleHandleExW(
                    GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                    BYONDCORE_DLL,
                    &this.handle,
                );

                if (result == 0) {
                    return null;
                }
            } else {
                this.handle = std.c.dlopen("libbyond.so", .{ .NOW = true, .NOLOAD = true });

                if (this.handle == null) {
                    if (std.c.dlerror()) |err| {
                        std.log.err("dlopen failed: {s}", .{std.mem.span(err)});
                    }

                    return null;
                }
            }
        }

        return this.handle;
    }

    fn fillTable(this: *Library) void {
        const handle = this.getHandle() orelse {
            std.log.err("failed to open the dynamic library handle", .{});

            @panic("failed to open the dynamic library handle");
        };

        this.table = undefined;

        inline for (symbols) |sym| {
            const name: [:0]const u8 = sym[0];
            const ptr = getSymbolPtr(handle, name) orelse {
                std.log.err("failed to load symbol '{s}'\n", .{name});

                std.debug.panic("Failed to load symbol '{s}'\n", .{name});
            };

            @field(this.table.?, sym[0]) = @ptrCast(@alignCast(ptr));
        }
    }
};

var library: Library = .{};

pub const u1c = c.u1c;
pub const s1c = c.s1c;
pub const u2c = c.u2c;
pub const s2c = c.s2c;
pub const u4c = c.u4c;
pub const s4c = c.s4c;

pub const ByondValue = c.CByondValue;
pub const ByondValueType = c.ByondValueType;
pub const ByondXYZ = c.CByondXYZ;
pub const ByondPixLoc = c.CByondPixLoc;
pub const ByondCallback = c.ByondCallback;

pub inline fn Byond_LastError(buf: *u8, buflen: *u4c) bool {
    const table = library.getTable();
    table.Byond_LastError(buf, buflen);
}

pub inline fn Byond_SetLastError(err: *const u8) void {
    const table = library.getTable();
    table.Byond_SetLastError(err);
}

pub inline fn Byond_GetVersion(version: *u4c, build: *u4c) void {
    const table = library.getTable();
    table.Byond_GetVersion(version, build);
}

pub inline fn Byond_GetDMBVersion() u4c {
    const table = library.getTable();
    return table.Byond_GetDMBVersion();
}

pub inline fn ByondValue_Clear(v: *ByondValue) void {
    const table = library.getTable();
    table.ByondValue_Clear(v);
}

pub inline fn ByondValue_Type(v: *const ByondValue) ByondValueType {
    const table = library.getTable();
    table.ByondValue_Type(v);
}

pub inline fn ByondValue_IsNull(v: *const ByondValue) bool {
    const table = library.getTable();
    return table.ByondValue_IsNull(v);
}

pub inline fn ByondValue_IsNum(v: *const ByondValue) bool {
    const table = library.getTable();
    return table.ByondValue_IsNum(v);
}

pub inline fn ByondValue_IsStr(v: *const ByondValue) bool {
    const table = library.getTable();
    return table.ByondValue_IsStr(v);
}

pub inline fn ByondValue_IsList(v: *const ByondValue) bool {
    const table = library.getTable();
    return table.ByondValue_IsList(v);
}

pub inline fn ByondValue_IsTrue(v: *const ByondValue) bool {
    const table = library.getTable();
    return table.ByondValue_IsTrue(v);
}

pub inline fn ByondValue_GetNum(v: *const ByondValue) f32 {
    const table = library.getTable();
    return table.ByondValue_GetNum(v);
}

pub inline fn ByondValue_GetRef(v: *const ByondValue) u4c {
    const table = library.getTable();
    return table.ByondValue_GetRef(v);
}

pub inline fn ByondValue_SetNum(v: *ByondValue, f: f32) void {
    const table = library.getTable();
    table.ByondValue_SetNum(v, f);
}

pub inline fn ByondValue_SetStr(v: *ByondValue, str: [:0]const u8) void {
    const table = library.getTable();
    table.ByondValue_SetStr(v, str);
}

pub inline fn ByondValue_SetStrId(v: *ByondValue, strid: u4c) void {
    const table = library.getTable();
    table.ByondValue_SetStrId(v, strid);
}

pub inline fn ByondValue_SetRef(v: *ByondValue, ty: ByondValueType, ref: u4c) void {
    const table = library.getTable();
    table.ByondValue_SetRef(v, ty, ref);
}

pub inline fn ByondValue_Equals(a: *const ByondValue, b: *const ByondValue) bool {
    const table = library.getTable();
    return table.ByondValue_Equals(a, b);
}

pub inline fn ByondValue_Equiv(a: *const ByondValue, b: *const ByondValue) bool {
    const table = library.getTable();
    return table.ByondValue_Equiv(a, b);
}

pub inline fn Byond_ThreadSync(callback: ByondCallback, data: ?*anyopaque, block: bool) ByondValue {
    const table = library.getTable();
    return table.Byond_ThreadSync(callback, data, block);
}

pub inline fn Byond_GetStrId(str: *const u8) u4c {
    const table = library.getTable();
    return table.Byond_GetStrId(str);
}

pub inline fn Byond_AddGetStrId(str: *const u8) u4c {
    const table = library.getTable();
    return table.Byond_AddGetStrId(str);
}

pub inline fn Byond_ReadVar(loc: *const ByondValue, varname: *const u8, result: *ByondValue) bool {
    const table = library.getTable();
    return table.Byond_ReadVar(loc, varname, result);
}

pub inline fn Byond_ReadVarByStrId(loc: *const ByondValue, varname: u4c, result: *ByondValue) bool {
    const table = library.getTable();
    return table.Byond_ReadVarByStrId(loc, varname, result);
}

pub inline fn Byond_WriteVar(loc: *const ByondValue, varname: *const u8, val: *const ByondValue) bool {
    const table = library.getTable();
    return table.Byond_WriteVar(loc, varname, val);
}

pub inline fn Byond_WriteVarByStrId(loc: *const ByondValue, varname: u4c, val: *const ByondValue) bool {
    const table = library.getTable();
    return table.Byond_WriteVarByStrId(loc, varname, val);
}

pub inline fn Byond_CreateList(result: *ByondValue) bool {
    const table = library.getTable();
    return table.Byond_CreateList(result);
}

pub inline fn Byond_CreateListLen(result: *ByondValue, len: u4c) bool {
    const table = library.getTable();
    return table.Byond_CreateListLen(result, len);
}

pub inline fn Byond_CreateDimensionalList(result: *ByondValue, sizes: *const u4c, dimension: u4c) bool {
    const table = library.getTable();
    return table.Byond_CreateDimensionalList(result, sizes, dimension);
}

pub inline fn Byond_ReadList(loc: *const ByondValue, list: *ByondValue, len: *u4c) bool {
    const table = library.getTable();
    return table.Byond_ReadList(loc, list, len);
}

pub inline fn Byond_ReadListAssoc(loc: *const ByondValue, list: *ByondValue, len: *u4c) bool {
    const table = library.getTable();
    return table.Byond_ReadListAssoc(loc, list, len);
}

pub inline fn Byond_WriteList(loc: *const ByondValue, list: *const ByondValue, len: u4c) bool {
    const table = library.getTable();
    return table.Byond_WriteList(loc, list, len);
}

pub inline fn Byond_ReadListIndex(loc: *const ByondValue, idx: *const ByondValue, result: *ByondValue) bool {
    const table = library.getTable();
    return table.Byond_ReadListIndex(loc, idx, result);
}

pub inline fn Byond_WriteListIndex(loc: *const ByondValue, idx: *const ByondValue, val: *const ByondValue) bool {
    const table = library.getTable();
    return table.Byond_WriteListIndex(loc, idx, val);
}

pub inline fn Byond_ListRemove(loc: *const ByondValue, items: *const ByondValue, count: u4c) u4c {
    const table = library.getTable();
    return table.Byond_ListRemove(loc, items, count);
}

pub inline fn Byond_ReadPointer(ptr: *const ByondValue, result: *ByondValue) bool {
    const table = library.getTable();
    return table.Byond_ReadPointer(ptr, result);
}

pub inline fn Byond_WritePointer(ptr: *const ByondValue, val: *const ByondValue) bool {
    const table = library.getTable();
    return table.Byond_WritePointer(ptr, val);
}

pub inline fn Byond_CallProc(src: *const ByondValue, name: [:0]const u8, arg: []const ByondValue, result: *ByondValue) bool {
    const table = library.getTable();
    return table.Byond_CallProc(src, name, arg.ptr, @intCast(arg.len), result);
}

pub inline fn Byond_CallProcByStrId(src: *const ByondValue, name: u4c, arg: []const ByondValue, result: *ByondValue) bool {
    const table = library.getTable();
    return table.Byond_CallProcByStrId(src, name, arg.ptr, @intCast(arg.len), result);
}

pub inline fn Byond_CallGlobalProc(name: [:0]const u8, arg: []const ByondValue, result: *ByondValue) bool {
    const table = library.getTable();
    return table.Byond_CallGlobalProc(name, arg.ptr, @intCast(arg.len), result);
}

pub inline fn Byond_CallGlobalProcByStrId(name: u4c, arg: []const ByondValue, result: *ByondValue) bool {
    const table = library.getTable();
    return table.Byond_CallGlobalProcByStrId(name, arg.ptr, @intCast(arg.len), result);
}

pub inline fn Byond_ToString(src: *const ByondValue, buf: ?[*]u8, buflen: *u4c) bool {
    const table = library.getTable();
    return table.Byond_ToString(src, buf, buflen);
}

pub inline fn Byond_Return(waiting_proc: *const ByondValue, retval: *const ByondValue) bool {
    const table = library.getTable();
    return table.Byond_Return(waiting_proc, retval);
}

pub inline fn Byond_Block(corner1: *const ByondXYZ, corner2: *const ByondXYZ, list: *ByondValue, len: *u4c) bool {
    const table = library.getTable();
    return table.Byond_Block(corner1, corner2, list, len);
}

pub inline fn ByondValue_IsType(src: *const ByondValue, typestr: *const u8) bool {
    const table = library.getTable();
    return table.ByondValue_IsType(src, typestr);
}

pub inline fn Byond_Length(src: *const ByondValue, result: *ByondValue) bool {
    const table = library.getTable();
    return table.Byond_Length(src, result);
}

pub inline fn Byond_LocateIn(ty: *const ByondValue, list: *const ByondValue, result: *ByondValue) bool {
    const table = library.getTable();
    return table.Byond_LocateIn(ty, list, result);
}

pub inline fn Byond_LocateXYZ(xyz: *const ByondXYZ, result: *ByondValue) bool {
    const table = library.getTable();
    return table.Byond_LocateXYZ(xyz, result);
}

pub inline fn Byond_New(ty: *const ByondValue, arg: *const ByondValue, arg_count: u4c, result: *ByondValue) bool {
    const table = library.getTable();
    return table.Byond_New(ty, arg, arg_count, result);
}

pub inline fn Byond_NewArglist(ty: *const ByondValue, arglist: *const ByondValue, result: *ByondValue) bool {
    const table = library.getTable();
    return table.Byond_NewArglist(ty, arglist, result);
}

pub inline fn Byond_Refcount(src: *const ByondValue, result: *u4c) bool {
    const table = library.getTable();
    return table.Byond_Refcount(src, result);
}

pub inline fn Byond_XYZ(src: *const ByondValue, xyz: *ByondXYZ) bool {
    const table = library.getTable();
    return table.Byond_XYZ(src, xyz);
}

pub inline fn Byond_PixLoc(src: *const ByondValue, pixloc: *ByondPixLoc) bool {
    const table = library.getTable();
    return table.Byond_XYZ(src, pixloc);
}

pub inline fn Byond_BoundPixLoc(src: *const ByondValue, dir: u1c, pixloc: *ByondPixLoc) bool {
    const table = library.getTable();
    return table.Byond_BoundPixLoc(src, dir, pixloc);
}

pub inline fn ByondValue_IncRef(src: *const ByondValue) void {
    const table = library.getTable();
    table.ByondValue_IncRef(src);
}

pub inline fn ByondValue_DecRef(src: *const ByondValue) void {
    const table = library.getTable();
    table.ByondValue_DecRef(src);
}

pub inline fn Byond_TestRef(src: *ByondValue) bool {
    const table = library.getTable();
    return table.Byond_TestRef(src);
}

pub inline fn Byond_CRASH(str: [:0]const u8) void {
    const table = library.getTable();
    table.Byond_CRASH(str);
}

pub inline fn numF(v: f32) ByondValue {
    var value: ByondValue = .{};
    ByondValue_SetNum(&value, v);

    return value;
}

pub inline fn num(v: u32) ByondValue {
    var value: ByondValue = .{};
    ByondValue_SetNum(&value, @floatFromInt(v));

    return value;
}

pub inline fn True() ByondValue {
    return num(1);
}

pub inline fn False() ByondValue {
    return num(0);
}

pub inline fn toString(allocator: std.mem.Allocator, v: *const ByondValue) ![:0]u8 {
    var buflen: u4c = 0;

    if (!Byond_ToString(v, null, &buflen) and buflen == 0) {
        return error.ToStringFailed;
    }

    const buf = try allocator.allocSentinel(u8, buflen, 0);
    errdefer allocator.free(buf);

    if (!Byond_ToString(v, buf.ptr, &buflen)) {
        return error.ToStringFailed;
    }

    return buf;
}
