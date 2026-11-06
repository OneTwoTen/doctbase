const std = @import("std");
const config_mod = @import("config");

pub fn run(init: std.process.Init, args: *std.process.Args.Iterator) !void {
    var config_path: []const u8 = init.environ_map.get("DOCTBASE_CONFIG") orelse "/etc/doctbase/doctbase.toml";
    var subcommand: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--config")) {
            config_path = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else if (subcommand == null) {
            subcommand = arg;
        } else {
            return error.UnknownOption;
        }
    }

    const sub = subcommand orelse "validate";

    if (std.mem.eql(u8, sub, "validate")) {
        return runValidate(init, config_path);
    } else if (std.mem.eql(u8, sub, "show")) {
        return runShow(init, config_path);
    } else if (std.mem.eql(u8, sub, "explain")) {
        const key = args.next();
        return runExplain(key);
    } else {
        std.log.err("unknown config subcommand: {s}", .{sub});
        printUsage();
        return error.UnknownCommand;
    }
}

fn runValidate(init: std.process.Init, path: []const u8) !void {
    var cfg = config_mod.load(init.gpa, init.io, path, .{ .allow_missing = false }) catch |err| {
        std.debug.print("Error: cannot load config from {s} ({s})\n", .{ path, @errorName(err) });
        std.process.exit(2);
    };
    defer cfg.deinit();

    var result = config_mod.validate.validate(init.gpa, &cfg) catch |err| {
        std.debug.print("Error during validation: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };
    defer result.deinit();

    if (!result.isValid()) {
        std.debug.print("Configuration errors found ({d}):\n", .{result.errors.items.len});
        for (result.errors.items) |err| {
            std.debug.print("  - {s}: {s}\n", .{ err.field, err.message });
        }
        std.process.exit(2);
    }

    const hash = config_mod.configHash(init.gpa, &cfg) catch "-";
    defer if (!std.mem.eql(u8, hash, "-")) init.gpa.free(hash);

    std.debug.print("Configuration at {s} is valid (hash: {s}).\n", .{ path, hash });
}

fn runShow(init: std.process.Init, path: []const u8) !void {
    var cfg = config_mod.load(init.gpa, init.io, path, .{ .allow_missing = true }) catch |err| {
        std.debug.print("Error: cannot load config: {s}\n", .{@errorName(err)});
        return err;
    };
    defer cfg.deinit();

    const hash = config_mod.configHash(init.gpa, &cfg) catch "-";
    defer if (!std.mem.eql(u8, hash, "-")) init.gpa.free(hash);

    std.debug.print(
        \\Resolved Configuration:
        \\  schema_version       = {d}
        \\  instance.name        = "{s}"
        \\  instance.domain      = "{s}"
        \\  instance.admin_email = "{s}"
        \\  instance.timezone    = "{s}"
        \\  database.mode        = {s}
        \\  database.max_conn    = {d}
        \\  pooler.enabled       = {s}
        \\  proxy.mode           = {s}
        \\  proxy.tls            = {s}
        \\  services.auth        = {s}
        \\  services.storage     = {s}
        \\  services.pg_meta     = {s}
        \\  services.rest        = {s}
        \\  services.realtime    = {s}
        \\  services.image_proxy = {s}
        \\  storage.backend      = {s}
        \\  storage.max_upload   = "{s}"
        \\  backup.enabled       = {s}
        \\  backup.schedule      = "{s}"
        \\  logging.level        = {s}
        \\  logging.format       = {s}
        \\  config_hash          = {s}
        \\
    , .{
        cfg.schema_version,
        cfg.instance.name,
        cfg.instance.domain,
        cfg.instance.admin_email,
        cfg.instance.timezone,
        @tagName(cfg.database.mode),
        cfg.database.max_connections,
        if (cfg.pooler.enabled) "true" else "false",
        @tagName(cfg.proxy.mode),
        @tagName(cfg.proxy.tls),
        if (cfg.services.auth) "true" else "false",
        if (cfg.services.storage) "true" else "false",
        if (cfg.services.pg_meta) "true" else "false",
        if (cfg.services.rest) "true" else "false",
        if (cfg.services.realtime) "true" else "false",
        if (cfg.services.image_proxy) "true" else "false",
        @tagName(cfg.storage.backend),
        cfg.storage.max_upload,
        if (cfg.backup.enabled) "true" else "false",
        cfg.backup.schedule,
        @tagName(cfg.logging.level),
        @tagName(cfg.logging.format),
        hash,
    });
}

fn runExplain(key_opt: ?[]const u8) !void {
    const key = key_opt orelse {
        std.debug.print("Specify a config key to explain. Example: `doctbase config explain database.mode`\n", .{});
        return;
    };

    if (std.mem.eql(u8, key, "instance.domain")) {
        std.debug.print("instance.domain (string, default: \"\")\n  Public domain for Doctbase. Empty string enables local mode without TLS.\n", .{});
    } else if (std.mem.eql(u8, key, "database.mode")) {
        std.debug.print("database.mode (enum, default: \"managed\")\n  Options: 'managed' (default local PostgreSQL 18) or 'external' (requires database.url_file).\n", .{});
    } else if (std.mem.eql(u8, key, "proxy.tls")) {
        std.debug.print("proxy.tls (enum, default: \"auto\")\n  Options: 'auto' (Let's Encrypt / ZeroSSL via Caddy), 'internal' (local CA), 'off', 'custom'.\n", .{});
    } else if (std.mem.eql(u8, key, "services.realtime")) {
        std.debug.print("services.realtime (bool, default: false)\n  Enable WebSocket and Postgres LISTEN/NOTIFY realtime service (requires services.auth=true).\n", .{});
    } else if (std.mem.eql(u8, key, "storage.max_upload")) {
        std.debug.print("storage.max_upload (size, default: \"50MB\")\n  Maximum upload size per file (e.g. '10MB', '50MB', '1GB').\n", .{});
    } else if (std.mem.eql(u8, key, "backup.schedule")) {
        std.debug.print("backup.schedule (string, default: \"03:00\")\n  Daily backup execution time in local timezone (24-hour HH:MM format).\n", .{});
    } else {
        std.debug.print("Key '{s}': see docs/config-reference.md for detailed documentation.\n", .{key});
    }
}

fn printUsage() void {
    std.debug.print(
        \\Usage: doctbase config <subcommand> [options]
        \\
        \\Subcommands:
        \\  validate [--config PATH]   Validate configuration syntax and semantics
        \\  show [--config PATH]       Show resolved configuration
        \\  explain <key>              Explain a configuration key and its default
        \\
    , .{});
}
