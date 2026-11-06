/// Release manifest schema. Serialization, checksum calculation, and signature
/// verification are implemented by the release tooling tasks.
pub const schema_version: u32 = 1;

pub const Artifact = struct {
    name: []const u8,
    target: []const u8,
    sha256: []const u8,
    signature: []const u8,
};

pub const Manifest = struct {
    version: []const u8,
    artifacts: []const Artifact,
};
