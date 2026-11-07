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

    const telemetry_mod = b.addModule("telemetry", .{
        .root_source_file = b.path("packages/telemetry/src/telemetry.zig"),
        .target = target,
        .optimize = optimize,
    });

    const http_mod = b.addModule("http", .{
        .root_source_file = b.path("packages/http/src/http.zig"),
        .target = target,
        .optimize = optimize,
    });

    const postgres_mod = b.addModule("postgres", .{
        .root_source_file = b.path("packages/postgres/src/postgres.zig"),
        .target = target,
        .optimize = optimize,
    });

    const security_mod = b.addModule("security", .{
        .root_source_file = b.path("packages/security/src/security.zig"),
        .target = target,
        .optimize = optimize,
    });

    const preflight_mod = b.addModule("preflight", .{
        .root_source_file = b.path("apps/cli/src/install/preflight.zig"),
        .target = target,
        .optimize = optimize,
    });

    const install_packages_mod = b.addModule("install_packages", .{
        .root_source_file = b.path("apps/cli/src/install/packages.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "preflight", .module = preflight_mod }},
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

    const management = b.addExecutable(.{
        .name = "doctbase-management",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/management/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "runtime", .module = runtime_mod },
                .{ .name = "service_lifecycle", .module = lifecycle_mod },
                .{ .name = "security", .module = security_mod },
            },
        }),
    });
    b.installArtifact(management);

    const storage = b.addExecutable(.{
        .name = "doctbase-storage",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/storage/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "runtime", .module = runtime_mod },
            },
        }),
    });
    b.installArtifact(storage);

    const pg_meta = b.addExecutable(.{
        .name = "doctbase-pg-meta",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/pg-meta/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "runtime", .module = runtime_mod },
            },
        }),
    });
    b.installArtifact(pg_meta);

    const rest = b.addExecutable(.{
        .name = "doctbase-rest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/rest/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "runtime", .module = runtime_mod },
            },
        }),
    });
    b.installArtifact(rest);

    const realtime = b.addExecutable(.{
        .name = "doctbase-realtime",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/realtime/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "runtime", .module = runtime_mod },
            },
        }),
    });
    b.installArtifact(realtime);

    const image_proxy = b.addExecutable(.{
        .name = "doctbase-image-proxy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/image-proxy/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "runtime", .module = runtime_mod },
            },
        }),
    });
    b.installArtifact(image_proxy);

    const cli = b.addExecutable(.{
        .name = "doctbase",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/cli/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "service_lifecycle", .module = lifecycle_mod },
                .{ .name = "config", .module = config_mod },
            },
        }),
    });
    b.installArtifact(cli);

    const run_gateway = b.addRunArtifact(gateway);
    run_gateway.step.dependOn(b.getInstallStep());
    const run_step = b.step("run-gateway", "Run the gateway service");
    run_step.dependOn(&run_gateway.step);

    const fmt_command = b.addSystemCommand(&.{ "zig", "fmt", "--check", "build.zig", "apps", "packages", "tests", "tools" });
    const fmt_step = b.step("fmt", "Check Zig source formatting");
    fmt_step.dependOn(&fmt_command.step);

    const test_step = b.step("test", "Run unit tests");

    const preflight_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/preflight_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "preflight", .module = preflight_mod }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(preflight_tests).step);

    const install_packages_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/install_packages_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "install_packages", .module = install_packages_mod },
                .{ .name = "preflight", .module = preflight_mod },
            },
        }),
    });
    const run_install_packages_tests = b.addRunArtifact(install_packages_tests);
    test_step.dependOn(&run_install_packages_tests.step);
    const install_packages_test_step = b.step("test-install-packages", "Run package installer unit tests");
    install_packages_test_step.dependOn(&run_install_packages_tests.step);

    inline for (.{ core_mod, config_mod, protocol_mod, runtime_mod, lifecycle_mod, postgres_mod, telemetry_mod, http_mod, security_mod }) |module| {
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

    const runtime_tcp_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/runtime_tcp_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "runtime", .module = runtime_mod },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(runtime_tcp_tests).step);

    const runtime_tcp_security_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/security/runtime_tcp_security_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "runtime", .module = runtime_mod },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(runtime_tcp_security_tests).step);

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

    const management_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/management/src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "service_lifecycle", .module = lifecycle_mod },
                .{ .name = "service_protocol", .module = protocol_mod },
                .{ .name = "core", .module = core_mod },
                .{ .name = "security", .module = security_mod },
            },
        }),
    });
    const cli_output_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/cli/src/output.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_cli_output_tests = b.addRunArtifact(cli_output_tests);
    test_step.dependOn(&run_cli_output_tests.step);

    const gateway_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/gateway/src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_gateway_tests = b.addRunArtifact(gateway_tests);
    test_step.dependOn(&run_gateway_tests.step);

    const auth_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/auth/src/keys.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_auth_tests = b.addRunArtifact(auth_tests);
    test_step.dependOn(&run_auth_tests.step);

    const harness_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/harness.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_harness_tests = b.addRunArtifact(harness_tests);
    test_step.dependOn(&run_harness_tests.step);

    inline for (.{
        "tests/unit/runtime_bootstrap_test.zig",
        "tests/unit/runtime_health_test.zig",
        "tests/unit/runtime_shutdown_test.zig",
    }) |test_file| {
        const u_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(test_file),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "runtime", .module = runtime_mod },
                    .{ .name = "config", .module = config_mod },
                },
            }),
        });
        const run_u_test = b.addRunArtifact(u_test);
        test_step.dependOn(&run_u_test.step);
    }

    const run_management_tests = b.addRunArtifact(management_tests);
    test_step.dependOn(&run_management_tests.step);
}
