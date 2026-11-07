const std = @import("std");
const install = @import("install_orchestrator");
const install_host = @import("install_host");
const summary = @import("install_summary");

pub fn run(
    init: std.process.Init,
    args: *std.process.Args.Iterator,
    initial_yes: bool,
    initial_dry_run: bool,
) !void {
    var options = install.Options{
        .yes = initial_yes,
        .dry_run = initial_dry_run,
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
        } else if (std.mem.eql(u8, arg, "--install-libvips")) {
            options.install_libvips = true;
        } else if (std.mem.eql(u8, arg, "--proxy")) {
            const mode = args.next() orelse return error.MissingValue;
            if (!std.mem.eql(u8, mode, "caddy")) {
                std.debug.print("Error: native install currently supports only --proxy caddy (got '{s}').\n", .{mode});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else {
            std.debug.print("Error: unknown install option '{s}'.\n", .{arg});
            return error.UnknownOption;
        }
    }

    if (!options.dry_run and !options.yes) {
        std.debug.print(
            \\This will install Doctbase on this host: packages, system users,
            \\a PostgreSQL 18 cluster on port 5433, PgBouncer, Caddy, secrets and
            \\systemd units. Re-run with --yes to continue, or --dry-run to only
            \\print the plan.
            \\
        , .{});
        std.process.exit(1);
    }

    var host = install_host.Host.init(init.gpa, init.io, options.assets_root);
    const outcome = try install.run(init.io, init.gpa, &options, host.executor());
    summary.print(&options, &outcome);

    if (outcome.exitCode() != 0) std.process.exit(outcome.exitCode());
}

fn printUsage() void {
    std.debug.print(
        \\Usage: doctbase install [options]
        \\
        \\Options:
        \\  --domain <host>       Public dashboard domain (admin.<host>); empty = local mode
        \\  --email <address>     ACME account email (optional)
        \\  --yes, -y             Confirm the system changes
        \\  --dry-run             Print the plan without changing the host
        \\  --proxy caddy         Edge proxy mode (native V1 supports caddy)
        \\  --assets <dir>        Directory containing deploy/ and infrastructure/ templates
        \\  --bin-dir <dir>       Directory containing doctbase-* service binaries
        \\  --install-libvips     Install libvips for the optional image proxy
        \\
    , .{});
}
