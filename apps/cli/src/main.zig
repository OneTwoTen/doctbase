const std = @import("std");
const lifecycle = @import("service_lifecycle");
const config_cmd = @import("commands/config.zig");
const docker_cmd = @import("commands/docker.zig");
const install_cmd = @import("commands/install.zig");
const install_host = @import("install_host");
const install_mod = @import("install_orchestrator");
const install_summary = @import("install_summary");
const repair_cmd = @import("install/repair.zig");
const uninstall_cmd = @import("commands/uninstall.zig");
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
    if (std.mem.eql(u8, cmd, "repair")) {
        return runRepair(init, &args, globals.yes, globals.dry_run);
    }
    if (std.mem.eql(u8, cmd, "init")) {
        return runInit(init, &args, globals.dry_run);
    }
    if (std.mem.eql(u8, cmd, "up")) {
        return runUp(init, &args, globals.dry_run);
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
    if (std.mem.eql(u8, cmd, "uninstall")) {
        return runUninstall(init, &args, globals.yes, globals.dry_run);
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

fn runInit(init: std.process.Init, args: *std.process.Args.Iterator, dry_run: bool) !void {
    var options = docker_cmd.InitOptions{ .dry_run = dry_run };
    var profile_selected = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--profile")) {
            options.profile = parseProfile(args.next() orelse return error.MissingValue) orelse return error.UnknownProfile;
            profile_selected = true;
        } else if (std.mem.eql(u8, arg, "--dir")) {
            options.directory = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--domain")) {
            options.domain = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--email")) {
            options.email = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--database")) {
            const value = args.next() orelse return error.MissingValue;
            options.database = std.meta.stringToEnum(docker_cmd.Database, value) orelse return error.UnknownDatabaseMode;
        } else if (std.mem.eql(u8, arg, "--instance-name")) {
            options.instance_name = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--image-prefix")) {
            options.image_prefix = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--version")) {
            options.version = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--assets")) {
            options.assets_root = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            options.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "-y")) {
            // init only writes local files; no confirmation is required.
        } else if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else {
            std.debug.print("Error: unknown init option '{s}'.\n", .{arg});
            return error.UnknownOption;
        }
    }

    if (!profile_selected or options.profile != .docker) {
        std.debug.print(
            \\Native init is covered by `doctbase install`. Use:
            \\  doctbase init --profile docker [--dir DIR] [--domain HOST] [--email ADDR]
            \\
        , .{});
        std.process.exit(1);
    }

    var result = docker_cmd.init(init.io, init.gpa, options) catch |err| {
        printDockerError(err);
        std.process.exit(1);
    };
    defer result.deinit();

    if (options.dry_run) {
        std.debug.print("Docker plan (no changes were made):\n", .{});
    } else {
        std.debug.print("Docker deployment initialized.\n", .{});
    }
    std.debug.print(
        \\Directory: {s}
        \\Compose:   {s}
        \\Caddyfile: {s}
        \\Env:       {s} ({s})
        \\
    , .{
        result.directory,
        result.compose_path,
        result.caddyfile_path,
        result.env_path,
        if (options.dry_run)
            (if (result.env_created) "would be created" else "existing values would be kept")
        else if (result.env_created)
            "created"
        else
            "existing values kept",
    });
    if (result.secrets_generated != 0) {
        if (options.dry_run) {
            std.debug.print(
                "{d} secret(s) would be generated in .env (mode 0600); values are never printed.\n",
                .{result.secrets_generated},
            );
        } else {
            std.debug.print(
                "{d} secret(s) generated in .env (mode 0600); values are never printed.\n",
                .{result.secrets_generated},
            );
        }
    }
    std.debug.print("Next: doctbase up --profile docker --dir {s}\n", .{result.directory});
}

fn runUp(init: std.process.Init, args: *std.process.Args.Iterator, dry_run: bool) !void {
    var options = docker_cmd.UpOptions{ .dry_run = dry_run };

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--profile")) {
            options.profile = parseProfile(args.next() orelse return error.MissingValue) orelse return error.UnknownProfile;
        } else if (std.mem.eql(u8, arg, "--dir")) {
            options.directory = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            options.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else {
            std.debug.print("Error: unknown up option '{s}'.\n", .{arg});
            return error.UnknownOption;
        }
    }

    var host = CommandHost{ .allocator = init.gpa, .io = init.io };
    docker_cmd.up(init.io, init.gpa, options, host.runner()) catch |err| {
        printDockerError(err);
        std.process.exit(1);
    };
}

