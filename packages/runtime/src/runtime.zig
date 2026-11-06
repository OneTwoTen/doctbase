const std = @import("std");
const httpz = @import("httpz");
const config_mod = @import("config");
const protocol = @import("service_protocol");
const core = @import("core");

const Allocator = std.mem.Allocator;

pub const Mode = enum {
    native,
    docker,
    dev,

    pub fn label(self: Mode) []const u8 {
        return @tagName(self);
    }
};

pub const Options = struct {
    service_key: []const u8,
    version: []const u8 = "0.1.0",
    commit: []const u8 = "dev",
    mode: Mode = .native,
    config_path: ?[]const u8 = null,
    run_dir: ?[]const u8 = null,
    socket_path: ?[]const u8 = null,
    socket_mode: u32 = 0o660,
    internal_token: ?[]const u8 = null,
    allow_missing_config: bool = true,
    install_signal_handlers: bool = true,
};

pub const Runtime = struct {
    allocator: Allocator,
    io: std.Io,
    options: Options,
    config: config_mod.Config,
    config_hash: []u8,
    socket_path: ?[]u8,
    context: Context,
    server: httpz.Server(*Context),
    started_at: i64,
    ready: std.atomic.Value(bool) = .init(false),
    shutdown_requested: std.atomic.Value(bool) = .init(false),
    server_running: std.atomic.Value(bool) = .init(false),
    request_count: std.atomic.Value(u64) = .init(0),
    checks: [8]protocol.ReadinessCheck = undefined,
    check_count: usize = 0,
    server_thread: ?std.Thread = null,
    watcher_thread: ?std.Thread = null,
    signals_installed: bool = false,

    pub fn create(allocator: Allocator, io: std.Io, options: Options) !*Runtime {
        const self = try allocator.create(Runtime);
        errdefer allocator.destroy(self);

        const config_path = options.config_path orelse "/etc/doctbase/doctbase.toml";
        var config = try config_mod.load(allocator, io, config_path, .{
            .allow_missing = options.allow_missing_config,
        });
        errdefer config.deinit();

        const config_hash = try config_mod.configHash(allocator, &config);
        errdefer allocator.free(config_hash);

        const socket_path = if (options.socket_path) |path|
            try allocator.dupe(u8, path)
        else blk: {
            const run_dir = options.run_dir orelse if (options.mode == .dev) "/tmp/doctbase" else "/run/doctbase";
            _ = std.Io.Dir.cwd().createDirPathStatus(io, run_dir, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => .existed,
                else => return err,
            };
            break :blk try std.fmt.allocPrint(allocator, "{s}/{s}.sock", .{ run_dir, options.service_key });
        };
        errdefer allocator.free(socket_path);

        try ensureSocketAvailable(io, socket_path);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .options = options,
            .config = config,
            .config_hash = config_hash,
            .socket_path = socket_path,
            .context = undefined,
            .server = undefined,
            .started_at = std.Io.Timestamp.now(io, .real).toSeconds(),
        };
        self.context = .{ .runtime = self };

        self.server = try httpz.Server(*Context).init(io, allocator, .{
            .address = .{ .unix = self.socket_path.? },
        }, &self.context);

        var router = try self.server.router(.{});
        router.get("/healthz", Context.healthz, .{});
        router.get("/readyz", Context.readyz, .{});
        router.get("/metrics", Context.metrics, .{});
        router.get("/internal/v1/info", Context.info, .{});

        self.checks[0] = .{ .name = "process", .status = .ok };
        self.check_count = 1;
        return self;
    }

    pub fn destroy(self: *Runtime) void {
        if (self.signals_installed and signal_runtime == self) signal_runtime = null;
        self.config.deinit();
        self.allocator.free(self.config_hash);
        if (self.socket_path) |path| self.allocator.free(path);
        self.server.deinit();
        self.allocator.destroy(self);
    }

    /// Starts the HTTP server and returns immediately. Use `wait` to join.
    pub fn start(self: *Runtime) !void {
        if (self.server_thread != null) return error.AlreadyStarted;
        if (self.options.install_signal_handlers) self.installSignals();

        self.server_running.store(true, .release);
        self.server_thread = self.server.listenInNewThread() catch |err| {
            self.server_running.store(false, .release);
            return err;
        };

        self.postBind() catch |err| {
            self.requestShutdown();
            if (self.server_thread) |thread| {
                thread.join();
                self.server_thread = null;
            }
            self.server_running.store(false, .release);
            return err;
        };

        self.ready.store(true, .release);
        self.watcher_thread = std.Thread.spawn(.{}, watcherMain, .{self}) catch |err| {
            self.requestShutdown();
            if (self.server_thread) |thread| {
                thread.join();
                self.server_thread = null;
            }
            self.server_running.store(false, .release);
            return err;
        };
    }

    /// Blocking server loop used by service binaries.
    pub fn listen(self: *Runtime) !void {
        try self.start();
        self.wait();
    }

    /// Waits for the server thread to stop and performs cleanup.
    pub fn wait(self: *Runtime) void {
        if (self.server_thread) |thread| {
            thread.join();
            self.server_thread = null;
        }
        self.server_running.store(false, .release);
        self.shutdown_requested.store(true, .release);
        self.ready.store(false, .release);
        if (self.watcher_thread) |thread| {
            thread.join();
            self.watcher_thread = null;
        }
        self.cleanupSocket();
    }

    pub fn requestShutdown(self: *Runtime) void {
        self.shutdown_requested.store(true, .release);
    }

    pub fn addReadinessCheck(self: *Runtime, check: protocol.ReadinessCheck) !void {
        if (self.check_count >= self.checks.len) return error.TooManyReadinessChecks;
        self.checks[self.check_count] = check;
        self.check_count += 1;
    }

    pub fn uptimeSeconds(self: *Runtime) i64 {
        const now = std.Io.Timestamp.now(self.io, .real).toSeconds();
        return @max(0, now - self.started_at);
    }

    fn postBind(self: *Runtime) !void {
        const path = self.socket_path orelse return;
        const permissions: std.Io.File.Permissions = @fromBackingInt(@intCast(self.options.socket_mode));
        std.Io.Dir.cwd().setFilePermissions(self.io, path, permissions, .{}) catch |err| {
            if (self.options.mode == .dev) {
                std.log.warn("cannot chmod socket {s}: {s}", .{ path, @errorName(err) });
            } else {
                return error.SocketPermissionDenied;
            }
        };
    }

    fn cleanupSocket(self: *Runtime) void {
        const path = self.socket_path orelse return;
        if (std.fs.path.isAbsolute(path)) {
            std.Io.Dir.deleteFileAbsolute(self.io, path) catch {};
        } else {
            std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
        }
    }

    fn installSignals(self: *Runtime) void {
        signal_runtime = self;
        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = handleSignal },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &action, null);
        std.posix.sigaction(std.posix.SIG.TERM, &action, null);
        self.signals_installed = true;
    }
};

