const std = @import("std");
const registry = @import("registry.zig");
const driver_mod = @import("driver.zig");

pub const Options = struct {
    docker_path: []const u8 = "docker",
    compose_file: ?[]const u8 = null,
    project_name: []const u8 = "doctbase",
    timeout_ms: u32 = 10000,
};

pub const ContainerStatus = struct {
    service: []const u8,
    state: driver_mod.ServiceState,
    health: driver_mod.Health,
};

pub const ComposeDriver = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) ComposeDriver {
        return .{
            .allocator = allocator,
            .io = io,
            .options = options,
        };
    }

    pub fn driver(self: *ComposeDriver) driver_mod.LifecycleDriver {
        return .{
            .context = self,
            .vtable = &vtable,
        };
    }

    const vtable = driver_mod.LifecycleDriver.VTable{
        .list = listFn,
        .get = getFn,
        .start = startFn,
        .stop = stopFn,
        .restart = restartFn,
        .setEnabled = setEnabledFn,
        .deinit = deinitFn,
    };

    fn listFn(context: *anyopaque, allocator: std.mem.Allocator) anyerror![]driver_mod.RuntimeState {
        const self: *ComposeDriver = @ptrCast(@alignCast(context));
        var states: std.ArrayList(driver_mod.RuntimeState) = .empty;
        errdefer states.deinit(allocator);

        // Run compose ps once for all services
        const output = self.runComposePs(null) catch null;
        defer if (output) |out| self.allocator.free(out);

        for (registry.specs()) |*spec| {
            if (spec.compose_service == null) continue;
            var state = stateFor(spec);

            if (output) |out| {
                if (parseContainerFromOutput(self.allocator, out, spec.compose_service.?)) |status| {
                    state.state = status.state;
                    state.health = status.health;
                }
            }
            state.last_check_at = std.Io.Timestamp.now(self.io, .real).toSeconds();
            try states.append(allocator, state);
        }

        return states.toOwnedSlice(allocator);
    }

    fn getFn(context: *anyopaque, key: registry.ServiceKey) anyerror!driver_mod.RuntimeState {
        const self: *ComposeDriver = @ptrCast(@alignCast(context));
        const spec = registry.get(key);
        const compose_service = spec.compose_service orelse return error.NoComposeService;

        var state = stateFor(spec);
        const output = try self.runComposePs(compose_service);
        defer self.allocator.free(output);

        if (parseContainerFromOutput(self.allocator, output, compose_service)) |status| {
            state.state = status.state;
            state.health = status.health;
        } else {
            state.state = .stopped;
            state.health = .unknown;
        }
        state.last_check_at = std.Io.Timestamp.now(self.io, .real).toSeconds();
        return state;
    }

    fn startFn(context: *anyopaque, key: registry.ServiceKey) anyerror!driver_mod.OperationResult {
        return action(context, key, .start, "start", "COMPOSE_START_FAILED");
    }

    fn stopFn(context: *anyopaque, key: registry.ServiceKey) anyerror!driver_mod.OperationResult {
        return action(context, key, .stop, "stop", "COMPOSE_STOP_FAILED");
    }

    fn restartFn(context: *anyopaque, key: registry.ServiceKey) anyerror!driver_mod.OperationResult {
        return action(context, key, .restart, "restart", "COMPOSE_RESTART_FAILED");
    }

    fn setEnabledFn(context: *anyopaque, key: registry.ServiceKey, enabled: bool) anyerror!driver_mod.OperationResult {
        _ = context;
        const spec = registry.get(key);
        if (!spec.isRestartable()) {
            return .{
                .key = key,
                .action = if (enabled) .enable else .disable,
                .ok = false,
                .error_code = "SERVICE_NOT_RESTARTABLE",
            };
        }
        return .{
            .key = key,
            .action = if (enabled) .enable else .disable,
            .ok = true,
        };
    }

    fn deinitFn(_: *anyopaque) void {}

    pub fn logs(self: *ComposeDriver, key: registry.ServiceKey, tail: u32) anyerror![]u8 {
        const spec = registry.get(key);
        const compose_service = spec.compose_service orelse return error.NoComposeService;

        var tail_buf: [16]u8 = undefined;
        const tail_str = try std.fmt.bufPrint(&tail_buf, "{d}", .{tail});

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.allocator);

        try self.appendBaseArgs(&argv);
        try argv.appendSlice(self.allocator, &.{ "logs", "--no-color", "--tail", tail_str, compose_service });

        const result = try std.process.run(self.allocator, self.io, .{
            .argv = argv.items,
            .timeout = .{ .duration = .{ .raw = .{ .nanoseconds = @as(i96, self.options.timeout_ms) * std.time.ns_per_ms }, .clock = .awake } },
        });
        defer self.allocator.free(result.stderr);

        if (!result.term.success()) {
            self.allocator.free(result.stdout);
            return error.ComposeCommandFailed;
        }

        return result.stdout;
    }

    fn appendBaseArgs(self: *ComposeDriver, argv: *std.ArrayList([]const u8)) !void {
        try argv.append(self.allocator, self.options.docker_path);
        try argv.append(self.allocator, "compose");
        if (self.options.compose_file) |file| {
            try argv.append(self.allocator, "-f");
            try argv.append(self.allocator, file);
        }
        try argv.append(self.allocator, "--project-name");
        try argv.append(self.allocator, self.options.project_name);
    }

    fn runComposePs(self: *ComposeDriver, service_filter: ?[]const u8) ![]u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.allocator);

        try self.appendBaseArgs(&argv);
        try argv.appendSlice(self.allocator, &.{ "ps", "--format", "json" });
        if (service_filter) |svc| {
            try argv.append(self.allocator, svc);
        }

        const result = try std.process.run(self.allocator, self.io, .{
            .argv = argv.items,
            .timeout = .{ .duration = .{ .raw = .{ .nanoseconds = @as(i96, self.options.timeout_ms) * std.time.ns_per_ms }, .clock = .awake } },
        });
        defer self.allocator.free(result.stderr);

        if (!result.term.success()) {
            self.allocator.free(result.stdout);
            return error.ComposeCommandFailed;
        }

        return result.stdout;
    }

    fn stateFor(spec: *const registry.ServiceSpec) driver_mod.RuntimeState {
        return .{
            .key = spec.key,
            .source = .compose,
            .optional = spec.optional,
            .unit = spec.compose_service,
            .endpoint = spec.socket_path,
            .state = .stopped,
            .health = .unknown,
        };
    }
};

