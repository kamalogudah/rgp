//! Corpus management: manifests, pinning, and snapshot synchronization.
const std = @import("std");

pub const manifest = @import("manifest.zig");
pub const git = @import("git.zig");
pub const sync = @import("sync.zig");

test {
    std.testing.refAllDecls(manifest);
    std.testing.refAllDecls(git);
    std.testing.refAllDecls(sync);
}