/// The httpz handler context. Keeping it separate from `Runtime` breaks the
/// recursive type dependency between `Runtime.server` and its handler type.
pub const Context = struct {
    runtime: *Runtime,

    pub fn dispatch(self: *Context, action: httpz.Action(*Context), req: *httpz.Request, res: *httpz.Response) !void {
        _ = self.runtime.request_count.fetchAdd(1, .monotonic);
        return action(self, req, res);
    }

    fn healthz(self: *Context, _: *httpz.Request, res: *httpz.Response) !void {
        const runtime = self.runtime;
        res.status = 200;
        res.content_type = .JSON;
        try res.writer().print("{{\"status\":\"ok\",\"service\":\"{s}\",\"version\":\"{s}\"}}", .{
            runtime.options.service_key,
            runtime.options.version,
        });
    }

    fn readyz(self: *Context, _: *httpz.Request, res: *httpz.Response) !void {
        const runtime = self.runtime;
        const ready = runtime.ready.load(.acquire);
        const response = protocol.ReadyResponse{
            .status = if (ready) .ready else .not_ready,
            .checks = runtime.checks[0..runtime.check_count],
            .version = runtime.options.version,
            .config_hash = runtime.config_hash,
            .uptime_seconds = runtime.uptimeSeconds(),
        };

        res.status = if (ready) 200 else 503;
        res.content_type = .JSON;
        try std.json.Stringify.value(response, .{}, res.writer());
    }

    fn info(self: *Context, req: *httpz.Request, res: *httpz.Response) !void {
        const runtime = self.runtime;
        if (!self.authorizeInternal(req)) {
            return self.problem(req, res, .internal_auth_failed, "missing or invalid internal bearer token");
        }

        var started_buffer: [32]u8 = undefined;
        const started_at = std.fmt.bufPrint(&started_buffer, "{d}", .{runtime.started_at}) catch "";
        const response = protocol.InfoResponse{
            .service = runtime.options.service_key,
            .version = runtime.options.version,
            .commit = runtime.options.commit,
            .mode = runtime.options.mode.label(),
            .uptime_seconds = runtime.uptimeSeconds(),
            .config_hash = runtime.config_hash,
            .started_at = started_at,
        };

        res.status = 200;
        res.content_type = .JSON;
        try std.json.Stringify.value(response, .{}, res.writer());
    }

    fn metrics(self: *Context, _: *httpz.Request, res: *httpz.Response) !void {
        const runtime = self.runtime;
        res.status = 200;
        res.content_type = .TEXT;
        try res.writer().print(
            \\# HELP doctbase_build_info Build information.
            \\# TYPE doctbase_build_info gauge
            \\doctbase_build_info{{service="{s}",version="{s}",commit="{s}"}} 1
            \\# HELP doctbase_uptime_seconds Process uptime.
            \\# TYPE doctbase_uptime_seconds gauge
            \\doctbase_uptime_seconds {d}
            \\# HELP doctbase_ready Readiness state.
            \\# TYPE doctbase_ready gauge
            \\doctbase_ready {d}
            \\# HELP doctbase_http_requests_total Total HTTP requests handled.
            \\# TYPE doctbase_http_requests_total counter
            \\doctbase_http_requests_total {d}
            \\
        , .{
            runtime.options.service_key,
            runtime.options.version,
            runtime.options.commit,
            runtime.uptimeSeconds(),
            @intFromBool(runtime.ready.load(.acquire)),
            runtime.request_count.load(.monotonic),
        });
    }

    pub fn notFound(self: *Context, req: *httpz.Request, res: *httpz.Response) !void {
        _ = self;
        var docs_buffer: [128]u8 = undefined;
        const docs = core.Code.not_found.docsUrl(&docs_buffer) catch "";
        const payload = protocol.Problem{
            .title = core.Code.not_found.title(),
            .status = 404,
            .detail = "The requested path is not registered by this service.",
            .code = core.Code.not_found.codeString(),
            .request_id = req.header("x-request-id") orelse "-",
            .docs_url = docs,
        };
        res.status = 404;
        res.content_type = .JSON;
        try std.json.Stringify.value(payload, .{}, res.writer());
    }

    pub fn uncaughtError(self: *Context, req: *httpz.Request, res: *httpz.Response, err: anyerror) void {
        _ = self;
        std.log.err("uncaught service error: {s}", .{@errorName(err)});
        var docs_buffer: [128]u8 = undefined;
        const docs = core.Code.internal.docsUrl(&docs_buffer) catch "";
        const payload = protocol.Problem{
            .title = core.Code.internal.title(),
            .status = 500,
            .detail = "The service encountered an internal error.",
            .code = core.Code.internal.codeString(),
            .request_id = req.header("x-request-id") orelse "-",
            .docs_url = docs,
        };
        res.status = 500;
        res.content_type = .JSON;
        std.json.Stringify.value(payload, .{}, res.writer()) catch {};
    }

    fn problem(self: *Context, req: *httpz.Request, res: *httpz.Response, code: core.Code, detail: ?[]const u8) !void {
        _ = self;
        var docs_buffer: [128]u8 = undefined;
        const docs = code.docsUrl(&docs_buffer) catch "";
        const status = code.httpStatus();
        const payload = protocol.Problem{
            .title = code.title(),
            .status = status,
            .detail = detail,
            .code = code.codeString(),
            .request_id = req.header("x-request-id") orelse "-",
            .docs_url = docs,
        };
        res.status = status;
        res.content_type = .JSON;
        try std.json.Stringify.value(payload, .{}, res.writer());
    }

    fn authorizeInternal(self: *Context, req: *httpz.Request) bool {
        const runtime = self.runtime;
        if (runtime.options.internal_token) |expected| {
            const header = req.header("authorization") orelse return false;
            const prefix = "Bearer ";
            if (!std.mem.startsWith(u8, header, prefix)) return false;
            return constantTimeEql(header[prefix.len..], expected);
        }
        return runtime.options.mode == .dev;
    }
};

