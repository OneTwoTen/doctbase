const std = @import("std");
const docker = @import("docker");

const Fixture = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: []u8,

    fn init() !Fixture {
        const allocator = std.testing.allocator;
        const io = std.testing.io;
        var random_bytes: [8]u8 = undefined;
        io.random(&random_bytes);

        const directory = try std.fmt.allocPrint(
            allocator,
            "/tmp/doctbase-docker-test-{d}",
            .{std.mem.readInt(u64, &random_bytes, .little)},
        );
        return .{ .allocator = allocator, .io = io, .directory = directory };
    }

    fn deinit(self: *Fixture) void {
        std.Io.Dir.cwd().deleteTree(self.io, self.directory) catch {};
        self.allocator.free(self.directory);
    }

    fn options(self: *Fixture) docker.InitOptions {
        return .{
            .profile = .docker,
            .directory = self.directory,
            .domain = "example.com",
            .email = "admin@example.com",
            .assets_root = ".",
            .version = "1.2.3",
            .image_prefix = "ghcr.io/acme",
        };
    }

    fn read(self: *Fixture, name: []const u8) ![]u8 {
        const path = try std.fs.path.join(self.allocator, &.{ self.directory, name });
        defer self.allocator.free(path);
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(256 * 1024));
    }
};

test "docker init writes a self-contained compose, Caddyfile and secret env" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    var result = try docker.init(fixture.io, fixture.allocator, fixture.options());
    defer result.deinit();

    try std.testing.expect(result.env_created);
    try std.testing.expectEqual(@as(usize, 2), result.secrets_generated);

    const compose = try fixture.read("compose.yml");
    defer fixture.allocator.free(compose);
    try std.testing.expect(std.mem.indexOf(u8, compose, "name: doctbase") != null);
    try std.testing.expect(std.mem.indexOf(u8, compose, "image: ghcr.io/acme/gateway:1.2.3") != null);
    try std.testing.expect(std.mem.indexOf(u8, compose, "image: ghcr.io/acme/management:1.2.3") != null);
    try std.testing.expect(std.mem.indexOf(u8, compose, "image: ghcr.io/acme/auth:1.2.3") != null);
    try std.testing.expect(std.mem.indexOf(u8, compose, "\"443:443\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, compose, "@") == null);

    const caddyfile = try fixture.read("Caddyfile");
    defer fixture.allocator.free(caddyfile);
    try std.testing.expect(std.mem.indexOf(u8, caddyfile, "email admin@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, caddyfile, "example.com {") != null);
    try std.testing.expect(std.mem.indexOf(u8, caddyfile, "reverse_proxy management:8081") != null);

    const env = try fixture.read(".env");
    defer fixture.allocator.free(env);
    try std.testing.expect(std.mem.indexOf(u8, env, "DOCTBASE_DATABASE_MODE=external") != null);
    try std.testing.expect(std.mem.indexOf(u8, env, "DOCTBASE_DOMAIN=example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, env, "SERVICE_PASSWORD_64_INTERNALTOKEN=") != null);
    try std.testing.expect(std.mem.indexOf(u8, env, "SERVICE_PASSWORD_64_POSTGRES=") != null);
    try std.testing.expectEqual(@as(usize, 64), secretLength(env, "SERVICE_PASSWORD_64_INTERNALTOKEN").?);
    try std.testing.expectEqual(@as(usize, 64), secretLength(env, "SERVICE_PASSWORD_64_POSTGRES").?);
}

test "docker init is idempotent and never rotates existing secrets" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    var first = try docker.init(fixture.io, fixture.allocator, fixture.options());
    defer first.deinit();
    const first_env = try fixture.read(".env");
    defer fixture.allocator.free(first_env);

    var changed = fixture.options();
    changed.domain = "other.example.com";
    changed.database = .bundled;
    var second = try docker.init(fixture.io, fixture.allocator, changed);
    defer second.deinit();

    try std.testing.expect(!second.env_created);
    try std.testing.expectEqual(@as(usize, 0), second.secrets_generated);

    const second_env = try fixture.read(".env");
    defer fixture.allocator.free(second_env);
    try std.testing.expect(std.mem.indexOf(u8, second_env, "DOCTBASE_DOMAIN=other.example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_env, "DOCTBASE_DOMAIN=example.com") == null);
    try std.testing.expect(std.mem.indexOf(u8, second_env, "DOCTBASE_DATABASE_MODE=managed") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_env, "COMPOSE_PROFILES=bundled") != null);
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(second_env, "DOCTBASE_DOMAIN="));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(second_env, "SERVICE_PASSWORD_64_INTERNALTOKEN="));
    try std.testing.expectEqualStrings(
        secretValue(first_env, "SERVICE_PASSWORD_64_INTERNALTOKEN").?,
        secretValue(second_env, "SERVICE_PASSWORD_64_INTERNALTOKEN").?,
    );
    try std.testing.expectEqualStrings(
        secretValue(first_env, "SERVICE_PASSWORD_64_POSTGRES").?,
        secretValue(second_env, "SERVICE_PASSWORD_64_POSTGRES").?,
    );

    // The generated compose artifact is refreshed from the current options.
    const compose = try fixture.read("compose.yml");
    defer fixture.allocator.free(compose);
    try std.testing.expect(std.mem.indexOf(u8, compose, "image: ghcr.io/acme/gateway:1.2.3") != null);

    // An explicit choice can switch back to an external database.
    var external = fixture.options();
    external.domain = "other.example.com";
    external.database = .external;
    var third = try docker.init(fixture.io, fixture.allocator, external);
    defer third.deinit();
    const third_env = try fixture.read(".env");
    defer fixture.allocator.free(third_env);
    try std.testing.expect(std.mem.indexOf(u8, third_env, "DOCTBASE_DATABASE_MODE=external") != null);
    try std.testing.expect(std.mem.indexOf(u8, third_env, "COMPOSE_PROFILES=") != null);
}

test "docker init bundled database selects the managed profile" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    var options = fixture.options();
    options.database = .bundled;
    options.domain = "";
    options.email = "";

    var result = try docker.init(fixture.io, fixture.allocator, options);
    defer result.deinit();

    const env = try fixture.read(".env");
    defer fixture.allocator.free(env);
    try std.testing.expect(std.mem.indexOf(u8, env, "DOCTBASE_DATABASE_MODE=managed") != null);
    try std.testing.expect(std.mem.indexOf(u8, env, "DOCTBASE_POOLER_ENABLED=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, env, "COMPOSE_PROFILES=bundled") != null);

    const caddyfile = try fixture.read("Caddyfile");
    defer fixture.allocator.free(caddyfile);
    try std.testing.expect(std.mem.indexOf(u8, caddyfile, ":80 {") != null);
    try std.testing.expect(std.mem.indexOf(u8, caddyfile, "email ") == null);
}

test "docker init dry run writes nothing and rejects unsafe input" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    var options = fixture.options();
    options.dry_run = true;
    var result = try docker.init(fixture.io, fixture.allocator, options);
    defer result.deinit();
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(fixture.io, result.compose_path, .{}),
    );

    try std.testing.expectError(
        error.NativeProfileUnsupported,
        docker.init(fixture.io, fixture.allocator, .{ .profile = .native, .directory = fixture.directory, .assets_root = "." }),
    );

    var bad_domain = fixture.options();
    bad_domain.domain = "https://example.com/path";
    try std.testing.expectError(error.InvalidDomain, docker.init(fixture.io, fixture.allocator, bad_domain));

    var bad_email = fixture.options();
    bad_email.email = "not-an-email";
    try std.testing.expectError(error.InvalidEmail, docker.init(fixture.io, fixture.allocator, bad_email));

    var bad_directory = fixture.options();
    bad_directory.directory = "/";
    try std.testing.expectError(error.InvalidDirectory, docker.init(fixture.io, fixture.allocator, bad_directory));

    var bad_version = fixture.options();
    bad_version.version = "1.2.3\nimage: evil";
    try std.testing.expectError(error.InvalidVersion, docker.init(fixture.io, fixture.allocator, bad_version));
}

const Capture = struct {
    values: std.ArrayList([]u8) = .empty,
    allocator: std.mem.Allocator,

    fn deinit(self: *Capture) void {
        for (self.values.items) |value| self.allocator.free(value);
        self.values.deinit(self.allocator);
    }

    fn runner(self: *Capture) docker.Runner {
        return .{ .context = self, .run = run };
    }

    fn run(context: ?*anyopaque, argv: []const []const u8) anyerror!bool {
        const self: *Capture = @ptrCast(@alignCast(context.?));
        var buffer = std.Io.Writer.Allocating.init(self.allocator);
        defer buffer.deinit();
        for (argv, 0..) |arg, index| {
            if (index != 0) try buffer.writer.writeByte(' ');
            try buffer.writer.writeAll(arg);
        }
        try self.values.append(self.allocator, try self.allocator.dupe(u8, buffer.written()));
        return true;
    }
};

test "docker up builds the compose command and requires an initialized directory" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    var result = try docker.init(fixture.io, fixture.allocator, fixture.options());
    defer result.deinit();

    var capture = Capture{ .allocator = fixture.allocator };
    defer capture.deinit();
    try docker.up(fixture.io, fixture.allocator, .{
        .profile = .docker,
        .directory = fixture.directory,
    }, capture.runner());

    try std.testing.expectEqual(@as(usize, 1), capture.values.items.len);
    const command = capture.values.items[0];
    try std.testing.expect(std.mem.startsWith(u8, command, "docker compose -f "));
    try std.testing.expect(std.mem.indexOf(u8, command, "--env-file") != null);
    try std.testing.expect(std.mem.endsWith(u8, command, "up -d --wait --wait-timeout 180"));

    const missing = try std.fmt.allocPrint(fixture.allocator, "{s}/missing", .{fixture.directory});
    defer fixture.allocator.free(missing);
    try std.testing.expectError(
        error.ComposeNotFound,
        docker.up(fixture.io, fixture.allocator, .{ .profile = .docker, .directory = missing }, capture.runner()),
    );
}

test "docker up dry run does not execute commands" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    var result = try docker.init(fixture.io, fixture.allocator, fixture.options());
    defer result.deinit();

    var capture = Capture{ .allocator = fixture.allocator };
    defer capture.deinit();
    try docker.up(fixture.io, fixture.allocator, .{
        .profile = .docker,
        .directory = fixture.directory,
        .dry_run = true,
    }, capture.runner());
    try std.testing.expectEqual(@as(usize, 0), capture.values.items.len);

    try docker.up(fixture.io, fixture.allocator, .{ .profile = .native, .dry_run = true }, capture.runner());
    try std.testing.expectEqual(@as(usize, 0), capture.values.items.len);
}

fn secretLength(env: []const u8, key: []const u8) ?usize {
    const value = secretValue(env, key) orelse return null;
    return value.len;
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, start, needle)) |index| {
        count += 1;
        start = index + needle.len;
    }
    return count;
}

fn secretValue(env: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, env, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, key)) continue;
        if (line.len <= key.len or line[key.len] != '=') continue;
        return line[key.len + 1 ..];
    }
    return null;
}
