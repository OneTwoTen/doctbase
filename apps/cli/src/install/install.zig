//! Native install orchestration.
//!
//! The orchestrator owns ordering, progress persistence, the install lock,
//! rollback and the final summary. Every mutation is delegated to an injected
//! `Executor` so the policy can be tested without root or a real host:
//!
//!   preflight -> packages -> users -> secrets -> PostgreSQL -> PgBouncer
//!             -> Caddy -> config -> binaries -> units -> services -> health
//!
//! Steps are idempotent on their own (existing secrets are kept, an existing
//! cluster is adopted, managed files are only written when absent or equal), so
//! a re-run after an interruption completes instead of leaving a half state.
//! Rollback only undoes receipts that this run created.
//!
//! Mapping source: `docs/nghien-cuu-cai-dat-cau-hinh.md` (Bước 1-11),
//! `specs/001-doctbase-install-config/spec.md` (US1) and `contracts/cli.md` §4.1.

const std = @import("std");
const preflight = @import("preflight");
const caddy = @import("install_caddy");
const state_mod = @import("install_state");

pub const Failure = struct {
    step: state_mod.Step,
    code: []const u8,
    detail: []const u8,
};

pub const Health = struct {
    gateway_ready: bool,
    management_ready: bool,
};

pub const Summary = struct {
    version: []const u8,
    domain: []const u8,
    email: []const u8,
    gateway_ready: bool,
    management_ready: bool,
    log_path: []const u8,
    state_path: []const u8,
    setup_token_path: []const u8,
};

pub const Status = enum {
    installed,
    dry_run,
    blocked,
    failed,
};

pub const Outcome = struct {
    status: Status,
    report: preflight.Report = .{},
    summary: ?Summary = null,
    failure: ?Failure = null,
    rolled_back: bool = false,

    pub fn exitCode(self: *const Outcome) u8 {
        return switch (self.status) {
            .installed, .dry_run => 0,
            .blocked => 3,
            .failed => if (self.failure) |failure| switch (failure.step) {
                .postgresql => 5,
                .units, .services, .binaries => 6,
                .health => 9,
                else => 1,
            } else 1,
        };
    }
};

pub const Options = struct {
    domain: []const u8 = "",
    email: []const u8 = "",
    version: []const u8 = "0.1.0",
    /// Directory that contains the shipped templates (`deploy/native/...` and
    /// `infrastructure/postgres/...`). The native package installs these under
    /// `/usr/local/lib/doctbase/current/share`.
    assets_root: []const u8 = "/usr/local/lib/doctbase/current/share",
    /// Directory containing the compiled service binaries. Empty means "next to
    /// the running CLI", which is the development layout.
    bin_dir: []const u8 = "",
    install_libvips: bool = false,
    dry_run: bool = false,
    yes: bool = false,
    state_path: []const u8 = state_mod.state_path,
    log_path: []const u8 = state_mod.log_path,
    lock_path: []const u8 = state_mod.lock_path,
    health_timeout_ms: u32 = 60_000,
};

/// Resources created during this run. The orchestrator owns the receipt strings
/// and frees them when the journal is deinitialized.
pub const Journal = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(state_mod.Receipt) = .empty,

    pub fn init(allocator: std.mem.Allocator) Journal {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Journal) void {
        for (self.items.items) |receipt| freeReceipt(self.allocator, receipt);
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    /// Take ownership of the receipt payload. Callers must allocate it with the
    /// same allocator they passed to `Journal.init`.
    pub fn add(self: *Journal, receipt: state_mod.Receipt) !void {
        try self.items.append(self.allocator, receipt);
    }

    pub fn count(self: *const Journal) usize {
        return self.items.items.len;
    }
};

fn freeReceipt(allocator: std.mem.Allocator, receipt: state_mod.Receipt) void {
    switch (receipt) {
        inline else => |payload| allocator.free(payload),
    }
}

pub const Executor = struct {
    context: ?*anyopaque = null,
    running_as_root: bool = false,
    preflight: *const fn (context: ?*anyopaque, options: *const Options) anyerror!preflight.Report,
    packages: *const fn (context: ?*anyopaque, options: *const Options, journal: *Journal) anyerror!void,
    users: *const fn (context: ?*anyopaque, options: *const Options, journal: *Journal) anyerror!void,
    secrets: *const fn (context: ?*anyopaque, options: *const Options, journal: *Journal) anyerror!void,
    postgresql: *const fn (context: ?*anyopaque, options: *const Options, journal: *Journal) anyerror!void,
    pgbouncer: *const fn (context: ?*anyopaque, options: *const Options, journal: *Journal) anyerror!void,
    caddy: *const fn (context: ?*anyopaque, options: *const Options, journal: *Journal) anyerror!void,
    config: *const fn (context: ?*anyopaque, options: *const Options, journal: *Journal) anyerror!void,
    binaries: *const fn (context: ?*anyopaque, options: *const Options, journal: *Journal) anyerror!void,
    units: *const fn (context: ?*anyopaque, options: *const Options, journal: *Journal) anyerror!void,
    services: *const fn (context: ?*anyopaque, options: *const Options, journal: *Journal) anyerror!void,
    health: *const fn (context: ?*anyopaque, options: *const Options) anyerror!Health,
    /// Returns an owned slice; the orchestrator frees the slice and each field.
    components: *const fn (context: ?*anyopaque, allocator: std.mem.Allocator) anyerror![]const state_mod.Component,
    rollback: *const fn (context: ?*anyopaque, receipt: state_mod.Receipt) anyerror!void,
};