var signal_runtime: ?*Runtime = null;

fn handleSignal(_: @TypeOf(std.posix.SIG.INT)) callconv(.c) void {
    if (signal_runtime) |runtime| runtime.requestShutdown();
}

fn watcherMain(runtime: *Runtime) void {
    while (!runtime.shutdown_requested.load(.acquire)) {
        std.Io.sleep(runtime.io, .{ .nanoseconds = 20 * std.time.ns_per_ms }, .awake) catch {};
    }
    if (runtime.server_running.load(.acquire)) runtime.server.stop();
}

fn ensureSocketAvailable(io: std.Io, path: []const u8) !void {
    const address = std.Io.net.UnixAddress.init(path) catch return error.SocketPathTooLong;
    var stream = address.connect(io) catch |err| switch (err) {
        error.FileNotFound, error.ConnectionRefused => return,
        error.AccessDenied, error.PermissionDenied => return error.SocketPermissionDenied,
        else => return err,
    };
    stream.close(io);
    return error.SocketInUse;
}

fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |left, right| diff |= left ^ right;
    return diff == 0;
}

/// Convenience entry point for service binaries. Production units set
/// `DOCTBASE_MODE=native`; `doctbase dev` leaves it unset (dev mode).
pub fn runService(init: std.process.Init, service_key: []const u8) !void {
    const environment = init.environ_map;
    const mode = if (environment.get("DOCTBASE_MODE")) |raw|
        std.meta.stringToEnum(Mode, raw) orelse .native
    else
        .dev;

    const options: Options = .{
        .service_key = service_key,
        .version = "0.1.0",
        .commit = "dev",
        .mode = mode,
        .config_path = environment.get("DOCTBASE_CONFIG"),
        .run_dir = environment.get("DOCTBASE_RUN_DIR"),
        .socket_path = environment.get("DOCTBASE_SOCKET_PATH"),
        .internal_token = environment.get("DOCTBASE_INTERNAL_TOKEN"),
        .allow_missing_config = mode == .dev,
    };

    const app = try Runtime.create(init.gpa, init.io, options);
    defer app.destroy();

    std.log.info("starting {s} on {s}", .{ service_key, app.socket_path.? });
    try app.listen();
    std.log.info("{s} stopped", .{service_key});
}

test "constant-time equality" {
    try std.testing.expect(constantTimeEql("secret", "secret"));
    try std.testing.expect(!constantTimeEql("secret", "secreu"));
    try std.testing.expect(!constantTimeEql("secret", "secret-longer"));
}
