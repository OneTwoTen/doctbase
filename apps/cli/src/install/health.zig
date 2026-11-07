//! Post-install readiness verification over Unix sockets.
//!
//! The installer starts `doctbase.target` and then waits until the gateway and
//! management sockets answer `/readyz`. A missing socket, a non-200 response or
//! a bind failure is reported as "not ready" so the orchestrator can fail the
//! health step and roll back the resources created by this run.
//!
//! Mapping source: `specs/001-doctbase-install-config/specs` US1 acceptance #1
//! and `contracts/service-protocol.md`.

const std = @import("std");
const registry = @import("service_lifecycle").registry;
const health_probe = @import("service_lifecycle").health_probe;

pub const Result = struct {
    gateway_ready: bool,
    management_ready: bool,
};

pub const Options = struct {
    /// Poll interval and total budget. The default keeps a fresh install under
    /// the five-minute acceptance target while tolerating slow TLS start-up.
    interval_ms: u32 = 500,
    timeout_ms: u32 = 60_000,
    probe_timeout_ms: u32 = 1_000,
    gateway_socket: []const u8 = "/run/doctbase/gateway.sock",
    management_socket: []const u8 = "/run/doctbase/management.sock",
    path: []const u8 = "/readyz",
};

pub fn wait(io: std.Io, options: Options) Result {
    const interval = if (options.interval_ms == 0) 1 else options.interval_ms;
    const attempts: u32 = @max(1, options.timeout_ms / interval);

    var gateway_ready = false;
    var management_ready = false;
    var attempt: u32 = 0;
    while (attempt < attempts) : (attempt += 1) {
        gateway_ready = probe(io, options.gateway_socket, options.probe_timeout_ms, options.path);
        management_ready = probe(io, options.management_socket, options.probe_timeout_ms, options.path);
        if (gateway_ready and management_ready) break;
        std.Io.sleep(io, .{ .nanoseconds = @as(i96, interval) * std.time.ns_per_ms }, .awake) catch {};
    }

    return .{
        .gateway_ready = gateway_ready,
        .management_ready = management_ready,
    };
}

/// Read the default socket paths from the shared service registry so a rename
/// cannot leave the health check probing a stale endpoint.
pub fn registryOptions(timeout_ms: u32) ?Options {
    const gateway = registry.get(.gateway).socket_path orelse return null;
    const management = registry.get(.management).socket_path orelse return null;
    return .{
        .timeout_ms = timeout_ms,
        .gateway_socket = gateway,
        .management_socket = management,
    };
}

fn probe(io: std.Io, socket_path: []const u8, timeout_ms: u32, path: []const u8) bool {
    const result = health_probe.probe(io, socket_path, timeout_ms, path) catch return false;
    return result.ready;
}
