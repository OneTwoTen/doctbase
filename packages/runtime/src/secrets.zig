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
};

test "credential loader falls back gracefully" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const loader = CredentialLoader.init(allocator, io, null);
    try std.testing.expectEqual(@as(?[]const u8, null), loader.loadCredential("NON_EXISTENT_KEY"));
}
