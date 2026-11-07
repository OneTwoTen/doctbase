const std = @import("std");
const install = @import("install_orchestrator");
const state = @import("install_state");
const preflight = @import("preflight");

const Fake = struct {
    allocator: std.mem.Allocator,
    running_as_root: bool = true,
    blocked: bool = false,
    fail_step: ?state.Step = null,
    health_ready: bool = true,
    calls: [state.step_count]usize = @splat(0),
    receipts_added: usize = 0,
    receipt_exists: [state.step_count]bool = @splat(false),
    rollbacks: [state.step_count][32]u8 = undefined,
    rollback_lengths: [state.step_count]usize = @splat(0),
    rollback_count: usize = 0,
    journal: ?*install.Journal = null,

    fn executor(self: *Fake) install.Executor {
        return .{
            .context = self,
            .running_as_root = self.running_as_root,
            .preflight = preflightFn,
            .packages = packagesFn,
            .users = usersFn,
            .secrets = secretsFn,
            .postgresql = postgresqlFn,
            .pgbouncer = pgbouncerFn,
            .caddy = caddyFn,
            .config = configFn,
            .binaries = binariesFn,
            .units = unitsFn,
            .services = servicesFn,
            .health = healthFn,
            .components = componentsFn,
            .rollback = rollbackFn,
        };
    }

    fn preflightFn(context: ?*anyopaque, options: *const install.Options) anyerror!preflight.Report {
        _ = options;
        const self: *Fake = @ptrCast(@alignCast(context.?));
        self.calls[@backingInt(state.Step.preflight)] += 1;
        var report: preflight.Report = .{};
        if (self.blocked) {
            report.findings[0] = .{ .code = .unsupported_os, .severity = .blocker };
            report.count = 1;
        }
        return report;
    }

    fn step(self: *Fake, which: state.Step) !void {
        const index = @backingInt(which);
        self.calls[index] += 1;
        if (self.fail_step != null and self.fail_step.? == which) return error.SimulatedFailure;
        if (which == .health) return;
        if (!self.receipt_exists[index]) {
            self.receipt_exists[index] = true;
            self.receipts_added += 1;
            const label = try std.fmt.allocPrint(self.allocator, "{s}", .{@tagName(which)});
            try self.journal.?.add(.{ .file = label });
        }
    }

    fn packagesFn(context: ?*anyopaque, options: *const install.Options, journal: *install.Journal) anyerror!void {
        _ = options;
        const self: *Fake = @ptrCast(@alignCast(context.?));
        self.journal = journal;
        try self.step(.packages);
    }

    fn usersFn(context: ?*anyopaque, options: *const install.Options, journal: *install.Journal) anyerror!void {
        _ = options;
        const self: *Fake = @ptrCast(@alignCast(context.?));
        self.journal = journal;
        try self.step(.users);
    }

    fn secretsFn(context: ?*anyopaque, options: *const install.Options, journal: *install.Journal) anyerror!void {
        _ = options;
        const self: *Fake = @ptrCast(@alignCast(context.?));
        self.journal = journal;
        try self.step(.secrets);
    }

    fn postgresqlFn(context: ?*anyopaque, options: *const install.Options, journal: *install.Journal) anyerror!void {
        _ = options;
        const self: *Fake = @ptrCast(@alignCast(context.?));
        self.journal = journal;
        try self.step(.postgresql);
    }

    fn pgbouncerFn(context: ?*anyopaque, options: *const install.Options, journal: *install.Journal) anyerror!void {
        _ = options;
        const self: *Fake = @ptrCast(@alignCast(context.?));
        self.journal = journal;
        try self.step(.pgbouncer);
    }

    fn caddyFn(context: ?*anyopaque, options: *const install.Options, journal: *install.Journal) anyerror!void {
        _ = options;
        const self: *Fake = @ptrCast(@alignCast(context.?));
        self.journal = journal;
        try self.step(.caddy);
    }

    fn configFn(context: ?*anyopaque, options: *const install.Options, journal: *install.Journal) anyerror!void {
        _ = options;
        const self: *Fake = @ptrCast(@alignCast(context.?));
        self.journal = journal;
        try self.step(.config);
    }

    fn binariesFn(context: ?*anyopaque, options: *const install.Options, journal: *install.Journal) anyerror!void {
        _ = options;
        const self: *Fake = @ptrCast(@alignCast(context.?));
        self.journal = journal;
        try self.step(.binaries);
    }

    fn unitsFn(context: ?*anyopaque, options: *const install.Options, journal: *install.Journal) anyerror!void {
        _ = options;
        const self: *Fake = @ptrCast(@alignCast(context.?));
        self.journal = journal;
        try self.step(.units);
    }

    fn servicesFn(context: ?*anyopaque, options: *const install.Options, journal: *install.Journal) anyerror!void {
        _ = options;
        const self: *Fake = @ptrCast(@alignCast(context.?));
        self.journal = journal;
        try self.step(.services);
    }

    fn healthFn(context: ?*anyopaque, options: *const install.Options) anyerror!install.Health {
        _ = options;
        const self: *Fake = @ptrCast(@alignCast(context.?));
        self.calls[@backingInt(state.Step.health)] += 1;
        if (self.fail_step != null and self.fail_step.? == .health) return error.SimulatedFailure;
        return .{
            .gateway_ready = self.health_ready,
            .management_ready = self.health_ready,
        };
    }

    fn componentsFn(context: ?*anyopaque, allocator: std.mem.Allocator) anyerror![]const state.Component {
        _ = context;
        const components = try allocator.alloc(state.Component, 1);
        components[0] = .{
            .name = try allocator.dupe(u8, "postgresql-18"),
            .version = try allocator.dupe(u8, "18.1"),
        };
        return components;
    }

    fn rollbackFn(context: ?*anyopaque, receipt: state.Receipt) anyerror!void {
        const self: *Fake = @ptrCast(@alignCast(context.?));
        const label = switch (receipt) {
            inline else => |payload| payload,
        };
        if (self.rollback_count >= self.rollbacks.len) return error.TooManyRollbacks;
        if (label.len > self.rollbacks[0].len) return error.LabelTooLong;
        @memcpy(self.rollbacks[self.rollback_count][0..label.len], label);
        self.rollback_lengths[self.rollback_count] = label.len;
        self.rollback_count += 1;
    }
};

