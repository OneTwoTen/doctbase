const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    boolean: bool,
    string_array: []const []const u8,
};

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    values: std.StringHashMapUnmanaged(Value) = .empty,

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn get(self: *const Document, key: []const u8) ?Value {
        return self.values.get(key);
    }
};

pub const ParseError = error{
    InvalidSyntax,
    InvalidValue,
    DuplicateKey,
    OutOfMemory,
};

/// Parses the TOML subset needed by the instance configuration:
/// top-level key/value pairs, `[section]` headers, strings, integers,
/// booleans and single-line string arrays. Unknown keys are preserved so
/// the schema layer can reject them with a useful message.
pub fn parse(allocator: Allocator, source: []const u8) ParseError!Document {
    var document = Document{
        .arena = std.heap.ArenaAllocator.init(allocator),
    };
    errdefer document.deinit();
    const arena = document.arena.allocator();

    var section: []const u8 = "";
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const without_comment = stripComment(raw_line);
        const line = std.mem.trim(u8, without_comment, " \t\r");
        if (line.len == 0) continue;

        if (line[0] == '[') {
            if (line.len < 3 or line[line.len - 1] != ']') return error.InvalidSyntax;
            section = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            if (section.len == 0) return error.InvalidSyntax;
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidSyntax;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const raw_value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (key.len == 0 or raw_value.len == 0) return error.InvalidSyntax;

        const full_key = if (section.len == 0)
            try arena.dupe(u8, key)
        else
            try std.fmt.allocPrint(arena, "{s}.{s}", .{ section, key });

        if (document.values.contains(full_key)) return error.DuplicateKey;

        const value = try parseValue(arena, raw_value);
        try document.values.put(arena, full_key, value);
    }

    return document;
}

fn stripComment(line: []const u8) []const u8 {
    var in_string = false;
    var escaped = false;
    for (line, 0..) |ch, index| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (in_string and ch == '\\') {
            escaped = true;
            continue;
        }
        if (ch == '"') {
            in_string = !in_string;
            continue;
        }
        if (ch == '#' and !in_string) return line[0..index];
    }
    return line;
}

fn parseValue(arena: Allocator, raw: []const u8) ParseError!Value {
    if (raw.len == 0) return error.InvalidValue;

    if (raw[0] == '"') {
        return .{ .string = try parseString(arena, raw) };
    }

    if (std.mem.eql(u8, raw, "true")) return .{ .boolean = true };
    if (std.mem.eql(u8, raw, "false")) return .{ .boolean = false };

    if (raw[0] == '[') {
        if (raw.len < 2 or raw[raw.len - 1] != ']') return error.InvalidValue;
        const inner = std.mem.trim(u8, raw[1 .. raw.len - 1], " \t\r");
        var values: std.ArrayList([]const u8) = .empty;
        if (inner.len != 0) {
            var parts = std.mem.splitScalar(u8, inner, ',');
            while (parts.next()) |part| {
                const trimmed = std.mem.trim(u8, part, " \t\r");
                if (trimmed.len < 2 or trimmed[0] != '"' or trimmed[trimmed.len - 1] != '"') {
                    return error.InvalidValue;
                }
                try values.append(arena, try parseString(arena, trimmed));
            }
        }
        return .{ .string_array = try values.toOwnedSlice(arena) };
    }

    const number = std.fmt.parseInt(i64, raw, 10) catch return error.InvalidValue;
    return .{ .integer = number };
}

fn parseString(arena: Allocator, raw: []const u8) ParseError![]const u8 {
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return error.InvalidValue;

    var out: std.ArrayList(u8) = .empty;
    var index: usize = 1;
    while (index < raw.len - 1) : (index += 1) {
        const ch = raw[index];
        if (ch != '\\') {
            try out.append(arena, ch);
            continue;
        }

        index += 1;
        if (index >= raw.len - 1) return error.InvalidValue;
        const escaped: u8 = switch (raw[index]) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            '"' => '"',
            '\\' => '\\',
            else => return error.InvalidValue,
        };
        try out.append(arena, escaped);
    }

    return try out.toOwnedSlice(arena);
}

test "parse minimal config and arrays" {
    const source =
        \\# instance configuration
        \\schema_version = 1
        \\[instance]
        \\name = "doctbase"
        \\domain = "example.com" # inline comment
        \\
        \\[security]
        \\admin_ip_allowlist = ["127.0.0.1", "10.0.0.0/8"]
    ;

    var doc = try parse(std.testing.allocator, source);
    defer doc.deinit();

    try std.testing.expectEqual(@as(i64, 1), doc.get("schema_version").?.integer);
    try std.testing.expectEqualStrings("doctbase", doc.get("instance.name").?.string);
    try std.testing.expectEqualStrings("example.com", doc.get("instance.domain").?.string);
    try std.testing.expectEqual(@as(usize, 2), doc.get("security.admin_ip_allowlist").?.string_array.len);
}

test "reject invalid and duplicate keys" {
    try std.testing.expectError(error.InvalidSyntax, parse(std.testing.allocator, "not a key"));
    try std.testing.expectError(error.DuplicateKey, parse(std.testing.allocator, "a = 1\na = 2\n"));
    try std.testing.expectError(error.InvalidValue, parse(std.testing.allocator, "a = nope\n"));
}
