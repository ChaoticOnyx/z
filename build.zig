// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    createLib(b, optimize);
}

fn createRootModule(b: *std.Build, os: std.Target.Os.Tag, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86,
        .os_tag = os,
        .abi = if (os == .linux) .musl else .gnu,
    });

    const ondatra = b.dependency("ondatra", .{
        .target = target,
        .optimize = optimize,
    });

    const mcu_sdk = b.dependency("mcu_sdk", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = os == .linux,
        .strip = optimize != .Debug,
        .imports = &.{
            .{ .name = "ondatra", .module = ondatra.module("ondatra") },
            .{ .name = "mcu_sdk", .module = mcu_sdk.module("mcu_sdk") },
        },
    });

    mod.addIncludePath(b.path("src/"));

    return mod;
}

fn createLib(b: *std.Build, optimize: std.builtin.OptimizeMode) void {
    const windows_lib = b.addLibrary(.{
        .name = "libz",
        .linkage = .dynamic,
        .root_module = createRootModule(b, .windows, optimize),
    });
    b.installArtifact(windows_lib);

    const linux_lib = b.addLibrary(.{
        .name = "libz",
        .linkage = .dynamic,
        .root_module = createRootModule(b, .linux, optimize),
    });
    b.installArtifact(linux_lib);
}
