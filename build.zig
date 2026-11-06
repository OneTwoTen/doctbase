const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core_mod = b.addModule("core", .{
        .root_source_file = b.path("packages/core/src/errors.zig"),
        .target = target,
        .optimize = optimize,
    });
    const config_mod = b.addModule("config", .{
        .root_source_file = b.path("packages/config/src/config.zig"),
        .target = target,
        .optimize = optimize,
    });
    const protocol_mod = b.addModule("service_protocol", .{
        .root_source_file = b.path("packages/service-protocol/src/protocol.zig"),
        .target = target,
        .optimize = optimize,
    });

    const httpz_mod = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    }).module("httpz");

    const runtime_mod = b.addModule("runtime", .{
        .root_source_file = b.path("packages/runtime/src/runtime.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "httpz", .module = httpz_mod },
            .{ .name = "config", .module = config_mod },
            .{ .name = "service_protocol", .module = protocol_mod },
            .{ .name = "core", .module = core_mod },
        },
    });

    const lifecycle_mod = b.addModule("service_lifecycle", .{
        .root_source_file = b.path("packages/service-lifecycle/src/lifecycle.zig"),
        .target = target,
        .optimize = optimize,
    });

    const gateway = b.addExecutable(.{
        .name = "doctbase-gateway",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/gateway/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "runtime", .module = runtime_mod },
            },
        }),
    });
    b.installArtifact(gateway);

    const auth = b.addExecutable(.{
        .name = "doctbase-auth",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/auth/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "runtime", .module = runtime_mod },
            },
        }),
    });
    b.installArtifact(auth);

    const cli = b.addExecutable(.{
        .name = "doctbase",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/cli/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "service_lifecycle", .module = lifecycle_mod },
            },
        }),
    });
    b.installArtifact(cli);

    const run_gateway = b.addRunArtifact(gateway);
    run_gateway.step.dependOn(b.getInstallStep());
    const run_step = b.step("run-gateway", "Run the gateway service");
    run_step.dependOn(&run_gateway.step);

    const test_step = b.step("test", "Run unit tests");
    inline for (.{ core_mod, config_mod, protocol_mod, runtime_mod, lifecycle_mod }) |module| {
        const tests = b.addTest(.{ .root_module = module });
        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
    }

    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/runtime_uds_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "runtime", .module = runtime_mod },
            },
        }),
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    test_step.dependOn(&run_integration_tests.step);

    const security_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/security/runtime_security_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "runtime", .module = runtime_mod },
            },
        }),
    });
    const run_security_tests = b.addRunArtifact(security_tests);
    test_step.dependOn(&run_security_tests.step);

    const health_probe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/health_probe_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "runtime", .module = runtime_mod },
                .{ .name = "service_lifecycle", .module = lifecycle_mod },
            },
        }),
    });
    const run_health_probe_tests = b.addRunArtifact(health_probe_tests);
    test_step.dependOn(&run_health_probe_tests.step);

    const dev_runner_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/dev_runner_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "service_lifecycle", .module = lifecycle_mod },
            },
        }),
    });
    const run_dev_runner_tests = b.addRunArtifact(dev_runner_tests);
    run_dev_runner_tests.step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_dev_runner_tests.step);
}
