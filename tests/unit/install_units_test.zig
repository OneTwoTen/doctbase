const std = @import("std");
const units = @import("install_units");
const users = @import("install_users");
const registry = @import("service_lifecycle").registry;

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(64 * 1024),
    );
}

fn isServiceUser(name: []const u8) bool {
    for (users.service_users) |user| {
        if (std.mem.eql(u8, user, name)) return true;
    }
    return false;
}

fn lineContaining(contents: []const u8, prefix: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, prefix)) return line;
    }
    return null;
}

test "every application service renders a complete hardened unit" {
    const allocator = std.testing.allocator;
    const template = try readFile(allocator, units.app_template_path);
    defer allocator.free(template);

    var app_count: usize = 0;
    for (registry.specs()) |*spec| {
        if (spec.kind != .app) continue;
        app_count += 1;

        const contents = try units.renderApp(allocator, template, spec);
        defer allocator.free(contents);

        const unit = spec.unit_name.?;
        try std.testing.expect(std.mem.indexOf(u8, contents, "Installed to /etc/systemd/system/") != null);
        try std.testing.expect(std.mem.indexOf(u8, contents, unit) != null);
        try std.testing.expect(std.mem.indexOf(u8, contents, "Description=Doctbase ") != null);
        try std.testing.expect(std.mem.indexOf(u8, contents, spec.display_name) != null);

        const user = units.userFor(spec.key);
        try std.testing.expect(isServiceUser(user));
        try std.testing.expect(std.mem.indexOf(u8, contents, "User=") != null);
        try std.testing.expect(std.mem.indexOf(u8, contents, user) != null);
        try std.testing.expect(std.mem.indexOf(u8, contents, "Group=doctbase") != null);
        try std.testing.expect(std.mem.indexOf(u8, contents, "User=root") == null);

        try std.testing.expect(std.mem.indexOf(u8, contents, "ExecStart=/usr/local/lib/doctbase/current/bin/") != null);
        try std.testing.expect(std.mem.indexOf(u8, contents, spec.binary_name.?) != null);
        try std.testing.expect(std.mem.indexOf(u8, contents, "Environment=DOCTBASE_SOCKET_PATH=") != null);
        try std.testing.expect(std.mem.indexOf(u8, contents, spec.socket_path.?) != null);
        try std.testing.expect(std.mem.indexOf(u8, contents, "Environment=DOCTBASE_CONFIG=/etc/doctbase/doctbase.toml") != null);
        try std.testing.expect(std.mem.indexOf(u8, contents, "Environment=DOCTBASE_RUN_DIR=/run/doctbase") != null);
        try std.testing.expect(std.mem.indexOf(u8, contents, "Environment=DOCTBASE_MODE=native") != null);

        try std.testing.expect(std.mem.indexOf(u8, contents, "Type=exec") != null);
        try std.testing.expect(std.mem.indexOf(u8, contents, "NoNewPrivileges=true") != null);
        try std.testing.expect(std.mem.indexOf(u8, contents, "PrivateTmp=true") != null);
        try std.testing.expect(std.mem.indexOf(u8, contents, "ProtectSystem=strict") != null);
        try std.testing.expect(std.mem.indexOf(u8, contents, "ProtectHome=true") != null);
        try std.testing.expect(std.mem.indexOf(u8, contents, "ReadWritePaths=") != null);
        try std.testing.expect(std.mem.indexOf(u8, contents, "/run/doctbase") != null);
        try std.testing.expect(std.mem.indexOf(u8, contents, "LoadCredential=internal_token:/etc/doctbase/secrets/internal_token") != null);
        try std.testing.expect(std.mem.indexOf(u8, contents, "WantedBy=doctbase.target") != null);
        try std.testing.expect(std.mem.indexOf(u8, contents, "PartOf=doctbase.target") != null);
        try std.testing.expect(std.mem.indexOf(u8, contents, "TimeoutStopSec=30s") != null);

        // Secrets never enter the unit environment.
        try std.testing.expect(std.mem.indexOf(u8, contents, "Environment=DOCTBASE_INTERNAL_TOKEN=") == null);
        try std.testing.expect(std.mem.indexOf(u8, contents, "@UNIT@") == null);
        try std.testing.expect(std.mem.indexOf(u8, contents, "@USER@") == null);
    }

    try std.testing.expectEqual(@as(usize, 8), app_count);
}

test "dependency ordering follows the service registry" {
    const allocator = std.testing.allocator;
    const template = try readFile(allocator, units.app_template_path);
    defer allocator.free(template);

    const rest = try units.renderApp(allocator, template, registry.get(.rest));
    defer allocator.free(rest);
    try std.testing.expect(std.mem.indexOf(u8, rest, "After=network-online.target doctbase-pgbouncer.service doctbase-pg-meta.service") != null);

    const realtime = try units.renderApp(allocator, template, registry.get(.realtime));
    defer allocator.free(realtime);
    try std.testing.expect(std.mem.indexOf(u8, realtime, "doctbase-auth.service") != null);

    const image_proxy = try units.renderApp(allocator, template, registry.get(.image_proxy));
    defer allocator.free(image_proxy);
    try std.testing.expect(std.mem.indexOf(u8, image_proxy, "doctbase-storage.service") != null);

    const gateway = try units.renderApp(allocator, template, registry.get(.gateway));
    defer allocator.free(gateway);
    const after = lineContaining(gateway, "After=").?;
    try std.testing.expectEqualStrings("After=network-online.target doctbase-pgbouncer.service", after);
}

