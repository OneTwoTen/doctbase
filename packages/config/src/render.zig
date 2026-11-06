const std = @import("std");
const schema = @import("schema.zig");

pub const RenderedFile = struct {
    rel_path: []const u8,
    content: []u8,

    pub fn deinit(self: RenderedFile, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
    }
};

pub const RenderPipeline = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RenderPipeline {
        return .{ .allocator = allocator };
    }

    pub fn renderCaddyfile(self: RenderPipeline, config: *const schema.Config) ![]u8 {
        var buf = std.Io.Writer.Allocating.init(self.allocator);
        defer buf.deinit();

        try buf.writer.print(
            \\{{
            \\    admin "unix//run/doctbase/caddy-admin.sock"
            \\}}
            \\
            \\{s} {{
            \\    reverse_proxy unix//run/doctbase/gateway.sock
            \\}}
            \\
        , .{config.instance.domain});

        return try self.allocator.dupe(u8, buf.written());
    }

    pub fn renderPgBouncer(self: RenderPipeline, config: *const schema.Config) ![]u8 {
        var buf = std.Io.Writer.Allocating.init(self.allocator);
        defer buf.deinit();

        try buf.writer.print(
            \\[databases]
            \\* = host=/var/run/postgresql port=5433
            \\
            \\[pgbouncer]
            \\listen_addr = 127.0.0.1
            \\listen_port = 6432
            \\unix_socket_dir = /run/doctbase
            \\pool_mode = {s}
            \\max_client_conn = {d}
            \\default_pool_size = {d}
            \\
        , .{
            @tagName(config.pooler.pool_mode),
            config.pooler.max_client_conn,
            config.pooler.default_pool_size,
        });

        return try self.allocator.dupe(u8, buf.written());
    }

    pub fn renderAll(self: RenderPipeline, config: *const schema.Config) ![]RenderedFile {
        var files: std.ArrayList(RenderedFile) = .empty;
        errdefer {
            for (files.items) |f| f.deinit(self.allocator);
            files.deinit(self.allocator);
        }

        const caddy = try self.renderCaddyfile(config);
        try files.append(self.allocator, .{
            .rel_path = "caddy/Caddyfile",
            .content = caddy,
        });

        const pgbouncer = try self.renderPgBouncer(config);
        try files.append(self.allocator, .{
            .rel_path = "pgbouncer/pgbouncer.ini",
            .content = pgbouncer,
        });

        return try files.toOwnedSlice(self.allocator);
    }
};

test "render pipeline produces caddy and pgbouncer configs" {
    const allocator = std.testing.allocator;
    const defaults = @import("defaults.zig");
    var cfg = defaults.defaultConfig(allocator);
    defer cfg.deinit();

    const pipeline = RenderPipeline.init(allocator);
    const files = try pipeline.renderAll(&cfg);
    defer {
        for (files) |f| f.deinit(allocator);
        allocator.free(files);
    }

    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expect(std.mem.indexOf(u8, files[0].content, "reverse_proxy unix//run/doctbase/gateway.sock") != null);
    try std.testing.expect(std.mem.indexOf(u8, files[1].content, "pool_mode = transaction") != null);
}
