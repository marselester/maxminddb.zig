const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const maxminddb_module = b.addModule("maxminddb", .{
        .root_source_file = b.path("src/maxminddb.zig"),
    });

    {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .root_source_file = b.path("src/maxminddb.zig"),
            }),
        });

        const run_tests = b.addRunArtifact(tests);
        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_tests.step);
    }

    const examples = [_]struct {
        file: []const u8,
        name: []const u8,
    }{
        .{ .file = "examples/lookup.zig", .name = "example_lookup" },
        .{ .file = "examples/within.zig", .name = "example_within" },
    };

    {
        for (examples) |ex| {
            const exe = b.addExecutable(.{
                .name = ex.name,
                .root_module = b.createModule(.{
                    .target = target,
                    .optimize = optimize,
                    .root_source_file = b.path(ex.file),
                }),
            });
            exe.root_module.addImport("maxminddb", maxminddb_module);
            b.installArtifact(exe);

            const run_cmd = b.addRunArtifact(exe);
            run_cmd.step.dependOn(b.getInstallStep());
            if (b.args) |args| {
                run_cmd.addArgs(args);
            }

            const run_step = b.step(ex.name, ex.file);
            run_step.dependOn(&run_cmd.step);
        }
    }
}