const Context = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    options: *const Options,
    executor: Executor,
    journal: *Journal,
    tracker: *state_mod.Tracker,
    health: ?Health = null,
};

const StepRunner = struct {
    step: state_mod.Step,
    label: []const u8,
    run: *const fn (*Context) anyerror!void,
};

const sequence = [_]StepRunner{
    .{ .step = .packages, .label = "installing system packages", .run = runPackages },
    .{ .step = .users, .label = "creating system users and directories", .run = runUsers },
    .{ .step = .secrets, .label = "generating instance secrets", .run = runSecrets },
    .{ .step = .postgresql, .label = "provisioning PostgreSQL cluster", .run = runPostgresql },
    .{ .step = .pgbouncer, .label = "configuring PgBouncer", .run = runPgbouncer },
    .{ .step = .caddy, .label = "configuring Caddy", .run = runCaddy },
    .{ .step = .config, .label = "writing instance configuration", .run = runConfig },
    .{ .step = .binaries, .label = "installing service binaries", .run = runBinaries },
    .{ .step = .units, .label = "installing systemd units", .run = runUnits },
    .{ .step = .services, .label = "starting Doctbase services", .run = runServices },
    .{ .step = .health, .label = "verifying service health", .run = runHealth },
};

pub const plan = [_][]const u8{
    "check host prerequisites (OS, architecture, RAM, disk, ports, DNS)",
    "install PostgreSQL 18, PgBouncer and Caddy from vendor repositories",
    "create the doctbase group, per-service accounts and owned directories",
    "generate 256-bit instance secrets under /etc/doctbase/secrets",
    "create the socket-only PostgreSQL cluster on port 5433 and bootstrap roles",
    "render the PgBouncer socket configuration and unit",
    "render the Caddy edge configuration with a Unix-socket admin API",
    "write /etc/doctbase/doctbase.toml when it does not exist yet",
    "install service binaries under /usr/local/lib/doctbase/current/bin",
    "install systemd units, the doctbase target and the polkit allowlist",
    "enable and start doctbase.target",
    "verify gateway and management readiness over their Unix sockets",
};

pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: *const Options,
    executor: Executor,
) !Outcome {
    if (options.domain.len != 0 and !caddy.validHost(options.domain)) {
        return .{
            .status = .failed,
            .failure = .{ .step = .preflight, .code = "INVALID_DOMAIN", .detail = "InvalidDomain" },
        };
    }
    if (options.email.len != 0 and !caddy.validEmail(options.email)) {
        return .{
            .status = .failed,
            .failure = .{ .step = .preflight, .code = "INVALID_EMAIL", .detail = "InvalidEmail" },
        };
    }

    const report = executor.preflight(executor.context, options) catch |err| {
        return .{
            .status = .failed,
            .failure = .{ .step = .preflight, .code = "PREFLIGHT_FAILED", .detail = @errorName(err) },
        };
    };

    if (report.isBlocked()) {
        return .{ .status = .blocked, .report = report };
    }
    if (options.dry_run) {
        return .{ .status = .dry_run, .report = report };
    }
    if (!executor.running_as_root) {
        return .{
            .status = .failed,
            .report = report,
            .failure = .{ .step = .preflight, .code = "ROOT_REQUIRED", .detail = "RootPrivilegesRequired" },
        };
    }

    var lock = state_mod.Lock.acquire(io, options.lock_path) catch |err| switch (err) {
        error.WouldBlock => return .{
            .status = .failed,
            .report = report,
            .failure = .{ .step = .preflight, .code = "INSTALL_IN_PROGRESS", .detail = "WouldBlock" },
        },
        else => return err,
    };
    defer lock.release(io);

    var tracker = try state_mod.Tracker.init(
        allocator,
        io,
        options.state_path,
        options.version,
        options.domain,
        options.email,
    );
    defer tracker.deinit();

    const started = state_mod.nowSeconds(io);
    try tracker.begin(started);
    note(io, allocator, options.log_path, started, "install started");
    try tracker.mark(.preflight, .done, started);

    var journal = Journal.init(allocator);
    defer journal.deinit();

    var context = Context{
        .io = io,
        .allocator = allocator,
        .options = options,
        .executor = executor,
        .journal = &journal,
        .tracker = &tracker,
    };

    for (sequence) |entry| {
        const step_started = state_mod.nowSeconds(io);
        try tracker.mark(entry.step, .running, step_started);
        note(io, allocator, options.log_path, step_started, entry.label);

        entry.run(&context) catch |err| {
            return fail(io, allocator, options, &context, entry.step, entry.label, err, report);
        };

        const step_finished = state_mod.nowSeconds(io);
        try tracker.mark(entry.step, .done, step_finished);
    }

    const installed_at = state_mod.nowSeconds(io);
    try tracker.finish(.healthy, null, installed_at);
    note(io, allocator, options.log_path, installed_at, "install completed");

    const health = context.health orelse Health{
        .gateway_ready = false,
        .management_ready = false,
    };
    return .{
        .status = .installed,
        .report = report,
        .summary = .{
            .version = options.version,
            .domain = options.domain,
            .email = options.email,
            .gateway_ready = health.gateway_ready,
            .management_ready = health.management_ready,
            .log_path = options.log_path,
            .state_path = options.state_path,
            .setup_token_path = "/etc/doctbase/secrets/admin_setup_token",
        },
    };
}

