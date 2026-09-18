//! Extracts deterministic observations from a libprism AST for Phase 2 constructs.
const std = @import("std");
const parser = @import("../prism/parser.zig");
const c = @import("../prism/bindings.zig");
const fixture_sources = @import("parser_fixtures");

pub const Observation = struct {
    start_offset: usize,
    end_offset: usize,
    line: usize,
    column: usize,
    node_kind: []const u8,
    construct: []const u8,
    name: ?[]const u8 = null,
    receiver_kind: ?[]const u8 = null,
    block_syntax: ?[]const u8 = null,

    pub fn json(self: Observation, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        var output = std.Io.Writer.Allocating.init(allocator);
        defer output.deinit();
        const writer = &output.writer;
        writer.writeAll("{") catch |err| return convertWriterError(err);
        writeJsonField(writer, "construct", self.construct) catch |err| return convertWriterError(err);
        if (self.name) |n| {
            writer.writeAll(",") catch |err| return convertWriterError(err);
            writeJsonField(writer, "name", n) catch |err| return convertWriterError(err);
        }
        if (self.receiver_kind) |r| {
            writer.writeAll(",") catch |err| return convertWriterError(err);
            writeJsonField(writer, "receiver_kind", r) catch |err| return convertWriterError(err);
        }
        if (self.block_syntax) |b| {
            writer.writeAll(",") catch |err| return convertWriterError(err);
            writeJsonField(writer, "block_syntax", b) catch |err| return convertWriterError(err);
        }
        writer.writeAll("}") catch |err| return convertWriterError(err);
        return allocator.dupe(u8, output.written()) catch |err| return err;
    }
};

fn convertWriterError(_: anyerror) std.mem.Allocator.Error {
    return error.OutOfMemory;
}

fn writeJsonField(writer: anytype, key: []const u8, value: []const u8) !void {
    try writer.writeByte('"');
    try writer.writeAll(key);
    try writer.writeAll("\":\"");
    for (value) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => if (byte < 0x20) try writer.print("\\u00{x:0>2}", .{byte}) else try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}

const Record = struct { raw: *const c.c.pm_node_t, parent: ?usize };

const Walker = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    records: std.ArrayList(Record) = .empty,
    observations: std.ArrayList(Observation) = .empty,
    stack: std.ArrayList(usize) = .empty,
    err: ?anyerror = null,

    fn deinit(self: *Walker) void {
        self.records.deinit(self.allocator);
        self.observations.deinit(self.allocator);
        self.stack.deinit(self.allocator);
    }

    fn walk(self: *Walker, raw: *const c.c.pm_node_t) !void {
        if (self.idFor(raw) != null) return;
        const parent = if (self.stack.items.len == 0) null else self.stack.items[self.stack.items.len - 1];
        const id = self.records.items.len;
        try self.records.append(self.allocator, .{ .raw = raw, .parent = parent });

        const node = parser.Node{ .raw = raw, .source_bytes = self.source };
        if (observationForNode(node)) |obs| {
            try self.observations.append(self.allocator, obs);
        }

        try self.stack.append(self.allocator, id);
        defer _ = self.stack.pop();
        c.c.pm_visit_child_nodes(raw, visitChild, self);
    }

    fn visitChild(raw: [*c]const c.c.pm_node_t, data: ?*anyopaque) callconv(.c) bool {
        const self: *Walker = @ptrCast(@alignCast(data.?));
        self.walk(raw) catch |err| {
            self.err = err;
            return false;
        };
        return false;
    }

    fn idFor(self: *const Walker, raw: *const c.c.pm_node_t) ?usize {
        for (self.records.items, 0..) |record, id| {
            if (record.raw == raw) return id;
        }
        return null;
    }
};

fn observationForNode(node: parser.Node) ?Observation {
    const kind = node.kind();
    const location = node.location();
    const base = Observation{
        .start_offset = location.start_offset,
        .end_offset = location.end_offset,
        .line = location.line,
        .column = location.column,
        .node_kind = kind,
        .construct = constructForKind(kind),
    };

    if (std.mem.eql(u8, kind, "PM_CALL_NODE")) {
        const call: *const c.c.pm_call_node_t = @ptrCast(node.raw);
        const name = sourceSlice(node.source_bytes, call.message_loc);
        if (trackedMethodName(name)) {
            return .{
                .start_offset = base.start_offset,
                .end_offset = base.end_offset,
                .line = base.line,
                .column = base.column,
                .node_kind = base.node_kind,
                .construct = name,
                .name = name,
                .receiver_kind = receiverKind(call.receiver, node.source_bytes),
            };
        }
        return null;
    }

    if (std.mem.eql(u8, kind, "PM_BLOCK_NODE")) {
        const block: *const c.c.pm_block_node_t = @ptrCast(node.raw);
        return .{
            .start_offset = base.start_offset,
            .end_offset = base.end_offset,
            .line = base.line,
            .column = base.column,
            .node_kind = base.node_kind,
            .construct = "block",
            .block_syntax = blockSyntax(block.opening_loc, node.source_bytes),
        };
    }

    if (base.construct.len == 0) return null;
    return base;
}

