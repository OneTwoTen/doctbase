const std = @import("std");
const builtin = @import("builtin");

pub const gib: u64 = 1024 * 1024 * 1024;
pub const minimum_memory_bytes: u64 = 2 * gib;
pub const minimum_disk_bytes: u64 = 20 * gib;

pub const Status = enum {
    ready,
    warning,
    blocked,
};

pub const Severity = enum {
    warning,
    blocker,
};

pub const Code = enum {
    host_collection_unsupported,
    os_release_unavailable,
    memory_probe_unavailable,
    disk_probe_unavailable,
    listener_probe_unavailable,
    unsupported_os,
    unsupported_architecture,
    insufficient_memory,
    insufficient_disk_space,
    http_port_in_use,
    domain_dns_unresolved,
    domain_dns_unchecked,

    pub fn codeString(self: Code) []const u8 {
        return switch (self) {
            .host_collection_unsupported => "HOST_COLLECTION_UNSUPPORTED",
            .os_release_unavailable => "OS_RELEASE_UNAVAILABLE",
            .memory_probe_unavailable => "MEMORY_PROBE_UNAVAILABLE",
            .disk_probe_unavailable => "DISK_PROBE_UNAVAILABLE",
            .listener_probe_unavailable => "LISTENER_PROBE_UNAVAILABLE",
            .unsupported_os => "UNSUPPORTED_OS",
            .unsupported_architecture => "UNSUPPORTED_ARCHITECTURE",
            .insufficient_memory => "INSUFFICIENT_MEMORY",
            .insufficient_disk_space => "INSUFFICIENT_DISK_SPACE",
            .http_port_in_use => "HTTP_PORT_IN_USE",
            .domain_dns_unresolved => "DOMAIN_DNS_UNRESOLVED",
            .domain_dns_unchecked => "DOMAIN_DNS_UNCHECKED",
        };
    }
};

pub const DnsStatus = enum {
    not_checked,
    resolves,
    unresolved,
    unavailable,
};

pub const Listener = struct {
    port: u16,
    service: []const u8,
    managed_by_doctbase: bool = false,
};

/// Read-only facts collected by the installer before making system changes.
/// Keeping collection separate from evaluation makes all policy deterministic
/// and lets tests cover unsupported or conflicting hosts without probing them.
pub const Facts = struct {
    collection_supported: bool = true,
    os_release_available: bool = true,
    memory_probe_available: bool = true,
    disk_probe_available: bool = true,
    listener_probe_available: bool = true,
    distro_id: []const u8,
    version_id: []const u8,
    architecture: []const u8,
    memory_bytes: u64,
    available_disk_bytes: u64,
    domain: ?[]const u8 = null,
    dns_status: DnsStatus = .not_checked,
    listeners: []const Listener = &.{},
};

pub const Finding = struct {
    code: Code,
    severity: Severity,
    port: ?u16 = null,
    service: ?[]const u8 = null,

    pub fn message(self: Finding) []const u8 {
        return switch (self.code) {
            .host_collection_unsupported => "Native host preflight collection is available only on Linux.",
            .os_release_unavailable => "The Linux distribution could not be identified from /etc/os-release.",
            .memory_probe_unavailable => "Total host memory could not be read from /proc/meminfo.",
            .disk_probe_unavailable => "Available space on the Doctbase data filesystem could not be determined.",
            .listener_probe_unavailable => "Listening TCP ports could not be inspected from /proc/net/tcp and tcp6.",
            .unsupported_os => "Native installation supports Debian 13 and Ubuntu 24.04 or 26.04.",
            .unsupported_architecture => "Native installation supports x86_64 and arm64 hosts.",
            .insufficient_memory => "The host has less than 2 GiB of memory.",
            .insufficient_disk_space => "The host has less than 20 GiB of available disk space.",
            .http_port_in_use => "A required public HTTP port is already in use.",
            .domain_dns_unresolved => "The configured domain does not resolve in DNS.",
            .domain_dns_unchecked => "DNS could not be checked for the configured domain.",
        };
    }

    pub fn fix(self: Finding) []const u8 {
        return switch (self.code) {
            .host_collection_unsupported => "Run the native installer on Debian 13 or Ubuntu 24.04/26.04 Linux.",
            .os_release_unavailable => "Restore readable /etc/os-release and retry the preflight check.",
            .memory_probe_unavailable => "Restore readable /proc/meminfo and retry the preflight check.",
            .disk_probe_unavailable => "Install coreutils and confirm the data path exists and is readable, then retry.",
            .listener_probe_unavailable => "Restore readable /proc/net/tcp and /proc/net/tcp6, then retry before installation.",
            .unsupported_os, .unsupported_architecture => "Use a supported Debian or Ubuntu release on x86_64 or arm64.",
            .insufficient_memory => "Use a host with at least 2 GiB of RAM before installing Doctbase.",
            .insufficient_disk_space => "Free at least 20 GiB on the Doctbase data filesystem, then retry.",
            .http_port_in_use => "Inspect the service using port 80 or 443; stop or reconfigure it yourself before retrying.",
            .domain_dns_unresolved => "Correct the domain DNS record or continue in local mode without a domain.",
            .domain_dns_unchecked => "Check DNS reachability; installation can continue, but automatic TLS may not be ready.",
        };
    }

    pub fn docsUrl(_: Finding, buffer: []u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "https://doctbase.dev/docs/troubleshooting#preflight", .{});
    }
};

