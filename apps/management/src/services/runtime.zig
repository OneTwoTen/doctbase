const std = @import("std");
const lifecycle = @import("service_lifecycle");
const registry = lifecycle.registry;
const driver_mod = lifecycle.driver;

pub const AggregatorOptions = struct {
    cache_ttl_ms: i64 = 2000,
    allow_infra_restart: bool = false,
};

pub const ServiceRuntimeAggregator = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    driver: driver_mod.LifecycleDriver,
    options: AggregatorOptions,
    cached_states: ?[]driver_mod.RuntimeState = null,
    cache_timestamp: i64 = 0,
    operation_locks: [registry.all.len]std.atomic.Value(bool) = [_]std.atomic.Value(bool){.init(false)} ** registry.all.len,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, driver: driver_mod.LifecycleDriver, options: AggregatorOptions) ServiceRuntimeAggregator {
        return .{
            .allocator = allocator,
            .io = io,
            .driver = driver,
            .options = options,
        };
    }

    pub fn deinit(self: *ServiceRuntimeAggregator) void {
        if (self.cached_states) |states| {
            self.allocator.free(states);
            self.cached_states = null;
        }
    }

    pub fn list(self: *ServiceRuntimeAggregator, allocator: std.mem.Allocator, refresh: bool) ![]driver_mod.RuntimeState {
        const now = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        if (!refresh and self.cached_states != null and (now - self.cache_timestamp) < self.options.cache_ttl_ms) {
            const cached = self.cached_states.?;
            const copy = try allocator.alloc(driver_mod.RuntimeState, cached.len);
            @memcpy(copy, cached);
            return copy;
        }

        const raw_states = try self.driver.list(self.allocator);
        defer self.allocator.free(raw_states);

        var fresh_states = try self.allocator.alloc(driver_mod.RuntimeState, raw_states.len);
        for (raw_states, 0..) |raw, i| {
            var state = raw;
            if (state.endpoint) |endpoint| {
                if (lifecycle.health_probe.probe(self.io, endpoint, 500, "/readyz")) |probe| {
                    if (probe.ready) {
                        state.state = .ready;
                        state.health = .ok;
                    }
                } else |_| {
                    if (state.state == .running) {
                        state.state = .degraded;
                        state.health = .err;
                    }
                }
            }
            state.last_check_at = std.Io.Timestamp.now(self.io, .real).toSeconds();
            fresh_states[i] = state;
        }

        if (self.cached_states) |old| self.allocator.free(old);
        self.cached_states = fresh_states;
        self.cache_timestamp = now;

        const result = try allocator.alloc(driver_mod.RuntimeState, fresh_states.len);
        @memcpy(result, fresh_states);
        return result;
    }

    pub fn get(self: *ServiceRuntimeAggregator, key: registry.ServiceKey) !driver_mod.RuntimeState {
        var state = try self.driver.get(key);
        if (state.endpoint) |endpoint| {
            if (lifecycle.health_probe.probe(self.io, endpoint, 500, "/readyz")) |probe| {
                if (probe.ready) {
                    state.state = .ready;
                    state.health = .ok;
                }
            } else |_| {
                if (state.state == .running) {
                    state.state = .degraded;
                    state.health = .err;
                }
            }
        }
        state.last_check_at = std.Io.Timestamp.now(self.io, .real).toSeconds();
        return state;
    }

    pub fn restart(self: *ServiceRuntimeAggregator, key: registry.ServiceKey) !driver_mod.OperationResult {
        const spec = registry.get(key);
        if (spec.kind == .infra and !self.options.allow_infra_restart) {
            return .{
                .key = key,
                .action = .restart,
                .ok = false,
                .error_code = "SERVICE_NOT_RESTARTABLE",
                .message = "infrastructure services cannot be restarted via management API by default",
            };
        }

        const idx = indexOfKey(key) orelse return error.UnknownService;
        // Try acquire operation lock
        if (self.operation_locks[idx].swap(true, .acquire)) {
            return .{
                .key = key,
                .action = .restart,
                .ok = false,
                .error_code = "SERVICE_OPERATION_IN_PROGRESS",
                .message = "another operation is currently in progress for this service",
            };
        }
        defer self.operation_locks[idx].store(false, .release);

        const result = try self.driver.restart(key);

        // Invalidate cache so next list call queries updated states
        if (self.cached_states) |old| {
            self.allocator.free(old);
            self.cached_states = null;
        }
        self.cache_timestamp = 0;

        return result;
    }
};

fn indexOfKey(key: registry.ServiceKey) ?usize {
    for (registry.all, 0..) |spec, index| {
        if (spec.key == key) return index;
    }
    return null;
}

test "aggregator caches state and invalidates on refresh" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var fake = lifecycle.fake.FakeDriver.init();
    var agg = ServiceRuntimeAggregator.init(allocator, io, fake.driver(), .{ .cache_ttl_ms = 5000 });
    defer agg.deinit();

    const list1 = try agg.list(allocator, false);
    defer allocator.free(list1);
    try std.testing.expectEqual(registry.all.len, list1.len);
    try std.testing.expect(agg.cached_states != null);

    // List again should hit cache
    const list2 = try agg.list(allocator, false);
    defer allocator.free(list2);
    try std.testing.expectEqual(list1[0].state, list2[0].state);

    // Restart auth
    const restart_res = try agg.restart(.auth);
    try std.testing.expect(restart_res.ok);
    // Cache was invalidated
    try std.testing.expect(agg.cached_states == null);

    // Restart infra service without allow flag is blocked
    const infra_res = try agg.restart(.postgresql);
    try std.testing.expect(!infra_res.ok);
    try std.testing.expectEqualStrings("SERVICE_NOT_RESTARTABLE", infra_res.error_code.?);
}

test "aggregator blocks concurrent operation with SERVICE_OPERATION_IN_PROGRESS" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var fake = lifecycle.fake.FakeDriver.init();
    var agg = ServiceRuntimeAggregator.init(allocator, io, fake.driver(), .{});
    defer agg.deinit();

    const idx = indexOfKey(.auth).?;
    agg.operation_locks[idx].store(true, .release);

    const res = try agg.restart(.auth);
    try std.testing.expect(!res.ok);
    try std.testing.expectEqualStrings("SERVICE_OPERATION_IN_PROGRESS", res.error_code.?);
}
