//! Deterministic loader for the educational taxonomy and idiom map.
const std = @import("std");

pub const Topic = struct {
    id: []const u8,
    title: []const u8,
    parent: ?[]const u8,
    constructs: []const []const u8,
};

pub const Idiom = struct { id: []const u8, topic: []const u8 };

pub const Taxonomy = struct {
    allocator: std.mem.Allocator,
    topics: []Topic,
    idioms: []Idiom,

    pub fn deinit(self: *Taxonomy) void {
        for (self.topics) |value| {
            self.allocator.free(value.id);
            self.allocator.free(value.title);
            if (value.parent) |parent| self.allocator.free(parent);
            for (value.constructs) |construct| self.allocator.free(construct);
            self.allocator.free(value.constructs);
        }
        for (self.idioms) |idiom| {
            self.allocator.free(idiom.id);
            self.allocator.free(idiom.topic);
        }
        self.allocator.free(self.topics);
        self.allocator.free(self.idioms);
        self.* = .{ .allocator = self.allocator, .topics = &.{}, .idioms = &.{} };
    }

    pub fn topic(self: *const Taxonomy, requested: []const u8) ?Topic {
        const id = alias(requested);
        for (self.topics) |value| if (std.mem.eql(u8, value.id, id)) return value;
        return null;
    }

    pub fn topicForConstruct(self: *const Taxonomy, construct: []const u8) ?[]const u8 {
        var result: ?[]const u8 = null;
        // Child topics follow their aggregate parent in taxonomy.toml. Keeping
        // the last match makes `map` resolve to transformation, while the
        // parent remains available for the explicit `collections` report.
        for (self.topics) |value| {
            for (value.constructs) |mapped| {
                if (std.mem.eql(u8, mapped, construct)) result = value.id;
            }
        }
        return result;
    }

    pub fn topicForIdiom(self: *const Taxonomy, idiom: []const u8) ?[]const u8 {
        for (self.idioms) |value| if (std.mem.eql(u8, value.id, idiom)) return value.topic;
        return null;
    }
};

pub const Error = error{ Invalid, UnsupportedSchema, DuplicateId, UnknownReference, Cycle, OutOfMemory };

pub fn load(allocator: std.mem.Allocator, taxonomy_text: []const u8, idioms_text: []const u8) Error!Taxonomy {
    var topics = std.ArrayList(Topic).empty;
    var idioms = std.ArrayList(Idiom).empty;
    errdefer {
        cleanup(allocator, topics.items, idioms.items);
        topics.deinit(allocator);
        idioms.deinit(allocator);
    }
    var current: ?TopicBuilder = null;
    var schema_seen = false;
    var in_idiom = false;
    var idiom_id: ?[]u8 = null;
    var idiom_topic: ?[]u8 = null;

    var lines = std.mem.splitScalar(u8, taxonomy_text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.eql(u8, line, "[[topic]]")) {
            if (current) |builder| try appendTopic(allocator, &topics, builder);
            current = .{};
            in_idiom = false;
            continue;
        }
        if (std.mem.eql(u8, fieldName(line), "schema_version")) {
            if (schema_seen or !std.mem.eql(u8, valueAfter(line, '='), "1")) return error.UnsupportedSchema;
            schema_seen = true;
            continue;
        }
        if (current == null) return error.Invalid;
        try setTopicField(allocator, &current.?, line);
    }
    if (current) |builder| try appendTopic(allocator, &topics, builder);
    if (!schema_seen) return error.Invalid;
    try validateTopics(topics.items);

    var ilines = std.mem.splitScalar(u8, idioms_text, '\n');
    var idiom_schema = false;
    while (ilines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.eql(u8, line, "[[idiom]]")) {
            if (idiom_id) |id| try appendIdiom(allocator, &idioms, id, idiom_topic orelse return error.Invalid);
            idiom_id = null;
            idiom_topic = null;
            in_idiom = true;
            continue;
        }
        if (std.mem.eql(u8, fieldName(line), "schema_version")) {
            if (idiom_schema or !std.mem.eql(u8, valueAfter(line, '='), "1")) return error.UnsupportedSchema;
            idiom_schema = true;
            continue;
        }
        if (!in_idiom) continue;
        if (std.mem.eql(u8, fieldName(line), "id")) idiom_id = try parseString(allocator, valueAfter(line, '=')) else if (std.mem.eql(u8, fieldName(line), "topic")) idiom_topic = try parseString(allocator, valueAfter(line, '='));
    }
    if (idiom_id) |id| try appendIdiom(allocator, &idioms, id, idiom_topic orelse return error.Invalid);
    if (!idiom_schema) return error.Invalid;
    for (idioms.items) |idiom| if (!hasTopic(topics.items, idiom.topic)) return error.UnknownReference;
    return .{ .allocator = allocator, .topics = try topics.toOwnedSlice(allocator), .idioms = try idioms.toOwnedSlice(allocator) };
}

