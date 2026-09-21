//! Incremental repository analysis: observation extraction and pipeline.
const std = @import("std");

pub const idioms = @import("idioms.zig");
pub const observation = @import("observation.zig");
pub const pipeline = @import("pipeline.zig");

test {
    std.testing.refAllDecls(observation);
    std.testing.refAllDecls(idioms);
    std.testing.refAllDecls(pipeline);
}
