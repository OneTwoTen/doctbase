const std = @import("std");
const repair = @import("repair");
const install = @import("install_orchestrator");
const state = @import("install_state");
const preflight = @import("preflight");

const Fake = struct {
    allocator: std.mem.Allocator,
    calls: [state.step_count]usize = @splat(0),
    receipt_exists: [state.step_count]bool = @splat(false),
    rollbacks: usize = 0,
    fail_step: ?state.Step = null,
    repair_seen: bool = false,
    domain_buf: [128]u8 = undefined,
    domain_len: usize = 0,
    email_buf: [128]u8 = undefined,
    email_len: usize = 0,

    fn domain(self: *const Fake) []const u8 {
        return self.domain_buf[0..self.domain_len];
    }

    fn email(self: *const Fake) []const u8 {
        return self.email_buf[0..self.email_len];
    }

    fn executor(self: *Fake) install.Executor {
        return .{
            .context = self,
            .running_as_root = true,
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

    fn fakeOf(context: ?*anyopaque) *Fake {
        return @ptrCast(@alignCast(context.?));
    }

    fn recordOptions(self: *Fake, options: *const install.Options) void {
        self.repair_seen = options.repair;
        self.domain_len = @min(options.domain.len, self.domain_buf.len);
        @memcpy(self.domain_buf[0..self.domain_len], options.domain[0..self.domain_len]);
        self.email_len = @min(options.email.len, self.email_buf.len);
        @memcpy(self.email_buf[0..self.email_len], options.email[0..self.email_len]);
    }

    fn preflightFn(context: ?*anyopaque, options: *const install.Options) anyerror!preflight.Report {
        const self = fakeOf(context);
        self.calls[@backingInt(state.Step.preflight)] += 1;
        self.recordOptions(options);
        return .{};
    }

    fn step(self: *Fake, which: state.Step, journal: *install.Journal) !void {
        self.calls[@backingInt(which)] += 1;
        if (self.fail_step != null and self.fail_step.? == which) return error.SimulatedFailure;

        const index = @backingInt(which);
        if (!self.receipt_exists[index]) {
            self.receipt_exists[index] = true;
            const label = try std.fmt.allocPrint(self.allocator, "{s}", .{@tagName(which)});
            try journal.add(.{ .file = label });
        }
    }

    fn packagesFn(context: ?*anyopaque, options: *const install.Options, journal: *install.Journal) anyerror!void {
        _ = options;
        try fakeOf(context).step(.packages, journal);
    }

    fn usersFn(context: ?*anyopaque, options: *const install.Options, journal: *install.Journal) anyerror!void {
        _ = options;
        try fakeOf(context).step(.users, journal);
    }

    fn secretsFn(context: ?*anyopaque, options: *const install.Options, journal: *install.Journal) anyerror!void {
        _ = options;
        try fakeOf(context).step(.secrets, journal);
    }

    fn postgresqlFn(context: ?*anyopaque, options: *const install.Options, journal: *install.Journal) anyerror!void {
        _ = options;
        try fakeOf(context).step(.postgresql, journal);
    }

    fn pgbouncerFn(context: ?*anyopaque, options: *const install.Options, journal: *install.Journal) anyerror!void {
        _ = options;
        try fakeOf(context).step(.pgbouncer, journal);
    }

    fn caddyFn(context: ?*anyopaque, options: *const install.Options, journal: *install.Journal) anyerror!void {
        _ = options;
        try fakeOf(context).step(.caddy, journal);
    }

    fn configFn(context: ?*anyopaque, options: *const install.Options, journal: *install.Journal) anyerror!void {
        _ = options;
        try fakeOf(context).step(.config, journal);
    }

    fn binariesFn(context: ?*anyopaque, options: *const install.Options, journal: *install.Journal) anyerror!void {
        _ = options;
        try fakeOf(context).step(.binaries, journal);
    }

    fn unitsFn(context: ?*anyopaque, options: *const install.Options, journal: *install.Journal) anyerror!void {
        _ = options;
        try fakeOf(context).step(.units, journal);
    }

    fn servicesFn(context: ?*anyopaque, options: *const install.Options, journal: *install.Journal) anyerror!void {
        _ = options;
        try fakeOf(context).step(.services, journal);
    }

    fn healthFn(context: ?*anyopaque, options: *const install.Options) anyerror!install.Health {
        _ = options;
        const self = fakeOf(context);
        self.calls[@backingInt(state.Step.health)] += 1;
        if (self.fail_step != null and self.fail_step.? == .health) return error.SimulatedFailure;
        return .{ .gateway_ready = true, .management_ready = true };
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
        _ = receipt;
        fakeOf(context).rollbacks += 1;
    }
};

const Fixture = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []u8,
    options: install.Options,

    fn init() !Fixture {
        const allocator = std.testing.allocator;
        const io = std.testing.io;
        var random_bytes: [8]u8 = undefined;
        io.random(&random_bytes);

        const root = try std.fmt.allocPrint(allocator, "/tmp/doctbase-repair-test-{d}", .{std.mem.readInt(u64, &random_bytes, .little)});
        const state_path = try std.fmt.allocPrint(allocator, "{s}/var/lib/doctbase/state.json", .{root});
        const log_path = try std.fmt.allocPrint(allocator, "{s}/var/log/doctbase/install.log", .{root});
        const lock_path = try std.fmt.allocPrint(allocator, "{s}/run/doctbase/install.lock", .{root});

        return .{
            .allocator = allocator,
            .io = io,
            .root = root,
            .options = .{
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

    fn seedInstalledState(self: *Fixture, domain: []const u8, email: []const u8) !void {
        var tracker = try state.Tracker.init(self.allocator, self.io, self.options.state_path, "9.9.9", domain, email);
        defer tracker.deinit();
        try tracker.begin(1_700_000_000);
        try tracker.finish(.healthy, null, 1_700_000_100);
    }
};

test "repair refuses a host without an installed state" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try std.testing.expectError(
        error.NotInstalled,
        repair.Context.init(fixture.allocator, fixture.io, fixture.options),
    );
}

test "repair reuses domain and email, sets repair mode and runs every phase" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.seedInstalledState("installed.example.com", "ops@example.com");

    var context = try repair.Context.init(fixture.allocator, fixture.io, fixture.options);
    defer context.deinit();

    try std.testing.expect(context.options.repair);
    try std.testing.expectEqualStrings("installed.example.com", context.options.domain);
    try std.testing.expectEqualStrings("ops@example.com", context.options.email);

    var fake = Fake{ .allocator = fixture.allocator };
    const outcome = try context.run(fake.executor());

    try std.testing.expectEqual(install.Status.installed, outcome.status);
    try std.testing.expectEqual(@as(u8, 0), outcome.exitCode());
    try std.testing.expectEqualStrings("installed.example.com", outcome.summary.?.domain);

    try std.testing.expect(fake.repair_seen);
    try std.testing.expectEqualStrings("installed.example.com", fake.domain());
    try std.testing.expectEqualStrings("ops@example.com", fake.email());
    for (fake.calls) |count| try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(usize, 0), fake.rollbacks);

    var parsed = (try state.load(fixture.allocator, fixture.io, fixture.options.state_path)).?;
    defer parsed.deinit();
    try std.testing.expectEqual(state.Status.healthy, parsed.value.status);
    try std.testing.expectEqualStrings("installed.example.com", parsed.value.domain);
    try std.testing.expectEqual(@as(usize, state.step_count), parsed.value.completedSteps());
}

test "explicit repair options override the installed domain and email" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.seedInstalledState("old.example.com", "old@example.com");

    var options = fixture.options;
    options.domain = "new.example.com";
    options.email = "new@example.com";

    var context = try repair.Context.init(fixture.allocator, fixture.io, options);
    defer context.deinit();
    try std.testing.expectEqualStrings("new.example.com", context.options.domain);
    try std.testing.expectEqualStrings("new@example.com", context.options.email);

    var fake = Fake{ .allocator = fixture.allocator };
    _ = try context.run(fake.executor());
    try std.testing.expectEqualStrings("new.example.com", fake.domain());
    try std.testing.expectEqualStrings("new@example.com", fake.email());

    var parsed = (try state.load(fixture.allocator, fixture.io, fixture.options.state_path)).?;
    defer parsed.deinit();
    try std.testing.expectEqualStrings("new.example.com", parsed.value.domain);
    try std.testing.expectEqualStrings("new@example.com", parsed.value.email);
}

