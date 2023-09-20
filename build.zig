const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sqlite3_dep = b.dependency("sqlite3", .{
        .target = target,
        .optimize = optimize,
    });
    const zigimg_dep = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });
    const utils_dep = b.dependency("utils", .{
        .target = target,
        .optimize = optimize,
    });
    const glfw_dep = b.dependency("glfw", .{
        .target = target,
        .optimize = optimize,
        .opengl = true,
    });

    const gl_module = b.addModule("gl", .{
        .source_file = .{ .path = "dep/gles3v0.zig" },
    });

    const exe = b.addExecutable(.{
        .name = "my-finances-app",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.addModule("sqlite3", sqlite3_dep.module("sqlite3"));
    exe.addModule("zigimg", zigimg_dep.module("zigimg"));
    exe.addModule("utils", utils_dep.module("utils.zig"));
    exe.addModule("gl", gl_module);
    exe.linkLibrary(sqlite3_dep.artifact("sqlite3"));
    exe.linkLibrary(glfw_dep.artifact("glfw"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_test = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_test.step);
}