pub const Report = struct {
    findings: [12]Finding = undefined,
    count: usize = 0,

    pub fn status(self: Report) Status {
        var has_warning = false;
        for (self.findings[0..self.count]) |finding| {
            if (finding.severity == .blocker) return .blocked;
            has_warning = true;
        }
        return if (has_warning) .warning else .ready;
    }

    pub fn isBlocked(self: Report) bool {
        return self.status() == .blocked;
    }

    fn add(self: *Report, finding: Finding) void {
        std.debug.assert(self.count < self.findings.len);
        self.findings[self.count] = finding;
        self.count += 1;
    }
};

/// Evaluate host facts without changing the host. A domain lookup failure is a
/// warning because the instance can still be installed in local mode; occupied
/// public ports and unsupported or undersized hosts block installation.
pub fn evaluate(facts: Facts) Report {
    var report: Report = .{};
    if (!facts.collection_supported) {
        report.add(.{ .code = .host_collection_unsupported, .severity = .blocker });
    } else {
        if (!facts.os_release_available) {
            report.add(.{ .code = .os_release_unavailable, .severity = .blocker });
        } else if (!supportedDistro(facts.distro_id, facts.version_id)) {
            report.add(.{ .code = .unsupported_os, .severity = .blocker });
        }
    }
    if (!supportedArchitecture(facts.architecture)) {
        report.add(.{ .code = .unsupported_architecture, .severity = .blocker });
    }
    if (facts.collection_supported) {
        if (!facts.memory_probe_available) {
            report.add(.{ .code = .memory_probe_unavailable, .severity = .blocker });
        } else if (facts.memory_bytes < minimum_memory_bytes) {
            report.add(.{ .code = .insufficient_memory, .severity = .blocker });
        }
        if (!facts.disk_probe_available) {
            report.add(.{ .code = .disk_probe_unavailable, .severity = .blocker });
        } else if (facts.available_disk_bytes < minimum_disk_bytes) {
            report.add(.{ .code = .insufficient_disk_space, .severity = .blocker });
        }
    }

    var http_listener: ?Listener = null;
    var https_listener: ?Listener = null;
    if (facts.collection_supported) {
        if (!facts.listener_probe_available) {
            report.add(.{ .code = .listener_probe_unavailable, .severity = .blocker });
        } else {
            for (facts.listeners) |listener| {
                if (listener.managed_by_doctbase) continue;
                if (listener.port == 80 and http_listener == null) http_listener = listener;
                if (listener.port == 443 and https_listener == null) https_listener = listener;
            }
        }
    }
    if (http_listener) |listener| report.add(.{
        .code = .http_port_in_use,
        .severity = .blocker,
        .port = listener.port,
        .service = listener.service,
    });
    if (https_listener) |listener| report.add(.{
        .code = .http_port_in_use,
        .severity = .blocker,
        .port = listener.port,
        .service = listener.service,
    });

    if (facts.collection_supported) {
        if (facts.domain) |domain| {
            if (domain.len > 0) {
                switch (facts.dns_status) {
                    .unresolved => report.add(.{ .code = .domain_dns_unresolved, .severity = .warning }),
                    .not_checked, .unavailable => report.add(.{ .code = .domain_dns_unchecked, .severity = .warning }),
                    .resolves => {},
                }
            }
        }
    }

    return report;
}

pub const CollectionOptions = struct {
    /// Target data directory. It may not exist yet; collection checks its nearest existing parent.
    data_path: []const u8 = "/var/lib/doctbase",
    domain: ?[]const u8 = null,
    /// Set only after the installer has verified that Doctbase owns these ports.
    doctbase_managed_ports: []const u16 = &.{},
};

pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    facts: Facts,

    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const OsRelease = struct {
    id: []const u8 = "",
    version_id: []const u8 = "",
};

pub const CommandOutput = struct {
    stdout: []const u8,
    succeeded: bool,
};

