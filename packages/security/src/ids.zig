const std = @import("std");

const CROCKFORD_BASE32 = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

pub fn generateUlid(io: std.Io, timestamp_ms: i64) [26]u8 {
    var out: [26]u8 = undefined;

    // 48-bit timestamp -> 10 chars
    var ts: u64 = if (timestamp_ms < 0) 0 else @intCast(timestamp_ms);
    ts &= 0x0000FFFFFFFFFFFF;

    var i: usize = 10;
    while (i > 0) {
        i -= 1;
        out[i] = CROCKFORD_BASE32[@intCast(ts & 0x1F)];
        ts >>= 5;
    }

    // 80-bit randomness -> 16 chars
    var rand_bytes: [10]u8 = undefined;
    io.random(&rand_bytes);

    var rand_val: u128 = 0;
    for (rand_bytes) |b| {
        rand_val = (rand_val << 8) | b;
    }

    var j: usize = 26;
    while (j > 10) {
        j -= 1;
        out[j] = CROCKFORD_BASE32[@intCast(rand_val & 0x1F)];
        rand_val >>= 5;
    }

    return out;
}

pub fn extractTimestamp(ulid: [26]u8) ?u64 {
    var ts: u64 = 0;
    for (ulid[0..10]) |c| {
        const val = decodeChar(c) orelse return null;
        ts = (ts << 5) | val;
    }
    return ts;
}

fn decodeChar(c: u8) ?u5 {
    return switch (c) {
        '0', 'O', 'o' => 0,
        '1', 'I', 'i', 'L', 'l' => 1,
        '2' => 2,
        '3' => 3,
        '4' => 4,
        '5' => 5,
        '6' => 6,
        '7' => 7,
        '8' => 8,
        '9' => 9,
        'A', 'a' => 10,
        'B', 'b' => 11,
        'C', 'c' => 12,
        'D', 'd' => 13,
        'E', 'e' => 14,
        'F', 'f' => 15,
        'G', 'g' => 16,
        'H', 'h' => 17,
        'J', 'j' => 18,
        'K', 'k' => 19,
        'M', 'm' => 20,
        'N', 'n' => 21,
        'P', 'p' => 22,
        'Q', 'q' => 23,
        'R', 'r' => 24,
        'S', 's' => 25,
        'T', 't' => 26,
        'V', 'v' => 27,
        'W', 'w' => 28,
        'X', 'x' => 29,
        'Y', 'y' => 30,
        'Z', 'z' => 31,
        else => null,
    };
}

test "generate and decode ulid timestamp" {
    const io = std.testing.io;
    const ts: i64 = 1714500000000;
    const ulid = generateUlid(io, ts);

    try std.testing.expectEqual(@as(usize, 26), ulid.len);
    const decoded_ts = extractTimestamp(ulid);
    try std.testing.expect(decoded_ts != null);
    try std.testing.expectEqual(@as(u64, @intCast(ts)), decoded_ts.?);
}
