//! Conservative, versioned idiom classification over raw observations.
const std = @import("std");
const observation = @import("observation.zig");
const parser = @import("../prism/parser.zig");

pub const rule_version = "4";
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
pub fn detect(allocator: std.mem.Allocator, observations: []const observation.Observation) ![]Match {
    return detectObservations(allocator, observations);
}

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

/// Refine observations with source-aware idiom classifications while retaining deterministic offsets.
pub fn detectSource(allocator: std.mem.Allocator, source: []const u8, observations: []const observation.Observation) ![]Match {
    const base = try detectObservations(allocator, observations);
    defer allocator.free(base);
    var result = std.ArrayList(Match).empty;
    errdefer result.deinit(allocator);
    for (base) |match| {
        const obs = observations[match.observation_index];
        const end = if (obs.end_offset < source.len) obs.end_offset else source.len;
        const text = if (obs.start_offset < end) source[obs.start_offset..end] else &.{};
        var refined = match;
        if (std.mem.eql(u8, obs.construct, "each")) {
            if (containsAny(text, &.{ "<<", ".push", ".append", ".concat" })) {
                refined.idiom_id = if (containsAny(text, &.{ " if ", " unless ", "next if", "next unless" })) "manual_filter" else "manual_collection_transformation";
                refined.reason = if (std.mem.eql(u8, refined.idiom_id, "manual_filter")) "each mutates a result collection only on a predicate path" else "each mutates a result collection for each input element";
                refined.confidence = "medium";
            } else if (containsAny(text, &.{ "+=", "-=", "*=", "/=", "sum =", "total =", "count =" })) {
                refined.idiom_id = "manual_accumulation";
                refined.reason = "each updates an accumulator across iterations";
                refined.confidence = "medium";
            }
        }
        if (std.mem.eql(u8, obs.construct, "if") or std.mem.eql(u8, obs.construct, "unless")) {
            if (isPostfixConditional(text)) try result.append(allocator, .{ .observation_index = match.observation_index, .idiom_id = "postfix_conditional", .reason = "postfix if/unless keeps a short conditional action on one line", .confidence = "high", .classification = .proven_equivalence });
            if (containsAny(text, &.{ "return ", "return\n", "next ", "break ", "raise " })) try result.append(allocator, .{ .observation_index = match.observation_index, .idiom_id = "conditional_guard", .reason = "early return/next/break/raise guards the remainder of the branch", .confidence = "medium", .classification = .potential_alternative });
            if (containsAny(text, &.{ ".empty?", ".size == 0", ".length == 0", ".count == 0" })) try result.append(allocator, .{ .observation_index = match.observation_index, .idiom_id = "empty_check", .reason = "conditional tests collection emptiness; count and size are not interchangeable in general", .confidence = if (std.mem.indexOf(u8, text, "empty?") != null) "high" else "medium", .classification = .potential_alternative });
            if (containsAny(text, &.{ ".nil?", " == nil", " != nil", " unless nil" })) try result.append(allocator, .{ .observation_index = match.observation_index, .idiom_id = "nil_guard", .reason = "conditional explicitly guards a nil value", .confidence = "high", .classification = .proven_equivalence });
        }
        if (std.mem.eql(u8, obs.construct, "new") and std.mem.startsWith(u8, std.mem.trim(u8, text, " \t\n"), "Hash.new")) try result.append(allocator, .{ .observation_index = match.observation_index, .idiom_id = "hash_default", .reason = "Hash.new supplies a default value or default block for missing keys", .confidence = "high", .classification = .proven_equivalence });
        if (std.mem.eql(u8, obs.construct, "new")) continue;
        if (std.mem.indexOf(u8, text, "&.") != null) try result.append(allocator, .{ .observation_index = match.observation_index, .idiom_id = "safe_navigation", .reason = "safe navigation skips the call when the receiver is nil", .confidence = "high", .classification = .proven_equivalence });
        if (std.mem.indexOf(u8, text, "&:") != null) try result.append(allocator, .{ .observation_index = match.observation_index, .idiom_id = "symbol_to_proc", .reason = "&:symbol converts a method symbol into a block; block arity and side effects still matter", .confidence = "high", .classification = .potential_alternative });
        if (std.mem.eql(u8, obs.construct, "def") and std.mem.indexOf(u8, text, "||=") != null) try result.append(allocator, .{ .observation_index = match.observation_index, .idiom_id = "memoization", .reason = "||= memoizes a method value, but falsey results do not remain cached", .confidence = "high", .classification = .potential_alternative });
        if (std.mem.eql(u8, obs.construct, "def")) {
            if (methodNameEnds(text, '?')) try result.append(allocator, .{ .observation_index = match.observation_index, .idiom_id = "predicate_method", .reason = "method definition name ends with ?, a syntactic predicate-method convention", .confidence = "high", .classification = .proven_equivalence });
            if (methodNameEnds(text, '!')) try result.append(allocator, .{ .observation_index = match.observation_index, .idiom_id = "bang_method", .reason = "method definition name ends with !, a syntactic bang-method convention", .confidence = "high", .classification = .proven_equivalence });
            if (std.mem.indexOf(u8, text, "...") != null) try result.append(allocator, .{ .observation_index = match.observation_index, .idiom_id = "method_forwarding", .reason = "method definition uses Ruby argument forwarding syntax; forwarded behavior is not inferred", .confidence = "high", .classification = .potential_alternative });
        }
        if (std.mem.eql(u8, obs.construct, "rescue") or std.mem.eql(u8, obs.construct, "inline_rescue")) {
            if (containsAny(text, &.{ "raise", "fail", "retry" })) try result.append(allocator, .{ .observation_index = match.observation_index, .idiom_id = "exception_as_control_flow", .reason = "exception syntax appears on a control-flow path; runtime intent is uncertain", .confidence = "low", .classification = .potential_alternative });
            if (std.mem.eql(u8, obs.construct, "rescue")) try result.append(allocator, .{ .observation_index = match.observation_index, .idiom_id = "rescue", .reason = "rescue clause is observed syntactically; handled exception behavior is not inferred", .confidence = "high", .classification = .proven_equivalence });
        }
        if (std.mem.eql(u8, obs.construct, "ensure")) try result.append(allocator, .{ .observation_index = match.observation_index, .idiom_id = "ensure", .reason = "ensure clause is observed syntactically; execution guarantees are not inferred", .confidence = "high", .classification = .proven_equivalence });
        if (std.mem.eql(u8, obs.construct, "inline_rescue")) try result.append(allocator, .{ .observation_index = match.observation_index, .idiom_id = "inline_rescue", .reason = "modifier rescue is observed syntactically", .confidence = "high", .classification = .proven_equivalence });
        if (std.mem.eql(u8, obs.construct, "retry")) try result.append(allocator, .{ .observation_index = match.observation_index, .idiom_id = "retry", .reason = "retry keyword is observed syntactically; retry safety is not inferred", .confidence = "high", .classification = .potential_alternative });
        if (std.mem.eql(u8, obs.construct, "raise") or std.mem.eql(u8, obs.construct, "fail")) try result.append(allocator, .{ .observation_index = match.observation_index, .idiom_id = "raise", .reason = "raise/fail call is observed syntactically; exception propagation is not inferred", .confidence = "high", .classification = .potential_alternative });
        if (std.mem.eql(u8, obs.construct, "include") or std.mem.eql(u8, obs.construct, "extend") or std.mem.eql(u8, obs.construct, "prepend")) try result.append(allocator, .{ .observation_index = match.observation_index, .idiom_id = "mixin", .reason = "include/extend/prepend call is observed syntactically; method lookup effects are not inferred", .confidence = "high", .classification = .potential_alternative });
        if (std.mem.eql(u8, obs.construct, "attr_reader") or std.mem.eql(u8, obs.construct, "attr_writer") or std.mem.eql(u8, obs.construct, "attr_accessor")) try result.append(allocator, .{ .observation_index = match.observation_index, .idiom_id = "class_macro", .reason = "attribute macro call is observed syntactically; generated methods are not expanded", .confidence = "high", .classification = .potential_alternative });
        if (std.mem.eql(u8, obs.construct, "private") or std.mem.eql(u8, obs.construct, "protected") or std.mem.eql(u8, obs.construct, "public") or std.mem.eql(u8, obs.construct, "module_function")) try result.append(allocator, .{ .observation_index = match.observation_index, .idiom_id = "visibility", .reason = "visibility directive is observed syntactically; its target method set is not inferred", .confidence = "high", .classification = .potential_alternative });
        if (std.mem.eql(u8, obs.construct, "super")) try result.append(allocator, .{ .observation_index = match.observation_index, .idiom_id = "method_forwarding", .reason = "super call forwards to an ancestor implementation; dispatch behavior is not inferred", .confidence = "high", .classification = .potential_alternative });
        if (std.mem.eql(u8, obs.construct, "return") or std.mem.eql(u8, obs.construct, "next") or std.mem.eql(u8, obs.construct, "break")) try result.append(allocator, .{ .observation_index = match.observation_index, .idiom_id = "early_return", .reason = "early control-flow keyword is observed; whether it forms a guard is not inferred", .confidence = "high", .classification = .potential_alternative });
        try result.append(allocator, refined);
    }
    // Source-only idioms may be attached to constructs that have no base rule.
    for (observations, 0..) |obs, index| {
        const end = if (obs.end_offset < source.len) obs.end_offset else source.len;
        const text = if (obs.start_offset < end) source[obs.start_offset..end] else &.{};
        if (std.mem.eql(u8, obs.construct, "if") or std.mem.eql(u8, obs.construct, "unless")) {
            if (isPostfixConditional(text)) try result.append(allocator, .{ .observation_index = index, .idiom_id = "postfix_conditional", .reason = "postfix if/unless keeps a short conditional action on one line", .confidence = "high", .classification = .proven_equivalence });
            if (containsAny(text, &.{ "return ", "return\n", "next ", "break ", "raise " })) try result.append(allocator, .{ .observation_index = index, .idiom_id = "conditional_guard", .reason = "early return/next/break/raise guards the remainder of the branch", .confidence = "medium", .classification = .potential_alternative });
            if (containsAny(text, &.{ ".empty?", ".size == 0", ".length == 0", ".count == 0" })) try result.append(allocator, .{ .observation_index = index, .idiom_id = "empty_check", .reason = "conditional tests collection emptiness; count and size are not interchangeable in general", .confidence = "high", .classification = .potential_alternative });
            if (containsAny(text, &.{ ".nil?", " == nil", " != nil", " unless nil" })) try result.append(allocator, .{ .observation_index = index, .idiom_id = "nil_guard", .reason = "conditional explicitly guards a nil value", .confidence = "high", .classification = .proven_equivalence });
        }
        if (std.mem.eql(u8, obs.construct, "new") and std.mem.startsWith(u8, std.mem.trim(u8, text, " \t\n"), "Hash.new")) try result.append(allocator, .{ .observation_index = index, .idiom_id = "hash_default", .reason = "Hash.new supplies a default value or default block for missing keys", .confidence = "high", .classification = .proven_equivalence });
        if (std.mem.eql(u8, obs.construct, "def") and std.mem.indexOf(u8, text, "||=") != null) try result.append(allocator, .{ .observation_index = index, .idiom_id = "memoization", .reason = "||= memoizes a method value, but falsey results do not remain cached", .confidence = "high", .classification = .potential_alternative });
        if (std.mem.eql(u8, obs.construct, "def")) {
            if (methodNameEnds(text, '?')) try result.append(allocator, .{ .observation_index = index, .idiom_id = "predicate_method", .reason = "method definition name ends with ?, a syntactic predicate-method convention", .confidence = "high", .classification = .proven_equivalence });
            if (methodNameEnds(text, '!')) try result.append(allocator, .{ .observation_index = index, .idiom_id = "bang_method", .reason = "method definition name ends with !, a syntactic bang-method convention", .confidence = "high", .classification = .proven_equivalence });
            if (std.mem.indexOf(u8, text, "...") != null) try result.append(allocator, .{ .observation_index = index, .idiom_id = "method_forwarding", .reason = "method definition uses Ruby argument forwarding syntax; forwarded behavior is not inferred", .confidence = "high", .classification = .potential_alternative });
        }
        if (std.mem.eql(u8, obs.construct, "rescue") or std.mem.eql(u8, obs.construct, "inline_rescue")) try result.append(allocator, .{ .observation_index = index, .idiom_id = if (std.mem.eql(u8, obs.construct, "rescue")) "rescue" else "inline_rescue", .reason = "exception syntax is observed; runtime handling is not inferred", .confidence = "high", .classification = .potential_alternative });
        if (std.mem.eql(u8, obs.construct, "ensure")) try result.append(allocator, .{ .observation_index = index, .idiom_id = "ensure", .reason = "ensure clause is observed syntactically; execution guarantees are not inferred", .confidence = "high", .classification = .proven_equivalence });
        if (std.mem.eql(u8, obs.construct, "retry")) try result.append(allocator, .{ .observation_index = index, .idiom_id = "retry", .reason = "retry keyword is observed syntactically; retry safety is not inferred", .confidence = "high", .classification = .potential_alternative });
        if (std.mem.eql(u8, obs.construct, "raise") or std.mem.eql(u8, obs.construct, "fail")) try result.append(allocator, .{ .observation_index = index, .idiom_id = "raise", .reason = "raise/fail call is observed syntactically; exception propagation is not inferred", .confidence = "high", .classification = .potential_alternative });
        if (std.mem.eql(u8, obs.construct, "include") or std.mem.eql(u8, obs.construct, "extend") or std.mem.eql(u8, obs.construct, "prepend")) try result.append(allocator, .{ .observation_index = index, .idiom_id = "mixin", .reason = "include/extend/prepend call is observed syntactically; method lookup effects are not inferred", .confidence = "high", .classification = .potential_alternative });
        if (std.mem.eql(u8, obs.construct, "attr_reader") or std.mem.eql(u8, obs.construct, "attr_writer") or std.mem.eql(u8, obs.construct, "attr_accessor")) try result.append(allocator, .{ .observation_index = index, .idiom_id = "class_macro", .reason = "attribute macro call is observed syntactically; generated methods are not expanded", .confidence = "high", .classification = .potential_alternative });
        if (std.mem.eql(u8, obs.construct, "private") or std.mem.eql(u8, obs.construct, "protected") or std.mem.eql(u8, obs.construct, "public") or std.mem.eql(u8, obs.construct, "module_function")) try result.append(allocator, .{ .observation_index = index, .idiom_id = "visibility", .reason = "visibility directive is observed syntactically; its target method set is not inferred", .confidence = "high", .classification = .potential_alternative });
        if (std.mem.eql(u8, obs.construct, "super")) try result.append(allocator, .{ .observation_index = index, .idiom_id = "method_forwarding", .reason = "super call forwards to an ancestor implementation; dispatch behavior is not inferred", .confidence = "high", .classification = .potential_alternative });
        if (std.mem.eql(u8, obs.construct, "return") or std.mem.eql(u8, obs.construct, "next") or std.mem.eql(u8, obs.construct, "break")) try result.append(allocator, .{ .observation_index = index, .idiom_id = "early_return", .reason = "early control-flow keyword is observed; whether it forms a guard is not inferred", .confidence = "high", .classification = .potential_alternative });
        if (std.mem.indexOf(u8, text, "&.") != null) try result.append(allocator, .{ .observation_index = index, .idiom_id = "safe_navigation", .reason = "safe navigation skips the call when the receiver is nil", .confidence = "high", .classification = .proven_equivalence });
    }
    for (observations, 0..) |obs, index| {
        if (!std.mem.eql(u8, obs.construct, "for")) continue;
        const end = if (obs.end_offset < source.len) obs.end_offset else source.len;
        const text = if (obs.start_offset < end) source[obs.start_offset..end] else &.{};
        if (containsAny(text, &.{ " in 0..", " in 1..", " in 0...", " in 1..." })) try result.append(allocator, .{ .observation_index = index, .idiom_id = "fixed_iteration", .reason = "for loop iterates over a literal-start counter range", .confidence = "medium", .classification = .potential_alternative });
    }
    return try result.toOwnedSlice(allocator);
}