fn constructForKind(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "PM_IF_NODE")) return "if";
    if (std.mem.eql(u8, kind, "PM_UNLESS_NODE")) return "unless";
    if (std.mem.eql(u8, kind, "PM_CASE_NODE")) return "case";
    if (std.mem.eql(u8, kind, "PM_CASE_MATCH_NODE")) return "case";
    if (std.mem.eql(u8, kind, "PM_WHILE_NODE")) return "while";
    if (std.mem.eql(u8, kind, "PM_UNTIL_NODE")) return "until";
    if (std.mem.eql(u8, kind, "PM_FOR_NODE")) return "for";
    if (std.mem.eql(u8, kind, "PM_DEF_NODE")) return "def";
    if (std.mem.eql(u8, kind, "PM_CLASS_NODE")) return "class";
    if (std.mem.eql(u8, kind, "PM_MODULE_NODE")) return "module";
    if (std.mem.eql(u8, kind, "PM_BLOCK_NODE")) return "block";
    if (std.mem.eql(u8, kind, "PM_RESCUE_NODE")) return "rescue";
    return "";
}

fn trackedMethodName(name: []const u8) bool {
    const names = [_][]const u8{ "each", "times", "map", "collect", "select", "filter", "reject", "reduce", "inject", "size", "length", "count" };
    for (names) |n| if (std.mem.eql(u8, name, n)) return true;
    return false;
}

fn blockSyntax(opening_loc: c.c.pm_location_t, source: []const u8) ?[]const u8 {
    const slice = sourceSlice(source, opening_loc);
    if (slice.len == 0) return null;
    if (slice[0] == '{') return "braces";
    if (std.mem.startsWith(u8, slice, "do")) return "do_end";
    return null;
}

fn receiverKind(receiver: ?*const c.c.pm_node_t, source: []const u8) ?[]const u8 {
    const raw = receiver orelse return null;
    const node = parser.Node{ .raw = raw, .source_bytes = source };
    const kind = node.kind();
    if (std.mem.eql(u8, kind, "PM_INTEGER_NODE")) return "integer";
    if (std.mem.eql(u8, kind, "PM_STRING_NODE")) return "string";
    if (std.mem.eql(u8, kind, "PM_ARRAY_NODE")) return "array";
    if (std.mem.eql(u8, kind, "PM_HASH_NODE")) return "hash";
    if (std.mem.eql(u8, kind, "PM_LOCAL_VARIABLE_READ_NODE")) return "local_variable";
    if (std.mem.eql(u8, kind, "PM_INSTANCE_VARIABLE_READ_NODE")) return "instance_variable";
    if (std.mem.eql(u8, kind, "PM_CALL_NODE")) return "call";
    return "other";
}

fn sourceSlice(source: []const u8, location: c.c.pm_location_t) []const u8 {
    const start = @intFromPtr(location.start) - @intFromPtr(source.ptr);
    const end = @intFromPtr(location.end) - @intFromPtr(source.ptr);
    return source[start..end];
}

/// Extract observations from a successfully parsed document. The returned slice
/// is owned by the caller.
pub fn extract(allocator: std.mem.Allocator, document: *const parser.Document) ![]Observation {
    var walker = Walker{
        .allocator = allocator,
        .source = document.source(),
    };
    defer walker.deinit();
    try walker.walk(document.root().raw);
    if (walker.err) |err| return err;
    return try walker.observations.toOwnedSlice(allocator);
}

test "extracts Phase 2 constructs from a fixture" {
    const source =
        "class Greeter\n" ++
        "  def hello(names)\n" ++
        "    names.each do |name|\n" ++
        "      puts name if name.size > 0\n" ++
        "    end\n" ++
        "  end\n" ++
        "end\n";
    var document = try parser.parse(std.testing.allocator, source, .{ .path = "greeting.rb" });
    defer document.deinit();
    const observations = try extract(std.testing.allocator, &document);
    defer std.testing.allocator.free(observations);

    try std.testing.expectEqual(@as(usize, 6), observations.len);
    var found = std.StringHashMap(void).init(std.testing.allocator);
    defer found.deinit();
    for (observations) |obs| {
        try found.put(obs.construct, {});
    }
    try std.testing.expect(found.contains("class"));
    try std.testing.expect(found.contains("def"));
    try std.testing.expect(found.contains("each"));
    try std.testing.expect(found.contains("if"));
    try std.testing.expect(found.contains("size"));
    try std.testing.expect(found.contains("block"));
}

test "tracks receiver kind for collection methods" {
    const source = "[1, 2, 3].each { |n| n.times {} }\n";
    var document = try parser.parse(std.testing.allocator, source, .{});
    defer document.deinit();
    const observations = try extract(std.testing.allocator, &document);
    defer std.testing.allocator.free(observations);

    var each_receiver: ?[]const u8 = null;
    var times_receiver: ?[]const u8 = null;
    for (observations) |obs| {
        if (std.mem.eql(u8, obs.construct, "each")) each_receiver = obs.receiver_kind;
        if (std.mem.eql(u8, obs.construct, "times")) times_receiver = obs.receiver_kind;
    }
    try std.testing.expectEqualStrings("array", each_receiver.?);
    try std.testing.expectEqualStrings("local_variable", times_receiver.?);
}

