//! Install transaction state, lock and log helpers for native deployments.
//!
//! The installer records its progress in `/var/lib/doctbase/state.json` so an
//! interrupted run can be diagnosed (or resumed) and `doctor` can compare the
//! installed component versions with the running host. The file never contains
//! secret values.
//!
//! `Lock` prevents two installers from mutating the same host at once, and
//! `appendLog` keeps a timestamped transcript at `/var/log/doctbase/install.log`.
//! The orchestrator owns rollback; this module only stores step progress and the
//! receipt type used by the transaction.
//!
//! Mapping source: `docs/nghien-cuu-cai-dat-cau-hinh.md` (Bước 1, Bước 3, Bước 11).

const std = @import("std");

pub const schema_version: u32 = 1;
pub const directory = "/var/lib/doctbase";
pub const state_path = directory ++ "/state.json";
pub const log_path = "/var/log/doctbase/install.log";
pub const lock_path = "/run/doctbase/install.lock";

/// Coarse install phases in execution order. `preflight` is read-only; every
/// other phase owns at least one mutation and must be safe to re-run.
pub const Step = enum {
    preflight,
    packages,
    users,
    secrets,
    postgresql,
    pgbouncer,
    caddy,
    config,
    binaries,
    units,
    services,
    health,
};

pub const step_count = @typeInfo(Step).@"enum".field_names.len;

pub const StepStatus = enum {
    pending,
    running,
    done,
    failed,
};

/// Instance lifecycle from `specs/001-doctbase-install-config/data-model.md`.
/// The installer only writes `installing`, `healthy`, `degraded` and `failed`;
/// `rolled_back` is recorded when every receipt was undone.
pub const Status = enum {
    installing,
    healthy,
    degraded,
    failed,
    rolled_back,
};

/// A mutation that this install run performed and therefore may undo. Receipts
/// are never recorded for resources that already existed before the run, so a
/// rollback cannot delete operator-owned data.
pub const Receipt = union(enum) {
    file: []const u8,
    directory: []const u8,
    user: []const u8,
    group: []const u8,
    cluster: []const u8,
    unit: []const u8,
};

pub const Component = struct {
    name: []const u8,
    version: []const u8,
};

pub const State = struct {
    schema_version: u32 = schema_version,
    version: []const u8 = "",
    status: Status = .installing,
    domain: []const u8 = "",
    email: []const u8 = "",
    error_code: ?[]const u8 = null,
    started_at: i64 = 0,
    updated_at: i64 = 0,
    steps: [step_count]StepStatus = @splat(.pending),
    components: []const Component = &.{},

    pub fn stepStatus(self: *const State, step: Step) StepStatus {
        return self.steps[@backingInt(step)];
    }

    pub fn completedSteps(self: *const State) usize {
        var count: usize = 0;
        for (self.steps) |value| {
            if (value == .done) count += 1;
        }
        return count;
    }
};

pub fn nowSeconds(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}

/// Load the persisted state. A missing file is not an error: it is a fresh
/// install. The returned value owns its allocations and must be deinitialized.
pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !?std.json.Parsed(State) {
    const contents = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(contents);

    return std.json.parseFromSlice(State, allocator, contents, .{ .allocate = .alloc_always }) catch error.InvalidStateFile;
}

/// Replace the state file atomically with a root-only JSON document.
pub fn save(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    value: *const State,
) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, value.*, .{ .whitespace = .indent_2 });
    defer allocator.free(json);

    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
        .permissions = std.Io.File.Permissions.fromMode(0o600),
        .make_path = true,
        .replace = true,
    });
    defer atomic.deinit(io);

    try atomic.file.writeStreamingAll(io, json);
    try atomic.file.writeStreamingAll(io, "\n");
    try atomic.replace(io);
}

/// Append one already-formatted line to the install log. The caller must ensure
/// the message contains no secret value.
pub fn appendLog(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    timestamp: i64,
    message: []const u8,
) !void {
    const line = try std.fmt.allocPrint(allocator, "{d} {s}\n", .{ timestamp, message });
    defer allocator.free(line);

    if (std.fs.path.dirname(path)) |parent| try ensureDirectory(io, parent);

    const existing_size: u64 = blk: {
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk 0,
            else => return err,
        };
        break :blk stat.size;
    };

    const file = try std.Io.Dir.cwd().createFile(io, path, .{
        .truncate = false,
        .permissions = std.Io.File.Permissions.fromMode(0o640),
    });
    defer file.close(io);
    try file.writePositionalAll(io, line, existing_size);
}

fn ensureDirectory(io: std.Io, path: []const u8) !void {
    _ = std.Io.Dir.cwd().createDirPathStatus(io, path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => .existed,
        else => return err,
    };
}

/// Process-wide exclusive lock for install-time mutations. Linux `flock` is
/// released by the kernel when the process exits, so a crashed installer cannot
/// leave a permanently locked host.
pub const Lock = struct {
    file: std.Io.File,

    pub fn acquire(io: std.Io, path: []const u8) !Lock {
        if (std.fs.path.dirname(path)) |parent| try ensureDirectory(io, parent);
        const file = try std.Io.Dir.cwd().createFile(io, path, .{
            .truncate = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        });
        return .{ .file = file };
    }

    pub fn release(self: *Lock, io: std.Io) void {
        self.file.close(io);
    }
};

