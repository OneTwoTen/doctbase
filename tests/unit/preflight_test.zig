const std = @import("std");
const builtin = @import("builtin");
const preflight = @import("preflight");

const gib: u64 = 1024 * 1024 * 1024;

fn supportedFacts() preflight.Facts {
    return .{
        .distro_id = "ubuntu",
        .version_id = "24.04",
        .architecture = "x86_64",
        .memory_bytes = 2 * gib,
        .available_disk_bytes = 20 * gib,
    };
}

fn hasCode(report: preflight.Report, code: preflight.Code) bool {
    for (report.findings[0..report.count]) |finding| {
        if (finding.code == code) return true;
    }
    return false;
}

test "supported Ubuntu and Debian hosts meet the install baseline" {
    var facts = supportedFacts();
    var report = preflight.evaluate(facts);
    try std.testing.expectEqual(preflight.Status.ready, report.status());
    try std.testing.expectEqual(@as(usize, 0), report.count);

    facts.distro_id = "debian";
    facts.version_id = "13";
    facts.architecture = "aarch64";
    report = preflight.evaluate(facts);
    try std.testing.expectEqual(preflight.Status.ready, report.status());

    facts.distro_id = "ubuntu";
    facts.version_id = "26.04";
    try std.testing.expectEqual(preflight.Status.ready, preflight.evaluate(facts).status());
}

test "unsupported operating systems and architectures block installation" {
    var facts = supportedFacts();
    facts.distro_id = "fedora";
    facts.architecture = "riscv64";
    const report = preflight.evaluate(facts);

    try std.testing.expectEqual(preflight.Status.blocked, report.status());
    try std.testing.expect(hasCode(report, .unsupported_os));
    try std.testing.expect(hasCode(report, .unsupported_architecture));
}

test "insufficient memory and disk produce actionable blockers" {
    var facts = supportedFacts();
    facts.memory_bytes = 2 * gib - 1;
    facts.available_disk_bytes = 20 * gib - 1;
    const report = preflight.evaluate(facts);

    try std.testing.expectEqual(preflight.Status.blocked, report.status());
    try std.testing.expect(hasCode(report, .insufficient_memory));
    try std.testing.expect(hasCode(report, .insufficient_disk_space));
    for (report.findings[0..report.count]) |finding| {
        try std.testing.expect(finding.fix().len > 0);
        var url: [160]u8 = undefined;
        try std.testing.expect(std.mem.startsWith(u8, try finding.docsUrl(&url), "https://doctbase.dev/docs/"));
    }
}

test "existing PostgreSQL on 5432 is preserved while an occupied HTTP port blocks install" {
    var facts = supportedFacts();
    facts.listeners = &.{
        .{ .port = 5432, .service = "postgresql.service" },
        .{ .port = 443, .service = "nginx.service" },
        .{ .port = 443, .service = "nginx.service" },
    };
    const report = preflight.evaluate(facts);

    try std.testing.expectEqual(preflight.Status.blocked, report.status());
    try std.testing.expectEqual(@as(usize, 1), report.count);
    try std.testing.expectEqual(preflight.Code.http_port_in_use, report.findings[0].code);
    try std.testing.expectEqual(@as(?u16, 443), report.findings[0].port);
    try std.testing.expectEqualStrings("nginx.service", report.findings[0].service.?);
}

test "domain DNS problems warn without blocking local installation" {
    var facts = supportedFacts();
    facts.domain = "api.example.test";
    facts.dns_status = .unresolved;
    const report = preflight.evaluate(facts);

    try std.testing.expectEqual(preflight.Status.warning, report.status());
    try std.testing.expect(!report.isBlocked());
    try std.testing.expect(hasCode(report, .domain_dns_unresolved));

    facts.domain = null;
    facts.dns_status = .not_checked;
    const local_report = preflight.evaluate(facts);
    try std.testing.expectEqual(preflight.Status.ready, local_report.status());

    facts.domain = "api.example.test";
    facts.dns_status = .unavailable;
    try std.testing.expectEqual(preflight.Status.warning, preflight.evaluate(facts).status());
}