const TopicBuilder = struct { id: ?[]u8 = null, title: ?[]u8 = null, parent: ?[]u8 = null, constructs: std.ArrayList([]u8) = .empty };

fn setTopicField(allocator: std.mem.Allocator, builder: *TopicBuilder, line: []const u8) Error!void {
    if (std.mem.eql(u8, fieldName(line), "id")) builder.id = try parseString(allocator, valueAfter(line, '=')) else if (std.mem.eql(u8, fieldName(line), "title")) builder.title = try parseString(allocator, valueAfter(line, '=')) else if (std.mem.eql(u8, fieldName(line), "parent")) builder.parent = try parseString(allocator, valueAfter(line, '=')) else if (std.mem.eql(u8, fieldName(line), "constructs")) {
        var value = std.mem.trim(u8, valueAfter(line, '='), " \t[]");
        while (value.len > 0) {
            const comma = std.mem.indexOfScalar(u8, value, ',') orelse value.len;
            const item = std.mem.trim(u8, value[0..comma], " \t\"");
            if (item.len > 0) try builder.constructs.append(allocator, try allocator.dupe(u8, item));
            value = if (comma == value.len) &.{} else value[comma + 1 ..];
        }
    } else return error.Invalid;
}

fn appendTopic(allocator: std.mem.Allocator, topics: *std.ArrayList(Topic), builder: TopicBuilder) Error!void {
    if (builder.id == null or builder.title == null) return error.Invalid;
    for (topics.items) |topic| if (std.mem.eql(u8, topic.id, builder.id.?)) {
        freeBuilder(allocator, builder);
        return error.DuplicateId;
    };
    var owned_builder = builder;
    try topics.append(allocator, .{ .id = owned_builder.id.?, .title = owned_builder.title.?, .parent = owned_builder.parent, .constructs = try owned_builder.constructs.toOwnedSlice(allocator) });
}

fn appendIdiom(allocator: std.mem.Allocator, idioms: *std.ArrayList(Idiom), id: []u8, topic: []u8) Error!void {
    for (idioms.items) |value| if (std.mem.eql(u8, value.id, id)) return error.DuplicateId;
    try idioms.append(allocator, .{ .id = id, .topic = topic });
}

fn validateTopics(topics: []const Topic) Error!void {
    for (topics) |topic| {
        if (!validId(topic.id)) return error.Invalid;
        if (topic.parent) |parent| if (!hasTopic(topics, parent)) return error.UnknownReference;
        var seen = std.StringHashMap(void).init(std.heap.page_allocator);
        defer seen.deinit();
        var cursor: ?[]const u8 = topic.id;
        while (cursor) |id| {
            if (seen.contains(id)) return error.Cycle;
            try seen.put(id, {});
            cursor = parentOf(topics, id);
        }
    }
}