const Fixture = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    options: install.Options,

    fn init() !Fixture {
        const allocator = std.testing.allocator;
        const io = std.testing.io;
        var random_bytes: [8]u8 = undefined;
        io.random(&random_bytes);

        const root = try std.fmt.allocPrint(allocator, "/tmp/doctbase-install-test-{d}", .{std.mem.readInt(u64, &random_bytes, .little)});
        const state_path = try std.fmt.allocPrint(allocator, "{s}/var/lib/doctbase/state.json", .{root});
        const log_path = try std.fmt.allocPrint(allocator, "{s}/var/log/doctbase/install.log", .{root});
        const lock_path = try std.fmt.allocPrint(allocator, "{s}/run/doctbase/install.lock", .{root});

        return .{
            .allocator = allocator,
            .io = io,
            .root = root,
            .options = .{
                .domain = "example.com",
                .email = "admin@example.com",
                .version = "test",
                .state_path = state_path,
                .log_path = log_path,
                .lock_path = lock_path,
            },
        };
    }

    fn deinit(self: *Fixture) void {
        std.Io.Dir.cwd().deleteTree(self.io, self.root) catch {};
        self.allocator.free(self.root);
        self.allocator.free(self.options.state_path);
        self.allocator.free(self.options.log_path);
        self.allocator.free(self.options.lock_path);
    }
};

test "fresh install runs every phase and records a healthy state" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    var fake = Fake{ .allocator = fixture.allocator };
    const outcome = try install.run(fixture.io, fixture.allocator, &fixture.options, fake.executor());

    try std.testing.expectEqual(install.Status.installed, outcome.status);
    try std.testing.expectEqual(@as(u8, 0), outcome.exitCode());
    try std.testing.expect(outcome.summary != null);
    try std.testing.expect(outcome.summary.?.gateway_ready);
    try std.testing.expectEqualStrings("example.com", outcome.summary.?.domain);
    try std.testing.expectEqual(@as(usize, 10), fake.receipts_added);
    for (fake.calls) |count| try std.testing.expectEqual(@as(usize, 1), count);

    var parsed = (try state.load(fixture.allocator, fixture.io, fixture.options.state_path)).?;
    defer parsed.deinit();
    try std.testing.expectEqual(state.Status.healthy, parsed.value.status);
    try std.testing.expectEqual(@as(usize, state.step_count), parsed.value.completedSteps());
    try std.testing.expectEqualStrings("test", parsed.value.version);
}

test "three install runs do not recreate resources" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    var fake = Fake{ .allocator = fixture.allocator };
    for (0..3) |_| {
        const outcome = try install.run(fixture.io, fixture.allocator, &fixture.options, fake.executor());
        try std.testing.expectEqual(install.Status.installed, outcome.status);
    }

    try std.testing.expectEqual(@as(usize, 10), fake.receipts_added);
    try std.testing.expectEqual(@as(usize, 0), fake.rollback_count);
    for (fake.calls) |count| try std.testing.expectEqual(@as(usize, 3), count);
}

