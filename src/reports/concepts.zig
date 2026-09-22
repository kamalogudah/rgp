//! Repository concept maps and cohort comparisons.
const std = @import("std");
const storage = @import("../storage/sqlite.zig");

pub const Concept = struct {
    id: []const u8,
    title: []const u8,
    prerequisite: ?[]const u8,
};

pub const known = [_]Concept{
    .{ .id = "each", .title = "Collection iteration", .prerequisite = "loops" },
    .{ .id = "for", .title = "For iteration", .prerequisite = "loops" },
    .{ .id = "times", .title = "Counted iteration", .prerequisite = "loops" },
    .{ .id = "while", .title = "Conditional loops", .prerequisite = "conditionals" },
    .{ .id = "map", .title = "Collection transformation", .prerequisite = "each" },
    .{ .id = "select", .title = "Collection filtering", .prerequisite = "each" },
    .{ .id = "reduce", .title = "Collection aggregation", .prerequisite = "each" },
    .{ .id = "size", .title = "Collection cardinality", .prerequisite = "collections" },
    .{ .id = "length", .title = "Collection cardinality", .prerequisite = "collections" },
    .{ .id = "count", .title = "Predicate-aware cardinality", .prerequisite = "collections" },
    .{ .id = "block", .title = "Blocks", .prerequisite = "methods" },
    .{ .id = "def", .title = "Methods", .prerequisite = "fundamentals" },
    .{ .id = "class", .title = "Classes", .prerequisite = "methods" },
    .{ .id = "module", .title = "Modules", .prerequisite = "classes" },
    .{ .id = "rescue", .title = "Exception handling", .prerequisite = "methods" },
};

pub const Map = struct {
    observed: [][]u8,
    absent: []const Concept,
    unknown: [][]u8,
    examples: []storage.SourceObservation,

    pub fn deinit(self: *Map, allocator: std.mem.Allocator) void {
        for (self.observed) |name| allocator.free(name);
        allocator.free(self.observed);
        for (self.unknown) |name| allocator.free(name);
        allocator.free(self.unknown);
        for (self.examples) |*example| example.deinit(allocator);
        allocator.free(self.examples);
    }
};

pub fn build(allocator: std.mem.Allocator, db: *storage.Database, filter: storage.StatisticsQuery) !Map {
    const observed = try db.queryConstructNames(allocator, filter);
    errdefer {
        for (observed) |name| allocator.free(name);
        allocator.free(observed);
    }
    var unknown = std.ArrayList([]u8).empty;
    var examples = std.ArrayList(storage.SourceObservation).empty;
    errdefer {
        for (unknown.items) |name| allocator.free(name);
        unknown.deinit(allocator);
        for (examples.items) |*example| example.deinit(allocator);
        examples.deinit(allocator);
    }
    for (observed) |name| {
        var recognized = false;
        for (known) |concept| {
            if (std.mem.eql(u8, concept.id, name)) recognized = true;
        }
        if (!recognized) try unknown.append(allocator, try allocator.dupe(u8, name));
        const found = try db.findExamples(allocator, name, filter, 1);
        if (found.len > 0) {
            try examples.append(allocator, found[0]);
            allocator.free(found);
        } else allocator.free(found);
    }
    var absent = std.ArrayList(Concept).empty;
    for (known) |concept| {
        var found = false;
        for (observed) |name| {
            if (std.mem.eql(u8, concept.id, name)) found = true;
        }
        if (!found) try absent.append(allocator, concept);
    }
    return .{ .observed = observed, .absent = try absent.toOwnedSlice(allocator), .unknown = try unknown.toOwnedSlice(allocator), .examples = try examples.toOwnedSlice(allocator) };
}
