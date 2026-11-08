const std = @import("std");
const uninstall = @import("uninstall");
const lifecycle = @import("service_lifecycle");

const Fake = struct {
    allocator: std.mem.Allocator,
    calls: std.ArrayList([]u8) = .empty,
    command_succeeds: bool = true,

    fn deinit(self: *Fake) void {
        for (self.calls.items) |call| self.allocator.free(call);
        self.calls.deinit(self.allocator);
    }

    fn executor(self: *Fake) uninstall.Executor {
        return .{
            .context = self,
            .running_as_root = true,
            .remove_path = removePath,
            .run = runCommand,
        };
    }

    fn fakeOf(context: ?*anyopaque) *Fake {
        return @ptrCast(@alignCast(context.?));
    }

    fn removePath(context: ?*anyopaque, path: []const u8) anyerror!void {
        const self = fakeOf(context);
        const call = try std.fmt.allocPrint(self.allocator, "remove:{s}", .{path});
        errdefer self.allocator.free(call);
        try self.calls.append(self.allocator, call);
    }

    fn runCommand(context: ?*anyopaque, argv: []const []const u8) anyerror!bool {
        const self = fakeOf(context);
        var buffer = std.Io.Writer.Allocating.init(self.allocator);
        defer buffer.deinit();
        try buffer.writer.writeAll("run:");
        for (argv, 0..) |arg, index| {
            if (index != 0) try buffer.writer.writeByte(' ');
            try buffer.writer.writeAll(arg);
        }
        const call = try self.allocator.dupe(u8, buffer.written());
        errdefer self.allocator.free(call);
        try self.calls.append(self.allocator, call);
        return self.command_succeeds;
    }

    fn find(self: *Fake, needle: []const u8) ?usize {
        for (self.calls.items, 0..) |call, index| {
            if (std.mem.indexOf(u8, call, needle) != null) return index;
        }
        return null;
    }

    fn has(self: *Fake, needle: []const u8) bool {
        return self.find(needle) != null;
    }

    fn hasExact(self: *Fake, call: []const u8) bool {
        for (self.calls.items) |recorded| {
            if (std.mem.eql(u8, recorded, call)) return true;
        }
        return false;
    }

    fn count(self: *Fake, prefix: []const u8) usize {
        var total: usize = 0;
        for (self.calls.items) |call| {
            if (std.mem.startsWith(u8, call, prefix)) total += 1;
        }
        return total;
    }
};

test "confirmation policy never lets --yes bypass a typed purge" {
    try std.testing.expect(uninstall.confirmationFor(.keep_data, true) == null);
    try std.testing.expectEqual(uninstall.Confirmation.simple, uninstall.confirmationFor(.keep_data, false).?);
    try std.testing.expectEqual(uninstall.Confirmation.typed_purge, uninstall.confirmationFor(.purge, true).?);
    try std.testing.expectEqual(uninstall.Confirmation.typed_purge, uninstall.confirmationFor(.purge, false).?);

    try std.testing.expect(uninstall.confirmationAccepted(.simple, "y"));
    try std.testing.expect(uninstall.confirmationAccepted(.simple, " YES \n"));
    try std.testing.expect(!uninstall.confirmationAccepted(.simple, ""));
    try std.testing.expect(!uninstall.confirmationAccepted(.simple, "n"));

    try std.testing.expect(uninstall.confirmationAccepted(.typed_purge, "purge"));
    try std.testing.expect(uninstall.confirmationAccepted(.typed_purge, " purge\r\n"));
    try std.testing.expect(!uninstall.confirmationAccepted(.typed_purge, "PURGE"));
    try std.testing.expect(!uninstall.confirmationAccepted(.typed_purge, "yes"));
}

test "keep-data uninstall removes services, binaries and generated files but keeps configuration and data" {
    const allocator = std.testing.allocator;
    var fake = Fake{ .allocator = allocator };
    defer fake.deinit();

    try uninstall.run(allocator, .{
        .mode = .keep_data,
        .assume_yes = true,
    }, fake.executor());

    try std.testing.expect(fake.has("remove:/usr/local/lib/doctbase"));
    try std.testing.expect(fake.has("remove:/etc/doctbase/generated"));
    try std.testing.expect(fake.has("remove:/etc/systemd/system/doctbase.target"));
    try std.testing.expect(fake.has("remove:/etc/systemd/system/doctbase-gateway.service"));
    try std.testing.expect(fake.has("remove:/etc/polkit-1/rules.d/50-doctbase.rules"));
    try std.testing.expect(fake.has("run:systemctl disable --now doctbase.target"));
    try std.testing.expect(fake.has("run:systemctl daemon-reload"));

    try std.testing.expect(!fake.hasExact("remove:/etc/doctbase"));
    try std.testing.expect(!fake.hasExact("remove:/var/lib/doctbase"));
    try std.testing.expect(!fake.has("run:pg_dropcluster"));
    try std.testing.expect(!fake.has("run:userdel"));
    try std.testing.expect(!fake.has("run:groupdel"));
    try std.testing.expect(!fake.has("remove:/etc/postgresql/18/doctbase"));
}

