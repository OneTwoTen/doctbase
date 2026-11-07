//! Human-readable install summary, failure output and support hints.
//!
//! Kept separate from the CLI parser so the wording can be tested and reused by
//! the bootstrap script. Secrets are referenced by path only; no value is ever
//! printed.

const std = @import("std");
const install = @import("install_orchestrator");
const preflight = @import("preflight");

pub fn print(options: *const install.Options, outcome: *const install.Outcome) void {
    switch (outcome.status) {
        .blocked => {
            std.debug.print("Installation blocked by preflight.\n", .{});
            printFindings(outcome.report);
            std.debug.print("Fix the items above and re-run `doctbase install`.\n", .{});
        },
        .dry_run => {
            if (options.domain.len == 0) {
                std.debug.print("Plan (local mode, no domain):\n", .{});
            } else {
                std.debug.print("Plan (domain: {s}):\n", .{options.domain});
            }
            for (install.plan, 1..) |line, index| {
                std.debug.print("  {d}. {s}\n", .{ index, line });
            }
            if (outcome.report.count != 0) {
                std.debug.print("\nWarnings:\n", .{});
                printFindings(outcome.report);
            }
            std.debug.print("\nNo changes were made.\n", .{});
        },
        .failed => {
            const failure = outcome.failure orelse install.Failure{
                .step = .preflight,
                .code = "INSTALL_FAILED",
                .detail = "unknown",
            };
            std.debug.print("Installation failed during {s}: {s} ({s}).\n", .{
                @tagName(failure.step),
                failure.code,
                failure.detail,
            });
            if (outcome.rolled_back) {
                std.debug.print("Rollback removed resources created by this run.\n", .{});
            } else {
                std.debug.print("Some resources may remain; inspect the log before retrying.\n", .{});
            }
            std.debug.print("Log: {s}\n", .{options.log_path});
            std.debug.print("Docs: https://doctbase.dev/docs/troubleshooting\n", .{});
        },
        .installed => {
            const summary = outcome.summary orelse unreachable;
            std.debug.print("Doctbase {s} is installed.\n", .{summary.version});
            if (summary.domain.len == 0) {
                std.debug.print(
                    \\Mode: local (no domain configured)
                    \\Admin: reach the management socket through an SSH tunnel:
                    \\  ssh -L 8081:/run/doctbase/management.sock <server>
                    \\
                , .{});
            } else {
                std.debug.print("Mode: {s} with automatic HTTPS\n", .{summary.domain});
                std.debug.print("Dashboard: https://admin.{s}/\n", .{summary.domain});
            }
            std.debug.print(
                \\Health: gateway {s}, management {s}
                \\Config: /etc/doctbase/doctbase.toml
                \\Setup token: {s} (read it as root; it is never printed)
                \\Log: {s}
                \\State: {s}
                \\
                \\Next: see docs/install.md for the setup and project steps.
                \\
            , .{
                if (summary.gateway_ready) "ready" else "not ready",
                if (summary.management_ready) "ready" else "not ready",
                summary.setup_token_path,
                summary.log_path,
                summary.state_path,
            });
        },
    }
}

pub fn printFindings(report: preflight.Report) void {
    for (report.findings[0..report.count]) |finding| {
        var docs_buffer: [128]u8 = undefined;
        const docs = finding.docsUrl(&docs_buffer) catch "";
        std.debug.print("  [{s}] {s}: {s}\n", .{
            @tagName(finding.severity),
            finding.code.codeString(),
            finding.message(),
        });
        std.debug.print("      Fix: {s}\n", .{finding.fix()});
        std.debug.print("      Docs: {s}\n", .{docs});
    }
}
