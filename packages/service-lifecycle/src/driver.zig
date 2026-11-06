const std = @import("std");
const registry = @import("registry.zig");

pub const Source = enum {
    systemd,
    compose,
    dev,
    fake,
};

pub const ServiceState = enum {
    starting,
    running,
    ready,
    degraded,
    stopping,
    stopped,
    failed,
};

pub const Health = enum {
    ok,
    warn,
    err,
    unknown,
};

pub const RuntimeState = struct {
    key: registry.ServiceKey,
    state: ServiceState = .stopped,
    health: Health = .unknown,
    source: Source,
    unit: ?[]const u8 = null,
    endpoint: ?[]const u8 = null,
    version: ?[]const u8 = null,
    config_hash: ?[]const u8 = null,
    last_error: ?[]const u8 = null,
    operation_id: ?[]const u8 = null,
    started_at: ?i64 = null,
    last_check_at: i64 = 0,
    optional: bool = false,
};

pub const OperationResult = struct {
    key: registry.ServiceKey,
    action: registry.Action,
    ok: bool,
    error_code: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

pub const LifecycleDriver = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        list: *const fn (context: *anyopaque, allocator: std.mem.Allocator) anyerror![]RuntimeState,
        get: *const fn (context: *anyopaque, key: registry.ServiceKey) anyerror!RuntimeState,
        start: *const fn (context: *anyopaque, key: registry.ServiceKey) anyerror!OperationResult,
        stop: *const fn (context: *anyopaque, key: registry.ServiceKey) anyerror!OperationResult,
        restart: *const fn (context: *anyopaque, key: registry.ServiceKey) anyerror!OperationResult,
        setEnabled: *const fn (context: *anyopaque, key: registry.ServiceKey, enabled: bool) anyerror!OperationResult,
        deinit: *const fn (context: *anyopaque) void,
    };

    pub fn list(self: LifecycleDriver, allocator: std.mem.Allocator) anyerror![]RuntimeState {
        return self.vtable.list(self.context, allocator);
    }

    pub fn get(self: LifecycleDriver, key: registry.ServiceKey) anyerror!RuntimeState {
        return self.vtable.get(self.context, key);
    }

    pub fn start(self: LifecycleDriver, key: registry.ServiceKey) anyerror!OperationResult {
        return self.vtable.start(self.context, key);
    }

    pub fn stop(self: LifecycleDriver, key: registry.ServiceKey) anyerror!OperationResult {
        return self.vtable.stop(self.context, key);
    }

    pub fn restart(self: LifecycleDriver, key: registry.ServiceKey) anyerror!OperationResult {
        return self.vtable.restart(self.context, key);
    }

    pub fn setEnabled(self: LifecycleDriver, key: registry.ServiceKey, enabled: bool) anyerror!OperationResult {
        return self.vtable.setEnabled(self.context, key, enabled);
    }

    pub fn deinit(self: LifecycleDriver) void {
        self.vtable.deinit(self.context);
    }
};

pub fn stateFromProcess(active: bool, ready: bool) ServiceState {
    if (!active) return .stopped;
    if (ready) return .ready;
    return .running;
}