fn cleanup(allocator: std.mem.Allocator, topics: []const Topic, idioms: []const Idiom) void {
    for (topics) |topic| {
        allocator.free(topic.id);
        allocator.free(topic.title);
        if (topic.parent) |parent| allocator.free(parent);
        for (topic.constructs) |construct| allocator.free(construct);
        allocator.free(topic.constructs);
    }
    for (idioms) |idiom| {
        allocator.free(idiom.id);
        allocator.free(idiom.topic);
    }
}

fn freeBuilder(allocator: std.mem.Allocator, builder: TopicBuilder) void {
    if (builder.id) |id| allocator.free(id);
    if (builder.title) |title| allocator.free(title);
    if (builder.parent) |parent| allocator.free(parent);
    for (builder.constructs.items) |construct| allocator.free(construct);
    var mutable = builder;
    mutable.constructs.deinit(allocator);
}
fn hasTopic(topics: []const Topic, id: []const u8) bool {
    for (topics) |topic| if (std.mem.eql(u8, topic.id, id)) return true;
    return false;
}
fn parentOf(topics: []const Topic, id: []const u8) ?[]const u8 {
    for (topics) |topic| if (std.mem.eql(u8, topic.id, id)) return topic.parent;
    return null;
}
fn validId(id: []const u8) bool {
    var segments = std.mem.splitScalar(u8, id, '.');
    var count: usize = 0;
    while (segments.next()) |segment| {
        if (segment.len == 0 or !isIdStart(segment[0])) return false;
        for (segment) |byte| if (!isIdChar(byte)) return false;
        count += 1;
    }
    return count > 0;
}
fn isIdStart(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9');
}
fn isIdChar(byte: u8) bool {
    return isIdStart(byte) or byte == '_' or byte == '-';
}
fn alias(id: []const u8) []const u8 {
    if (std.mem.eql(u8, id, "collections")) return "collections";
    if (std.mem.eql(u8, id, "loops-and-iteration")) return "loops_and_iteration";
    return id;
}
fn valueAfter(line: []const u8, separator: u8) []const u8 {
    return std.mem.trim(u8, line[std.mem.indexOfScalar(u8, line, separator).? + 1 ..], " \t");
}
fn fieldName(line: []const u8) []const u8 {
    return std.mem.trim(u8, line[0..std.mem.indexOfScalar(u8, line, '=').?], " \t");
}
fn parseString(allocator: std.mem.Allocator, value: []const u8) Error![]u8 {
    const trimmed = std.mem.trim(u8, value, " \t\"");
    if (trimmed.len == 0) return error.Invalid;
    return allocator.dupe(u8, trimmed);
}

test "taxonomy loads mappings and documented aliases" {
    var taxonomy = try load(std.testing.allocator, "schema_version = 1\n[[topic]]\nid = \"collections\"\ntitle = \"Collections\"\nconstructs = [\"map\"]\n", "schema_version = 1\n[[idiom]]\nid = \"map\"\ntopic = \"collections\"\n");
    defer taxonomy.deinit();
    try std.testing.expect(taxonomy.topic("collections") != null);
    try std.testing.expectEqualStrings("collections", taxonomy.topicForConstruct("map").?);
    try std.testing.expectEqualStrings("collections", taxonomy.topicForIdiom("map").?);
}

test "taxonomy rejects duplicates, missing references, and cycles" {
    try std.testing.expectError(error.DuplicateId, load(std.testing.allocator, "schema_version = 1\n[[topic]]\nid = \"x\"\ntitle = \"X\"\n[[topic]]\nid = \"x\"\ntitle = \"X\"\n", "schema_version = 1\n"));
    try std.testing.expectError(error.UnknownReference, load(std.testing.allocator, "schema_version = 1\n[[topic]]\nid = \"x\"\ntitle = \"X\"\nparent = \"missing\"\n", "schema_version = 1\n"));
    try std.testing.expectError(error.Cycle, load(std.testing.allocator, "schema_version = 1\n[[topic]]\nid = \"a\"\ntitle = \"A\"\nparent = \"b\"\n[[topic]]\nid = \"b\"\ntitle = \"B\"\nparent = \"a\"\n", "schema_version = 1\n"));
}
