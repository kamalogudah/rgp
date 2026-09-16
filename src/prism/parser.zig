const std = @import("std");
const c = @import("bindings.zig").c;

pub const ParseOptions = struct { path: []const u8 = "<memory>" };
pub const Severity = enum { syntax_error, warning };
pub const Location = struct { start_offset: usize, end_offset: usize, line: usize, column: usize, end_line: usize, end_column: usize };
pub const Diagnostic = struct { severity: Severity, message: []const u8, location: Location };

/// Non-owning AST view. It must not outlive its Document.
pub const Node = struct {
    raw: *const c.pm_node_t,
    source_bytes: []const u8,
    pub fn kind(self: Node) []const u8 {
        return std.mem.span(c.pm_node_type_to_str(self.raw.type));
    }
    pub fn location(self: Node) Location {
        return locationFromPointers(self.source_bytes, self.raw.location.start, self.raw.location.end);
    }
    pub fn source(self: Node) []const u8 {
        const range = self.location();
        return self.source_bytes[range.start_offset..range.end_offset];
    }
};

// pm_parser_t contains self-referential state, so this stays heap-stable.
const State = struct {
    parser: c.pm_parser_t = undefined,
    root: ?*c.pm_node_t = null,
    source: []u8,
    path: []u8,
    diagnostics: []Diagnostic = &.{},
};

/// Owns copied source, parser, AST, and diagnostics.
pub const Document = struct {
    allocator: std.mem.Allocator,
    state: *State,

    /// Tree cleanup must precede parser cleanup, then source cleanup.
    pub fn deinit(self: *Document) void {
        if (self.state.root) |root_node| c.pm_node_destroy(&self.state.parser, root_node);
        c.pm_parser_free(&self.state.parser);
        for (self.state.diagnostics) |diagnostic| self.allocator.free(diagnostic.message);
        self.allocator.free(self.state.diagnostics);
        self.allocator.free(self.state.path);
        self.allocator.free(self.state.source);
        self.allocator.destroy(self.state);
        self.* = undefined;
    }

    pub fn source(self: *const Document) []const u8 {
        return self.state.source;
    }
    pub fn path(self: *const Document) []const u8 {
        return self.state.path;
    }
    pub fn root(self: *const Document) Node {
        return .{ .raw = self.state.root.?, .source_bytes = self.state.source };
    }
    pub fn diagnostics(self: *const Document) []const Diagnostic {
        return self.state.diagnostics;
    }
    pub fn success(self: *const Document) bool {
        for (self.state.diagnostics) |diagnostic| if (diagnostic.severity == .syntax_error) return false;
        return true;
    }
};

/// Syntax and encoding failures are diagnostics, not Zig errors.
pub fn parse(allocator: std.mem.Allocator, input: []const u8, options: ParseOptions) !Document {
    const state = try allocator.create(State);
    errdefer allocator.destroy(state);
    state.source = try allocator.dupe(u8, input);
    errdefer allocator.free(state.source);
    state.path = try allocator.dupe(u8, options.path);
    errdefer allocator.free(state.path);

    c.pm_parser_init(&state.parser, state.source.ptr, state.source.len, null);
    state.root = c.pm_parse(&state.parser);
    errdefer {
        if (state.root) |root_node| c.pm_node_destroy(&state.parser, root_node);
        c.pm_parser_free(&state.parser);
    }
    state.diagnostics = try copyDiagnostics(allocator, state.source, &state.parser);
    return .{ .allocator = allocator, .state = state };
}

fn copyDiagnostics(allocator: std.mem.Allocator, source: []const u8, parser: *const c.pm_parser_t) ![]Diagnostic {
    const error_count = parser.error_list.size;
    const warning_count = parser.warning_list.size;
    const result = try allocator.alloc(Diagnostic, error_count + warning_count);
    var index: usize = 0;
    errdefer {
        for (result[0..index]) |diagnostic| allocator.free(diagnostic.message);
        allocator.free(result);
    }
    index = try copyDiagnosticList(allocator, source, result, index, parser.error_list, .syntax_error);
    _ = try copyDiagnosticList(allocator, source, result, index, parser.warning_list, .warning);
    return result;
}

fn copyDiagnosticList(allocator: std.mem.Allocator, source: []const u8, result: []Diagnostic, start_index: usize, list: c.pm_list_t, severity: Severity) !usize {
    var index = start_index;
    var next = list.head;
    while (next != null) : (next = next[0].next) {
        const list_node = next;
        const raw: *const c.pm_diagnostic_t = @ptrCast(list_node);
        result[index] = .{
            .severity = severity,
            .message = try allocator.dupe(u8, std.mem.span(raw.message)),
            .location = locationFromPointers(source, raw.location.start, raw.location.end),
        };
        index += 1;
    }
    return index;
}

fn positionAt(source: []const u8, offset: usize) struct { line: usize, column: usize } {
    const prefix = source[0..offset];
    const last_newline = std.mem.lastIndexOfScalar(u8, prefix, '\n');
    return .{ .line = std.mem.count(u8, prefix, "\n") + 1, .column = offset - (if (last_newline) |newline| newline + 1 else 0) + 1 };
}

fn locationFromPointers(source: []const u8, start: [*c]const u8, end: [*c]const u8) Location {
    const start_offset = @intFromPtr(start) - @intFromPtr(source.ptr);
    const end_offset = @intFromPtr(end) - @intFromPtr(source.ptr);
    const start_position = positionAt(source, start_offset);
    const end_position = positionAt(source, end_offset);
    return .{
        .start_offset = start_offset,
        .end_offset = end_offset,
        .line = start_position.line,
        .column = start_position.column,
        .end_line = end_position.line,
        .end_column = end_position.column,
    };
}

test "valid Ruby has a tree and no diagnostics" {
    var document = try parse(std.testing.allocator, "answer = 40 + 2\nputs answer\n", .{ .path = "fixtures/answer.rb" });
    defer document.deinit();
    try std.testing.expect(document.success());
    try std.testing.expectEqualStrings("fixtures/answer.rb", document.path());
    try std.testing.expectEqual(@as(usize, 0), document.diagnostics().len);
    try std.testing.expectEqualStrings("PM_PROGRAM_NODE", document.root().kind());
}

test "invalid Ruby retains source and file diagnostics" {
    var input = [_]u8{ 'd', 'e', 'f', ' ', 'x', '(' };
    var document = try parse(std.testing.allocator, &input, .{ .path = "fixtures/broken.rb" });
    defer document.deinit();
    input[0] = 'x';
    try std.testing.expect(!document.success());
    try std.testing.expect(document.diagnostics().len > 0);
    try std.testing.expectEqual(.syntax_error, document.diagnostics()[0].severity);
    try std.testing.expect(document.diagnostics()[0].message.len > 0);
    try std.testing.expectEqualStrings("fixtures/broken.rb", document.path());
    try std.testing.expectEqualStrings("def x(", document.source());
}

test "invalid encoding retains provenance" {
    var document = try parse(std.testing.allocator, "# encoding: definitely-not-an-encoding\nvalue = 1\n", .{ .path = "fixtures/bad_encoding.rb" });
    defer document.deinit();
    try std.testing.expect(!document.success());
    try std.testing.expect(document.diagnostics().len > 0);
    try std.testing.expectEqualStrings("fixtures/bad_encoding.rb", document.path());
    try std.testing.expectEqualStrings("# encoding: definitely-not-an-encoding\nvalue = 1\n", document.source());
    try std.testing.expect(document.diagnostics()[0].message.len > 0);
}
