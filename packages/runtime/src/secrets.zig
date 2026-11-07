const std = @import("std");

pub const CredentialLoader = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: ?*const std.process.Environ.Map,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, environ: ?*const std.process.Environ.Map) CredentialLoader {
        return .{
            .allocator = allocator,
            .io = io,
            .environ = environ,
        };
    }

    /// Load secret from systemd credentials directory ($CREDENTIALS_DIRECTORY/<name>),
    /// or falling back to environment variable (<NAME>), or null.
    pub fn loadCredential(self: CredentialLoader, name: []const u8) ?[]const u8 {
        // 1. Try $CREDENTIALS_DIRECTORY/<name>
        if (self.environ) |env| {
            if (env.get("CREDENTIALS_DIRECTORY")) |dir| {
                const cred_path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir, name }) catch return null;
                defer self.allocator.free(cred_path);

                if (std.Io.Dir.cwd().readFileAlloc(self.io, cred_path, self.allocator, .unlimited)) |val| {
                    return std.mem.trim(u8, val, " \t\r\n");
                } else |_| {}
            }

            // 2. Fall back to environment variable
            if (env.get(name)) |val| {
                return val;
            }
        }

        return null;
    }

    /// Read a systemd credential into a caller-owned copy. Only the credentials
    /// directory is consulted: a unit that expects `LoadCredential=` must never
    /// be silently satisfied by a different environment variable.
    pub fn loadCredentialOwned(self: CredentialLoader, name: []const u8) !?[]u8 {
        const environ = self.environ orelse return null;
        const directory = environ.get("CREDENTIALS_DIRECTORY") orelse return null;

        const credential_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ directory, name });
        defer self.allocator.free(credential_path);

        const raw = std.Io.Dir.cwd().readFileAlloc(
            self.io,
            credential_path,
            self.allocator,
            .unlimited,
        ) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.AccessDenied => return null,
            else => return err,
        };
        defer self.allocator.free(raw);

        return try self.allocator.dupe(u8, std.mem.trim(u8, raw, " \t\r\n"));
    }
};

test "credential loader falls back gracefully" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const loader = CredentialLoader.init(allocator, io, null);
    try std.testing.expectEqual(@as(?[]const u8, null), loader.loadCredential("NON_EXISTENT_KEY"));
    try std.testing.expectEqual(@as(?[]u8, null), try loader.loadCredentialOwned("internal_token"));
}

test "credential loader reads systemd credentials as an owned copy" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{
        .sub_path = "internal_token",
        .data = "  abc123\n",
    });
    const directory = blk: {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const length = try temporary.dir.realPath(io, &path_buffer);
        break :blk path_buffer[0..length];
    };

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("CREDENTIALS_DIRECTORY", directory);

    const loader = CredentialLoader.init(allocator, io, &environ);
    const value = (try loader.loadCredentialOwned("internal_token")).?;
    defer allocator.free(value);
    try std.testing.expectEqualStrings("abc123", value);
}