test "only the management plane can read the system journal" {
    const allocator = std.testing.allocator;
    const template = try readFile(allocator, units.app_template_path);
    defer allocator.free(template);

    const management = try units.renderApp(allocator, template, registry.get(.management));
    defer allocator.free(management);
    try std.testing.expect(std.mem.indexOf(u8, management, "SupplementaryGroups=systemd-journal") != null);
    try std.testing.expect(std.mem.indexOf(u8, management, "ReadWritePaths=/run/doctbase /var/lib/doctbase/projects /var/lib/doctbase/control /etc/doctbase/generated") != null);
    try std.testing.expect(std.mem.indexOf(u8, management, "LoadCredential=admin_setup_token:/etc/doctbase/secrets/admin_setup_token") != null);

    const gateway = try units.renderApp(allocator, template, registry.get(.gateway));
    defer allocator.free(gateway);
    try std.testing.expect(std.mem.indexOf(u8, gateway, "SupplementaryGroups=") == null);
    try std.testing.expect(std.mem.indexOf(u8, gateway, "admin_setup_token") == null);
}

test "writable paths are scoped to each service" {
    const allocator = std.testing.allocator;
    const template = try readFile(allocator, units.app_template_path);
    defer allocator.free(template);

    const expected = [_]struct {
        key: registry.ServiceKey,
        path: []const u8,
    }{
        .{ .key = .auth, .path = "/var/lib/doctbase/auth" },
        .{ .key = .storage, .path = "/var/lib/doctbase/projects" },
        .{ .key = .image_proxy, .path = "/var/lib/doctbase/cache" },
    };

    for (expected) |item| {
        const contents = try units.renderApp(allocator, template, registry.get(item.key));
        defer allocator.free(contents);
        try std.testing.expect(std.mem.indexOf(u8, contents, item.path) != null);
    }
}

test "target aggregates core and infrastructure units but not optional services" {
    const allocator = std.testing.allocator;
    const template = try readFile(allocator, units.target_template_path);
    defer allocator.free(template);

    const contents = try units.renderTarget(allocator, template);
    defer allocator.free(contents);

    try std.testing.expect(std.mem.indexOf(u8, contents, "Installed to /etc/systemd/system/doctbase.target") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "WantedBy=multi-user.target") != null);

    const wants = lineContaining(contents, "Wants=").?;
    for (registry.specs()) |spec| {
        const unit = spec.unit_name orelse continue;
        if (spec.optional) {
            try std.testing.expect(std.mem.indexOf(u8, wants, unit) == null);
        } else {
            try std.testing.expect(std.mem.indexOf(u8, wants, unit) != null);
        }
    }

    try std.testing.expect(std.mem.indexOf(u8, contents, "doctbase-rest.service") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "doctbase-realtime.service") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "doctbase-image-proxy.service") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "@CORE_UNITS@") == null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "@INFRA_UNITS@") == null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "@OPTIONAL_UNITS@") == null);
}

test "unit and target install paths are inside /etc/systemd/system" {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("/etc/systemd/system/doctbase-auth.service", try units.unitPath(&buffer, "doctbase-auth.service"));
    try std.testing.expectEqualStrings("/etc/systemd/system/doctbase.target", try units.targetPath(&buffer));
}

test "polkit allowlist is narrow, explicit and excludes infrastructure" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqualStrings("/etc/polkit-1/rules.d/50-doctbase.rules", units.polkit_install_path);
    const rule = try readFile(allocator, units.polkit_path);
    defer allocator.free(rule);

    try std.testing.expect(std.mem.indexOf(u8, rule, "subject.user !== \"doctbase-management\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rule, "subject.isInGroup(\"doctbase\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, rule, "org.freedesktop.systemd1.manage-units") != null);
    try std.testing.expect(std.mem.indexOf(u8, rule, "org.freedesktop.systemd1.manage-unit-files") != null);
    try std.testing.expect(std.mem.indexOf(u8, rule, "\"start\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rule, "\"restart\"") != null);

    for (registry.specs()) |spec| {
        const unit = spec.unit_name orelse continue;
        const quoted = try std.fmt.allocPrint(allocator, "\"{s}\"", .{unit});
        defer allocator.free(quoted);
        if (spec.kind == .app) {
            try std.testing.expect(std.mem.indexOf(u8, rule, quoted) != null);
        } else {
            try std.testing.expect(std.mem.indexOf(u8, rule, quoted) == null);
        }
    }

    // No wildcard unit match and no actions on the system bus as a whole.
    try std.testing.expect(std.mem.indexOf(u8, rule, "\"*\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, rule, "org.freedesktop.systemd1.manage-units\": [\"*\"]") == null);
}
