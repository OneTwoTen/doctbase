const std = @import("std");

pub const Stage = enum {
    init,
    loading_config,
    binding_sockets,
    starting_http,
    ready,
    stopping,
    stopped,
};

pub const BootstrapTracker = struct {
    current_stage: Stage = .init,

    pub fn advance(self: *BootstrapTracker, next_stage: Stage) bool {
        if (@intFromEnum(next_stage) > @intFromEnum(self.current_stage)) {
            self.current_stage = next_stage;
            return true;
        }
        return false;
    }

    pub fn isReady(self: BootstrapTracker) bool {
        return self.current_stage == .ready;
    }
};

test "bootstrap stage progression" {
    var tracker = BootstrapTracker{};
    try std.testing.expectEqual(Stage.init, tracker.current_stage);

    try std.testing.expect(tracker.advance(.loading_config));
    try std.testing.expect(tracker.advance(.binding_sockets));
    try std.testing.expect(tracker.advance(.starting_http));
    try std.testing.expect(tracker.advance(.ready));
    try std.testing.expect(tracker.isReady());

    // Cannot advance backwards
    try std.testing.expect(!tracker.advance(.init));
}
