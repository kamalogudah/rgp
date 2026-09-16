//! Deterministic, read-only Prism AST traversal and JSON reporting.
const std = @import("std");
const parser = @import("parser.zig");
const c = @import("bindings.zig").c;
const fixture_sources = @import("parser_fixtures");

const Record = struct { raw: *const c.pm_node_t, parent: ?usize };

const Walker = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayList(Record) = .empty,
    stack: std.ArrayList(usize) = .empty,
    err: ?anyerror = null,

    fn deinit(self: *Walker) void {
        self.records.deinit(self.allocator);
        self.stack.deinit(self.allocator);
    }
    fn walk(self: *Walker, raw: *const c.pm_node_t) !void {
        // Prism's AST is a tree, but keep this guarantee at our boundary: a
        // malformed or future shared child must not become two observations.
        if (self.idFor(raw) != null) return;
        const parent = if (self.stack.items.len == 0) null else self.stack.items[self.stack.items.len - 1];
        const id = self.records.items.len;
        try self.records.append(self.allocator, .{ .raw = raw, .parent = parent });
        try self.stack.append(self.allocator, id);
        defer _ = self.stack.pop();
        c.pm_visit_child_nodes(raw, visitChild, self);
    }
    fn visitChild(raw: [*c]const c.pm_node_t, data: ?*anyopaque) callconv(.c) bool {
        const self: *Walker = @ptrCast(@alignCast(data.?));
        self.walk(raw) catch |err| {
            self.err = err;
            return false;
        };
        return false;
    }

    fn idFor(self: *const Walker, raw: *const c.pm_node_t) ?usize {
        for (self.records.items, 0..) |record, id| {
            if (record.raw == raw) return id;
        }
        return null;
    }
};

/// Emits stable JSON in source/pre-order, with no pointer values or hash-map iteration.
pub fn writeJson(document: *const parser.Document, writer: anytype) !void {
    var walker = Walker{ .allocator = document.allocator };
    defer walker.deinit();
    try walker.walk(document.root().raw);
    if (walker.err) |err| return err;
    try writer.writeAll("{\"path\":");
    try writeString(writer, document.path());
    try writer.print(",\"success\":{s},\"diagnostics\":[", .{if (document.success()) "true" else "false"});
    for (document.diagnostics(), 0..) |diagnostic, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll("{\"severity\":");
        try writeString(writer, @tagName(diagnostic.severity));
        try writer.writeAll(",\"message\":");
        try writeString(writer, diagnostic.message);
        try writer.writeAll(",\"span\":");
        try writeLocation(writer, diagnostic.location);
        try writer.writeByte('}');
    }
    try writer.writeAll("],\"nodes\":[");
    for (walker.records.items, 0..) |record, id| {
        if (id != 0) try writer.writeByte(',');
        try writeRecord(writer, document.source(), walker.records.items, record, id);
    }
    try writer.writeAll("]}\n");
}

fn writeRecord(writer: anytype, source: []const u8, records: []const Record, record: Record, id: usize) !void {
    const node = parser.Node{ .raw = record.raw, .source_bytes = source };
    try writer.writeAll("{\"id\":");
    try writer.print("{}", .{id});
    try writer.writeAll(",\"kind\":");
    try writeString(writer, node.kind());
    try writer.writeAll(",\"span\":");
    try writeLocation(writer, node.location());
    try writer.writeAll(",\"parent\":");
    if (record.parent) |parent| try writer.print("{}", .{parent}) else try writer.writeAll("null");
    try writer.writeAll(",\"ancestors\":[");
    try writeAncestors(writer, records, record.parent);
    try writer.writeByte(']');
    if (std.mem.eql(u8, node.kind(), "PM_CALL_NODE")) {
        const call: *const c.pm_call_node_t = @ptrCast(record.raw);
        try writer.writeAll(",\"call\":{\"name\":");
        try writeLocationSource(writer, source, call.message_loc);
        try writer.writeAll(",\"receiver\":");
        if (call.receiver != null) try writeNodeRef(writer, source, records, call.receiver) else try writer.writeAll("null");
        try writer.writeAll(",\"arguments\":[");
        if (call.arguments != null) try writeArguments(writer, source, records, call.arguments);
        try writer.print("],\"block\":{s}}}", .{if (call.block != null) "true" else "false"});
    }
    if (std.mem.endsWith(u8, node.kind(), "_WRITE_NODE")) try writer.writeAll(",\"assignment\":true");
    try writer.writeByte('}');
}