fn fail(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: *const Options,
    context: *Context,
    step: state_mod.Step,
    label: []const u8,
    err: anyerror,
    report: preflight.Report,
) !Outcome {
    const failed_at = state_mod.nowSeconds(io);
    try context.tracker.mark(step, .failed, failed_at);
    noteFmt(io, allocator, options.log_path, failed_at, "step failed: {s}", .{label});

    const rolled_back = rollback(context);
    const status: state_mod.Status = if (rolled_back) .rolled_back else .failed;
    const code = codeFor(step);
    try context.tracker.finish(status, code, failed_at);
    note(io, allocator, options.log_path, failed_at, if (rolled_back) "rollback completed" else "rollback incomplete");

    return .{
        .status = .failed,
        .report = report,
        .failure = .{ .step = step, .code = code, .detail = @errorName(err) },
        .rolled_back = rolled_back,
    };
}

fn rollback(context: *Context) bool {
    var complete = true;
    var index = context.journal.items.items.len;
    while (index > 0) {
        index -= 1;
        const receipt = context.journal.items.items[index];
        context.executor.rollback(context.executor.context, receipt) catch {
            complete = false;
        };
    }
    return complete;
}

fn codeFor(step: state_mod.Step) []const u8 {
    return switch (step) {
        .preflight => "PREFLIGHT_FAILED",
        .packages => "PACKAGE_INSTALL_FAILED",
        .users => "SYSTEM_IDENTITY_FAILED",
        .secrets => "SECRET_SETUP_FAILED",
        .postgresql => "DATABASE_SETUP_FAILED",
        .pgbouncer => "PGBOUNCER_SETUP_FAILED",
        .caddy => "CADDY_SETUP_FAILED",
        .config => "CONFIG_WRITE_FAILED",
        .binaries => "BINARY_INSTALL_FAILED",
        .units => "UNIT_INSTALL_FAILED",
        .services => "SERVICE_START_FAILED",
        .health => "HEALTH_CHECK_FAILED",
    };
}

fn note(io: std.Io, allocator: std.mem.Allocator, path: []const u8, timestamp: i64, message: []const u8) void {
    state_mod.appendLog(io, allocator, path, timestamp, message) catch {};
}

fn noteFmt(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    timestamp: i64,
    comptime format: []const u8,
    args: anytype,
) void {
    const message = std.fmt.allocPrint(allocator, format, args) catch return;
    defer allocator.free(message);
    note(io, allocator, path, timestamp, message);
}

fn runPackages(context: *Context) !void {
    try context.executor.packages(context.executor.context, context.options, context.journal);

    const components = try context.executor.components(context.executor.context, context.allocator);
    defer {
        for (components) |component| {
            context.allocator.free(component.name);
            context.allocator.free(component.version);
        }
        context.allocator.free(components);
    }
    try context.tracker.setComponents(components);
}

fn runUsers(context: *Context) !void {
    try context.executor.users(context.executor.context, context.options, context.journal);
}

fn runSecrets(context: *Context) !void {
    try context.executor.secrets(context.executor.context, context.options, context.journal);
}

fn runPostgresql(context: *Context) !void {
    try context.executor.postgresql(context.executor.context, context.options, context.journal);
}

fn runPgbouncer(context: *Context) !void {
    try context.executor.pgbouncer(context.executor.context, context.options, context.journal);
}

fn runCaddy(context: *Context) !void {
    try context.executor.caddy(context.executor.context, context.options, context.journal);
}

fn runConfig(context: *Context) !void {
    try context.executor.config(context.executor.context, context.options, context.journal);
}

fn runBinaries(context: *Context) !void {
    try context.executor.binaries(context.executor.context, context.options, context.journal);
}

fn runUnits(context: *Context) !void {
    try context.executor.units(context.executor.context, context.options, context.journal);
}

fn runServices(context: *Context) !void {
    try context.executor.services(context.executor.context, context.options, context.journal);
}

fn runHealth(context: *Context) !void {
    const health = try context.executor.health(context.executor.context, context.options);
    context.health = health;
    if (!health.gateway_ready or !health.management_ready) return error.HealthCheckFailed;
}

comptime {
    // The sequence must cover every mutating step exactly once and in order.
    const expected = state_mod.step_count - 1;
    if (sequence.len != expected) @compileError("install sequence must cover every mutating step");
    for (sequence, 0..) |entry, index| {
        if (@backingInt(entry.step) != index + 1) @compileError("install sequence is out of order");
    }
}
