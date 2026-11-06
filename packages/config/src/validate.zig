const std = @import("std");
const schema = @import("schema.zig");

pub const ValidationError = struct {
    field: []const u8,
    message: []const u8,
};

pub const ValidationResult = struct {
    allocator: std.mem.Allocator,
    errors: std.ArrayList(ValidationError),

    pub fn init(allocator: std.mem.Allocator) ValidationResult {
        return .{
            .allocator = allocator,
            .errors = std.ArrayList(ValidationError).init(allocator),
        };
    }

    pub fn deinit(self: *ValidationResult) void {
        self.errors.deinit();
    }

    pub fn isValid(self: ValidationResult) bool {
        return self.errors.items.len == 0;
    }

    pub fn addError(self: *ValidationResult, field: []const u8, message: []const u8) !void {
        try self.errors.append(.{ .field = field, .message = message });
    }
};

pub fn validate(allocator: std.mem.Allocator, config: *const schema.Config) !ValidationResult {
    var result = ValidationResult.init(allocator);
    errdefer result.deinit();

    // 1. schema_version
    if (config.schema_version != 1) {
        try result.addError("schema_version", "unsupported schema version; only version 1 is supported");
    }

    // 2. instance.domain
    if (config.instance.domain.len > 0) {
        if (!isValidDomain(config.instance.domain)) {
            try result.addError("instance.domain", "domain must be lowercase valid DNS name without wildcards or bare IP");
        }
    }

    // 3. database
    if (config.database.mode == .external) {
        if (config.database.url_file == null or config.database.url_file.?.len == 0) {
            try result.addError("database.url_file", "database.url_file must be specified when database.mode is 'external'");
        }
    }
    if (config.database.max_connections < 10 or config.database.max_connections > 10000) {
        try result.addError("database.max_connections", "database.max_connections must be between 10 and 10000");
    }

    // 4. proxy
    if (config.proxy.tls == .custom) {
        if (config.proxy.custom_cert == null or config.proxy.custom_cert.?.len == 0) {
            try result.addError("proxy.custom_cert", "custom_cert must be provided when proxy.tls is 'custom'");
        }
        if (config.proxy.custom_key == null or config.proxy.custom_key.?.len == 0) {
            try result.addError("proxy.custom_key", "custom_key must be provided when proxy.tls is 'custom'");
        }
    }

    // 5. services dependencies
    if (config.services.realtime and !config.services.auth) {
        try result.addError("services.realtime", "services.realtime requires services.auth to be enabled");
    }
    if (config.services.rest and !config.services.pg_meta) {
        try result.addError("services.rest", "services.rest requires services.pg_meta to be enabled");
    }
    if (config.services.image_proxy and !config.services.storage) {
        try result.addError("services.image_proxy", "services.image_proxy requires services.storage to be enabled");
    }

    // 6. storage.max_upload
    if (!isValidSize(config.storage.max_upload)) {
        try result.addError("storage.max_upload", "storage.max_upload must be a valid size string (e.g. '50MB', '1GB', '500KB')");
    }

    // 7. backup.schedule
    if (config.backup.enabled and !isValidSchedule(config.backup.schedule)) {
        try result.addError("backup.schedule", "backup.schedule must be in 24-hour HH:MM format (e.g. '03:00')");
    }

    // 8. security.session_ttl
    if (!isValidDuration(config.security.session_ttl)) {
        try result.addError("security.session_ttl", "security.session_ttl must be a valid duration (e.g. '24h', '30m', '7d')");
    }

    return result;
}

pub fn isValidDomain(domain: []const u8) bool {
    if (domain.len == 0 or domain.len > 253) return false;
    if (domain[0] == '.' or domain[domain.len - 1] == '.') return false;
    if (domain[0] == '-' or domain[domain.len - 1] == '-') return false;

    var all_digits = true;
    for (domain) |c| {
        if (c >= 'A' and c <= 'Z') return false; // must be lowercase
        if (c == '*' or c == ' ' or c == '/' or c == ':') return false; // no wildcards, spaces or ports
        const is_dns_char = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '.' or c == '-';
        if (!is_dns_char) return false;
        if (!(c >= '0' and c <= '9') and c != '.') {
            all_digits = false;
        }
    }
    // Reject bare IPv4 address
    if (all_digits) return false;

    return true;
}

pub fn isValidSchedule(schedule: []const u8) bool {
    if (schedule.len != 5) return false;
    if (schedule[2] != ':') return false;

    const hours = std.fmt.parseInt(u32, schedule[0..2], 10) catch return false;
    const minutes = std.fmt.parseInt(u32, schedule[3..5], 10) catch return false;

    return hours < 24 and minutes < 60;
}

pub fn isValidSize(size: []const u8) bool {
    if (size.len == 0) return false;
    var num_len = size.len;

    if (std.mem.endsWith(u8, size, "GB") or std.mem.endsWith(u8, size, "MB") or std.mem.endsWith(u8, size, "KB")) {
        num_len = size.len - 2;
    } else if (std.mem.endsWith(u8, size, "B")) {
        num_len = size.len - 1;
    }

    if (num_len == 0) return false;
    const num = std.fmt.parseInt(u64, size[0..num_len], 10) catch return false;
    return num > 0;
}

pub fn isValidDuration(duration: []const u8) bool {
    if (duration.len < 2) return false;
    const unit = duration[duration.len - 1];
    if (unit != 's' and unit != 'm' and unit != 'h' and unit != 'd') return false;

    const num = std.fmt.parseInt(u64, duration[0 .. duration.len - 1], 10) catch return false;
    return num > 0;
}

test "validation passes for default config" {
    const allocator = std.testing.allocator;
    const config = schema.Config{
        .arena = std.heap.ArenaAllocator.init(allocator),
    };
    defer @constCast(&config).deinit();

    var result = try validate(allocator, &config);
    defer result.deinit();

    try std.testing.expect(result.isValid());
}

test "validation detects domain, schedule, size and service dependency errors" {
    const allocator = std.testing.allocator;
    var config = schema.Config{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .instance = .{ .domain = "EXAMPLE.COM" }, // uppercase invalid
        .services = .{
            .auth = false,
            .realtime = true, // requires auth
            .pg_meta = false,
            .rest = true, // requires pg_meta
        },
        .backup = .{ .schedule = "25:70" }, // invalid time
        .storage = .{ .max_upload = "invalid_size" },
    };
    defer config.deinit();

    var result = try validate(allocator, &config);
    defer result.deinit();

    try std.testing.expect(!result.isValid());
    try std.testing.expect(result.errors.items.len >= 5);
}

test "validation requires url_file for external database mode" {
    const allocator = std.testing.allocator;
    var config = schema.Config{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .database = .{ .mode = .external, .url_file = null },
    };
    defer config.deinit();

    var result = try validate(allocator, &config);
    defer result.deinit();

    try std.testing.expect(!result.isValid());
    var found = false;
    for (result.errors.items) |err| {
        if (std.mem.eql(u8, err.field, "database.url_file")) found = true;
    }
    try std.testing.expect(found);
}
