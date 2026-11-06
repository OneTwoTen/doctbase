const std = @import("std");
const registry = @import("registry.zig");
const driver_mod = @import("driver.zig");
const health_probe = @import("health_probe.zig");

pub const Options = struct {
    bin_dir: []const u8,
    run_dir: []const u8,
    config_path: ?[]const u8 = null,
    internal_token: ?[]const u8 = null,
    base_env: ?*const std.process.Environ.Map = null,
    inherit_stdio: bool = true,
};

const Process = struct {
    spec: *const registry.ServiceSpec,
    child: ?std.process.Child = null,
    state: driver_mod.RuntimeState,
    endpoint: ?[]u8 = null,
};

pub const DevDriver = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    processes: [registry.all.len]Process,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !DevDriver {
        var self: DevDriver = undefined;
        self.allocator = allocator;
        self.io = io;
        self.options = options;

        for (registry.specs(), 0..) |*spec, index| {
            const endpoint = if (spec.socket_name) |socket_name|
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ options.run_dir, socket_name })
            else
                null;
            self.processes[index] = .{
                .spec = spec,
                .endpoint = endpoint,
                .state = .{
                    .key = spec.key,
                    .source = .dev,
                    .optional = spec.optional,
                    .endpoint = endpoint,
                    .state = .stopped,
                    .health = .unknown,
                },
            };
        }

        return self;
    }

    pub fn deinit(self: *DevDriver) void {
        for (&self.processes) |*process| {
            if (process.child) |*child| {
                child.kill(self.io);
                process.child = null;
            }
            if (process.endpoint) |endpoint| self.allocator.free(endpoint);
        }
        self.processes = undefined;
    }

    pub fn driver(self: *DevDriver) driver_mod.LifecycleDriver {
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
        const self: *DevDriver = @ptrCast(@alignCast(context));
        const out = try allocator.alloc(driver_mod.RuntimeState, self.processes.len);
        for (self.processes, 0..) |process, index| out[index] = process.state;
        return out;
    }

    fn getFn(context: *anyopaque, key: registry.ServiceKey) anyerror!driver_mod.RuntimeState {
        const self: *DevDriver = @ptrCast(@alignCast(context));
        return self.processes[indexOf(key) orelse return error.UnknownService].state;
    }

    fn startFn(context: *anyopaque, key: registry.ServiceKey) anyerror!driver_mod.OperationResult {
        const self: *DevDriver = @ptrCast(@alignCast(context));
        const index = indexOf(key) orelse return error.UnknownService;
        const process = &self.processes[index];

        if (process.spec.kind != .app) {
            return .{ .key = key, .action = .start, .ok = false, .error_code = "SERVICE_NOT_STARTABLE" };
        }
        if (process.child != null) {
            return .{ .key = key, .action = .start, .ok = true, .message = "already running" };
        }

        const binary_name = process.spec.binary_name orelse {
            return .{ .key = key, .action = .start, .ok = false, .error_code = "SERVICE_BINARY_MISSING" };
        };
        const binary_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.options.bin_dir, binary_name });
        defer self.allocator.free(binary_path);

        var env = std.process.Environ.Map.init(self.allocator);
        defer env.deinit();
        if (self.options.base_env) |base| try env.putAll(base);
        try env.put("DOCTBASE_RUN_DIR", self.options.run_dir);
        if (self.options.config_path) |path| try env.put("DOCTBASE_CONFIG", path);
        if (self.options.internal_token) |token| try env.put("DOCTBASE_INTERNAL_TOKEN", token);

        process.child = std.process.spawn(self.io, .{
            .argv = &.{binary_path},
            .environ_map = &env,
            .stdin = .ignore,
            .stdout = if (self.options.inherit_stdio) .inherit else .ignore,
            .stderr = if (self.options.inherit_stdio) .inherit else .ignore,
        }) catch |err| {
            process.state.state = .failed;
            process.state.health = .err;
            process.state.last_error = @errorName(err);
            return .{ .key = key, .action = .start, .ok = false, .error_code = "SERVICE_SPAWN_FAILED", .message = @errorName(err) };
        };

        const now = std.Io.Timestamp.now(self.io, .real).toSeconds();
        process.state.state = .running;
        process.state.health = .unknown;
        process.state.started_at = now;
        process.state.last_check_at = now;

        if (process.endpoint) |endpoint| {
            var attempt: usize = 0;
            while (attempt < 20) : (attempt += 1) {
                const result = health_probe.probe(self.io, endpoint, 250, process.spec.health_path) catch {
                    std.Io.sleep(self.io, .{ .nanoseconds = 50 * std.time.ns_per_ms }, .awake) catch {};
                    continue;
                };
                if (result.ready) {
                    process.state.state = .ready;
                    process.state.health = .ok;
                    break;
                }
            }
        }

        return .{ .key = key, .action = .start, .ok = true };
    }

    fn stopFn(context: *anyopaque, key: registry.ServiceKey) anyerror!driver_mod.OperationResult {
        const self: *DevDriver = @ptrCast(@alignCast(context));
        const index = indexOf(key) orelse return error.UnknownService;
        const process = &self.processes[index];

        if (process.child) |*child| {
            if (child.id) |pid| std.posix.kill(pid, std.posix.SIG.TERM) catch {};
            _ = child.wait(self.io) catch {};
            process.child = null;
        }

        process.state.state = .stopped;
        process.state.health = .unknown;
        return .{ .key = key, .action = .stop, .ok = true };
    }

    fn restartFn(context: *anyopaque, key: registry.ServiceKey) anyerror!driver_mod.OperationResult {
        _ = try stopFn(context, key);
        const result = try startFn(context, key);
        return .{ .key = key, .action = .restart, .ok = result.ok, .error_code = result.error_code, .message = result.message };
    }

    fn setEnabledFn(context: *anyopaque, key: registry.ServiceKey, enabled: bool) anyerror!driver_mod.OperationResult {
        if (!enabled) {
            const stopped = try stopFn(context, key);
            return .{ .key = key, .action = .disable, .ok = stopped.ok };
        }
        return .{ .key = key, .action = .enable, .ok = true, .message = "start the service explicitly" };
    }

    fn deinitFn(context: *anyopaque) void {
        const self: *DevDriver = @ptrCast(@alignCast(context));
        for (&self.processes) |*process| {
            if (process.child) |*child| {
                child.kill(self.io);
                process.child = null;
            }
        }
    }
};

fn indexOf(key: registry.ServiceKey) ?usize {
    for (registry.all, 0..) |spec, index| {
        if (spec.key == key) return index;
    }
    return null;
}