fn parseProfile(value: []const u8) ?docker_cmd.Profile {
    return std.meta.stringToEnum(docker_cmd.Profile, value);
}

fn printDockerError(err: anyerror) void {
    const message = switch (err) {
        error.NativeProfileUnsupported => "profile native uses `doctbase install`",
        error.InvalidDirectory => "--dir must be a concrete directory, not /, . or ..",
        error.InvalidDomain => "invalid --domain; use a DNS hostname without scheme or path",
        error.InvalidEmail => "invalid --email address",
        error.InvalidInstanceName => "--instance-name must be lowercase letters, digits or '-'",
        error.InvalidImagePrefix => "--image-prefix must be a valid image repository prefix",
        error.InvalidVersion => "--version must be a tag or digest without whitespace",
        error.TemplateNotFound => "compose template not found; pass --assets <release-share-dir>",
        error.ComposeNotFound => "compose.yml not found; run `doctbase init --profile docker` first",
        error.CommandFailed => "docker compose / systemctl command failed; inspect the output above",
        else => @errorName(err),
    };
    std.debug.print("Error: {s}.\n", .{message});
}

const CommandHost = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    fn runner(self: *CommandHost) docker_cmd.Runner {
        return .{ .context = self, .run = runCommand };
    }

    fn hostOf(context: ?*anyopaque) *CommandHost {
        return @ptrCast(@alignCast(context.?));
    }

    fn runCommand(context: ?*anyopaque, argv: []const []const u8) anyerror!bool {
        const self = hostOf(context);
        const result = std.process.run(self.allocator, self.io, .{
            .argv = argv,
            .stdout_limit = .limited(1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        }) catch return false;
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.stdout.len != 0) std.debug.print("{s}", .{result.stdout});
        if (result.stderr.len != 0) std.debug.print("{s}", .{result.stderr});

        return switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };
    }
};

fn runRepair(
    init: std.process.Init,
    args: *std.process.Args.Iterator,
    assume_yes: bool,
    dry_run: bool,
) !void {
    var options = install_mod.Options{
        .yes = assume_yes,
        .dry_run = dry_run,
        .repair = true,
    };

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--domain")) {
            options.domain = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--email")) {
            options.email = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "-y")) {
            options.yes = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            options.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--assets")) {
            options.assets_root = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--bin-dir")) {
            options.bin_dir = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else {
            std.debug.print("Error: unknown repair option '{s}'.\n", .{arg});
            return error.UnknownOption;
        }
    }

    if (!options.dry_run and !options.yes) {
        std.debug.print(
            \\This re-runs the installer against the existing instance to repair
            \\binaries, units, generated files and service health. Existing
            \\configuration, secrets and data are kept. Re-run with --yes to
            \\continue, or --dry-run to only print the plan.
            \\
        , .{});
        std.process.exit(1);
    }

    var host = install_host.Host.init(init.gpa, init.io, options.assets_root);
    var repair = repair_cmd.Context.init(init.gpa, init.io, options) catch |err| switch (err) {
        error.NotInstalled => {
            std.debug.print("Doctbase is not installed on this host; run `doctbase install` first.\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };
    defer repair.deinit();

    const outcome = try repair.run(host.executor());
    install_summary.print(&repair.options, &outcome);
    if (outcome.exitCode() != 0) std.process.exit(outcome.exitCode());
}

fn runUninstall(
    init: std.process.Init,
    args: *std.process.Args.Iterator,
    assume_yes: bool,
    dry_run: bool,
) !void {
    var mode: uninstall_cmd.Mode = .keep_data;
    var yes = assume_yes;
    var plan_only = dry_run;
    var mode_selected = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--purge")) {
            if (mode_selected and mode != .purge) return error.ConflictingUninstallMode;
            mode = .purge;
            mode_selected = true;
        } else if (std.mem.eql(u8, arg, "--keep-data")) {
            if (mode_selected and mode != .keep_data) return error.ConflictingUninstallMode;
            mode = .keep_data;
            mode_selected = true;
        } else if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "-y")) {
            yes = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            plan_only = true;
        } else if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else {
            std.log.err("unknown uninstall option: {s}", .{arg});
            return error.UnknownOption;
        }
    }

    var answer: ?[]u8 = null;
    defer if (answer) |value| init.gpa.free(value);

    if (!plan_only) {
        if (uninstall_cmd.confirmationFor(mode, yes)) |required| {
            answer = try promptAnswer(init.io, init.gpa, required);
        }
    }

    var host = UninstallHost{ .allocator = init.gpa, .io = init.io };
    uninstall_cmd.run(init.gpa, .{
        .mode = mode,
        .assume_yes = yes,
        .dry_run = plan_only,
        .confirmation = if (answer) |value| value else null,
    }, host.executor()) catch |err| switch (err) {
        error.ConfirmationRequired, error.ConfirmationMismatch => {
            std.debug.print("Uninstall cancelled.\n", .{});
            std.process.exit(2);
        },
        else => return err,
    };
}