fn action(
    context: *anyopaque,
    key: registry.ServiceKey,
    action_kind: registry.Action,
    verb: []const u8,
    error_code: []const u8,
) anyerror!driver_mod.OperationResult {
    const self: *ComposeDriver = @ptrCast(@alignCast(context));
    const spec = registry.get(key);
    if (!spec.actions.allows(action_kind)) {
        return .{
            .key = key,
            .action = action_kind,
            .ok = false,
            .error_code = "SERVICE_NOT_RESTARTABLE",
        };
    }
    const compose_service = spec.compose_service orelse return error.NoComposeService;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(self.allocator);

    try self.appendBaseArgs(&argv);
    try argv.append(self.allocator, verb);
    try argv.append(self.allocator, compose_service);

    const result = try std.process.run(self.allocator, self.io, .{
        .argv = argv.items,
        .timeout = .{ .duration = .{ .raw = .{ .nanoseconds = @as(i96, self.options.timeout_ms) * std.time.ns_per_ms }, .clock = .awake } },
    });
    defer self.allocator.free(result.stdout);
    defer self.allocator.free(result.stderr);

    if (!result.term.success()) {
        return .{ .key = key, .action = action_kind, .ok = false, .error_code = error_code };
    }
    return .{ .key = key, .action = action_kind, .ok = true };
}

pub fn mapComposeState(state_str: []const u8, health_str: []const u8) driver_mod.ServiceState {
    if (std.mem.eql(u8, health_str, "healthy")) return .ready;
    if (std.mem.eql(u8, health_str, "unhealthy")) return .degraded;
    if (std.mem.eql(u8, health_str, "starting")) return .starting;

    if (std.mem.eql(u8, state_str, "running")) {
        return .running;
    }
    if (std.mem.eql(u8, state_str, "restarting") or std.mem.eql(u8, state_str, "created")) {
        return .starting;
    }
    if (std.mem.eql(u8, state_str, "exited") or std.mem.eql(u8, state_str, "paused")) {
        return .stopped;
    }
    if (std.mem.eql(u8, state_str, "dead")) {
        return .failed;
    }
    if (state_str.len == 0) {
        return .stopped;
    }
    return .failed;
}

pub fn healthForState(state: driver_mod.ServiceState) driver_mod.Health {
    return switch (state) {
        .ready => .ok,
        .degraded, .failed => .err,
        .starting, .running, .stopping => .unknown,
        .stopped => .unknown,
    };
}

fn parseContainerFromOutput(allocator: std.mem.Allocator, stdout: []const u8, target_service: []const u8) ?ContainerStatus {
    const trimmed = std.mem.trim(u8, stdout, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "[]")) return null;

    if (trimmed[0] == '[') {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .array) return null;

        for (parsed.value.array.items) |item| {
            if (item != .object) continue;
            const s_val = item.object.get("Service") orelse item.object.get("service") orelse continue;
            if (s_val != .string) continue;
            if (!std.mem.eql(u8, s_val.string, target_service)) continue;

            const state_str = if (item.object.get("State")) |st| if (st == .string) st.string else "" else "";
            const health_str = if (item.object.get("Health")) |h| if (h == .string) h.string else "" else "";
            const st = mapComposeState(state_str, health_str);
            return ContainerStatus{
                .service = s_val.string,
                .state = st,
                .health = healthForState(st),
            };
        }
        return null;
    } else {
        var lines = std.mem.splitScalar(u8, trimmed, '\n');
        while (lines.next()) |line| {
            const line_trimmed = std.mem.trim(u8, line, " \t\r");
            if (line_trimmed.len == 0) continue;
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, line_trimmed, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;

            const s_val = parsed.value.object.get("Service") orelse parsed.value.object.get("service") orelse continue;
            if (s_val != .string) continue;
            if (!std.mem.eql(u8, s_val.string, target_service)) continue;

            const state_str = if (parsed.value.object.get("State")) |st| if (st == .string) st.string else "" else "";
            const health_str = if (parsed.value.object.get("Health")) |h| if (h == .string) h.string else "" else "";
            const st = mapComposeState(state_str, health_str);
            return ContainerStatus{
                .service = s_val.string,
                .state = st,
                .health = healthForState(st),
            };
        }
        return null;
    }
}