test "Doctbase-owned listeners are allowed during an idempotent reinstall" {
    var facts = supportedFacts();
    facts.listeners = &.{
        .{ .port = 80, .service = "doctbase-caddy.service", .managed_by_doctbase = true },
        .{ .port = 443, .service = "doctbase-caddy.service", .managed_by_doctbase = true },
    };
    const report = preflight.evaluate(facts);

    try std.testing.expectEqual(preflight.Status.ready, report.status());
    try std.testing.expect(!report.isBlocked());
}

test "host probe failures are explicit blockers instead of fake low resource values" {
    var facts = supportedFacts();
    facts.os_release_available = false;
    facts.memory_probe_available = false;
    facts.disk_probe_available = false;
    facts.listener_probe_available = false;
    const report = preflight.evaluate(facts);

    try std.testing.expectEqual(preflight.Status.blocked, report.status());
    try std.testing.expect(hasCode(report, .os_release_unavailable));
    try std.testing.expect(hasCode(report, .memory_probe_unavailable));
    try std.testing.expect(hasCode(report, .disk_probe_unavailable));
    try std.testing.expect(hasCode(report, .listener_probe_unavailable));
    try std.testing.expect(!hasCode(report, .unsupported_os));
    try std.testing.expect(!hasCode(report, .insufficient_memory));
    try std.testing.expect(!hasCode(report, .insufficient_disk_space));
}

test "native collector reports unsupported host platforms directly" {
    var facts = supportedFacts();
    facts.collection_supported = false;

    const report = preflight.evaluate(facts);
    try std.testing.expectEqual(preflight.Status.blocked, report.status());
    try std.testing.expectEqual(@as(usize, 1), report.count);
    try std.testing.expectEqual(preflight.Code.host_collection_unsupported, report.findings[0].code);
}

test "os-release parsing reads values without evaluating shell syntax" {
    const release = preflight.parseOsRelease(
        "NAME=\"Ubuntu\"\n" ++
            "ID=ubuntu\n" ++
            "VERSION_ID=\"24.04\"\n" ++
            "PRETTY_NAME=\"Ubuntu $(touch /tmp/should-not-run)\"\n" ++
            "# comment\n",
    );

    try std.testing.expectEqualStrings("ubuntu", release.id);
    try std.testing.expectEqualStrings("24.04", release.version_id);
}

test "memory and disk parsers convert Linux kilobytes to bytes" {
    try std.testing.expectEqual(@as(?u64, 2 * gib), preflight.parseMemTotal(
        "MemFree:         120000 kB\nMemTotal:       2097152 kB\n",
    ));
    try std.testing.expectEqual(@as(?u64, 20 * gib), preflight.parseDfAvailable("Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/sda1 41943040 1000 20971520 1% /\n"));
    try std.testing.expectEqual(@as(?u64, null), preflight.parseDfAvailable("Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/sda1 41943040 1000 unknown 1% /\n"));
}

test "proc tcp parser reports only listeners and marks validated owned ports" {
    const tcp =
        "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n" ++
        "   0: 00000000:0050 00000000:0000 0A 00000000:00000000 00:00000000 00000000 0 0 42\n" ++
        "   1: 00000000:01BB 00000000:0000 01 00000000:00000000 00:00000000 00000000 0 0 43\n" ++
        "   2: 00000000:15B3 00000000:0000 0A 00000000:00000000 00:00000000 00000000 0 0 44\n";
    const listeners = try preflight.parseProcNetTcp(std.testing.allocator, tcp, &.{80});
    defer std.testing.allocator.free(listeners);

    try std.testing.expectEqual(@as(usize, 2), listeners.len);
    try std.testing.expectEqual(@as(u16, 80), listeners[0].port);
    try std.testing.expect(listeners[0].managed_by_doctbase);
    try std.testing.expectEqual(@as(u16, 5555), listeners[1].port);
    try std.testing.expect(!listeners[1].managed_by_doctbase);
}

test "live host collection is guarded to Linux" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var snapshot = try preflight.collect(std.testing.allocator, std.testing.io, .{});
    defer snapshot.deinit();

    try std.testing.expect(snapshot.facts.collection_supported);
    try std.testing.expect(snapshot.facts.os_release_available);
    try std.testing.expect(snapshot.facts.memory_probe_available);
}
