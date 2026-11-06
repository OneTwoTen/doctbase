const std = @import("std");
const registry = @import("registry.zig");
const driver_mod = @import("driver.zig");

pub const FakeDriver = struct {
    states: [registry.all.len]driver_mod.RuntimeState,
    fail_key: ?registry.ServiceKey = null,

    pub fn init() FakeDriver {
        var self: FakeDriver = undefined;
        for (registry.all, 0..) |spec, index| {
            self.states[index] = .{
                .key = spec.key,
                .source = .fake,
                .optional = spec.optional,
                .state = .stopped,
                .health = .unknown,
            };
        }
        return self;
    }

    pub fn driver(self: *FakeDriver) driver_mod.LifecycleDriver {
        return .{
            .context = self,
            .vtable = &vtable,
        };
    }

    pub fn stateOf(self: *FakeDriver, key: registry.ServiceKey) driver_mod.RuntimeState {
        return self.states[indexOf(key).?];
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
        const self: *FakeDriver = @ptrCast(@alignCast(context));
        const out = try allocator.alloc(driver_mod.RuntimeState, self.states.len);
        for (self.states, 0..) |state, index| out[index] = state;
        return out;
    }

    fn getFn(context: *anyopaque, key: registry.ServiceKey) anyerror!driver_mod.RuntimeState {
        const self: *FakeDriver = @ptrCast(@alignCast(context));
        return self.states[indexOf(key) orelse return error.UnknownService];
    }

    fn startFn(context: *anyopaque, key: registry.ServiceKey) anyerror!driver_mod.OperationResult {
        const self: *FakeDriver = @ptrCast(@alignCast(context));
        const index = indexOf(key) orelse return error.UnknownService;
        if (self.fail_key == key) {
            self.states[index].state = .failed;
            self.states[index].health = .err;
            return .{
                .key = key,
                .action = .start,
                .ok = false,
                .error_code = "SERVICE_START_FAILED",
                .message = "fake failure",
            };
        }
        self.states[index].state = .ready;
        self.states[index].health = .ok;
        return .{ .key = key, .action = .start, .ok = true };
    }

    fn stopFn(context: *anyopaque, key: registry.ServiceKey) anyerror!driver_mod.OperationResult {
        const self: *FakeDriver = @ptrCast(@alignCast(context));
        const index = indexOf(key) orelse return error.UnknownService;
        self.states[index].state = .stopped;
        self.states[index].health = .unknown;
        return .{ .key = key, .action = .stop, .ok = true };
    }

    fn restartFn(context: *anyopaque, key: registry.ServiceKey) anyerror!driver_mod.OperationResult {
        const self: *FakeDriver = @ptrCast(@alignCast(context));
        const index = indexOf(key) orelse return error.UnknownService;
        self.states[index].state = .starting;
        self.states[index].state = .ready;
        self.states[index].health = .ok;
        return .{ .key = key, .action = .restart, .ok = true };
    }

    fn setEnabledFn(context: *anyopaque, key: registry.ServiceKey, enabled: bool) anyerror!driver_mod.OperationResult {
        const self: *FakeDriver = @ptrCast(@alignCast(context));
        const index = indexOf(key) orelse return error.UnknownService;
        self.states[index].state = .stopped;
        self.states[index].health = .unknown;
        return .{ .key = key, .action = if (enabled) .enable else .disable, .ok = true };
    }

    fn deinitFn(_: *anyopaque) void {}
};

fn indexOf(key: registry.ServiceKey) ?usize {
    for (registry.all, 0..) |spec, index| {
        if (spec.key == key) return index;
    }
    return null;
}

test "fake driver transitions through start, stop and restart" {
    var fake = FakeDriver.init();
    const lifecycle = fake.driver();

    try std.testing.expectEqual(driver_mod.ServiceState.stopped, (try lifecycle.get(.auth)).state);

    const started = try lifecycle.start(.auth);
    try std.testing.expect(started.ok);
    try std.testing.expectEqual(driver_mod.ServiceState.ready, (try lifecycle.get(.auth)).state);

    const restarted = try lifecycle.restart(.auth);
    try std.testing.expect(restarted.ok);
    try std.testing.expectEqual(driver_mod.ServiceState.ready, (try lifecycle.get(.auth)).state);

    const stopped = try lifecycle.stop(.auth);
    try std.testing.expect(stopped.ok);
    try std.testing.expectEqual(driver_mod.ServiceState.stopped, (try lifecycle.get(.auth)).state);
}

test "fake driver lists all services and can simulate failure" {
    var fake = FakeDriver.init();
    fake.fail_key = .storage;
    const lifecycle = fake.driver();

    const states = try lifecycle.list(std.testing.allocator);
    defer std.testing.allocator.free(states);
    try std.testing.expectEqual(registry.all.len, states.len);

    const failed = try lifecycle.start(.storage);
    try std.testing.expect(!failed.ok);
    try std.testing.expectEqualStrings("SERVICE_START_FAILED", failed.error_code.?);
    try std.testing.expectEqual(driver_mod.ServiceState.failed, (try lifecycle.get(.storage)).state);
}