/// Mutable install progress with an arena for persisted component strings.
pub const Tracker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    state: State = .{},
    parsed: ?std.json.Parsed(State) = null,
    arena: std.heap.ArenaAllocator,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
        version: []const u8,
        domain: []const u8,
        email: []const u8,
    ) !Tracker {
        var tracker = Tracker{
            .allocator = allocator,
            .io = io,
            .path = path,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
        errdefer tracker.deinit();

        tracker.parsed = try load(allocator, io, path);
        if (tracker.parsed) |parsed| {
            tracker.state = parsed.value;
        } else {
            tracker.state = .{
                .version = version,
                .domain = domain,
                .email = email,
            };
        }
        return tracker;
    }

    pub fn deinit(self: *Tracker) void {
        if (self.parsed) |parsed| parsed.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn begin(self: *Tracker, timestamp: i64) !void {
        self.state.status = .installing;
        self.state.error_code = null;
        if (self.state.started_at == 0) self.state.started_at = timestamp;
        self.state.updated_at = timestamp;
        for (&self.state.steps) |*status| {
            if (status.* == .running) status.* = .pending;
        }
        try self.persist();
    }

    pub fn mark(self: *Tracker, step: Step, status: StepStatus, timestamp: i64) !void {
        self.state.steps[@backingInt(step)] = status;
        self.state.updated_at = timestamp;
        try self.persist();
    }

    pub fn finish(self: *Tracker, status: Status, error_code: ?[]const u8, timestamp: i64) !void {
        self.state.status = status;
        self.state.error_code = error_code;
        self.state.updated_at = timestamp;
        try self.persist();
    }

    pub fn setComponents(self: *Tracker, components: []const Component) !void {
        const arena = self.arena.allocator();
        const copy = try arena.alloc(Component, components.len);
        for (components, 0..) |component, index| {
            copy[index] = .{
                .name = try arena.dupe(u8, component.name),
                .version = try arena.dupe(u8, component.version),
            };
        }
        self.state.components = copy;
    }

    fn persist(self: *Tracker) !void {
        try save(self.io, self.allocator, self.path, &self.state);
    }
};

test "install state records step progress and survives a JSON round trip" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const directory_path = try std.fmt.allocPrint(allocator, "/tmp/doctbase-state-test-{d}", .{std.mem.readInt(u64, &random_bytes, .little)});
    defer allocator.free(directory_path);
    defer std.Io.Dir.cwd().deleteTree(io, directory_path) catch {};

    const path = try std.fmt.allocPrint(allocator, "{s}/state.json", .{directory_path});
    defer allocator.free(path);

    var tracker = try Tracker.init(allocator, io, path, "0.1.0", "example.com", "admin@example.com");
    defer tracker.deinit();

    try tracker.begin(1_700_000_000);
    try tracker.mark(.preflight, .done, 1_700_000_001);
    try tracker.mark(.packages, .done, 1_700_000_002);
    try tracker.setComponents(&.{.{ .name = "postgresql-18", .version = "18.1" }});
    try tracker.finish(.failed, "SERVICE_START_FAILED", 1_700_000_003);

    try std.testing.expectEqual(@as(usize, 2), tracker.state.completedSteps());

    var parsed = (try load(allocator, io, path)).?;
    defer parsed.deinit();

    try std.testing.expectEqual(Status.failed, parsed.value.status);
    try std.testing.expectEqualStrings("SERVICE_START_FAILED", parsed.value.error_code.?);
    try std.testing.expectEqual(StepStatus.done, parsed.value.stepStatus(.preflight));
    try std.testing.expectEqual(StepStatus.pending, parsed.value.stepStatus(.health));
    try std.testing.expectEqual(@as(usize, 1), parsed.value.components.len);
    try std.testing.expectEqualStrings("18.1", parsed.value.components[0].version);
}

test "install lock is exclusive and released by close" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const directory_path = try std.fmt.allocPrint(allocator, "/tmp/doctbase-lock-test-{d}", .{std.mem.readInt(u64, &random_bytes, .little)});
    defer allocator.free(directory_path);
    defer std.Io.Dir.cwd().deleteTree(io, directory_path) catch {};

    const path = try std.fmt.allocPrint(allocator, "{s}/install.lock", .{directory_path});
    defer allocator.free(path);

    var first = try Lock.acquire(io, path);
    try std.testing.expectError(error.WouldBlock, Lock.acquire(io, path));

    first.release(io);
    var second = try Lock.acquire(io, path);
    second.release(io);
}

test "install log appends without truncating earlier lines" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const directory_path = try std.fmt.allocPrint(allocator, "/tmp/doctbase-log-test-{d}", .{std.mem.readInt(u64, &random_bytes, .little)});
    defer allocator.free(directory_path);
    defer std.Io.Dir.cwd().deleteTree(io, directory_path) catch {};

    const path = try std.fmt.allocPrint(allocator, "{s}/install.log", .{directory_path});
    defer allocator.free(path);

    try appendLog(io, allocator, path, 10, "first");
    try appendLog(io, allocator, path, 20, "second");

    const contents = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("10 first\n20 second\n", contents);
}
