const std = @import("std");
const router_mod = @import("api/router.zig");

const max_asset_bytes = 16 * 1024 * 1024;
const max_request_path_bytes = 4096;
const test_dashboard_directory = "tests/fixtures/management-dashboard";

const reserved_namespaces = [_][]const u8{
    "/api",
    "/auth",
    "/services",
    "/setup",
    "/healthz",
    "/readyz",
    "/metrics",
    "/internal",
};

pub fn serve(
    allocator: std.mem.Allocator,
    io: std.Io,
    dashboard_directory: []const u8,
    method: []const u8,
    request_path: []const u8,
    accept: ?[]const u8,
) !?router_mod.HttpResponse {
    const is_head = std.mem.eql(u8, method, "HEAD");
    if (!is_head and !std.mem.eql(u8, method, "GET")) return null;
    if (isReservedPath(request_path)) return null;

    const relative_path = safeRelativePath(request_path) orelse return null;
    const is_root = relative_path.len == 0;

    if (!is_root) {
        if (try responseForAsset(allocator, io, dashboard_directory, relative_path, is_head)) |response| {
            return response;
        }
        if (hasExtension(relative_path) or !acceptsHtml(accept)) return null;
    }

    return responseForAsset(allocator, io, dashboard_directory, "index.html", is_head);
}

fn responseForAsset(
    allocator: std.mem.Allocator,
    io: std.Io,
    dashboard_directory: []const u8,
    relative_path: []const u8,
    is_head: bool,
) !?router_mod.HttpResponse {
    const body = try readAsset(allocator, io, dashboard_directory, relative_path) orelse return null;
    if (is_head) {
        allocator.free(body);
        return .{
            .status = 200,
            .content_type = contentType(relative_path),
            .body = try allocator.alloc(u8, 0),
        };
    }

    return .{
        .status = 200,
        .content_type = contentType(relative_path),
        .body = body,
    };
}

fn readAsset(
    allocator: std.mem.Allocator,
    io: std.Io,
    dashboard_directory: []const u8,
    relative_path: []const u8,
) !?[]u8 {
    const separator: []const u8 = if (dashboard_directory.len > 0 and (dashboard_directory[dashboard_directory.len - 1] == '/' or dashboard_directory[dashboard_directory.len - 1] == '\\')) "" else "/";
    const full_path = try std.mem.concat(allocator, u8, &.{ dashboard_directory, separator, relative_path });
    defer allocator.free(full_path);

    return std.Io.Dir.cwd().readFileAlloc(io, full_path, allocator, .limited(max_asset_bytes)) catch |err| switch (err) {
        error.FileNotFound => null,
        error.IsDir => null,
        else => return err,
    };
}

fn safeRelativePath(request_path: []const u8) ?[]const u8 {
    if (request_path.len == 0 or request_path[0] != '/' or request_path.len > max_request_path_bytes) return null;
    if (request_path.len == 1) return request_path[1..];
    if (request_path[1] == '/') return null;

    var relative_path = request_path[1..];
    if (relative_path[relative_path.len - 1] == '/') {
        relative_path = relative_path[0 .. relative_path.len - 1];
    }
    if (std.mem.indexOfAny(u8, relative_path, "\\%:\x00") != null) return null;

    var segments = std.mem.splitScalar(u8, relative_path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return null;
        for (segment) |byte| {
            if (byte < 0x20 or byte == 0x7f) return null;
        }
    }

    return relative_path;
}

fn isReservedPath(request_path: []const u8) bool {
    for (reserved_namespaces) |namespace| {
        if (std.mem.eql(u8, request_path, namespace)) return true;
        if (std.mem.startsWith(u8, request_path, namespace) and request_path.len > namespace.len and request_path[namespace.len] == '/') return true;
    }
    return false;
}

fn hasExtension(path: []const u8) bool {
    const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |separator| path[separator + 1 ..] else path;
    return std.mem.indexOfScalar(u8, basename, '.') != null;
}

fn acceptsHtml(accept: ?[]const u8) bool {
    const header = accept orelse return false;
    return containsIgnoreCase(header, "text/html") or containsIgnoreCase(header, "application/xhtml+xml");
}

fn containsIgnoreCase(value: []const u8, needle: []const u8) bool {
    if (needle.len > value.len) return false;
    for (0..value.len - needle.len + 1) |start| {
        if (std.ascii.eqlIgnoreCase(value[start .. start + needle.len], needle)) return true;
    }
    return false;
}

