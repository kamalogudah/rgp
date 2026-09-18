//! CLI command adapters that bridge process arguments and I/O to the RGP core.
const std = @import("std");

pub const corpus = @import("corpus.zig");
pub const analyze = @import("analyze.zig");

test {
    std.testing.refAllDecls(corpus);
    std.testing.refAllDecls(analyze);
}
