const std = @import("std");

pub const Service = struct {
    name: []const u8,
    version: []const u8 = "0.1.0",
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        start: *const fn (ctx: *anyopaque) anyerror!void,
        stop: *const fn (ctx: *anyopaque) void,
        checkHealth: *const fn (ctx: *anyopaque) bool,
    };

    pub fn start(self: Service) !void {
        try self.vtable.start(self.ptr);
    }

    pub fn stop(self: Service) void {
        self.vtable.stop(self.ptr);
    }

    pub fn checkHealth(self: Service) bool {
        return self.vtable.checkHealth(self.ptr);
    }
};

test "service interface dispatch" {
    const Mock = struct {
        started: bool = false,

        fn doStart(ctx: *anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.started = true;
        }

        fn doStop(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.started = false;
        }

        fn doHealth(ctx: *anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.started;
        }
    };

    var mock = Mock{};
    const vtable = Service.VTable{
        .start = Mock.doStart,
        .stop = Mock.doStop,
        .checkHealth = Mock.doHealth,
    };

    const svc = Service{
        .name = "mock",
        .ptr = &mock,
        .vtable = &vtable,
    };

    try svc.start();
    try std.testing.expect(svc.checkHealth());
    svc.stop();
    try std.testing.expect(!svc.checkHealth());
}
