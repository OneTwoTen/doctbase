const std = @import("std");
const lifecycle = @import("service_lifecycle");

var stop_requested: std.atomic.Value(bool) = .init(false);

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();

    const command = args.next() orelse {
        printUsage();
        return;
    };

    if (std.mem.eql(u8, command, "dev")) {
        return runDev(init, &args);
    }
    if (std.mem.eql(u8, command, "status")) {
        return runStatus(init, &args);
    }
    if (std.mem.eql(u8, command, "restart")) {
        return runRestart(init, &args);
    }
    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "help")) {
        printUsage();
        return;
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
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--systemctl")) {
            systemctl_path = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else {
            return error.UnknownOption;
        }
    }

    var systemd = lifecycle.systemd.SystemdDriver.init(init.gpa, init.io, .{
        .systemctl_path = systemctl_path,
    });
    const driver = systemd.driver();
    defer driver.deinit();

    const states = try driver.list(init.gpa);
    defer init.gpa.free(states);

    std.debug.print("SERVICE      STATE     HEALTH   UNIT                              ENDPOINT\n", .{});
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
    var service_name: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--systemctl")) {
            systemctl_path = args.next() orelse return error.MissingValue;
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

    var systemd = lifecycle.systemd.SystemdDriver.init(init.gpa, init.io, .{
        .systemctl_path = systemctl_path,
    });
    const driver = systemd.driver();
    defer driver.deinit();

    const result = try driver.restart(key);
    if (!result.ok) {
        std.log.err("restart {s} failed: {s}", .{ name, result.error_code orelse "unknown" });
        std.process.exit(6);
    }
    std.log.info("restarted {s}", .{name});
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
        \\  dev [--run-dir DIR] [--bin-dir DIR] [--config FILE] [--token TOKEN]
        \\      [--service NAME]...
        \\  status [--systemctl PATH]
        \\  restart <service> [--systemctl PATH]
        \\
        \\Examples:
        \\  doctbase dev
        \\  doctbase dev --service gateway --service auth --token dev-secret
        \\  doctbase status
        \\  doctbase restart auth
        \\
    , .{});
}
