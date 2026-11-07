const std = @import("std");
const lifecycle = @import("service_lifecycle");
const config_cmd = @import("commands/config.zig");
const install_cmd = @import("commands/install.zig");
pub const output = @import("output.zig");

var stop_requested: std.atomic.Value(bool) = .init(false);

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();

    var globals = output.GlobalFlags{};
    var command: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--config")) {
            globals.config_path = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--json")) {
            globals.json = true;
        } else if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "-y")) {
            globals.yes = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            globals.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            globals.verbose = true;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            globals.no_color = true;
        } else if (std.mem.eql(u8, arg, "--version")) {
            std.debug.print("doctbase 0.1.0\n", .{});
            return;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "help")) {
            printUsage();
            return;
        } else if (command == null) {
            command = arg;
            break;
        }
    }

    const cmd = command orelse {
        printUsage();
        return;
    };

    if (std.mem.eql(u8, cmd, "install")) {
        return install_cmd.run(init, &args, globals.yes, globals.dry_run);
    }
    if (std.mem.eql(u8, cmd, "dev")) {
        return runDev(init, &args);
    }
    if (std.mem.eql(u8, cmd, "status")) {
        return runStatus(init, &args);
    }
    if (std.mem.eql(u8, cmd, "restart")) {
        return runRestart(init, &args);
    }
    if (std.mem.eql(u8, cmd, "logs")) {
        return runLogs(init, &args);
    }
    if (std.mem.eql(u8, cmd, "config")) {
        return config_cmd.run(init, &args);
    }

    printUsage();
    return error.UnknownCommand;
}

fn runDev(init: std.process.Init, args: *std.process.Args.Iterator) !void {
    var run_dir: []const u8 = "/tmp/doctbase-dev";
    var bin_dir: []const u8 = "zig-out/bin";
    var config_path: ?[]const u8 = null;
    var internal_token: ?[]const u8 = null;
    var services: std.ArrayList([]const u8) = .empty;
    defer services.deinit(init.gpa);

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--run-dir")) {
            run_dir = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--bin-dir")) {
            bin_dir = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--config")) {
            config_path = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--token")) {
            internal_token = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--service")) {
            try services.append(init.gpa, args.next() orelse return error.MissingValue);
        } else if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else {
            std.log.err("unknown dev option: {s}", .{arg});
            return error.UnknownOption;
        }
    }

    if (services.items.len == 0) {
        try services.append(init.gpa, "gateway");
        try services.append(init.gpa, "auth");
    }

    var dev = try lifecycle.dev.DevDriver.init(init.gpa, init.io, .{
        .bin_dir = bin_dir,
        .run_dir = run_dir,
        .config_path = config_path,
        .internal_token = internal_token,
        .base_env = init.environ_map,
    });
    defer dev.deinit();

    const driver = dev.driver();
    defer driver.deinit();

    installSignals();

    var started: std.ArrayList(lifecycle.registry.ServiceKey) = .empty;
    defer started.deinit(init.gpa);

    for (services.items) |name| {
        const key = lifecycle.registry.parse(name) orelse {
            std.log.err("unknown service: {s}", .{name});
            continue;
        };
        const result = try driver.start(key);
        if (result.ok) {
            try started.append(init.gpa, key);
            std.log.info("started {s}", .{name});
        } else {
            std.log.err("failed to start {s}: {s}", .{ name, result.error_code orelse "unknown" });
        }
    }

    if (started.items.len == 0) return error.NoServicesStarted;

    printStatus(init.io, driver) catch {};

    while (!stop_requested.load(.acquire)) {
        std.Io.sleep(init.io, .{ .nanoseconds = 200 * std.time.ns_per_ms }, .awake) catch {};
    }

    std.log.info("stopping dev services", .{});
    var index = started.items.len;
    while (index > 0) {
        index -= 1;
        _ = driver.stop(started.items[index]) catch {};
    }
}

