const std = @import("std");

pub const REDACTED = "[REDACTED]";

const SENSITIVE_KEYS = [_][]const u8{
    "authorization",
    "password",
    "secret",
    "token",
    "apikey",
    "api_key",
    "access_token",
    "refresh_token",
    "private_key",
};

/// Checks if a key name matches any known sensitive pattern (case-insensitive)
pub fn isSensitiveKey(key: []const u8) bool {
    var lower_buf: [64]u8 = undefined;
    if (key.len > lower_buf.len) return false;
    const lower = std.ascii.lowerString(&lower_buf, key);

    for (SENSITIVE_KEYS) |sensitive| {
        if (std.mem.indexOf(u8, lower, sensitive) != null) return true;
    }
    return false;
}

/// Redact sensitive values from log messages, strings, URLs, or headers.
pub fn redact(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        // 1. Check for Bearer token: "Bearer <token>"
        if (i + 7 <= input.len and std.ascii.eqlIgnoreCase(input[i .. i + 7], "bearer ")) {
            try result.appendSlice(allocator, input[i .. i + 7]);
            i += 7;
            // Skip leading spaces
            while (i < input.len and input[i] == ' ') : (i += 1) {
                try result.append(allocator, ' ');
            }
            // Skip the token characters until delimiter
            var token_len: usize = 0;
            while (i + token_len < input.len and isTokenChar(input[i + token_len])) : (token_len += 1) {}
            if (token_len > 0) {
                try result.appendSlice(allocator, REDACTED);
                i += token_len;
            }
            continue;
        }

        // 2. Check for URI credentials: "://user:password@"
        if (i + 3 <= input.len and std.mem.eql(u8, input[i .. i + 3], "://")) {
            try result.appendSlice(allocator, "://");
            i += 3;
            const start = i;
            var colon_idx: ?usize = null;
            var at_idx: ?usize = null;
            while (i < input.len and input[i] != '/' and input[i] != ' ' and input[i] != '\n') : (i += 1) {
                if (input[i] == ':' and colon_idx == null) {
                    colon_idx = i;
                } else if (input[i] == '@') {
                    at_idx = i;
                    break;
                }
            }

            if (colon_idx != null and at_idx != null and colon_idx.? < at_idx.?) {
                // We have user:password@
                try result.appendSlice(allocator, input[start .. colon_idx.? + 1]);
                try result.appendSlice(allocator, REDACTED);
                try result.append(allocator, '@');
                i = at_idx.? + 1;
            } else {
                // Not a user:password@ URL, write what we read
                try result.appendSlice(allocator, input[start..i]);
            }
            continue;
        }

        // 3. Check for key=value or "key": "value" patterns
        var matched_key: ?[]const u8 = null;
        for (SENSITIVE_KEYS) |sk| {
            if (i + sk.len <= input.len and std.ascii.eqlIgnoreCase(input[i .. i + sk.len], sk)) {
                matched_key = sk;
                break;
            }
        }

        if (matched_key) |sk| {
            try result.appendSlice(allocator, input[i .. i + sk.len]);
            i += sk.len;
            // Check for assignment (= or : or ": ")
            var j = i;
            while (j < input.len and (input[j] == ' ' or input[j] == '"' or input[j] == '\'' or input[j] == ':' or input[j] == '=')) : (j += 1) {}
            if (j > i) {
                try result.appendSlice(allocator, input[i..j]);
                i = j;
                // If it's "Bearer ", preserve "Bearer " and redact the token after it
                if (i + 7 <= input.len and std.ascii.eqlIgnoreCase(input[i .. i + 7], "bearer ")) {
                    try result.appendSlice(allocator, input[i .. i + 7]);
                    i += 7;
                    while (i < input.len and input[i] == ' ') : (i += 1) {
                        try result.append(allocator, ' ');
                    }
                }
                // Redact value until delimiter (quote, comma, newline, &, })
                var val_len: usize = 0;
                while (i + val_len < input.len and !isValDelimiter(input[i + val_len])) : (val_len += 1) {}
                if (val_len > 0) {
                    try result.appendSlice(allocator, REDACTED);
                    i += val_len;
                }
            }
            continue;
        }

        try result.append(allocator, input[i]);
        i += 1;
    }

    return try allocator.dupe(u8, result.items);
}

fn isTokenChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.', '~', '+', '/' => true,
        else => false,
    };
}

fn isValDelimiter(c: u8) bool {
    return switch (c) {
        '"', '\'', ' ', '\t', '\r', '\n', ',', '&', '}', ';' => true,
        else => false,
    };
}

test "redact bearer tokens" {
    const allocator = std.testing.allocator;
    const input = "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.test and Bearer secret123";
    const cleaned = try redact(allocator, input);
    defer allocator.free(cleaned);

    try std.testing.expect(std.mem.indexOf(u8, cleaned, "eyJhbGciOiJIUzI1NiJ9.test") == null);
    try std.testing.expect(std.mem.indexOf(u8, cleaned, "secret123") == null);
    try std.testing.expectEqualStrings("Authorization: Bearer [REDACTED] and Bearer [REDACTED]", cleaned);
}

test "redact uri passwords" {
    const allocator = std.testing.allocator;
    const input = "Connecting to postgres://doctbase:supersecretpass@localhost:5433/doctbase_test";
    const cleaned = try redact(allocator, input);
    defer allocator.free(cleaned);

    try std.testing.expect(std.mem.indexOf(u8, cleaned, "supersecretpass") == null);
    try std.testing.expectEqualStrings("Connecting to postgres://doctbase:[REDACTED]@localhost:5433/doctbase_test", cleaned);
}

test "redact key value pairs" {
    const allocator = std.testing.allocator;
    const input = "{\"password\": \"my-secret-pw\", \"apikey\": \"dtb_12345\"}";
    const cleaned = try redact(allocator, input);
    defer allocator.free(cleaned);

    try std.testing.expect(std.mem.indexOf(u8, cleaned, "my-secret-pw") == null);
    try std.testing.expect(std.mem.indexOf(u8, cleaned, "dtb_12345") == null);
}
