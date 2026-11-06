pub const secrets = @import("secrets.zig");
pub const password = @import("password.zig");
pub const ids = @import("ids.zig");

test {
    _ = secrets;
    _ = password;
    _ = ids;
}
