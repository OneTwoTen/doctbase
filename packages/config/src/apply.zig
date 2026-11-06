const std = @import("std");
const render = @import("render.zig");

pub const FileDiff = struct {
    rel_path: []const u8,
    is_new: bool,
    changed: bool,
};

pub const ApplyManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    target_dir: []const u8,
    staging_dir: []const u8,
    backup_dir: []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        target_dir: []const u8,
        staging_dir: []const u8,
        backup_dir: []const u8,
    ) ApplyManager {
        return .{
            .allocator = allocator,
            .io = io,
            .target_dir = target_dir,
            .staging_dir = staging_dir,
            .backup_dir = backup_dir,
        };
    }

    pub fn stage(self: ApplyManager, files: []const render.RenderedFile) !void {
        _ = std.Io.Dir.cwd().createDirPathStatus(self.io, self.staging_dir, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => .existed,
            else => return err,
        };

        for (files) |f| {
            const staged_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.staging_dir, f.rel_path });
            defer self.allocator.free(staged_path);

            if (std.fs.path.dirname(staged_path)) |dir| {
                _ = std.Io.Dir.cwd().createDirPathStatus(self.io, dir, .default_dir) catch |err| switch (err) {
                    error.PathAlreadyExists => .existed,
                    else => return err,
                };
            }

            const file = try std.Io.Dir.cwd().createFile(self.io, staged_path, .{ .truncate = true });
            defer file.close(self.io);
            try file.writePositionalAll(self.io, f.content, 0);
        }
    }

    pub fn computeDiff(self: ApplyManager, files: []const render.RenderedFile) ![]FileDiff {
        var diffs: std.ArrayList(FileDiff) = .empty;
        errdefer diffs.deinit(self.allocator);

        for (files) |f| {
            const target_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.target_dir, f.rel_path });
            defer self.allocator.free(target_path);

            const existing_content = std.Io.Dir.cwd().readFileAlloc(self.io, target_path, self.allocator, .unlimited) catch |err| switch (err) {
                error.FileNotFound => {
                    try diffs.append(self.allocator, .{
                        .rel_path = f.rel_path,
                        .is_new = true,
                        .changed = true,
                    });
                    continue;
                },
                else => return err,
            };
            defer self.allocator.free(existing_content);

            const changed = !std.mem.eql(u8, existing_content, f.content);
            try diffs.append(self.allocator, .{
                .rel_path = f.rel_path,
                .is_new = false,
                .changed = changed,
            });
        }

        return try diffs.toOwnedSlice(self.allocator);
    }

    pub fn apply(self: ApplyManager, files: []const render.RenderedFile) !void {
        _ = std.Io.Dir.cwd().createDirPathStatus(self.io, self.target_dir, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => .existed,
            else => return err,
        };
        _ = std.Io.Dir.cwd().createDirPathStatus(self.io, self.backup_dir, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => .existed,
            else => return err,
        };

        for (files) |f| {
            const target_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.target_dir, f.rel_path });
            defer self.allocator.free(target_path);
            const backup_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.backup_dir, f.rel_path });
            defer self.allocator.free(backup_path);

            // Backup existing if present
            if (std.Io.Dir.cwd().readFileAlloc(self.io, target_path, self.allocator, .unlimited)) |existing| {
                defer self.allocator.free(existing);
                if (std.fs.path.dirname(backup_path)) |bdir| {
                    _ = std.Io.Dir.cwd().createDirPathStatus(self.io, bdir, .default_dir) catch {};
                }
                const bfile = try std.Io.Dir.cwd().createFile(self.io, backup_path, .{ .truncate = true });
                defer bfile.close(self.io);
                try bfile.writePositionalAll(self.io, existing, 0);
            } else |_| {}

            // Write target file
            if (std.fs.path.dirname(target_path)) |tdir| {
                _ = std.Io.Dir.cwd().createDirPathStatus(self.io, tdir, .default_dir) catch {};
            }
            const tfile = try std.Io.Dir.cwd().createFile(self.io, target_path, .{ .truncate = true });
            defer tfile.close(self.io);
            try tfile.writePositionalAll(self.io, f.content, 0);
        }
    }
};

test "apply manager staging and diff" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const tmp_target = "/tmp/doctbase-test-apply-target";
    const tmp_staging = "/tmp/doctbase-test-apply-staging";
    const tmp_backup = "/tmp/doctbase-test-apply-backup";
    defer {
        std.Io.Dir.cwd().deleteTree(io, tmp_target) catch {};
        std.Io.Dir.cwd().deleteTree(io, tmp_staging) catch {};
        std.Io.Dir.cwd().deleteTree(io, tmp_backup) catch {};
    }

    const files = [_]render.RenderedFile{
        .{
            .rel_path = "test.txt",
            .content = @constCast("hello world"),
        },
    };

    const mgr = ApplyManager.init(allocator, io, tmp_target, tmp_staging, tmp_backup);
    try mgr.stage(&files);

    const diffs = try mgr.computeDiff(&files);
    defer allocator.free(diffs);

    try std.testing.expectEqual(@as(usize, 1), diffs.len);
    try std.testing.expect(diffs[0].is_new);

    try mgr.apply(&files);

    const diffs_after = try mgr.computeDiff(&files);
    defer allocator.free(diffs_after);
    try std.testing.expect(!diffs_after[0].changed);
}
