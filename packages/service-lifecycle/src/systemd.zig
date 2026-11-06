const std = @import("std");
const registry = @import("registry.zig");
const driver_mod = @import("driver.zig");

pub const Options = struct {
    systemctl_path: []const u8 = "systemctl",
    timeout_ms: u32 = 5000,
};

const ActiveState = enum {
    active,
    activating,
    deactivating,
    inactive,
    failed,
    unknown,
};

const SubState = enum {
    running,
    exited,
    dead,
    failed,
    start,
    stop,
    auto_restart,
    unknown,
};

const UnitFileState = enum {
    enabled,
    disabled,
    static,
    masked,
    generated,
    transient,
    unknown,
};

const UnitStatus = struct {
    active: ActiveState = .unknown,
    sub: SubState = .unknown,
    unit_file: UnitFileState = .unknown,
    main_pid: ?u32 = null,
};

pub const SystemdDriver = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) SystemdDriver {
        return .{ .allocator = allocator, .io = io, .options = options };
    }

    pub fn driver(self: *SystemdDriver) driver_mod.LifecycleDriver {
        return .{ .context = self, .vtable = &vtable };
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
        const self: *SystemdDriver = @ptrCast(@alignCast(context));
        var states: std.ArrayList(driver_mod.RuntimeState) = .empty;
        errdefer states.deinit(allocator);

        for (registry.specs()) |*spec| {
            if (spec.unit_name == null) continue;
            var state = stateFor(spec);
            if (self.queryStatus(spec)) |status| {
                state.state = mapState(status);
                state.health = healthForState(state.state);
            } else |err| {
                state.state = .failed;
                state.health = .err;
                state.last_error = @errorName(err);
            }
            try states.append(allocator, state);
        }

        return states.toOwnedSlice(allocator);
    }

    fn getFn(context: *anyopaque, key: registry.ServiceKey) anyerror!driver_mod.RuntimeState {
        const self: *SystemdDriver = @ptrCast(@alignCast(context));
        const spec = registry.get(key);
        var state = stateFor(spec);
        const status = try self.queryStatus(spec);
        state.state = mapState(status);
        state.health = healthForState(state.state);
        state.last_check_at = std.Io.Timestamp.now(self.io, .real).toSeconds();
        return state;
    }

    fn startFn(context: *anyopaque, key: registry.ServiceKey) anyerror!driver_mod.OperationResult {
        return action(context, key, .start, "start", "SERVICE_START_FAILED");
    }

    fn stopFn(context: *anyopaque, key: registry.ServiceKey) anyerror!driver_mod.OperationResult {
        return action(context, key, .stop, "stop", "SERVICE_STOP_FAILED");
    }

    fn restartFn(context: *anyopaque, key: registry.ServiceKey) anyerror!driver_mod.OperationResult {
        return action(context, key, .restart, "restart", "SERVICE_RESTART_FAILED");
    }

    fn setEnabledFn(context: *anyopaque, key: registry.ServiceKey, enabled: bool) anyerror!driver_mod.OperationResult {
        return action(
            context,
            key,
            if (enabled) .enable else .disable,
            if (enabled) "enable" else "disable",
            "SERVICE_ENABLE_FAILED",
        );
    }

    fn deinitFn(_: *anyopaque) void {}

    fn stateFor(spec: *const registry.ServiceSpec) driver_mod.RuntimeState {
        return .{
            .key = spec.key,
            .source = .systemd,
            .optional = spec.optional,
            .unit = spec.unit_name,
            .endpoint = spec.socket_path,
            .state = .stopped,
            .health = .unknown,
        };
    }

    fn queryStatus(self: *SystemdDriver, spec: *const registry.ServiceSpec) anyerror!UnitStatus {
        const unit = spec.unit_name orelse return error.NoUnit;
        const result = try std.process.run(self.allocator, self.io, .{
            .argv = &.{
                self.options.systemctl_path,
                "show",
                "--no-pager",
                "-p",
                "ActiveState",
                "-p",
                "SubState",
                "-p",
                "Result",
                "-p",
                "UnitFileState",
                "-p",
                "MainPID",
                unit,
            },
            .timeout = .{ .duration = .{ .raw = .{ .nanoseconds = @as(i96, self.options.timeout_ms) * std.time.ns_per_ms }, .clock = .awake } },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (!result.term.success()) return error.SystemdCommandFailed;

        var status = UnitStatus{};
        var lines = std.mem.splitScalar(u8, result.stdout, '\n');
        while (lines.next()) |line| {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = line[0..eq];
            const value = std.mem.trim(u8, line[eq + 1 ..], " \t\r");
            if (std.mem.eql(u8, key, "ActiveState")) {
                status.active = std.meta.stringToEnum(ActiveState, value) orelse .unknown;
            } else if (std.mem.eql(u8, key, "SubState")) {
                status.sub = parseSubState(value);
            } else if (std.mem.eql(u8, key, "UnitFileState")) {
                status.unit_file = std.meta.stringToEnum(UnitFileState, value) orelse .unknown;
            } else if (std.mem.eql(u8, key, "MainPID")) {
                status.main_pid = std.fmt.parseInt(u32, value, 10) catch null;
            }
        }
        return status;
    }
};

fn action(
    context: *anyopaque,
    key: registry.ServiceKey,
    action_kind: registry.Action,
    verb: []const u8,
    error_code: []const u8,
) anyerror!driver_mod.OperationResult {
    const self: *SystemdDriver = @ptrCast(@alignCast(context));
    const spec = registry.get(key);
    if (!spec.actions.allows(action_kind)) {
        return .{ .key = key, .action = action_kind, .ok = false, .error_code = "SERVICE_NOT_RESTARTABLE" };
    }
    const unit = spec.unit_name orelse return error.NoUnit;
    const result = try std.process.run(self.allocator, self.io, .{
        .argv = &.{ self.options.systemctl_path, verb, unit },
        .timeout = .{ .duration = .{ .raw = .{ .nanoseconds = @as(i96, self.options.timeout_ms) * std.time.ns_per_ms }, .clock = .awake } },
    });
    defer self.allocator.free(result.stdout);
    defer self.allocator.free(result.stderr);

    if (!result.term.success()) {
        return .{ .key = key, .action = action_kind, .ok = false, .error_code = error_code };
    }
    return .{ .key = key, .action = action_kind, .ok = true };
}

fn parseSubState(value: []const u8) SubState {
    if (std.mem.eql(u8, value, "running")) return .running;
    if (std.mem.eql(u8, value, "exited")) return .exited;
    if (std.mem.eql(u8, value, "dead")) return .dead;
    if (std.mem.eql(u8, value, "failed")) return .failed;
    if (std.mem.eql(u8, value, "start")) return .start;
    if (std.mem.eql(u8, value, "stop")) return .stop;
    if (std.mem.eql(u8, value, "auto-restart")) return .auto_restart;
    return .unknown;
}

fn mapState(status: UnitStatus) driver_mod.ServiceState {
    return switch (status.active) {
        .active => switch (status.sub) {
            .running => .running,
            .exited => .ready,
            else => .running,
        },
        .activating => .starting,
        .deactivating => .stopping,
        .inactive => .stopped,
        .failed => .failed,
        .unknown => .failed,
    };
}

fn healthForState(state: driver_mod.ServiceState) driver_mod.Health {
    return switch (state) {
        .ready => .ok,
        .degraded, .failed => .err,
        .starting, .running, .stopping => .unknown,
        .stopped => .unknown,
    };
}

test "systemd driver parses show output and maps state" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const script_path = try std.fmt.allocPrint(allocator, "/tmp/doctbase-fake-systemctl-{d}", .{std.mem.readInt(u64, &random_bytes, .little)});
    defer allocator.free(script_path);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = script_path,
        .data =
        \\#!/bin/sh
        \\case "$1" in
        \\  show)
        \\    printf 'ActiveState=active\nSubState=running\nResult=success\nUnitFileState=enabled\nMainPID=4242\n'
        \\    exit 0
        \\    ;;
        \\  start|stop|restart|enable|disable)
        \\    exit 0
        \\    ;;
        \\  *)
        \\    exit 1
        \\    ;;
        \\esac
        ,
        .flags = .{ .permissions = @fromBackingInt(@intCast(0o755)) },
    });
    defer std.Io.Dir.cwd().deleteFile(io, script_path) catch {};

    var systemd = SystemdDriver.init(allocator, io, .{ .systemctl_path = script_path });
    const lifecycle = systemd.driver();

    const state = try lifecycle.get(.auth);
    try std.testing.expectEqual(driver_mod.ServiceState.running, state.state);
    try std.testing.expectEqualStrings("doctbase-auth.service", state.unit.?);

    const restarted = try lifecycle.restart(.auth);
    try std.testing.expect(restarted.ok);

    const stopped = try lifecycle.stop(.postgresql);
    try std.testing.expect(!stopped.ok);
    try std.testing.expectEqualStrings("SERVICE_NOT_RESTARTABLE", stopped.error_code.?);
}