fn writeAncestors(writer: anytype, records: []const Record, initial: ?usize) !void {
    if (initial) |id| {
        try writeAncestors(writer, records, records[id].parent);
        if (records[id].parent != null) try writer.writeByte(',');
        try writer.print("{}", .{id});
    }
}
fn writeArguments(writer: anytype, source: []const u8, records: []const Record, arguments: *const c.pm_arguments_node_t) !void {
    var index: usize = 0;
    while (index < arguments.arguments.size) : (index += 1) {
        if (index != 0) try writer.writeByte(',');
        try writeNodeRef(writer, source, records, arguments.arguments.nodes[index]);
    }
}
fn writeNodeRef(writer: anytype, source: []const u8, records: []const Record, raw: *const c.pm_node_t) !void {
    const node = parser.Node{ .raw = raw, .source_bytes = source };
    try writer.writeAll("{\"id\":");
    if (idFor(records, raw)) |id| try writer.print("{}", .{id}) else try writer.writeAll("null");
    try writer.writeAll(",\"kind\":");
    try writeString(writer, node.kind());
    try writer.writeAll(",\"span\":");
    try writeLocation(writer, node.location());
    try writer.writeByte('}');
}
fn idFor(records: []const Record, raw: *const c.pm_node_t) ?usize {
    for (records, 0..) |record, id| if (record.raw == raw) return id;
    return null;
}
fn writeLocationSource(writer: anytype, source: []const u8, location: c.pm_location_t) !void {
    try writeString(writer, source[@intFromPtr(location.start) - @intFromPtr(source.ptr) .. @intFromPtr(location.end) - @intFromPtr(source.ptr)]);
}
fn writeLocation(writer: anytype, location: parser.Location) !void {
    try writer.writeAll("{\"start_offset\":");
    try writer.print("{}", .{location.start_offset});
    try writer.writeAll(",\"end_offset\":");
    try writer.print("{}", .{location.end_offset});
    try writer.writeAll(",\"line\":");
    try writer.print("{}", .{location.line});
    try writer.writeAll(",\"column\":");
    try writer.print("{}", .{location.column});
    try writer.writeAll(",\"end_line\":");
    try writer.print("{}", .{location.end_line});
    try writer.writeAll(",\"end_column\":");
    try writer.print("{}", .{location.end_column});
    try writer.writeByte('}');
}
fn writeString(writer: anytype, bytes: []const u8) !void {
    try writer.writeByte('"');
    for (bytes) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => if (byte < 0x20) try writer.print("\\u00{x:0>2}", .{byte}) else try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}

test "traversal covers Phase 1 constructs without duplicate calls" {
    const source = fixture_sources.phase1_constructs;
    var document = try parser.parse(std.testing.allocator, source, .{ .path = "phase1.rb" });
    defer document.deinit();
    try std.testing.expect(document.success());
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try writeJson(&document, &output.writer);
    const report = output.written();
    inline for ([_][]const u8{ "PM_MODULE_NODE", "PM_CLASS_NODE", "PM_DEF_NODE", "PM_IF_NODE", "PM_UNLESS_NODE", "PM_CASE_NODE", "PM_WHILE_NODE", "PM_UNTIL_NODE", "PM_FOR_NODE", "PM_BLOCK_NODE", "PM_ARRAY_NODE", "PM_HASH_NODE", "PM_RESCUE_NODE", "PM_LOCAL_VARIABLE_WRITE_NODE" }) |kind| {
        try std.testing.expect(std.mem.indexOf(u8, report, kind) != null);
    }
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, report, "\"name\":\"each\""));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, report, "\"name\":\"work\""));
}

test "checked-in parser fixtures produce deterministic reports" {
    const Fixture = struct {
        path: []const u8,
        source: []const u8,
        success: bool,
        expected: []const []const u8,
    };
    const fixtures = [_]Fixture{
        .{
            .path = "fixtures/parser/phase1_constructs.rb",
            .source = fixture_sources.phase1_constructs,
            .success = true,
            .expected = &.{ "PM_MODULE_NODE", "PM_CLASS_NODE", "PM_DEF_NODE", "PM_IF_NODE", "PM_UNLESS_NODE", "PM_CASE_NODE", "PM_WHILE_NODE", "PM_UNTIL_NODE", "PM_FOR_NODE", "PM_BLOCK_NODE", "PM_ARRAY_NODE", "PM_HASH_NODE", "PM_RESCUE_NODE", "PM_LOCAL_VARIABLE_WRITE_NODE" },
        },
        .{
            .path = "fixtures/parser/nested_multiline.rb",
            .source = fixture_sources.nested_multiline,
            .success = true,
            .expected = &.{ "PM_BLOCK_NODE", "PM_IF_NODE", "PM_LOCAL_VARIABLE_WRITE_NODE", "\"line\":5,\"column\":7" },
        },
        .{
            .path = "fixtures/parser/ambiguous_calls.rb",
            .source = fixture_sources.ambiguous_calls,
            .success = true,
            .expected = &.{ "PM_REGULAR_EXPRESSION_NODE", "\"name\":\"render\"" },
        },
        .{
            .path = "fixtures/parser/ruby_2_7_pattern_matching.rb",
            .source = fixture_sources.ruby_2_7_pattern_matching,
            .success = true,
            .expected = &.{ "PM_CASE_MATCH_NODE", "PM_IN_NODE" },
        },
        .{
            .path = "fixtures/parser/invalid_unclosed_definition.rb",
            .source = fixture_sources.invalid_unclosed_definition,
            .success = false,
            .expected = &.{"\"severity\":\"syntax_error\""},
        },
    };

    for (fixtures) |fixture| {
        var first_document = try parser.parse(std.testing.allocator, fixture.source, .{ .path = fixture.path });
        defer first_document.deinit();
        var second_document = try parser.parse(std.testing.allocator, fixture.source, .{ .path = fixture.path });
        defer second_document.deinit();
        try std.testing.expectEqual(fixture.success, first_document.success());
        try std.testing.expectEqual(fixture.success, second_document.success());

        var first = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer first.deinit();
        var second = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer second.deinit();
        try writeJson(&first_document, &first.writer);
        try writeJson(&second_document, &second.writer);
        try std.testing.expectEqualStrings(first.written(), second.written());
        try std.testing.expect(std.mem.indexOf(u8, first.written(), fixture.path) != null);
        for (fixture.expected) |needle| try std.testing.expect(std.mem.indexOf(u8, first.written(), needle) != null);
    }
}

test "traversal reports calls once with parent context" {
    var document = try parser.parse(std.testing.allocator, "items.each do |item|\n  puts item\nend\n", .{ .path = "fixture.rb" });
    defer document.deinit();
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try writeJson(&document, &output.writer);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"name\":\"each\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"name\":\"puts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"receiver\":{\"id\":3,\"kind\":\"PM_CALL_NODE\"") != null);
}