fn promptAnswer(io: std.Io, allocator: std.mem.Allocator, required: uninstall_cmd.Confirmation) ![]u8 {
    switch (required) {
        .simple => std.debug.print(
            "Remove Doctbase services and generated files but keep configuration and data? [y/N] ",
            .{},
        ),
        .typed_purge => std.debug.print(
            "This permanently deletes all Doctbase data. Type '{s}' to continue: ",
            .{uninstall_cmd.typed_purge_answer},
        ),
    }

    var buffer: [256]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &buffer);
    const line = reader.interface.takeDelimiterExclusive('\n') catch |err| switch (err) {
        error.EndOfStream => "",
        else => return err,
    };
    return allocator.dupe(u8, line);
}

const UninstallHost = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    fn executor(self: *UninstallHost) uninstall_cmd.Executor {
        return .{
            .context = self,
            .running_as_root = isRoot(),
            .remove_path = removePath,
            .run = runCommand,
        };
    }

    fn hostOf(context: ?*anyopaque) *UninstallHost {
        return @ptrCast(@alignCast(context.?));
    }

    /// Delete a file, symlink or directory without following symlinks. A path
    /// that is already absent is success, which makes re-runs idempotent.
    fn removePath(context: ?*anyopaque, path: []const u8) anyerror!void {
        const self = hostOf(context);
        const stat = std.Io.Dir.cwd().statFile(self.io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };

        if (stat.kind == .directory) {
            try std.Io.Dir.cwd().deleteTree(self.io, path);
        } else {
            // Never traverse a symlink: deleting the link itself is the only
            // safe action when the target may belong to another package.
            std.Io.Dir.cwd().deleteFile(self.io, path) catch |err| switch (err) {
                error.FileNotFound => return,
                else => return err,
            };
        }
    }

    /// Commands are best effort: unavailable units, missing clusters and
    /// already-removed accounts must not abort the remaining cleanup.
    fn runCommand(context: ?*anyopaque, argv: []const []const u8) anyerror!bool {
        const self = hostOf(context);
        const result = std.process.run(self.allocator, self.io, .{
            .argv = argv,
            .stdout_limit = .limited(256 * 1024),
            .stderr_limit = .limited(256 * 1024),
        }) catch return false;
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };
    }
};

fn isRoot() bool {
    return std.os.linux.geteuid() == 0;
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
        \\  repair [--domain HOST] [--email ADDR] [--yes] [--dry-run]
        \\         [--assets DIR] [--bin-dir DIR]
        \\  init --profile docker [--dir DIR] [--domain HOST] [--email ADDR]
        \\       [--database external|bundled] [--dry-run]
        \\  up [--profile native|docker] [--dir DIR] [--dry-run]
        \\  dev [--run-dir DIR] [--bin-dir DIR] [--config FILE] [--token TOKEN]
        \\      [--service NAME]...
        \\  status [--systemctl PATH] [--compose] [--compose-file FILE]
        \\  restart <service> [--systemctl PATH] [--compose] [--compose-file FILE]
        \\  logs <service> [--tail N] [--journalctl PATH] [--compose]
        \\  config <validate|show|explain> [--config PATH]
        \\  uninstall [--keep-data|--purge] [--yes] [--dry-run]
        \\
        \\Examples:
        \\  doctbase install --domain example.com --email admin@example.com --yes
        \\  doctbase install --dry-run
        \\  doctbase repair --yes
        \\  doctbase init --profile docker --dir /opt/doctbase --domain example.com
        \\  doctbase up --profile docker --dir /opt/doctbase
        \\  doctbase dev
        \\  doctbase dev --service gateway --service auth --token dev-secret
        \\  doctbase status
        \\  doctbase status --compose
        \\  doctbase restart auth
        \\  doctbase logs auth --tail 100
        \\  doctbase config validate
        \\  doctbase config show
        \\  doctbase config explain database.mode
        \\  doctbase uninstall
        \\  doctbase uninstall --purge
        \\
    , .{});
}