/// Parse the simple ID and VERSION_ID fields without sourcing the shell file.
pub fn parseOsRelease(contents: []const u8) OsRelease {
    var result: OsRelease = .{};
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const separator = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..separator], " \t");
        const value = parseOsReleaseValue(std.mem.trim(u8, line[separator + 1 ..], " \t"));
        if (std.mem.eql(u8, key, "ID")) result.id = value;
        if (std.mem.eql(u8, key, "VERSION_ID")) result.version_id = value;
    }
    return result;
}

fn parseOsReleaseValue(raw: []const u8) []const u8 {
    if (raw.len >= 2 and ((raw[0] == '"' and raw[raw.len - 1] == '"') or
        (raw[0] == '\'' and raw[raw.len - 1] == '\''))) return raw[1 .. raw.len - 1];
    return raw;
}

/// Return MemTotal from /proc/meminfo in bytes.
pub fn parseMemTotal(contents: []const u8) ?u64 {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t:");
        const name = fields.next() orelse continue;
        if (!std.mem.eql(u8, name, "MemTotal")) continue;
        const amount_text = fields.next() orelse return null;
        const unit = fields.next() orelse return null;
        if (!std.mem.eql(u8, unit, "kB")) return null;
        const amount = std.fmt.parseInt(u64, amount_text, 10) catch return null;
        return std.math.mul(u64, amount, 1024) catch null;
    }
    return null;
}

/// Parse the available KiB value from portable `df -Pk` output.
pub fn parseDfAvailable(contents: []const u8) ?u64 {
    var lines = std.mem.tokenizeScalar(u8, contents, '\n');
    _ = lines.next() orelse return null; // header
    const row = lines.next() orelse return null;

    var fields = std.mem.tokenizeAny(u8, row, " \t\r");
    _ = fields.next() orelse return null; // filesystem
    _ = fields.next() orelse return null; // 1024-blocks
    _ = fields.next() orelse return null; // used
    const value = fields.next() orelse return null; // available

    const kib = std.fmt.parseInt(u64, value, 10) catch return null;
    return std.math.mul(u64, kib, 1024) catch null;
}

/// Parse Linux /proc/net/tcp or tcp6 and return listening sockets.
pub fn parseProcNetTcp(allocator: std.mem.Allocator, contents: []const u8, managed_ports: []const u16) ![]Listener {
    var listeners: std.ArrayList(Listener) = .empty;
    var lines = std.mem.tokenizeScalar(u8, contents, '\n');
    _ = lines.next() orelse return error.InvalidProcNetTcp; // header
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t\r");
        var index: usize = 0;
        var local_address: ?[]const u8 = null;
        var state: ?[]const u8 = null;
        while (fields.next()) |field| : (index += 1) {
            if (index == 1) local_address = field;
            if (index == 3) state = field;
        }
        const local = local_address orelse return error.InvalidProcNetTcp;
        if (!std.mem.eql(u8, state orelse return error.InvalidProcNetTcp, "0A")) continue;
        const colon = std.mem.lastIndexOfScalar(u8, local, ':') orelse return error.InvalidProcNetTcp;
        const port = std.fmt.parseInt(u16, local[colon + 1 ..], 16) catch return error.InvalidProcNetTcp;
        if (port == 0) continue;

        const managed = containsPort(managed_ports, port);
        try listeners.append(allocator, .{
            .port = port,
            .service = if (managed) "doctbase-managed" else "unknown service; inspect with ss -ltnp",
            .managed_by_doctbase = managed,
        });
    }
    return listeners.toOwnedSlice(allocator);
}

fn containsPort(ports: []const u16, needle: u16) bool {
    for (ports) |port| if (port == needle) return true;
    return false;
}

