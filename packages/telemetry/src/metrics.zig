const std = @import("std");

pub const MetricType = enum {
    counter,
    gauge,
    histogram,

    pub fn label(self: MetricType) []const u8 {
        return @tagName(self);
    }
};

pub const MetricEntry = struct {
    name: []const u8,
    help: []const u8,
    type: MetricType,
    value: f64,
    labels: []const Label = &.{},
};

pub const Label = struct {
    key: []const u8,
    value: []const u8,
};

pub const MetricsRegistry = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MetricsRegistry {
        return .{ .allocator = allocator };
    }

    pub fn formatPrometheus(self: MetricsRegistry, metrics: []const MetricEntry) ![]u8 {
        var buf = std.Io.Writer.Allocating.init(self.allocator);
        defer buf.deinit();

        for (metrics) |m| {
            try buf.writer.print("# HELP {s} {s}\n", .{ m.name, m.help });
            try buf.writer.print("# TYPE {s} {s}\n", .{ m.name, m.type.label() });

            try buf.writer.print("{s}", .{m.name});
            if (m.labels.len > 0) {
                try buf.writer.writeAll("{");
                for (m.labels, 0..) |l, i| {
                    if (i > 0) try buf.writer.writeAll(",");
                    try buf.writer.print("{s}=\"{s}\"", .{ l.key, l.value });
                }
                try buf.writer.writeAll("}");
            }
            try buf.writer.print(" {d}\n", .{m.value});
        }

        return try self.allocator.dupe(u8, buf.written());
    }
};

test "formatPrometheus outputs valid exposition text" {
    const allocator = std.testing.allocator;
    const reg = MetricsRegistry.init(allocator);

    const labels = [_]Label{.{ .key = "service", .value = "gateway" }};
    const entries = [_]MetricEntry{
        .{
            .name = "http_requests_total",
            .help = "Total HTTP requests",
            .type = .counter,
            .value = 42.0,
            .labels = &labels,
        },
    };

    const text = try reg.formatPrometheus(&entries);
    defer allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "# HELP http_requests_total Total HTTP requests") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "# TYPE http_requests_total counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "http_requests_total{service=\"gateway\"} 42") != null);
}
