const manifest = @import("manifest.zig");

/// Release pipeline inputs. The packaging and signing pipeline is added by the
/// release implementation tasks.
pub const Options = struct {
    version: []const u8,
    targets: []const []const u8,
    output_dir: []const u8,
};

pub const Artifact = manifest.Artifact;
pub const Manifest = manifest.Manifest;