fn runStatus(init: std.process.Init, args: *std.process.Args.Iterator) !void {
    var systemctl_path: []const u8 = "systemctl";
    var docker_path: []const u8 = "docker";
    var compose_file: ?[]const u8 = null;
    var use_compose: bool = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--systemctl")) {
            systemctl_path = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--compose") or std.mem.eql(u8, arg, "--docker")) {
            use_compose = true;
        } else if (std.mem.eql(u8, arg, "--compose-file")) {
            use_compose = true;
            compose_file = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--docker-path")) {
            use_compose = true;
            docker_path = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else {
            return error.UnknownOption;
        }
    }

    if (use_compose) {
        var compose = lifecycle.compose.ComposeDriver.init(init.gpa, init.io, .{
            .docker_path = docker_path,
            .compose_file = compose_file,
        });
        const driver = compose.driver();
        defer driver.deinit();
        try displayStatus(init, driver, true);
    } else {
        var systemd = lifecycle.systemd.SystemdDriver.init(init.gpa, init.io, .{
            .systemctl_path = systemctl_path,
        });
        const driver = systemd.driver();
        defer driver.deinit();
        try displayStatus(init, driver, false);
    }
}

fn displayStatus(init: std.process.Init, driver: lifecycle.driver.LifecycleDriver, is_compose: bool) !void {
    const states = try driver.list(init.gpa);
    defer init.gpa.free(states);

    if (is_compose) {
        std.debug.print("SERVICE      STATE     HEALTH   COMPOSE_SERVICE                   ENDPOINT\n", .{});
    } else {
        std.debug.print("SERVICE      STATE     HEALTH   UNIT                              ENDPOINT\n", .{});
    }

    for (states) |*state| {
        if (state.endpoint) |endpoint| {
            if (lifecycle.health_probe.probe(init.io, endpoint, 500, "/readyz")) |probe| {
                if (probe.ready) {
                    state.state = .ready;
                    state.health = .ok;
                }
            } else |_| {
                if (state.state == .running) {
                    state.state = .degraded;
                    state.health = .err;
                }
            }
        }
        std.debug.print("{s: <12} {s: <9} {s: <8} {s: <33} {s}\n", .{
            @tagName(state.key),
            @tagName(state.state),
            @tagName(state.health),
            state.unit orelse "-",
            state.endpoint orelse "-",
        });
    }
}

fn runRestart(init: std.process.Init, args: *std.process.Args.Iterator) !void {
    var systemctl_path: []const u8 = "systemctl";
    var docker_path: []const u8 = "docker";
    var compose_file: ?[]const u8 = null;
    var use_compose: bool = false;
    var service_name: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--systemctl")) {
            systemctl_path = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--compose") or std.mem.eql(u8, arg, "--docker")) {
            use_compose = true;
        } else if (std.mem.eql(u8, arg, "--compose-file")) {
            use_compose = true;
            compose_file = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--docker-path")) {
            use_compose = true;
            docker_path = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else if (service_name == null) {
            service_name = arg;
        } else {
            return error.UnknownOption;
        }
    }

    const name = service_name orelse return error.MissingService;
    const key = lifecycle.registry.parse(name) orelse {
        std.log.err("unknown service: {s}", .{name});
        return error.UnknownService;
    };

    var result: lifecycle.driver.OperationResult = undefined;
    if (use_compose) {
        var compose = lifecycle.compose.ComposeDriver.init(init.gpa, init.io, .{
            .docker_path = docker_path,
            .compose_file = compose_file,
        });
        const driver = compose.driver();
        defer driver.deinit();
        result = try driver.restart(key);
    } else {
        var systemd = lifecycle.systemd.SystemdDriver.init(init.gpa, init.io, .{
            .systemctl_path = systemctl_path,
        });
        const driver = systemd.driver();
        defer driver.deinit();
        result = try driver.restart(key);
    }

    if (!result.ok) {
        std.log.err("restart {s} failed: {s}", .{ name, result.error_code orelse "unknown" });
        std.process.exit(6);
    }
    std.log.info("restarted {s}", .{name});
}

