const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zoto_dep = b.dependency("zoto", .{
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "person",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zoto", .module = zoto_dep.module("zoto") },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the person example");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
