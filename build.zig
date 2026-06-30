const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const bench_optimize = b.option(
        std.builtin.OptimizeMode,
        "bench-optimize",
        "Optimization mode for csv parser benchmarks",
    ) orelse .ReleaseFast;

    const csv_parser = b.addModule("csv_parser", .{
        .root_source_file = b.path("csv_parser.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .name = "csv-parser-test",
        .root_module = csv_parser,
    });

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run csv parser tests");
    test_step.dependOn(&run_tests.step);

    const examples_step = b.step("examples", "Build examples");

    const basic_example = b.addExecutable(.{
        .name = "csv-example-basic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/basic.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    basic_example.root_module.addImport("csv_parser", csv_parser);
    examples_step.dependOn(&basic_example.step);

    const streaming_example = b.addExecutable(.{
        .name = "csv-example-streaming",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/streaming.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    streaming_example.root_module.addImport("csv_parser", csv_parser);
    examples_step.dependOn(&streaming_example.step);

    const bench_exe = b.addExecutable(.{
        .name = "csv-parser-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench.zig"),
            .target = target,
            .optimize = bench_optimize,
        }),
    });

    const bench_run = b.addRunArtifact(bench_exe);
    if (b.args) |args| bench_run.addArgs(args);

    const bench_step = b.step("bench", "Run csv parser benchmarks");
    bench_step.dependOn(&bench_run.step);
}
