const std = @import("std");

const c = @cImport({
    @cInclude("prism.h");
});

/// Return whether libprism accepts `source` without syntax errors or warnings.
/// This is intentionally a minimal C-linkage spike, not the Phase 1 parser API.
pub fn parses(source: []const u8) bool {
    return c.pm_parse_success_p(source.ptr, source.len, null);
}

/// The runtime version is checked by the integration test to make a dependency
/// replacement or incomplete linkage visible immediately.
pub fn version() []const u8 {
    return std.mem.span(c.pm_version());
}