/// Collect read-only host facts on Linux. Probe failures are returned as facts
/// for evaluate() to turn into actionable blocker findings.
pub fn collect(allocator: std.mem.Allocator, io: std.Io, options: CollectionOptions) !Snapshot {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();
    var facts = Facts{
        .collection_supported = builtin.os.tag == .linux,
        .os_release_available = false,
        .memory_probe_available = false,
        .disk_probe_available = false,
        .listener_probe_available = false,
        .distro_id = "",
        .version_id = "",
        .architecture = architectureName(),
        .memory_bytes = 0,
        .available_disk_bytes = 0,
        .domain = if (options.domain) |domain| try arena_allocator.dupe(u8, domain) else null,
    };

    if (!facts.collection_supported) return .{ .arena = arena, .facts = facts };

    if (try readAbsolute(allocator, io, arena_allocator, "/etc/os-release")) |contents| {
        const os = parseOsRelease(contents);
        facts.distro_id = os.id;
        facts.version_id = os.version_id;
        facts.os_release_available = os.id.len > 0 and os.version_id.len > 0;
    }
    if (try readAbsolute(allocator, io, arena_allocator, "/proc/meminfo")) |contents| {
        if (parseMemTotal(contents)) |memory| {
            facts.memory_bytes = memory;
            facts.memory_probe_available = true;
        }
    }

    if (try existingDataDirectory(io, arena_allocator, options.data_path)) |disk_path| {
        if (try runCommand(allocator, io, arena_allocator, &.{ "df", "-Pk", "--", disk_path })) |output| {
            if (output.succeeded) if (parseDfAvailable(output.stdout)) |available| {
                facts.available_disk_bytes = available;
                facts.disk_probe_available = true;
            };
        }
    }

    const tcp = try readAbsolute(allocator, io, arena_allocator, "/proc/net/tcp");
    const tcp6 = try readAbsolute(allocator, io, arena_allocator, "/proc/net/tcp6");
    if (tcp != null and tcp6 != null) {
        var listeners: std.ArrayList(Listener) = .empty;
        const ipv4_listeners = parseProcNetTcp(arena_allocator, tcp.?, options.doctbase_managed_ports) catch |err| switch (err) {
            error.InvalidProcNetTcp => null,
            else => return err,
        };
        const ipv6_listeners = parseProcNetTcp(arena_allocator, tcp6.?, options.doctbase_managed_ports) catch |err| switch (err) {
            error.InvalidProcNetTcp => null,
            else => return err,
        };
        if (ipv4_listeners) |values| try listeners.appendSlice(arena_allocator, values);
        if (ipv6_listeners) |values| try listeners.appendSlice(arena_allocator, values);
        if (ipv4_listeners != null and ipv6_listeners != null) {
            facts.listeners = try listeners.toOwnedSlice(arena_allocator);
            facts.listener_probe_available = true;
        }
    }

    if (options.domain) |domain| {
        if (domain.len > 0) {
            if (try runCommand(allocator, io, arena_allocator, &.{ "getent", "ahosts", domain })) |output| {
                facts.dns_status = if (output.succeeded and output.stdout.len > 0) .resolves else .unresolved;
            } else {
                facts.dns_status = .unavailable;
            }
        }
    }

    return .{ .arena = arena, .facts = facts };
}

fn architectureName() []const u8 {
    return switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => @tagName(builtin.cpu.arch),
    };
}

fn existingDataDirectory(io: std.Io, arena_allocator: std.mem.Allocator, data_path: []const u8) !?[]const u8 {
    var current = data_path;
    while (true) {
        if (std.Io.Dir.cwd().statFile(io, current, .{})) |stat| {
            if (stat.kind == .directory) return try arena_allocator.dupe(u8, current);
        } else |_| {}

        const parent = std.fs.path.dirname(current) orelse return null;
        if (parent.len == 0 or std.mem.eql(u8, parent, current)) return null;
        current = parent;
    }
}

/// Read a file with a streaming reader rather than a stat-size-driven one.
/// Pseudo-filesystems such as procfs report a size of zero while still
/// returning data, so `readFileAlloc` would treat /proc/meminfo and
/// /proc/net/tcp* as empty and every preflight probe would fail.
fn readAbsolute(
    gpa: std.mem.Allocator,
    io: std.Io,
    arena_allocator: std.mem.Allocator,
    path: []const u8,
) !?[]const u8 {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);

    var reader = file.readerStreaming(io, &.{});
    const contents = reader.interface.allocRemaining(gpa, .limited(1024 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer gpa.free(contents);
    return try arena_allocator.dupe(u8, contents);
}

fn runCommand(
    gpa: std.mem.Allocator,
    io: std.Io,
    arena_allocator: std.mem.Allocator,
    argv: []const []const u8,
) !?CommandOutput {
    const result = std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{
            .raw = .{ .nanoseconds = 2 * std.time.ns_per_s },
            .clock = .awake,
        } },
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    const exit_code = switch (result.term) {
        .exited => |code| code,
        else => return null,
    };
    return .{
        .stdout = try arena_allocator.dupe(u8, result.stdout),
        .succeeded = exit_code == 0,
    };
}

fn supportedDistro(distro_id: []const u8, version_id: []const u8) bool {
    if (std.mem.eql(u8, distro_id, "debian")) return std.mem.eql(u8, version_id, "13");
    if (!std.mem.eql(u8, distro_id, "ubuntu")) return false;
    return std.mem.eql(u8, version_id, "24.04") or std.mem.eql(u8, version_id, "26.04");
}

fn supportedArchitecture(architecture: []const u8) bool {
    return std.mem.eql(u8, architecture, "x86_64") or
        std.mem.eql(u8, architecture, "amd64") or
        std.mem.eql(u8, architecture, "aarch64") or
        std.mem.eql(u8, architecture, "arm64");
}