fn runLogs(init: std.process.Init, args: *std.process.Args.Iterator) !void {
    var journalctl_path: []const u8 = "journalctl";
    var docker_path: []const u8 = "docker";
    var compose_file: ?[]const u8 = null;
    var use_compose: bool = false;
    var service_name: ?[]const u8 = null;
    var tail: u32 = 50;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--journalctl") or std.mem.eql(u8, arg, "--systemctl")) {
            journalctl_path = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--compose") or std.mem.eql(u8, arg, "--docker")) {
            use_compose = true;
        } else if (std.mem.eql(u8, arg, "--compose-file")) {
            use_compose = true;
            compose_file = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--docker-path")) {
            use_compose = true;
            docker_path = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--tail") or std.mem.eql(u8, arg, "-n")) {
            const val = args.next() orelse return error.MissingValue;
            tail = std.fmt.parseInt(u32, val, 10) catch 50;
        } else if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else if (service_name == null) {
            service_name = arg;
        } else {
            return error.UnknownOption;
        }
    }

    const name = service_name orelse return error.MissingService;
    const key = lifecycle.registry.parse(name) orelse {
        std.log.err("unknown service: {s}", .{name});
        return error.UnknownService;
    };
    const spec = lifecycle.registry.get(key);

    if (use_compose) {
        var compose = lifecycle.compose.ComposeDriver.init(init.gpa, init.io, .{
            .docker_path = docker_path,
            .compose_file = compose_file,
        });
        const log_output = compose.logs(key, tail) catch |err| {
            std.log.err("failed to fetch compose logs: {s}", .{@errorName(err)});
            return err;
        };
        defer init.gpa.free(log_output);
        std.debug.print("{s}", .{log_output});
    } else {
        const unit = spec.unit_name orelse return error.NoUnit;
        var tail_buf: [16]u8 = undefined;
        const tail_str = std.fmt.bufPrint(&tail_buf, "{d}", .{tail}) catch "50";
        const result = std.process.run(init.gpa, init.io, .{
            .argv = &.{ journalctl_path, "-u", unit, "--no-pager", "-n", tail_str },
        }) catch |err| {
            std.log.err("failed to run journalctl: {s}", .{@errorName(err)});
            return err;
        };
        defer init.gpa.free(result.stdout);
        defer init.gpa.free(result.stderr);
        std.debug.print("{s}", .{result.stdout});
    }
}

fn printStatus(io: std.Io, driver: lifecycle.driver.LifecycleDriver) !void {
    const states = try driver.list(std.heap.page_allocator);
    defer std.heap.page_allocator.free(states);

    std.debug.print("SERVICE      STATE     HEALTH   ENDPOINT\n", .{});
    _ = io;
    for (states) |state| {
        std.debug.print("{s: <12} {s: <9} {s: <8} {s}\n", .{
            @tagName(state.key),
            @tagName(state.state),
            @tagName(state.health),
            state.endpoint orelse "-",
        });
    }
}

fn installSignals() void {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
    std.posix.sigaction(std.posix.SIG.TERM, &action, null);
}

fn handleSignal(_: @TypeOf(std.posix.SIG.INT)) callconv(.c) void {
    stop_requested.store(true, .release);
}

fn printUsage() void {
    std.debug.print(
        \\Usage: doctbase <command> [options]
        \\
        \\Commands:
        \\  install [--domain HOST] [--email ADDR] [--yes] [--dry-run]
        \\          [--assets DIR] [--bin-dir DIR]
        \\  dev [--run-dir DIR] [--bin-dir DIR] [--config FILE] [--token TOKEN]
        \\      [--service NAME]...
        \\  status [--systemctl PATH] [--compose] [--compose-file FILE]
        \\  restart <service> [--systemctl PATH] [--compose] [--compose-file FILE]
        \\  logs <service> [--tail N] [--journalctl PATH] [--compose]
        \\  config <validate|show|explain> [--config PATH]
        \\
        \\Examples:
        \\  doctbase install --domain example.com --email admin@example.com --yes
        \\  doctbase install --dry-run
        \\  doctbase dev
        \\  doctbase dev --service gateway --service auth --token dev-secret
        \\  doctbase status
        \\  doctbase status --compose
        \\  doctbase restart auth
        \\  doctbase logs auth --tail 100
        \\  doctbase config validate
        \\  doctbase config show
        \\  doctbase config explain database.mode
        \\
    , .{});
}
