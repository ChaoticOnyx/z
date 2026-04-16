// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const profiler = b.option(bool, "profiler", "Enable profiler") orelse false;

    const libws = b.createModule(.{
        .root_source_file = b.path("src/libws.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = optimize != .Debug,
    });

    const libws_tests = b.addTest(.{
        .root_module = libws,
    });

    const libws_tests_run = b.addRunArtifact(libws_tests);
    const libws_tests_step = b.step("libws-test", "Run the libws tests");

    libws_tests_step.dependOn(&libws_tests_run.step);

    createLib(b, optimize, profiler);
}

fn createRootModule(b: *std.Build, os: std.Target.Os.Tag, optimize: std.builtin.OptimizeMode, profiler: bool) *std.Build.Module {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86,
        .os_tag = os,
        .abi = .gnu,
        .glibc_version = if (os == .linux) .{ .major = 2, .minor = 17, .patch = 0 } else null,
    });

    const ondatra = b.dependency("ondatra", .{
        .target = target,
        .optimize = optimize,
    });

    const mcu_sdk = b.dependency("mcu_sdk", .{
        .target = target,
        .optimize = optimize,
    });

    const zlua = b.dependency("zlua", .{
        .target = target,
        .optimize = optimize,
        .lang = .luau,
    });

    const options = b.addOptions();
    options.addOption(bool, "profiler", profiler);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .strip = optimize != .Debug,
        .imports = &.{
            .{ .name = "ondatra", .module = ondatra.module("ondatra") },
            .{ .name = "mcu_sdk", .module = mcu_sdk.module("mcu_sdk") },
            .{ .name = "options", .module = options.createModule() },
            .{ .name = "zlua", .module = zlua.module("zlua") },
        },
    });

    if (target.result.os.tag == .windows) {
        mod.linkSystemLibrary("Ws2_32", .{});
    }

    mod.addIncludePath(b.path("src/"));

    return mod;
}

fn createLib(b: *std.Build, optimize: std.builtin.OptimizeMode, profiler: bool) void {
    const windows_lib = b.addLibrary(.{
        .name = "libz",
        .linkage = .dynamic,
        .root_module = createRootModule(b, .windows, optimize, profiler),
    });
    b.installArtifact(windows_lib);

    const linux_lib = b.addLibrary(.{
        .name = "libz",
        .linkage = .dynamic,
        .root_module = createRootModule(b, .linux, optimize, profiler),
    });
    b.installArtifact(linux_lib);
}
