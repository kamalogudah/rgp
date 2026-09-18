//! CLI command adapters that bridge process arguments and I/O to the RGP core.
const std = @import("std");

pub const corpus = @import("corpus.zig");

test {
    std.testing.refAllDecls(corpus);
}