test "compose driver maps state and health correctly" {
    try std.testing.expectEqual(driver_mod.ServiceState.ready, mapComposeState("running", "healthy"));
    try std.testing.expectEqual(driver_mod.Health.ok, healthForState(.ready));

    try std.testing.expectEqual(driver_mod.ServiceState.degraded, mapComposeState("running", "unhealthy"));
    try std.testing.expectEqual(driver_mod.Health.err, healthForState(.degraded));

    try std.testing.expectEqual(driver_mod.ServiceState.running, mapComposeState("running", ""));
    try std.testing.expectEqual(driver_mod.ServiceState.starting, mapComposeState("created", ""));
    try std.testing.expectEqual(driver_mod.ServiceState.stopped, mapComposeState("exited", ""));
    try std.testing.expectEqual(driver_mod.ServiceState.failed, mapComposeState("dead", ""));
}

test "compose driver parses json array and lines" {
    const allocator = std.testing.allocator;

    const array_json =
        \\[
        \\  {"Service": "auth", "State": "running", "Health": "healthy"},
        \\  {"Service": "gateway", "State": "running", "Health": ""}
        \\]
    ;

    const auth_status = parseContainerFromOutput(allocator, array_json, "auth");
    try std.testing.expect(auth_status != null);
    try std.testing.expectEqual(driver_mod.ServiceState.ready, auth_status.?.state);
    try std.testing.expectEqual(driver_mod.Health.ok, auth_status.?.health);

    const gateway_status = parseContainerFromOutput(allocator, array_json, "gateway");
    try std.testing.expect(gateway_status != null);
    try std.testing.expectEqual(driver_mod.ServiceState.running, gateway_status.?.state);

    const missing_status = parseContainerFromOutput(allocator, array_json, "unknown");
    try std.testing.expect(missing_status == null);

    const lines_json =
        \\{"Service": "storage", "State": "running", "Health": "healthy"}
        \\{"Service": "pg-meta", "State": "exited", "Health": ""}
    ;

    const storage_status = parseContainerFromOutput(allocator, lines_json, "storage");
    try std.testing.expect(storage_status != null);
    try std.testing.expectEqual(driver_mod.ServiceState.ready, storage_status.?.state);

    const pg_meta_status = parseContainerFromOutput(allocator, lines_json, "pg-meta");
    try std.testing.expect(pg_meta_status != null);
    try std.testing.expectEqual(driver_mod.ServiceState.stopped, pg_meta_status.?.state);
}

test "compose driver runs fake docker script for status, restart, and blocked infra" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const script_path = try std.fmt.allocPrint(allocator, "/tmp/doctbase-fake-docker-{d}", .{std.mem.readInt(u64, &random_bytes, .little)});
    defer allocator.free(script_path);

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = script_path,
        .data =
        \\#!/bin/sh
        \\# args: compose ... ps --format json [service]
        \\# args: compose ... restart <service>
        \\shift # skip "compose"
        \\while [ $# -gt 0 ]; do
        \\  case "$1" in
        \\    ps)
        \\      printf '[{"Service":"auth","State":"running","Health":"healthy"},{"Service":"gateway","State":"running","Health":""}]\n'
        \\      exit 0
        \\      ;;
        \\    start|stop|restart)
        \\      exit 0
        \\      ;;
        \\    logs)
        \\      printf 'fake log line 1\nfake log line 2\n'
        \\      exit 0
        \\      ;;
        \\  esac
        \\  shift
        \\done
        \\exit 0
        ,
        .flags = .{ .permissions = @fromBackingInt(@intCast(0o755)) },
    });
    defer std.Io.Dir.cwd().deleteFile(io, script_path) catch {};

    var compose = ComposeDriver.init(allocator, io, .{ .docker_path = script_path });
    const lifecycle = compose.driver();

    const auth_state = try lifecycle.get(.auth);
    try std.testing.expectEqual(driver_mod.ServiceState.ready, auth_state.state);
    try std.testing.expectEqual(driver_mod.Health.ok, auth_state.health);

    const restarted = try lifecycle.restart(.auth);
    try std.testing.expect(restarted.ok);

    const blocked = try lifecycle.restart(.postgresql);
    try std.testing.expect(!blocked.ok);
    try std.testing.expectEqualStrings("SERVICE_NOT_RESTARTABLE", blocked.error_code.?);

    const log_output = try compose.logs(.auth, 10);
    defer allocator.free(log_output);
    try std.testing.expect(std.mem.indexOf(u8, log_output, "fake log line") != null);
}