test "repair dry run performs preflight only and leaves state untouched" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.seedInstalledState("installed.example.com", "ops@example.com");

    var options = fixture.options;
    options.dry_run = true;

    var context = try repair.Context.init(fixture.allocator, fixture.io, options);
    defer context.deinit();

    var fake = Fake{ .allocator = fixture.allocator };
    const outcome = try context.run(fake.executor());

    try std.testing.expectEqual(install.Status.dry_run, outcome.status);
    try std.testing.expectEqual(@as(usize, 1), fake.calls[@backingInt(state.Step.preflight)]);
    for (0..state.step_count) |index| {
        if (index == @backingInt(state.Step.preflight)) continue;
        try std.testing.expectEqual(@as(usize, 0), fake.calls[index]);
    }

    var parsed = (try state.load(fixture.allocator, fixture.io, fixture.options.state_path)).?;
    defer parsed.deinit();
    try std.testing.expectEqual(state.Status.healthy, parsed.value.status);
    try std.testing.expectEqualStrings("installed.example.com", parsed.value.domain);
}

test "repair failure rolls back only receipts created by this run" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.seedInstalledState("installed.example.com", "ops@example.com");

    var context = try repair.Context.init(fixture.allocator, fixture.io, fixture.options);
    defer context.deinit();

    var fake = Fake{ .allocator = fixture.allocator, .fail_step = .units };
    const outcome = try context.run(fake.executor());

    try std.testing.expectEqual(install.Status.failed, outcome.status);
    try std.testing.expectEqual(state.Step.units, outcome.failure.?.step);
    try std.testing.expect(fake.rollbacks > 0);
    try std.testing.expect(fake.rollbacks <= @as(usize, @backingInt(state.Step.units)));

    // Project data is not touched by the transaction: the state file and its
    // instance domain still exist after a failed repair.
    var parsed = (try state.load(fixture.allocator, fixture.io, fixture.options.state_path)).?;
    defer parsed.deinit();
    try std.testing.expectEqualStrings("installed.example.com", parsed.value.domain);
}
