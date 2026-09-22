//! CLI command adapters that bridge process arguments and I/O to the RGP core.
const std = @import("std");

pub const corpus = @import("corpus.zig");
pub const analyze = @import("analyze.zig");
pub const compare = @import("compare.zig");
pub const report = @import("report.zig");
pub const idioms = @import("idioms.zig");
pub const examples = @import("examples.zig");
pub const learn = @import("learn.zig");

test {
    std.testing.refAllDecls(corpus);
    std.testing.refAllDecls(analyze);
    std.testing.refAllDecls(compare);
    std.testing.refAllDecls(report);
    std.testing.refAllDecls(idioms);
    std.testing.refAllDecls(examples);
    std.testing.refAllDecls(learn);
}