fn methodNameEnds(text: []const u8, suffix: u8) bool {
    const start = std.mem.indexOf(u8, text, "def ") orelse return false;
    var i = start + 4;
    while (i < text.len and text[i] != ' ' and text[i] != '(' and text[i] != '\n' and text[i] != '\r') : (i += 1) {}
    return i > start + 4 and text[i - 1] == suffix;
}

fn isPostfixConditional(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    return std.mem.indexOf(u8, trimmed, " if ") != null or std.mem.indexOf(u8, trimmed, " unless ") != null;
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
    try std.testing.expectEqualStrings("4", rule_version);
}

test "source-aware manual loop classification" {
    const source = "xs.each { |x| out << x if x > 0 }\n";
    const observations = [_]observation.Observation{.{ .start_offset = 0, .end_offset = source.len, .line = 1, .column = 1, .node_kind = "PM_CALL_NODE", .construct = "each", .receiver_kind = "local_variable" }};
    const matches = try detectSource(std.testing.allocator, source, &observations);
    defer std.testing.allocator.free(matches);
    try std.testing.expectEqualStrings("manual_filter", matches[0].idiom_id);
}

test "phase 4 idioms cover positive and semantic-negative fixtures" {
    const source = "def value\n  @value ||= compute\nend\n" ++
        "items.each { |item| out << item if item }\n" ++
        "if record.nil?\n  return nil\nend\n" ++
        "items.map(&:name)\n" ++
        "user&.size\n" ++
        "if items.count == 0\n  return []\nend\n" ++
        "cache = Hash.new { |h, k| h[k] = [] }\n" ++
        "class Child\n" ++
        "  include Feature\n" ++
        "  extend Feature\n" ++
        "  prepend Feature\n" ++
        "  attr_reader :value\n" ++
        "  attr_writer :value\n" ++
        "  attr_accessor :other\n" ++
        "  private\n" ++
        "  protected\n" ++
        "  public\n" ++
        "  def ready?\n    true\n  end\n" ++
        "  def refresh!\n    super\n  end\n" ++
        "  def run\n    risky rescue nil\n  end\n" ++
        "  def failer\n    fail :boom\n  end\n" ++
        "  def retryer\n    begin\n      work\n    rescue\n      retry\n    end\n  end\n" ++
        "  def rescued\n    begin\n      work\n    rescue\n      recover\n    end\n  end\n" ++
        "  def guarded\n    begin\n      work\n    ensure\n      cleanup\n    end\n  end\n" ++
        "end\n";
    var document = try parser.parse(std.testing.allocator, source, .{});
    defer document.deinit();
    const observations = try observation.extract(std.testing.allocator, &document);
    defer std.testing.allocator.free(observations);
    const matches = try detectSource(std.testing.allocator, source, observations);
    defer std.testing.allocator.free(matches);
    var found = std.StringHashMap(void).init(std.testing.allocator);
    defer found.deinit();
    for (matches) |match| {
        try found.put(match.idiom_id, {});
        try std.testing.expect(match.observation_index < observations.len);
        try std.testing.expect(observations[match.observation_index].start_offset <= observations[match.observation_index].end_offset);
    }
    inline for ([_][]const u8{ "memoization", "manual_filter", "nil_guard", "symbol_to_proc", "safe_navigation", "hash_default", "empty_check", "mixin", "class_macro", "visibility", "predicate_method", "bang_method", "method_forwarding", "inline_rescue", "ensure", "early_return", "raise", "retry", "rescue" }) |id| try std.testing.expect(found.contains(id));
    for (matches) |match| if (std.mem.eql(u8, match.idiom_id, "symbol_to_proc")) try std.testing.expectEqual(Classification.potential_alternative, match.classification);
    for (matches) |match| if (std.mem.eql(u8, match.idiom_id, "empty_check")) {
        try std.testing.expectEqual(Classification.potential_alternative, match.classification);
        try std.testing.expect(std.mem.indexOf(u8, match.reason, "not interchangeable") != null);
    };
    for (matches) |match| if (std.mem.eql(u8, match.idiom_id, "memoization")) {
        try std.testing.expectEqual(Classification.potential_alternative, match.classification);
        try std.testing.expect(std.mem.indexOf(u8, match.reason, "falsey") != null);
    };
}
