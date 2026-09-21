//! Conservative, versioned idiom classification over raw observations.
const std = @import("std");
const observation = @import("observation.zig");

pub const rule_version = "2";
pub const Classification = enum { proven_equivalence, potential_alternative };

pub const Match = struct {
    observation_index: usize,
    idiom_id: []const u8,
    reason: []const u8,
    confidence: []const u8,
    classification: Classification,
};

/// Rules classify observations conservatively. Only literal array/integer
/// receivers are considered proven; variables, calls, and absent receivers
/// remain potential alternatives.
pub fn detect(allocator: std.mem.Allocator, observations: []const observation.Observation) ![]Match { return detectObservations(allocator, observations); }

pub fn detectObservations(allocator: std.mem.Allocator, observations: []const observation.Observation) ![]Match {
    var matches = std.ArrayList(Match).empty;
    errdefer matches.deinit(allocator);
    for (observations, 0..) |obs, index| {
        const receiver = obs.receiver_kind orelse "unknown";
        if (std.mem.eql(u8, obs.construct, "map") or std.mem.eql(u8, obs.construct, "collect")) {
            const proven = std.mem.eql(u8, receiver, "array");
            try matches.append(allocator, .{
                .observation_index = index,
                .idiom_id = "collection_transformation",
                .reason = if (proven) "array receiver and map-like method directly express a transformation" else "map-like method suggests a collection transformation; receiver semantics are not proven",
                .confidence = if (proven) "high" else "medium",
                .classification = if (proven) .proven_equivalence else .potential_alternative,
            });
        } else if (std.mem.eql(u8, obs.construct, "each_with_index")) {
            try matches.append(allocator, .{ .observation_index = index, .idiom_id = "each_with_index", .reason = "each_with_index explicitly supplies an iteration index", .confidence = "high", .classification = .proven_equivalence });
        } else if (std.mem.eql(u8, obs.construct, "each_with_object")) {
            try matches.append(allocator, .{ .observation_index = index, .idiom_id = "each_with_object", .reason = "each_with_object explicitly supplies a shared accumulator object", .confidence = "high", .classification = .proven_equivalence });
        } else if (std.mem.eql(u8, obs.construct, "select") or std.mem.eql(u8, obs.construct, "filter") or std.mem.eql(u8, obs.construct, "reject")) {
            try matches.append(allocator, .{ .observation_index = index, .idiom_id = "collection_filter", .reason = "select/filter/reject directly express collection filtering", .confidence = "medium", .classification = .potential_alternative });
        } else if (std.mem.eql(u8, obs.construct, "reduce") or std.mem.eql(u8, obs.construct, "inject")) {
            try matches.append(allocator, .{ .observation_index = index, .idiom_id = "aggregation", .reason = "reduce/inject directly express accumulation", .confidence = "medium", .classification = .potential_alternative });
        } else if (std.mem.eql(u8, obs.construct, "each")) {
            try matches.append(allocator, .{
                .observation_index = index,
                .idiom_id = "collection_iteration",
                .reason = "each expresses iteration, but iteration alone does not prove a transformation",
                .confidence = if (std.mem.eql(u8, receiver, "array")) "high" else "medium",
                .classification = .potential_alternative,
            });
        } else if (std.mem.eql(u8, obs.construct, "times") and std.mem.eql(u8, receiver, "integer")) {
            try matches.append(allocator, .{
                .observation_index = index,
                .idiom_id = "fixed_iteration",
                .reason = "integer receiver proves a fixed iteration count",
                .confidence = "high",
                .classification = .proven_equivalence,
            });
        }
    }
    return try matches.toOwnedSlice(allocator);
}

/// Refine `each` classifications using the source span while retaining deterministic offsets.
pub fn detectSource(allocator: std.mem.Allocator, source: []const u8, observations: []const observation.Observation) ![]Match {
    const base = try detectObservations(allocator, observations);
    defer allocator.free(base);
    var result = std.ArrayList(Match).empty;
    errdefer result.deinit(allocator);
    for (base) |match| {
        const obs = observations[match.observation_index];
        if (!std.mem.eql(u8, obs.construct, "each")) {
            try result.append(allocator, match);
            continue;
        }
        const end = if (obs.end_offset < source.len) obs.end_offset else source.len;
        const text = if (obs.start_offset < end) source[obs.start_offset..end] else &.{};
        var refined = match;
        if (containsAny(text, &.{ "<<", ".push", ".append", ".concat" })) {
            refined.idiom_id = if (containsAny(text, &.{ " if ", " unless ", "next if", "next unless" })) "manual_filter" else "manual_collection_transformation";
            refined.reason = if (std.mem.eql(u8, refined.idiom_id, "manual_filter")) "each mutates a result collection only on a predicate path" else "each mutates a result collection for each input element";
            refined.confidence = "medium";
        } else if (containsAny(text, &.{ "+=", "-=", "*=", "/=", "sum =", "total =", "count =" })) {
            refined.idiom_id = "manual_accumulation";
            refined.reason = "each updates an accumulator across iterations";
            refined.confidence = "medium";
        }
        try result.append(allocator, refined);
    }
    for (observations, 0..) |obs, index| {
        if (!std.mem.eql(u8, obs.construct, "for")) continue;
        const end = if (obs.end_offset < source.len) obs.end_offset else source.len;
        const text = if (obs.start_offset < end) source[obs.start_offset..end] else &.{};
        if (containsAny(text, &.{ " in 0..", " in 1..", " in 0...", " in 1..." })) {
            try result.append(allocator, .{ .observation_index = index, .idiom_id = "fixed_iteration", .reason = "for loop iterates over a literal-start counter range", .confidence = "medium", .classification = .potential_alternative });
        }
    }
    return try result.toOwnedSlice(allocator);
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| if (std.mem.indexOf(u8, haystack, needle) != null) return true;
    return false;
}

test "idiom rules preserve conservative unknown context" {
    const matches = try detectObservations(std.testing.allocator, &.{
        .{ .start_offset = 0, .end_offset = 8, .line = 1, .column = 1, .node_kind = "PM_CALL_NODE", .construct = "map", .receiver_kind = "unknown" },
        .{ .start_offset = 9, .end_offset = 18, .line = 2, .column = 1, .node_kind = "PM_CALL_NODE", .construct = "map", .receiver_kind = "array" },
    });
    defer std.testing.allocator.free(matches);
    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expectEqual(.potential_alternative, matches[0].classification);
    try std.testing.expectEqual(.proven_equivalence, matches[1].classification);
    try std.testing.expectEqualStrings("2", rule_version);
}


test "source-aware manual loop classification" {
    const source = "xs.each { |x| out << x if x > 0 }\n";
    const observations = [_]observation.Observation{.{ .start_offset = 0, .end_offset = source.len, .line = 1, .column = 1, .node_kind = "PM_CALL_NODE", .construct = "each", .receiver_kind = "local_variable" }};
    const matches = try detectSource(std.testing.allocator, source, &observations);
    defer std.testing.allocator.free(matches);
    try std.testing.expectEqualStrings("manual_filter", matches[0].idiom_id);
}
