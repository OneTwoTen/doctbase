//! Management service application: owns the control-plane stores and exposes
//! the HTTP API through the shared runtime's fallback handler.
//!
//! Core endpoints (`/healthz`, `/readyz`, `/metrics`, `/internal/v1/info`) stay
//! in `packages/runtime`; everything below `/api/v1` and `/setup` is handled by
//! the management router.

const std = @import("std");
const httpz = @import("httpz");
const runtime = @import("runtime");
const lifecycle = @import("service_lifecycle");
const driver_mod = lifecycle.driver;

const router_mod = @import("api/router.zig");
const session_mod = @import("auth/session.zig");
const users_mod = @import("auth/users.zig");
const setup_mod = @import("auth/setup.zig");
const runtime_agg = @import("services/runtime.zig");

pub const Options = struct {
    /// JSON persistence path for admin accounts. The control DB repository will
    /// replace this behind `UserStore`; keep it 0600 and inside the management
    /// writable directory.
    admin_path: []const u8 = "/var/lib/doctbase/control/admin.json",
    environ: ?*const std.process.Environ.Map = null,
    internal_token: ?[]const u8 = null,
    setup_state: ?setup_mod.State = null,
    driver: driver_mod.LifecycleDriver,
    cookie_secure: bool = true,
};

pub const SetupState = setup_mod.State;

pub const ManagementApp = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    session_store: *session_mod.SessionStore,
    users: *users_mod.UserStore,
    setup: *setup_mod.State,
    aggregator: *runtime_agg.ServiceRuntimeAggregator,
    api: router_mod.ManagementApi,
    internal_token: ?[]u8 = null,
    mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !ManagementApp {
        const internal_token = try loadInternalToken(allocator, io, options);
        errdefer if (internal_token) |token| allocator.free(token);

        const session_store = try allocator.create(session_mod.SessionStore);
        errdefer allocator.destroy(session_store);
        session_store.* = session_mod.SessionStore.init(allocator, io, internal_token);
        session_store.cookie_secure = options.cookie_secure;

        const users = try allocator.create(users_mod.UserStore);
        errdefer allocator.destroy(users);
        users.* = try users_mod.UserStore.initPersistent(allocator, io, options.admin_path);

        const setup = try allocator.create(setup_mod.State);
        errdefer allocator.destroy(setup);
        setup.* = if (options.setup_state) |state|
            state
        else if (options.environ) |environ|
            setup_mod.fromEnvironment(allocator, io, environ) catch setup_mod.State.disabled(allocator, io)
        else
            setup_mod.State.disabled(allocator, io);

        const aggregator = try allocator.create(runtime_agg.ServiceRuntimeAggregator);
        errdefer allocator.destroy(aggregator);
        aggregator.* = runtime_agg.ServiceRuntimeAggregator.init(allocator, io, options.driver, .{});

        return .{
            .allocator = allocator,
            .io = io,
            .session_store = session_store,
            .users = users,
            .setup = setup,
            .aggregator = aggregator,
            .api = router_mod.ManagementApi.initWithSetup(allocator, io, session_store, users, aggregator, setup),
            .internal_token = internal_token,
        };
    }

    pub fn deinit(self: *ManagementApp) void {
        if (self.internal_token) |token| self.allocator.free(token);
        self.aggregator.deinit();
        self.allocator.destroy(self.aggregator);
        self.users.deinit();
        self.allocator.destroy(self.users);
        self.session_store.deinit();
        self.allocator.destroy(self.session_store);
        self.allocator.destroy(self.setup);
        self.* = undefined;
    }

    pub fn handler(self: *ManagementApp) runtime.Fallback {
        return .{ .context = self, .handler = handle };
    }

    fn appOf(context: *anyopaque) *ManagementApp {
        return @ptrCast(@alignCast(context));
    }

    fn handle(context: *anyopaque, req: *httpz.Request, res: *httpz.Response) anyerror!void {
        const self = appOf(context);

        const method = if (req.method == .OTHER) req.method_string else @tagName(req.method);
        const api_request = router_mod.Request{
            .method = method,
            .path = req.url.path,
            .cookie_header = req.header("cookie"),
            .auth_header = req.header("authorization"),
            .csrf_header = req.header("x-csrf-token"),
            .content_type = req.header("content-type"),
            .body = req.body(),
            .request_id = req.header("x-request-id"),
        };

        // The router and its stores are not internally synchronized; serialize
        // management-plane requests. Traffic is low and mutations are rare.
        self.mutex.lockUncancelable(self.io);
        const response = self.api.handle(api_request) catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
        self.mutex.unlock(self.io);
        defer response.deinit(self.allocator);

        res.status = response.status;
        if (std.mem.eql(u8, response.content_type, "application/json")) {
            res.content_type = .JSON;
        } else {
            res.headerOpts("Content-Type", response.content_type, .{ .dupe_name = true, .dupe_value = true }) catch {};
        }
        for (response.headers) |header| {
            res.headerOpts(header.name, header.value, .{ .dupe_name = true, .dupe_value = true }) catch {};
        }
        try res.writer().writeAll(response.body);
    }
};

fn loadInternalToken(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
) !?[]u8 {
    if (options.internal_token) |token| return try allocator.dupe(u8, token);
    const environ = options.environ orelse return null;
    const loader = runtime.secrets.CredentialLoader.init(allocator, io, environ);
    if (try loader.loadCredentialOwned("internal_token")) |token| return token;
    if (environ.get("DOCTBASE_INTERNAL_TOKEN")) |token| return try allocator.dupe(u8, token);
    return null;
}
