//! Generator for the single user-editable instance configuration.
//!
//! `/etc/doctbase/doctbase.toml` is written only when it does not exist yet.
//! Re-running the installer must never overwrite operator edits; `doctbase
//! config diff`/`apply` owns drift afterwards. The generated file contains no
//! secret: credentials live under `/etc/doctbase/secrets` and are referenced
//! only by the services that need them.
//!
//! Mapping source: `docs/nghien-cuu-cai-dat-cau-hinh.md` §6.1 and `contracts/config.md`.

const std = @import("std");

pub const path = "/etc/doctbase/doctbase.toml";
pub const file_mode: u16 = 0o640;
pub const owner = "root";
pub const group = "doctbase";

pub const Options = struct {
    domain: []const u8 = "",
    email: []const u8 = "",
};

pub fn render(allocator: std.mem.Allocator, options: Options) ![]u8 {
    for (options.domain) |byte| {
        if (byte == '"' or byte == '\\' or byte < 0x21) return error.InvalidDomain;
    }
    for (options.email) |byte| {
        if (byte == '"' or byte == '\\' or byte < 0x21) return error.InvalidEmail;
    }

    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();

    try output.writer.writeAll(
        \\# Doctbase instance configuration.
        \\# This is the only file an operator edits. Generated artifacts
        \\# (Caddyfile, pgbouncer.ini, systemd units, projects.json) live under
        \\# /etc/doctbase/generated and are rewritten by `sudo doctbase apply`.
        \\#
        \\# Secrets are NOT stored here. They live under /etc/doctbase/secrets.
        \\schema_version = 1
        \\
        \\[instance]
        \\name = "doctbase"
        \\
    );
    try output.writer.print("domain = \"{s}\"\n", .{options.domain});
    try output.writer.print("admin_email = \"{s}\"\n", .{options.email});
    try output.writer.writeAll(
        \\timezone = "UTC"
        \\
        \\[database]
        \\mode = "managed"
        \\max_connections = 200
        \\
        \\[pooler]
        \\enabled = true
        \\pool_mode = "transaction"
        \\default_pool_size = 10
        \\max_client_conn = 1000
        \\
        \\[proxy]
        \\mode = "caddy"
        \\tls = "auto"
        \\
        \\[services]
        \\auth = true
        \\storage = true
        \\pg_meta = true
        \\rest = false
        \\realtime = false
        \\image_proxy = false
        \\
        \\[storage]
        \\backend = "local"
        \\max_upload = "50MB"
        \\
        \\[backup]
        \\enabled = true
        \\schedule = "03:00"
        \\retain_daily = 7
        \\retain_weekly = 4
        \\
        \\[logging]
        \\level = "info"
        \\format = "json"
        \\
        \\[security]
        \\admin_ip_allowlist = []
        \\session_ttl = "24h"
        \\default_rate_limit = "600/min"
        \\
    );

    return try allocator.dupe(u8, output.written());
}

comptime {
    if ((file_mode & 0o007) != 0) @compileError("doctbase.toml must not be world accessible");
}