test "purge stops the cluster before dropping it and removes accounts after data" {
    const allocator = std.testing.allocator;
    var fake = Fake{ .allocator = allocator };
    defer fake.deinit();

    try uninstall.run(allocator, .{
        .mode = .purge,
        .assume_yes = true,
        .confirmation = "purge",
    }, fake.executor());

    const stop_index = fake.find("run:systemctl stop postgresql@18-doctbase.service") orelse return error.TestExpectedStop;
    const drop_index = fake.find("run:pg_dropcluster --stop 18 doctbase") orelse return error.TestExpectedDrop;
    try std.testing.expect(stop_index < drop_index);

    try std.testing.expect(fake.hasExact("remove:/etc/doctbase"));
    try std.testing.expect(fake.hasExact("remove:/var/lib/doctbase"));
    try std.testing.expect(fake.hasExact("remove:/var/log/doctbase"));
    try std.testing.expect(fake.has("remove:/etc/postgresql/18/doctbase"));
    try std.testing.expect(fake.has("remove:/var/lib/postgresql/18/doctbase"));
    try std.testing.expect(fake.has("run:userdel doctbase-gateway"));
    try std.testing.expect(fake.has("run:userdel doctbase-backup"));

    const first_user = fake.find("run:userdel") orelse return error.TestExpectedUser;
    const remove_data = fake.find("remove:/var/lib/doctbase") orelse return error.TestExpectedData;
    const group = fake.find("run:groupdel doctbase") orelse return error.TestExpectedGroup;
    try std.testing.expect(remove_data < first_user);
    try std.testing.expect(first_user < group);
}

test "dry run, missing confirmation and non-root never mutate the host" {
    const allocator = std.testing.allocator;

    {
        var fake = Fake{ .allocator = allocator };
        defer fake.deinit();
        try uninstall.run(allocator, .{ .mode = .purge, .dry_run = true }, .{
            .context = &fake,
            .running_as_root = false,
            .remove_path = Fake.removePath,
            .run = Fake.runCommand,
        });
        try std.testing.expectEqual(@as(usize, 0), fake.calls.items.len);
    }

    {
        var fake = Fake{ .allocator = allocator };
        defer fake.deinit();
        try std.testing.expectError(
            error.ConfirmationRequired,
            uninstall.run(allocator, .{ .mode = .keep_data }, fake.executor()),
        );
        try std.testing.expectEqual(@as(usize, 0), fake.calls.items.len);
    }

    {
        var fake = Fake{ .allocator = allocator };
        defer fake.deinit();
        try std.testing.expectError(
            error.RootPrivilegesRequired,
            uninstall.run(allocator, .{ .mode = .keep_data, .assume_yes = true }, .{
                .context = &fake,
                .running_as_root = false,
                .remove_path = Fake.removePath,
                .run = Fake.runCommand,
            }),
        );
        try std.testing.expectEqual(@as(usize, 0), fake.calls.items.len);
    }

    {
        var fake = Fake{ .allocator = allocator };
        defer fake.deinit();
        try std.testing.expectError(
            error.ConfirmationMismatch,
            uninstall.run(allocator, .{
                .mode = .purge,
                .assume_yes = true,
                .confirmation = "yes",
            }, fake.executor()),
        );
        try std.testing.expectEqual(@as(usize, 0), fake.calls.items.len);
    }
}

test "failed system commands do not abort remaining cleanup" {
    const allocator = std.testing.allocator;
    var fake = Fake{ .allocator = allocator, .command_succeeds = false };
    defer fake.deinit();

    try uninstall.run(allocator, .{ .mode = .keep_data, .assume_yes = true }, fake.executor());

    try std.testing.expect(fake.has("remove:/usr/local/lib/doctbase"));
    try std.testing.expect(fake.has("run:systemctl daemon-reload"));
}

test "every removal path is absolute, explicit and inside the Doctbase allowlist" {
    const allocator = std.testing.allocator;
    var fake = Fake{ .allocator = allocator };
    defer fake.deinit();

    try uninstall.run(allocator, .{
        .mode = .purge,
        .assume_yes = true,
        .confirmation = "purge",
    }, fake.executor());

    const allowed = [_][]const u8{
        "/etc/doctbase",
        "/etc/systemd/system/",
        "/etc/polkit-1/rules.d/50-doctbase.rules",
        "/etc/tmpfiles.d/doctbase.conf",
        "/usr/local/lib/doctbase",
        "/var/lib/doctbase",
        "/var/log/doctbase",
        "/run/doctbase",
        "/etc/postgresql/18/doctbase",
        "/var/lib/postgresql/18/doctbase",
    };

    for (fake.calls.items) |call| {
        if (!std.mem.startsWith(u8, call, "remove:")) continue;
        const path = call["remove:".len..];
        try std.testing.expect(std.fs.path.isAbsolute(path));
        try std.testing.expect(std.mem.indexOf(u8, path, "..") == null);
        try std.testing.expect(std.mem.indexOfAny(u8, path, "*?[") == null);

        var accepted = false;
        for (allowed) |prefix| {
            if (std.mem.startsWith(u8, path, prefix)) {
                accepted = true;
                break;
            }
        }
        try std.testing.expect(accepted);
    }

    // One unit file per application service plus pgbouncer/caddy and the target;
    // the PostgreSQL cluster instance unit is owned by postgresql-common.
    var expected_units: usize = 1;
    for (lifecycle.registry.specs()) |spec| {
        if (spec.key != .postgresql and spec.unit_name != null) expected_units += 1;
    }
    try std.testing.expectEqual(expected_units, fake.count("remove:/etc/systemd/system/doctbase"));
}