fn contentType(path: []const u8) []const u8 {
    const extension_start = std.mem.lastIndexOfScalar(u8, path, '.') orelse return "application/octet-stream";
    const extension = path[extension_start..];
    if (std.ascii.eqlIgnoreCase(extension, ".html")) return "text/html; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(extension, ".css")) return "text/css; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(extension, ".js") or std.ascii.eqlIgnoreCase(extension, ".mjs")) return "text/javascript; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(extension, ".json") or std.ascii.eqlIgnoreCase(extension, ".map")) return "application/json";
    if (std.ascii.eqlIgnoreCase(extension, ".svg")) return "image/svg+xml";
    if (std.ascii.eqlIgnoreCase(extension, ".png")) return "image/png";
    if (std.ascii.eqlIgnoreCase(extension, ".jpg") or std.ascii.eqlIgnoreCase(extension, ".jpeg")) return "image/jpeg";
    if (std.ascii.eqlIgnoreCase(extension, ".gif")) return "image/gif";
    if (std.ascii.eqlIgnoreCase(extension, ".webp")) return "image/webp";
    if (std.ascii.eqlIgnoreCase(extension, ".avif")) return "image/avif";
    if (std.ascii.eqlIgnoreCase(extension, ".ico")) return "image/x-icon";
    if (std.ascii.eqlIgnoreCase(extension, ".woff")) return "font/woff";
    if (std.ascii.eqlIgnoreCase(extension, ".woff2")) return "font/woff2";
    if (std.ascii.eqlIgnoreCase(extension, ".ttf")) return "font/ttf";
    if (std.ascii.eqlIgnoreCase(extension, ".txt")) return "text/plain; charset=utf-8";
    return "application/octet-stream";
}

test "dashboard serves root and static assets with MIME types" {
    const root = (try serve(std.testing.allocator, std.testing.io, test_dashboard_directory, "GET", "/", null)) orelse return error.TestUnexpectedResult;
    defer root.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), root.status);
    try std.testing.expectEqualStrings("text/html; charset=utf-8", root.content_type);
    try std.testing.expectEqualStrings("dashboard fixture\n", root.body);

    const asset = (try serve(std.testing.allocator, std.testing.io, test_dashboard_directory, "GET", "/assets/app.js", null)) orelse return error.TestUnexpectedResult;
    defer asset.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("text/javascript; charset=utf-8", asset.content_type);
    try std.testing.expectEqualStrings("export const dashboard = true;\n", asset.body);
}

test "dashboard falls back only for browser routes without file extensions" {
    const route = (try serve(std.testing.allocator, std.testing.io, test_dashboard_directory, "GET", "/ui/projects/123", "text/html,application/xhtml+xml")) orelse return error.TestUnexpectedResult;
    defer route.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("dashboard fixture\n", route.body);

    try std.testing.expect((try serve(std.testing.allocator, std.testing.io, test_dashboard_directory, "GET", "/ui/missing.js", "text/html")) == null);
    try std.testing.expect((try serve(std.testing.allocator, std.testing.io, test_dashboard_directory, "GET", "/ui/projects/123", "application/json")) == null);
}

test "dashboard never falls back for API or operational paths" {
    const paths = [_][]const u8{
        "/api",
        "/api/v1/missing",
        "/auth/login",
        "/services/missing",
        "/setup/status",
        "/healthz",
        "/readyz",
        "/metrics",
        "/internal/v1/info",
    };
    for (paths) |path| {
        try std.testing.expect((try serve(std.testing.allocator, std.testing.io, test_dashboard_directory, "GET", path, "text/html")) == null);
    }
}

test "dashboard rejects traversal, encoded paths and unsupported methods" {
    const paths = [_][]const u8{
        "/../outside-dashboard-marker.txt",
        "/%2e%2e/outside.txt",
        "/assets\\..\\outside.txt",
        "//assets/app.js",
    };
    for (paths) |path| {
        try std.testing.expect((try serve(std.testing.allocator, std.testing.io, test_dashboard_directory, "GET", path, "text/html")) == null);
    }
    try std.testing.expect((try serve(std.testing.allocator, std.testing.io, test_dashboard_directory, "POST", "/", "text/html")) == null);
}

test "dashboard supports HEAD without returning an asset body" {
    const response = (try serve(std.testing.allocator, std.testing.io, test_dashboard_directory, "HEAD", "/", null)) orelse return error.TestUnexpectedResult;
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("text/html; charset=utf-8", response.content_type);
    try std.testing.expectEqual(@as(usize, 0), response.body.len);
}
