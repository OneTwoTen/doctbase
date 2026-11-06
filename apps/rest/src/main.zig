const std = @import("std");
const runtime = @import("runtime");

pub fn main(init: std.process.Init) !void {
    try runtime.runService(init, "rest");
}