test "construct catalog fixture yields exact counts" {
    const source = fixture_sources.construct_catalog;
    var document = try parser.parse(std.testing.allocator, source, .{ .path = "fixtures/parser/construct_catalog.rb" });
    defer document.deinit();
    try std.testing.expect(document.success());

    const observations = try extract(std.testing.allocator, &document);
    defer std.testing.allocator.free(observations);

    var counts = std.StringHashMap(usize).init(std.testing.allocator);
    defer counts.deinit();
    for (observations) |obs| {
        const entry = try counts.getOrPut(obs.construct);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
    }

    const expected = [_]struct { []const u8, usize }{
        .{ "module", 1 },
        .{ "class", 1 },
        .{ "def", 1 },
        .{ "if", 1 },
        .{ "unless", 1 },
        .{ "case", 1 },
        .{ "while", 1 },
        .{ "until", 1 },
        .{ "for", 1 },
        .{ "each", 1 },
        .{ "times", 1 },
        .{ "map", 1 },
        .{ "collect", 1 },
        .{ "select", 1 },
        .{ "filter", 1 },
        .{ "reject", 1 },
        .{ "reduce", 1 },
        .{ "inject", 1 },
        .{ "size", 1 },
        .{ "length", 1 },
        .{ "count", 1 },
        .{ "block", 9 },
        .{ "rescue", 1 },
    };

    var total: usize = 0;
    for (expected) |pair| {
        const construct = pair[0];
        const count = pair[1];
        total += count;
        const actual = counts.get(construct) orelse 0;
        try std.testing.expectEqual(count, actual);
    }
    try std.testing.expectEqual(total, observations.len);
}

test "construct catalog fixture distinguishes call names from receiver semantics" {
    const source = fixture_sources.construct_catalog;
    var document = try parser.parse(std.testing.allocator, source, .{ .path = "fixtures/parser/construct_catalog.rb" });
    defer document.deinit();

    const observations = try extract(std.testing.allocator, &document);
    defer std.testing.allocator.free(observations);

    var receivers = std.StringHashMap(std.ArrayList([]const u8)).init(std.testing.allocator);
    defer {
        var iter = receivers.valueIterator();
        while (iter.next()) |list| list.deinit(std.testing.allocator);
        receivers.deinit();
    }

    for (observations) |obs| {
        const rk = obs.receiver_kind orelse continue;
        const entry = try receivers.getOrPut(obs.construct);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(std.testing.allocator, rk);
    }

    try assertReceiverKind(&receivers, "each", &.{"local_variable"});
    try assertReceiverKind(&receivers, "times", &.{"integer"});
    try assertReceiverKind(&receivers, "map", &.{"array"});
    try assertReceiverKind(&receivers, "collect", &.{"local_variable"});
    try assertReceiverKind(&receivers, "select", &.{"local_variable"});
    try assertReceiverKind(&receivers, "filter", &.{"local_variable"});
    try assertReceiverKind(&receivers, "reject", &.{"local_variable"});
    try assertReceiverKind(&receivers, "reduce", &.{"local_variable"});
    try assertReceiverKind(&receivers, "inject", &.{"local_variable"});
    try assertReceiverKind(&receivers, "size", &.{"local_variable"});
    try assertReceiverKind(&receivers, "length", &.{"string"});
    try assertReceiverKind(&receivers, "count", &.{"array"});
}

test "construct catalog fixture records block syntax forms" {
    const source = fixture_sources.construct_catalog;
    var document = try parser.parse(std.testing.allocator, source, .{ .path = "fixtures/parser/construct_catalog.rb" });
    defer document.deinit();

    const observations = try extract(std.testing.allocator, &document);
    defer std.testing.allocator.free(observations);

    var braces: usize = 0;
    var do_end: usize = 0;
    var unspecified: usize = 0;
    for (observations) |obs| {
        if (!std.mem.eql(u8, obs.construct, "block")) continue;
        if (obs.block_syntax) |syntax| {
            if (std.mem.eql(u8, syntax, "braces")) {
                braces += 1;
            } else if (std.mem.eql(u8, syntax, "do_end")) {
                do_end += 1;
            } else {
                unspecified += 1;
            }
        } else {
            unspecified += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 8), braces);
    try std.testing.expectEqual(@as(usize, 1), do_end);
    try std.testing.expectEqual(@as(usize, 0), unspecified);
}

fn assertReceiverKind(receivers: *std.StringHashMap(std.ArrayList([]const u8)), construct: []const u8, expected: []const []const u8) !void {
    const list = receivers.get(construct) orelse {
        std.debug.print("no observations for construct `{s}`\n", .{construct});
        return error.MissingConstruct;
    };
    try std.testing.expectEqual(expected.len, list.items.len);
    for (expected, list.items) |exp, actual| {
        try std.testing.expectEqualStrings(exp, actual);
    }
}