test "failure rolls back created receipts in reverse order" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    var fake = Fake{ .allocator = fixture.allocator, .fail_step = .pgbouncer };
    const outcome = try install.run(fixture.io, fixture.allocator, &fixture.options, fake.executor());

    try std.testing.expectEqual(install.Status.failed, outcome.status);
    try std.testing.expect(outcome.rolled_back);
    try std.testing.expectEqual(state.Step.pgbouncer, outcome.failure.?.step);
    try std.testing.expectEqualStrings("PGBOUNCER_SETUP_FAILED", outcome.failure.?.code);
    try std.testing.expectEqual(@as(u8, 1), outcome.exitCode());

    try std.testing.expectEqual(@as(usize, 4), fake.rollback_count);
    try std.testing.expectEqualStrings("postgresql", fake.rollbacks[0][0..fake.rollback_lengths[0]]);
    try std.testing.expectEqualStrings("secrets", fake.rollbacks[1][0..fake.rollback_lengths[1]]);
    try std.testing.expectEqualStrings("users", fake.rollbacks[2][0..fake.rollback_lengths[2]]);
    try std.testing.expectEqualStrings("packages", fake.rollbacks[3][0..fake.rollback_lengths[3]]);

    var parsed = (try state.load(fixture.allocator, fixture.io, fixture.options.state_path)).?;
    defer parsed.deinit();
    try std.testing.expectEqual(state.Status.rolled_back, parsed.value.status);
    try std.testing.expectEqual(state.StepStatus.failed, parsed.value.stepStatus(.pgbouncer));
}

test "dry-run performs no mutation and writes no state" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.options.dry_run = true;

    var fake = Fake{ .allocator = fixture.allocator };
    const outcome = try install.run(fixture.io, fixture.allocator, &fixture.options, fake.executor());

    try std.testing.expectEqual(install.Status.dry_run, outcome.status);
    try std.testing.expectEqual(@as(usize, 1), fake.calls[@backingInt(state.Step.preflight)]);
    for (0..state.step_count) |index| {
        if (index == @backingInt(state.Step.preflight)) continue;
        try std.testing.expectEqual(@as(usize, 0), fake.calls[index]);
    }
    try std.testing.expect(try state.load(fixture.allocator, fixture.io, fixture.options.state_path) == null);
    try std.testing.expect(install.plan.len > 0);
}

test "preflight blocker stops before any mutation" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    var fake = Fake{ .allocator = fixture.allocator, .blocked = true };
    const outcome = try install.run(fixture.io, fixture.allocator, &fixture.options, fake.executor());

    try std.testing.expectEqual(install.Status.blocked, outcome.status);
    try std.testing.expectEqual(@as(u8, 3), outcome.exitCode());
    try std.testing.expectEqual(@as(usize, 1), fake.calls[@backingInt(state.Step.preflight)]);
    try std.testing.expect(try state.load(fixture.allocator, fixture.io, fixture.options.state_path) == null);
}

test "concurrent install is rejected by the install lock" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    var lock = try state.Lock.acquire(fixture.io, fixture.options.lock_path);
    defer lock.release(fixture.io);

    var fake = Fake{ .allocator = fixture.allocator };
    const outcome = try install.run(fixture.io, fixture.allocator, &fixture.options, fake.executor());

    try std.testing.expectEqual(install.Status.failed, outcome.status);
    try std.testing.expectEqualStrings("INSTALL_IN_PROGRESS", outcome.failure.?.code);
}

test "non-root run refuses to mutate the host" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    var fake = Fake{ .allocator = fixture.allocator, .running_as_root = false };
    const outcome = try install.run(fixture.io, fixture.allocator, &fixture.options, fake.executor());

    try std.testing.expectEqual(install.Status.failed, outcome.status);
    try std.testing.expectEqualStrings("ROOT_REQUIRED", outcome.failure.?.code);
    try std.testing.expectEqual(@as(usize, 1), fake.calls[@backingInt(state.Step.preflight)]);
}

test "unready health fails the last step and rolls back" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    var fake = Fake{ .allocator = fixture.allocator, .health_ready = false };
    const outcome = try install.run(fixture.io, fixture.allocator, &fixture.options, fake.executor());

    try std.testing.expectEqual(install.Status.failed, outcome.status);
    try std.testing.expectEqual(state.Step.health, outcome.failure.?.step);
    try std.testing.expectEqual(@as(u8, 9), outcome.exitCode());
    try std.testing.expectEqual(@as(usize, 10), fake.rollback_count);
}
